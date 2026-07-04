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
}
