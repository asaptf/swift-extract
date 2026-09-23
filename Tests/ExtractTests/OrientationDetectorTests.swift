import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import Extract

@Suite("Orientation detector")
struct OrientationDetectorTests {
    @Test("wide high-confidence lines beat tall lines by a large margin")
    func axisScorePrefersWideLines() {
        let wide = [line("INVOICE TOTAL QUANTITY AMOUNT", width: 0.8, height: 0.04, confidence: 1)]
        let tall = [line("INVOICE TOTAL QUANTITY AMOUNT", width: 0.04, height: 0.8, confidence: 1)]
        #expect(OrientationDetector.axisScore(wide) > OrientationDetector.axisScore(tall) * 5)
    }

    /// The scores are the ones measured on a six-page scanned invoice at the probe DPI. The
    /// page fell on its side, and 90° — the turn the old detector picked by guessing from
    /// character order — is the upside-down one. Reading it scores a quarter of the upright
    /// turn, so the only way to get this wrong is not to look.
    @Test(
        "a sideways page is turned the way that actually reads, not the way that was guessed",
        arguments: [
            [0: 97.0, 90: 327.0, 270: 1206.0],
            [0: 137.0, 90: 318.0, 270: 1203.0],
            [0: 110.0, 90: 277.0, 270: 1292.0],
        ]
    )
    func sidewaysPageIsTurnedUpright(scores: [Int: Double]) {
        #expect(OrientationDetector.choose(scores: scores).rotation == 270)
    }

    @Test("an upright page is left alone")
    func uprightPageIsLeftAlone() {
        // Page one of the same invoice: upright reads best by a wide margin.
        #expect(OrientationDetector.choose(scores: [0: 775.0, 90: 71.0, 180: 201.0]).rotation == 0)
    }

    /// The last page of that invoice carries a footer, a faded stamp and little else: 234
    /// upright against 297 upside-down. That is noise, not evidence, and turning the page on
    /// it would have been wrong — so a turn has to read decisively better, not merely better.
    @Test("a weak preference does not turn a page that already reads")
    func weakPreferenceKeepsThePage() {
        let decision = OrientationDetector.choose(scores: [0: 234.0, 90: 20.0, 180: 297.0])
        #expect(decision.rotation == 0)
        #expect(decision.gain < OrientationDetector.decisiveGain)
        #expect(OrientationDetector.choose(scores: [0: 200.0, 180: 400.0]).rotation == 180)
    }

    /// Clean print reads the same upside-down: measured on a synthetic page of invoice rows,
    /// 90° scored 1711 and 270° scored 1728 — a 1% difference, which is no evidence at all.
    /// The page still has to be turned onto the right axis, but the direction is a coin toss
    /// and has to say so.
    @Test("a direction the probe cannot tell apart is marked ambiguous")
    func indistinguishableDirectionIsMarked() {
        let decision = OrientationDetector.choose(scores: [0: 170.0, 90: 1711.0, 180: 169.0, 270: 1728.0])
        #expect(decision.rotation == 270)
        #expect(decision.isAmbiguous, "a 1% difference is not a direction")
        let real = OrientationDetector.choose(scores: [0: 97.0, 90: 327.0, 180: 122.0, 270: 1206.0])
        #expect(!real.isAmbiguous, "3.7x is a direction")
    }

    /// A stack of sheets goes through a scanner the same way round, so a page the probe could
    /// not settle takes its direction from the pages that were sure.
    @Test("an undecidable page follows the pages on its axis that were decisive")
    func ambiguousPageFollowsItsPeers() {
        let decisions = [
            0: OrientationDecision(rotation: 0, gain: 1, margin: 4),
            1: OrientationDecision(rotation: 270, gain: 11, margin: 3.9),
            2: OrientationDecision(rotation: 90, gain: 9, margin: 1.01),
        ]
        let resolved = OrientationDetector.resolve(decisions)
        #expect(resolved[2]?.rotation == 270, "the coin-toss page follows its sideways peer")
        #expect(resolved[1]?.rotation == 270)
        #expect(resolved[0]?.rotation == 0, "an upright page is not dragged onto another axis")
        #expect(resolved[2]?.isAmbiguous == true, "following a peer is not the same as knowing")
    }

