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

/// One recognized WORD within a line, with its own Vision-normalized box.
/// Word boxes let a match ring the exact word ("Export") instead of the whole
/// recognized line ("File Export Share") — root-cause report cause C7.
struct OCRWord {
    let text: String
    let boundingBox: CGRect
}

/// One recognized line of text with its Vision-normalized (bottom-left) box.
/// `words` may be empty when per-word geometry was unavailable; matching then
/// falls back to line-level containment.
struct OCRLine {
    let text: String
    let boundingBox: CGRect
    var words: [OCRWord] = []
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
            let lineText = topCandidate.string
            // Per-word geometry via boundingBox(for:) so matches ring the word,
            // not the line (C7), and glyph-text buttons ("FX") are addressable.
            var wordBoxes: [OCRWord] = []
            lineText.enumerateSubstrings(
                in: lineText.startIndex..<lineText.endIndex, options: .byWords
            ) { wordSubstring, wordRange, _, _ in
                guard let wordSubstring,
                      let wordObservation = try? topCandidate.boundingBox(for: wordRange) else { return }
                wordBoxes.append(OCRWord(text: wordSubstring, boundingBox: wordObservation.boundingBox))
            }
            return OCRLine(text: lineText, boundingBox: observation.boundingBox, words: wordBoxes)
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
    /// Strategy: (0) whole-word sequence match using per-word boxes — rings
    /// the exact word(s), not the line (C7); (1) a single line that contains
    /// the query — with duplicate disambiguation; (2) the shortest contiguous
    /// run of lines whose concatenation contains the query.
    static func matchResult(for query: String, in lines: [OCRLine]) -> MatchResult {
        matchResult(for: query, in: lines, allowSubstringMatching: true)
    }

    /// `allowSubstringMatching: false` restricts to whole-word-boundary matches —
    /// the only safe mode for very short queries ("fx"), where substring
    /// containment would land inside unrelated words.
    static func matchResult(for query: String, in lines: [OCRLine],
                            allowSubstringMatching: Bool) -> MatchResult {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return .notFound }

        // (0) Word-boundary pass: every occurrence of the query's token
        // sequence as consecutive whole words, boxed by the union of exactly
        // those words. Same disambiguation semantics as the line pass.
        let queryTokens = normalizedQuery.split(separator: " ").map(String.init)
        let wordOccurrenceBoxes = wordSequenceOccurrenceBoxes(queryTokens: queryTokens, in: lines)
        if wordOccurrenceBoxes.count == 1 {
            return .match(wordOccurrenceBoxes[0])
        }
        if wordOccurrenceBoxes.count > 1 {
            guard queryTokens.count >= 2,
                  let mostProminentBox = wordOccurrenceBoxes.max(by: {
                      ($0.width * $0.height) < ($1.width * $1.height)
                  }) else {
                return .ambiguous(matchCount: wordOccurrenceBoxes.count)
            }
            return .match(mostProminentBox)
        }
        guard allowSubstringMatching else { return .notFound }

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

    // MARK: - Plato — descriptive-label matching for point_at_element (DaVinci
    // "OpenFX panel" incident, 2026-07-07). The tool's labels are DESCRIPTIVE:
    // the model appends words like "panel"/"button"/"icon" that are not
    // literally on screen, so full-phrase containment misses the exact text
    // ("OpenFX") sitting right there. Retry with trailing tokens dropped —
    // the on-screen text is usually the label's PREFIX — bounded so the query
    // never degenerates. highlight_text keeps the exact matcher: its argument
    // IS literal on-screen text.
    /// How many trailing tokens relaxation may drop before giving up.
    private static let maximumDroppedTrailingTokens = 2
    /// Below this length a query may only match on WORD boundaries ("fx" is a
    /// safe whole word but a wildly-matching substring).
    private static let minimumSubstringQueryLength = 3

    static func matchResultForDescriptiveLabel(_ label: String, in lines: [OCRLine]) -> MatchResult {
        let normalizedLabel = normalize(label)
        guard !normalizedLabel.isEmpty else { return .notFound }

        var queryTokens = normalizedLabel.split(separator: " ").map(String.init)
        let minimumTokenCount = max(1, queryTokens.count - maximumDroppedTrailingTokens)

        while true {
            let relaxedQuery = queryTokens.joined(separator: " ")
            let result = matchResult(
                for: relaxedQuery, in: lines,
                allowSubstringMatching: relaxedQuery.count >= minimumSubstringQueryLength
            )
            // A definitive answer (match OR honest ambiguity) ends the search —
            // relaxing an already-ambiguous query can only get more ambiguous.
            if result != .notFound { return result }

            guard queryTokens.count > minimumTokenCount else { return .notFound }
            queryTokens.removeLast()
        }
    }

    /// Every occurrence of `queryTokens` as CONSECUTIVE whole words within a
    /// line, boxed by the union of exactly those words' boxes. Lines without
    /// word geometry contribute nothing (callers fall back to line matching).
    private static func wordSequenceOccurrenceBoxes(
        queryTokens: [String], in lines: [OCRLine]
    ) -> [CGRect] {
        guard !queryTokens.isEmpty else { return [] }
        var occurrenceBoxes: [CGRect] = []
        for line in lines where !line.words.isEmpty {
            // One OCR word may normalize to several tokens ("File/Export");
            // each token keeps its source word's box.
            var lineTokensWithBoxes: [(token: String, box: CGRect)] = []
            for word in line.words {
                for token in normalize(word.text).split(separator: " ") {
                    lineTokensWithBoxes.append((String(token), word.boundingBox))
                }
            }
            guard lineTokensWithBoxes.count >= queryTokens.count else { continue }
            var lineOccurrenceBoxes: [CGRect] = []
            for startIndex in 0...(lineTokensWithBoxes.count - queryTokens.count) {
                var sequenceMatches = true
                for offset in queryTokens.indices
                where lineTokensWithBoxes[startIndex + offset].token != queryTokens[offset] {
                    sequenceMatches = false
                    break
                }
                guard sequenceMatches else { continue }
                var unionBox = lineTokensWithBoxes[startIndex].box
                for offset in 1..<queryTokens.count {
                    unionBox = unionBox.union(lineTokensWithBoxes[startIndex + offset].box)
                }
                lineOccurrenceBoxes.append(unionBox)
            }
            // A single word repeating WITHIN one line collapses to one union
            // occurrence — the pre-word-pass line matcher treated that line as
            // one match, and cross-line repeats are the only real ambiguity.
            if queryTokens.count == 1, lineOccurrenceBoxes.count > 1 {
                let collapsedBox = lineOccurrenceBoxes.dropFirst()
                    .reduce(lineOccurrenceBoxes[0]) { $0.union($1) }
                occurrenceBoxes.append(collapsedBox)
            } else {
                occurrenceBoxes.append(contentsOf: lineOccurrenceBoxes)
            }
        }
        return occurrenceBoxes
    }
}
