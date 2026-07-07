// MARK: - Plato
//
//  PointingInstrumentation.swift
//  leanring-buddy
//
//  Pure, unit-testable primitives for measuring the pointing pipeline.
//
//  Three prior fix rounds tuned pointing blind: every anchor source (exact AX
//  ring, whole OCR line, raw model-pixel guess, cursor-only hedge) fired the
//  same "element_pointed" analytics event, and none of the ~11 decline gates
//  emitted anything — so neither an accuracy rate nor a "user asked where,
//  app only talked" rate was ever a measurable number (see
//  docs/reviews/2026-07-07-pointing-root-cause-report.md, cause X2).
//
//  These types make the two symptoms countable:
//  - PointAnchorPath / PointOutcome: WHICH source anchored each visual, and
//    how far the model's raw guess was from the resolved ground truth.
//  - PointDeclineGate / PointDecline: WHICH gate silently dropped a visual.
//  - WhereIsIntentClassifier: did the user ask to locate something on screen
//    this turn (the denominator of the "should have pointed" rate).
//  - PointingTurnMetrics: per-turn accumulator, summarized into both PostHog
//    events (SkillyAnalytics) and the local JSONL turn row (RealtimeTelemetry)
//    so the data exists even when analytics is disabled.

import Foundation
import CoreGraphics

// MARK: - Anchor paths

/// Which source ultimately anchored a rendered visual (ring, cursor flight,
/// region, ripple). Ordered roughly from most to least precise — the whole
/// point of the instrumentation is that these used to be indistinguishable.
enum PointAnchorPath: String {
    /// Accessibility API resolved the named control's real frame (name walk).
    case axName = "ax_name"
    /// Accessibility API hit-test under the model's guessed point.
    case axHitTest = "ax_hittest"
    /// Vision OCR matched the target text and returned its real frame.
    case ocrMatch = "ocr_match"
    /// Legacy inline [POINT:x,y] tag — raw model pixel guess, cursor only.
    case rawInline = "raw_inline"
    /// Model-supplied bounding box drawn verbatim (highlight_region/spotlight).
    case rawRegion = "raw_region"
    /// Model-supplied single point drawn verbatim (ripple, scroll affordance).
    case rawPoint = "raw_point"
    /// OCR missed; cursor moved to the in-bounds guess with a hedged bubble,
    /// no ring. Least precise outcome that still shows the user something.
    case hedgeNoRing = "hedge_no_ring"
}

/// One rendered (or hedged) visual and how precisely it was anchored.
struct PointOutcome {
    let path: PointAnchorPath
    let drewRing: Bool
    let movedCursor: Bool
    /// Area in points² of the resolved frame, when a real frame was resolved.
    /// An oversized area flags container/image mis-picks (report cause P1-b).
    let resolvedFrameArea: Double?
    /// Euclidean distance in points between the model's mapped pixel guess
    /// and the resolved anchor center — the direct Symptom-1 accuracy metric.
    /// nil when the model gave no usable guess or the anchor IS the guess.
    let offsetFromModelGuessInPoints: Double?
}

// MARK: - Decline gates

/// Every gate that can silently drop a visual. Each site that used to
/// `return` with nothing now records which gate fired (report cause X1:
/// three fix rounds added decline gates; none were observable).
enum PointDeclineGate: String {
    /// Tool arguments failed to parse (bad JSON, missing x/y).
    case malformedArguments = "malformed_args"
    /// point_at_element arrived with an empty/missing label.
    case missingLabel = "missing_label"
    /// The directive named a screen index with no matching capture.
    case wrongScreenIndex = "wrong_screen_index"
    /// No screenshot exists for this turn at all (capture failed/empty).
    case noScreenCapture = "no_screen_capture"
    /// Coordinates fell >2% outside the screenshot AND no resolver rescued
    /// the point — declined rather than clamped to a screen edge.
    case outOfBoundsNoResolve = "out_of_bounds_no_resolve"
    /// OCR found the text in multiple places and refused to pick one.
    case ocrAmbiguous = "ocr_ambiguous"
    /// OCR could not find the text at all (and there was no hedge anchor).
    case ocrNotFound = "ocr_not_found"
    /// The turn/screen changed while async OCR ran; painting would be stale.
    case screenChangedMidResolve = "screen_changed_mid_resolve"
}

/// One silently-declined visual and whether the model had given an
/// in-bounds coordinate guess when it was declined.
struct PointDecline {
    let gate: PointDeclineGate
    let hadModelPoint: Bool
}

// MARK: - Where-is intent

