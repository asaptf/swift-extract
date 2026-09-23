import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import Extract

/// Which pages were OCR'd, and which were read from their own text layer.
///
/// The gate that decides this already runs per page, but its answer stayed inside ingest:
/// `usedOCRFallback` is one flag for a whole document. A caller adding a text layer to a scan
/// cannot act on one flag — a merged PDF where a digital cover sheet is bound in front of
/// scanned pages would have the cover's real text stamped over a second time, and doubled
/// text is worse than none.
@Suite("Page text source")
struct PageTextSourceTests {
    @Test("a page with a clean text layer is read from the text layer")
    func cleanTextLayer() throws {
        let url = try makePDF(pages: [Self.cleanText])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try PDFAdapter.ingest(
            url: url,
            options: ExtractionOptions(autoOrient: false),
            engines: IngestContext(ocr: PageSourceOCR(lines: ["SCANNED"]))
        )
        #expect(document.pageSources == [0: .textLayer])
        #expect(!document.usedOCRFallback)
    }

    @Test("a page with no text layer is read by OCR")
    func noTextLayer() throws {
        let url = try makePDF(pages: [""])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try PDFAdapter.ingest(
            url: url,
            options: ExtractionOptions(autoOrient: false),
            engines: IngestContext(ocr: PageSourceOCR(lines: ["SCANNED"]))
        )
        #expect(document.pageSources == [0: .ocr])
        #expect(document.usedOCRFallback)
    }

    @Test("a document says which of its pages were OCR'd")
    func mixedDocument() throws {
        let url = try makePDF(pages: [Self.cleanText, "", Self.cleanText])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try PDFAdapter.ingest(
            url: url,
            options: ExtractionOptions(autoOrient: false),
            engines: IngestContext(ocr: PageSourceOCR(lines: ["SCANNED"]))
        )
        #expect(document.pageSources == [0: .textLayer, 1: .ocr, 2: .textLayer])
        // The document-level flag is true for the same document and cannot say which page.
        #expect(document.usedOCRFallback)
    }

    @Test("a page whose OCR read nothing falls back to its text layer, and says so")
    func ocrReadNothing() throws {
        let url = try makePDF(pages: [Self.cleanText])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try PDFAdapter.ingest(
            url: url,
            // `.never` sends the page to OCR however good its text layer is.
            options: ExtractionOptions(textLayerPolicy: .never, autoOrient: false),
            engines: IngestContext(ocr: PageSourceOCR(lines: []))
        )
        // What actually happened, not what was asked for.
        #expect(document.pageSources == [0: .textLayer])
        #expect(!document.usedOCRFallback)
    }

    @Test("a page that yields no text at all is absent")
    func blankPage() throws {
        let url = try makePDF(pages: [""])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try PDFAdapter.ingest(
            url: url,
            options: ExtractionOptions(autoOrient: false),
            engines: IngestContext(ocr: PageSourceOCR(lines: []))
        )
        #expect(document.pageSources.isEmpty)
        #expect(document.blocks.isEmpty)
    }

    @Test("inspect publishes the page sources")
    func inspectPublishes() async throws {
        let url = try makePDF(pages: [Self.cleanText, ""])
        defer { try? FileManager.default.removeItem(at: url) }
        let inspection = try await Extract.inspect(
            url,
            options: ExtractionOptions(autoOrient: false),
            ingest: IngestContext(ocr: PageSourceOCR(lines: ["SCANNED"]))
        )
        #expect(inspection.pageSources == [0: .textLayer, 1: .ocr])
    }

    @Test("an image is page zero, read by OCR")
    func imageSource() async throws {
        let image = try #require(blankImage(width: 64, height: 64))
        let inspection = try await Extract.inspect(
            .image(image),
            options: ExtractionOptions(autoOrient: false),
            ingest: IngestContext(ocr: PageSourceOCR(lines: ["RECEIPT"]))
        )
        #expect(inspection.pageSources == [0: .ocr])
    }

    /// Scores well above the 0.85 gate: every token is a word or a well-formed number.
    private static let cleanText = "Invoice number 2026 total amount 1285.00 EUR payable within thirty days"

    private func makePDF(pages: [String], size: CGSize = CGSize(width: 612, height: 792)) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-page-source-\(UUID().uuidString).pdf")
        let pageRect = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw ExtractionError.internalError("Could not create PDF context")
        }
        for text in pages {
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
        }
        pdfContext.closePDF()
        try (data as Data).write(to: url)
        return url
    }

    private func blankImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(gray: 1, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }
}

/// Reads whatever it was told to read, on every page, so a test decides what OCR "found".
private struct PageSourceOCR: OCRRecognizing {
    let lines: [String]

    func recognize(image: CGImage) throws -> [RecognizedLine] {
        lines.enumerated().map { index, text in
            RecognizedLine(
                text: text,
                boundingBox: CGRect(x: 0.1, y: 0.1 + Double(index) * 0.1, width: 0.5, height: 0.05),
                confidence: 1
            )
        }
    }
}
