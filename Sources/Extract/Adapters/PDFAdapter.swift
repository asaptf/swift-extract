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

            if trimmed.isEmpty {
                continue
            }

            let wordBlocks = wordBlocksFromTextLayer(
                page: page,
                pageIndex: index,
                document: document
            )
            if !wordBlocks.isEmpty {
                blocks.append(contentsOf: wordBlocks)
            } else {
                // Geometry failed; keep plain text so fullText stays usable.
                blocks.append(
                    ExtractedDocument.Block(text: trimmed, pageIndex: index, boundingBox: nil)
                )
            }
        }

        return ExtractedDocument(blocks: blocks, sourceDescription: sourceDescription)
    }

    /// Extract per-word blocks with normalized top-left bounding boxes from a PDF text layer.
    ///
    /// Uses `PDFDocument` character-index selections (more reliable than
    /// `PDFPage.characterBounds(at:)` alone on many commercial PDFs). Words are split on
    /// whitespace / newlines in `page.string`, which is aligned with `numberOfCharacters`.
    static func wordBlocksFromTextLayer(
        page: PDFPage,
        pageIndex: Int,
        document: PDFDocument
    ) -> [ExtractedDocument.Block] {
        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return [] }

        let characterCount = page.numberOfCharacters
        guard characterCount > 0, let fullString = page.string, !fullString.isEmpty else {
            return []
        }

        var blocks: [ExtractedDocument.Block] = []
        var stringIndex = fullString.startIndex
        var characterIndex = 0

        while stringIndex < fullString.endIndex, characterIndex < characterCount {
            let ch = fullString[stringIndex]
            if ch.isNewline || ch.isWhitespace {
                stringIndex = fullString.index(after: stringIndex)
                characterIndex += 1
                continue
            }

            let wordStart = characterIndex
            var wordEndIndex = stringIndex
            while wordEndIndex < fullString.endIndex, characterIndex < characterCount {
                let c = fullString[wordEndIndex]
                if c.isNewline || c.isWhitespace { break }
                wordEndIndex = fullString.index(after: wordEndIndex)
                characterIndex += 1
            }

            let word = String(fullString[stringIndex..<wordEndIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty, wordStart < characterIndex {
                let lastChar = characterIndex - 1
                if let selection = document.selection(
                    from: page,
                    atCharacterIndex: wordStart,
                    to: page,
                    atCharacterIndex: lastChar
                ) {
                    let bounds = selection.bounds(for: page)
                    if bounds.width > 0 || bounds.height > 0 {
                        let normalized = normalizedTopLeft(bounds, pageBounds: pageBounds)
                        blocks.append(
                            ExtractedDocument.Block(
                                text: word,
                                pageIndex: pageIndex,
                                boundingBox: normalized
                            )
                        )
                    }
                }
            }

            stringIndex = wordEndIndex
        }

        return blocks
    }

    /// PDFKit uses bottom-left origin; adapters expose top-left normalized boxes.
    private static func normalizedTopLeft(_ rect: CGRect, pageBounds: CGRect) -> CGRect {
        let x = (rect.minX - pageBounds.minX) / pageBounds.width
        let y = 1.0 - ((rect.maxY - pageBounds.minY) / pageBounds.height)
        let w = rect.width / pageBounds.width
        let h = rect.height / pageBounds.height
        return CGRect(x: x, y: y, width: max(w, 0), height: max(h, 0))
    }
}
