//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses an active (.defaultTap) CGEvent tap so it can SWALLOW the
//  shortcut's own key presses — otherwise a key-combo like ctrl + shift + 8 falls
//  through to the frontmost app, which beeps on the unhandled modified keystroke.
//  Only the shortcut's own keys are consumed; all other input passes through.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    // MARK: - Skilly — Escape key for cancel
    let escapeKeyPressedPublisher = PassthroughSubject<Void, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // MARK: - Plato — Active tap (was .listenOnly) so the callback can return
            // nil to delete the shortcut's own key events before they reach the focused
            // app. A listen-only tap can only observe, so the modified keystroke fell
            // through and the app beeped on it (the "unhandled key" ping).
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // MARK: - Skilly — Debug logging (stripped in release)
            #if DEBUG
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            #endif
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            // MARK: - Skilly — Debug logging (stripped in release)
            #if DEBUG
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            #endif
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // MARK: - Skilly — Detect cancel key press (configurable, default: Escape)
        let cancelKeyCode = AppSettings.shared.cancelKeyCode
        if eventKeyCode == cancelKeyCode && (eventType == .keyDown || eventType.rawValue == 10) {
            // MARK: - Skilly — Debug logging (stripped in release)
            #if DEBUG
            print("🛑 Cancel key detected (keyCode=\(eventKeyCode), eventType=\(eventType.rawValue))")
            #endif
            escapeKeyPressedPublisher.send()
        }

        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        // MARK: - Plato — Decide whether to swallow this event BEFORE the switch
        // below mutates isShortcutCurrentlyPressed, so the keyUp case sees the
        // pre-release state.
        let shouldConsumeShortcutKeyEvent = BuddyPushToTalkShortcut.shouldConsumeEvent(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        // MARK: - Plato — Swallow the shortcut's own key events so the modified
        // keystroke never reaches the frontmost app (which would beep on it).
        // Everything else (typing, modifiers, Escape, other apps' shortcuts)
        // passes through untouched.
        if shouldConsumeShortcutKeyEvent {
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}
