// MARK: - Plato
//
//  SessionStateManager.swift
//  leanring-buddy
//
//  Persists a snapshot of the user's last Plato session to Application Support
//  so the next launch can deliver a re-entry briefing ("last session you were
//  on Chapter 3 — pick up there?"). Tracks lightweight session facts during the
//  session and composes a natural-language recap at quit.
//

import Foundation

/// Codable snapshot written to ~/Library/Application Support/Plato/session-state.json.
struct PlatoSessionState: Codable {
    var endedAt: Date
    var focusTopic: String
    var pomodorosCompleted: Int
    var papersSearched: Int
    var summary: String
    var recentTurns: [String]
}

@MainActor
final class SessionStateManager {

    /// Cap on stored conversation turns (the spec's context-budget strategy).
    static let maxRecentTurns = 10

    // MARK: - Live session counters

    private(set) var pomodorosCompleted = 0
    private(set) var papersSearched = 0
    private var focusTopic = ""
    private var lastAssistantResponse = ""
    private var recentTurns: [String] = []

    // MARK: - Storage location

    private let fileURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Plato", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("session-state.json")
    }()

    // MARK: - Recording (called during the session)

    func recordPomodoroCompleted() { pomodorosCompleted += 1 }

    func recordPaperSearch() { papersSearched += 1 }

    func recordFocusTopic(_ topic: String?) {
        focusTopic = topic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Records a completed turn, keeping the assistant's latest reply and a trimmed transcript.
    func recordTurn(userTranscript: String, assistantResponse: String) {
        let assistant = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if !assistant.isEmpty { lastAssistantResponse = assistant }

        let user = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty || !assistant.isEmpty else { return }
        recentTurns.append("You: \(user)\nPlato: \(assistant)")
        if recentTurns.count > Self.maxRecentTurns {
            recentTurns.removeFirst(recentTurns.count - Self.maxRecentTurns)
        }
    }

    // MARK: - Load (launch)

    /// Returns the previous session's recap for the re-entry briefing, or nil if none exists.
    func loadLastSummary() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(PlatoSessionState.self, from: data) else {
            return nil
        }
        let summary = state.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    // MARK: - Persist (session end / quit)

    /// Writes the current session snapshot, composing a recap from tracked facts and the
    /// last exchange. Safe to call at termination (no model round-trip required).
    func persistCurrentSession() {
        // Skip writing an empty session (nothing happened) so we don't clobber a useful prior one.
        guard pomodorosCompleted > 0 || papersSearched > 0 || !lastAssistantResponse.isEmpty || !focusTopic.isEmpty else {
            return
        }
        let state = PlatoSessionState(
            endedAt: Date(),
            focusTopic: focusTopic,
            pomodorosCompleted: pomodorosCompleted,
            papersSearched: papersSearched,
            summary: composeSummary(),
            recentTurns: recentTurns
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL)
        }
    }

    /// Builds a concise natural-language recap from tracked facts plus the last assistant reply.
    private func composeSummary() -> String {
        var parts: [String] = []
        if !focusTopic.isEmpty { parts.append("Focus: \(focusTopic).") }
        if pomodorosCompleted > 0 {
            parts.append("Completed \(pomodorosCompleted) focus block\(pomodorosCompleted == 1 ? "" : "s").")
        }
        if papersSearched > 0 {
            parts.append("Looked up the literature \(papersSearched) time\(papersSearched == 1 ? "" : "s").")
        }
        if !lastAssistantResponse.isEmpty {
            parts.append("Where you left off: \(String(lastAssistantResponse.prefix(400)))")
        }
        return parts.joined(separator: " ")
    }
}
