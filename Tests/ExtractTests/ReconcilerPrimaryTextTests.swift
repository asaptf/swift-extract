import CoreGraphics
import Foundation
import Testing

@testable import Extract

/// A disagreement is a fact about a line, not a second line.
///
/// Measured on the six-page customer invoice: keeping both readings as blocks put every disputed
/// line into the page text twice — 13 388 characters against 11 769, a first line reading
/// `PIP PIP VISM VISM` — and the model read the doubled page far worse: **84.21%** against
/// **97.38%** for a single pass. The signal has to reach the caller without reaching the prompt.
@Suite("Reconciled text is one reading")
struct ReconcilerPrimaryTextTests {
    private func block(_ text: String, y: CGFloat, page: Int = 0) -> ExtractedDocument.Block {
        ExtractedDocument.Block(
            text: text, pageIndex: page,
            boundingBox: CGRect(x: 0.1, y: y, width: 0.6, height: 0.02))
    }

    @Test("two passes that disagree produce one line, the first pass's")
    func disagreementKeepsThePrimaryReading() {
        let reconciled = OCRReconciler.reconcile([
            [block("ICONIC BLACK LOW S1PL ESD", y: 0.30)],
            [block("ICONIC BLACK LOW SIPLESD", y: 0.302)],
        ])
        #expect(reconciled.count == 1, "a disputed line must not become two lines of page text")
        let line = try? #require(reconciled.first)
        #expect(line?.text == "ICONIC BLACK LOW S1PL ESD", "the first pass is the page the caller asked for")
        #expect(line?.agreement.matchingPasses == 1)
        #expect(line?.agreement.observingPasses == 2)
        #expect(
            line?.alternatives == ["ICONIC BLACK LOW SIPLESD"],
            "the other reading is kept as evidence, off the page")
    }

    @Test("two passes that agree produce one line at full agreement and no alternatives")
    func agreementIsUnanimous() {
        let reconciled = OCRReconciler.reconcile([
            [block("40 4051428124003 CN", y: 0.4)],
            [block("40 4051428124003 CN", y: 0.401)],
        ])
        #expect(reconciled.count == 1)
        #expect(reconciled.first?.agreement.isUnanimous == true)
        #expect(reconciled.first?.alternatives.isEmpty == true)
    }

    /// A reading that sits on top of a line the caller's pass already read is another reading of
    /// it, and stays off the page: both as text doubled the page and cost thirteen points. A
    /// line with nothing under it is a gap, and gaps are what a second pass is for — see
    /// ``ReconcilerGapTests``.
    @Test("a second reading of a line the caller already has stays evidence, not text")
    func secondReadingOfTheSameLineIsEvidence() throws {
        let reconciled = OCRReconciler.reconcile([
            [block("43 4051428075268 CN 1,285", y: 0.5)],
            [block("43 4051428075268 CN 1,285", y: 0.501), block("43 4051428075268 CN 1.285", y: 0.5005)],
        ])
        #expect(reconciled.count == 1, "the page keeps one line where the page has one line")
        #expect(reconciled.first?.alternatives.contains("43 4051428075268 CN 1.285") == true)
    }

    @Test("one pass is exactly what it was before any of this existed")
    func singlePassIsUnchanged() {
        let only = [block("PIP ISM Invoice", y: 0.1), block("Customer No.: 505286", y: 0.13)]
        let reconciled = OCRReconciler.reconcile([only])
        #expect(reconciled.map(\.text) == only.map(\.text))
        #expect(reconciled.allSatisfy { $0.agreement.isUnanimous == true })
        #expect(reconciled.allSatisfy { $0.alternatives.isEmpty })
    }

    @Test("a pass that read nothing cannot lower agreement")
    func emptyPassIsNotAVote() {
        let reconciled = OCRReconciler.reconcile([[block("Total USD 11.771,00", y: 0.2)], []])
        #expect(reconciled.count == 1)
        #expect(reconciled.first?.agreement == OCRAgreement(matchingPasses: 1, observingPasses: 1))
    }
}

/// A gap is not a disagreement.
///
/// macOS 27's text recogniser drops barcodes this scan used to read: one pass finds 75 of the
/// 86 printed, another finds 73 — and their union is 83, because they miss *different* ones.
/// Those eight are not another reading of a line the caller's pass already has; they are lines
/// it has nothing at all for. Keeping them off the page to avoid doubling it would throw away
/// the only thing a second pass is good for.
@Suite("Gaps a later pass fills")
struct ReconcilerGapTests {
    private func block(_ text: String, y: CGFloat) -> ExtractedDocument.Block {
        ExtractedDocument.Block(
            text: text, pageIndex: 0,
            boundingBox: CGRect(x: 0.1, y: y, width: 0.6, height: 0.02))
    }

    @Test("a line the caller's pass did not read at all is added to the page")
    func gapIsFilled() {
        let reconciled = OCRReconciler.reconcile([
            [block("43 CN 1,285 1,655", y: 0.30)],
            [block("43 4051428075268 CN 1,285 1,655", y: 0.302), block("44 4051428124003 CN", y: 0.40)],
        ])
        let texts = reconciled.map(\.text)
        #expect(
            texts.contains("44 4051428124003 CN"),
            "a barcode only the second pass read must reach the page: \(texts)")
        #expect(reconciled.count == 2, "the disputed line stays one line; the missing line is added")
    }

    @Test("the line the passes merely read differently is still one line")
    func disagreementIsStillOneLine() {
        let reconciled = OCRReconciler.reconcile([
            [block("ICONIC BLACK LOW S1PL ESD", y: 0.30)],
            [block("ICONIC BLACK LOW SIPLESD", y: 0.301)],
        ])
        #expect(reconciled.count == 1)
        #expect(reconciled.first?.text == "ICONIC BLACK LOW S1PL ESD")
        #expect(reconciled.first?.alternatives == ["ICONIC BLACK LOW SIPLESD"])
    }

    @Test("a line added from a later pass says it came from one")
    func filledGapIsMarked() {
        let reconciled = OCRReconciler.reconcile([
            [block("first", y: 0.1)],
            [block("first", y: 0.101), block("only the second pass saw this", y: 0.5)],
        ])
        let added = reconciled.first { $0.text == "only the second pass saw this" }
        #expect(added?.agreement == OCRAgreement(matchingPasses: 1, observingPasses: 2))
        #expect(added?.agreement.isUnanimous == false, "one pass out of two is not agreement")
    }
}
