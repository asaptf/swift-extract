import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import Extract

/// A line Vision read upside down comes back with the right text and the right box — and its
/// words in the opposite order along that box. Nothing else about the line says so, and a
/// caller that lays the text back over the page left to right puts every word at the mirrored
/// end of its line: measured 2026-09-23, about 100 pt off on a 612 pt page.
///
/// The order is the evidence. macOS 27's Vision reports a box per **word** for any character
/// range inside it — every character of a word carries the word's centre, and a space comes
/// back at `0` — so a line of two words or more says which way it runs, and a line of one
/// word says nothing.
@Suite("Line orientation")
struct LineOrientationTests {
    static let box = CGRect(x: 0.094, y: 0.14, width: 0.333, height: 0.028)

    @Test("a line whose words run the way its script is written stands upright")
    func forwardLineIsUpright() {
        // Measured: `LIPPSTADT 50,50 EUR` read from an upright page, word centres 0.177 → 0.389.
        let line = line("LIPPSTADT 50,50 EUR", from: 0.177, to: 0.389)
        #expect(line.orientation == .upright)
    }

    @Test("the same line with its words running the other way is upside down")
    func backwardLineIsUpsideDown() {
        // Measured: the same line read from the page turned 180°, word centres 0.822 → 0.607.
        let line = line("LIPPSTADT 50,50 EUR", from: 0.822, to: 0.607, box: Self.box.offsetBy(dx: 0.47, dy: 0))
        #expect(line.orientation == .upsideDown)
    }

    /// Arabic is written right to left, so an upright Arabic line has its first word at the
    /// right. Reading x-order as "left to right means upright" would call every upright Arabic
    /// line upside down, and a caller that turned those over would mirror exactly the pages
    /// that were right.
    @Test("a line in a right-to-left script stands upright when its words run right to left")
    func rightToLeftScriptIsJudgedByItsOwnDirection() {
        #expect(line("الكمية 12", from: 0.40, to: 0.14).orientation == .upright)
        #expect(line("الكمية 12", from: 0.14, to: 0.40).orientation == .upsideDown)
        #expect(line("שלום עולם", from: 0.40, to: 0.14).orientation == .upright)
    }

    /// The direction is the first letter's, which is how Unicode sets a paragraph's direction
    /// and how CoreText lays a line by default: a code in front of an Arabic word does not make
    /// the line left to right, and figures alone are laid left to right.
    @Test("figures carry no direction of their own")
    func figuresFollowTheFirstLetter() {
        #expect(line("12 الكمية", from: 0.40, to: 0.14).orientation == .upright)
        #expect(line("159,00 53,00 1,100", from: 0.12, to: 0.40).orientation == .upright)
        #expect(line("159,00 53,00 1,100", from: 0.40, to: 0.12).orientation == .upsideDown)
    }

    @Test(
        "a line that cannot say which way it runs says so",
        arguments: [
            // One word: every character carries the same centre.
            RecognizedLine(
                text: "LIPPSTADT", boundingBox: box, confidence: 1, characterXs: Array(repeating: 0.26, count: 9)),
            // An engine that supplies no per-character positions.
            RecognizedLine(text: "LIPPSTADT 50,50 EUR", boundingBox: box, confidence: 1, characterXs: []),
            // Positions that do not belong to this text.
            RecognizedLine(text: "LIPPSTADT 50,50 EUR", boundingBox: box, confidence: 1, characterXs: [0.1, 0.3]),
            // Sideways: the line runs down the page, and its words' x-centres differ by noise.
            RecognizedLine(
                text: "40 4051428075268 CN", boundingBox: CGRect(x: 0.84, y: 0.52, width: 0.012, height: 0.38),
                confidence: 1, characterXs: sidewaysXs("40 4051428075268 CN")),
            // Words that barely move along a wide box: jitter, not order.
            RecognizedLine(
                text: "TOTAL DUE", boundingBox: box, confidence: 1,
                characterXs: [0.26, 0.26, 0.26, 0.26, 0.26, 0, 0.262, 0.262, 0.262]),
        ])
    func undecidableLineIsUnknown(line: RecognizedLine) {
        #expect(line.orientation == .unknown)
    }

    // MARK: - Vision, live