/// Heuristic classifier for "the user asked to LOCATE something on screen".
/// This is the denominator of the Symptom-2 rate: (where-is turns that drew
/// no visual) / (where-is turns). Conservative keyword matching on the STT
/// transcript — a rate metric, not a router, so occasional misses are fine.
enum WhereIsIntentClassifier {

    /// Phrases that indicate the user wants something located/shown on
    /// screen. Matched against the lowercased, apostrophe-normalized
    /// transcript. Deliberately excludes generic "how do I ..." (usually a
    /// concept question) except the explicit find/open forms.
    private static let locateIntentPhrases: [String] = [
        "where is", "where's", "where are", "where was",
        "where do i", "where can i", "where would i", "where did",
        "show me where", "show me the",
        "point to", "point at", "point me",
        "which button", "which menu", "which icon", "which tab", "which option",
        "how do i find", "how do i open", "how do i get to",
        "can't find", "cannot find", "don't see", "do not see",
        "highlight the", "circle the",
    ]

    static func isWhereIsQuestion(_ transcript: String) -> Bool {
        // Voice transcription emits curly apostrophes (U+2019); normalize so
        // "can’t find" matches "can't find".
        let normalizedTranscript = transcript
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
        guard !normalizedTranscript.isEmpty else { return false }
        return locateIntentPhrases.contains { normalizedTranscript.contains($0) }
    }
}

// MARK: - Geometry metrics

enum PointingGeometryMetrics {
    /// Euclidean distance in points between the model's mapped guess and the
    /// resolved anchor center. nil when there was no usable guess to compare.
    static func offsetInPoints(fromModelGuess modelGuess: CGPoint?, toResolvedCenter resolvedCenter: CGPoint) -> Double? {
        guard let modelGuess else { return nil }
        return Double(hypot(resolvedCenter.x - modelGuess.x, resolvedCenter.y - modelGuess.y))
    }
}

// MARK: - Per-turn accumulator

/// JSONL/analytics-facing snapshot of one turn's pointing activity. Field
/// names are snake_case because they are written verbatim into the telemetry
/// JSONL rows and PostHog properties — renaming them breaks dashboards.
struct PointingTurnSummaryRow: Codable {
    let where_is_intent: Bool
    let visual_tool_call_count: Int
    let drew_any_visual: Bool
    let outcomes: [PointOutcomeRow]
    let declines: [PointDeclineRow]

    struct PointOutcomeRow: Codable {
        let path: String
        let drew_ring: Bool
        let moved_cursor: Bool
        let resolved_frame_area: Double?
        let offset_from_model_guess_pt: Double?
    }

    struct PointDeclineRow: Codable {
        let gate: String
        let had_model_point: Bool
    }
}

/// Accumulates one turn's pointing activity. Reset at turn start, summarized
/// at response completion into the turn telemetry row + a PostHog event.
struct PointingTurnMetrics {
    var whereIsIntent: Bool = false
    /// How many visual tool calls (point_at_element, highlight_*, ripple,
    /// spotlight, scroll affordance) the model made this turn.
    var visualToolCallCount: Int = 0
    private(set) var outcomes: [PointOutcome] = []
    private(set) var declines: [PointDecline] = []

    mutating func record(_ outcome: PointOutcome) {
        outcomes.append(outcome)
    }

    mutating func record(_ decline: PointDecline) {
        declines.append(decline)
    }

    /// True when the user actually SAW something this turn (ring, region,
    /// ripple, or cursor movement). The Symptom-2 rate is where-is turns
    /// where this stays false.
    var drewAnyVisual: Bool {
        outcomes.contains { $0.drewRing || $0.movedCursor }
    }

    /// Whether this turn is worth a summary row at all (skip pure-chat turns
    /// with no locate intent and no pointing activity).
    var hasAnySignal: Bool {
        whereIsIntent || visualToolCallCount > 0 || !outcomes.isEmpty || !declines.isEmpty
    }

    func summaryRow() -> PointingTurnSummaryRow {
        PointingTurnSummaryRow(
            where_is_intent: whereIsIntent,
            visual_tool_call_count: visualToolCallCount,
            drew_any_visual: drewAnyVisual,
            outcomes: outcomes.map {
                PointingTurnSummaryRow.PointOutcomeRow(
                    path: $0.path.rawValue,
                    drew_ring: $0.drewRing,
                    moved_cursor: $0.movedCursor,
                    resolved_frame_area: $0.resolvedFrameArea,
                    offset_from_model_guess_pt: $0.offsetFromModelGuessInPoints
                )
            },
            declines: declines.map {
                PointingTurnSummaryRow.PointDeclineRow(
                    gate: $0.gate.rawValue,
                    had_model_point: $0.hadModelPoint
                )
            }
        )
    }
}
