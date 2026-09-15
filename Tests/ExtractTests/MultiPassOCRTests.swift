import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import Extract

@Suite("Multi-pass OCR")
struct MultiPassOCRTests {
    @Test("one pass produces the same blocks as today's ingest")
    func onePassMatchesToday() throws {
        let url = try makePDF(text: "")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = RecognizedLine(
            text: "S1PL ESD",
            boundingBox: CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.04),
            confidence: 1
        )
        let options = ExtractionOptions(textLayerPolicy: .never, autoOrient: false)
        let today = try PDFAdapter.ingest(
            url: url, options: options, engines: IngestContext(ocr: RecordingOCR(lines: [line])))
        let stillOne = try PDFAdapter.ingest(
            url: url,
            options: options,
            engines: IngestContext(ocr: RecordingOCR(lines: [line]))
        )
        #expect(today.blocks.map(\.text) == stillOne.blocks.map(\.text))
        #expect(today.blocks.map(\.boundingBox) == stillOne.blocks.map(\.boundingBox))
        #expect(today.blocks.map(\.pageIndex) == stillOne.blocks.map(\.pageIndex))
        #expect(stillOne.blocks.count == 1)
        #expect(stillOne.blocks[0].agreement == .unanimous(passes: 1))
    }

    @Test("an additional pass with the same settings is dropped")
    func duplicatePassIsDropped() throws {
        let url = try makePDF(text: "")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = RecognizedLine(
            text: "HELLO",
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.05),
            confidence: 1
        )
        let ocr = RecordingOCR(lines: [line])
        var options = ExtractionOptions(textLayerPolicy: .never, autoOrient: false)
        options.additionalOCRPasses = [
            OCRPass(rasterDPI: options.rasterDPI, usesLanguageCorrection: options.usesLanguageCorrection)
        ]
        let document = try PDFAdapter.ingest(url: url, options: options, engines: IngestContext(ocr: ocr))
        #expect(ocr.recognizeCount == 1)
        #expect(document.blocks.count == 1)
        #expect(document.blocks[0].agreement == .unanimous(passes: 1))
    }

    @Test("two passes that agree produce one block at full agreement")
    func agreeingPassesCollapse() throws {
        let url = try makePDF(text: "")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = RecognizedLine(
            text: "S1PL ESD",
            boundingBox: CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.04),
            confidence: 1
        )
        let ocr = RecordingOCR(lines: [line])
        var options = ExtractionOptions(textLayerPolicy: .never, autoOrient: false)
        options.additionalOCRPasses = [OCRPass(rasterDPI: 400, usesLanguageCorrection: false)]
        let document = try PDFAdapter.ingest(url: url, options: options, engines: IngestContext(ocr: ocr))
        #expect(ocr.recognizeCount == 2)
        #expect(document.blocks.map(\.text) == ["S1PL ESD"])
        #expect(document.blocks[0].agreement == OCRAgreement(matchingPasses: 2, observingPasses: 2))
        #expect(document.blocks[0].agreement.isUnanimous)
    }

    @Test("two passes that disagree keep the caller's reading and mark the line")
    func disagreeingPassesKeepBoth() throws {
        let url = try makePDF(text: "")
        defer { try? FileManager.default.removeItem(at: url) }
        let box = CGRect(x: 0.10, y: 0.20, width: 0.40, height: 0.04)
        let ocr = ScriptedOCR(queue: [
            [
                RecognizedLine(text: "S1PL ESD", boundingBox: box, confidence: 1)
            ],
            [
                RecognizedLine(text: "SIPLESD", boundingBox: box, confidence: 1)
            ],
        ])
        var options = ExtractionOptions(textLayerPolicy: .never, autoOrient: false)
        options.additionalOCRPasses = [OCRPass(rasterDPI: 400, usesLanguageCorrection: false)]
        let document = try PDFAdapter.ingest(url: url, options: options, engines: IngestContext(ocr: ocr))
        // One line of page text — the caller's own pass — with the other reading kept beside
        // it. Both as text doubled the page and cost the model thirteen points of accuracy.
        #expect(document.blocks.count == 1)
        #expect(document.blocks.first?.text == "S1PL ESD")
        #expect(document.blocks.first?.alternatives == ["SIPLESD"])
        for block in document.blocks {
            #expect(block.agreement == OCRAgreement(matchingPasses: 1, observingPasses: 2))
            #expect(!block.agreement.isUnanimous)
        }
    }

    @Test("a pass that returns nothing does not lower agreement")
    func emptyPassIsNotAVote() throws {
        let url = try makePDF(text: "")
        defer { try? FileManager.default.removeItem(at: url) }
        let ocr = ScriptedOCR(queue: [
            [
                RecognizedLine(
                    text: "HELLO",
                    boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.05),
                    confidence: 1
                )
            ],
            [],
        ])
        var options = ExtractionOptions(textLayerPolicy: .never, autoOrient: false)
        options.additionalOCRPasses = [OCRPass(rasterDPI: 400, usesLanguageCorrection: false)]
        let document = try PDFAdapter.ingest(url: url, options: options, engines: IngestContext(ocr: ocr))
        #expect(document.blocks.map(\.text) == ["HELLO"])
        #expect(document.blocks[0].agreement == .unanimous(passes: 1))
    }

    @Test("an empty first pass does not hide a later reading")
    func emptyFirstPassKeepsTheSecond() throws {
        let url = try makePDF(text: "")
        defer { try? FileManager.default.removeItem(at: url) }
        let ocr = ScriptedOCR(queue: [
            [],
            [
                RecognizedLine(
                    text: "HELLO",
                    boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.05),
                    confidence: 1
                )
            ],
        ])
        var options = ExtractionOptions(textLayerPolicy: .never, autoOrient: false)
        options.additionalOCRPasses = [OCRPass(rasterDPI: 400, usesLanguageCorrection: false)]
        let document = try PDFAdapter.ingest(url: url, options: options, engines: IngestContext(ocr: ocr))
        #expect(document.blocks.map(\.text) == ["HELLO"])
        #expect(document.blocks[0].agreement == .unanimous(passes: 1))
    }

    @Test("the same synthetic PDF rasterised at 300 and 400 still pairs")
    func dpiShiftStillPairs() throws {
        let url = try makePDF(text: "S1PL ESD")
        defer { try? FileManager.default.removeItem(at: url) }
        let ocr = DPIOffsetOCR()
        var options = ExtractionOptions(
            textLayerPolicy: .never, rasterDPI: 300, autoOrient: false)
        options.additionalOCRPasses = [OCRPass(rasterDPI: 400, usesLanguageCorrection: false)]
        let document = try PDFAdapter.ingest(url: url, options: options, engines: IngestContext(ocr: ocr))
        #expect(ocr.sizes.count == 2)
        #expect(ocr.sizes[0].width < ocr.sizes[1].width)
        #expect(document.blocks.map(\.text) == ["S1PL ESD"])
        #expect(document.blocks[0].agreement == OCRAgreement(matchingPasses: 2, observingPasses: 2))
    }

    @Test("inspect publishes agreement on positioned blocks")
    func inspectCarriesAgreement() async throws {
        let url = try makePDF(text: "")
        defer { try? FileManager.default.removeItem(at: url) }
        let box = CGRect(x: 0.10, y: 0.20, width: 0.40, height: 0.04)
        let ocr = ScriptedOCR(queue: [
            [RecognizedLine(text: "64039993900", boundingBox: box, confidence: 1)],
            [RecognizedLine(text: "54039993900", boundingBox: box, confidence: 1)],
        ])
        var options = ExtractionOptions(textLayerPolicy: .never, autoOrient: false)
        options.additionalOCRPasses = [OCRPass(rasterDPI: 400, usesLanguageCorrection: false)]
        let inspection = try await Extract.inspect(
            .pdf(url), options: options, ingest: IngestContext(ocr: ocr))
        #expect(inspection.positionedBlocks.map(\.text) == ["64039993900"])
        #expect(inspection.positionedBlocks.count == 1, "a disputed line is one line, not two")
        for block in inspection.positionedBlocks {
            #expect(block.agreement == OCRAgreement(matchingPasses: 1, observingPasses: 2))
        }
    }

    @Test("geometry pairing tolerates a couple of percent of box drift")
    func pairingToleratesDPIDrift() {
        let a = CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.04)
        let b = CGRect(x: 0.115, y: 0.215, width: 0.29, height: 0.045)
        #expect(OCRReconciler.geometryPairs(a, b))
        let otherLine = CGRect(x: 0.10, y: 0.40, width: 0.30, height: 0.04)
        #expect(!OCRReconciler.geometryPairs(a, otherLine))
    }

    private func makePDF(text: String, size: CGSize = CGSize(width: 612, height: 792)) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-multipass-\(UUID().uuidString).pdf")
        let pageRect = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw ExtractionError.internalError("Could not create PDF context")
        }
        pdfContext.beginPage(mediaBox: &mediaBox)
        pdfContext.setFillColor(CGColor(gray: 1, alpha: 1))
        pdfContext.fill(pageRect)
        if !text.isEmpty {
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
            ]
            let attributed = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(
                rect: CGRect(x: 20, y: 20, width: size.width - 40, height: size.height - 40),
                transform: nil
            )
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, pdfContext)
        }
        pdfContext.endPage()
        pdfContext.closePDF()
        try (data as Data).write(to: url)
        return url
    }
}

