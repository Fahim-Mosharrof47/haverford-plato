// MARK: - Plato
import Testing
import Foundation
import CoreGraphics
@testable import leanring_buddy

// Tests for the pointing-instrumentation primitives (root-cause report
// docs/reviews/2026-07-07-pointing-root-cause-report.md, "What to instrument
// first"): the where-is intent classifier, the model-guess→resolved-anchor
// offset metric, and the per-turn pointing metrics accumulator.
struct PointingInstrumentationTests {

    // MARK: - WhereIsIntentClassifier

    @Test func classifierDetectsDirectWhereIsQuestions() {
        #expect(WhereIsIntentClassifier.isWhereIsQuestion("Where is the export button?"))
        #expect(WhereIsIntentClassifier.isWhereIsQuestion("where's the button to change margins"))
        #expect(WhereIsIntentClassifier.isWhereIsQuestion("Where are the paragraph settings"))
    }

    @Test func classifierDetectsLocateAndShowPhrasings() {
        #expect(WhereIsIntentClassifier.isWhereIsQuestion("Show me where I click to add a citation"))
        #expect(WhereIsIntentClassifier.isWhereIsQuestion("Can you point to the Zotero icon"))
        #expect(WhereIsIntentClassifier.isWhereIsQuestion("point at the compile button please"))
        #expect(WhereIsIntentClassifier.isWhereIsQuestion("Which button undoes this?"))
        #expect(WhereIsIntentClassifier.isWhereIsQuestion("which menu has the line spacing option"))
        #expect(WhereIsIntentClassifier.isWhereIsQuestion("I can't find the settings"))
        #expect(WhereIsIntentClassifier.isWhereIsQuestion("How do I find the reference manager"))
    }

    @Test func classifierNormalizesCurlyApostrophes() {
        // Voice transcription often emits U+2019 instead of ASCII apostrophes.
        #expect(WhereIsIntentClassifier.isWhereIsQuestion("Where\u{2019}s the citation button"))
        #expect(WhereIsIntentClassifier.isWhereIsQuestion("I can\u{2019}t find the export menu"))
    }

    @Test func classifierIgnoresFactualAndConversationalTurns() {
        #expect(!WhereIsIntentClassifier.isWhereIsQuestion("What is the capital of Spain?"))
        #expect(!WhereIsIntentClassifier.isWhereIsQuestion("Explain photosynthesis to me"))
        #expect(!WhereIsIntentClassifier.isWhereIsQuestion("Thanks, that helped a lot"))
        #expect(!WhereIsIntentClassifier.isWhereIsQuestion("How does a for loop work?"))
        #expect(!WhereIsIntentClassifier.isWhereIsQuestion(""))
    }

    // MARK: - Model-guess → resolved-anchor offset

    @Test func offsetIsEuclideanDistanceBetweenGuessAndResolvedCenter() {
        let offset = PointingGeometryMetrics.offsetInPoints(
            fromModelGuess: CGPoint(x: 100, y: 100),
            toResolvedCenter: CGPoint(x: 103, y: 104)
        )
        #expect(offset == 5.0)
    }

    @Test func offsetIsNilWithoutAModelGuess() {
        let offset = PointingGeometryMetrics.offsetInPoints(
            fromModelGuess: nil,
            toResolvedCenter: CGPoint(x: 103, y: 104)
        )
        #expect(offset == nil)
    }

    // MARK: - PointingTurnMetrics accumulator

    @Test func freshMetricsHaveNoSignal() {
        let metrics = PointingTurnMetrics()
        #expect(!metrics.drewAnyVisual)
        #expect(!metrics.hasAnySignal)
    }

    @Test func whereIsIntentAloneIsASignal() {
        var metrics = PointingTurnMetrics()
        metrics.whereIsIntent = true
        #expect(metrics.hasAnySignal)
        #expect(!metrics.drewAnyVisual)
    }

    @Test func ringOutcomeCountsAsVisual() {
        var metrics = PointingTurnMetrics()
        metrics.record(PointOutcome(
            path: .axName, drewRing: true, movedCursor: true,
            resolvedFrameArea: 400, offsetFromModelGuessInPoints: 12.5
        ))
        #expect(metrics.drewAnyVisual)
        #expect(metrics.hasAnySignal)
        #expect(metrics.outcomes.count == 1)
    }

    @Test func cursorOnlyHedgeStillCountsAsVisual() {
        var metrics = PointingTurnMetrics()
        metrics.record(PointOutcome(
            path: .hedgeNoRing, drewRing: false, movedCursor: true,
            resolvedFrameArea: nil, offsetFromModelGuessInPoints: nil
        ))
        #expect(metrics.drewAnyVisual)
    }

    @Test func declineIsASignalButNotAVisual() {
        var metrics = PointingTurnMetrics()
        metrics.record(PointDecline(gate: .outOfBoundsNoResolve, hadModelPoint: false))
        #expect(!metrics.drewAnyVisual)
        #expect(metrics.hasAnySignal)
        #expect(metrics.declines.count == 1)
    }

    @Test func analyticsPathAndGateValuesAreStableSnakeCase() {
        // These raw values are the PostHog/JSONL contract — renaming them
        // silently breaks dashboards, so pin them.
        #expect(PointAnchorPath.axName.rawValue == "ax_name")
        #expect(PointAnchorPath.axHitTest.rawValue == "ax_hittest")
        #expect(PointAnchorPath.ocrMatch.rawValue == "ocr_match")
        #expect(PointAnchorPath.cropRefined.rawValue == "crop_refined")
        #expect(PointAnchorPath.rawInline.rawValue == "raw_inline")
        #expect(PointAnchorPath.rawRegion.rawValue == "raw_region")
        #expect(PointAnchorPath.rawPoint.rawValue == "raw_point")
        #expect(PointAnchorPath.hedgeNoRing.rawValue == "hedge_no_ring")
        #expect(PointDeclineGate.malformedArguments.rawValue == "malformed_args")
        #expect(PointDeclineGate.missingLabel.rawValue == "missing_label")
        #expect(PointDeclineGate.wrongScreenIndex.rawValue == "wrong_screen_index")
        #expect(PointDeclineGate.noScreenCapture.rawValue == "no_screen_capture")
        #expect(PointDeclineGate.outOfBoundsNoResolve.rawValue == "out_of_bounds_no_resolve")
        #expect(PointDeclineGate.ocrAmbiguous.rawValue == "ocr_ambiguous")
        #expect(PointDeclineGate.ocrNotFound.rawValue == "ocr_not_found")
        #expect(PointDeclineGate.screenChangedMidResolve.rawValue == "screen_changed_mid_resolve")
    }

    @Test func turnSummaryRowCarriesTheAccumulatedCounts() {
        var metrics = PointingTurnMetrics()
        metrics.whereIsIntent = true
        metrics.visualToolCallCount = 2
        metrics.record(PointOutcome(
            path: .ocrMatch, drewRing: true, movedCursor: true,
            resolvedFrameArea: 900, offsetFromModelGuessInPoints: 30
        ))
        metrics.record(PointDecline(gate: .ocrAmbiguous, hadModelPoint: true))

        let summaryRow = metrics.summaryRow()
        #expect(summaryRow.where_is_intent == true)
        #expect(summaryRow.visual_tool_call_count == 2)
        #expect(summaryRow.drew_any_visual == true)
        #expect(summaryRow.outcomes.count == 1)
        #expect(summaryRow.outcomes[0].path == "ocr_match")
        #expect(summaryRow.declines.count == 1)
        #expect(summaryRow.declines[0].gate == "ocr_ambiguous")
    }
}
