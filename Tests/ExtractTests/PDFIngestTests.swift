import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import Extract

@Suite("PDF ingest")
struct PDFIngestTests {
    @Test("render honours /Rotate by swapping pixel dimensions")
    func renderHonoursRotate() throws {
        let url = try makePDF(text: "X", size: CGSize(width: 200, height: 400))
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let upright = try #require(PDFPageRenderer.render(page: page, dpi: 72, extraRotation: 0))
        #expect(upright.width == 200)
        #expect(upright.height == 400)

        page.rotation = 90
        let rotated = try #require(PDFPageRenderer.render(page: page, dpi: 72, extraRotation: 0))
        #expect(rotated.width == 400)
        #expect(rotated.height == 200)
        #expect(page.rotation == 90)
    }

    @Test("render uses 300 DPI by default and clamps to 400")
    func renderDPI() throws {
        let url = try makePDF(text: "X", size: CGSize(width: 72, height: 144))
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let at300 = try #require(PDFPageRenderer.render(page: page, dpi: 300))
        #expect(at300.width == 300)
        #expect(at300.height == 600)

        let clamped = try #require(PDFPageRenderer.render(page: page, dpi: 800))
        #expect(clamped.width == 400)
        #expect(clamped.height == 800)

        #expect(PDFPageRenderer.clampedDPI(12) == 72)
        #expect(PDFPageRenderer.clampedDPI(300) == 300)
    }

    @Test("extraRotation is applied on top of /Rotate")
    func extraRotationOnTopOfPageRotate() throws {
        let url = try makePDF(text: "X", size: CGSize(width: 200, height: 400))
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        page.rotation = 90
        let image = try #require(PDFPageRenderer.render(page: page, dpi: 72, extraRotation: 90))
        #expect(image.width == 200)
        #expect(image.height == 400)
        #expect(page.rotation == 90)
    }

    @Test("OCR raster is 300 DPI when auto-orient is off")
    func ocrRasterIs300DPI() throws {
        let url = try makePDF(text: "")
        defer { try? FileManager.default.removeItem(at: url) }
        let ocr = RecordingOCR(
            lines: [
                RecognizedLine(
                    text: "SCAN",
                    boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.05),
                    confidence: 1,
                    characterXs: []
                )
            ]
        )
        _ = try PDFAdapter.ingest(
            url: url,
            options: ExtractionOptions(textLayerPolicy: .never, autoOrient: false),
            ocr: ocr
        )
        let size = try #require(ocr.sizes.last)
        #expect(size.width == 2550)
        #expect(size.height == 3300)
    }

    @Test("garbled text layer is sent to OCR")
    func garbledTextLayerUsesOCR() throws {
        let url = try makePDF(text: String(repeating: "~~ @@ ## xx $$ ", count: 40))
        defer { try? FileManager.default.removeItem(at: url) }
        let ocr = RecordingOCR(
            lines: [
                RecognizedLine(
                    text: "FRESH OCR",
                    boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05),
                    confidence: 1,
                    characterXs: []
                )
            ]
        )
        let document = try PDFAdapter.ingest(
            url: url,
            options: ExtractionOptions(autoOrient: false),
            ocr: ocr
        )
        #expect(document.usedOCRFallback)
        #expect(document.fullText.contains("FRESH OCR"))
        #expect(ocr.recognizeCount >= 1)
    }

    @Test("clean digital text layer is kept without OCR")
    func cleanTextLayerSkipsOCR() throws {
        let url = try makePDF(
            text: """
                INVOICE
                Vendor: Acme Supplies Co.
                Total due: 1250.00 USD
                Line: Widget Pro
                """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let ocr = RecordingOCR(lines: [])
        let document = try PDFAdapter.ingest(
            url: url,
            options: .init(),
            ocr: ocr
        )
        #expect(!document.usedOCRFallback)
        #expect(ocr.recognizeCount == 0)
        #expect(document.fullText.contains("Acme Supplies"))
    }

    @Test("auto-orient picks 90° when landscape probe scores higher")
    func autoOrientPicksLandscapeAxis() throws {
        let url = try makePDF(text: "")
        defer { try? FileManager.default.removeItem(at: url) }
        let ocr = AxisScoringOCR()
        let options = ExtractionOptions(
            textLayerPolicy: .never,
            rasterDPI: 72,
            autoOrient: true
        )
        _ = try PDFAdapter.ingest(url: url, options: options, ocr: ocr)
        let last = try #require(ocr.sizes.last)
        #expect(last.width > last.height)
    }

    private func makePDF(text: String, size: CGSize = CGSize(width: 612, height: 792)) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-ingest-\(UUID().uuidString).pdf")
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

final class RecordingOCR: OCRRecognizing, @unchecked Sendable {
    var recognizeCount = 0
    var sizes: [CGSize] = []
    var lines: [RecognizedLine]

    init(lines: [RecognizedLine]) {
        self.lines = lines
    }

    func recognize(image: CGImage) throws -> [RecognizedLine] {
        recognizeCount += 1
        sizes.append(CGSize(width: image.width, height: image.height))
        return lines
    }
}

/// Scores landscape rasters as wide-line text so auto-orient chooses 90°.
final class AxisScoringOCR: OCRRecognizing, @unchecked Sendable {
    var sizes: [CGSize] = []

    func recognize(image: CGImage) throws -> [RecognizedLine] {
        sizes.append(CGSize(width: image.width, height: image.height))
        let landscape = image.width > image.height
        if landscape {
            return [
                RecognizedLine(
                    text: String(repeating: "W", count: 40),
                    boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.05),
                    confidence: 1,
                    characterXs: (0..<40).map { CGFloat($0) / 40 }
                )
            ]
        }
        return [
            RecognizedLine(
                text: "H",
                boundingBox: CGRect(x: 0.4, y: 0.1, width: 0.05, height: 0.8),
                confidence: 1,
                characterXs: [0.4]
            )
        ]
    }
}
