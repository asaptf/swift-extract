import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import Extract

/// A scan fed sideways into the scanner is a landscape page with `/Rotate = 0` and its
/// content lying on its side. Vision reads such a page at **both** 90° and 270° — the text
/// comes back legible either way — so a detector that only renders one of them and guesses
/// the other from character order is guessing with no signal. Measured on a six-page customer
/// invoice: the upright turn scored about four times the upside-down one, and the guess went
/// the wrong way on every sideways page, which put the footer first and cost the whole table.
@Suite("Sideways pages")
struct SidewaysPageTests {
    static let header = "HEADER INVOICE NUMBER VR1493952"
    static let footer = "FOOTER LINE"

    @Test(
        "a page whose content lies on its side is read from its top, not its footer",
        arguments: [true, false]
    )
    func sidewaysPageIsReadUpright(clockwise: Bool) throws {
        let url = try makeSidewaysPDF(clockwise: clockwise)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        #expect(page.rotation == 0, "the fixture carries no /Rotate — the content itself is sideways")

        let decided = OCRAdapter.detectOrientation(page: page, ocr: VisionOCR(), renderer: PDFKitRenderer())
        #expect(decided != 0, "a sideways page has to be turned")

        var options = ExtractionOptions()
        options.textLayerPolicy = .never
        let blocks = try OCRAdapter.ocrPDFPage(
            page, pageIndex: 0, options: options, ocr: VisionOCR(), renderer: PDFKitRenderer())
        let texts = blocks.map { $0.text.uppercased() }
        let headerIndex = try #require(texts.firstIndex { $0.contains("HEADER") }, "header not read: \(texts)")
        let footerIndex = try #require(texts.firstIndex { $0.contains("FOOTER") }, "footer not read: \(texts)")
        #expect(headerIndex < footerIndex, "read bottom-first — the page was turned the wrong way: \(texts)")

        let headerBox = try #require(blocks[headerIndex].boundingBox)
        #expect(headerBox.midY < 0.5, "the header came back in the lower half at midY \(headerBox.midY)")
    }

    /// An upright page, rasterised with scan-like grain and then turned a quarter turn —
    /// which is what a sheet fed sideways into a scanner actually is: an image, not text.
    /// The grain matters. On clean vector text Vision reads an upside-down page far worse
    /// than an upright one, so the orientation lands right by luck; on a grainy scan of
    /// dense small print it reads both ways almost equally well, and that is where a
    /// detector that never renders the fourth quarter turn has to guess.
    private func makeSidewaysPDF(clockwise: Bool) throws -> URL {
        let upright = try makeUprightPDF()
        defer { try? FileManager.default.removeItem(at: upright) }
        let document = try #require(PDFDocument(url: upright))
        let page = try #require(document.page(at: 0))
        let media = page.bounds(for: .mediaBox)
        let scan = try #require(scanned(page: page, media: media))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-sideways-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: media.height, height: media.width)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)
        else {
            throw ExtractionError.internalError("Could not create PDF context")
        }
        pdf.beginPage(mediaBox: &box)
        pdf.setFillColor(CGColor(gray: 1, alpha: 1))
        pdf.fill(box)
        pdf.saveGState()
        if clockwise {
            pdf.translateBy(x: 0, y: media.width)
            pdf.rotate(by: -.pi / 2)
        } else {
            pdf.translateBy(x: media.height, y: 0)
            pdf.rotate(by: .pi / 2)
        }
        pdf.draw(scan, in: media)
        pdf.restoreGState()
        pdf.endPage()
        pdf.closePDF()
        try (data as Data).write(to: url)
        return url
    }

    /// The page as a scanner would hand it over: a greyscale bitmap with speckle.
    private func scanned(page: PDFPage, media: CGRect) -> CGImage? {
        let scale: CGFloat = 150.0 / 72.0
        let width = Int(media.width * scale)
        let height = Int(media.height * scale)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let pixels = context.data else { return context.makeImage() }
        var generator = SystemRandomNumberGenerator()
        let bytes = pixels.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        for index in stride(from: 0, to: context.bytesPerRow * height, by: 4) {
            let noise = Int(UInt8.random(in: 0...60, using: &generator)) - 30
            for channel in 0..<3 {
                bytes[index + channel] = UInt8(clamping: Int(bytes[index + channel]) + noise)
            }
        }
        return context.makeImage()
    }

    /// Dense small print, not two big lines: Vision reads a sparse page badly when it is
    /// upside-down, which hides the bug. A page of invoice rows it reads almost as well
    /// either way round — that is the condition under which the old detector guessed.
    private func makeUprightPDF() throws -> URL {
        let size = CGSize(width: 612, height: 792)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-upright-\(UUID().uuidString).pdf")
        var box = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)
        else {
            throw ExtractionError.internalError("Could not create PDF context")
        }
        pdf.beginPage(mediaBox: &box)
        pdf.setFillColor(CGColor(gray: 1, alpha: 1))
        pdf.fill(box)
        draw(Self.header, at: CGPoint(x: 50, y: size.height - 70), size: 14, in: pdf)
        for row in 0..<34 {
            let text = String(
                format: "%2d  40514280%05d  CN  1,%03d  1,%03d  %d  Pair  53,00  159,00",
                40 + row % 8, 75268 + row, 100 + row * 7, 400 + row * 9, 1 + row % 9)
            draw(text, at: CGPoint(x: 50, y: size.height - 110 - CGFloat(row) * 18), size: 9, in: pdf)
        }
        draw(Self.footer, at: CGPoint(x: 50, y: 60), size: 12, in: pdf)
        pdf.endPage()
        pdf.closePDF()
        try (data as Data).write(to: url)
        return url
    }

    private func draw(_ text: String, at point: CGPoint, size: CGFloat = 30, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
}
