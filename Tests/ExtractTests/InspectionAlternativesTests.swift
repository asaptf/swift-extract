import CoreGraphics
import Foundation
import Testing

@testable import Extract

/// A reading another pass disagreed with reaches the caller, without reaching the page.
///
/// Both halves matter. Putting a second pass's readings into the page text doubled the page
/// and cost thirteen points, so they stay out of ``DocumentInspection/fullText``. But keeping
/// them nowhere at all threw away the better reading: measured on the customer invoice, the
/// primary pass reads `63314` and `… FO HRO SRI` where another pass, at the same geometry,
/// reads `633140` and `… FO HRO SR`.
@Suite("What another pass read reaches the caller")
struct InspectionAlternativesTests {
    private func block(
        _ text: String, y: Double, alternatives: [String] = []
    )
        -> ExtractedDocument.Block
    {
        var block = ExtractedDocument.Block(
            text: text, pageIndex: 0,
            boundingBox: CGRect(x: 0.1, y: y, width: 0.3, height: 0.01))
        block.alternatives = alternatives
        return block
    }

    @Test("a positioned block carries what the other passes read")
    func positionedBlockCarriesAlternatives() throws {
        let document = ExtractedDocument(
            blocks: [
                block("63314", y: 0.5, alternatives: ["633140"]),
                block("Colour: 204", y: 0.52),
            ],
            sourceDescription: "t", usedOCRFallback: true)
        // The page text is unchanged by alternatives — that is the point of them being kept
        // apart from it.
        #expect(document.fullText.contains("63314"))
        #expect(!document.fullText.contains("633140"))

        let positioned = document.blocks.compactMap { block -> PositionedBlock? in
            guard let box = block.boundingBox, let page = block.pageIndex else { return nil }
            return PositionedBlock(
                text: block.text, pageIndex: page, boundingBox: box,
                agreement: block.agreement, alternatives: block.alternatives)
        }
        #expect(positioned.first?.alternatives == ["633140"])
        #expect(positioned.last?.alternatives.isEmpty == true)
    }

    @Test("a block nobody disagreed with has nothing to offer")
    func noAlternativesByDefault() {
        let plain = PositionedBlock(
            text: "633140", pageIndex: 0, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(plain.alternatives.isEmpty)
    }
}