    @Test("a page with no confident peer keeps its own reading rather than inventing agreement")
    func loneAmbiguousPageKeepsItsBest() {
        let alone = [0: OrientationDecision(rotation: 90, gain: 9, margin: 1.01)]
        #expect(OrientationDetector.resolve(alone)[0]?.rotation == 90)
        // An upright page says nothing about which way a sideways one fell.
        let mixed = [
            0: OrientationDecision(rotation: 0, gain: 1, margin: 5),
            1: OrientationDecision(rotation: 90, gain: 9, margin: 1.01),
        ]
        #expect(OrientationDetector.resolve(mixed)[1]?.rotation == 90)
    }

    // MARK: - Settling a direction from the lines

    /// The failure measured on 2026-09-23: a clean sheet scanned upside down scores within 1%
    /// either way up and was reported as needing no turn. Vision still read every line of it —
    /// and read every one with its words running backwards, which the scores never look at.
    @Test("a direction the scores cannot tell apart is settled by which way the words run")
    func lineOrderSettlesAnUpsideDownPage() {
        let readings = [
            0: lines(8, .backwards, confidence: 1.0),
            90: lines(8, .sideways, confidence: 1.0),
            180: lines(8, .forwards, confidence: 0.99),
            270: lines(8, .sideways, confidence: 1.0),
        ]
        #expect(OrientationDetector.choose(scores: readings.mapValues(OrientationDetector.axisScore)).rotation == 0)
        let decision = OrientationDetector.choose(readings: readings)
        #expect(decision.rotation == 180)
        #expect(!decision.isAmbiguous, "a page whose every line runs backwards is not a coin toss")
    }

    /// The second measured failure: a sheet fed in sideways, whose two readings along the axis
    /// scored 1711 and 1728. The better-scoring one is the upside-down one.
    @Test("a sideways page is turned the way its words run forwards")
    func lineOrderSettlesASidewaysPage() {
        let readings = [
            0: lines(8, .sideways, confidence: 1.0),
            90: lines(8, .forwards, confidence: 0.99),
            180: lines(8, .sideways, confidence: 1.0),
            270: lines(8, .backwards, confidence: 1.0),
        ]
        let decision = OrientationDetector.choose(readings: readings)
        #expect(decision.rotation == 90)
        #expect(!decision.isAmbiguous)
    }

    /// Every page of the customer's scanned invoice is decided by its scores, and on every one
    /// the lines agree: the upright turn had no line reading backwards. What the scores settle
    /// is still not reopened — a page read one way yesterday is read the same way today, and
    /// extraction accuracy was measured on those turns.
    @Test("a direction the scores already settle is not reopened")
    func decisiveScoresAreKept() {
        let readings = [
            0: lines(8, .backwards, confidence: 1.0),
            180: lines(2, .forwards, confidence: 1.0),
        ]
        let decision = OrientationDetector.choose(readings: readings)
        #expect(decision.rotation == 0)
        #expect(!decision.isAmbiguous)
    }

    @Test("one line is not enough to settle a page")
    func thinEvidenceStaysAmbiguous() {
        let readings = [
            0: lines(1, .backwards, confidence: 1.0) + lines(7, .undecided, confidence: 1.0),
            180: lines(8, .undecided, confidence: 0.99),
        ]
        let decision = OrientationDetector.choose(readings: readings)
        #expect(decision.isAmbiguous)
        #expect(decision.rotation == 0)
    }

    @Test("lines that contradict each other settle nothing")
    func contradictoryEvidenceStaysAmbiguous() {
        let readings = [
            0: lines(4, .forwards, confidence: 1.0) + lines(4, .backwards, confidence: 1.0),
            180: lines(4, .forwards, confidence: 0.99) + lines(4, .backwards, confidence: 0.99),
        ]
        #expect(OrientationDetector.choose(readings: readings).isAmbiguous)
    }

    /// A page its own words settled is as good a witness to how the stack went through the
    /// scanner as a page its scores settled.
    @Test("a page its words settled is a peer the others can follow")
    func settledPageVotes() {
        let settled = OrientationDetector.choose(readings: [
            0: lines(8, .backwards, confidence: 1.0),
            180: lines(8, .forwards, confidence: 0.99),
        ])
        let unsettled = OrientationDecision(rotation: 0, gain: 1, margin: 1.01)
        let resolved = OrientationDetector.resolve([0: settled, 1: unsettled])
        #expect(resolved[0]?.rotation == 180)
        #expect(resolved[1]?.rotation == 180)
    }

