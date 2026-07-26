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

        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            let raw = page.string ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.count < ocrFallbackThreshold {
                let ocrBlocks = try OCRAdapter.ocrPDFPage(page, pageIndex: index)
                if !ocrBlocks.isEmpty {
                    blocks.append(contentsOf: ocrBlocks)
                    continue
                }
            }
            if !trimmed.isEmpty {
                blocks.append(
                    ExtractedDocument.Block(text: trimmed, pageIndex: index, boundingBox: nil)
                )
            }
        }

        return ExtractedDocument(blocks: blocks, sourceDescription: sourceDescription)
    }
}
