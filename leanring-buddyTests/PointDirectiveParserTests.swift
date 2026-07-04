// MARK: - Plato
import Testing
import CoreGraphics
import Foundation
@testable import leanring_buddy

struct PointDirectiveParserTests {

    // MARK: - parse(from:)

    @Test func parsesBasicTag() {
        let directive = PointDirectiveParser.parse(from: "click here [POINT:640,220:save button]")
        #expect(directive?.screenshotXInPixels == 640)
        #expect(directive?.screenshotYInPixels == 220)
        #expect(directive?.elementLabel == "save button")
        #expect(directive?.oneBasedScreenNumber == nil)
    }

    @Test func parsesScreenSuffix() {
        let directive = PointDirectiveParser.parse(from: "[POINT:400,300:terminal:screen2]")
        #expect(directive?.elementLabel == "terminal")
        #expect(directive?.oneBasedScreenNumber == 2)
    }

    @Test func keepsColonsInsideLabel() {
        let directive = PointDirectiveParser.parse(from: "[POINT:10,20:File: Export]")
        #expect(directive?.elementLabel == "File: Export")
    }

    // The tool path accepts floats, so the fallback tag path must too — a float
    // must not silently drop the whole directive (review finding D-11).
    @Test func parsesFloatCoordinatesByRounding() {
        let directive = PointDirectiveParser.parse(from: "[POINT:640.5,219.4:save button]")
        #expect(directive?.screenshotXInPixels == 641)
        #expect(directive?.screenshotYInPixels == 219)
    }

    @Test func usesLastTagWhenMultiplePresent() {
        let directive = PointDirectiveParser.parse(
            from: "[POINT:1,2:first] and then [POINT:3,4:second]"
        )
        #expect(directive?.elementLabel == "second")
    }

    @Test func explicitNoneReturnsNil() {
        #expect(PointDirectiveParser.parse(from: "[POINT:none]") == nil)
    }

    @Test func malformedPayloadsReturnNil() {
        #expect(PointDirectiveParser.parse(from: "no tag at all") == nil)
        #expect(PointDirectiveParser.parse(from: "[POINT:640:missing y]") == nil)
        #expect(PointDirectiveParser.parse(from: "[POINT:x,y:label]") == nil)
        #expect(PointDirectiveParser.parse(from: "[POINT:640,220:]") == nil)
        #expect(PointDirectiveParser.parse(from: "[POINT:nan,220:label]") == nil)
        #expect(PointDirectiveParser.parse(from: "[POINT:inf,220:label]") == nil)
    }

    // MARK: - Tag stripping (review finding D-10)

    // An INLINE tag mid-sentence must be removed, not just an end-anchored one.
    @Test func stripsInlineTagMidSentence() {
        let cleaned = PointDirectiveParser.stripCompletedPointTags(
            from: "click the save button [POINT:640,220:save button] and then export"
        )
        #expect(cleaned == "click the save button and then export")
    }

    @Test func stripsMultipleTagsAndTrailingTag() {
        let cleaned = PointDirectiveParser.stripCompletedPointTags(
            from: "first [POINT:1,2:a] middle [POINT:3,4:b]"
        )
        #expect(cleaned == "first middle")
    }

    @Test func streamingBubbleStripHidesTrailingPartialFragment() {
        let cleaned = PointDirectiveParser.stripPointTagArtifactsForStreamingBubble(
            from: "click the button [POINT:640,2"
        )
        #expect(cleaned == "click the button")
    }

    @Test func streamingBubbleStripRemovesInlineCompleteTag() {
        let cleaned = PointDirectiveParser.stripPointTagArtifactsForStreamingBubble(
            from: "click [POINT:640,220:save] then export, and [POINT:1,"
        )
        #expect(cleaned == "click then export, and")
    }

    // MARK: - resolveTargetScreenCapture (review finding D-09)

    private func makeScreenCapture(isCursorScreen: Bool, label: String) -> CompanionScreenCapture {
        CompanionScreenCapture(
            imageData: Data(),
            label: label,
            isCursorScreen: isCursorScreen,
            displayWidthInPoints: 1440,
            displayHeightInPoints: 900,
            displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800
        )
    }

    private func directive(screen: Int?) -> ParsedPointDirective {
        ParsedPointDirective(
            screenshotXInPixels: 0, screenshotYInPixels: 0,
            elementLabel: "x", oneBasedScreenNumber: screen
        )
    }

    @Test func explicitValidScreenNumberSelectsThatCapture() {
        let captures = [
            makeScreenCapture(isCursorScreen: true, label: "one"),
            makeScreenCapture(isCursorScreen: false, label: "two"),
        ]
        let resolved = PointDirectiveParser.resolveTargetScreenCapture(for: directive(screen: 2), in: captures)
        #expect(resolved?.label == "two")
    }

    // An explicit-but-invalid screen number must DECLINE, not silently remap the
    // coordinates onto the cursor screen (decline > mis-point).
    @Test func explicitInvalidScreenNumberReturnsNil() {
        let captures = [
            makeScreenCapture(isCursorScreen: true, label: "one"),
            makeScreenCapture(isCursorScreen: false, label: "two"),
        ]
        #expect(PointDirectiveParser.resolveTargetScreenCapture(for: directive(screen: 3), in: captures) == nil)
        #expect(PointDirectiveParser.resolveTargetScreenCapture(for: directive(screen: 0), in: captures) == nil)
    }

    @Test func missingScreenNumberFallsBackToCursorScreen() {
        let captures = [
            makeScreenCapture(isCursorScreen: false, label: "one"),
            makeScreenCapture(isCursorScreen: true, label: "two"),
        ]
        let resolved = PointDirectiveParser.resolveTargetScreenCapture(for: directive(screen: nil), in: captures)
        #expect(resolved?.label == "two")
    }

    @Test func emptyCapturesReturnsNil() {
        #expect(PointDirectiveParser.resolveTargetScreenCapture(for: directive(screen: nil), in: []) == nil)
    }
}