    @Test("nothing recognised anywhere leaves the page as it is")
    func emptyStaysUpright() {
        #expect(OrientationDetector.choose(scores: [:]).rotation == 0)
        #expect(OrientationDetector.choose(scores: [0: 0, 90: 0, 180: 0, 270: 0]).rotation == 0)
        // A page only the turned probe could read at all is still turned.
        #expect(OrientationDetector.choose(scores: [0: 0, 90: 500.0, 270: 900.0]).rotation == 270)
    }

    /// The detector must not be able to choose a turn it never rendered: the old one returned
    /// 270° while only ever looking at 0° and 90°.
    @Test("every turn the detector can choose is one it rendered and read")
    func everyChosenTurnWasRead() throws {
        let url = try uprightPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let renderer = RotationTaggingRenderer()
        let ocr = RotationScoringOCR(best: 270)
        let decision = OrientationDetector.choose(
            scores: [:])  // sanity: an empty probe never invents a turn
        #expect(decision.rotation == 0)

        let chosen = OCRAdapter.orientation(page: page, ocr: ocr, renderer: renderer)
        #expect(chosen.rotation == 270)
        #expect(ocr.read.contains(270), "270° was chosen without ever being read")
        #expect(ocr.read.contains(0) && ocr.read.contains(90), "the axis must be probed first")
    }

    private func uprightPDF() throws -> URL {
        let size = CGSize(width: 200, height: 200)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-orient-\(UUID().uuidString).pdf")
        var box = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPage(mediaBox: &box)
        pdf.setFillColor(CGColor(gray: 1, alpha: 1))
        pdf.fill(box)
        pdf.endPage()
        pdf.closePDF()
        try (data as Data).write(to: url)
        return url
    }

    /// `undecided` is a line Vision gave no order for: every word at the same centre.
    private enum Reading { case forwards, backwards, sideways, undecided }

    /// `count` lines of invoice print as Vision returns them for one probe turn.
    private func lines(_ count: Int, _ reading: Reading, confidence: Double) -> [RecognizedLine] {
        (0..<count).map { index in
            let text = "40 40514280752\(index) CN 1,100 53,00"
            let wide = CGRect(x: 0.1, y: 0.1 + CGFloat(index) * 0.05, width: 0.6, height: 0.02)
            switch reading {
            case .forwards:
                return RecognizedLine(
                    text: text, boundingBox: wide, confidence: confidence,
                    characterXs: wordXs(text, from: 0.12, to: 0.66))
            case .backwards:
                return RecognizedLine(
                    text: text, boundingBox: wide, confidence: confidence,
                    characterXs: wordXs(text, from: 0.66, to: 0.12))
            case .undecided:
                return RecognizedLine(
                    text: text, boundingBox: wide, confidence: confidence,
                    characterXs: wordXs(text, from: 0.4, to: 0.4))
            case .sideways:
                return RecognizedLine(
                    text: text, boundingBox: CGRect(x: 0.1 + CGFloat(index) * 0.05, y: 0.1, width: 0.02, height: 0.6),
                    confidence: confidence * 0.3, characterXs: wordXs(text, from: 0.11, to: 0.11))
            }
        }
    }

    private func line(
        _ text: String,
        width: CGFloat = 0.8,
        height: CGFloat = 0.04,
        confidence: Double = 1
    ) -> RecognizedLine {
        RecognizedLine(
            text: text,
            boundingBox: CGRect(x: 0.1, y: 0.2, width: width, height: height),
            confidence: confidence,
            characterXs: []
        )
    }
}

/// Renders a marker whose pixel width names the rotation it was asked for, so the OCR stub
/// can answer per candidate turn.
private struct RotationTaggingRenderer: PDFRendering {
    func render(page: PDFPage, dpi: Double, extraRotation: Int) -> CGImage? {
        let width = max(1, extraRotation + 1)
        let context = CGContext(
            data: nil, width: width, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context?.makeImage()
    }
}

private final class RotationScoringOCR: OCRRecognizing, @unchecked Sendable {
    let best: Int
    private let lock = NSLock()
    private var seen: [Int] = []
    var read: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    init(best: Int) {
        self.best = best
    }

    func recognize(image: CGImage) throws -> [RecognizedLine] {
        let rotation = image.width - 1
        lock.lock()
        seen.append(rotation)
        lock.unlock()
        let text = rotation == best ? String(repeating: "INVOICE LINE ", count: 8) : "x"
        return [
            RecognizedLine(
                text: text,
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.03),
                confidence: 1,
                characterXs: [])
        ]
    }
}
