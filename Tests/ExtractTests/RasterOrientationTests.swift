import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import Extract

/// The rasteriser's own output, read back by Vision.
///
/// Pixel-dimension assertions cannot see a vertical flip or a mirror — both preserve
/// width and height. Only reading the page back catches those, so this suite renders a
/// known single line and checks both *what* Vision reads and *where* it sits.
@Suite("Raster orientation")
struct RasterOrientationTests {
    static let probe = "ORIENTATION PROBE"

    @Test("rendered page reads back upright: text recognised, and near the top where it was drawn")
    func renderedPageIsUpright() throws {
        let url = try makeProbePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        #expect(page.rotation == 0, "probe fixture must have /Rotate = 0")

        let image = try #require(PDFKitRenderer.render(page: page, dpi: 300, extraRotation: 0))
        let lines = try VisionOCR().recognize(image: image)
        let text = lines.map(\.text).joined(separator: " ").uppercased()

        #expect(
            text.contains(Self.probe),
            "Vision could not read the rendered page — mirrored or flipped raster. Got: \(text)"
        )

        // Drawn near the top of the page. `RecognizedLine.boundingBox` is normalised with a
        // top-left origin and y down (`VisionOCR` converts Vision's bottom-left boxes), so an
        // upright raster puts the line in the upper half. A 180° turn puts it in the lower
        // half while still being readable, which the text assertion alone would not catch.
        let probeLine = lines.first { $0.text.uppercased().contains("ORIENTATION") }
        let box = try #require(probeLine?.boundingBox, "no line matched the probe")
        #expect(
            box.midY < 0.5,
            "probe drawn at the top of the page came back at midY \(box.midY) — raster is upside down"
        )
    }

    private func makeProbePDF() throws -> URL {
        let size = CGSize(width: 612, height: 300)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-orientation-\(UUID().uuidString).pdf")
        let pageRect = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw ExtractionError.internalError("Could not create PDF context")
        }
        pdf.beginPage(mediaBox: &mediaBox)
        pdf.setFillColor(CGColor(gray: 1, alpha: 1))
        pdf.fill(pageRect)
        let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(nil, Self.probe as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        // Baseline near the top of the page, in PDF user space (y up).
        pdf.textPosition = CGPoint(x: 40, y: size.height - 80)
        CTLineDraw(line, pdf)
        pdf.endPage()
        pdf.closePDF()
        try (data as Data).write(to: url)
        return url
    }
}
