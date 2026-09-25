import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Extract

/// A fax, a scanner's multi-page TIFF and an animated GIF are one file holding several pictures.
/// Each is a page. Reading the first and dropping the rest handed a caller a document pages short
/// with nothing to say so: the text of page two was simply not there.
///
/// Every file here is drawn for the test with `CGImageDestination`. Frames differ in width, which
/// is how the scripted engine tells them apart and how a test tells which frame it was shown.
@Suite("Multi-frame images")
struct MultiFrameImageTests {
    @Test("every frame of a multi-page TIFF is read as its own page, in order")
    func everyFrameIsAPage() async throws {
        let url = try writeFrames(widths: [100, 101, 102], as: .tiff)
        defer { try? FileManager.default.removeItem(at: url) }
        let ocr = FrameOCR([100: ["PAGE ONE"], 101: ["PAGE TWO"], 102: ["PAGE THREE"]])
        let inspection = try await Extract.inspect(
            .fileURL(url), tableDetection: .off, ingest: IngestContext(ocr: ocr))

        #expect(ocr.widthsRead == [100, 101, 102], "each frame read once, in file order")
        #expect(inspection.pageSources == [0: .ocr, 1: .ocr, 2: .ocr])
        #expect(inspection.positionedBlocks.map(\.pageIndex) == [0, 1, 2])
        #expect(inspection.positionedBlocks.map(\.text) == ["PAGE ONE", "PAGE TWO", "PAGE THREE"])
        #expect(
            inspection.fullText
                == "--- Page 1 ---\nPAGE ONE\n\n--- Page 2 ---\nPAGE TWO\n\n--- Page 3 ---\nPAGE THREE")
        // A picture is read as it is stored; no frame is turned.
        #expect(inspection.pageRotations.isEmpty)
        #expect(!inspection.usedOCRFallback)
    }

    /// A blank frame is a page that yielded nothing, the way a blank PDF page is: absent from the
    /// page sources, and not a reason for every later frame to move up a page.
    @Test("a frame that reads nothing is absent, and the frames after it keep their own page")
    func blankFrameKeepsLaterPages() async throws {
        let url = try writeFrames(widths: [100, 101, 102], as: .tiff)
        defer { try? FileManager.default.removeItem(at: url) }
        let ocr = FrameOCR([100: ["COVER"], 101: [], 102: ["LAST PAGE"]])
        let inspection = try await Extract.inspect(
            .fileURL(url), tableDetection: .off, ingest: IngestContext(ocr: ocr))

        #expect(inspection.pageSources == [0: .ocr, 2: .ocr])
        #expect(inspection.positionedBlocks.map(\.pageIndex) == [0, 2])
        #expect(inspection.fullText == "--- Page 1 ---\nCOVER\n\n--- Page 3 ---\nLAST PAGE")
    }

    @Test("an animated GIF is read frame by frame")
    func animatedGIF() async throws {
        let url = try writeFrames(widths: [100, 101], as: .gif)
        defer { try? FileManager.default.removeItem(at: url) }
        let ocr = FrameOCR([100: ["FIRST"], 101: ["SECOND"]])
        let inspection = try await Extract.inspect(
            .fileURL(url), tableDetection: .off, ingest: IngestContext(ocr: ocr))

        #expect(inspection.pageSources == [0: .ocr, 1: .ocr])
        #expect(inspection.positionedBlocks.map(\.pageIndex) == [0, 1])
    }

    @Test("an image of one frame is still page zero")
    func singleFrameIsPageZero() async throws {
        let url = try writeFrames(widths: [100], as: .png)
        defer { try? FileManager.default.removeItem(at: url) }
        let ocr = FrameOCR([100: ["RECEIPT"]])
        let inspection = try await Extract.inspect(
            .fileURL(url), tableDetection: .off, ingest: IngestContext(ocr: ocr))

        #expect(ocr.widthsRead == [100])
        #expect(inspection.pageSources == [0: .ocr])
        #expect(inspection.positionedBlocks.map(\.pageIndex) == [0])
        #expect(inspection.fullText == "--- Page 1 ---\nRECEIPT")
    }

    @Test("a multi-frame image where no frame reads anything is an empty document")
    func everyFrameBlank() async throws {
        let url = try writeFrames(widths: [100, 101], as: .tiff)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: ExtractionError.self) {
            try await Extract.inspect(
                .fileURL(url), tableDetection: .off, ingest: IngestContext(ocr: FrameOCR([:])))
        }
    }

    /// `ExtractionSource.image` is one picture. A convenience that decodes a file into one would
    /// have to pick a frame and drop the rest, so it refuses, and names the source that reads
    /// every frame.
    @Test("the one-picture conveniences refuse a file of several frames rather than keep its first")
    func conveniencesRefuseSeveralFrames() throws {
        let url = try writeFrames(widths: [100, 101, 102], as: .tiff)
        defer { try? FileManager.default.removeItem(at: url) }

        let fromURL = #expect(throws: ExtractionError.self) { try ExtractionSource.image(url: url) }
        let fromData = #expect(throws: ExtractionError.self) {
            try ExtractionSource.image(data: Data(contentsOf: url))
        }
        for error in [fromURL, fromData] {
            let message = error?.localizedDescription ?? ""
            #expect(message.contains("3 frames"), "\(message)")
            #expect(message.contains("fileURL"), "\(message)")
        }
    }

    @Test("the one-picture conveniences still decode a file of one frame")
    func conveniencesDecodeOneFrame() throws {
        let url = try writeFrames(widths: [100], as: .png)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .image(let picture) = try ExtractionSource.image(url: url) else {
            Issue.record("expected an image source")
            return
        }
        #expect(picture.width == 100)
    }

    /// The same file through the real engine, so what is checked is the picture of each frame and
    /// not only the index it was filed under.
    @Test("the live engine reads the text of each frame onto its own page")
    func liveEngineReadsEachFrame() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-frames-live-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, try page(showing: ["INVOICE 2026", "Lippstadt"]), nil)
        CGImageDestinationAddImage(destination, try page(showing: ["TOTAL 1285.00 EUR"]), nil)
        #expect(CGImageDestinationFinalize(destination))

        let inspection = try await Extract.inspect(
            .fileURL(url), tableDetection: .off,
            options: ExtractionOptions(autoOrient: false, recognitionLanguages: ["en-US"]))

        #expect(inspection.pageSources == [0: .ocr, 1: .ocr])
        let first = inspection.positionedBlocks.filter { $0.pageIndex == 0 }.map(\.text).joined(separator: " ")
        let second = inspection.positionedBlocks.filter { $0.pageIndex == 1 }.map(\.text).joined(separator: " ")
        #expect(first.contains("INVOICE 2026"), "page 1 read: \(first)")
        #expect(first.contains("Lippstadt"), "page 1 read: \(first)")
        #expect(!first.contains("TOTAL"), "page 1 read: \(first)")
        #expect(second.contains("1285.00"), "page 2 read: \(second)")
        #expect(!second.contains("INVOICE"), "page 2 read: \(second)")
    }
}

