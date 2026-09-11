import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
import Vision

@testable import Extract

/// Vision recognises only English unless it is told otherwise, and it says nothing when it
/// meets a script it was not asked for: the Arabic line `الكمية 12 الوزن 1,285` came back as
/// `1,285 ja|| 12 tall` — plausible, wrong, and unflagged. A document type therefore has to be
/// able to state what its pages are printed in.
@Suite("Recognition languages")
struct RecognitionLanguageTests {
    static let arabic = "فاتورة تجارية رقم 1493952"
    static let latin = "INVOICE VR1493952"

    @Test("Arabic is read when the caller asks for it")
    func arabicIsReadWhenRequested() throws {
        let image = try #require(mixedScriptImage())
        let withArabic = try VisionOCR().recognize(
            image: image, languages: ["ar-SA", "en-US"], correctsLanguage: true)
        let text = withArabic.map(\.text).joined(separator: " ")
        #expect(text.contains(Self.arabic), "Arabic not read with ar-SA requested: \(text)")
        #expect(text.contains(Self.latin), "asking for Arabic must not cost the Latin line: \(text)")
    }

    @Test("the languages a document states reach the engine, and so does the correction switch")
    func languagesReachTheEngine() throws {
        let url = try blankPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        var options = ExtractionOptions()
        options.recognitionLanguages = ["ar-SA", "en-US"]
        options.usesLanguageCorrection = false
        options.autoOrient = false
        let ocr = LanguageRecordingOCR()
        _ = try OCRAdapter.ocrPDFPage(
            page, pageIndex: 0, options: options, ocr: ocr, renderer: PDFKitRenderer())
        #expect(ocr.languages == ["ar-SA", "en-US"])
        #expect(ocr.correction == false)
    }

    @Test("a caller that states nothing keeps the engine's own default")
    func defaultStaysEngineDefault() throws {
        let url = try blankPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        var options = ExtractionOptions()
        options.autoOrient = false
        let ocr = LanguageRecordingOCR()
        _ = try OCRAdapter.ocrPDFPage(
            page, pageIndex: 0, options: options, ocr: ocr, renderer: PDFKitRenderer())
        #expect(ocr.languages == [])
        #expect(ocr.correction == true)
    }

    /// An engine that knows nothing about languages must still be usable — it simply reads the
    /// way it always did, which is what the protocol's default does.
    @Test("an engine that ignores languages still works")
    func engineWithoutLanguageSupport() throws {
        let image = try #require(mixedScriptImage())
        let lines = try SingleLineOCR().recognize(
            image: image, languages: ["ar-SA"], correctsLanguage: false)
        #expect(lines.map(\.text) == ["fixed"])
    }

    private func mixedScriptImage() -> CGImage? {
        let width = 1000
        let height = 300
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(Self.arabic, at: CGPoint(x: 60, y: 180), size: 48, in: context)
        draw(Self.latin, at: CGPoint(x: 60, y: 60), size: 40, in: context)
        return context.makeImage()
    }

    private func draw(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName("Geeza Pro" as CFString, size, nil)
        let attributed = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    private func blankPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-languages-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPage(mediaBox: &box)
        pdf.setFillColor(CGColor(gray: 1, alpha: 1))
        pdf.fill(box)
        pdf.endPage()
        pdf.closePDF()
        try (data as Data).write(to: url)
        return url
    }
}

private final class LanguageRecordingOCR: OCRRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var seenLanguages: [String] = []
    private var seenCorrection = true

    var languages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seenLanguages
    }
    var correction: Bool {
        lock.lock()
        defer { lock.unlock() }
        return seenCorrection
    }

    func recognize(image: CGImage) throws -> [RecognizedLine] { [] }

    func recognize(
        image: CGImage, languages: [String], correctsLanguage: Bool
    ) throws -> [RecognizedLine] {
        lock.lock()
        seenLanguages = languages
        seenCorrection = correctsLanguage
        lock.unlock()
        return []
    }
}

/// Conforms the old way, without knowing about languages.
private struct SingleLineOCR: OCRRecognizing {
    func recognize(image: CGImage) throws -> [RecognizedLine] {
        [RecognizedLine(text: "fixed", boundingBox: .init(x: 0, y: 0, width: 1, height: 1), confidence: 1)]
    }
}

/// The scripts have to reach the image path and the orientation probe too: a probe that reads
/// an Arabic page as English scores four turns of the same garbage, and a standalone image is
/// the same page without a PDF around it.
@Suite("Recognition languages reach every path")
struct RecognitionLanguageReachTests {
    @Test("a standalone image is read in the stated scripts")
    func imagePathCarriesLanguages() throws {
        let context = CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let image = try #require(context?.makeImage())
        var options = ExtractionOptions()
        options.recognitionLanguages = ["ar-SA"]
        options.usesLanguageCorrection = false
        let ocr = ReachRecordingOCR()
        _ = try OCRAdapter.recognize(cgImage: image, options: options, ocr: ocr)
        #expect(ocr.calls == [["ar-SA"]])
        #expect(ocr.corrections == [false])
    }

    @Test("the orientation probe reads the page in the same scripts as the page itself")
    func probeCarriesLanguages() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-probe-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPage(mediaBox: &box)
        pdf.endPage()
        pdf.closePDF()
        try (data as Data).write(to: url)

        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let ocr = ReachRecordingOCR()
        _ = OCRAdapter.orientation(
            page: page, ocr: ocr, renderer: PDFKitRenderer(), languages: ["ar-SA", "en-US"],
            correctsLanguage: false)
        #expect(ocr.calls.count == 4, "all four turns are probed")
        #expect(ocr.calls.allSatisfy { $0 == ["ar-SA", "en-US"] })
        #expect(ocr.corrections.allSatisfy { $0 == false })
    }
}

private final class ReachRecordingOCR: OCRRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [[String]] = []
    private var seenCorrections: [Bool] = []
    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
    var corrections: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return seenCorrections
    }
    func recognize(image: CGImage) throws -> [RecognizedLine] { [] }
    func recognize(
        image: CGImage, languages: [String], correctsLanguage: Bool
    ) throws -> [RecognizedLine] {
        lock.lock()
        seen.append(languages)
        seenCorrections.append(correctsLanguage)
        lock.unlock()
        return []
    }
}
