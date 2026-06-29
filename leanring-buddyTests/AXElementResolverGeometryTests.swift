// MARK: - Plato
import Testing
import CoreGraphics
@testable import leanring_buddy

struct AXElementResolverGeometryTests {
    // The AX→AppKit flip is the unit-testable core of the resolver.
    @Test func axTopLeftFrameFlipsToAppKitBottomLeft() {
        let rect = HighlightGeometry.appKitRectFromAXFrame(
            axOrigin: CGPoint(x: 200, y: 100), axSize: CGSize(width: 80, height: 24),
            primaryScreenHeight: 1080
        )
        #expect(rect == CGRect(x: 200, y: 1080 - 100 - 24, width: 80, height: 24))
    }
}
