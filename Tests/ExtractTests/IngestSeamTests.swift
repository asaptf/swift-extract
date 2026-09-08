import CoreGraphics
import Extract
import Foundation
import PDFKit
import Testing

@Suite("Ingest engine seam")
struct IngestSeamTests {
    @Test("defaults are the public Vision and PDFKit types")
    func defaultEngines() {
        let context = IngestContext()
        #expect(context.ocr is VisionOCR)
        #expect(context.renderer is PDFKitRenderer)
        _ = VisionOCR()
        _ = PDFKitRenderer()
    }

    @Test("inspect uses an injected OCR and renderer")
    func inspectInjectsEngines() async throws {
        let url = try makeBlankPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let ocr = CountingOCR()
        let renderer = CountingRenderer()
        let inspection = try await Extract.inspect(
            url,
            options: ExtractionOptions(textLayerPolicy: .never, autoOrient: false),
            ingest: IngestContext(ocr: ocr, renderer: renderer)
        )
        #expect(renderer.renderCount >= 1)
        #expect(ocr.recognizeCount >= 1)
        #expect(inspection.usedOCRFallback)
        #expect(inspection.fullText.contains("INJECTED"))
    }

    @Test("from uses injected OCR on an image source")
    func fromInjectsOCRForImage() async throws {
        let image = try #require(solidImage(width: 8, height: 8))
        let ocr = CountingOCR()
        let canned = """
            {"title":"INJECTED","body":"ok"}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [canned]))
        let doc: TinyDoc = try await Extract.from(
            .image(image),
            using: session,
            ingest: IngestContext(ocr: ocr)
        )
        #expect(ocr.recognizeCount == 1)
        #expect(doc.title == "INJECTED")
    }

    private func makeBlankPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-seam-\(UUID().uuidString).pdf")
        let pageRect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let data = NSMutableData()
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw ExtractionError.internalError("Could not create PDF")
        }
        pdfContext.beginPage(mediaBox: &mediaBox)
        pdfContext.setFillColor(CGColor(gray: 1, alpha: 1))
        pdfContext.fill(pageRect)
        pdfContext.endPage()
        pdfContext.closePDF()
        try (data as Data).write(to: url)
        return url
    }
}

private final class CountingOCR: OCRRecognizing, @unchecked Sendable {
    var recognizeCount = 0

    func recognize(image: CGImage) throws -> [RecognizedLine] {
        recognizeCount += 1
        return [
            RecognizedLine(
                text: "INJECTED",
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1),
                confidence: 1
            )
        ]
    }
}

private final class CountingRenderer: PDFRendering, @unchecked Sendable {
    var renderCount = 0

    func render(page: PDFPage, dpi: Double, extraRotation: Int) -> CGImage? {
        renderCount += 1
        return solidImage(width: 16, height: 16)
    }
}

private func solidImage(width: Int, height: Int) -> CGImage? {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    context?.setFillColor(CGColor(gray: 1, alpha: 1))
    context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context?.makeImage()
}
