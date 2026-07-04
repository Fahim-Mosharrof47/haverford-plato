// MARK: - Plato
//
//  AXCandidateScoring.swift
//  leanring-buddy
//
//  Pure ranking for Accessibility label matches. AXElementResolver collects ALL
//  controls whose title/description/help contains the query, then this picks the
//  one to ring — or declines when the choice is genuinely ambiguous. Wrong-target
//  pointing is worse than no pointing, so a tie the model's approximate point
//  can't break returns nil (the caller falls back to its secondary strategy).
//  Pure so it is unit-tested without a live AX tree (review finding D-01).
//

import CoreGraphics
import Foundation

/// One AX control whose accessible text matched the query.
struct AXControlCandidate: Equatable {
    /// The AX title/description/help string that contained the query.
    let matchedText: String
    /// The control's frame in global AppKit coordinates (bottom-left origin).
    let globalFrame: CGRect
}

enum AXCandidateScoring {

    /// How specifically a candidate's text matches the query. Higher is better.
    enum MatchQuality: Int, Comparable {
        case substring = 1
        case prefix = 2
        case exact = 3

        static func < (lhs: MatchQuality, rhs: MatchQuality) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// When two same-quality candidates compete, the nearer one must beat the
    /// other by at least this many points, or the match is declared ambiguous.
    static let ambiguityDistanceMarginInPoints: CGFloat = 40

    // MARK: - Plato — hit-test plausibility

    /// Largest fraction of a display a hit-tested element may cover and still be
    /// treated as a pointable CONTROL. Above this it is almost certainly a
    /// container (web content area, window body, scroll view); ringing that
    /// points confidently at nothing, so the caller declines instead.
    static let maxHitTestControlAreaFraction: CGFloat = 0.4

    /// True when `frame` is small enough (relative to its display) to be a real
    /// control rather than a container. `displayArea <= 0` ⇒ treat as plausible
    /// (no display info to judge against — do not over-decline).
    static func isPlausibleControlFrame(_ frame: CGRect, displayArea: CGFloat) -> Bool {
        guard displayArea > 0 else { return true }
        return (frame.width * frame.height) <= displayArea * maxHitTestControlAreaFraction
    }

    static func matchQuality(of matchedText: String, forNormalizedQuery normalizedQuery: String) -> MatchQuality? {
        let normalizedText = matchedText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedText.contains(normalizedQuery) else { return nil }
        if normalizedText == normalizedQuery { return .exact }
        if normalizedText.hasPrefix(normalizedQuery) { return .prefix }
        return .substring
    }

    /// Picks the best candidate for the query, or nil when nothing qualifies or
    /// the best two are too close to call. Rules, in order:
    ///  1. Off-screen candidates are dropped (frame must intersect a real screen —
    ///     an element AX still reports for a closed window/minimized state must
    ///     never be ringed).
    ///  2. Exact-title match beats prefix match beats substring match.
    ///  3. Same quality: nearest to the model's approximate point wins, but only
    ///     when it is decisively nearer (ambiguityDistanceMarginInPoints);
    ///     otherwise decline — two equally plausible "Save" buttons means we
    ///     don't know which one the model meant.
    /// `maxDistanceForInexactMatch`: when non-nil AND an approximate point is
    /// available, a prefix/substring winner farther than this from the model's
    /// hinted point is DECLINED (nil) instead of ringed — a weak name match on
    /// the far side of the screen is probably a different control that merely
    /// shares a word. Exact-title matches bypass the gate (strong evidence).
    /// The distance is passed in (not computed here) so this stays pure/testable;
    /// the caller derives it from the actual display size (dimension-agnostic).
    static func bestCandidate(
        among candidates: [AXControlCandidate],
        normalizedQuery: String,
        approximatePoint: CGPoint?,
        visibleScreenFrames: [CGRect],
        maxDistanceForInexactMatch: CGFloat? = nil
    ) -> AXControlCandidate? {
        let scoredOnScreenCandidates: [(candidate: AXControlCandidate, quality: MatchQuality, distance: CGFloat)] =
            candidates.compactMap { candidate in
                guard !candidate.globalFrame.isEmpty,
                      visibleScreenFrames.contains(where: { $0.intersects(candidate.globalFrame) }),
                      let quality = matchQuality(of: candidate.matchedText, forNormalizedQuery: normalizedQuery) else {
                    return nil
                }
                let distance: CGFloat
                if let approximatePoint {
                    distance = hypot(
                        candidate.globalFrame.midX - approximatePoint.x,
                        candidate.globalFrame.midY - approximatePoint.y
                    )
                } else {
                    distance = 0
                }
                return (candidate, quality, distance)
            }

        let rankedCandidates = scoredOnScreenCandidates.sorted { first, second in
            if first.quality != second.quality { return first.quality > second.quality }
            return first.distance < second.distance
        }

        guard let bestRankedCandidate = rankedCandidates.first else { return nil }

        // MARK: - Plato — spatial sanity gate for weak (non-exact) matches.
        // A prefix/substring winner far from the model's hint is probably a
        // different control that merely shares a word; decline rather than ring
        // it. Exact-title matches bypass the gate (strong evidence). The gate is
        // skipped when no approximate point exists (distance would be a
        // meaningless 0) or no limit was supplied (back-compatible callers).
        if bestRankedCandidate.quality != .exact,
           approximatePoint != nil,
           let maxDistanceForInexactMatch,
           bestRankedCandidate.distance > maxDistanceForInexactMatch {
            return nil
        }

        if rankedCandidates.count == 1 { return bestRankedCandidate.candidate }

        let runnerUpCandidate = rankedCandidates[1]
        // A strictly better match quality is decisive on its own.
        if bestRankedCandidate.quality > runnerUpCandidate.quality {
            return bestRankedCandidate.candidate
        }
        // Same quality: require the approximate point to break the tie decisively.
        guard approximatePoint != nil,
              runnerUpCandidate.distance - bestRankedCandidate.distance >= ambiguityDistanceMarginInPoints else {
            return nil
        }
        return bestRankedCandidate.candidate
    }
}
