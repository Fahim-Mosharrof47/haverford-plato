// MARK: - Plato
import Testing
import CoreGraphics
@testable import leanring_buddy

struct AXCandidateScoringTests {

    private let mainScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func candidate(_ text: String, x: CGFloat, y: CGFloat) -> AXControlCandidate {
        AXControlCandidate(matchedText: text, globalFrame: CGRect(x: x, y: y, width: 60, height: 24))
    }

    // MARK: - Match quality

    @Test func exactBeatsPrefixBeatsSubstring() {
        #expect(AXCandidateScoring.matchQuality(of: "Print", forNormalizedQuery: "print") == .exact)
        #expect(AXCandidateScoring.matchQuality(of: "Print Preview", forNormalizedQuery: "print") == .prefix)
        #expect(AXCandidateScoring.matchQuality(of: "Show Print Dialog", forNormalizedQuery: "print") == .substring)
        #expect(AXCandidateScoring.matchQuality(of: "Export", forNormalizedQuery: "print") == nil)
    }

    // MARK: - Ranking

    @Test func exactTitleWinsOverSubstringRegardlessOfDistance() {
        let exactFarAway = candidate("Save", x: 1300, y: 50)
        let substringNearby = candidate("Save As Template", x: 100, y: 100)
        let best = AXCandidateScoring.bestCandidate(
            among: [substringNearby, exactFarAway],
            normalizedQuery: "save",
            approximatePoint: CGPoint(x: 110, y: 110),
            visibleScreenFrames: [mainScreen]
        )
        #expect(best == exactFarAway)
    }

    @Test func sameQualityTieBrokenByDecisiveProximity() {
        let nearButton = candidate("Save", x: 100, y: 100)
        let farButton = candidate("Save", x: 1200, y: 700)
        let best = AXCandidateScoring.bestCandidate(
            among: [farButton, nearButton],
            normalizedQuery: "save",
            approximatePoint: CGPoint(x: 105, y: 105),
            visibleScreenFrames: [mainScreen]
        )
        #expect(best == nearButton)
    }

    // Two equally plausible "Save" buttons equidistant from the guess: decline —
    // wrong-target pointing is worse than no pointing (review finding D-01).
    @Test func sameQualityNearEqualDistanceDeclines() {
        let leftButton = candidate("Save", x: 400, y: 500)
        let rightButton = candidate("Save", x: 460, y: 500)
        let best = AXCandidateScoring.bestCandidate(
            among: [leftButton, rightButton],
            normalizedQuery: "save",
            approximatePoint: CGPoint(x: 445, y: 512),
            visibleScreenFrames: [mainScreen]
        )
        #expect(best == nil)
    }

    @Test func sameQualityTieWithoutApproximatePointDeclines() {
        let best = AXCandidateScoring.bestCandidate(
            among: [candidate("Save", x: 100, y: 100), candidate("Save", x: 900, y: 700)],
            normalizedQuery: "save",
            approximatePoint: nil,
            visibleScreenFrames: [mainScreen]
        )
        #expect(best == nil)
    }

    // MARK: - Visibility

    // An element AX reports at an off-screen frame (closed window, stale state)
    // must never be ringed.
    @Test func offScreenCandidatesAreFilteredOut() {
        let offScreen = candidate("Print", x: 5000, y: 5000)
        let onScreen = candidate("Print Preview", x: 200, y: 200)
        let best = AXCandidateScoring.bestCandidate(
            among: [offScreen, onScreen],
            normalizedQuery: "print",
            approximatePoint: nil,
            visibleScreenFrames: [mainScreen]
        )
        // The off-screen EXACT match loses to the on-screen prefix match.
        #expect(best == onScreen)
    }

    @Test func allCandidatesOffScreenReturnsNil() {
        let best = AXCandidateScoring.bestCandidate(
            among: [candidate("Print", x: 5000, y: 5000)],
            normalizedQuery: "print",
            approximatePoint: nil,
            visibleScreenFrames: [mainScreen]
        )
        #expect(best == nil)
    }

    @Test func singleOnScreenMatchWins() {
        let only = candidate("Color Inspector", x: 1100, y: 850)
        let best = AXCandidateScoring.bestCandidate(
            among: [only],
            normalizedQuery: "color inspector",
            approximatePoint: nil,
            visibleScreenFrames: [mainScreen]
        )
        #expect(best == only)
    }

    // Candidates on a negative-origin secondary display (above-left arrangement)
    // must count as visible.
    @Test func candidateOnNegativeOriginSecondaryIsVisible() {
        let secondaryScreen = CGRect(x: -2560, y: 1117, width: 2560, height: 1440)
        let onSecondary = candidate("Export", x: -1500, y: 1500)
        let best = AXCandidateScoring.bestCandidate(
            among: [onSecondary],
            normalizedQuery: "export",
            approximatePoint: nil,
            visibleScreenFrames: [mainScreen, secondaryScreen]
        )
        #expect(best == onSecondary)
    }
}
