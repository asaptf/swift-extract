import CoreGraphics
import Foundation

/// Normalized document produced by source adapters (internal).
struct ExtractedDocument: Sendable, Equatable {
    struct Block: Sendable, Equatable {
        var text: String
        var pageIndex: Int?
        /// Normalised page/image box when known.
        ///
        /// Convention (shared by PDF text-layer and Vision OCR adapters): origin at the
        /// **top-left**, x right / y down, components in `0...1` relative to the page
        /// media box or image size. See ``FieldProvenance``.
        var boundingBox: CGRect?
    }

    var blocks: [Block]
    var sourceDescription: String
    /// True when a PDF used OCR because the text layer was missing or below the quality gate.
    var usedOCRFallback: Bool
    /// Clockwise degrees each page was turned by before it was read, keyed by page index.
    ///
    /// Boxes in ``Block/boundingBox`` are in the turned frame — the one the text reads
    /// upright in — not the frame the page is stored in. A caller that renders the page
    /// for a person to look at has to turn it the same way, or every box it draws lands
    /// somewhere the value is not. Pages that were not turned are absent.
    var pageRotations: [Int: Int]

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

    init(
        blocks: [Block], sourceDescription: String, usedOCRFallback: Bool = false,
        pageRotations: [Int: Int] = [:]
    ) {
        self.blocks = blocks
        self.sourceDescription = sourceDescription
        self.usedOCRFallback = usedOCRFallback
        self.pageRotations = pageRotations
    }

    init(text: String, sourceDescription: String = "text", usedOCRFallback: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self.blocks = []
        } else {
            self.blocks = [Block(text: trimmed, pageIndex: nil, boundingBox: nil)]
        }
        self.sourceDescription = sourceDescription
        self.usedOCRFallback = usedOCRFallback
        self.pageRotations = [:]
    }

    /// Split into character-budget chunks, preferring page boundaries.
    ///
    /// When a single page exceeds the budget it is hard-split. Split points prefer a
    /// line boundary (newline), then any whitespace, within a window around the budget
    /// cut — never mid-token when a boundary exists in that window.
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
                    sourceDescription: "\(sourceDescription)#chunk\(result.count + 1)",
                    usedOCRFallback: usedOCRFallback,
                    pageRotations: pageRotations
                )
            )
            currentBlocks = []
            currentCount = 0
        }

        for item in pageTexts {
            if item.text.count > budget {
                flush()
                for slice in Self.hardSplit(item.text, budget: budget) {
                    result.append(
                        ExtractedDocument(
                            blocks: [Block(text: slice, pageIndex: item.page, boundingBox: nil)],
                            sourceDescription: "\(sourceDescription)#chunk\(result.count + 1)",
                            usedOCRFallback: usedOCRFallback,
                            pageRotations: pageRotations
                        )
                    )
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

    /// Characters searched either side of the budget cut when choosing a split point.
    private static let hardSplitBoundaryWindow = 80

    /// Split `text` into slices of at most `budget` characters, preferring line then
    /// whitespace boundaries so tokens are not cut mid-word when avoidable.
    static func hardSplit(_ text: String, budget: Int) -> [String] {
        guard budget > 0 else { return [text] }
        guard text.count > budget else { return text.isEmpty ? [] : [text] }

        var slices: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let hardEnd =
                text.index(start, offsetBy: budget, limitedBy: text.endIndex) ?? text.endIndex
            if hardEnd == text.endIndex {
                let rest = String(text[start..<hardEnd])
                if !rest.isEmpty { slices.append(rest) }
                break
            }

            let end = preferredSplitEnd(in: text, start: start, hardEnd: hardEnd, budget: budget)
            let slice = String(text[start..<end])
            if slice.isEmpty {
                // Pathological: no progress (e.g. budget 0 already guarded). Force one char.
                let forced =
                    text.index(start, offsetBy: 1, limitedBy: text.endIndex) ?? text.endIndex
                slices.append(String(text[start..<forced]))
                start = forced
            } else {
                slices.append(slice)
                start = end
            }
        }
        return slices
    }

    /// Choose a split index in `(start, hardEnd]` (or slightly past `hardEnd`) that lands
    /// on a line or whitespace boundary when one exists near the budget cut.
    private static func preferredSplitEnd(
        in text: String,
        start: String.Index,
        hardEnd: String.Index,
        budget: Int
    ) -> String.Index {
        let window = min(hardSplitBoundaryWindow, budget)
        let backLo = text.index(hardEnd, offsetBy: -window, limitedBy: start) ?? start
        let forwardHi =
            text.index(hardEnd, offsetBy: window, limitedBy: text.endIndex) ?? text.endIndex

        // Prefer the last newline at or before hardEnd within the back window.
        if let idx = lastBoundary(
            in: text,
            range: backLo..<hardEnd,
            predicate: { $0.isNewline },
            afterStart: start
        ) {
            return idx
        }
        // Else first newline at/after hardEnd within the forward window.
        if let idx = firstBoundary(
            in: text,
            range: hardEnd..<forwardHi,
            predicate: { $0.isNewline }
        ) {
            return idx
        }

        // Whitespace (not newline — already checked): back then forward.
        if let idx = lastBoundary(
            in: text,
            range: backLo..<hardEnd,
            predicate: { $0.isWhitespace },
            afterStart: start
        ) {
            return idx
        }
        if let idx = firstBoundary(
            in: text,
            range: hardEnd..<forwardHi,
            predicate: { $0.isWhitespace }
        ) {
            return idx
        }

        // No boundary in the window: hard cut (token longer than the window).
        return hardEnd
    }

    /// Index just after the last character in `range` matching `predicate`, if that
    /// index is strictly after `afterStart`.
    private static func lastBoundary(
        in text: String,
        range: Range<String.Index>,
        predicate: (Character) -> Bool,
        afterStart: String.Index
    ) -> String.Index? {
        var best: String.Index?
        var i = range.lowerBound
        while i < range.upperBound {
            let ch = text[i]
            let next = text.index(after: i)
            if predicate(ch), next > afterStart {
                best = next
            }
            i = next
        }
        return best
    }

    /// Index just after the first character in `range` matching `predicate`.
    private static func firstBoundary(
        in text: String,
        range: Range<String.Index>,
        predicate: (Character) -> Bool
    ) -> String.Index? {
        var i = range.lowerBound
        while i < range.upperBound {
            let ch = text[i]
            let next = text.index(after: i)
            if predicate(ch) {
                return next
            }
            i = next
        }
        return nil
    }
}
