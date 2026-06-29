// MARK: - Skilly
//
//  AppSettings.swift
//  leanring-buddy
//
//  Central settings model for Skilly. All user preferences are stored
//  in UserDefaults and exposed as @Published properties so SwiftUI
//  views and managers react to changes automatically.
//

import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: - Skilly — Configurable Endpoints

    /// Base URL for the Cloudflare Worker proxy. All API calls route through this endpoint.
    /// Change this to point to your own Worker instance. Defaults to the Skilly-hosted proxy.
    @Published var workerBaseURL: String {
        didSet { UserDefaults.standard.set(workerBaseURL, forKey: "workerBaseURL") }
    }

    /// PostHog analytics API key. Set to empty string to disable analytics entirely.
    @Published var postHogAPIKey: String {
        didSet { UserDefaults.standard.set(postHogAPIKey, forKey: "postHogAPIKey") }
    }

    // MARK: - Skilly — Bring Your Own Key (BYOK)

    /// User-supplied OpenAI API key. When non-empty, the app bypasses the
    /// Skilly worker relay and mints ephemeral Realtime sessions directly
    /// against api.openai.com using this key. Stored in UserDefaults
    /// (plaintext on disk). The user is billed by OpenAI for usage.
    @Published var openAIAPIKey: String {
        didSet { UserDefaults.standard.set(openAIAPIKey, forKey: "openAIAPIKey") }
    }

    /// True when the user has provided their own OpenAI key.
    /// Drives BYOK code paths: bypassing the relay, skipping trial gating,
    /// and surfacing a "BYOK active" indicator in the UI.
    var hasOwnAPIKey: Bool {
        !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether analytics tracking is enabled. When false, no events are sent to PostHog.
    @Published var analyticsEnabled: Bool {
        didSet { UserDefaults.standard.set(analyticsEnabled, forKey: "analyticsEnabled") }
    }

    /// Whether the user has consented to beta telemetry. Required before sending
    /// skilly_turn_completed and skilly_session_ended events to PostHog.
    /// Explicitly names PostHog as the analytics processor.
    @Published var beta_terms_consent: Bool {
        didSet { UserDefaults.standard.set(beta_terms_consent, forKey: "beta_terms_consent") }
    }

    // MARK: - Skilly — External asset URLs

    /// URL for the HLS onboarding video stream. Forks should replace with their own asset.
    /// Set to empty string to skip onboarding video entirely.
    @Published var onboardingVideoURL: String {
        didSet { UserDefaults.standard.set(onboardingVideoURL, forKey: "onboardingVideoURL") }
    }

    // MARK: - Language

    /// Preferred language for speech recognition and AI responses.
    /// Uses ISO 639-1 codes (e.g., "en", "es", "ar", "de").
    /// Default: system language or "en".
    @Published var preferredLanguage: String {
        didSet { UserDefaults.standard.set(preferredLanguage, forKey: "preferredLanguage") }
    }

    /// When true, auto-detect language from the user's speech.
    /// When false, always use preferredLanguage.
    @Published var autoDetectLanguage: Bool {
        didSet { UserDefaults.standard.set(autoDetectLanguage, forKey: "autoDetectLanguage") }
    }

    /// Human-readable name for a language code.
    static let supportedLanguages: [(code: String, name: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ar", "Arabic"),
        ("zh", "Chinese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("ru", "Russian"),
        ("hi", "Hindi"),
        ("tr", "Turkish"),
        ("nl", "Dutch"),
        ("pl", "Polish"),
        ("sv", "Swedish"),
    ]

    static func languageName(for code: String) -> String {
        supportedLanguages.first(where: { $0.code == code })?.name ?? code
    }

    // MARK: - Shortcuts

    /// Display name for the push-to-talk shortcut.
    /// Stored as a string key that maps to BuddyPushToTalkShortcut.ShortcutOption.
    @Published var pushToTalkShortcut: String {
        didSet { UserDefaults.standard.set(pushToTalkShortcut, forKey: "pushToTalkShortcut") }
    }

    /// Display name for the cancel shortcut key.
    /// Stored as a keyCode integer.
    @Published var cancelKeyCode: UInt16 {
        didSet { UserDefaults.standard.set(Int(cancelKeyCode), forKey: "cancelKeyCode") }
    }

    /// Human-readable name for the cancel key.
    var cancelKeyDisplayName: String {
        switch cancelKeyCode {
        case 53: return "Escape"
        case 51: return "Delete"
        case 117: return "Forward Delete"
        default: return "Key \(cancelKeyCode)"
        }
    }

    // MARK: - Voice

    /// OpenAI Realtime voice name.
    @Published var voiceName: String {
        didSet { UserDefaults.standard.set(voiceName, forKey: "voiceName") }
    }

    // Pipeline is always OpenAI Realtime — classic pipeline removed.

    // MARK: - Voice Input Mode

    /// Controls how voice input is captured. "pushToTalk" requires holding the hotkey;
    /// "liveTutor" uses always-on listening with server-side VAD for a hands-free experience.
    /// Valid values: "pushToTalk", "liveTutor".
    @Published var voiceInputMode: String {
        didSet { UserDefaults.standard.set(voiceInputMode, forKey: "voiceInputMode") }
    }

    /// Number of minutes of silence after which Live Tutor mode automatically sleeps.
    /// When 0, Live Tutor never auto-sleeps. Only applies when voiceInputMode is "liveTutor".
    @Published var liveTutorAutoSleepMinutes: Int {
        didSet { UserDefaults.standard.set(liveTutorAutoSleepMinutes, forKey: "liveTutorAutoSleepMinutes") }
    }

    // MARK: - Plato — Academic companion

    /// Master switch for Plato's always-active academic persona. When true, the bundled
    /// `plato-academic-tutor` skill stays active across every foreground app. When false,
    /// the persona is turned off entirely (the real off-switch for the global skill).
    /// Drives `SkillManager.activateGlobalSkillOrDeactivate()`.
    @Published var academicModeEnabled: Bool {
        didSet { UserDefaults.standard.set(academicModeEnabled, forKey: "academicModeEnabled") }
    }

    // MARK: - Plato — Pomodoro focus timer

    /// Length of a focus (work) block in minutes. Pickable: 15 / 25 / 45 / 60.
    @Published var pomodoroWorkMinutes: Int {
        didSet { UserDefaults.standard.set(pomodoroWorkMinutes, forKey: "pomodoroWorkMinutes") }
    }

    /// Length of a break in minutes. Pickable: 5 / 10 / 15.
    @Published var pomodoroBreakMinutes: Int {
        didSet { UserDefaults.standard.set(pomodoroBreakMinutes, forKey: "pomodoroBreakMinutes") }
    }

    /// Number of focus blocks in a set (the "N" in "3 of N").
    @Published var pomodoroSessionsPerBlock: Int {
        didSet { UserDefaults.standard.set(pomodoroSessionsPerBlock, forKey: "pomodoroSessionsPerBlock") }
    }

    // MARK: - Plato — Research

    /// Optional OpenAlex API key (primary paper-search source). Keyless works for light use
    /// (~100 searches/day) but then rate-limits; a free key (openalex.org/settings/api) raises it
    /// to ~1000/day. Sent as the `api_key` query param. Empty by default.
    @Published var openAlexAPIKey: String {
        didSet { UserDefaults.standard.set(openAlexAPIKey, forKey: "openAlexAPIKey") }
    }

    /// Optional Semantic Scholar API key (legacy / unused by the current OpenAlex-first path;
    /// kept for forward compatibility). Empty by default.
    @Published var semanticScholarAPIKey: String {
        didSet { UserDefaults.standard.set(semanticScholarAPIKey, forKey: "semanticScholarAPIKey") }
    }

    // MARK: - Init

    private init() {
        // Skilly — Configurable endpoints
        self.workerBaseURL = UserDefaults.standard.string(forKey: "workerBaseURL")
            ?? "https://skilly-proxy.eng-mohamedszaied.workers.dev"

        // BYOK — load user-supplied OpenAI key if previously saved.
        self.openAIAPIKey = UserDefaults.standard.string(forKey: "openAIAPIKey") ?? ""

        // PostHog key — migrate any stale cached keys to the current default.
        let currentPostHogKey = "phc_D46KQXyPXhmRabFDiL3KUZTWJcmjyqhpGJfpH7H48Sso"
        let cachedPostHogKey = UserDefaults.standard.string(forKey: "postHogAPIKey")
        let staleKeys: Set<String> = [
            "phc_qkw7erTLNNLwstjfYatewM9WheZ7MS9WkXgzF6HdzpPV",  // previous project
            "phc_xcQPygmhTMzzYh8wNW92CCwoXmnzqyChAixh8zgpqC3C",  // upstream Clicky
        ]
        if let cachedKey = cachedPostHogKey, !staleKeys.contains(cachedKey) {
            self.postHogAPIKey = cachedKey
        } else {
            self.postHogAPIKey = currentPostHogKey
            UserDefaults.standard.set(currentPostHogKey, forKey: "postHogAPIKey")
        }
        self.analyticsEnabled = UserDefaults.standard.object(forKey: "analyticsEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "analyticsEnabled")
        self.beta_terms_consent = UserDefaults.standard.bool(forKey: "beta_terms_consent")

        // Skilly — External assets
        self.onboardingVideoURL = UserDefaults.standard.string(forKey: "onboardingVideoURL")
            ?? "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8"

        // Language
        let systemLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        self.preferredLanguage = UserDefaults.standard.string(forKey: "preferredLanguage")
            ?? (AppSettings.supportedLanguages.contains(where: { $0.code == systemLanguage }) ? systemLanguage : "en")
        self.autoDetectLanguage = UserDefaults.standard.object(forKey: "autoDetectLanguage") == nil
            ? false  // Default OFF — use preferred language
            : UserDefaults.standard.bool(forKey: "autoDetectLanguage")

        // Shortcuts
        // MARK: - Plato — Default ctrl+shift+8 (was ctrl+option+0); see BuddyPushToTalkShortcut.
        // One-time migration: earlier builds persisted an older default (control+option or
        // ctrl+option+0), and a persisted value overrides the new default. Move those installs
        // onto ctrl+shift+8 exactly once, then never again — so a user who later picks a
        // different shortcut in Settings keeps their choice. (didSet does not fire in init,
        // so the migration writes UserDefaults directly.)
        let pushToTalkMigratedKey = "pushToTalkShortcutMigratedToControlShiftEight"
        if !UserDefaults.standard.bool(forKey: pushToTalkMigratedKey) {
            UserDefaults.standard.set("controlShiftEight", forKey: "pushToTalkShortcut")
            UserDefaults.standard.set(true, forKey: pushToTalkMigratedKey)
        }
        self.pushToTalkShortcut = UserDefaults.standard.string(forKey: "pushToTalkShortcut") ?? "controlShiftEight"
        self.cancelKeyCode = UInt16(UserDefaults.standard.integer(forKey: "cancelKeyCode") == 0
            ? 53  // Default: Escape
            : UserDefaults.standard.integer(forKey: "cancelKeyCode"))

        // Voice
        self.voiceName = UserDefaults.standard.string(forKey: "voiceName") ?? "ash"

        // Voice Input Mode
        self.voiceInputMode = UserDefaults.standard.string(forKey: "voiceInputMode") ?? "pushToTalk"
        self.liveTutorAutoSleepMinutes = UserDefaults.standard.object(forKey: "liveTutorAutoSleepMinutes") == nil
            ? 5  // Default: auto-sleep after 5 minutes of silence
            : UserDefaults.standard.integer(forKey: "liveTutorAutoSleepMinutes")

        // Plato — Academic mode defaults ON so the persona is present out of the box.
        self.academicModeEnabled = UserDefaults.standard.object(forKey: "academicModeEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "academicModeEnabled")

        // Plato — Pomodoro defaults: 25-minute focus, 5-minute break, 4 blocks per set.
        self.pomodoroWorkMinutes = UserDefaults.standard.object(forKey: "pomodoroWorkMinutes") == nil
            ? 25
            : UserDefaults.standard.integer(forKey: "pomodoroWorkMinutes")
        self.pomodoroBreakMinutes = UserDefaults.standard.object(forKey: "pomodoroBreakMinutes") == nil
            ? 5
            : UserDefaults.standard.integer(forKey: "pomodoroBreakMinutes")
        self.pomodoroSessionsPerBlock = UserDefaults.standard.object(forKey: "pomodoroSessionsPerBlock") == nil
            ? 4
            : UserDefaults.standard.integer(forKey: "pomodoroSessionsPerBlock")

        // Plato — Research
        self.openAlexAPIKey = UserDefaults.standard.string(forKey: "openAlexAPIKey") ?? ""
        self.semanticScholarAPIKey = UserDefaults.standard.string(forKey: "semanticScholarAPIKey") ?? ""

        // Pipeline is always OpenAI Realtime
    }
}
