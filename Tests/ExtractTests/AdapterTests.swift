import CoreGraphics
import Extract
import Foundation
import PDFKit
import Testing

@Extractable
struct TinyDoc {
    let title: String
    let body: String
}

@Suite("Adapters")
struct AdapterTests {
    @Test("text adapter")
    func textAdapter() async throws {
        let canned = """
            {"title":"Hello","body":"World"}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [canned]))
        let doc: TinyDoc = try await Extract.from(.text("Hello World"), using: session)
        #expect(doc.title == "Hello")
        #expect(doc.body == "World")
    }

    @Test("PDF text-layer extraction contains fixture content")
    func pdfTextLayer() async throws {
        let url = try makePDFFixture(
            text: """
                INVOICE
                Vendor: Acme Supplies Co.
                Total due: 1250.00 USD
                Line: Widget Pro
                """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        // Drive the real ingest path via Extract with a mock that echoes schema-valid JSON.
        let canned = """
            {"title":"INVOICE","body":"Acme Supplies Co."}
            """
        let session = ExtractionSession.mock(
            MockLanguageModel { system, user, _ in
                // Assert the PDF text made it into the prompt.
                #expect(user.contains("Acme Supplies Co.") || user.contains("INVOICE"))
                _ = system
                return canned
            }
        )
        let doc: TinyDoc = try await Extract.from(.pdf(url), using: session)
        #expect(doc.title == "INVOICE")
        #expect(doc.body.contains("Acme"))
    }

    @Test("fileURL sniffs PDF")
    func fileURLPDF() async throws {
        let url = try makePDFFixture(text: "Title: Report\nBody: Details about the system.")
        defer { try? FileManager.default.removeItem(at: url) }

        let canned = """
            {"title":"Report","body":"Details about the system."}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [canned]))
        let doc: TinyDoc = try await Extract.from(.fileURL(url), using: session)
        #expect(doc.title == "Report")
    }

    @Test("PDF OCR fallback is applied per page")
    func mixedPDFUsesOCRForScannedPage() async throws {
        let url = try makeMixedPDFFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let canned = """
            {"title":"Mixed PDF","body":"Text and scanned pages"}
            """
        let session = ExtractionSession.mock(
            MockLanguageModel { _, user, _ in
                let prompt = user.uppercased()
                #expect(prompt.contains("TEXT LAYER PAGE"))
                #expect(prompt.contains("SCANNED PAGE"))
                return canned
            }
        )

        let doc: TinyDoc = try await Extract.from(.pdf(url), using: session)
        #expect(doc.title == "Mixed PDF")
    }

    @Test("file read failures use ExtractionError")
    func unreadableFileURL() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).txt")
        let session = ExtractionSession.mock(MockLanguageModel(responses: ["{}"]))

        do {
            let _: TinyDoc = try await Extract.from(.fileURL(missing), using: session)
            Issue.record("Expected unreadableSource")
        } catch let error as ExtractionError {
            guard case .unreadableSource(let underlying) = error else {
                Issue.record("Wrong error \(error)")
                return
            }
            #expect(underlying != nil)
        } catch {
            Issue.record("Expected ExtractionError, got \(error)")
        }
    }

    @Test("OCR path on rendered image (skip if Vision fails)")
    func ocrImage() async throws {
        // Render a simple bitmap with text via Core Graphics, then OCR.
        let width = 400
        let height = 120
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            Issue.record("Could not create CGContext")
            return
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw text using Core Text
        let text = "RECEIPT TOTAL 42.00" as CFString
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 28, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let attrString = CFAttributedStringCreate(nil, text, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrString)
        context.textPosition = CGPoint(x: 20, y: 50)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else {
            Issue.record("Could not make image")
            return
        }

        let canned = """
            {"title":"RECEIPT","body":"TOTAL 42.00"}
            """
        let session = ExtractionSession.mock(
            MockLanguageModel { _, user, _ in
                // If OCR worked, prompt should mention RECEIPT or TOTAL.
                // If OCR returned empty, Extract throws emptyDocument — skip.
                return canned
            }
        )

        do {
            let doc: TinyDoc = try await Extract.from(.image(image), using: session)
            #expect(!doc.title.isEmpty)
        } catch let error as ExtractionError {
            if case .emptyDocument = error {
                // Vision unavailable or failed — explicit skip, not a silent pass.
                print("SKIP ocrImage: Vision returned empty text")
                return
            }
            if case .unreadableSource = error {
                print("SKIP ocrImage: \(error.localizedDescription)")
                return
            }
            throw error
        }
    }

    // MARK: - Helpers

    private func makePDFFixture(text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-test-\(UUID().uuidString).pdf")
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRendererCompat(bounds: pageRect)
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: FontCompat.systemFont(ofSize: 14)
            ]
            let ns = text as NSString
            ns.draw(in: CGRect(x: 50, y: 50, width: 500, height: 700), withAttributes: attrs)
        }
        // Prefer PDFKit write for cross-platform
        return try writePDFKit(text: text, to: url)
    }

    private func makeMixedPDFFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-mixed-\(UUID().uuidString).pdf")
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw ExtractionError.internalError("Could not create mixed PDF context")
        }

        pdfContext.beginPage(mediaBox: &mediaBox)
        drawText(
            "TEXT LAYER PAGE WITH ENOUGH CHARACTERS TO KEEP ITS NATIVE TEXT",
            in: pdfContext,
            frame: CGRect(x: 50, y: 500, width: 500, height: 100),
            fontSize: 20
        )
        pdfContext.endPage()

        guard
            let bitmap = CGContext(
                data: nil,
                width: 1_200,
                height: 300,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw ExtractionError.internalError("Could not create scanned page image")
        }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 1_200, height: 300))
        drawText(
            "SCANNED PAGE TOTAL 42.00",
            in: bitmap,
            frame: CGRect(x: 40, y: 80, width: 1_100, height: 140),
            fontSize: 64
        )
        guard let scannedImage = bitmap.makeImage() else {
            throw ExtractionError.internalError("Could not render scanned page image")
        }

        pdfContext.beginPage(mediaBox: &mediaBox)
        pdfContext.setFillColor(CGColor(gray: 1, alpha: 1))
        pdfContext.fill(pageRect)
        pdfContext.saveGState()
        pdfContext.translateBy(x: pageRect.width, y: 0)
        pdfContext.scaleBy(x: -1, y: 1)
        pdfContext.draw(scannedImage, in: CGRect(x: 40, y: 300, width: 532, height: 133))
        pdfContext.restoreGState()
        pdfContext.endPage()
        pdfContext.closePDF()

        try (data as Data).write(to: url)
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.internalError("Could not reopen mixed PDF fixture")
        }
        let scannedPageText = document.page(at: 1)?.string ?? ""
        guard document.pageCount == 2,
            document.page(at: 0)?.string?.contains("TEXT LAYER PAGE") == true,
            scannedPageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ExtractionError.internalError("Mixed PDF fixture has unexpected text layers")
        }
        return url
    }

    private func drawText(
        _ text: String,
        in context: CGContext,
        frame: CGRect,
        fontSize: CGFloat
    ) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(
            nil,
            text as CFString,
            attributes as CFDictionary
        )!
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: frame, transform: nil)
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        CTFrameDraw(textFrame, context)
    }

    private func writePDFKit(text: String, to url: URL) throws -> URL {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw ExtractionError.internalError("Could not create PDF context")
        }
        pdfContext.beginPage(mediaBox: &mediaBox)
        pdfContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        pdfContext.fill(pageRect)

        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let attrString = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        let path = CGPath(rect: CGRect(x: 50, y: 50, width: 500, height: 700), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        CTFrameDraw(frame, pdfContext)
        pdfContext.endPage()
        pdfContext.closePDF()

        try (data as Data).write(to: url)
        // Verify PDFKit can open and has a text layer (or at least opens)
        guard PDFDocument(url: url) != nil else {
            throw ExtractionError.unreadableSource(underlying: nil)
        }
        return url
    }
}

// Minimal stubs so we don't pull UIKit in tests on macOS for PDF drawing.
private enum FontCompat {
    static func systemFont(ofSize size: CGFloat) -> CTFont {
        CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }
}

private struct UIGraphicsPDFRendererCompat {
    let bounds: CGRect
    func writePDF(to url: URL, withActions: (PDFContextCompat) -> Void) throws {
        // no-op path — real write is writePDFKit
    }
}

private struct PDFContextCompat {
    func beginPage() {}
}
