// MARK: - Plato
import Testing
import CoreGraphics
@testable import leanring_buddy

struct ScreenshotTextMatcherTests {

    private func line(_ text: String, _ box: CGRect) -> OCRLine { OCRLine(text: text, boundingBox: box) }

    @Test func normalizeLowercasesAndCollapses() {
        #expect(ScreenshotTextMatcher.normalize("  Methods,  Section! ") == "methods section")
    }

    @Test func singleLineSubstringMatchReturnsItsBox() {
        let lines = [
            line("Introduction", CGRect(x: 0.1, y: 0.9, width: 0.3, height: 0.03)),
            line("3. Methods", CGRect(x: 0.1, y: 0.6, width: 0.25, height: 0.03)),
            line("Results", CGRect(x: 0.1, y: 0.3, width: 0.2, height: 0.03)),
        ]
        // Returned box is an unchanged input box, so exact equality is safe here.
        #expect(ScreenshotTextMatcher.bestMatchBoundingBox(for: "Methods", in: lines)
                == CGRect(x: 0.1, y: 0.6, width: 0.25, height: 0.03))
    }

    @Test func multiLineSpanUnionsBoxes() {
        let lines = [
            line("We measured the dependent", CGRect(x: 0.1, y: 0.50, width: 0.4, height: 0.03)),
            line("variable across conditions.", CGRect(x: 0.1, y: 0.46, width: 0.4, height: 0.03)),
        ]
        let box = ScreenshotTextMatcher.bestMatchBoundingBox(for: "dependent variable across conditions", in: lines)
        // .union does float arithmetic, so compare with tolerance (exact == would be flaky).
        #expect(box != nil)
        if let box {
            #expect(abs(box.minX - 0.1) < 0.0001)
            #expect(abs(box.minY - 0.46) < 0.0001)
            #expect(abs(box.width - 0.4) < 0.0001)
            #expect(abs(box.height - 0.07) < 0.0001)
        }
    }

    @Test func noMatchReturnsNil() {
        let lines = [line("Conclusion", CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.03))]
        #expect(ScreenshotTextMatcher.bestMatchBoundingBox(for: "appendix", in: lines) == nil)
    }

    // MARK: - Duplicate-match disambiguation (review finding D-15)

    // A single-word query appearing in several lines (TOC row AND the section
    // heading) is genuinely ambiguous — decline instead of shading whichever
    // line Vision listed first.
    @Test func singleWordQueryWithMultipleMatchesIsAmbiguous() {
        let lines = [
            line("3. Methods ........ 4", CGRect(x: 0.1, y: 0.8, width: 0.30, height: 0.02)),
            line("Methods", CGRect(x: 0.1, y: 0.4, width: 0.25, height: 0.04)),
        ]
        #expect(ScreenshotTextMatcher.matchResult(for: "Methods", in: lines)
                == .ambiguous(matchCount: 2))
        #expect(ScreenshotTextMatcher.bestMatchBoundingBox(for: "Methods", in: lines) == nil)
    }

    // A multi-word query carries enough context: prefer the most prominent
    // (largest-box) occurrence — headings beat TOC rows.
    @Test func multiWordQueryWithMultipleMatchesPicksLargestBox() {
        let tocBox = CGRect(x: 0.1, y: 0.8, width: 0.30, height: 0.02)
        let headingBox = CGRect(x: 0.1, y: 0.4, width: 0.40, height: 0.05)
        let lines = [
            line("2. Related Work ........ 3", tocBox),
            line("Related Work", headingBox),
        ]
        #expect(ScreenshotTextMatcher.matchResult(for: "Related Work", in: lines) == .match(headingBox))
    }

    @Test func uniqueMatchStillResolvesDirectly() {
        let onlyBox = CGRect(x: 0.1, y: 0.6, width: 0.25, height: 0.03)
        let lines = [
            line("Introduction", CGRect(x: 0.1, y: 0.9, width: 0.3, height: 0.03)),
            line("3. Methods", onlyBox),
        ]
        #expect(ScreenshotTextMatcher.matchResult(for: "Methods", in: lines) == .match(onlyBox))
    }

    @Test func matchResultReportsNotFound() {
        let lines = [line("Conclusion", CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.03))]
        #expect(ScreenshotTextMatcher.matchResult(for: "appendix", in: lines) == .notFound)
    }

    // MARK: - Descriptive-label relaxation (DaVinci "OpenFX panel" incident,
    // 2026-07-07). point_at_element labels are DESCRIPTIVE — the model appends
    // words like "panel"/"button" that are not literally on screen — so a
    // full-phrase miss retries with trailing tokens dropped (longest matching
    // prefix wins, bounded so the query never degenerates).

    @Test func descriptiveLabelMatchesByDroppingTrailingToken() {
        let openFXBox = CGRect(x: 0.85, y: 0.95, width: 0.06, height: 0.02)
        let lines = [
            line("Color", CGRect(x: 0.1, y: 0.95, width: 0.05, height: 0.02)),
            line("OpenFX", openFXBox),
        ]
        #expect(ScreenshotTextMatcher.matchResultForDescriptiveLabel("OpenFX panel", in: lines)
                == .match(openFXBox))
    }

    @Test func descriptiveLabelPrefersTheFullPhraseWhenItExists() {
        let fullBox = CGRect(x: 0.2, y: 0.5, width: 0.3, height: 0.03)
        let prefixBox = CGRect(x: 0.2, y: 0.8, width: 0.2, height: 0.03)
        let lines = [
            line("Export", prefixBox),
            line("Export Settings", fullBox),
        ]
        // "Export Settings" contains the full query — no relaxation happens.
        #expect(ScreenshotTextMatcher.matchResultForDescriptiveLabel("Export Settings", in: lines)
                == .match(fullBox))
    }

    @Test func descriptiveLabelRelaxationStopsAtAmbiguity() {
        // Relaxing "Methods button" → "Methods" hits two lines: surface the
        // honest ambiguity instead of guessing.
        let lines = [
            line("3. Methods ........ 4", CGRect(x: 0.1, y: 0.8, width: 0.30, height: 0.02)),
            line("Methods", CGRect(x: 0.1, y: 0.4, width: 0.25, height: 0.04)),
        ]
        #expect(ScreenshotTextMatcher.matchResultForDescriptiveLabel("Methods button", in: lines)
                == .ambiguous(matchCount: 2))
    }

    @Test func descriptiveLabelRelaxationDropsAtMostTwoTokens() {
        let lines = [line("Export", CGRect(x: 0.2, y: 0.8, width: 0.2, height: 0.03))]
        // Would need to drop 3 tokens to reach "export" — out of bounds.
        #expect(ScreenshotTextMatcher.matchResultForDescriptiveLabel(
            "export as new file now", in: lines) == .notFound)
    }

    @Test func descriptiveLabelRelaxationRefusesDegenerateShortQueries() {
        // A sub-3-character relaxed query may only match on WORD boundaries —
        // never by substring ("x" is inside every line containing the letter).
        let lines = [line("Extras", CGRect(x: 0.2, y: 0.8, width: 0.2, height: 0.03))]
        #expect(ScreenshotTextMatcher.matchResultForDescriptiveLabel("x panel", in: lines)
                == .notFound)
    }

    // MARK: - Word-boundary matching (root-cause report C7 + icon-glyph
    // buttons like DaVinci's "FX"). When Vision word boxes are available, a
    // match rings the exact WORD(s), not the whole recognized line, and short
    // glyph text ("FX") is matchable safely because word-boundary equality
    // cannot land inside an unrelated word.

    private func wordedLine(_ text: String, _ box: CGRect, _ words: [(String, CGRect)]) -> OCRLine {
        OCRLine(text: text, boundingBox: box,
                words: words.map { OCRWord(text: $0.0, boundingBox: $0.1) })
    }

    @Test func wordLevelMatchRingsTheWordNotTheLine() {
        let exportWordBox = CGRect(x: 0.40, y: 0.9, width: 0.06, height: 0.02)
        let lines = [wordedLine("File Export Share", CGRect(x: 0.1, y: 0.9, width: 0.5, height: 0.02), [
            ("File", CGRect(x: 0.10, y: 0.9, width: 0.05, height: 0.02)),
            ("Export", exportWordBox),
            ("Share", CGRect(x: 0.55, y: 0.9, width: 0.05, height: 0.02)),
        ])]
        #expect(ScreenshotTextMatcher.matchResult(for: "Export", in: lines) == .match(exportWordBox))
    }

    @Test func consecutiveWordSequenceUnionsOnlyThoseWordBoxes() {
        let effectsBox = CGRect(x: 0.10, y: 0.9, width: 0.07, height: 0.02)
        let libraryBox = CGRect(x: 0.18, y: 0.9, width: 0.07, height: 0.02)
        let lines = [wordedLine("Effects Library Edit Index", CGRect(x: 0.1, y: 0.9, width: 0.4, height: 0.02), [
            ("Effects", effectsBox), ("Library", libraryBox),
            ("Edit", CGRect(x: 0.26, y: 0.9, width: 0.05, height: 0.02)),
            ("Index", CGRect(x: 0.32, y: 0.9, width: 0.05, height: 0.02)),
        ])]
        #expect(ScreenshotTextMatcher.matchResult(for: "Effects Library", in: lines)
                == .match(effectsBox.union(libraryBox)))
    }

    @Test func shortGlyphLabelResolvesViaWordBoundaryMatch() {
        // The DaVinci case: an icon-only button whose glyph OCRs as the word
        // "FX". The model's descriptive label "FX icon" relaxes to "fx" —
        // allowed because word-boundary equality is safe at any length.
        let fxBox = CGRect(x: 0.85, y: 0.95, width: 0.03, height: 0.02)
        let lines = [wordedLine("Color FX Fusion", CGRect(x: 0.7, y: 0.95, width: 0.25, height: 0.02), [
            ("Color", CGRect(x: 0.70, y: 0.95, width: 0.06, height: 0.02)),
            ("FX", fxBox),
            ("Fusion", CGRect(x: 0.90, y: 0.95, width: 0.06, height: 0.02)),
        ])]
        #expect(ScreenshotTextMatcher.matchResultForDescriptiveLabel("FX icon", in: lines)
                == .match(fxBox))
    }

    @Test func shortQueriesNeverMatchInsideOtherWords() {
        // "ex" is a substring of "Export" but not a word — must not match.
        let lines = [wordedLine("Export", CGRect(x: 0.2, y: 0.8, width: 0.2, height: 0.03), [
            ("Export", CGRect(x: 0.2, y: 0.8, width: 0.2, height: 0.03)),
        ])]
        #expect(ScreenshotTextMatcher.matchResultForDescriptiveLabel("ex panel", in: lines)
                == .notFound)
    }

    @Test func repeatedWordWithinOneLineCollapsesToOneMatch() {
        // Pre-word-pass behavior: a single word repeating inside ONE line still
        // highlighted that line. Keep that contract — same-line repeats collapse
        // to one union match; only cross-line repeats are genuinely ambiguous.
        let firstTheBox = CGRect(x: 0.10, y: 0.5, width: 0.03, height: 0.02)
        let secondTheBox = CGRect(x: 0.30, y: 0.5, width: 0.03, height: 0.02)
        let lines = [wordedLine("the cat and the dog", CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.02), [
            ("the", firstTheBox),
            ("cat", CGRect(x: 0.14, y: 0.5, width: 0.04, height: 0.02)),
            ("and", CGRect(x: 0.20, y: 0.5, width: 0.04, height: 0.02)),
            ("the", secondTheBox),
            ("dog", CGRect(x: 0.35, y: 0.5, width: 0.04, height: 0.02)),
        ])]
        #expect(ScreenshotTextMatcher.matchResult(for: "the", in: lines)
                == .match(firstTheBox.union(secondTheBox)))
    }

    @Test func duplicateShortGlyphWordsAreAmbiguous() {
        let lines = [
            wordedLine("FX", CGRect(x: 0.2, y: 0.9, width: 0.03, height: 0.02),
                       [("FX", CGRect(x: 0.2, y: 0.9, width: 0.03, height: 0.02))]),
            wordedLine("FX", CGRect(x: 0.6, y: 0.5, width: 0.03, height: 0.02),
                       [("FX", CGRect(x: 0.6, y: 0.5, width: 0.03, height: 0.02))]),
        ]
        #expect(ScreenshotTextMatcher.matchResultForDescriptiveLabel("FX icon", in: lines)
                == .ambiguous(matchCount: 2))
    }
}
