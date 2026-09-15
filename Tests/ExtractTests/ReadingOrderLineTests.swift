import CoreGraphics
import Foundation
import Testing

@testable import Extract

/// A line of a scanned table is one row, and stays one row.
///
/// Measured on the customer invoice: sizes 43 and 44 of article 640542 came out as
/// `|43|` on its own and `|44 1051428063351 TR 1,425 1,795 20 Pair 45,00 900,00 TR 1,470 1,840
/// Pair 45,00 225,00|` — one text line carrying two rows' worth of values, and the model then
/// assigned 43's weights, quantity and amount to 44 and 44's to 45. Eight cells.
///
/// Two things did it. The line's box was grown with `union` as each block joined, so a line
/// that had absorbed a token half a row down was measured as a line and a half tall and
/// swallowed the row below on the next comparison. And "on the same line" is not transitive —
/// a token can share a line with each of two tokens that do not share one with each other — so
/// using it as a sort comparator left the order unspecified.
@Suite("One line is one row")
struct ReadingOrderLineTests {
    /// Three rows of the customer invoice, with the boxes OCR actually produced.
    ///
    /// The one that does the damage is `1051428063351` — a barcode the scanner garbled, boxed
    /// three line-heights tall at `0.0262` where its neighbours are `0.0087`. It overlaps rows
    /// 43 and 44 equally well, so every word of both joined it.
    private func tableBlocks() -> [ExtractedDocument.Block] {
        func block(_ text: String, x: Double, y: Double, w: Double, h: Double)
            -> ExtractedDocument.Block
        {
            ExtractedDocument.Block(
                text: text, pageIndex: 0,
                boundingBox: CGRect(x: x, y: y, width: w, height: h))
        }
        return [
            block("4051428063357", x: 0.2710, y: 0.2951, w: 0.0842, h: 0.0087),
            block("Pair", x: 0.6879, y: 0.2951, w: 0.0246, h: 0.0073),
            block("1,380", x: 0.5031, y: 0.2951, w: 0.0287, h: 0.0073),
            block("5", x: 0.6468, y: 0.2951, w: 0.0103, h: 0.0087),
            block("42", x: 0.1869, y: 0.2951, w: 0.0164, h: 0.0087),
            block("TR", x: 0.4025, y: 0.2951, w: 0.0164, h: 0.0087),

            block("1051428063351", x: 0.2669, y: 0.3038, w: 0.0924, h: 0.0262),
            block("1,425", x: 0.5010, y: 0.3052, w: 0.0308, h: 0.0087),
            block("45,00", x: 0.7413, y: 0.3052, w: 0.0329, h: 0.0087),
            block("1,795", x: 0.5688, y: 0.3067, w: 0.0308, h: 0.0087),
            block("Pair", x: 0.6879, y: 0.3067, w: 0.0246, h: 0.0073),
            block("900,00", x: 0.8768, y: 0.3067, w: 0.0390, h: 0.0073),
            block("43", x: 0.1889, y: 0.3067, w: 0.0123, h: 0.0073),
            block("TR", x: 0.4025, y: 0.3067, w: 0.0164, h: 0.0073),
            block("20", x: 0.6407, y: 0.3067, w: 0.0164, h: 0.0073),

            block("225,00", x: 0.8768, y: 0.3169, w: 0.0390, h: 0.0087),
            block("1,470", x: 0.5010, y: 0.3169, w: 0.0329, h: 0.0102),
            block("45,00", x: 0.7388, y: 0.3170, w: 0.0358, h: 0.0098),
            block("Pair", x: 0.6879, y: 0.3183, w: 0.0246, h: 0.0073),
            block("1,840", x: 0.5667, y: 0.3183, w: 0.0349, h: 0.0073),
            block("44", x: 0.1869, y: 0.3183, w: 0.0164, h: 0.0073),
            block("TR", x: 0.4025, y: 0.3183, w: 0.0164, h: 0.0073),
        ]
    }

    private func lines(_ blocks: [ExtractedDocument.Block]) -> [String] {
        ExtractedDocument(blocks: blocks, sourceDescription: "t")
            .fullText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.hasPrefix("--- Page") && !$0.isEmpty }
    }

    @Test("a row does not swallow the row below it")
    func linesDoNotSnowball() {
        let text = lines(tableBlocks())
        #expect(text.count == 3, "three rows of a table are three lines, got \(text)")
        #expect(text[0] == "42 4051428063357 TR 1,380 5 Pair")
        #expect(text[1] == "43 1051428063351 TR 1,425 1,795 20 Pair 45,00 900,00")
        #expect(text[2] == "44 TR 1,470 1,840 Pair 45,00 225,00")
    }

    @Test("a row reads left to right whatever order its words arrived in")
    func lineIsInReadingOrder() {
        let text = lines(tableBlocks().reversed())
        #expect(text.count == 3)
        #expect(text[1] == "43 1051428063351 TR 1,425 1,795 20 Pair 45,00 900,00")
    }

    @Test("words of one line still join, however they are jittered")
    func jitteredWordsStillJoin() {
        func word(_ text: String, x: Double, y: Double) -> ExtractedDocument.Block {
            ExtractedDocument.Block(
                text: text, pageIndex: 0,
                boundingBox: CGRect(x: x, y: y, width: 0.05, height: 0.009))
        }
        let text = lines([
            word("Acme", x: 0.10, y: 0.2000),
            word("Supplies", x: 0.16, y: 0.2008),
            word("Co.", x: 0.24, y: 0.1994),
        ])
        #expect(text == ["Acme Supplies Co."])
    }

    @Test("a line's height is taken from the page, not from its tallest accident")
    func typicalHeightIsRobust() {
        let blocks = tableBlocks()
        let typical = ExtractedDocument.typicalHeight(of: blocks)
        #expect(typical < 0.011, "one box three times too tall must not set the line height")
        // That tall box is placed by where its text starts, not by its middle.
        let tall = CGRect(x: 0.2669, y: 0.3038, width: 0.0924, height: 0.0262)
        let normal = CGRect(x: 0.1889, y: 0.3067, width: 0.0123, height: 0.0073)
        #expect(
            abs(
                ExtractedDocument.lineAnchor(tall, typical: typical)
                    - ExtractedDocument.lineAnchor(normal, typical: typical)) < 0.008)
    }

    @Test("a page with nothing to measure still has a line height")
    func typicalHeightWithoutGeometry() {
        #expect(ExtractedDocument.typicalHeight(of: []) == 0.008)
    }

    @Test("a page with no geometry is still one block per line")
    func plainTextIsUnchanged() {
        let blocks = [
            ExtractedDocument.Block(text: "first", pageIndex: nil, boundingBox: nil),
            ExtractedDocument.Block(text: "second", pageIndex: nil, boundingBox: nil),
        ]
        #expect(lines(blocks) == ["first", "second"])
    }
}
