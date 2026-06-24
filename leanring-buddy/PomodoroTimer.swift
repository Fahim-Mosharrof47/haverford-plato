// MARK: - Plato
//
//  PomodoroTimer.swift
//  leanring-buddy
//
//  A focus (Pomodoro) timer for Plato. Pure state machine + 1-second ticker.
//  Voice announcements and focus-topic propagation are delegated to closures
//  set by CompanionManager, so this type stays UI- and voice-agnostic.
//

import Combine
import Foundation

@MainActor
final class PomodoroTimer: ObservableObject {

    enum Phase: String {
        case idle
        case work
        case breakTime
    }

    // MARK: - Published state (observed by the panel UI)

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var secondsRemaining: Int = 0
    @Published private(set) var isRunning: Bool = false

    /// 1-based index of the current focus block within the set.
    @Published private(set) var currentSession: Int = 1

    /// The user's declared focus topic for the active set. When it changes during a work
    /// block, the new topic is propagated immediately so the persona's prompt stays current.
    @Published var focusTopic: String = "" {
        didSet {
            if phase == .work {
                onFocusTopicChange?(focusTopic.isEmpty ? nil : focusTopic)
            }
        }
    }

    // MARK: - Configuration (read from AppSettings when a set begins)

    private var workMinutes: Int = 25
    private var breakMinutes: Int = 5
    private var sessionsPerBlock: Int = 4

    /// Total focus blocks in the current set (for "3 of N" display).
    var sessionsTotal: Int { sessionsPerBlock }

    // MARK: - Transition callbacks (wired by CompanionManager)

    /// Fired when a focus block starts: (sessionIndex, totalSessions, focusTopic).
    var onWorkStart: ((Int, Int, String) -> Void)?
    /// Fired when a focus block ends and a break begins: (sessionIndex, totalSessions).
    var onWorkEnd: ((Int, Int) -> Void)?
    /// Fired when a break ends.
    var onBreakEnd: (() -> Void)?
    /// Fired whenever the active focus topic should propagate to the prompt. nil clears it.
    var onFocusTopicChange: ((String?) -> Void)?

    private var ticker: Timer?

    // MARK: - Display

    /// Countdown formatted as MM:SS for the Geist Mono timer readout.
    var displayTime: String {
        let minutes = max(secondsRemaining, 0) / 60
        let seconds = max(secondsRemaining, 0) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Controls

    /// Start a new set (from idle) or resume after a pause.
    func start() {
        if phase == .idle {
            let settings = AppSettings.shared
            workMinutes = settings.pomodoroWorkMinutes
            breakMinutes = settings.pomodoroBreakMinutes
            sessionsPerBlock = settings.pomodoroSessionsPerBlock
            currentSession = 1
            beginWork()
        } else {
            isRunning = true
            startTicker()
        }
    }

    /// Pause the countdown without losing the current phase or remaining time.
    func pause() {
        isRunning = false
        ticker?.invalidate()
        ticker = nil
    }

    /// Stop everything and return to idle.
    func reset() {
        pause()
        phase = .idle
        secondsRemaining = 0
        currentSession = 1
        onFocusTopicChange?(nil)
    }

    // MARK: - Phase transitions

    private func beginWork() {
        phase = .work
        secondsRemaining = max(workMinutes, 1) * 60
        isRunning = true
        onFocusTopicChange?(focusTopic.isEmpty ? nil : focusTopic)
        onWorkStart?(currentSession, sessionsPerBlock, focusTopic)
        startTicker()
    }

    private func beginBreak() {
        phase = .breakTime
        secondsRemaining = max(breakMinutes, 1) * 60
        isRunning = true
        onWorkEnd?(currentSession, sessionsPerBlock)
        onFocusTopicChange?(nil)  // not focusing during a break
        startTicker()
    }

    private func finishBreak() {
        onBreakEnd?()
        if currentSession < sessionsPerBlock {
            currentSession += 1
            beginWork()
        } else {
            reset()  // completed the full set
        }
    }

    // MARK: - Ticking

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        guard isRunning else { return }
        if secondsRemaining > 0 {
            secondsRemaining -= 1
            return
        }
        switch phase {
        case .work: beginBreak()
        case .breakTime: finishBreak()
        case .idle: pause()
        }
    }
}
