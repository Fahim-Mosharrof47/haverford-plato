// MARK: - Plato
import Testing
import CoreGraphics
@testable import leanring_buddy

struct HighlightGeometryTests {

    private let primaryDisplay = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // A full-image screenshot rect should map to the whole display.
    @Test func screenshotFullRectMapsToWholeDisplay() {
        let rect = HighlightGeometry.globalRectFromScreenshotPixelRect(
            x: 0, y: 0, width: 1280, height: 800,
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 800,
            displayFrame: primaryDisplay
        )
        #expect(rect == CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    // A box in the TOP-LEFT quarter of the screenshot maps to the TOP-LEFT of the
    // display, which in AppKit (bottom-left origin) is the HIGH-Y half.
    @Test func screenshotTopLeftQuarterMapsToTopLeftAppKit() {
        let rect = HighlightGeometry.globalRectFromScreenshotPixelRect(
            x: 0, y: 0, width: 640, height: 400,
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 800,
            displayFrame: primaryDisplay
        )
        // width 640/1280 -> 720; height 400/800 -> 450; top edge at AppKit y=900,
        // so origin.y = 900 - 450 = 450.
        #expect(rect == CGRect(x: 0, y: 450, width: 720, height: 450))
    }

    // Vision box is already bottom-left normalized: no Y flip.
    @Test func visionBoxMapsWithoutYFlip() {
        let box = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        let rect = HighlightGeometry.globalRectFromNormalizedVisionBox(box, displayFrame: primaryDisplay)
        #expect(rect == CGRect(x: 720, y: 450, width: 720, height: 450))
    }

    // Global AppKit rect -> overlay-local SwiftUI rect (top-left origin) on a
    // secondary screen whose origin is offset.
    @Test func globalRectToLocalRectFlipsAndOffsets() {
        let screenFrame = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        // A 100x100 rect whose AppKit bottom edge is at y=800 (top edge y=900 = top of screen).
        let globalFrame = CGRect(x: 1540, y: 800, width: 100, height: 100)
        let local = HighlightGeometry.localRectFromGlobalRect(globalFrame, screenFrame: screenFrame)
        // x: 1540 - 1440 = 100; top edge -> local y = (0+900) - (800+100) = 0.
        #expect(local == CGRect(x: 100, y: 0, width: 100, height: 100))
    }

    // AX frame is top-left points anchored to primary; flip Y only, against primary height.
    @Test func axFrameFlipsAgainstPrimaryHeight() {
        let rect = HighlightGeometry.appKitRectFromAXFrame(
            axOrigin: CGPoint(x: 10, y: 50), axSize: CGSize(width: 100, height: 30),
            primaryScreenHeight: 900
        )
        // appKit y = 900 - 50 - 30 = 820.
        #expect(rect == CGRect(x: 10, y: 820, width: 100, height: 30))
    }

    // MARK: - Point mapping (single source of truth; review finding D-08)

    @Test func pointMapsCenterOfScreenshotToCenterOfDisplay() {
        let point = HighlightGeometry.globalPointFromScreenshotPixel(
            x: 640, y: 400,
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 800,
            displayFrame: primaryDisplay
        )
        #expect(point == CGPoint(x: 720, y: 450))
    }

    @Test func slightOvershootWithinToleranceIsClamped() {
        // 1290 on a 1280px image is 0.8% over — normal model rounding, clamp it.
        let point = HighlightGeometry.globalPointFromScreenshotPixel(
            x: 1290, y: 800,
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 800,
            displayFrame: primaryDisplay
        )
        #expect(point == CGPoint(x: 1440, y: 0))
    }

    // Hallucinated coordinates far outside the image must DECLINE, not be
    // clamped to a screen corner and confidently pointed at.
    @Test func farOutOfRangeCoordinatesDecline() {
        #expect(HighlightGeometry.globalPointFromScreenshotPixel(
            x: 5000, y: 3000,
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 800,
            displayFrame: primaryDisplay
        ) == nil)
        #expect(HighlightGeometry.globalPointFromScreenshotPixel(
            x: -200, y: 100,
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 800,
            displayFrame: primaryDisplay
        ) == nil)
    }

    // MARK: - Rect extent clamping (review finding D-12)

    // x+width past the image edge must clamp to the display edge, not run off it.
    @Test func rectExtentBeyondImageClampsToDisplayEdge() {
        let rect = HighlightGeometry.globalRectFromScreenshotPixelRect(
            x: 1000, y: 0, width: 600, height: 800,
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 800,
            displayFrame: primaryDisplay
        )
        // x: 1000/1280 -> 1125; width clamps to 280px -> 315pt; right edge = 1440.
        #expect(rect == CGRect(x: 1125, y: 0, width: 315, height: 900))
    }

    // MARK: - Above-left secondary display (negative X, high Y) — the
    // arrangement most likely to regress, absent from the original fixtures.
    // Secondary 2560x1440 positioned ABOVE-LEFT of a 1728x1117 primary:
    // AppKit frame (-2560, 1117, 2560, 1440).

    private let aboveLeftSecondary = CGRect(x: -2560, y: 1117, width: 2560, height: 1440)

    @Test func pointMapsOntoAboveLeftSecondary() {
        // Screenshot 1280x720. Pixel (320, 180) = 25% right, 25% down.
        let point = HighlightGeometry.globalPointFromScreenshotPixel(
            x: 320, y: 180,
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 720,
            displayFrame: aboveLeftSecondary
        )
        // gX = -2560 + 2560*0.25 = -1920; gY = 2557 - 1440*0.25 = 2197.
        #expect(point == CGPoint(x: -1920, y: 2197))
    }

    @Test func screenshotRectMapsOntoAboveLeftSecondary() {
        // Top-left quarter of the screenshot -> top-left quarter of the display.
        let rect = HighlightGeometry.globalRectFromScreenshotPixelRect(
            x: 0, y: 0, width: 640, height: 360,
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 720,
            displayFrame: aboveLeftSecondary
        )
        // Top edge at AppKit maxY (2557); origin.y = 2557 - 720 = 1837.
        #expect(rect == CGRect(x: -2560, y: 1837, width: 1280, height: 720))
    }

    @Test func visionBoxMapsOntoAboveLeftSecondaryWithoutFlip() {
        let box = CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.1)
        let rect = HighlightGeometry.globalRectFromNormalizedVisionBox(box, displayFrame: aboveLeftSecondary)
        // x = -2560 + 0.25*2560 = -1920; y = 1117 + 0.5*1440 = 1837.
        #expect(rect == CGRect(x: -1920, y: 1837, width: 640, height: 144))
    }

    @Test func globalRectToLocalRectOnAboveLeftSecondary() {
        // A 100x100 rect at the display's top-left corner.
        let globalFrame = CGRect(x: -2560, y: 2457, width: 100, height: 100)
        let local = HighlightGeometry.localRectFromGlobalRect(globalFrame, screenFrame: aboveLeftSecondary)
        // x: -2560 - (-2560) = 0; y: (1117+1440) - (2457+100) = 0.
        #expect(local == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func axFrameOnAboveLeftSecondaryFlipsAgainstPrimaryHeightOnly() {
        // AX (CG top-left global) for the above-left secondary: y in [-1440, 0).
        // A 24pt-tall element whose AX y is -1200 on a 1117pt primary:
        // appKit y = 1117 - (-1200) - 24 = 2293.
        let rect = HighlightGeometry.appKitRectFromAXFrame(
            axOrigin: CGPoint(x: -2000, y: -1200), axSize: CGSize(width: 120, height: 24),
            primaryScreenHeight: 1117
        )
        #expect(rect == CGRect(x: -2000, y: 2293, width: 120, height: 24))
    }
}
