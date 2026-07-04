// MARK: - Plato
import Testing
import Foundation
import CoreGraphics
@testable import leanring_buddy

struct PlatoHighlightTests {

    private func makeHighlight(createdAt: Date, timeToLive: TimeInterval) -> PlatoHighlight {
        PlatoHighlight(
            kind: .ripplePulse(color: PlatoHighlight.color(forName: "blue")),
            globalFrame: CGRect(x: 100, y: 100, width: 0, height: 0),
            label: nil,
            createdAt: createdAt,
            timeToLive: timeToLive
        )
    }

    @Test func highlightIsNotExpiredWithinItsTimeToLive() {
        let created = Date(timeIntervalSinceReferenceDate: 1000)
        let highlight = makeHighlight(createdAt: created, timeToLive: 4.0)
        #expect(!highlight.isExpired(at: created.addingTimeInterval(3.9)))
        #expect(!highlight.isExpired(at: created))
    }

    @Test func highlightExpiresAfterItsTimeToLive() {
        let created = Date(timeIntervalSinceReferenceDate: 1000)
        let highlight = makeHighlight(createdAt: created, timeToLive: 4.0)
        #expect(highlight.isExpired(at: created.addingTimeInterval(4.1)))
    }
}
