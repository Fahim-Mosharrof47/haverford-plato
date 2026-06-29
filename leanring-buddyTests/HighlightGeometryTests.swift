// MARK: - Plato
import XCTest
@testable import leanring_buddy

final class HighlightGeometryTests: XCTestCase {

    private let primaryDisplay = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // A full-image screenshot rect should map to the whole display.
    func testScreenshotFullRectMapsToWholeDisplay() {
        let rect = HighlightGeometry.globalRectFromScreenshotPixelRect(
            x: 0, y: 0, width: 1280, height: 800,
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 800,
            displayFrame: primaryDisplay
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    // A box in the TOP-LEFT quarter of the screenshot maps to the TOP-LEFT of the
    // display, which in AppKit (bottom-left origin) is the HIGH-Y half.
    func testScreenshotTopLeftQuarterMapsToTopLeftAppKit() {
        let rect = HighlightGeometry.globalRectFromScreenshotPixelRect(
            x: 0, y: 0, width: 640, height: 400,
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 800,
            displayFrame: primaryDisplay
        )
        // width 640/1280 -> 720; height 400/800 -> 450; top edge at AppKit y=900,
        // so origin.y = 900 - 450 = 450.
        XCTAssertEqual(rect, CGRect(x: 0, y: 450, width: 720, height: 450))
    }

    // Vision box is already bottom-left normalized: no Y flip.
    func testVisionBoxMapsWithoutYFlip() {
        let box = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        let rect = HighlightGeometry.globalRectFromNormalizedVisionBox(box, displayFrame: primaryDisplay)
        XCTAssertEqual(rect, CGRect(x: 720, y: 450, width: 720, height: 450))
    }

    // Global AppKit rect -> overlay-local SwiftUI rect (top-left origin) on a
    // secondary screen whose origin is offset.
    func testGlobalRectToLocalRectFlipsAndOffsets() {
        let screenFrame = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        // A 100x100 rect whose AppKit bottom edge is at y=800 (top edge y=900 = top of screen).
        let globalFrame = CGRect(x: 1540, y: 800, width: 100, height: 100)
        let local = HighlightGeometry.localRectFromGlobalRect(globalFrame, screenFrame: screenFrame)
        // x: 1540 - 1440 = 100; top edge -> local y = (0+900) - (800+100) = 0.
        XCTAssertEqual(local, CGRect(x: 100, y: 0, width: 100, height: 100))
    }

    // AX frame is top-left points anchored to primary; flip Y only, against primary height.
    func testAXFrameFlipsAgainstPrimaryHeight() {
        let rect = HighlightGeometry.appKitRectFromAXFrame(
            axOrigin: CGPoint(x: 10, y: 50), axSize: CGSize(width: 100, height: 30),
            primaryScreenHeight: 900
        )
        // appKit y = 900 - 50 - 30 = 820.
        XCTAssertEqual(rect, CGRect(x: 10, y: 820, width: 100, height: 30))
    }
}
