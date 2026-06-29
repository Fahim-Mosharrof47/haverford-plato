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

    /// Returns the normalized (0...1, bottom-left) union box of the best match,
    /// or nil if the query isn't confidently found.
    /// Strategy: (1) a single line that contains the query; (2) the shortest
    /// contiguous run of lines whose concatenation contains the query.
    static func bestMatchBoundingBox(for query: String, in lines: [OCRLine]) -> CGRect? {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return nil }

        // (1) Single-line containment.
        if let singleLine = lines.first(where: { normalize($0.text).contains(normalizedQuery) }) {
            return singleLine.boundingBox
        }

        // (2) Multi-line contiguous span.
        for startIndex in lines.indices {
            var concatenated = normalize(lines[startIndex].text)
            var unionBox = lines[startIndex].boundingBox
            if concatenated.contains(normalizedQuery) { return unionBox }
            var endIndex = startIndex + 1
            while endIndex < lines.count {
                concatenated += " " + normalize(lines[endIndex].text)
                unionBox = unionBox.union(lines[endIndex].boundingBox)
                if concatenated.contains(normalizedQuery) { return unionBox }
                // Bound the window so we don't union half the page.
                if concatenated.count > normalizedQuery.count + 240 { break }
                endIndex += 1
            }
        }
        return nil
    }
}
