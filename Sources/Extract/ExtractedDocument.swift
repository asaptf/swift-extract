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
        var pages: [Int: [Block]] = [:]
        var unpaged: [Block] = []
        for block in blocks {
            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let cleaned = Block(
                text: trimmed,
                pageIndex: block.pageIndex,
                boundingBox: block.boundingBox
            )
            if let page = block.pageIndex {
                pages[page, default: []].append(cleaned)
            } else {
                unpaged.append(cleaned)
            }
        }
        var parts: [String] = []
        if !unpaged.isEmpty {
            parts.append(Self.joinBlocksReadingOrder(unpaged))
        }
        for page in pages.keys.sorted() {
            let body = Self.joinBlocksReadingOrder(pages[page] ?? [])
            parts.append("--- Page \(page + 1) ---\n\(body)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Join blocks into reading-order text.
    ///
    /// When bounding boxes are present, fragments on the same horizontal line are joined
    /// with spaces (so per-word PDF geometry still yields `Acme Supplies Co.`); new lines
    /// start when vertical position advances. Without boxes, blocks are joined with newlines
    /// (legacy behaviour for plain-text pages).
    private static func joinBlocksReadingOrder(_ blocks: [Block]) -> String {
        guard !blocks.isEmpty else { return "" }
        let hasGeometry = blocks.contains { $0.boundingBox != nil }
        guard hasGeometry else {
            return blocks.map(\.text).joined(separator: "\n")
        }

        let sorted = blocks.sorted { a, b in
            switch (a.boundingBox, b.boundingBox) {
            case (let aBox?, let bBox?):
                if !sameReadingLine(aBox, bBox) {
                    return aBox.minY < bBox.minY
                }
                return aBox.minX < bBox.minX
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return false
            }
        }

        var lines: [String] = []
        var currentLine: [String] = []
        var currentLineBox: CGRect?

        func flushLine() {
            guard !currentLine.isEmpty else { return }
            lines.append(currentLine.joined(separator: " "))
            currentLine = []
            currentLineBox = nil
        }

        for block in sorted {
            guard let box = block.boundingBox else {
                flushLine()
                lines.append(block.text)
                continue
            }
            if let lineBox = currentLineBox, sameReadingLine(lineBox, box) {
                currentLine.append(block.text)
                currentLineBox = lineBox.union(box)
            } else {
                flushLine()
                currentLine = [block.text]
                currentLineBox = box
            }
        }
        flushLine()
        return lines.joined(separator: "\n")
    }

    private static func sameReadingLine(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        let minH = min(a.height, b.height)
        if minH > 0, overlap / minH >= 0.25 {
            return true
        }
        let tol = max(max(a.height, b.height) * 0.6, 0.008)
        return abs(a.midY - b.midY) <= tol
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