/// Returns a queued set of lines per `recognize` call, so two passes can disagree.
final class ScriptedOCR: OCRRecognizing, @unchecked Sendable {
    var queue: [[RecognizedLine]]

    init(queue: [[RecognizedLine]]) {
        self.queue = queue
    }

    func recognize(image: CGImage) throws -> [RecognizedLine] {
        try recognize(image: image, languages: [], correctsLanguage: true)
    }

    func recognize(image: CGImage, languages: [String], correctsLanguage: Bool) throws -> [RecognizedLine] {
        if queue.isEmpty { return [] }
        return queue.removeFirst()
    }
}

/// Same text at both DPIs, with the small box drift two rasters of one line produce.
final class DPIOffsetOCR: OCRRecognizing, @unchecked Sendable {
    var sizes: [CGSize] = []

    func recognize(image: CGImage) throws -> [RecognizedLine] {
        try recognize(image: image, languages: [], correctsLanguage: true)
    }

    func recognize(
        image: CGImage, languages: [String], correctsLanguage: Bool
    ) throws -> [RecognizedLine] {
        sizes.append(CGSize(width: image.width, height: image.height))
        let shift: CGFloat = image.width > 3000 ? 0.015 : 0
        return [
            RecognizedLine(
                text: "S1PL ESD",
                boundingBox: CGRect(x: 0.10 + shift, y: 0.20 + shift, width: 0.30, height: 0.04),
                confidence: 1
            )
        ]
    }
}
