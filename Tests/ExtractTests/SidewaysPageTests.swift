import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import Extract

/// A scan fed sideways into the scanner is a landscape page with `/Rotate = 0` and its
/// content lying on its side. Vision reads such a page at **both** 90° and 270° — the text
/// comes back legible either way — so a detector that only renders one of them and guesses
/// the other is guessing. Measured on a six-page customer invoice: the upright turn scored
/// about four times the upside-down one, and the old guess went the wrong way on every
/// sideways page, which put the footer first and cost the whole table.
///
/// On clean print the scores cannot tell the two ends of the axis apart, and the words can:
/// the upside-down reading has every line running backwards. So on this fixture the direction
/// is asserted, and the proof it is right is the reading order — the header first.
@Suite("Sideways pages")
struct SidewaysPageTests {
    static let header = "HEADER INVOICE NUMBER VR1493952"
    static let footer = "FOOTER LINE"

    @Test(
        "a page whose content lies on its side is turned the right way up and read",
        arguments: [true, false]
    )
    func sidewaysPageIsTurnedUpright(clockwise: Bool) async throws {
        let url = try makeSidewaysPDF(clockwise: clockwise)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        #expect(page.rotation == 0, "the fixture carries no /Rotate — the content itself is sideways")

        // On the ingest queue, as ingest reads: Vision called straight from a test parks a
        // cooperative-pool thread, and enough tests doing that at once wedge the suite.
        let decision = try await IngestExecutor.run {
            OCRAdapter.orientation(page: page, ocr: VisionOCR(), renderer: PDFKitRenderer())
        }
        // Drawn turned a quarter clockwise, the sheet reads upright turned three quarters more.
        #expect(decision.rotation == (clockwise ? 270 : 90), "turned \(decision.rotation)")
        #expect(!decision.isAmbiguous, "every line reads backwards the wrong way up: \(decision)")

        var options = ExtractionOptions()
        options.textLayerPolicy = .never
        let blocks = try await IngestExecutor.run {
            try OCRAdapter.ocrPDFPage(
                page, pageIndex: 0, options: options, ocr: VisionOCR(), renderer: PDFKitRenderer(),
                rotation: decision.rotation)
        }
        let texts = blocks.map { $0.text.uppercased() }
        #expect(texts.first?.contains("HEADER") == true, "read from the wrong end: \(texts.prefix(3))")
        #expect(texts.last?.contains("FOOTER") == true, "footer not last: \(texts.suffix(3))")
    }

    /// The same clean print scanned upside down. Its two readings score within a percent of each
    /// other, and it used to be reported as needing no turn at all — read footer first, every
    /// line's words at the mirrored end of its box.
    @Test("a clean page scanned upside down is turned the right way up")
    func upsideDownPageIsTurnedUpright() async throws {
        let url = try makeTurnedPDF(quarterTurns: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let decision = try await IngestExecutor.run {
            OCRAdapter.orientation(page: page, ocr: VisionOCR(), renderer: PDFKitRenderer())
        }
        #expect(decision.rotation == 180, "\(decision)")
        #expect(!decision.isAmbiguous)

        var options = ExtractionOptions()
        options.textLayerPolicy = .never
        let inspection = try await Extract.inspect(.fileURL(url), tableDetection: .off, options: options)
        #expect(inspection.pageRotations == [0: 180])
        let blocks = inspection.positionedBlocks
        #expect(blocks.first?.text.uppercased().contains("HEADER") == true, "\(blocks.prefix(2).map(\.text))")
        #expect(!blocks.contains { $0.lineOrientation == .upsideDown }, "read upright, no line runs backwards")
    }

    /// A caller that turned detection off gets the page as stored, and the lines are the only
    /// thing left that can say they were read upside down.
    @Test("with orientation off, an upside-down page's lines say they read upside down")
    func upsideDownLinesSaySo() async throws {
        let url = try makeTurnedPDF(quarterTurns: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = ExtractionOptions()
        options.textLayerPolicy = .never
        options.autoOrient = false
        let inspection = try await Extract.inspect(.fileURL(url), tableDetection: .off, options: options)
        #expect(inspection.pageRotations.isEmpty)
        let orientations = inspection.positionedBlocks.map(\.lineOrientation)
        #expect(!orientations.contains(.upright), "\(orientations)")
        #expect(orientations.filter { $0 == .upsideDown }.count >= 30, "\(orientations)")
    }

    /// The turn is not only an internal step. Boxes come back in the turned frame, so an
    /// application that shows the page to a person has to turn it the same way — and it
    /// cannot, unless ingest says by how much. It went unsaid, and every box drawn over a
    /// sideways page in review landed somewhere the value was not.
    @Test("inspect reports the turn each page was read at")
    func inspectReportsThePageRotation() async throws {
        let url = try makeSidewaysPDF(clockwise: true)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = ExtractionOptions()
        options.textLayerPolicy = .never
        let inspection = try await Extract.inspect(.fileURL(url), options: options)
        let rotation = try #require(inspection.pageRotations[0], "a turned page must say so")
        #expect(rotation % 180 == 90, "a sideways page is turned onto its axis: \(rotation)")
        #expect(inspection.pageRotations.count == 1)
    }

    /// A page that was read as it was stored must not claim a turn; an application that
    /// rotated by a phantom 0-that-is-really-360 would break the pages that were fine.
    @Test("a page read as it stands reports no turn")
    func uprightPageReportsNoRotation() async throws {
        let url = try makeUprightPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        var options = ExtractionOptions()
        options.textLayerPolicy = .never
        let inspection = try await Extract.inspect(.fileURL(url), options: options)
        #expect(inspection.pageRotations[0] == nil, "got \(inspection.pageRotations)")
    }

    /// An upright page, rasterised with scan-like grain and then turned a quarter turn —
    /// which is what a sheet fed sideways into a scanner actually is: an image, not text.
    /// The grain matters. On clean vector text Vision reads an upside-down page far worse
    /// than an upright one, so the orientation lands right by luck; on a grainy scan of
    /// dense small print it reads both ways almost equally well, and that is where a
    /// detector that never renders the fourth quarter turn has to guess.
    private func makeSidewaysPDF(clockwise: Bool) throws -> URL {
        try makeTurnedPDF(quarterTurns: clockwise ? 1 : 3)
    }

    /// The grainy upright page drawn turned clockwise by `quarterTurns` quarter turns.
    private func makeTurnedPDF(quarterTurns: Int) throws -> URL {
        let upright = try makeUprightPDF()
        defer { try? FileManager.default.removeItem(at: upright) }
        let document = try #require(PDFDocument(url: upright))
        let page = try #require(document.page(at: 0))
        let media = page.bounds(for: .mediaBox)
        let scan = try #require(scanned(page: page, media: media))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-sideways-\(UUID().uuidString).pdf")
        let sideways = quarterTurns % 2 == 1
        var box =
            sideways
            ? CGRect(x: 0, y: 0, width: media.height, height: media.width) : CGRect(origin: .zero, size: media.size)
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
        switch quarterTurns % 4 {
        case 1:
            pdf.translateBy(x: 0, y: media.width)
            pdf.rotate(by: -.pi / 2)
        case 2:
            pdf.translateBy(x: media.width, y: media.height)
            pdf.rotate(by: .pi)
        case 3:
            pdf.translateBy(x: media.height, y: 0)
            pdf.rotate(by: .pi / 2)
        default:
            break
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
