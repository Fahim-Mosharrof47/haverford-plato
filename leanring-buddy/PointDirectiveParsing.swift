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

// MARK: - Plato — lenient point_at_element tool arguments (root-cause report
// cause X1, fix step 2). The label is the ONLY hard requirement: AX name
// search and OCR are coordinate-free, so a missing/malformed pixel guess must
// degrade to coordinate-free resolution instead of declining the attempt.
struct ParsedPointToolArguments: Equatable {
    let elementLabel: String
    /// nil unless BOTH coordinates parsed — a lone axis cannot anchor anything.
    let screenshotXInPixels: Int?
    let screenshotYInPixels: Int?
    let oneBasedScreenNumber: Int?
}

/// Distinguishes the two hard failures so each records its own decline gate.
enum PointToolArgumentsParseResult: Equatable {
    case parsed(ParsedPointToolArguments)
    /// The arguments string was not a JSON object at all.
    case malformedJSON
    /// JSON parsed but there is no non-empty label — nothing to resolve by.
    case missingLabel
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

    // MARK: - Plato — lenient parse of point_at_element's arguments JSON.
    /// Accepts Int or Double for numeric fields (the model emits either). A
    /// missing/unparseable coordinate pair is discarded — NOT fatal — because
    /// the AX name search and OCR resolve by label alone.
    static func parsePointToolArguments(fromJSON argumentsJSON: String) -> PointToolArgumentsParseResult {
        guard let argumentsData = argumentsJSON.data(using: .utf8),
              let parsedObject = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] else {
            return .malformedJSON
        }

        guard let elementLabel = (parsedObject["label"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !elementLabel.isEmpty else {
            return .missingLabel
        }

        func roundedInteger(from value: Any?) -> Int? {
            if let integerValue = value as? Int { return integerValue }
            if let doubleValue = value as? Double, doubleValue.isFinite {
                return Int(doubleValue.rounded())
            }
            return nil
        }

        // Coordinates are kept only as a complete pair — a lone axis is useless.
        var screenshotXInPixels = roundedInteger(from: parsedObject["x"])
        var screenshotYInPixels = roundedInteger(from: parsedObject["y"])
        if screenshotXInPixels == nil || screenshotYInPixels == nil {
            screenshotXInPixels = nil
            screenshotYInPixels = nil
        }

        return .parsed(ParsedPointToolArguments(
            elementLabel: elementLabel,
            screenshotXInPixels: screenshotXInPixels,
            screenshotYInPixels: screenshotYInPixels,
            oneBasedScreenNumber: roundedInteger(from: parsedObject["screen"])
        ))
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
        resolveTargetScreenCapture(
            oneBasedScreenNumber: parsedPointDirective.oneBasedScreenNumber,
            in: screenCaptures
        )
    }

    // MARK: - Plato — screen-number-only overload (fix step 2): the tool path
    // resolves captures before it has a full directive, and COORDINATE mapping
    // must still refuse an explicit-but-wrong screen (nil here) even though the
    // coordinate-free resolvers go on to scan a fallback screen.
    static func resolveTargetScreenCapture(
        oneBasedScreenNumber: Int?,
        in screenCaptures: [CompanionScreenCapture]
    ) -> CompanionScreenCapture? {
        guard !screenCaptures.isEmpty else { return nil }

        if let oneBasedScreenNumber {
            let zeroBasedScreenIndex = oneBasedScreenNumber - 1
            guard screenCaptures.indices.contains(zeroBasedScreenIndex) else { return nil }
            return screenCaptures[zeroBasedScreenIndex]
        }

        return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
    }
}
