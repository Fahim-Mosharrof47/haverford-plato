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
    static func bestCandidate(
        among candidates: [AXControlCandidate],
        normalizedQuery: String,
        approximatePoint: CGPoint?,
        visibleScreenFrames: [CGRect]
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
