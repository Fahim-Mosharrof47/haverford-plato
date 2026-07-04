// MARK: - Plato
//
//  PointDirectiveParsing.swift
//  leanring-buddy
//
//  Pure parsing/sanitizing logic for the legacy inline [POINT:x,y:label:screenN]
//  protocol and for resolving which turn screenshot a directive targets.
//  Extracted from CompanionManager so the entire malformed-model-output surface
//  is unit-testable without the app (review findings D-09/D-10/D-11).
//

import CoreGraphics
import Foundation

/// One parsed pointing directive, in screenshot pixel space.
struct ParsedPointDirective {
    let screenshotXInPixels: Int
    let screenshotYInPixels: Int
    let elementLabel: String
    let oneBasedScreenNumber: Int?
}

enum PointDirectiveParser {

    /// Parses the LAST complete [POINT:x,y:label(:screenN)] tag in the response,
    /// or nil for no tag / a malformed payload / an explicit "none". Coordinates
    /// accept integers or floats ("640.5") because the tool path does too — a
    /// float on the fallback path must not silently drop the whole directive.
    static func parse(from responseText: String) -> ParsedPointDirective? {
        guard let regularExpression = try? NSRegularExpression(pattern: #"\[POINT:([^\]]+)\]"#) else {
            return nil
        }

        let fullResponseRange = NSRange(responseText.startIndex..<responseText.endIndex, in: responseText)
        let allMatches = regularExpression.matches(in: responseText, range: fullResponseRange)
        guard let lastPointMatch = allMatches.last,
              lastPointMatch.numberOfRanges > 1,
              let payloadRange = Range(lastPointMatch.range(at: 1), in: responseText) else {
            return nil
        }

        let payload = responseText[payloadRange].trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.caseInsensitiveCompare("none") == .orderedSame {
            return nil
        }

        let payloadSegments = payload
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        guard payloadSegments.count >= 2 else { return nil }

        let coordinateSegment = payloadSegments[0]
        let coordinateComponents = coordinateSegment
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard coordinateComponents.count == 2,
              let screenshotXAsDouble = Double(coordinateComponents[0]),
              let screenshotYAsDouble = Double(coordinateComponents[1]),
              screenshotXAsDouble.isFinite, screenshotYAsDouble.isFinite else {
            return nil
        }
        let screenshotXInPixels = Int(screenshotXAsDouble.rounded())
        let screenshotYInPixels = Int(screenshotYAsDouble.rounded())

        var labelSegments = Array(payloadSegments.dropFirst())
        var oneBasedScreenNumber: Int?
        if let lastSegment = labelSegments.last?.lowercased(),
           lastSegment.hasPrefix("screen"),
           let parsedScreenNumber = Int(lastSegment.replacingOccurrences(of: "screen", with: "")) {
            oneBasedScreenNumber = parsedScreenNumber
            labelSegments.removeLast()
        }

        let elementLabel = labelSegments
            .joined(separator: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !elementLabel.isEmpty else { return nil }

        return ParsedPointDirective(
            screenshotXInPixels: screenshotXInPixels,
            screenshotYInPixels: screenshotYInPixels,
            elementLabel: elementLabel,
            oneBasedScreenNumber: oneBasedScreenNumber
        )
    }

    /// Removes EVERY complete [POINT:...] tag, wherever it appears in the text.
    /// The model emits the tag inline mid-sentence, not only at the end, so an
    /// end-anchored strip leaks protocol metadata into the visible transcript.
    static func stripCompletedPointTags(from text: String) -> String {
        text.replacingOccurrences(
            of: #"\s*\[POINT:[^\]]+\]\s*"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bubble-safe strip while the model is still streaming: removes every
    /// complete tag AND a partially streamed trailing "[POINT:..." fragment.
    static func stripPointTagArtifactsForStreamingBubble(from text: String) -> String {
        let withoutCompleteTags = text.replacingOccurrences(
            of: #"\s*\[POINT:[^\]]+\]\s*"#,
            with: " ",
            options: .regularExpression
        )
        let withoutTrailingFragment = withoutCompleteTags.replacingOccurrences(
            of: #"\s*\[POINT:[^\]]*$"#,
            with: "",
            options: .regularExpression
        )
        return withoutTrailingFragment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Which turn screenshot a directive's coordinates are relative to.
    /// An EXPLICIT screen number that doesn't match a capture returns nil —
    /// mapping another screen's coordinates onto the cursor screen points at
    /// the wrong target, and declining beats mis-pointing. Only a directive
    /// with NO screen number falls back to the cursor screen.
    static func resolveTargetScreenCapture(
        for parsedPointDirective: ParsedPointDirective,
        in screenCaptures: [CompanionScreenCapture]
    ) -> CompanionScreenCapture? {
        guard !screenCaptures.isEmpty else { return nil }

        if let oneBasedScreenNumber = parsedPointDirective.oneBasedScreenNumber {
            let zeroBasedScreenIndex = oneBasedScreenNumber - 1
            guard screenCaptures.indices.contains(zeroBasedScreenIndex) else { return nil }
            return screenCaptures[zeroBasedScreenIndex]
        }

        return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
    }
}
