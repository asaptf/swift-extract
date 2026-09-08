import Foundation
import Testing

@testable import Extract

@Suite("Text layer quality")
struct TextLayerQualityTests {
    @Test("empty text scores zero")
    func emptyIsZero() {
        #expect(TextLayerQuality.score("") == 0)
        #expect(TextLayerQuality.score("   \n") == 0)
    }

    @Test("a clean invoice text layer scores above the default threshold")
    func cleanInvoiceIsHigh() {
        let text = """
            INVOICE
            Vendor: Acme Supplies Co.
            Total due: 1250.00 USD
            Line: Widget Pro
            Quantity 2 Amount 500.00
            """
        let score = TextLayerQuality.score(text)
        #expect(score >= 0.85)
        #expect(
            TextLayerQuality.shouldOCR(text: text, policy: .auto, threshold: 0.85) == false
        )
    }

    @Test("garbled OCR-layer junk scores below the default threshold")
    func garbledIsLow() {
        let text = String(repeating: "~~ @@ ## xx $$ ", count: 40) + "\u{FFFD}\u{FFFD}"
        let score = TextLayerQuality.score(text)
        #expect(score < 0.85)
        #expect(TextLayerQuality.shouldOCR(text: text, policy: .auto, threshold: 0.85))
    }

    @Test("replacement characters cap the score")
    func replacementCapsScore() {
        let text = "INVOICE Vendor Acme Supplies Total 1250.00 \u{FFFD}"
        #expect(TextLayerQuality.score(text) <= 0.3)
    }

    @Test("policy always never OCRs; policy never always OCRs")
    func policies() {
        let clean = "INVOICE Vendor Acme Supplies Co. Total 1250.00 USD"
        let empty = ""
        #expect(TextLayerQuality.shouldOCR(text: clean, policy: .always, threshold: 0.85) == false)
        #expect(TextLayerQuality.shouldOCR(text: empty, policy: .always, threshold: 0.85) == false)
        #expect(TextLayerQuality.shouldOCR(text: clean, policy: .never, threshold: 0.85))
        #expect(TextLayerQuality.shouldOCR(text: empty, policy: .never, threshold: 0.85))
    }
}
