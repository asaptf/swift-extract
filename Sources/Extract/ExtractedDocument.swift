import CoreGraphics
import Foundation

/// Normalized document produced by source adapters (internal).
struct ExtractedDocument: Sendable, Equatable {
    struct Block: Sendable, Equatable {
        var text: String
        var pageIndex: Int?
        /// Normalized bounding box in page/image coordinates (origin top-left), if known.
        var boundingBox: CGRect?
    }

    var blocks: [Block]
    var sourceDescription: String

    var isEmpty: Bool {
        fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var fullText: String {
        var pages: [Int: [String]] = [:]
        var unpaged: [String] = []
        for block in blocks {
            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let page = block.pageIndex {
                pages[page, default: []].append(trimmed)
            } else {
                unpaged.append(trimmed)
            }
        }
        var parts: [String] = []
        if !unpaged.isEmpty {
            parts.append(unpaged.joined(separator: "\n"))
        }
        for page in pages.keys.sorted() {
            let body = pages[page]!.joined(separator: "\n")
            parts.append("--- Page \(page + 1) ---\n\(body)")
        }
        return parts.joined(separator: "\n\n")
    }

    init(blocks: [Block], sourceDescription: String) {
        self.blocks = blocks
        self.sourceDescription = sourceDescription
    }

    init(text: String, sourceDescription: String = "text") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self.blocks = []
        } else {
            self.blocks = [Block(text: trimmed, pageIndex: nil, boundingBox: nil)]
        }
        self.sourceDescription = sourceDescription
    }

    /// Split into character-budget chunks, preferring page boundaries.
    func chunks(budget: Int) -> [ExtractedDocument] {
        guard budget > 0 else { return [self] }
        let text = fullText
        if text.count <= budget {
            return [self]
        }

        // Group by page when possible.
        var pageTexts: [(page: Int?, text: String)] = []
        var pages: [Int: [String]] = [:]
        var unpaged: [String] = []
        for block in blocks {
            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let page = block.pageIndex {
                pages[page, default: []].append(trimmed)
            } else {
                unpaged.append(trimmed)
            }
        }
        if !unpaged.isEmpty {
            pageTexts.append((nil, unpaged.joined(separator: "\n")))
        }
        for page in pages.keys.sorted() {
            pageTexts.append((page, pages[page]!.joined(separator: "\n")))
        }

        var result: [ExtractedDocument] = []
        var currentBlocks: [Block] = []
        var currentCount = 0

        func flush() {
            guard !currentBlocks.isEmpty else { return }
            result.append(
                ExtractedDocument(
                    blocks: currentBlocks,
                    sourceDescription: "\(sourceDescription)#chunk\(result.count + 1)"
                )
            )
            currentBlocks = []
            currentCount = 0
        }

        for item in pageTexts {
            if item.text.count > budget {
                flush()
                // Hard-split oversized page.
                var start = item.text.startIndex
                while start < item.text.endIndex {
                    let end =
                        item.text.index(start, offsetBy: budget, limitedBy: item.text.endIndex)
                        ?? item.text.endIndex
                    let slice = String(item.text[start..<end])
                    result.append(
                        ExtractedDocument(
                            blocks: [Block(text: slice, pageIndex: item.page, boundingBox: nil)],
                            sourceDescription: "\(sourceDescription)#chunk\(result.count + 1)"
                        )
                    )
                    start = end
                }
                continue
            }
            if currentCount + item.text.count > budget {
                flush()
            }
            currentBlocks.append(Block(text: item.text, pageIndex: item.page, boundingBox: nil))
            currentCount += item.text.count
        }
        flush()
        return result.isEmpty ? [self] : result
    }
}
