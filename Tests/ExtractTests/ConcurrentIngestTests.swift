import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import Extract

/// Two callers extracting OCR-bound PDFs at the same time.
///
/// The ingest path calls Vision synchronously, so if that blocking work runs on Swift's
/// cooperative pool, concurrent callers starve the pool and Vision's own capacity-limited
/// queue, and neither finishes. A library whose entry point is `async` has to survive this.
@Suite("Concurrent ingest")
struct ConcurrentIngestTests {
    @Test("oversubscribed concurrent OCR extractions all finish")
    func concurrentOCRExtractions() async throws {
        // Deliberately more callers than cores. Two failure modes lived here: blocking the
        // cooperative pool (every thread parked inside a synchronous Vision call, measured
        // to wedge at 16 on a 15-core machine) and oversubscribing Vision's own
        // capacity-limited queue (wedged at 64). Both are gone; this pins them.
        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        let urls = try (0..<count).map { _ in try makeScanOnlyPDF() }
        defer {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }

        let canned = #"{"title":"Scan","body":"ok"}"#
        try await withThrowingTaskGroup(of: String.self) { group in
            for url in urls {
                group.addTask {
                    let session = ExtractionSession.mock(MockLanguageModel(responses: [canned]))
                    let doc: TinyDoc = try await Extract.from(.pdf(url), using: session)
                    return doc.title
                }
            }
            var titles: [String] = []
            for try await title in group { titles.append(title) }
            #expect(titles.count == count)
        }
    }

    /// One page, no text layer — forces the raster + OCR path.
    private func makeScanOnlyPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-concurrent-\(UUID().uuidString).pdf")
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 300)
        let data = NSMutableData()
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw ExtractionError.internalError("Could not create PDF context")
        }
        guard
            let bitmap = CGContext(
                data: nil, width: 1_600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw ExtractionError.internalError("Could not create scan bitmap")
        }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 1_600, height: 400))
        let font = CTFontCreateWithName("Helvetica" as CFString, 96, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(nil, "SCANNED INVOICE 42" as CFString, attrs as CFDictionary)!
        bitmap.textPosition = CGPoint(x: 40, y: 160)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), bitmap)
        guard let scan = bitmap.makeImage() else {
            throw ExtractionError.internalError("Could not make scan image")
        }
        pdf.beginPage(mediaBox: &mediaBox)
        pdf.setFillColor(CGColor(gray: 1, alpha: 1))
        pdf.fill(pageRect)
        pdf.draw(scan, in: CGRect(x: 20, y: 40, width: 572, height: 143))
        pdf.endPage()
        pdf.closePDF()
        try (data as Data).write(to: url)
        return url
    }
}
