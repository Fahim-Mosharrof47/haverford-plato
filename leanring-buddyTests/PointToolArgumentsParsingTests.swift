// MARK: - Plato
import Testing
import Foundation
@testable import leanring_buddy

// Tests for the LENIENT point_at_element argument parse (root-cause report
// cause X1, fix step 2). The label is the only hard requirement: AX name
// search and OCR are coordinate-free, so a missing or malformed pixel guess
// must degrade to coordinate-free resolution instead of declining the
// entire pointing attempt.
struct PointToolArgumentsParsingTests {

    private func parse(_ json: String) -> PointToolArgumentsParseResult {
        PointDirectiveParser.parsePointToolArguments(fromJSON: json)
    }

    @Test func parsesCompleteArguments() {
        let result = parse(#"{"x": 640, "y": 360, "label": "Export button", "screen": 2}"#)
        guard case .parsed(let arguments) = result else {
            Issue.record("expected .parsed, got \(result)")
            return
        }
        #expect(arguments.screenshotXInPixels == 640)
        #expect(arguments.screenshotYInPixels == 360)
        #expect(arguments.elementLabel == "Export button")
        #expect(arguments.oneBasedScreenNumber == 2)
    }

    @Test func acceptsDoubleCoordinatesByRounding() {
        let result = parse(#"{"x": 640.6, "y": 359.4, "label": "Export"}"#)
        guard case .parsed(let arguments) = result else {
            Issue.record("expected .parsed, got \(result)")
            return
        }
        #expect(arguments.screenshotXInPixels == 641)
        #expect(arguments.screenshotYInPixels == 359)
    }

    @Test func missingCoordinatesStillParseWithNilCoordinates() {
        let result = parse(#"{"label": "Export button"}"#)
        guard case .parsed(let arguments) = result else {
            Issue.record("expected .parsed, got \(result)")
            return
        }
        #expect(arguments.screenshotXInPixels == nil)
        #expect(arguments.screenshotYInPixels == nil)
    }

    @Test func aLoneCoordinateIsDiscardedAsAPair() {
        // A single axis is useless for anchoring — treat the pair atomically.
        let result = parse(#"{"x": 640, "label": "Export"}"#)
        guard case .parsed(let arguments) = result else {
            Issue.record("expected .parsed, got \(result)")
            return
        }
        #expect(arguments.screenshotXInPixels == nil)
        #expect(arguments.screenshotYInPixels == nil)
    }

    @Test func nonNumericCoordinatesAreDiscardedNotFatal() {
        let result = parse(#"{"x": "center", "y": 360, "label": "Export"}"#)
        guard case .parsed(let arguments) = result else {
            Issue.record("expected .parsed, got \(result)")
            return
        }
        #expect(arguments.screenshotXInPixels == nil)
        #expect(arguments.screenshotYInPixels == nil)
    }

    @Test func missingLabelIsItsOwnFailure() {
        #expect(parse(#"{"x": 640, "y": 360}"#) == .missingLabel)
        #expect(parse(#"{"x": 640, "y": 360, "label": "   "}"#) == .missingLabel)
    }

    @Test func unparseableJSONIsMalformed() {
        #expect(parse("not json at all") == .malformedJSON)
        #expect(parse(#"["x", 640]"#) == .malformedJSON)
    }

    @Test func labelIsTrimmedAndScreenAcceptsDouble() {
        let result = parse(#"{"label": "  Compile  ", "screen": 1.0}"#)
        guard case .parsed(let arguments) = result else {
            Issue.record("expected .parsed, got \(result)")
            return
        }
        #expect(arguments.elementLabel == "Compile")
        #expect(arguments.oneBasedScreenNumber == 1)
    }
}
