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
