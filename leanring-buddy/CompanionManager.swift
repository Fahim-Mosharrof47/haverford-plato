//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from the model response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?
    /// Live transcript bubble text rendered in the same overlay as the cursor.
    /// This keeps the spoken response physically attached to the floating cursor.
    @Published private(set) var realtimeResponseBubbleText: String = ""
    /// True while the response transcript bubble should be visible beside the cursor.
    @Published private(set) var isShowingRealtimeResponseBubble: Bool = false

    // MARK: - Plato — Visual highlights
    /// Momentary teaching highlights drawn by the overlay. Always time-boxed;
    /// cleared at every turn boundary so a stale absolute-coordinate box never
    /// lingers after the user scrolls.
    @Published var activeHighlights: [PlatoHighlight] = []
    private var highlightExpirationTimer: Timer?
    /// Bumped on every clearAllHighlights() (i.e. every turn boundary). Async
    /// resolution work (highlight_text OCR) records the generation it started
    /// under and drops its result if the generation moved on — a slow OCR from
    /// the previous turn must never paint a stale box into the current one.
    private var highlightGeneration = 0

    func addHighlight(_ highlight: PlatoHighlight) {
        installHighlightDismissalMonitorIfNeeded()
        activeHighlights.append(highlight)
        startHighlightExpirationTimerIfNeeded()
    }

    func clearAllHighlights() {
        // Always advance the generation: a turn boundary invalidates in-flight
        // OCR work even when nothing is currently drawn.
        highlightGeneration += 1
        guard !activeHighlights.isEmpty || highlightExpirationTimer != nil else { return }
        activeHighlights.removeAll()
        highlightExpirationTimer?.invalidate()
        highlightExpirationTimer = nil
    }

    /// Prunes expired highlights ~5x/sec. Runs only while highlights exist, then
    /// stops itself — no always-on timer. Mirrors the bezier flight's Timer idiom.
    private func startHighlightExpirationTimerIfNeeded() {
        guard highlightExpirationTimer == nil else { return }
        highlightExpirationTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                self.activeHighlights.removeAll { $0.isExpired(at: now) }
                if self.activeHighlights.isEmpty {
                    self.highlightExpirationTimer?.invalidate()
                    self.highlightExpirationTimer = nil
                }
            }
        }
    }

    // MARK: - Plato — Auto-dismiss highlights on first user interaction
    private var highlightDismissalMonitor: Any?

    /// Absolute-coordinate highlights go stale the instant content moves; a
    /// scroll/click/drag is the signal to clear them. Global monitors are
    /// read-only (cannot consume events), which is exactly what we want.
    private func installHighlightDismissalMonitorIfNeeded() {
        guard highlightDismissalMonitor == nil else { return }
        highlightDismissalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged]
        ) { [weak self] _ in
            Task { @MainActor in self?.clearAllHighlights() }
        }
    }

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Plato — Guided onboarding tour state
    /// The step the guided first-run tour is on, or nil when it isn't running.
    enum OnboardingStep {
        case intro
        case focusTimer
        case skills
        case research
    }
    /// A panel control the tour can fly the cursor to.
    enum OnboardingPointTarget {
        case focusTimerStart
        case addSkill
    }
    @Published private(set) var guidedOnboardingStep: OnboardingStep?
    /// Live on-screen (AppKit) frames of pointable panel controls, reported by the panel.
    private var onboardingTargetScreenFrames: [OnboardingPointTarget: CGRect] = [:]
    /// Per-step fallback timer that advances the tour if the user doesn't act.
    private var onboardingStepTimeoutTimer: Timer?
    /// Types out the persistent instruction bubble for the current step.
    private var onboardingBubbleTypeTimer: Timer?
    /// Watches the focus timer so the tour advances the moment a block starts.
    private var onboardingFocusTimerObservation: AnyCancellable?

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    // MARK: - Skilly

    /// Optional skill manager — when set and a skill is active, the companion
    /// uses a composed system prompt with domain teaching instructions instead
    /// of the generic Skilly prompt. When nil or no skill active, original
    /// Skilly behavior is preserved.
    private var skillManager: SkillManager?

    func setSkillManager(_ manager: SkillManager) {
        self.skillManager = manager
    }

    /// Returns the skill-composed system prompt if a skill is active,
    /// otherwise falls back to the base Skilly prompt.
    private var composedSystemPrompt: String {
        // Plato: dynamic per-turn context (scholar contract, focus topic, re-entry briefing)
        // is appended to the base prompt here so it flows through BOTH the skill-composed path
        // and the fallback — and stays out of the Rust-backed SkillPromptComposer.
        let base = modeAwareBasePrompt + "\n\n" + platoSessionContext
        if let skillManager,
           let composed = skillManager.composedSystemPrompt(basePrompt: base) {
            return composed
        }
        return base
    }

    // MARK: - Skilly Core

    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

    // MARK: - Skilly — OpenAI Realtime Pipeline
    let openAIRealtimeClient = OpenAIRealtimeClient()
    private var realtimeAudioPlayer: RealtimeAudioPlayer?  // Plays PCM16 24kHz
    private var realtimeEventSubscription: AnyCancellable?
    private var realtimeAudioEngine: AVAudioEngine?
    private var realtimePushToTalkTask: Task<Void, Never>?
    // MARK: - Skilly — Realtime transcript accumulation
    private var realtimeResponseText: String = ""
    private var currentTurnUserTranscript: String?
    /// Screen capture metadata for the current turn, used to map [POINT:x,y]
    /// tags from screenshot pixel space back into global AppKit screen space.
    private var currentTurnScreenCaptures: [CompanionScreenCapture] = []
    /// When the user pressed push-to-talk for the current turn. Used to
    /// measure turn duration for usage tracking (recorded on response.done).
    private var currentTurnStartTime: Date?

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    private var shortcutTransitionCancellable: AnyCancellable?
    // MARK: - Skilly — Escape key cancel
    private var escapeKeyCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?
    /// True after `responseDone` while waiting for the realtime audio queue
    /// to finish playing. Prevents transcript bubble from hiding too early.
    private var isWaitingForRealtimeAudioQueueDrain = false
    private var voiceSettingCancellable: AnyCancellable?
    private var prewarmConnectionTask: Task<Void, Error>?
    private let minimumAudioChunksRequiredToCommit = 1
    private var hasEndedAssistantSpeechForCurrentTurn = false
    private var didReceivePointToolCallForCurrentTurn = false
    private var didReceiveAnyAudioChunkForCurrentTurn = false
    private var pendingToolCallIdForCurrentTurn: String?
    private var isAwaitingForcedSpokenFollowUp = false
    // MARK: - Plato — Set while a focus block is being started by a voice command, so the
    // onWorkStart announcement is suppressed (the tool continuation speaks the confirmation).
    private var isVoiceInitiatedPomodoroStart = false

    // MARK: - Plato — In-flight async research tool calls (search_scholar).
    // Deliberately NOT reset on turn boundaries (push-to-talk start / VAD speech_started):
    // a multi-second network fetch can outlive the turn, and we must still deliver the
    // function_call_output for its call_id. Capped at one in-flight call for the MVP.
    private var pendingResearchCallIds = Set<String>()

    // MARK: - Plato — Dynamic session context (injected into the system prompt)
    /// The current focus-block topic (set by the Pomodoro timer). Included in the prompt so the
    /// persona's distraction-detection has context. Nil when no focus block is active.
    @Published var currentFocusTopic: String?
    /// One-shot last-session summary for the re-entry briefing (set on launch by
    /// SessionStateManager). Surfaced in the prompt until the session has re-entered.
    var pendingSessionBriefing: String?

    // MARK: - Plato — Pomodoro focus timer
    /// Lazily created so its callbacks can capture a fully-initialized self. The panel UI
    /// observes this object directly. Plato stays SILENT on timer transitions — the only
    /// time it speaks on its own is a distraction nudge during an active focus block (below).
    lazy var pomodoro: PomodoroTimer = {
        let timer = PomodoroTimer()
        timer.onFocusTopicChange = { [weak self] topic in
            self?.currentFocusTopic = topic
            self?.sessionState.recordFocusTopic(topic)
        }
        timer.onWorkStart = { [weak self] session, total, topic in
            guard let self else { return }
            self.startFocusWatch()  // begin watching for distraction
            // MARK: - Plato — When the block was started by a voice command, the tool
            // continuation already speaks the confirmation — don't double-speak here.
            if self.isVoiceInitiatedPomodoroStart {
                self.isVoiceInitiatedPomodoroStart = false
                return
            }
            let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedTopic.isEmpty {
                // No topic yet — ask what they're working on. The user answers by holding
                // push-to-talk, and the model records the answer via control_pomodoro(set_topic).
                self.speakProactiveAnnouncement(
                    "A focus block just started (block \(session) of \(total)). In ONE short, warm sentence, ask the user what they're working on this block so you can help keep them on track."
                )
            } else {
                self.speakProactiveAnnouncement(
                    "A focus block just started (block \(session) of \(total)). The user is focusing on: \"\(trimmedTopic)\". In ONE short sentence, acknowledge it and say you'll help keep them on track."
                )
            }
        }
        timer.onWorkEnd = { [weak self] _, _ in
            self?.sessionState.recordPomodoroCompleted()
            self?.stopFocusWatch()
            self?.speakProactiveAnnouncement(
                "The focus block just ended — it's break time. In one or two short sentences, congratulate the user and give a brief recap of what they worked on this block based on your recent conversation, then suggest a short break."
            )
        }
        timer.onBreakEnd = { [weak self] in
            self?.speakProactiveAnnouncement(
                "The break just ended. In one short sentence, gently nudge the user back to work."
            )
        }
        return timer
    }()

    /// Speaks a one-off proactive line via the realtime session (no-op unless connected).
    /// Used ONLY for distraction nudges during a focus block — Plato is otherwise silent.
    func speakProactiveAnnouncement(_ instruction: String) {
        openAIRealtimeClient.requestForcedSpokenResponse(instruction: instruction)
    }

    // MARK: - Plato — True while Plato is mid push-to-talk turn, answering, still
    // generating, or draining a spoken line's audio tail. Distraction nudges DEFER
    // (skip this tick, keep the cooldown unstamped) rather than cancel, so a nudge
    // never talks over the user or over a prior nudge, and is never dropped by the
    // GA Realtime "one active response at a time" rule. Mirrors the readiness
    // signals used by isOnboardingLineStillSpeaking.
    private var isPlatoBusySpeakingOrListening: Bool {
        voiceState != .idle
            || openAIRealtimeClient.isModelSpeaking
            || isWaitingForRealtimeAudioQueueDrain
    }

    // MARK: - Plato — Focus watch (distraction nudges during an active focus block)

    private var focusWatchTimer: Timer?
    private var lastFocusNudgeAt: Date?
    // MARK: - Plato — Prevents overlapping focus checks: classifyFocus is a network
    // call, and at a ~15s check interval a slow/hung request could otherwise let a
    // second check start (and double-nudge) before the first finishes.
    private var isFocusCheckInFlight = false
    /// How often to glance at the screen during a focus block. Kept well below the
    /// nudge cooldown so the every-other-check rhythm lands on the target cadence.
    private let focusWatchIntervalSeconds: TimeInterval = 15
    /// Minimum gap between spoken nudges. Set a few seconds BELOW the 30s target
    /// cadence (not at it) so the post-classify stamp drift + timer jitter don't
    /// push the next eligible check past the target and slip the cadence to ~45s.
    /// Must stay strictly greater than focusWatchIntervalSeconds. Requirement:
    /// nudge roughly every 30s while continuously off-task, first nudge ~15s.
    private let focusNudgeCooldownSeconds: TimeInterval = 28

    private func startFocusWatch() {
        stopFocusWatch()
        // Ensure the session is connected so a nudge can actually be spoken.
        startRealtimeSessionPrewarmIfNeeded()
        focusWatchTimer = Timer.scheduledTimer(withTimeInterval: focusWatchIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.performFocusCheck() }
        }
    }

    private func stopFocusWatch() {
        focusWatchTimer?.invalidate()
        focusWatchTimer = nil
    }

    /// Glances at the screen and, only if the user is clearly off-task relative to their declared
    /// focus topic, speaks a single gentle nudge. Detection is a silent, cheap vision call — the
    /// realtime voice is used only to deliver the nudge. Requires a BYOK OpenAI key.
    private func performFocusCheck() {
        guard pomodoro.phase == .work, pomodoro.isRunning else {
            stopFocusWatch()
            return
        }
        let topic = (currentFocusTopic ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return }  // need a declared topic to judge "off-task"
        // Respect the cooldown — never nag.
        if let last = lastFocusNudgeAt, Date().timeIntervalSince(last) < focusNudgeCooldownSeconds {
            return
        }
        // MARK: - Plato — Don't stack a vision call on top of one already running.
        guard !isFocusCheckInFlight else { return }
        // MARK: - Plato — Defer (don't cancel) if Plato is mid-turn: the user is
        // holding push-to-talk, Plato is answering, a prior nudge is still being
        // spoken, or its audio tail is still draining. Speaking now would either
        // talk over the user or be dropped by the GA "one active response" rule.
        // We simply skip this tick without stamping the cooldown, so the next
        // ~15s check re-evaluates and speaks once Plato is idle again.
        guard !isPlatoBusySpeakingOrListening else { return }

        isFocusCheckInFlight = true
        Task { @MainActor in
            defer { isFocusCheckInFlight = false }
            guard let capture = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG().first else { return }
            let result = await classifyFocus(jpeg: capture.imageData, topic: topic)
            // Re-check everything after the awaits: the block may have paused/ended,
            // or Plato may have started speaking, while the vision call was in flight.
            guard result.distracted, pomodoro.phase == .work, pomodoro.isRunning,
                  !isPlatoBusySpeakingOrListening else { return }
            lastFocusNudgeAt = Date()
            let reasonClause = result.reason.map { " (looks like \($0))" } ?? ""
            speakProactiveAnnouncement(
                "The user is in a focus session working on \"\(topic)\" but their screen looks off-task\(reasonClause). "
                + "Give ONE short, friendly nudge to get back to it — amused, like a labmate, not preachy. "
                + "Do not mention that you are watching their screen."
            )
        }
    }

    /// Silent off-task classifier: asks a cheap vision model whether the screenshot is off-task
    /// for the focus topic. Returns (distracted, reason). No-ops (returns not-distracted) when no
    /// BYOK key is set. Never throws.
    private func classifyFocus(jpeg: Data, topic: String) async -> (distracted: Bool, reason: String?) {
        let key = AppSettings.shared.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            return (false, nil)
        }
        let dataURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "max_tokens": 60,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text":
                        "The user is in a focus session working on: \"\(topic)\". Look at this screenshot of their screen. "
                        + "Are they CLEARLY off-task — social media, YouTube/video, games, shopping, or unrelated browsing? "
                        + "If it could plausibly relate to their work, or you're unsure, treat it as NOT distracted. "
                        + "Reply with ONLY compact JSON: {\"distracted\": true|false, \"reason\": \"<a few words>\"}."],
                    ["type": "image_url", "image_url": ["url": dataURL]],
                ],
            ]],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return (false, nil)
        }

        // The model may wrap JSON in ``` fences — strip them before parsing.
        let cleaned = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsedData = cleaned.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: parsedData) as? [String: Any] {
            return ((parsed["distracted"] as? Bool) ?? false, parsed["reason"] as? String)
        }
        // MARK: - Plato — Parse failure ⇒ treat as on-task. Never nudge on uncertain output.
        return (false, nil)
    }

    // MARK: - Plato — Local session state + re-entry briefing
    let sessionState = SessionStateManager()

    /// Called at launch: loads the previous session's recap so the persona can open with a
    /// re-entry briefing. Surfaced via platoSessionContext until the session has re-entered.
    func loadLastSessionForBriefing() {
        pendingSessionBriefing = sessionState.loadLastSummary()
    }

    /// Called at quit: persists the current session snapshot for next launch's briefing.
    func persistSession() {
        sessionState.persistCurrentSession()
    }
    private var rustRealtimeEventLog: [RustRealtimeBridge.RealtimeEventPayload] = []
    private var currentRustRealtimeTurnID: String?
    private var latestRustRealtimePhaseName: String = "idle"

    // MARK: - Skilly — Live Tutor mode state
    private var isLiveTutorModeActive = false
    private var liveTutorAudioEngine: AVAudioEngine?
    private var liveTutorAutoSleepTask: Task<Void, Never>?
    private var liveTutorSettingsCancellable: AnyCancellable?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// User preference for whether the Skilly cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isSkillyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isSkillyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isSkillyCursorEnabled")

    func setSkillyCursorEnabled(_ enabled: Bool) {
        isSkillyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isSkillyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    // MARK: - Skilly — Email submission: FormSpark endpoint removed for open-source.
    // The hasSubmittedEmail flag is set locally so the UI dismisses correctly.
    // Forks can add their own email collection here if desired.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")
    }

    func start() {
        refreshAllPermissions()
        // MARK: - Skilly — Debug logging (stripped in release)
        #if DEBUG
        print("🔑 Skilly start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        #endif
        startPermissionPolling()
        bindShortcutTransitions()
        bindSettingsObservers()
        installScreenReconfigurationObserverIfNeeded()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isSkillyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        if hasCompletedOnboarding && allPermissionsGranted {
            startRealtimeSessionPrewarmIfNeeded()
        }
    }

    // MARK: - Plato — Display reconfiguration (dock/undock, rearrange)
    /// Overlay windows and every BlueCursorView's immutable screenFrame are
    /// captured at creation, so adding/removing/rearranging monitors leaves a
    /// newly attached display with NO overlay and the remaining overlays
    /// converting against stale frames. Rebuild the overlays (and drop
    /// highlights — their global frames are stale by definition) whenever the
    /// screen arrangement changes.
    private var screenParametersObserver: NSObjectProtocol?

    private func installScreenReconfigurationObserverIfNeeded() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenReconfiguration() }
        }
    }

    private func handleScreenReconfiguration() {
        clearAllHighlights()
        clearDetectedElementLocation()
        guard overlayWindowManager.isShowingOverlay() else { return }
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .skillyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        SkillyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .skillyDismissPanel, object: nil)
        SkillyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    // MARK: - Plato — Demo reset
    /// Rewinds Plato to its first-run state so the onboarding can be demoed
    /// again. Clears the onboarding/email flags the panel gates on, tears down
    /// the cursor overlay so the welcome animation + intro video replay fresh,
    /// and nudges observers so the panel reverts to showing the "Start" button.
    /// Intentionally does NOT sign the user out or touch permissions/skills —
    /// it only rewinds onboarding so clicking "Start" replays the full intro.
    func resetOnboardingForDemo() {
        // Plato: fully tear down any in-progress guided tour first. Otherwise its
        // step state (guidedOnboardingStep) and timers survive the rewind — a
        // lingering non-nil step would keep the realtime transcript bubble
        // suppressed for later interactions, and an orphaned step timer could
        // fire after the reset.
        finishGuidedOnboarding()

        // Rewind the first-run flags the panel gates on.
        hasCompletedOnboarding = false
        hasSubmittedEmail = false
        UserDefaults.standard.set(false, forKey: "hasSubmittedEmail")

        // Tear down the overlay so the next onboarding run starts from the
        // welcome animation (isFirstAppearance == true) instead of a warm
        // cursor that has already been shown.
        stopOnboardingMusic()
        tearDownOnboardingVideo()
        overlayWindowManager.hideOverlay()
        overlayWindowManager.hasShownOverlayBefore = false
        isOverlayVisible = false

        // hasCompletedOnboarding is a plain UserDefaults-backed property (not
        // @Published), so explicitly notify observers to re-render the panel
        // into its first-run state showing the "Start" button.
        objectWillChange.send()
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            // MARK: - Skilly — Debug logging (stripped in release)
            #if DEBUG
            print("⚠️ Skilly: ff.mp3 not found in bundle")
            #endif
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // Plato — the music is faded out by the guided tour itself
            // (finishGuidedOnboarding, when the tour ends), so it accompanies the
            // whole intro instead of the old fixed 90s timer that was sized for
            // the removed (longer) intro video.
        } catch {
            // MARK: - Skilly — Debug logging (stripped in release)
            #if DEBUG
            print("⚠️ Skilly: Failed to play onboarding music: \(error)")
            #endif
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        overlayWindowManager.hideOverlay()
        isWaitingForRealtimeAudioQueueDrain = false
        clearRealtimeResponseBubble()
        transientHideTask?.cancel()
        shortcutTransitionCancellable?.cancel()
        voiceSettingCancellable?.cancel()
        prewarmConnectionTask?.cancel()
        prewarmConnectionTask = nil
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil

        let sessionDurationSeconds = TimeInterval(RealtimeTelemetry.shared.currentSessionDurationMs) / 1000
        recordSessionSecondsIfNeeded(sessionDurationSeconds)
        SkillyNotificationManager.shared.checkAndSendTrial80PercentWarning()
        SkillyNotificationManager.shared.checkAndSendUsage80PercentWarning()

        RealtimeTelemetry.shared.endSession()
        openAIRealtimeClient.disconnect()
    }

    private func recordSessionSecondsIfNeeded(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        // MARK: - Skilly — Fall back to trial when no entitlement is set
        // (new user, offline, or Worker hasn't synced). This ensures
        // usage starts tracking immediately on first use.
        switch EntitlementManager.shared.status {
        case .trial, .none:
            // Ensure the trial has been started before recording seconds;
            // otherwise recordSessionSeconds bails out on !hasStarted.
            TrialTracker.shared.beginTrialIfNeeded()
            TrialTracker.shared.recordSessionSeconds(seconds)
        case .active, .canceled:
            UsageTracker.shared.recordSessionSeconds(seconds)
        case .expired:
            break
        }
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            // MARK: - Skilly — Debug logging (stripped in release)
            #if DEBUG
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
            #endif
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            SkillyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            SkillyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            SkillyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            SkillyAnalytics.trackAllPermissionsGranted()
            if hasCompletedOnboarding {
                startRealtimeSessionPrewarmIfNeeded()
            }
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                // MARK: - Skilly — Debug logging (stripped in release)
                #if DEBUG
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                #endif
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    SkillyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isSkillyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                // MARK: - Skilly — Debug logging (stripped in release)
                #if DEBUG
                print("⚠️ Screen content permission request failed: \(error)")
                #endif
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }

        // MARK: - Skilly — Escape key to cancel recording or response
        escapeKeyCancellable = globalPushToTalkShortcutMonitor
            .escapeKeyPressedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleEscapeKeyPressed()
            }
    }

    private func bindSettingsObservers() {
        voiceSettingCancellable = AppSettings.shared.$voiceName
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newVoiceName in
                guard let self else { return }
                Task { @MainActor in
                    do {
                        try await self.openAIRealtimeClient.updateVoice(voiceName: newVoiceName)
                    } catch {
                        #if DEBUG
                        print("⚠️ OpenAI Realtime: failed to update voice to \(newVoiceName): \(error)")
                        #endif
                    }
                }
            }

        // MARK: - Skilly — Live Tutor: react to voiceInputMode changes
        liveTutorSettingsCancellable = AppSettings.shared.$voiceInputMode
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newMode in
                guard let self else { return }
                if newMode == "liveTutor" {
                    self.startLiveTutorMode()
                } else {
                    self.stopLiveTutorMode()
                }
            }
    }

    private func startRealtimeSessionPrewarmIfNeeded() {
        guard prewarmConnectionTask == nil else { return }
        guard !openAIRealtimeClient.isConnected else { return }

        let configuredVoiceName = AppSettings.shared.voiceName
        let currentSystemPrompt = composedSystemPrompt
        prewarmConnectionTask = Task { @MainActor in
            try await openAIRealtimeClient.connect(
                systemPrompt: currentSystemPrompt,
                voiceName: configuredVoiceName
            )
            ensureRealtimeEventSubscriptionAndAudioPlayer()
        }
    }

    private func ensureRealtimeEventSubscriptionAndAudioPlayer() {
        if realtimeEventSubscription == nil {
            realtimeEventSubscription = openAIRealtimeClient.eventPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] event in
                    self?.handleRealtimeEvent(event)
                }
        }

        if realtimeAudioPlayer == nil {
            let realtimeAudioPlayer = RealtimeAudioPlayer()
            realtimeAudioPlayer.onQueueDrained = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleRealtimeAudioQueueDrained()
                }
            }
            self.realtimeAudioPlayer = realtimeAudioPlayer
        }
    }

    private func ensureRealtimeSessionReadyForTurn() async throws {
        let configuredVoiceName = AppSettings.shared.voiceName
        let currentSystemPrompt = composedSystemPrompt

        let (allowed, reason) = EntitlementManager.shared.canStartTurn()
        if !allowed {
            NotificationCenter.default.post(
                name: .skillyTurnBlocked,
                object: nil,
                userInfo: reason.map { ["blockReason": $0] }
            )
            throw SkillManager.SkillAccessError.entitlementBlocked(reason ?? .subscriptionInactive)
        }

        if let prewarmConnectionTask {
            defer { self.prewarmConnectionTask = nil }
            _ = try await prewarmConnectionTask.value
        }

        if !openAIRealtimeClient.isConnected {
            try await openAIRealtimeClient.connect(
                systemPrompt: currentSystemPrompt,
                voiceName: configuredVoiceName
            )
            RealtimeTelemetry.shared.beginSession(model: openAIRealtimeClient.currentModel)
        } else {
            try await openAIRealtimeClient.updateSessionConfiguration(
                systemPrompt: currentSystemPrompt,
                voiceName: configuredVoiceName
            )
        }

        ensureRealtimeEventSubscriptionAndAudioPlayer()
    }

    // MARK: - Skilly — Escape Key Cancel Handler

    private func handleEscapeKeyPressed() {
        // MARK: - Skilly — Debug logging (stripped in release)
        #if DEBUG
        print("🛑 Escape handler: voiceState=\(voiceState), isModelSpeaking=\(openAIRealtimeClient.isModelSpeaking)")
        #endif

        // Check if the model is speaking even if voiceState hasn't updated
        if openAIRealtimeClient.isModelSpeaking {
            // MARK: - Skilly — Debug logging (stripped in release)
            #if DEBUG
            print("🛑 Escape: stopping AI response (model still speaking)")
            #endif
            openAIRealtimeClient.cancelResponse()
            realtimeAudioPlayer?.stop()
            isWaitingForRealtimeAudioQueueDrain = false
            voiceState = .idle
            clearRealtimeResponseBubble()
            resetRustRealtimeTracking()
            return
        }

        switch voiceState {
        case .listening:
            // MARK: - Skilly — Debug logging (stripped in release)
            #if DEBUG
            print("🛑 Escape: cancelling recording")
            #endif
            realtimeAudioEngine?.stop()
            realtimeAudioEngine?.inputNode.removeTap(onBus: 0)
            realtimeAudioEngine = nil
            realtimePushToTalkTask?.cancel()
            realtimePushToTalkTask = nil
            openAIRealtimeClient.clearAudioBuffer()
            isWaitingForRealtimeAudioQueueDrain = false
            voiceState = .idle
            clearRealtimeResponseBubble()
            resetRustRealtimeTracking()

        case .processing:
            // MARK: - Skilly — Debug logging (stripped in release)
            #if DEBUG
            print("🛑 Escape: cancelling pending response")
            #endif
            openAIRealtimeClient.cancelResponse()
            isWaitingForRealtimeAudioQueueDrain = false
            voiceState = .idle
            clearRealtimeResponseBubble()
            resetRustRealtimeTracking()

        case .responding:
            // MARK: - Skilly — Debug logging (stripped in release)
            #if DEBUG
            print("🛑 Escape: stopping AI response")
            #endif
            openAIRealtimeClient.cancelResponse()
            realtimeAudioPlayer?.stop()
            isWaitingForRealtimeAudioQueueDrain = false
            voiceState = .idle
            clearRealtimeResponseBubble()
            resetRustRealtimeTracking()

        case .idle:
            break
        }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // MARK: - Plato — pre-arm Chromium/Electron accessibility for THIS turn.
            // The user is about to speak (seconds pass before any point_at_element
            // tool call), so the frontmost app's on-demand AX tree has time to
            // populate — the real control is then resolvable by name instead of
            // forcing the unsafe hit-test fallback. Cheap, non-blocking; runs for
            // both PTT and liveTutor since it precedes the mode branch.
            AXElementResolver.enableOnDemandAccessibilityForFrontmostApp()

            // MARK: - Plato — The user just engaged Plato directly; push the next
            // distraction-nudge eligibility out by the full cooldown so Plato doesn't
            // nag right after the user spoke to it. If they immediately go off-task,
            // the next nudge is still only ~cooldown away. No effect outside a focus
            // block (lastFocusNudgeAt is only consulted while the watch is running).
            lastFocusNudgeAt = Date()

            // MARK: - Skilly — In Live Tutor mode, the PTT shortcut
            // toggles the mode on/off. Does NOT fall through to PTT.
            if AppSettings.shared.voiceInputMode == "liveTutor" {
                if isLiveTutorModeActive {
                    stopLiveTutorMode()
                } else {
                    startLiveTutorMode()
                }
                return
            }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isSkillyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .skillyDismissPanel, object: nil)

            // MARK: - Skilly — Clear stale pointing state from previous utterance
            clearDetectedElementLocation()
            clearRealtimeResponseBubble()

            // Plato: when the user holds push-to-talk to take their own turn, end
            // any guided tour first. Clearing guidedOnboardingStep lifts the
            // transcript-bubble suppression — otherwise Plato answers the user's
            // question aloud with no on-screen text. finishGuidedOnboarding also
            // hides the tour's instruction bubble, so the answer doesn't stack a
            // second box on top of it.
            if guidedOnboardingStep != nil {
                finishGuidedOnboarding()
            } else if showOnboardingPrompt {
                // Not in a tour, but a prompt is lingering — dismiss it.
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }

            SkillyAnalytics.trackPushToTalkStarted()

            // MARK: - Skilly — OpenAI Realtime pipeline
            startOpenAIRealtimePushToTalk()

        case .released:
            SkillyAnalytics.trackPushToTalkReleased()
            stopOpenAIRealtimePushToTalk()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    // MARK: - Skilly — Base prompt for realtime assistant responses
    private static let realtimeCompanionBasePrompt = """
    you're Plato, an always-on academic research companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - speak in a calm, steady, grounded tone — composed and reassuring, like a wise mentor who's never rattled. but keep a normal conversational pace: don't slow down, drag words out, or go soft, breathy, or sleepy. calm and clear, not mellow or sluggish.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing — show, don't just tell:
    you have a small blue cursor that flies to and points at things on screen, plus tools to ring controls, highlight text, shade regions, pulse a spot, and show a scroll arrow. these are the core of how you help — not an optional flourish. whenever your answer refers to something the user can SEE — a button, menu, icon, tab, field, a region of a document, or a specific piece of text — point at it or highlight it in the SAME response. don't just describe where something is in words and leave the user to hunt for it; show them. default to showing. a purely verbal "it's in the top right" is a fallback for when you truly can't show, not your normal move.

    if you walk the user through several steps, show each thing as you mention it — point at or highlight every one, not only the first.

    only skip showing when there's genuinely nothing on screen to show — a general-knowledge question, or the conversation has nothing to do with what's on screen. and never point at a guess: if the target isn't actually visible, or you can't name it, don't fly the cursor to a made-up spot — instead say the menu path out loud, or tell the user which way to scroll and show it once it's visible. declining to show is always better than showing the wrong thing.

    ABSOLUTE RULE: you must ALWAYS speak a spoken response to the user. speech is mandatory on every single turn. pointing and highlighting are additional, never a replacement. never respond with only a tool call and no speech — if you do, the user hears nothing and thinks plato is broken. speak first, show second (in the same response).

    to point at a control, call the `point_at_element` tool IN ADDITION to your spoken response. you emit both the spoken message AND the tool call as part of the same response. the tool takes:
    - x, y — integer pixel coordinates in the screenshot's coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward. the screenshot images are labeled with their pixel dimensions — use those dimensions as the coordinate space.
    - label — a short 1-3 word name of the element, like "frame tool" or "save button". give the exact on-screen name — plato uses it to find and ring the real control.
    - screen — optional 1-based screen number when there are multiple screenshots. omit if the element is on the cursor's screen. include it if the element is on a DIFFERENT screen (use the screen number from the image label). this is important — without the screen number, the cursor will point at the wrong place.

    never say "point", never read coordinates out loud, never mention any tool name, and never describe the tool call in your spoken response. tool calls are silent metadata — just speak naturally about what the user should do, and call the tools in parallel.

    when the user says things like "show me", "where is it", "can you point", "guide me" — they are asking for BOTH a spoken explanation AND the cursor moving. you must deliver both. do not interpret "show me" as "skip speech and only call the tool". always include the spoken explanation.

    examples (every example shows BOTH the spoken response AND the tool call — never one without the other when the thing is on screen):
    - user: "how do i color grade in final cut?" → you say: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves." AND you call point_at_element with x=1100, y=42, label="color inspector"
    - user: "what is html?" → you say: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at?" (no tool call — general knowledge question, speech only)
    - user: "can you show me how to commit in xcode?" → you say: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut." AND you call point_at_element with x=285, y=11, label="source control"
    - user: "walk me through submitting this form" → you say: "first fill in your name up top, then your email just below, then hit submit at the bottom." AND you call point_at_element once for each field as you name it, each with its own label
    - user: "where's my terminal?" (on another monitor) → you say: "that's over on your other monitor — see the terminal window?" AND you call point_at_element with x=400, y=300, label="terminal", screen=2
    """

    // MARK: - Skilly — Mode-aware prompt for Live Tutor vs push-to-talk

    /// Returns the base prompt with a mode-specific preamble.
    /// In Live Tutor mode, the model should know it's always listening
    /// and should respond more concisely since there's no deliberate
    /// push-to-talk action from the user.
    private var modeAwareBasePrompt: String {
        if isLiveTutorModeActive {
            return Self.realtimeCompanionBasePrompt.replacingOccurrences(
                of: "the user just spoke to you via push-to-talk",
                with: "you're in live tutor mode — always listening. the user is working and talking to you naturally without pressing any buttons. they might think aloud, ask quick questions, or narrate what they're doing. be extra concise unless they ask for detail — they're in a flow state and interruptions should be short"
            )
        }
        return Self.realtimeCompanionBasePrompt
    }

    // MARK: - Plato — Dynamic context + search_scholar tool

    /// Static instruction describing the search_scholar tool contract and citation discipline.
    /// Reinforces the persona SKILL.md at the operational level (the model sees both).
    private static let platoScholarInstruction = """
    RESEARCH & CITATIONS: You have a search_scholar tool that returns REAL academic papers. \
    When the user asks about research, asks who studied or proved something, wants citations, \
    or asks what to read, call search_scholar — do not answer about specific papers from memory. \
    Cite ONLY papers the tool returns, each by its exact title and first author (et al. if more). \
    If the tool returns a paper matching what the user asked for, report it as FOUND — state its exact \
    title and first author — even if the year or venue looks unusual or the record is marked a preprint. \
    Do NOT claim you couldn't find a paper when the tool actually returned a match. \
    Give the year only if the tool provides one; year and venue may be missing or approximate for \
    preprints, so if a year looks off or is absent, say you're not certain rather than stating it as fact. \
    Never invent or recall a title, author, year, journal, or DOI. If a returned paper has no summary, \
    say so rather than guessing. If the tool reports no results, an error, or a rate limit, tell the user \
    you could not find or reach the literature and suggest rephrasing — never fabricate a source.
    """

    /// Dynamic per-turn context appended to the base prompt: the scholar contract plus, when
    /// present, the active focus topic and the last-session re-entry briefing. Injected at the
    /// CompanionManager level (not the Rust-backed composer) to keep Plato out of the Rust layer.
    private var platoSessionContext: String {
        var sections: [String] = [Self.platoScholarInstruction]

        if let focusTopic = currentFocusTopic?.trimmingCharacters(in: .whitespacesAndNewlines),
           !focusTopic.isEmpty {
            sections.append(
                "ACTIVE FOCUS BLOCK: The user is in a focus session working on: \"\(focusTopic)\". "
                + "If the screen clearly shows something unrelated to this during the block, nudge them "
                + "back once, lightly — then drop it."
            )
        }

        if let briefing = pendingSessionBriefing?.trimmingCharacters(in: .whitespacesAndNewlines),
           !briefing.isEmpty {
            sections.append(
                "LAST SESSION (use for a one- or two-sentence re-entry briefing when the session opens): "
                + briefing
            )
        }

        return sections.joined(separator: "\n\n")
    }

    /// Handle a `search_scholar` function call: parse args, fetch from the Worker `/papers`
    /// route, and return the real result to the model via `sendToolResultAndContinue`. The
    /// network work runs off the current turn (the turn may end before the fetch resolves);
    /// `pendingResearchCallIds` survives turn resets so the correct call_id is always closed.
    private func handleScholarToolCall(argumentsJSON: String, callId: String) {
        // Parse arguments (query required; limit optional, clamped 1...10, default 5).
        var query = ""
        var limit = 5
        if let data = argumentsJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            query = (object["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let rawLimit = object["limit"] as? Int {
                limit = rawLimit
            } else if let rawLimit = object["limit"] as? Double {
                limit = Int(rawLimit)
            } else if let rawLimit = object["limit"] as? String, let parsed = Int(rawLimit) {
                limit = parsed
            }
        }
        limit = min(max(limit, 1), 10)

        guard !query.isEmpty else {
            openAIRealtimeClient.sendToolResultAndContinue(
                callId: callId,
                output: #"{"status":"error","papers":[],"message":"Empty query."}"#
            )
            return
        }

        // MARK: - Plato — A real research question during the guided onboarding
        // tour advances (and finishes) it, so the demo flows straight into the
        // live search the user just triggered.
        if guidedOnboardingStep == .research {
            advanceOnboarding()
        }

        // Cap to a single in-flight research call for the MVP.
        guard pendingResearchCallIds.isEmpty else {
            openAIRealtimeClient.sendToolResultAndContinue(
                callId: callId,
                output: #"{"status":"error","papers":[],"message":"A search is already in progress. Ask again in a moment."}"#
            )
            return
        }

        pendingResearchCallIds.insert(callId)
        sessionState.recordPaperSearch()
        Task { @MainActor in
            let resultJSON = await fetchScholarPapers(query: query, limit: limit)
            pendingResearchCallIds.remove(callId)
            openAIRealtimeClient.sendToolResultAndContinue(callId: callId, output: resultJSON)
        }
    }

    // MARK: - Plato — control_pomodoro tool handler

    /// Handle a `control_pomodoro` function call: parse the action, drive the PomodoroTimer, and
    /// return the resulting timer state to the model via `sendToolResultAndContinue` so Plato
    /// speaks a brief confirmation. All actions are local/synchronous (no network await).
    private func handlePomodoroToolCall(argumentsJSON: String, callId: String) {
        var action = ""
        var minutes: Int?
        var topic: String?
        if let data = argumentsJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            action = (object["action"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            if let rawMinutes = object["minutes"] as? Int {
                minutes = rawMinutes
            } else if let rawMinutes = object["minutes"] as? Double {
                minutes = Int(rawMinutes)
            } else if let rawMinutes = object["minutes"] as? String, let parsed = Int(rawMinutes) {
                minutes = parsed
            }
            topic = (object["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let nonEmptyTopic = (topic?.isEmpty == false) ? topic : nil

        switch action {
        case "start":
            // Suppress the onWorkStart announcement; the continuation below speaks the confirmation.
            isVoiceInitiatedPomodoroStart = true
            let clampedMinutes = minutes.map { min(max($0, 1), 180) }
            pomodoro.start(minutes: clampedMinutes, topic: nonEmptyTopic)
            isVoiceInitiatedPomodoroStart = false  // safety: clear even if no new block began (resume)
        case "pause":
            pomodoro.pause()
        case "resume":
            pomodoro.resume()
            // MARK: - Plato — resume() only restarts the countdown ticker; it does NOT
            // re-fire onWorkStart, and the focus watch was invalidated when the pause
            // tick hit the phase/isRunning guard. Re-arm it so distraction nudges keep
            // working for the rest of the block. startFocusWatch() is idempotent
            // (it calls stopFocusWatch() first), and its own guard no-ops unless we're
            // genuinely in a running work block.
            if pomodoro.phase == .work, pomodoro.isRunning {
                startFocusWatch()
            }
        case "stop":
            pomodoro.stop()
        case "skip_break":
            pomodoro.skipBreak()
        case "set_topic":
            if let nonEmptyTopic {
                pomodoro.focusTopic = nonEmptyTopic
                // PomodoroTimer.focusTopic.didSet only propagates onFocusTopicChange during a work
                // block. The primary use (recording the answer to the block-start ask) happens in
                // .work, so that path is covered. If the user names a topic while idle, mirror it to
                // the live session here; beginWork() re-propagates at the next block start. During a
                // break we intentionally leave the topic cleared (not focusing during a break).
                if pomodoro.phase == .idle {
                    currentFocusTopic = nonEmptyTopic
                    sessionState.recordFocusTopic(nonEmptyTopic)
                }
            }
        case "status":
            break  // state is reported below
        default:
            openAIRealtimeClient.sendToolResultAndContinue(
                callId: callId,
                output: #"{"status":"error","message":"Unknown timer action."}"#
            )
            return
        }

        openAIRealtimeClient.sendToolResultAndContinue(callId: callId, output: pomodoroStateJSON())
    }

    /// Compact JSON snapshot of the focus timer for a tool result, so the model can confirm the
    /// action or answer "how much time is left?" accurately. Never throws.
    private func pomodoroStateJSON() -> String {
        let phaseLabel: String
        switch pomodoro.phase {
        case .idle: phaseLabel = "idle"
        case .work: phaseLabel = "focusing"
        case .breakTime: phaseLabel = "break"
        }
        let secondsRemaining = max(pomodoro.secondsRemaining, 0)
        let stateObject: [String: Any] = [
            "status": "ok",
            "phase": phaseLabel,
            "running": pomodoro.isRunning,
            "minutes_remaining": secondsRemaining / 60,
            "seconds_remaining": secondsRemaining,
            "current_block": pomodoro.currentSession,
            "total_blocks": pomodoro.sessionsTotal,
            "topic": pomodoro.focusTopic,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: stateObject),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return #"{"status":"ok"}"#
    }

    /// Fetch papers for the search_scholar tool. ALWAYS returns a JSON string suitable for
    /// `function_call_output` — never throws, never returns empty — so the model is never left
    /// hanging. Prefers the Worker `/papers` route when a worker session exists (deployed-worker
    /// path: hides an API key + rate-limits); otherwise queries Semantic Scholar directly from
    /// the app (the BYOK / no-server path — free tier, no key required).
    private func fetchScholarPapers(query: String, limit: Int) async -> String {
        if let workerResult = await fetchScholarPapersViaWorker(query: query, limit: limit) {
            return workerResult
        }
        return await fetchScholarPapersDirect(query: query, limit: limit)
    }

    /// Returns the Worker `/papers` contract JSON, or nil when there's no worker session or the
    /// call fails/404s (e.g. the default Skilly worker has no /papers route) — so the caller
    /// falls back to a direct Semantic Scholar query.
    private func fetchScholarPapersViaWorker(query: String, limit: Int) async -> String? {
        guard let url = URL(string: "\(AppSettings.shared.workerBaseURL)/papers") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard AuthManager.shared.applyWorkerSessionAuthorization(to: &request) else { return nil }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "limit": limit])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let body = String(data: data, encoding: .utf8), !body.isEmpty else {
            return nil
        }
        return body
    }

    /// Direct Semantic Scholar query from the app — no server, no key (free tier). Builds the
    /// same tool-output contract the Worker does, with strict per-paper provenance (explicit
    /// nulls) so the model cites only what's returned.
    // MARK: - Plato — Direct scholarly metadata sources (no server, BYOK path)

    private enum ScholarFetchOutcome {
        case papers([[String: Any]])   // usable results
        case empty                      // source responded but found nothing
        case unavailable                // network / rate-limit / auth / bad-response — try next source
    }

    /// Coalesce any optional to a JSON-serializable value: the value, or JSON null.
    private func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    private func encodeContract(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"status":"error","papers":[],"message":"Could not reach the research service."}"#
        }
        return string
    }

    private static let scholarDisclaimer =
        "These are the only papers returned. Cite only these, by exact title and first author. "
        + "Year and venue may be missing or approximate (especially for preprints) — give the year only if provided, "
        + "say so if it seems uncertain, and never invent a year, venue, or DOI."

    /// No-server paper search. Tries OpenAlex (best relevance), then Crossref (keyless DOI/metadata
    /// fallback). ALWAYS returns the tool-output contract; never throws.
    private func fetchScholarPapersDirect(query: String, limit: Int) async -> String {
        let openAlex = await fetchOpenAlexPapers(query: query, limit: limit)
        if case .papers(let papers) = openAlex {
            return encodeContract(["status": "ok", "papers": papers, "disclaimer": Self.scholarDisclaimer])
        }

        let crossref = await fetchCrossrefPapers(query: query, limit: limit)
        if case .papers(let papers) = crossref {
            return encodeContract(["status": "ok", "papers": papers, "disclaimer": Self.scholarDisclaimer])
        }

        if case .empty = openAlex {
            return encodeContract(["status": "no_results", "papers": [],
                                   "message": "No papers found for that query. Try rephrasing."])
        }
        if case .empty = crossref {
            return encodeContract(["status": "no_results", "papers": [],
                                   "message": "No papers found for that query. Try rephrasing."])
        }
        return encodeContract(["status": "rate_limited", "papers": [],
                               "message": "Could not reach the research service right now. Try again in a moment."])
    }

    /// Reconstructs OpenAlex's `abstract_inverted_index` ({word: [positions]}) into plain text,
    /// capped for TTS brevity. Returns nil when the index is missing.
    private func reconstructAbstract(_ raw: Any?) -> String? {
        guard let invertedIndex = raw as? [String: Any], !invertedIndex.isEmpty else { return nil }
        var positioned: [(Int, String)] = []
        for (word, value) in invertedIndex {
            let positions = (value as? [Int]) ?? (value as? [Any])?.compactMap { $0 as? Int } ?? []
            for position in positions { positioned.append((position, word)) }
        }
        let words = positioned.sorted { $0.0 < $1.0 }.map { $0.1 }
        guard !words.isEmpty else { return nil }
        return words.prefix(80).joined(separator: " ")
    }

    /// OpenAlex `/works` relevance search — the primary source. Keyless works for light use; a
    /// free `api_key` raises the daily budget. Handles a bad pasted key (401) by retrying keyless.
    private func fetchOpenAlexPapers(query: String, limit: Int) async -> ScholarFetchOutcome {
        func makeRequest(includeKey: Bool) -> URLRequest? {
            var components = URLComponents(string: "https://api.openalex.org/works")
            var items = [
                URLQueryItem(name: "search", value: query),
                URLQueryItem(name: "per_page", value: String(limit)),
                URLQueryItem(name: "select", value: "id,title,publication_year,doi,cited_by_count,authorships,primary_location,abstract_inverted_index,type"),
                URLQueryItem(name: "mailto", value: "plato@hyperspell.com"),
            ]
            let key = AppSettings.shared.openAlexAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if includeKey, !key.isEmpty {
                items.append(URLQueryItem(name: "api_key", value: key))
            }
            components?.queryItems = items
            guard let url = components?.url else { return nil }
            return URLRequest(url: url)
        }

        func run(_ request: URLRequest) async -> (Data, HTTPURLResponse)? {
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { return nil }
            return (data, http)
        }

        let hasKey = !AppSettings.shared.openAlexAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let request = makeRequest(includeKey: true) else { return .unavailable }

        var attempt = await run(request)
        // A malformed/expired pasted key returns 401 — drop it and retry keyless once.
        if hasKey, let (_, http) = attempt, http.statusCode == 401,
           let keylessRequest = makeRequest(includeKey: false) {
            attempt = await run(keylessRequest)
        }

        guard let (data, http) = attempt, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unavailable
        }

        let rawWorks = (json["results"] as? [[String: Any]]) ?? []
        if rawWorks.isEmpty { return .empty }

        let papers: [[String: Any]] = rawWorks.prefix(limit).map { work in
            let authors = ((work["authorships"] as? [[String: Any]]) ?? [])
                .compactMap { ($0["author"] as? [String: Any])?["display_name"] as? String }
                .prefix(6)
            let doiURL = work["doi"] as? String
            let bareDOI = doiURL?.replacingOccurrences(of: "https://doi.org/", with: "")
            let venue = ((work["primary_location"] as? [String: Any])?["source"] as? [String: Any])?["display_name"] as? String
            let abstract = reconstructAbstract(work["abstract_inverted_index"])
            return [
                "paperId": orNull(work["id"] as? String),
                "title": orNull(work["title"] as? String),
                "year": orNull(work["publication_year"] as? Int),
                "authors": Array(authors),
                "citationCount": orNull(work["cited_by_count"] as? Int),
                "url": orNull(work["id"] as? String),
                "venue": orNull(venue),
                "type": orNull(work["type"] as? String),
                "externalIds": [
                    "DOI": orNull(bareDOI),
                    "ArXiv": NSNull(),
                ] as [String: Any],
                "tldr": orNull(abstract),
            ]
        }
        return .papers(papers)
    }

    /// Crossref `/works` keyless fallback (polite pool via mailto). Used for DOI/metadata when
    /// OpenAlex is unavailable. Its relevance ranking is weaker, so it is a fallback, not primary.
    private func fetchCrossrefPapers(query: String, limit: Int) async -> ScholarFetchOutcome {
        var components = URLComponents(string: "https://api.crossref.org/works")
        components?.queryItems = [
            URLQueryItem(name: "query.bibliographic", value: query),
            URLQueryItem(name: "sort", value: "relevance"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "rows", value: String(limit)),
            URLQueryItem(name: "select", value: "DOI,title,author,published,container-title,is-referenced-by-count,abstract,type"),
            URLQueryItem(name: "mailto", value: "plato@hyperspell.com"),
        ]
        guard let url = components?.url else { return .unavailable }
        var request = URLRequest(url: url)
        request.setValue("Plato/1.0 (mailto:plato@hyperspell.com)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else {
            return .unavailable
        }

        let items = (message["items"] as? [[String: Any]]) ?? []
        if items.isEmpty { return .empty }

        func stripJATS(_ text: String?) -> String? {
            guard let text else { return nil }
            let stripped = text
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty ? nil : String(stripped.prefix(600))
        }

        let papers: [[String: Any]] = items.prefix(limit).map { item in
            let title = (item["title"] as? [String])?.first
            let venue = (item["container-title"] as? [String])?.first
            let doi = item["DOI"] as? String
            let authors = ((item["author"] as? [[String: Any]]) ?? []).compactMap { author -> String? in
                let name = [author["given"] as? String, author["family"] as? String]
                    .compactMap { $0 }
                    .joined(separator: " ")
                return name.isEmpty ? nil : name
            }.prefix(6)
            let dateParts = (item["published"] as? [String: Any])?["date-parts"] as? [[Any]]
            let year = dateParts?.first?.first as? Int
            return [
                "paperId": orNull(doi),
                "title": orNull(title),
                "year": orNull(year),
                "authors": Array(authors),
                "citationCount": orNull(item["is-referenced-by-count"] as? Int),
                "url": orNull(doi.map { "https://doi.org/\($0)" }),
                "venue": orNull(venue),
                "type": orNull(item["type"] as? String),
                "externalIds": [
                    "DOI": orNull(doi),
                    "ArXiv": NSNull(),
                ] as [String: Any],
                "tldr": orNull(stripJATS(item["abstract"] as? String)),
            ]
        }
        return .papers(papers)
    }

    /// If the cursor is in transient mode (user toggled "Show Skilly" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isSkillyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // MARK: - Skilly — Wait for realtime response playback to finish
            while openAIRealtimeClient.isModelSpeaking || voiceState == .responding {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    // MARK: - Realtime Response Bubble

    private func showRealtimeResponseBubble() {
        // Plato: a new response's audio is starting — drop any text a previous
        // response left displayed (e.g. an onboarding step's caption, which we
        // intentionally persist past its own audio) so this response never paints
        // with stale text. The first .audioTranscriptDelta repopulates it; if that
        // transcript is ever delayed, the bubble stays blank rather than showing
        // the wrong line under the new audio.
        realtimeResponseBubbleText = ""
        isShowingRealtimeResponseBubble = true
    }

    private func clearRealtimeResponseBubble() {
        isShowingRealtimeResponseBubble = false
        realtimeResponseBubbleText = ""
    }

    /// Keeps the transcript bubble clean while the model streams. This strips
    /// ALL complete [POINT:...] tags (the model emits them inline mid-sentence,
    /// not only at the end) and also hides a partially streamed trailing
    /// [POINT:... fragment so users never see protocol metadata.
    private func updateRealtimeResponseBubble(usingRawModelResponse rawModelResponseText: String) {
        let cleanedResponseBubbleText = PointDirectiveParser.stripPointTagArtifactsForStreamingBubble(
            from: rawModelResponseText
        )
        realtimeResponseBubbleText = cleanedResponseBubbleText
        isShowingRealtimeResponseBubble = !cleanedResponseBubbleText.isEmpty
    }

    // MARK: - Point Directive Parsing
    // ParsedPointDirective + parsing/stripping/screen-resolution live in
    // PointDirectiveParsing.swift so the malformed-model-output surface is
    // unit-testable (review findings D-09/D-10/D-11).

    private func applyPointDirectiveIfPresent(in fullModelResponseText: String) {
        guard let parsedPointDirective = PointDirectiveParser.parse(from: fullModelResponseText),
              let targetScreenCapture = PointDirectiveParser.resolveTargetScreenCapture(
                  for: parsedPointDirective, in: currentTurnScreenCaptures
              ),
              let screenLocation = mapScreenshotPixelCoordinateToGlobalScreenPoint(
                  screenshotXInPixels: parsedPointDirective.screenshotXInPixels,
                  screenshotYInPixels: parsedPointDirective.screenshotYInPixels,
                  screenCapture: targetScreenCapture
              ) else {
            return
        }

        detectedElementScreenLocation = screenLocation
        detectedElementDisplayFrame = targetScreenCapture.displayFrame
        detectedElementBubbleText = parsedPointDirective.elementLabel
        SkillyAnalytics.trackElementPointed(elementLabel: parsedPointDirective.elementLabel)
    }

    // MARK: - Plato — outcome of the synchronous phase of a point directive.
    // The AX label/hit-test resolution is synchronous, but when it can't confirm
    // the named control we hand off to an ASYNC OCR pass (mirroring highlight_text)
    // that owns closing the function call itself. This tells the dispatcher which
    // callId-lifecycle path to take.
    private enum PointDirectiveSyncOutcome {
        /// AX resolved the real control and a ring was drawn — report success.
        case resolvedSynchronously
        /// The directive was declined or malformed — NO ring was drawn. `reason`
        /// is sent to the model so it recovers verbally instead of claiming a
        /// highlight it never made.
        case declinedSynchronously(reason: String)
        /// AX could not confirm the control but the model gave an in-bounds guess;
        /// run the OCR fallback, which will close the callId when it finishes.
        case needsAsyncTextResolution(searchLabel: String, screenCapture: CompanionScreenCapture, modelPoint: CGPoint?)
    }

    // MARK: - Plato — honest failure phrasing handed to the model on a point miss,
    // so it describes the location in words instead of claiming a highlight.
    private func honestLocateFailureReason(for label: String) -> String {
        "could not visually locate '\(label)' on screen; do not claim you highlighted it — describe where it is in words instead"
    }

    // MARK: - Plato — Builds a `function_call_output` JSON string safely (the label
    // inside `reason` may contain quotes/backslashes — never string-interpolate it
    // into a raw JSON literal). Falls back to a bare ok flag if encoding ever fails.
    private func pointToolOutputJSON(ok: Bool, reason: String? = nil) -> String {
        var payload: [String: Any] = ["ok": ok]
        if let reason { payload["reason"] = reason }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return ok ? #"{"ok":true}"# : #"{"ok":false}"#
        }
        return json
    }

    // MARK: - Skilly — Tool-call pointing directive
    /// Applies a pointing directive that arrived as a structured function
    /// call from gpt-realtime, instead of as an inline [POINT:...] text tag.
    /// This is the preferred path — it keeps coordinates out of the audio
    /// and text streams entirely, so the TTS never voices them.
    private func applyPointDirectiveFromToolCall(argumentsJSON: String) -> PointDirectiveSyncOutcome {
        guard let argumentsData = argumentsJSON.data(using: .utf8),
              let parsedArguments = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] else {
            #if DEBUG
            print("⚠️ point_at_element: could not parse arguments JSON")
            #endif
            return .declinedSynchronously(reason: "could not read the pointing request")
        }

        // Accept integers or doubles for x/y.
        let screenshotXInPixels: Int
        let screenshotYInPixels: Int
        if let integerX = parsedArguments["x"] as? Int {
            screenshotXInPixels = integerX
        } else if let doubleX = parsedArguments["x"] as? Double {
            screenshotXInPixels = Int(doubleX)
        } else {
            return .declinedSynchronously(reason: "could not read the pointing request")
        }
        if let integerY = parsedArguments["y"] as? Int {
            screenshotYInPixels = integerY
        } else if let doubleY = parsedArguments["y"] as? Double {
            screenshotYInPixels = Int(doubleY)
        } else {
            return .declinedSynchronously(reason: "could not read the pointing request")
        }

        guard let elementLabel = (parsedArguments["label"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !elementLabel.isEmpty else {
            return .declinedSynchronously(reason: "could not read the pointing request")
        }

        // Optional 1-based screen index when the model is pointing on a
        // different display than the one the cursor is currently on.
        var oneBasedScreenNumber: Int?
        if let integerScreen = parsedArguments["screen"] as? Int {
            oneBasedScreenNumber = integerScreen
        } else if let doubleScreen = parsedArguments["screen"] as? Double {
            oneBasedScreenNumber = Int(doubleScreen)
        }

        let parsedPointDirective = ParsedPointDirective(
            screenshotXInPixels: screenshotXInPixels,
            screenshotYInPixels: screenshotYInPixels,
            elementLabel: elementLabel,
            oneBasedScreenNumber: oneBasedScreenNumber
        )
        guard let targetScreenCapture = PointDirectiveParser.resolveTargetScreenCapture(
            for: parsedPointDirective, in: currentTurnScreenCaptures
        ) else {
            return .declinedSynchronously(reason: "could not read the pointing request")
        }

        // Out-of-range (hallucinated) coordinates decline the directive entirely —
        // but the AX name search below can still rescue the point, because it
        // never needed the coordinates in the first place.
        let modelPoint = mapScreenshotPixelCoordinateToGlobalScreenPoint(
            screenshotXInPixels: parsedPointDirective.screenshotXInPixels,
            screenshotYInPixels: parsedPointDirective.screenshotYInPixels,
            screenCapture: targetScreenCapture
        )

        // MARK: - Plato — prefer the real control frame (by name) over guessed pixels
        if let controlFrame = resolveControlGlobalFrame(
            label: parsedPointDirective.elementLabel, approximatePoint: modelPoint
        ) {
            // Anchor the animation to the screen that actually CONTAINS the
            // resolved control — the AX match may sit on a different display
            // than the one the model designated (its screen guess can be wrong
            // in exactly the cases where its pixel guess was).
            let controlCenter = CGPoint(x: controlFrame.midX, y: controlFrame.midY)
            let hostingScreenFrame = NSScreen.screens
                .first(where: { $0.frame.contains(controlCenter) })?.frame
                ?? targetScreenCapture.displayFrame
            detectedElementScreenLocation = controlCenter
            detectedElementDisplayFrame = hostingScreenFrame
            detectedElementBubbleText = parsedPointDirective.elementLabel
            addHighlight(PlatoHighlight(
                kind: .strokedRegion(color: PlatoHighlight.color(forName: "blue"), lineWidth: 2.5),
                globalFrame: controlFrame, label: parsedPointDirective.elementLabel,
                createdAt: Date(), timeToLive: 4.0))
            SkillyAnalytics.trackElementPointed(elementLabel: parsedPointDirective.elementLabel)
            return .resolvedSynchronously
        }

        // AX could not resolve the control AND the coordinates were hallucinated:
        // decline (no pointing) rather than fly to a clamped screen edge. With no
        // in-bounds guess there is also nothing to anchor an OCR-miss hedge to.
        guard let modelPoint else {
            return .declinedSynchronously(
                reason: honestLocateFailureReason(for: parsedPointDirective.elementLabel))
        }

        // MARK: - Plato — AX missed but the guess is in-bounds. Defer to the OCR
        // fallback (non-AX surfaces: web/PDF/canvas). It rings the real text frame
        // on a hit and honestly hedges the cursor on a miss — no confident wrong
        // ring. The async task owns closing the callId.
        return .needsAsyncTextResolution(
            searchLabel: parsedPointDirective.elementLabel,
            screenCapture: targetScreenCapture,
            modelPoint: modelPoint
        )
    }

    // MARK: - Plato — OCR fallback for point_at_element (mirrors highlight_text).
    /// Runs only when the AX label/hit-test resolution could not confirm the named
    /// control. Matches the label text on a FRESH native-resolution capture of the
    /// target display; on a hit it rings the real text frame, on a miss it degrades
    /// to the honest hedged cursor-only path (no ring). Generation-stamped exactly
    /// like highlight_text so a slow OCR can never paint after the next turn starts.
    /// Closes `callId` itself.
    private func resolvePointDirectiveByOCR(searchLabel: String,
                                            screenCapture: CompanionScreenCapture,
                                            modelPoint: CGPoint?,
                                            callId: String) {
        let displayFrame = screenCapture.displayFrame
        let turnScreenshotJPEGData = screenCapture.imageData
        let generationAtRequest = highlightGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }

            // Fresh capture at tool-call time; falls back to the turn screenshot
            // if the capture fails (display unplugged mid-call, TCC hiccup).
            let freshDisplayImage = try? await CompanionScreenCaptureUtility.captureDisplayImageForOCR(
                displayFrame: displayFrame
            )

            // OCR is synchronous + CPU-bound — keep it off the main actor.
            let matchResult = await Task.detached(priority: .userInitiated) { () -> ScreenshotTextMatcher.MatchResult in
                let imageForOCR = freshDisplayImage ?? NSBitmapImageRep(data: turnScreenshotJPEGData)?.cgImage
                guard let imageForOCR else { return .notFound }
                let recognizedLines = (try? ScreenshotTextRecognizer.recognizeText(in: imageForOCR)) ?? []
                return ScreenshotTextMatcher.matchResult(for: searchLabel, in: recognizedLines)
            }.value

            guard generationAtRequest == self.highlightGeneration else {
                // The turn moved on (new turn, scroll, display change) while OCR
                // ran — pointing now would ring the wrong content.
                self.openAIRealtimeClient.sendFunctionCallOutput(
                    callId: callId,
                    output: #"{"ok":false,"reason":"the screen changed before pointing"}"#
                )
                return
            }

            if case .match(let normalizedBox) = matchResult {
                let globalFrame = HighlightGeometry.globalRectFromNormalizedVisionBox(
                    normalizedBox, displayFrame: displayFrame
                )
                let controlCenter = CGPoint(x: globalFrame.midX, y: globalFrame.midY)
                let hostingScreenFrame = NSScreen.screens
                    .first(where: { $0.frame.contains(controlCenter) })?.frame
                    ?? displayFrame
                self.detectedElementScreenLocation = controlCenter
                self.detectedElementDisplayFrame = hostingScreenFrame
                self.detectedElementBubbleText = searchLabel
                self.addHighlight(PlatoHighlight(
                    kind: .strokedRegion(color: PlatoHighlight.color(forName: "blue"), lineWidth: 2.5),
                    globalFrame: globalFrame, label: searchLabel,
                    createdAt: Date(), timeToLive: 4.0))
                SkillyAnalytics.trackElementPointed(elementLabel: searchLabel)
                self.openAIRealtimeClient.sendFunctionCallOutput(callId: callId, output: #"{"ok":true}"#)
                return
            }

            // OCR miss: honest degrade — move the cursor to the in-bounds guess
            // with a hedged bubble and NO ring, or decline entirely if no guess.
            if let modelPoint {
                self.detectedElementScreenLocation = modelPoint
                self.detectedElementDisplayFrame = displayFrame
                self.detectedElementBubbleText = "around here — \(searchLabel)"
                SkillyAnalytics.trackElementPointed(elementLabel: searchLabel)
            }
            self.openAIRealtimeClient.sendFunctionCallOutput(
                callId: callId,
                output: self.pointToolOutputJSON(ok: false, reason: self.honestLocateFailureReason(for: searchLabel))
            )
        }
    }

    // MARK: - Plato — resolve the REAL control frame, preferring an AX label match
    // over the model's guessed pixels. nil → caller falls back to model coordinates.
    private func resolveControlGlobalFrame(label: String, approximatePoint: CGPoint?) -> CGRect? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLabel.isEmpty,
           let frameByName = AXElementResolver.controlFrame(matchingLabel: trimmedLabel, near: approximatePoint) {
            return frameByName
        }
        // Secondary: the element directly under the model's guessed point (only
        // helps when the guess already landed on the right control).
        guard let approximatePoint else { return nil }
        return AXElementResolver.elementFrameAtAppKitPoint(approximatePoint, matchingLabel: trimmedLabel)
    }

    // MARK: - Plato — Tool argument decoding helpers (shared by highlight tools)
    private func decodeToolArguments(_ argumentsJSON: String) -> [String: Any]? {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Accepts Int or Double (the model sometimes emits 12.0 for an integer field).
    private func integerValue(from value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        return nil
    }

    // MARK: - Plato — highlight_region handler
    private func applyHighlightRegionDirective(argumentsJSON: String) {
        guard let arguments = decodeToolArguments(argumentsJSON),
              let x = integerValue(from: arguments["x"]),
              let y = integerValue(from: arguments["y"]),
              let width = integerValue(from: arguments["width"]),
              let height = integerValue(from: arguments["height"]) else {
            return
        }
        let colorName = arguments["color"] as? String
        let style = (arguments["style"] as? String) ?? "filled"
        let label = (arguments["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneBasedScreenNumber = integerValue(from: arguments["screen"])

        // Reuse the pointing resolver, which only reads oneBasedScreenNumber.
        let resolverDirective = ParsedPointDirective(
            screenshotXInPixels: x, screenshotYInPixels: y,
            elementLabel: label ?? "", oneBasedScreenNumber: oneBasedScreenNumber
        )
        guard let targetScreenCapture = PointDirectiveParser.resolveTargetScreenCapture(
            for: resolverDirective, in: currentTurnScreenCaptures
        ) else { return }

        let globalFrame = HighlightGeometry.globalRectFromScreenshotPixelRect(
            x: x, y: y, width: width, height: height,
            screenshotWidthInPixels: targetScreenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: targetScreenCapture.screenshotHeightInPixels,
            displayFrame: targetScreenCapture.displayFrame
        )

        // MARK: - Plato — snap a single control to its real AX frame (by name, then point)
        if (arguments["snap_to_control"] as? Bool) ?? false {
            // nil when the box center is hallucinated — the AX name search
            // still runs; only the point-based hit-test fallback is skipped.
            let centerPoint = mapScreenshotPixelCoordinateToGlobalScreenPoint(
                screenshotXInPixels: x + (width / 2),
                screenshotYInPixels: y + (height / 2),
                screenCapture: targetScreenCapture
            )
            if let axFrame = resolveControlGlobalFrame(label: label ?? "", approximatePoint: centerPoint) {
                addHighlight(PlatoHighlight(
                    kind: .strokedRegion(color: PlatoHighlight.color(forName: colorName), lineWidth: 2.5),
                    globalFrame: axFrame, label: label, createdAt: Date(), timeToLive: 4.0))
                return
            }
            // AX couldn't resolve (canvas/GPU app, no element) — fall through to the model bbox.
        }

        let highlightColor = PlatoHighlight.color(forName: colorName)
        let kind: PlatoHighlight.Kind = (style == "outline")
            ? .strokedRegion(color: highlightColor, lineWidth: 2.5)
            : .filledRegion(color: highlightColor)

        addHighlight(PlatoHighlight(kind: kind, globalFrame: globalFrame,
                                    label: label, createdAt: Date(), timeToLive: 4.0))
    }

    // MARK: - Plato — ripple_here handler
    private func applyRippleDirective(argumentsJSON: String) {
        guard let arguments = decodeToolArguments(argumentsJSON),
              let x = integerValue(from: arguments["x"]),
              let y = integerValue(from: arguments["y"]) else {
            return
        }
        let label = (arguments["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneBasedScreenNumber = integerValue(from: arguments["screen"])

        let resolverDirective = ParsedPointDirective(
            screenshotXInPixels: x, screenshotYInPixels: y,
            elementLabel: label ?? "", oneBasedScreenNumber: oneBasedScreenNumber
        )
        guard let targetScreenCapture = PointDirectiveParser.resolveTargetScreenCapture(
            for: resolverDirective, in: currentTurnScreenCaptures
        ) else { return }

        // Hallucinated coordinates decline the ripple (never pulse at a clamped edge).
        guard let globalPoint = mapScreenshotPixelCoordinateToGlobalScreenPoint(
            screenshotXInPixels: x, screenshotYInPixels: y, screenCapture: targetScreenCapture
        ) else { return }
        // Zero-size rect: the ripple view centers on its midpoint.
        let globalFrame = CGRect(x: globalPoint.x, y: globalPoint.y, width: 0, height: 0)
        addHighlight(PlatoHighlight(kind: .ripplePulse(color: PlatoHighlight.color(forName: "blue")),
                                    globalFrame: globalFrame, label: label,
                                    createdAt: Date(), timeToLive: 4.0))
    }

    // MARK: - Plato — highlight_text handler (async OCR)
    /// Resolves the model's named text to an exact on-screen rect and closes the
    /// function call with the REAL outcome once OCR finishes (never a premature
    /// {"ok":true} — the model must not claim it highlighted something that
    /// never rendered). OCR runs on a FRESH native-resolution capture of the
    /// target display: the per-turn 1280px JPEG is seconds stale (the user may
    /// have scrolled while speaking) and too small for paper body text.
    private func applyHighlightTextDirective(argumentsJSON: String, callId: String) {
        guard let arguments = decodeToolArguments(argumentsJSON),
              let searchText = (arguments["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !searchText.isEmpty else {
            openAIRealtimeClient.sendFunctionCallOutput(
                callId: callId,
                output: #"{"ok":false,"reason":"missing or empty text argument"}"#
            )
            return
        }
        let colorName = (arguments["color"] as? String) ?? "yellow"
        let label = (arguments["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneBasedScreenNumber = integerValue(from: arguments["screen"])

        let resolverDirective = ParsedPointDirective(
            screenshotXInPixels: 0, screenshotYInPixels: 0,
            elementLabel: label ?? searchText, oneBasedScreenNumber: oneBasedScreenNumber
        )
        guard let targetScreenCapture = PointDirectiveParser.resolveTargetScreenCapture(
            for: resolverDirective, in: currentTurnScreenCaptures
        ) else {
            openAIRealtimeClient.sendFunctionCallOutput(
                callId: callId,
                output: #"{"ok":false,"reason":"no screenshot exists for that screen"}"#
            )
            return
        }

        // Snapshot the value-type bits the detached OCR work needs.
        let turnScreenshotJPEGData = targetScreenCapture.imageData
        let displayFrame = targetScreenCapture.displayFrame
        // Stamp the request with the current turn's generation so a slow OCR
        // can never paint a stale box after the next turn started.
        let generationAtRequest = highlightGeneration

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Fresh capture at tool-call time; falls back to the turn screenshot
            // if the capture fails (display unplugged mid-call, TCC hiccup).
            let freshDisplayImage = try? await CompanionScreenCaptureUtility.captureDisplayImageForOCR(
                displayFrame: displayFrame
            )

            // The OCR itself is synchronous + CPU-bound — keep it off the main actor.
            let matchResult = await Task.detached(priority: .userInitiated) { () -> ScreenshotTextMatcher.MatchResult in
                let imageForOCR = freshDisplayImage ?? NSBitmapImageRep(data: turnScreenshotJPEGData)?.cgImage
                guard let imageForOCR else { return .notFound }
                let recognizedLines = (try? ScreenshotTextRecognizer.recognizeText(in: imageForOCR)) ?? []
                return ScreenshotTextMatcher.matchResult(for: searchText, in: recognizedLines)
            }.value

            switch matchResult {
            case .match(let normalizedBox):
                guard generationAtRequest == self.highlightGeneration else {
                    // The turn moved on (new turn, scroll, display change) while
                    // OCR ran — drawing now would shade the wrong content.
                    self.openAIRealtimeClient.sendFunctionCallOutput(
                        callId: callId,
                        output: #"{"ok":false,"reason":"the screen changed before the highlight could render"}"#
                    )
                    return
                }
                let globalFrame = HighlightGeometry.globalRectFromNormalizedVisionBox(
                    normalizedBox, displayFrame: displayFrame
                )
                self.addHighlight(PlatoHighlight(
                    kind: .filledRegion(color: PlatoHighlight.color(forName: colorName)),
                    globalFrame: globalFrame, label: label,
                    createdAt: Date(), timeToLive: 5.0
                ))
                self.openAIRealtimeClient.sendFunctionCallOutput(callId: callId, output: #"{"ok":true}"#)
            case .ambiguous(let matchCount):
                // Continue (not just close) so the model verbally recovers
                // instead of having silently claimed a highlight it never drew.
                self.openAIRealtimeClient.sendToolResultAndContinue(
                    callId: callId,
                    output: #"{"ok":false,"reason":"that text appears in \#(matchCount) places on screen — tell the user, and retry with a longer, unique phrase"}"#
                )
            case .notFound:
                self.openAIRealtimeClient.sendToolResultAndContinue(
                    callId: callId,
                    output: #"{"ok":false,"reason":"that text was not found on screen — it may be scrolled out of view; tell the user where to scroll instead"}"#
                )
            }
        }
    }

    // MARK: - Plato — show_scroll_affordance handler
    /// Directional "scroll this way" arrow near the relevant screen edge, for
    /// targets that are scrolled out of view (the prompt names this tool).
    private func applyScrollAffordanceDirective(argumentsJSON: String) {
        guard let arguments = decodeToolArguments(argumentsJSON),
              let directionName = (arguments["direction"] as? String)?.lowercased() else {
            return
        }
        let direction: PlatoHighlight.ArrowDirection
        switch directionName {
        case "up": direction = .up
        case "left": direction = .left
        case "right": direction = .right
        default: direction = .down
        }
        let label = (arguments["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneBasedScreenNumber = integerValue(from: arguments["screen"])
        let resolverDirective = ParsedPointDirective(
            screenshotXInPixels: 0, screenshotYInPixels: 0,
            elementLabel: label ?? "", oneBasedScreenNumber: oneBasedScreenNumber
        )
        guard let targetScreenCapture = PointDirectiveParser.resolveTargetScreenCapture(
            for: resolverDirective, in: currentTurnScreenCaptures
        ) else { return }

        // Place the arrow near the relevant edge of the target display.
        let frame = targetScreenCapture.displayFrame
        let arrowCenter: CGPoint
        switch direction {
        case .down:  arrowCenter = CGPoint(x: frame.midX, y: frame.minY + 80)
        case .up:    arrowCenter = CGPoint(x: frame.midX, y: frame.maxY - 80)
        case .left:  arrowCenter = CGPoint(x: frame.minX + 80, y: frame.midY)
        case .right: arrowCenter = CGPoint(x: frame.maxX - 80, y: frame.midY)
        }
        let globalFrame = CGRect(x: arrowCenter.x, y: arrowCenter.y, width: 0, height: 0)
        addHighlight(PlatoHighlight(
            kind: .directionalArrow(direction: direction, color: PlatoHighlight.color(forName: "blue")),
            globalFrame: globalFrame, label: label, createdAt: Date(), timeToLive: 4.0
        ))
    }

    // MARK: - Plato — spotlight_region handler
    /// Dims everything except one region. Sparing, single-focus emphasis.
    private func applySpotlightDirective(argumentsJSON: String) {
        guard let arguments = decodeToolArguments(argumentsJSON),
              let x = integerValue(from: arguments["x"]),
              let y = integerValue(from: arguments["y"]),
              let width = integerValue(from: arguments["width"]),
              let height = integerValue(from: arguments["height"]) else {
            return
        }
        let oneBasedScreenNumber = integerValue(from: arguments["screen"])
        let resolverDirective = ParsedPointDirective(
            screenshotXInPixels: x, screenshotYInPixels: y,
            elementLabel: "", oneBasedScreenNumber: oneBasedScreenNumber
        )
        guard let targetScreenCapture = PointDirectiveParser.resolveTargetScreenCapture(
            for: resolverDirective, in: currentTurnScreenCaptures
        ) else { return }
        let globalFrame = HighlightGeometry.globalRectFromScreenshotPixelRect(
            x: x, y: y, width: width, height: height,
            screenshotWidthInPixels: targetScreenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: targetScreenCapture.screenshotHeightInPixels,
            displayFrame: targetScreenCapture.displayFrame
        )
        // Only one spotlight at a time — clear others first so dim layers don't stack.
        clearAllHighlights()
        addHighlight(PlatoHighlight(kind: .spotlight(dimOpacity: 0.45), globalFrame: globalFrame,
                                    label: nil, createdAt: Date(), timeToLive: 4.0))
    }

    /// Delegates to the single source of truth in HighlightGeometry (the math
    /// used to be duplicated here). nil means the coordinates fell outside the
    /// screenshot beyond tolerance — the directive should be declined, not
    /// clamped to a screen edge and pointed at confidently.
    private func mapScreenshotPixelCoordinateToGlobalScreenPoint(
        screenshotXInPixels: Int,
        screenshotYInPixels: Int,
        screenCapture: CompanionScreenCapture
    ) -> CGPoint? {
        HighlightGeometry.globalPointFromScreenshotPixel(
            x: screenshotXInPixels,
            y: screenshotYInPixels,
            screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: screenCapture.screenshotHeightInPixels,
            displayFrame: screenCapture.displayFrame
        )
    }

    // MARK: - Skilly — Rust realtime transition tracking

    private func beginRustRealtimeTurnTracking(turnPrefix: String) {
        rustRealtimeEventLog = []
        let newTurnID = "\(turnPrefix)-\(UUID().uuidString)"
        currentRustRealtimeTurnID = newTurnID
        appendRustRealtimeEvent(
            type: .turnStarted,
            turnID: newTurnID
        )
    }

    private func resetRustRealtimeTracking() {
        if !rustRealtimeEventLog.isEmpty {
            appendRustRealtimeEvent(type: .sessionReset, turnID: nil, message: nil)
        }
        rustRealtimeEventLog = []
        currentRustRealtimeTurnID = nil
        latestRustRealtimePhaseName = "idle"
    }

    private func appendRustRealtimeEvent(
        type: RustRealtimeBridge.RealtimeEventType,
        turnID: String? = nil,
        message: String? = nil
    ) {
        let resolvedTurnID = turnID ?? currentRustRealtimeTurnID
        if type != .sessionReset && resolvedTurnID == nil {
            return
        }

        let realtimeEventPayload = RustRealtimeBridge.shared.makeEvent(
            type: type,
            turnID: resolvedTurnID,
            message: message
        )
        rustRealtimeEventLog.append(realtimeEventPayload)

        guard let replaySummary = RustRealtimeBridge.shared.replaySummary(events: rustRealtimeEventLog) else {
            return
        }
        latestRustRealtimePhaseName = replaySummary.phaseName
        applyVoiceStateFromRustPhaseNameIfNeeded(replaySummary.phaseName)
    }

    private func applyVoiceStateFromRustPhaseNameIfNeeded(_ phaseName: String) {
        switch phaseName {
        case "capturing":
            if voiceState != .listening {
                voiceState = .listening
            }
        case "awaiting_response":
            if voiceState != .processing {
                voiceState = .processing
            }
        case "speaking":
            if voiceState != .responding {
                voiceState = .responding
            }
        default:
            break
        }
    }

    // MARK: - Skilly — OpenAI Realtime Push-to-Talk Pipeline

    private func startOpenAIRealtimePushToTalk() {
        realtimePushToTalkTask?.cancel()
        // MARK: - Skilly — Reset response transcript buffer for each new turn
        realtimeResponseText = ""
        currentTurnUserTranscript = nil
        currentTurnScreenCaptures = []
        hasEndedAssistantSpeechForCurrentTurn = false
        didReceivePointToolCallForCurrentTurn = false
        didReceiveAnyAudioChunkForCurrentTurn = false
        pendingToolCallIdForCurrentTurn = nil
        isAwaitingForcedSpokenFollowUp = false
        isWaitingForRealtimeAudioQueueDrain = false
        // MARK: - Plato — drop last turn's highlights before a new turn
        clearAllHighlights()
        // MARK: - Skilly — Record turn start for usage tracking (key press → response.done)
        currentTurnStartTime = Date()
        beginRustRealtimeTurnTracking(turnPrefix: "ptt")
        clearRealtimeResponseBubble()

        realtimePushToTalkTask = Task {
            let pipelineStartTime = CFAbsoluteTimeGetCurrent()
            voiceState = .listening

            do {
                try await ensureRealtimeSessionReadyForTurn()
                RealtimeTelemetry.shared.beginTurn()

                guard !Task.isCancelled else { return }

                // Clear any stale audio from previous interaction
                openAIRealtimeClient.clearAudioBuffer()
                realtimeAudioChunksSent = 0

                // Capture and send all screens immediately so the model can reason
                // across multi-monitor setups and map [POINT] tags correctly.
                let allScreenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                currentTurnScreenCaptures = allScreenCaptures
                RealtimeTelemetry.shared.recordVisionUsed()
                for (screenIndex, screenCapture) in allScreenCaptures.enumerated() {
                    // MARK: - Plato — give the model a SINGLE coordinate space (the
                    // image's own pixel grid). Previously we also advertised the
                    // display's point size, and a model that answered in points
                    // produced coordinates scaled by displayPoints/screenshotPixels
                    // (a systematic down-right offset that grew with display size).
                    let screenshotDescription = """
                    \(screenCapture.label). \
                    coordinate space: this image is \(screenCapture.screenshotWidthInPixels) pixels wide by \(screenCapture.screenshotHeightInPixels) pixels tall; give x,y in THIS pixel grid, top-left origin. \
                    screen number: \(screenIndex + 1).
                    """
                    openAIRealtimeClient.sendScreenshot(
                        screenCapture.imageData,
                        withText: screenshotDescription
                    )

                    // MARK: - Skilly — Debug logging (stripped in release)
                    #if DEBUG
                    let sendLatencyMilliseconds = Int((CFAbsoluteTimeGetCurrent() - pipelineStartTime) * 1000)
                    print("⏱️ OpenAI Realtime: screen \(screenIndex + 1)/\(allScreenCaptures.count) sent (\(screenCapture.imageData.count / 1024)KB) at \(sendLatencyMilliseconds)ms")
                    #endif
                }

                RealtimeTelemetry.shared.beginUserSpeech()

                // Start audio capture and stream to OpenAI
                let audioEngine = AVAudioEngine()
                self.realtimeAudioEngine = audioEngine

                let inputNode = audioEngine.inputNode
                let inputFormat = inputNode.outputFormat(forBus: 0)

                inputNode.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
                    guard let pcm16Data = self?.convertBufferToPCM16(buffer) else { return }
                    self?.openAIRealtimeClient.appendAudioChunk(pcm16Data)
                    self?.realtimeAudioChunksSent += 1
                    self?.updateRealtimeAudioPowerLevel(from: buffer)
                }

                audioEngine.prepare()
                try audioEngine.start()

                // MARK: - Skilly — Debug logging (stripped in release)
                #if DEBUG
                print("⏱️ OpenAI Realtime: audio streaming started at \(Int((CFAbsoluteTimeGetCurrent() - pipelineStartTime) * 1000))ms")
                #endif

            } catch {
                // MARK: - Skilly — Debug logging (stripped in release)
                #if DEBUG
                print("⚠️ OpenAI Realtime: failed to start: \(error)")
                #endif
                appendRustRealtimeEvent(
                    type: .sessionError,
                    message: error.localizedDescription
                )
                voiceState = .idle
                clearRealtimeResponseBubble()
                resetRustRealtimeTracking()

                // MARK: - Skilly — Auth recovery: if the Worker rejected
                // /openai/token because our Keychain session token is stale,
                // sign the user out and surface the panel so they re-auth
                // instead of silently failing on every push-to-talk press.
                if case OpenAIRealtimeClient.OpenAIRealtimeError.authExpired = error {
                    AuthManager.shared.signOut()
                    NotificationCenter.default.post(name: .skillyAuthExpired, object: nil)
                }
            }
        }
    }

    /// Tracks whether we've actually sent any audio chunks this press.
    private var realtimeAudioChunksSent = 0

    private func stopOpenAIRealtimePushToTalk() {
        // Stop audio capture
        realtimeAudioEngine?.stop()
        realtimeAudioEngine?.inputNode.removeTap(onBus: 0)
        realtimeAudioEngine = nil
        realtimePushToTalkTask = nil

        // Only commit if we've actually sent audio
        if realtimeAudioChunksSent >= minimumAudioChunksRequiredToCommit {
            RealtimeTelemetry.shared.endUserSpeech()
            appendRustRealtimeEvent(type: .audioCaptureCommitted)
            openAIRealtimeClient.commitAudioAndRespond()
            voiceState = .processing
            // MARK: - Skilly — Debug logging (stripped in release)
            #if DEBUG
            print("🎙️ OpenAI Realtime: committed \(realtimeAudioChunksSent) audio chunks")
            #endif
        } else {
            // MARK: - Skilly — Debug logging (stripped in release)
            #if DEBUG
            print("⚠️ OpenAI Realtime: not enough audio captured (\(realtimeAudioChunksSent) chunks), skipping commit")
            #endif
            isWaitingForRealtimeAudioQueueDrain = false
            voiceState = .idle
            clearRealtimeResponseBubble()
            resetRustRealtimeTracking()
        }
        realtimeAudioChunksSent = 0
    }

    // MARK: - Skilly — Live Tutor Mode Pipeline

    private func startLiveTutorMode() {
        guard !isLiveTutorModeActive else { return }
        isLiveTutorModeActive = true

        #if DEBUG
        print("🎓 Live Tutor: starting")
        #endif

        Task {
            do {
                try await ensureRealtimeSessionReadyForTurn()
                try await openAIRealtimeClient.updateTurnDetection(enabled: true)
            } catch {
                #if DEBUG
                print("⚠️ Live Tutor: failed to start session: \(error)")
                #endif
                isLiveTutorModeActive = false
                return
            }

            let audioEngine = AVAudioEngine()
            self.liveTutorAudioEngine = audioEngine

            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
                guard let self, self.isLiveTutorModeActive else { return }
                // Mute the mic feed while the model is speaking to prevent
                // the TTS audio from being picked up by the mic and echoing
                // back as a false "speech detected" event from the server VAD.
                // This disables barge-in but avoids the feedback loop that
                // causes empty transcriptions and cancellation storms.
                guard self.voiceState != .responding else { return }
                guard let pcm16Data = self.convertBufferToPCM16(buffer) else { return }
                self.openAIRealtimeClient.appendAudioChunk(pcm16Data)
            }

            audioEngine.prepare()
            try? audioEngine.start()

            #if DEBUG
            print("🎓 Live Tutor: mic streaming started")
            #endif

            resetLiveTutorAutoSleepTimer()
        }
    }

    private func stopLiveTutorMode() {
        guard isLiveTutorModeActive else { return }
        isLiveTutorModeActive = false

        #if DEBUG
        print("🎓 Live Tutor: stopping")
        #endif

        liveTutorAutoSleepTask?.cancel()
        liveTutorAutoSleepTask = nil

        liveTutorAudioEngine?.stop()
        liveTutorAudioEngine?.inputNode.removeTap(onBus: 0)
        liveTutorAudioEngine = nil

        Task {
            try? await openAIRealtimeClient.updateTurnDetection(enabled: false)
        }

        voiceState = .idle
        clearRealtimeResponseBubble()
        resetRustRealtimeTracking()
    }

    private func resetLiveTutorAutoSleepTimer() {
        liveTutorAutoSleepTask?.cancel()
        let autoSleepMinutes = AppSettings.shared.liveTutorAutoSleepMinutes
        guard autoSleepMinutes > 0 else { return }

        liveTutorAutoSleepTask = Task {
            try? await Task.sleep(for: .seconds(autoSleepMinutes * 60))
            guard !Task.isCancelled, isLiveTutorModeActive else { return }
            #if DEBUG
            print("🎓 Live Tutor: auto-sleeping after \(autoSleepMinutes) minutes of silence")
            #endif
            stopLiveTutorMode()
            AppSettings.shared.voiceInputMode = "pushToTalk"
        }
    }

    private func handleRealtimeEvent(_ event: OpenAIRealtimeEvent) {
        switch event {
        case .sessionCreated:
            break

        case .audioChunk(let pcm16Data):
            if voiceState != .responding {
                appendRustRealtimeEvent(type: .audioPlaybackStarted)
                voiceState = .responding
                isWaitingForRealtimeAudioQueueDrain = false
                showRealtimeResponseBubble()
                RealtimeTelemetry.shared.beginAssistantSpeech()
                // MARK: - Skilly — Debug logging (stripped in release)
                #if DEBUG
                print("🔊 OpenAI Realtime: voiceState → responding")
                #endif
            }
            // MARK: - Skilly — Track whether this turn produced any spoken
            // audio. If a response completes with a tool call but no audio,
            // we force a spoken follow-up in .responseDone below.
            didReceiveAnyAudioChunkForCurrentTurn = true
            realtimeAudioPlayer?.enqueueAudio(pcm16Data)

        case .audioTranscriptDelta(let text):
            // MARK: - Skilly — Stream AI response text to cursor overlay
            realtimeResponseText += text
            // The [POINT:...] tag is silent-metadata per the system prompt
            // (gpt-realtime does not generate speech tokens for text it is
            // told to treat as silent directives). We used to drop audio
            // chunks whenever "[point:" appeared in the text stream, but that
            // cut off real speech whenever the model emitted the tag inline
            // instead of strictly at the end. The tag is stripped from the
            // visible bubble by updateRealtimeResponseBubble and from the
            // curriculum transcript in .responseDone below.
            updateRealtimeResponseBubble(usingRawModelResponse: realtimeResponseText)

        case .inputTranscriptDone(let transcript):
            // What the user said (STT result)
            lastTranscript = transcript
            currentTurnUserTranscript = transcript
            SkillyAnalytics.trackUserMessageSent(transcript: transcript)

        case .responseDone(let usage):
            // MARK: - Skilly — Runtime recovery for tool-call-only responses
            // gpt-realtime sometimes emits a function_call item with no
            // message item, which means no audio is generated and the user
            // hears silence. When we detect that, close the tool call with
            // a trivial function_call_output and immediately request a
            // forced spoken follow-up (tool_choice: "none"). The follow-up
            // will arrive as a NEW .responseDone event; this second pass
            // takes the normal completion path below.
            let shouldForceSpokenFollowUp = didReceivePointToolCallForCurrentTurn
                && !didReceiveAnyAudioChunkForCurrentTurn
                && !isAwaitingForcedSpokenFollowUp
            if shouldForceSpokenFollowUp {
                #if DEBUG
                print("🗣️ OpenAI Realtime: tool-only response detected, forcing spoken follow-up")
                #endif
                if let pendingToolCallId = pendingToolCallIdForCurrentTurn {
                    openAIRealtimeClient.sendFunctionCallOutput(
                        callId: pendingToolCallId,
                        output: #"{"ok":true}"#
                    )
                }
                isAwaitingForcedSpokenFollowUp = true
                // We intentionally do NOT reset didReceivePointToolCallForCurrentTurn
                // here — the point was already applied and we don't want the
                // second response to point again. We DO need to allow new audio
                // to arrive for the follow-up, which is already allowed because
                // didReceiveAnyAudioChunkForCurrentTurn simply gets set when
                // the first forced-speech chunk arrives.
                openAIRealtimeClient.requestForcedSpokenResponse(
                    instruction: "Now provide your normal spoken explanation for the user's last question. Speak naturally and conversationally, as if you were answering them out loud. Do not call any tools. Do not mention that you are pointing, do not say coordinates, and do not refer to the tool you just invoked. Just give the explanation."
                )
                return
            }

            appendRustRealtimeEvent(type: .responseCompleted)
            RealtimeTelemetry.shared.endTurn(usage: usage)
            if !hasEndedAssistantSpeechForCurrentTurn {
                RealtimeTelemetry.shared.endAssistantSpeech()
                hasEndedAssistantSpeechForCurrentTurn = true
            }
            // MARK: - Skilly — Record per-turn usage for trial/cap tracking
            if let turnStart = currentTurnStartTime {
                let turnDurationSeconds = Date().timeIntervalSince(turnStart)
                recordSessionSecondsIfNeeded(turnDurationSeconds)
                // Fire the first-turn milestone on the very first trial turn
                TrialTracker.shared.recordFirstTurn()
                // Check for 80% warning thresholds after each recording
                SkillyNotificationManager.shared.checkAndSendTrial80PercentWarning()
                SkillyNotificationManager.shared.checkAndSendUsage80PercentWarning()
            }
            currentTurnStartTime = nil
            isAwaitingForcedSpokenFollowUp = false
            // Fallback: only parse inline [POINT:...] text tags if the model
            // did NOT already call the point_at_element tool for this turn.
            // New turns should always use the tool; legacy inline tags are
            // kept as a safety net in case the model ignores the tool.
            if !didReceivePointToolCallForCurrentTurn {
                applyPointDirectiveIfPresent(in: realtimeResponseText)
            }
            if let currentTurnUserTranscript {
                // Strip ALL inline [POINT] tags (not just a trailing one) so raw
                // protocol metadata never lands in the curriculum/session transcripts.
                let trimmedAssistantResponse = PointDirectiveParser.stripCompletedPointTags(
                    from: realtimeResponseText
                )
                skillManager?.didReceiveInteraction(
                    transcript: currentTurnUserTranscript,
                    assistantResponse: trimmedAssistantResponse
                )
                // Plato: keep a trimmed transcript for the session recap / re-entry briefing.
                sessionState.recordTurn(
                    userTranscript: currentTurnUserTranscript,
                    assistantResponse: trimmedAssistantResponse
                )
            }
            self.currentTurnUserTranscript = nil
            // Wait for audio queue drain instead of a fixed timer so the
            // transcript remains visible for the full spoken response.
            isWaitingForRealtimeAudioQueueDrain = true
            if realtimeAudioPlayer?.hasPendingAudio != true {
                handleRealtimeAudioQueueDrained()
            }

        case .functionCallDone(let name, let argumentsJSON, let callId):
            // MARK: - Skilly — Tool call handler
            // gpt-realtime invokes point_at_element as a structured function
            // call that arrives alongside (but separately from) the spoken
            // message. We route it straight to the pointing animation without
            // touching the audio/text stream. We also save the call_id so
            // we can close the call with function_call_output in .responseDone.
            // MARK: - Plato — General tool dispatch.
            // point_at_element's synchronous path now closes its callId inline with
            // {"ok":true} (like highlight_region), so a turn with several point calls
            // never orphans function_calls; its async OCR fallback self-owns its close.
            // search_scholar routes to an async network handler. Unknown tools are
            // closed immediately so no function_call is orphaned.
            switch name {
            case "point_at_element":
                // MARK: - Plato — the AX phase is synchronous, but an AX miss
                // hands off to an async OCR fallback that closes the callId itself
                // (mirrors highlight_text): set didReceivePointToolCallForCurrentTurn
                // but NOT pendingToolCallIdForCurrentTurn, so the .responseDone
                // recovery branch does not also try to close a callId the async task owns.
                switch applyPointDirectiveFromToolCall(argumentsJSON: argumentsJSON) {
                case .resolvedSynchronously:
                    // MARK: - Plato — close each synchronously-resolved point call
                    // inline (like highlight_region) so a turn with several
                    // point_at_element calls doesn't orphan function_calls. The async
                    // OCR path (.needsAsyncTextResolution) still self-owns its close.
                    didReceivePointToolCallForCurrentTurn = true
                    openAIRealtimeClient.sendFunctionCallOutput(
                        callId: callId, output: pointToolOutputJSON(ok: true))
                case .declinedSynchronously(let reason):
                    // No ring drawn — tell the model the truth so it recovers
                    // verbally. Still mark the tool as fired so the forced spoken
                    // follow-up net runs and no function_call is orphaned.
                    didReceivePointToolCallForCurrentTurn = true
                    openAIRealtimeClient.sendFunctionCallOutput(
                        callId: callId, output: pointToolOutputJSON(ok: false, reason: reason))
                case .needsAsyncTextResolution(let searchLabel, let screenCapture, let modelPoint):
                    didReceivePointToolCallForCurrentTurn = true
                    resolvePointDirectiveByOCR(
                        searchLabel: searchLabel, screenCapture: screenCapture,
                        modelPoint: modelPoint, callId: callId
                    )
                }
            case "search_scholar":
                handleScholarToolCall(argumentsJSON: argumentsJSON, callId: callId)
            case "control_pomodoro":
                handlePomodoroToolCall(argumentsJSON: argumentsJSON, callId: callId)
            case "highlight_region":
                applyHighlightRegionDirective(argumentsJSON: argumentsJSON)
                // Reuse the point_at_element follow-up safety net: marks that a
                // visual tool fired (so the inline-tag fallback is skipped and a
                // tool-only response still triggers a forced spoken follow-up),
                // and closes THIS call now without eliciting a new response.
                didReceivePointToolCallForCurrentTurn = true
                openAIRealtimeClient.sendFunctionCallOutput(callId: callId, output: #"{"ok":true}"#)
            case "ripple_here":
                applyRippleDirective(argumentsJSON: argumentsJSON)
                didReceivePointToolCallForCurrentTurn = true
                openAIRealtimeClient.sendFunctionCallOutput(callId: callId, output: #"{"ok":true}"#)
            case "highlight_text":
                // Async close: the handler resolves OCR first and reports the REAL
                // outcome ({"ok":false,...} on a miss so the model verbally
                // recovers) — never a premature {"ok":true} for a highlight that
                // may never render.
                applyHighlightTextDirective(argumentsJSON: argumentsJSON, callId: callId)
                didReceivePointToolCallForCurrentTurn = true
            case "show_scroll_affordance":
                applyScrollAffordanceDirective(argumentsJSON: argumentsJSON)
                didReceivePointToolCallForCurrentTurn = true
                openAIRealtimeClient.sendFunctionCallOutput(callId: callId, output: #"{"ok":true}"#)
            case "spotlight_region":
                applySpotlightDirective(argumentsJSON: argumentsJSON)
                didReceivePointToolCallForCurrentTurn = true
                openAIRealtimeClient.sendFunctionCallOutput(callId: callId, output: #"{"ok":true}"#)
            default:
                #if DEBUG
                print("[CompanionManager] Unknown tool call '\(name)' — closing with error output")
                #endif
                openAIRealtimeClient.sendToolResultAndContinue(
                    callId: callId,
                    output: #"{"status":"error","message":"Unknown tool."}"#
                )
            }

        case .speechStarted:
            // MARK: - Skilly — Live Tutor: server detected speech
            guard isLiveTutorModeActive else { break }
            // Ignore speech events while the model is responding — with the
            // mic muted during TTS playback, any straggling speech_started
            // events are from buffered audio before the mute kicked in.
            guard voiceState != .responding else { break }
            resetLiveTutorAutoSleepTimer()

            // Reset per-turn state
            realtimeResponseText = ""
            currentTurnUserTranscript = nil
            currentTurnScreenCaptures = []
            hasEndedAssistantSpeechForCurrentTurn = false
            didReceivePointToolCallForCurrentTurn = false
            didReceiveAnyAudioChunkForCurrentTurn = false
            pendingToolCallIdForCurrentTurn = nil
            isAwaitingForcedSpokenFollowUp = false
            currentTurnStartTime = Date()
            beginRustRealtimeTurnTracking(turnPrefix: "vad")
            clearDetectedElementLocation()
            // MARK: - Plato — drop last turn's highlights before a new turn
            clearAllHighlights()
            clearRealtimeResponseBubble()

            voiceState = .listening

            // Show overlay if hidden
            if !isSkillyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Capture screenshots for visual context
            Task {
                do {
                    let allScreenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                    currentTurnScreenCaptures = allScreenCaptures
                    for (screenIndex, screenCapture) in allScreenCaptures.enumerated() {
                        // MARK: - Plato — give the model a SINGLE coordinate space
                        // (the image's own pixel grid). Previously we also advertised
                        // the display's point size, and a model that answered in
                        // points produced coordinates scaled by
                        // displayPoints/screenshotPixels (a systematic down-right
                        // offset that grew with display size).
                        let screenshotDescription = """
                        \(screenCapture.label). \
                        coordinate space: this image is \(screenCapture.screenshotWidthInPixels) pixels wide by \(screenCapture.screenshotHeightInPixels) pixels tall; give x,y in THIS pixel grid, top-left origin. \
                        screen number: \(screenIndex + 1).
                        """
                        openAIRealtimeClient.sendScreenshot(
                            screenCapture.imageData,
                            withText: screenshotDescription
                        )
                    }
                } catch {
                    #if DEBUG
                    print("⚠️ Live Tutor: screenshot capture failed: \(error)")
                    #endif
                }
            }

        case .speechStopped:
            // MARK: - Skilly — Live Tutor: server detected end of speech
            guard isLiveTutorModeActive else { break }
            appendRustRealtimeEvent(type: .audioCaptureCommitted)
            voiceState = .processing
            #if DEBUG
            print("🎓 Live Tutor: speech ended, server auto-committed")
            #endif

        case .error(let message):
            appendRustRealtimeEvent(type: .sessionError, message: message)
            // MARK: - Skilly — Debug logging (stripped in release)
            #if DEBUG
            print("⚠️ OpenAI Realtime error: \(message)")
            #endif
            // Stop Live Tutor if active — the WebSocket is dead and the
            // audio tap would pump chunks into a disconnected client.
            if isLiveTutorModeActive {
                stopLiveTutorMode()
            }
            hasEndedAssistantSpeechForCurrentTurn = false
            isWaitingForRealtimeAudioQueueDrain = false
            voiceState = .idle
            clearRealtimeResponseBubble()
            resetRustRealtimeTracking()
        }
    }

    private func handleRealtimeAudioQueueDrained() {
        guard isWaitingForRealtimeAudioQueueDrain else { return }
        isWaitingForRealtimeAudioQueueDrain = false
        voiceState = .idle
        // Plato: during the guided tour, keep the just-spoken line's caption
        // visible after the audio drains (it's replaced when the next step speaks,
        // or cleared by finishGuidedOnboarding) so the guidance stays on screen
        // while the user acts, instead of blanking between steps. Normal turns
        // clear the bubble as before.
        if guidedOnboardingStep == nil {
            clearRealtimeResponseBubble()
        }
        // Plato: the final tour step (research) has no follow-on step. Once its
        // spoken line finishes playing, end the tour shortly after instead of
        // waiting out the long no-speech fallback timeout — that fallback left a
        // big lag (~14s of dead air with the music still playing) after the last
        // word. scheduleOnboardingAdvance replaces that fallback timer; for the
        // research step advanceOnboarding calls finishGuidedOnboarding, which
        // fades the music out. A user push-to-talk still ends the tour immediately.
        if guidedOnboardingStep == .research {
            scheduleOnboardingAdvance(after: onboardingFinalStepEndDelaySeconds)
        }
        scheduleTransientHideIfNeeded()
        resetRustRealtimeTracking()
        if !hasEndedAssistantSpeechForCurrentTurn {
            RealtimeTelemetry.shared.endAssistantSpeech()
            hasEndedAssistantSpeechForCurrentTurn = true
        }
        // MARK: - Skilly — Debug logging (stripped in release)
        #if DEBUG
        print("🔊 OpenAI Realtime: voiceState → idle (audio queue drained)")
        #endif
    }

    private func updateRealtimeAudioPowerLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frameCount { sum += abs(channelData[i]) }
        let power = CGFloat(min(1.0, (sum / Float(frameCount)) * 5.0))
        Task { @MainActor in self.currentAudioPowerLevel = power }
    }

    /// Convert AVAudioPCMBuffer to PCM16 mono 16kHz for OpenAI Realtime.
    private func convertBufferToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let floatData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let ratio = buffer.format.sampleRate / 16000.0
        let targetFrameCount = Int(Double(frameCount) / ratio)

        var pcm16 = Data(capacity: targetFrameCount * 2)
        for i in 0..<targetFrameCount {
            let srcFrame = min(Int(Double(i) * ratio), frameCount - 1)
            var sample: Float = 0
            for ch in 0..<channelCount { sample += floatData[ch][srcFrame] }
            sample /= Float(channelCount)
            var int16 = Int16(max(-1, min(1, sample)) * Float(Int16.max))
            pcm16.append(Data(bytes: &int16, count: 2))
        }
        return pcm16
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        // MARK: - Plato — Farza's intro video is replaced by Plato's guided self-introduction tour.
        startGuidedOnboarding()
    }

    // MARK: - Plato — Guided onboarding tour
    //
    // A fixed-script, 4-step first-run tour. Plato introduces itself, then walks
    // the user through the focus timer, skills, and research lookup. Each step
    // shows a persistent instruction bubble on the cursor, speaks the same point
    // aloud, and (for the timer/skills) flies the cursor to the real panel
    // control. A step advances when Plato detects the user doing the thing
    // (starting a focus block, asking a research question); a per-step timeout
    // keeps the tour moving so it never stalls. Scripts are the constants below.

    /// How long a step waits for the user to act before advancing on its own.
    private var onboardingStepTimeoutSeconds: TimeInterval { 13.0 }

    /// How long the final step lingers after its spoken line finishes before the
    /// tour ends and the music fades. Keeps the ending from feeling abrupt while
    /// avoiding the long dead-air lag the no-speech fallback timeout used to cause.
    private var onboardingFinalStepEndDelaySeconds: TimeInterval { 2.0 }

    /// Begins the guided tour: prewarm the realtime session (so Plato can speak),
    /// start the ambient music, and run the first step.
    func startGuidedOnboarding() {
        // Plato: clear any realtime transcript bubble left over from a prior
        // interaction so the tour starts with only its own instruction bubble.
        clearRealtimeResponseBubble()
        startRealtimeSessionPrewarmIfNeeded()
        startOnboardingMusic()
        runOnboardingStep(.intro)
    }

    private func runOnboardingStep(_ step: OnboardingStep) {
        guidedOnboardingStep = step
        // Each step re-arms its own timers/observers; clear the previous ones.
        onboardingStepTimeoutTimer?.invalidate()
        onboardingFocusTimerObservation = nil

        switch step {
        case .intro:
            narrateOnboardingStep("Hi, I'm Plato, your study and research partner. I can see your screen and help with whatever you're curious about. Let me give you a quick tour.")
            scheduleOnboardingAdvance(after: onboardingStepTimeoutSeconds)

        case .focusTimer:
            narrateOnboardingStep("First, your focus timer. Start a block and I'll help you stay on task. If you drift to something distracting, I'll gently nudge you back.")
            pointCursorAtOnboardingTarget(.focusTimerStart, label: "start a block")
            // Advance the instant the user actually starts a focus block...
            observeFocusTimerStartForOnboarding()
            // ...otherwise just move on (chosen fallback — Plato does not start it for them).
            scheduleOnboardingAdvance(after: onboardingStepTimeoutSeconds)

        case .skills:
            narrateOnboardingStep(skillsStepNarration())
            pointCursorAtOnboardingTarget(.addSkill, label: "add skills here")
            // Explain, then auto-advance (chosen behavior).
            scheduleOnboardingAdvance(after: onboardingStepTimeoutSeconds)

        case .research:
            // No control to point at — clear the panel so the screen is calm for
            // the "ask me something" moment.
            NotificationCenter.default.post(name: .skillyDismissPanel, object: nil)
            let pushToTalkShortcut = BuddyPushToTalkShortcut.pushToTalkDisplayText
            narrateOnboardingStep("I can also look up real research papers. Curious about something? Hold \(pushToTalkShortcut) and just ask me — for example, find papers on a topic you care about.")
            // Normal end: when the line finishes speaking, handleRealtimeAudioQueueDrained
            // ends the tour after onboardingFinalStepEndDelaySeconds. A user push-to-talk
            // (or handleScholarToolCall detecting a search) ends it sooner. This longer
            // timeout is only a fallback for the case where the line never plays at all
            // (e.g. the realtime session never connected), so the tour can't hang.
            scheduleOnboardingAdvance(after: onboardingStepTimeoutSeconds + 9.0)
        }
    }

    /// Narrates one step's line in Plato's voice. The on-cursor caption is NOT a
    /// pre-scripted bubble — it's the live transcript of this very speech (the
    /// realtime response bubble), so the text the user reads always matches what
    /// they hear, even though gpt-realtime may not voice the line perfectly
    /// word-for-word. (A pre-scripted bubble could never match the model's
    /// paraphrase, which is exactly the mismatch this avoids.)
    private func narrateOnboardingStep(_ line: String) {
        speakOnboardingLine(line)
    }

    /// Move to the next step, or finish after the last one.
    private func advanceOnboarding() {
        switch guidedOnboardingStep {
        case .intro: runOnboardingStep(.focusTimer)
        case .focusTimer: runOnboardingStep(.skills)
        case .skills: runOnboardingStep(.research)
        case .research: finishGuidedOnboarding()
        case .none: break
        }
    }

    /// Tears the tour down: stop timers/observers, hide the bubble and pointer,
    /// and fade the music. Safe to call at any time.
    func finishGuidedOnboarding() {
        onboardingStepTimeoutTimer?.invalidate()
        onboardingStepTimeoutTimer = nil
        onboardingFocusTimerObservation = nil
        guidedOnboardingStep = nil
        clearDetectedElementLocation()
        // MARK: - Plato
        clearAllHighlights()
        hideOnboardingBubble()
        // Plato: drop any suppressed transcript bubble state so a normal
        // interaction right after the tour renders its bubble cleanly.
        clearRealtimeResponseBubble()
        fadeOutOnboardingMusic()
    }

    private func scheduleOnboardingAdvance(after seconds: TimeInterval) {
        onboardingStepTimeoutTimer?.invalidate()
        onboardingStepTimeoutTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.requestOnboardingAdvance()
        }
    }

    /// True while Plato is still generating or playing the current step's spoken
    /// line. `.responding` spans from the first audio chunk until the audio queue
    /// drains; `isModelSpeaking` covers generation before the first chunk arrives;
    /// the drain flag covers the tail still playing out after the model finished.
    private var isOnboardingLineStillSpeaking: Bool {
        voiceState == .responding
            || openAIRealtimeClient.isModelSpeaking
            || isWaitingForRealtimeAudioQueueDrain
    }

    /// Advances the tour, but NEVER tears a step down while its line is still
    /// being spoken. Advancing mid-speech runs speakViaRealtimeWhenConnected,
    /// which calls cancelResponse() and blanks realtimeResponseText — cutting the
    /// audio and wiping the caption's tail. That is exactly why the (longest)
    /// skills line's "…and you can add more anytime by importing a skill folder"
    /// was spoken but never finished rendering in the bubble: the fixed timeout
    /// fired while that line was still playing. Instead we re-check until the line
    /// finishes, then advance — so the full line is both heard and read. The
    /// bounded re-checks guarantee the tour can never stall if the line never
    /// plays (e.g. the realtime session never connected). A step change cancels
    /// these re-checks because runOnboardingStep invalidates onboardingStepTimeoutTimer.
    private func requestOnboardingAdvance(speechCompletionChecksRemaining: Int = 30) {
        guard guidedOnboardingStep != nil else { return }
        if isOnboardingLineStillSpeaking && speechCompletionChecksRemaining > 0 {
            onboardingStepTimeoutTimer?.invalidate()
            onboardingStepTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.requestOnboardingAdvance(speechCompletionChecksRemaining: speechCompletionChecksRemaining - 1)
            }
            return
        }
        advanceOnboarding()
    }

    /// Advances the tour the moment the focus timer enters its work phase.
    private func observeFocusTimerStartForOnboarding() {
        onboardingFocusTimerObservation = pomodoro.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self, self.guidedOnboardingStep == .focusTimer else { return }
                if phase == .work {
                    self.advanceOnboarding()
                }
            }
    }

    /// Opens the panel (so the control is on screen) and flies the cursor to it.
    private func pointCursorAtOnboardingTarget(_ target: OnboardingPointTarget, label: String) {
        NotificationCenter.default.post(name: .platoShowPanelForOnboarding, object: nil)
        // Give the panel a beat to open and report the control's frame, then point.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.guidedOnboardingStep != nil else { return }
            guard let targetScreenRect = self.onboardingTargetScreenFrames[target] else { return }
            let targetCenter = CGPoint(x: targetScreenRect.midX, y: targetScreenRect.midY)
            let hostingScreen = NSScreen.screens.first { $0.frame.contains(targetCenter) } ?? NSScreen.main
            // Set display frame + label before the location, which triggers the flight.
            self.detectedElementDisplayFrame = hostingScreen?.frame
            self.detectedElementBubbleText = label
            self.detectedElementScreenLocation = targetCenter
        }
    }

    /// Called by the panel to report a pointable control's live on-screen frame.
    func registerOnboardingTargetFrame(_ target: OnboardingPointTarget, screenRect: CGRect) {
        onboardingTargetScreenFrames[target] = screenRect
    }

    /// Builds the skills-step narration from the user's actually-installed skills.
    /// Names at most the first three so the line stays short whether the user has
    /// three skills or thirty (keeps the spoken line and matching bubble concise).
    private func skillsStepNarration() -> String {
        let allSkillNames = (skillManager?.installedSkills ?? []).map { $0.metadata.name }
        if allSkillNames.isEmpty {
            return "You can add skills by importing a skill folder. Each one teaches me a subject so I can tutor you in it."
        }
        let topSkillNames = Array(allSkillNames.prefix(3))
        let nameList = naturalListSentence(from: topSkillNames)
        if allSkillNames.count > topSkillNames.count {
            return "Some of your skills are \(nameList), and more. Each one teaches me a subject so I can tutor you in it, and you can add more anytime by importing a skill folder."
        }
        return "These are your skills: \(nameList). Each one teaches me a subject so I can tutor you in it, and you can add more anytime by importing a skill folder."
    }

    /// Joins items into a spoken-style list, e.g. "A, B, and C".
    private func naturalListSentence(from items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            let allButLast = items.dropLast().joined(separator: ", ")
            return "\(allButLast), and \(items[items.count - 1])"
        }
    }

    /// Shows a persistent instruction bubble on the cursor, typed out. Unlike the
    /// old auto-dismissing prompt, this stays until the tour replaces or hides it.
    private func showOnboardingBubble(_ text: String) {
        onboardingBubbleTypeTimer?.invalidate()
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0
        withAnimation(.easeIn(duration: 0.3)) {
            onboardingPromptOpacity = 1.0
        }
        var characterIndex = 0
        onboardingBubbleTypeTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard characterIndex < text.count else { timer.invalidate(); return }
            let index = text.index(text.startIndex, offsetBy: characterIndex)
            self.onboardingPromptText.append(text[index])
            characterIndex += 1
        }
    }

    private func hideOnboardingBubble() {
        onboardingBubbleTypeTimer?.invalidate()
        onboardingBubbleTypeTimer = nil
        withAnimation(.easeOut(duration: 0.3)) {
            onboardingPromptOpacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.showOnboardingPrompt = false
            self?.onboardingPromptText = ""
        }
    }

    /// Speaks one fixed tour line in Plato's voice. The same content is in the
    /// bubble, so the tour still reads correctly even with no audio.
    private func speakOnboardingLine(_ line: String) {
        let instruction = "Say the following to the user out loud, warmly and naturally, word for word with no additions, no preamble, and do not call any tools: \"\(line)\""
        speakViaRealtimeWhenConnected(instruction: instruction)
    }

    /// Sends a forced spoken response, waiting (best-effort) for the realtime
    /// session to connect first. connect() can take several seconds (token +
    /// WebSocket handshake + session.created + config); a fixed delay used to
    /// race it and the line was silently dropped by the isConnected guard. If a
    /// previous line is still playing it is cancelled so steps never collide with
    /// the GA "one active response at a time" rule.
    private func speakViaRealtimeWhenConnected(instruction: String) {
        let speakNow: () -> Void = { [weak self] in
            guard let self else { return }
            if self.openAIRealtimeClient.isModelSpeaking {
                self.openAIRealtimeClient.cancelResponse()
            }
            // Plato: start each forced line with an empty transcript buffer so the
            // live caption shows only this line. Forced narration responses don't
            // reset realtimeResponseText themselves (only user turns do, at
            // push-to-talk start), so without this each step's transcript would
            // append onto the previous step's.
            self.realtimeResponseText = ""
            self.openAIRealtimeClient.requestForcedSpokenResponse(instruction: instruction)
        }

        if openAIRealtimeClient.isConnected {
            speakNow()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            var connectionAttemptsRemaining = 60  // 60 × 200ms ≈ 12s
            while connectionAttemptsRemaining > 0 && !self.openAIRealtimeClient.isConnected {
                try? await Task.sleep(for: .milliseconds(200))
                connectionAttemptsRemaining -= 1
            }
            guard self.openAIRealtimeClient.isConnected else { return }
            speakNow()
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    func performOnboardingDemoInteraction() {
        // MARK: - Skilly — Onboarding demo uses realtime pipeline (classic Claude pipeline removed)
    }
}
