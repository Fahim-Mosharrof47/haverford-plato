//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import AppKit
import CoreText
import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    // MARK: - Skilly
    private let skillManager = SkillManager.createDefault()
    let authManager = AuthManager.shared

    /// Plato — registers the bundled Geist / Geist Mono fonts with the process so SwiftUI's
    /// Font.custom("Geist" / "Geist Mono") resolves. Works whether the .ttf files are copied
    /// flat into Resources or kept under a Fonts/ subdirectory.
    private static func registerBundledFonts() {
        for name in ["Geist-Variable", "GeistMono-Variable"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // MARK: - Plato — Single-instance guard.
        // Plato is a menu-bar (LSUIElement) app with no Dock icon, so older copies are easy to
        // leave running (a login-item launch plus an Xcode/manual launch). Two instances both
        // run the intro / timer announcements / focus nudges and speak over each other. Terminate
        // any older copies so only this (newest) instance survives.
        let currentProcessID = NSRunningApplication.current.processIdentifier
        let duplicateInstances = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
                && $0.processIdentifier != currentProcessID
        }
        for duplicate in duplicateInstances {
            duplicate.terminate()
        }

        // MARK: - Skilly — Debug logging (stripped in release)
        #if DEBUG
        print("🎯 Skilly: Starting...")
        print("🎯 Skilly: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")
        #endif

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        // Plato — register the bundled Geist fonts before any UI is built.
        Self.registerBundledFonts()

        SkillyAnalytics.configure()
        SkillyAnalytics.trackAppOpened()
        // MARK: - Skilly — If a Keychain session was restored during
        // AuthManager.init() (loadStoredUser), re-identify the user in PostHog
        // now that the SDK has been configured. This covers the "already
        // authenticated on launch" case from the PostHog identification task.
        authManager.identifyCurrentUserIfAuthenticated()
        SkillyNotificationManager.shared.requestAuthorization()

        // Inject skill manager into companion and panel
        companionManager.setSkillManager(skillManager)
        skillManager.seedBundledSkillsIfNeeded()
        skillManager.loadInstalledSkills()

        // Register for skilly:// deep links (WorkOS auth callback)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        menuBarPanelManager = MenuBarPanelManager(
            companionManager: companionManager,
            skillManager: skillManager,
            authManager: authManager
        )
        companionManager.start()
        // Plato — load the last session's recap so Plato can open with a re-entry briefing.
        companionManager.loadLastSessionForBriefing()
        if authManager.isAuthenticated {
            Task { await EntitlementManager.shared.refresh() }
        }
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        unregisterLoginItemIfNeeded()
        // startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Plato — persist the session snapshot for next launch's re-entry briefing.
        companionManager.persistSession()
        companionManager.stop()
    }

    // MARK: - Plato — Do NOT auto-launch at login.
    /// Plato should only run when the user explicitly launches it (e.g. by
    /// building & running from Xcode). Earlier builds registered the app as a
    /// macOS login item on every launch via `SMAppService.mainApp.register()`,
    /// which made it start automatically on every login and stay "always on".
    /// This actively removes any such leftover registration so the app no
    /// longer starts on login. It is a no-op once nothing is registered.
    private func unregisterLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        switch loginItemService.status {
        case .enabled, .requiresApproval:
            do {
                try loginItemService.unregister()
                #if DEBUG
                print("🎯 Plato: Unregistered login item — will not start on login")
                #endif
            } catch {
                #if DEBUG
                print("⚠️ Plato: Failed to unregister login item: \(error)")
                #endif
            }
        default:
            // .notRegistered / .notFound — nothing to remove.
            break
        }
    }

    // MARK: - Deep Link Handler (WorkOS Auth Callback)

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "skilly" else {
            return
        }

        // MARK: - Skilly — Handle checkout-success deep link
        // After paying on Polar, the success page has an "Open Skilly"
        // button that links to skilly://checkout-success. Refresh the
        // entitlement so the PlanStrip updates without a relaunch.
        if url.host == "checkout-success" {
            #if DEBUG
            print("🎯 Skilly: Received checkout-success deep link, refreshing entitlement")
            #endif
            Task { await EntitlementManager.shared.refresh() }
            return
        }

        guard url.host == "auth",
              url.path == "/callback" || url.path == "callback" else {
            return
        }

        // Extract the authorization code from the callback URL
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value else {
            // MARK: - Skilly — Debug logging (stripped in release)
            #if DEBUG
            print("⚠️ Skilly Auth: No code in callback URL")
            #endif
            return
        }

        // MARK: - Skilly — Debug logging (stripped in release)
        #if DEBUG
        print("🎯 Skilly Auth: Received auth callback with code")
        #endif
        let state = components?.queryItems?.first(where: { $0.name == "state" })?.value
        authManager.handleAuthCallback(code: code, state: state)
        Task { await EntitlementManager.shared.refresh() }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            // MARK: - Skilly — Debug logging (stripped in release)
            #if DEBUG
            print("⚠️ Skilly: Sparkle updater failed to start: \(error)")
            #endif
        }
    }
}
