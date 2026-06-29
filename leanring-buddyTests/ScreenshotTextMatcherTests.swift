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
}