/// Reads the lines scripted for a frame of that width, and remembers which widths it was shown.
private final class FrameOCR: OCRRecognizing, @unchecked Sendable {
    private let linesByWidth: [Int: [String]]
    private let lock = NSLock()
    private var seen: [Int] = []

    init(_ linesByWidth: [Int: [String]]) { self.linesByWidth = linesByWidth }

    var widthsRead: [Int] { lock.withLock { seen } }

    func recognize(image: CGImage) throws -> [RecognizedLine] {
        lock.withLock { seen.append(image.width) }
        return (linesByWidth[image.width] ?? []).enumerated().map { index, text in
            RecognizedLine(
                text: text, boundingBox: CGRect(x: 0.1, y: 0.1 + Double(index) * 0.1, width: 0.5, height: 0.05),
                confidence: 1)
        }
    }
}

/// One white frame per width, 80 pixels tall, in one file of the given type.
private func writeFrames(widths: [Int], as type: UTType) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("extract-frames-\(UUID().uuidString)")
        .appendingPathExtension(for: type)
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, widths.count, nil)
    else { throw ExtractionError.internalError("no destination for \(type.identifier)") }
    for width in widths {
        guard
            let context = CGContext(
                data: nil, width: width, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ExtractionError.internalError("no bitmap") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 80))
        guard let frame = context.makeImage() else { throw ExtractionError.internalError("no frame") }
        CGImageDestinationAddImage(destination, frame, nil)
    }
    guard CGImageDestinationFinalize(destination) else {
        throw ExtractionError.internalError("could not write \(type.identifier)")
    }
    return url
}

/// `lines` drawn into a 150 DPI bitmap of a Letter page — pixels, not text.
private func page(showing lines: [String]) throws -> CGImage {
    let width = 1275
    let height = 1650
    guard
        let bitmap = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { throw ExtractionError.internalError("no bitmap") }
    bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
    bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, 34, nil)
    for (index, text) in lines.enumerated() {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
        ]
        guard let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            throw ExtractionError.internalError("no string")
        }
        bitmap.textPosition = CGPoint(x: 100, y: CGFloat(height - 200 - index * 90))
        CTLineDraw(CTLineCreateWithAttributedString(string), bitmap)
    }
    guard let image = bitmap.makeImage() else { throw ExtractionError.internalError("no page") }
    return image
}