    /// Everything above rests on how this OS's Vision reports a line it read upside down. This
    /// pins it: if a release stops reporting per-word boxes, lines fall back to `.unknown`
    /// rather than to a direction nobody measured, and this test says which.
    ///
    /// Read on the ingest queue, as ingest reads: Vision called straight from a test parks a
    /// cooperative-pool thread, and enough tests doing that at once wedge the suite.
    @Test("Vision reads an upside-down page with every line's words running backwards", arguments: [0, 180])
    func visionReportsTheOrder(turn: Int) async throws {
        let image = try #require(Self.page(turn: turn))
        let lines = try await IngestExecutor.run {
            try VisionOCR().recognize(image: image, languages: ["en-US"], correctsLanguage: true)
        }
        let expected: LineOrientation = turn == 0 ? .upright : .upsideDown
        let opposite: LineOrientation = turn == 0 ? .upsideDown : .upright
        #expect(lines.count == Self.lines.count, "read \(lines.map(\.text))")
        #expect(lines.allSatisfy { $0.orientation == expected }, "\(lines.map { ($0.text, $0.orientation) })")
        #expect(!lines.contains { $0.orientation == opposite })
    }

    // MARK: - Published

    /// An image is read as it is stored — nothing turns it — so a photo taken upside down is
    /// read upside down, and its lines are the only place that can say so.
    @Test("inspect says which lines were read upside down")
    func inspectPublishesTheOrientation() async throws {
        let image = try #require(Self.page(turn: 180))
        var options = ExtractionOptions()
        options.recognitionLanguages = ["en-US"]
        let inspection = try await Extract.inspect(.image(image), tableDetection: .off, options: options)
        #expect(inspection.positionedBlocks.count == Self.lines.count)
        #expect(inspection.positionedBlocks.allSatisfy { $0.lineOrientation == .upsideDown })
        #expect(inspection.pageRotations.isEmpty, "an image is never turned")
    }

    @Test("a text layer's words make no claim about which way up they stand")
    func textLayerBlocksAreUnknown() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-layer-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPage(mediaBox: &box)
        Self.draw(
            "Invoice number 2026 total amount 1285.00 EUR payable within thirty days", at: CGPoint(x: 72, y: 700),
            size: 12, in: pdf)
        pdf.endPage()
        pdf.closePDF()
        try (data as Data).write(to: url)
        let inspection = try await Extract.inspect(.fileURL(url), tableDetection: .off)
        #expect(inspection.pageSources[0] == .textLayer)
        #expect(!inspection.positionedBlocks.isEmpty)
        #expect(inspection.positionedBlocks.allSatisfy { $0.lineOrientation == .unknown })
    }

    // MARK: - Fixtures

    static let lines = ["LIPPSTADT 50,50 EUR", "TARIFF 64039993900", "VELOCITY BLACK LOW S3S", "DELIVERY NOTE 2026"]

    /// Letter at 150 DPI with four lines of 40 pt print, turned clockwise by `turn`.
    static func page(turn: Int) -> CGImage? {
        let size = CGSize(width: 1275, height: 1650)
        guard
            let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        if turn == 180 {
            context.translateBy(x: size.width, y: size.height)
            context.rotate(by: .pi)
        }
        for (index, text) in lines.enumerated() {
            draw(text, at: CGPoint(x: 120, y: size.height - 220 - CGFloat(index) * 90), size: 40, in: context)
        }
        return context.makeImage()
    }

    static func draw(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary)!
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    private func line(_ text: String, from start: CGFloat, to end: CGFloat, box: CGRect = box) -> RecognizedLine {
        RecognizedLine(text: text, boundingBox: box, confidence: 1, characterXs: wordXs(text, from: start, to: end))
    }
}

/// Word-level x-centres the way macOS 27's Vision reports them: each character of a word
/// carries the word's centre, the words spaced evenly from `start` to `end`, a space at `0`.
func wordXs(_ text: String, from start: CGFloat, to end: CGFloat) -> [CGFloat] {
    let words = text.split(separator: " ").count
    let step = words > 1 ? (end - start) / CGFloat(words - 1) : 0
    var xs: [CGFloat] = []
    var word = 0
    var previous: Character = " "
    for character in text {
        if character == " " {
            xs.append(0)
        } else {
            if previous == " ", !xs.isEmpty { word += 1 }
            xs.append(start + step * CGFloat(word))
        }
        previous = character
    }
    return xs
}

/// A line lying down the page: its words share an x-centre give or take a thousandth.
private func sidewaysXs(_ text: String) -> [CGFloat] {
    wordXs(text, from: 0.846, to: 0.845)
}
