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
            // A positional hint is present (in-range coords), so the on-screen
            // prefix match is allowed — this test's subject is off-screen filtering,
            // not the no-hint exact-only rule (covered separately below).
            approximatePoint: CGPoint(x: 200, y: 200),
            visibleScreenFrames: [mainScreen]
        )
        // The off-screen EXACT match loses to the on-screen prefix match.
        #expect(best == onScreen)
    }

    // MARK: - Plato — no-positional-hint gate (adversarial finding)

    // With NO approximate point (hallucinated/out-of-range coords), a lone weak
    // match must be DECLINED, not ringed. This is the exact wrong-ring class the
    // fix targets: query "save" (role-word-stripped from "save button")
    // substring-hits an unrelated "Autosave" and, ungated, was ringed ok:true.
    @Test func weakSubstringMatchWithoutHintDeclines() {
        let autosave = candidate("Autosave", x: 300, y: 300)
        let best = AXCandidateScoring.bestCandidate(
            among: [autosave],
            normalizedQuery: "save",
            approximatePoint: nil,
            visibleScreenFrames: [mainScreen]
        )
        #expect(best == nil)
    }

    // A lone PREFIX match with no hint is likewise a wrong-ring risk → decline.
    @Test func weakPrefixMatchWithoutHintDeclines() {
        let saveAs = candidate("Save As Template", x: 300, y: 300)
        let best = AXCandidateScoring.bestCandidate(
            among: [saveAs],
            normalizedQuery: "save",
            approximatePoint: nil,
            visibleScreenFrames: [mainScreen]
        )
        #expect(best == nil)
    }

    // An EXACT-title match has strong evidence and is accepted even with no hint
    // (this keeps the common "download button" → "Download" path working when the
    // model's coordinates are out of range).
    @Test func exactMatchWithoutHintIsAccepted() {
        let save = candidate("Save", x: 300, y: 300)
        let best = AXCandidateScoring.bestCandidate(
            among: [save],
            normalizedQuery: "save",
            approximatePoint: nil,
            visibleScreenFrames: [mainScreen]
        )
        #expect(best == save)
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

    // MARK: - Plato — RC-2 proximity gate

    @Test func substringMatchFarFromHintIsDeclinedWhenGated() {
        let farSubstring = candidate("Save As Template", x: 1300, y: 800) // ~far from hint
        let best = AXCandidateScoring.bestCandidate(
            among: [farSubstring],
            normalizedQuery: "save",
            approximatePoint: CGPoint(x: 100, y: 100),
            visibleScreenFrames: [mainScreen],
            maxDistanceForInexactMatch: 300 // 0.33 * 900-ish
        )
        #expect(best == nil)
    }

    @Test func exactMatchFarFromHintBypassesGate() {
        let farExact = candidate("Save", x: 1300, y: 800)
        let best = AXCandidateScoring.bestCandidate(
            among: [farExact],
            normalizedQuery: "save",
            approximatePoint: CGPoint(x: 100, y: 100),
            visibleScreenFrames: [mainScreen],
            maxDistanceForInexactMatch: 300
        )
        #expect(best == farExact)
    }

    @Test func substringMatchNearHintPassesGate() {
        let nearSubstring = candidate("Save As Template", x: 110, y: 110)
        let best = AXCandidateScoring.bestCandidate(
            among: [nearSubstring],
            normalizedQuery: "save",
            approximatePoint: CGPoint(x: 120, y: 120),
            visibleScreenFrames: [mainScreen],
            maxDistanceForInexactMatch: 300
        )
        #expect(best == nearSubstring)
    }

    @Test func noGateWhenDistanceLimitNil() {
        let farSubstring = candidate("Save As Template", x: 1300, y: 800)
        let best = AXCandidateScoring.bestCandidate(
            among: [farSubstring],
            normalizedQuery: "save",
            approximatePoint: CGPoint(x: 100, y: 100),
            visibleScreenFrames: [mainScreen]) // default nil ⇒ ungated, back-compat
        #expect(best == farSubstring)
    }

    // MARK: - Plato — RC-3 plausibility

    @Test func giantFrameRejectedSmallFrameAccepted() {
        let displaySize = CGSize(width: 1440, height: 900)
        let control = CGRect(x: 10, y: 10, width: 80, height: 30)
        let container = CGRect(x: 0, y: 0, width: 1440, height: 500) // >40% of display
        #expect(AXCandidateScoring.isPlausibleControlFrame(control, displaySize: displaySize) == true)
        #expect(AXCandidateScoring.isPlausibleControlFrame(container, displaySize: displaySize) == false)
        #expect(AXCandidateScoring.isPlausibleControlFrame(container, displaySize: .zero) == true) // no info ⇒ don't over-decline
    }

    // MARK: - Plato — D2 per-dimension plausibility caps

    // The direct regression: a full-width, thin toolbar is only ~3.4% AREA (sails
    // through the area-only gate) but ~99% WIDTH — the wrong-ring the old logic
    // produced. Must now be rejected by the width cap.
    @Test func wideThingToolbarRejected() {
        let displaySize = CGSize(width: 1512, height: 982)
        let toolbar = CGRect(x: 7, y: 947, width: 1498, height: 34)
        #expect(AXCandidateScoring.isPlausibleControlFrame(toolbar, displaySize: displaySize) == false)
    }

    @Test func tallSidebarRejected() {
        let displaySize = CGSize(width: 1440, height: 900)
        let sidebar = CGRect(x: 0, y: 0, width: 40, height: 900) // full-height thin strip
        #expect(AXCandidateScoring.isPlausibleControlFrame(sidebar, displaySize: displaySize) == false)
    }

    @Test func normalControlAccepted() {
        let displaySize = CGSize(width: 1440, height: 900)
        let control = CGRect(x: 10, y: 10, width: 80, height: 30)
        #expect(AXCandidateScoring.isPlausibleControlFrame(control, displaySize: displaySize) == true)
    }

    @Test func zeroDisplaySizeIsPlausible() {
        let anyContainer = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(AXCandidateScoring.isPlausibleControlFrame(anyContainer, displaySize: .zero) == true)
    }

    // MARK: - Plato — D5b query normalization

    @Test func stripsTrailingRoleWord() {
        #expect(AXCandidateScoring.normalizedControlQuery(from: "download button") == "download")
    }

    @Test func stripsMultipleTrailingRoleWords() {
        #expect(AXCandidateScoring.normalizedControlQuery(from: "save icon button") == "save")
    }

    @Test func stopsAtSingleRoleToken() {
        #expect(AXCandidateScoring.normalizedControlQuery(from: "menu button") == "menu")
        #expect(AXCandidateScoring.normalizedControlQuery(from: "button") == "button")
    }

    @Test func preservesRealNamesWithNonRoleTail() {
        #expect(AXCandidateScoring.normalizedControlQuery(from: "color inspector") == "color inspector")
        #expect(AXCandidateScoring.normalizedControlQuery(from: "frame tool") == "frame tool")
    }

    @Test func normalizedQueryMatchesExactTier() {
        let normalized = AXCandidateScoring.normalizedControlQuery(from: "download button")
        #expect(AXCandidateScoring.matchQuality(of: "Download", forNormalizedQuery: normalized) == .exact)
    }
}
