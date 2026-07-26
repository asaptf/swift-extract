import CoreGraphics
import Foundation
import PDFKit

enum PDFAdapter {
    /// Average extractable characters per page below this threshold triggers OCR fallback.
    static let ocrFallbackThreshold = 10

    static func ingest(url: URL) throws -> ExtractedDocument {
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.unreadableSource(
                underlying: NSError(
                    domain: "Extract",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "PDFKit could not open \(url.path)"]
                )
            )
        }
        return try ingest(document: document, sourceDescription: url.lastPathComponent)
    }

    static func ingest(document: PDFDocument, sourceDescription: String) throws -> ExtractedDocument {
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw ExtractionError.emptyDocument
        }

        var blocks: [ExtractedDocument.Block] = []
        var totalChars = 0

        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            let raw = page.string ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            totalChars += trimmed.count
            if !trimmed.isEmpty {
                blocks.append(
                    ExtractedDocument.Block(text: trimmed, pageIndex: index, boundingBox: nil)
                )
            }
        }

        let average = pageCount > 0 ? totalChars / pageCount : 0
        if average < ocrFallbackThreshold {
            // Rasterize + Vision OCR
            let ocrBlocks = try OCRAdapter.ocrPDFDocument(document)
            if !ocrBlocks.isEmpty {
                return ExtractedDocument(blocks: ocrBlocks, sourceDescription: sourceDescription)
            }
            // Fall through to whatever text layer we got (may be empty).
        }

        return ExtractedDocument(blocks: blocks, sourceDescription: sourceDescription)
    }
}
