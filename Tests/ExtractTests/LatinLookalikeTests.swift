import CoreGraphics
import Foundation
import Testing

@testable import Extract

/// A Latin-only reader cannot have meant a Cyrillic letter.
///
/// Measured on the customer invoice: the country of origin `KH` came back as `KН` — Latin `K`
/// then U+041D CYRILLIC CAPITAL LETTER EN, drawn identically. It failed the ISO 3166 list, the
/// model dropped the field rather than emit it, and three single-row articles lost their
/// country outright.
@Suite("Letters a Latin-only reader cannot have meant")
struct LatinLookalikeTests {
    @Test("a Cyrillic letter drawn as a Latin one is read as the Latin one")
    func homoglyphsAreNormalised() {
        #expect(LatinLookalikes.normalised("K\u{041D}") == "KH")
        #expect(LatinLookalikes.normalised("\u{0421}N") == "CN")
        #expect(LatinLookalikes.normalised("TR") == "TR")
    }

    @Test("a letter that is not drawn the same is left alone")
    func onlyLookalikesMove() {
        // Ж, Д, Ф and the like have no Latin twin: changing them would change what is on the
        // page, not what was misread.
        #expect(LatinLookalikes.normalised("ЖДФ") == "ЖДФ")
        #expect(LatinLookalikes.normalised("مرحبا") == "مرحبا")
    }

    @Test("only a pass that asked for Latin and nothing else may do this")
    func scriptGate() {
        #expect(LatinLookalikes.onlyLatinRequested(["en-US"]))
        #expect(LatinLookalikes.onlyLatinRequested(["de-DE", "fr-FR"]))
        #expect(!LatinLookalikes.onlyLatinRequested(["en-US", "ar-SA"]))
        #expect(!LatinLookalikes.onlyLatinRequested(["ru-RU"]))
        #expect(!LatinLookalikes.onlyLatinRequested(["el"]))
        // Nothing asked for means the recogniser chose, and what it chose is not known here.
        #expect(!LatinLookalikes.onlyLatinRequested([]))
        // A tag nobody here recognises is not assumed to be Latin.
        #expect(!LatinLookalikes.onlyLatinRequested(["zz"]))
    }

    private func line(_ text: String) -> RecognizedLine {
        RecognizedLine(text: text, boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.01), confidence: 1)
    }

    @Test("an English-only page is cleaned; an Arabic one is not")
    func blocksRespectTheGate() {
        let english = OCRAdapter.blocks(
            from: [line("42 K\u{041D} 1,150")], pageIndex: 0, languages: ["en-US"])
        #expect(english.first?.text == "42 KH 1,150")

        let arabic = OCRAdapter.blocks(
            from: [line("42 K\u{041D} 1,150")], pageIndex: 0, languages: ["ar-SA"])
        #expect(arabic.first?.text == "42 K\u{041D} 1,150")

        let unstated = OCRAdapter.blocks(from: [line("K\u{041D}")], pageIndex: 0)
        #expect(unstated.first?.text == "K\u{041D}")
    }

    @Test("a line that is nothing but whitespace is still dropped")
    func emptyLinesStillGo() {
        #expect(OCRAdapter.blocks(from: [line("   ")], pageIndex: 0, languages: ["en-US"]).isEmpty)
    }
}
