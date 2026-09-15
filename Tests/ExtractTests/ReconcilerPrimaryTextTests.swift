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

    /// A line only a later pass saw is not added to the page: that is how the text doubled. It is
    /// recorded against the nearest line the caller's own pass did read, so it is not lost either.
    @Test("a line only a later pass saw stays off the page and is kept as evidence")
    func secondaryOnlyLineIsEvidenceNotText() {
        let reconciled = OCRReconciler.reconcile([
            [block("43 4051428075268 CN 1,285", y: 0.5)],
            [block("43 4051428075268 CN 1,285", y: 0.501), block("1,655 3 Pair 53,00", y: 0.53)],
        ])
        #expect(reconciled.count == 1, "the page keeps the lines the first pass read")
        #expect(reconciled.first?.alternatives.contains("1,655 3 Pair 53,00") == true)
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
