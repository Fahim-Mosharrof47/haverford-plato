// MARK: - Plato
//
//  ScreenshotTextRecognizer.swift
//  leanring-buddy
//
//  OCRs a captured screenshot (Vision) and matches the model's named text to a
//  bounding box, so "highlight the Methods section" resolves to an exact rect
//  instead of the model guessing pixels. The matcher is pure (operates on
//  [OCRLine]) so it is unit-tested without Vision. Vision boundingBoxes are
//  normalized 0...1, BOTTOM-LEFT origin — the same handedness as displayFrame,
//  so no Y flip is needed downstream (see HighlightGeometry).
//

import Vision
import CoreGraphics

/// One recognized line of text with its Vision-normalized (bottom-left) box.
struct OCRLine {
    let text: String
    let boundingBox: CGRect
}

enum ScreenshotTextRecognizer {
    /// Synchronous and CPU-bound — call OFF the main actor (e.g. Task.detached).
    /// Deployment target macOS 14.2 → classic VNRecognizeTextRequest.
    static func recognizeText(in cgImage: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate          // dense paper text, not live camera
        request.usesLanguageCorrection = true         // cleaner strings → better matching
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let topCandidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(text: topCandidate.string, boundingBox: observation.boundingBox)
        }
    }
}

enum ScreenshotTextMatcher {
    /// Lowercase, strip punctuation, collapse runs of whitespace.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " { return Character(scalar) }
            return " "
        }
        let collapsed = String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed
    }

    /// Outcome of matching the model's query against the OCR lines. `ambiguous`
    /// lets the caller tell the model honestly that the text appears in several
    /// places instead of silently shading whichever line Vision listed first.
    enum MatchResult: Equatable {
        case match(CGRect)
        case ambiguous(matchCount: Int)
        case notFound
    }

    /// Matches the query to a normalized (0...1, bottom-left) box.
    /// Strategy: (1) a single line that contains the query — with duplicate
    /// disambiguation; (2) the shortest contiguous run of lines whose
    /// concatenation contains the query.
    static func matchResult(for query: String, in lines: [OCRLine]) -> MatchResult {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return .notFound }

        // (1) Single-line containment — collect ALL hits so repeated text
        // ("Methods" in the TOC and as the section heading) is disambiguated
        // rather than resolved to whichever line Vision happened to list first.
        let singleLineMatches = lines.filter { normalize($0.text).contains(normalizedQuery) }
        if singleLineMatches.count == 1 {
            return .match(singleLineMatches[0].boundingBox)
        }
        if singleLineMatches.count > 1 {
            // A multi-word query carries enough context to prefer the most
            // prominent occurrence (largest box — headings beat TOC rows). A
            // single word is genuinely ambiguous: decline instead of guessing.
            let queryWordCount = normalizedQuery.split(separator: " ").count
            guard queryWordCount >= 2,
                  let mostProminentMatch = singleLineMatches.max(by: {
                      ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
                  }) else {
                return .ambiguous(matchCount: singleLineMatches.count)
            }
            return .match(mostProminentMatch.boundingBox)
        }

        // (2) Multi-line contiguous span.
        for startIndex in lines.indices {
            var concatenated = normalize(lines[startIndex].text)
            var unionBox = lines[startIndex].boundingBox
            if concatenated.contains(normalizedQuery) { return .match(unionBox) }
            var endIndex = startIndex + 1
            while endIndex < lines.count {
                concatenated += " " + normalize(lines[endIndex].text)
                unionBox = unionBox.union(lines[endIndex].boundingBox)
                if concatenated.contains(normalizedQuery) { return .match(unionBox) }
                // Bound the window so we don't union half the page.
                if concatenated.count > normalizedQuery.count + 240 { break }
                endIndex += 1
            }
        }
        return .notFound
    }

    /// Convenience: the matched box, or nil for both no-match and ambiguous.
    static func bestMatchBoundingBox(for query: String, in lines: [OCRLine]) -> CGRect? {
        if case .match(let boundingBox) = matchResult(for: query, in: lines) {
            return boundingBox
        }
        return nil
    }
}
