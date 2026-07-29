import CoreGraphics
import Foundation

/// Conservative geometric table reconstruction from positioned text blocks.
///
/// The detector is intentionally **biased toward false negatives**. Emitting a bogus
/// table from ordinary prose would poison every downstream extraction, which is worse
/// than missing a real table. It only returns a table when multiple rows agree on
/// column boundaries with clear inter-cell gaps.
///
/// ## Thresholds
///
/// All geometry uses **normalized top-left** coordinates (`0...1` on the page/image).
///
/// | Parameter | Value | Rationale |
/// | --- | --- | --- |
/// | Row grouping | vertical IoU ≥ `0.25`, or mid-Y within `0.6 × max(height)` | Match OCR line fragments and PDF words on the same baseline without merging stacked lines. |
/// | Cell merge gap | horizontal gap ≤ `0.018` | Join words inside one cell (`Widget`+`Pro`) while keeping column gutters separate. |
/// | Min inter-cell gap | ≥ `0.03` in a row | Require a real gutter; rejects tight bullet+text pairs and single flowing lines. |
/// | Min rows / columns | `2` / `2` | One multi-column line (e.g. date + time) is not a table. |
/// | Column cluster tol. | `0.045` on min-X | Same column when left edges agree across rows; wide enough for OCR jitter. |
/// | Min column separation | `0.035` | Collapse near-duplicate clusters from ragged left edges. |
/// | Column agreement | ≥ `2` rows contribute to each kept column | Columns must be evidenced by more than one row (anti–single-outlier). |
/// | Numeric column | ≥ `50%` of filled cells look like numbers/currency | Strong invoice/receipt signal; relaxes length checks. |
/// | Non-numeric tables | max ≤ `6` words/cell, width ≤ `0.28`, ≥ `3` rows | Allows short label grids; rejects two-column article/sidebar layouts and prose. |
/// | List-marker columns | dropped when every cell is a bullet/dash | Avoids treating bulleted lists as 2-column tables. |
///
/// ## Known weak spots
///
/// - Tables without a numeric/currency column need short cells and ≥ 3 rows.
/// - Nested or multi-page tables are not merged across pages.
/// - Heavily skewed scans may fail column clustering.
/// - Header detection is keyword-based and optional; many real tables leave it `nil`.
public enum TableDetector {
    // MARK: - Thresholds (see type doc comment)

    private static let rowYOverlapMin: CGFloat = 0.25
    private static let rowMidYFactor: CGFloat = 0.6
    private static let rowMidYFloor: CGFloat = 0.008
    private static let cellMergeMaxGapX: CGFloat = 0.018
    private static let minInterCellGap: CGFloat = 0.03
    private static let minColumns = 2
    private static let minRows = 2
    private static let columnClusterTolerance: CGFloat = 0.045
    private static let minColumnSeparation: CGFloat = 0.035
    private static let minRowsSharingColumn = 2
    private static let numericColumnFraction = 0.5
    private static let maxProseWordsWithoutNumeric = 6
    private static let maxCellWidthWithoutNumeric: CGFloat = 0.28
    private static let minRowsWithoutNumeric = 3

    private static let headerKeywords: Set<String> = [
        "item", "items", "description", "desc", "qty", "quantity", "qty.", "price",
        "amount", "total", "unit", "date", "name", "product", "sku", "cost", "rate",
        "hours", "tax", "subtotal", "code", "id", "no", "no.", "#",
    ]

    /// Detect tables in positioned blocks, respecting ``TableDetectionMode``.
    ///
    /// - Parameters:
    ///   - blocks: Positioned text (boxes required; empty text is ignored).
    ///   - mode: `.off` returns `[]` immediately; `.automatic` runs detection.
    /// - Returns: Zero or more tables, in page order then top-to-bottom.
    public static func detect(
        in blocks: [TableSourceBlock],
        mode: TableDetectionMode = .automatic
    ) -> [ExtractedTable] {
        guard mode == .automatic else { return [] }
        let usable = blocks.compactMap { block -> TableSourceBlock? in
            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return TableSourceBlock(
                text: trimmed,
                pageIndex: block.pageIndex,
                boundingBox: block.boundingBox
            )
        }
        guard !usable.isEmpty else { return [] }

        let byPage = Dictionary(grouping: usable) { $0.pageIndex ?? 0 }
        var tables: [ExtractedTable] = []
        for page in byPage.keys.sorted() {
            guard let pageBlocks = byPage[page] else { continue }
            tables.append(contentsOf: detectOnPage(pageBlocks, pageIndex: page))
        }
        return tables
    }

    /// Convenience over internal document blocks (same geometry convention).
    static func detect(
        documentBlocks: [ExtractedDocument.Block],
        mode: TableDetectionMode = .automatic
    ) -> [ExtractedTable] {
        let sources: [TableSourceBlock] = documentBlocks.compactMap { block in
            guard let box = block.boundingBox else { return nil }
            return TableSourceBlock(text: block.text, pageIndex: block.pageIndex, boundingBox: box)
        }
        return detect(in: sources, mode: mode)
    }

    // MARK: - Page pipeline

    private static func detectOnPage(
        _ blocks: [TableSourceBlock],
        pageIndex: Int
    ) -> [ExtractedTable] {
        let rows = groupIntoRows(blocks)
        let rowCells = rows.map { mergeCells(in: $0) }

        let multiIndices = rowCells.indices.filter { rowCells[$0].count >= 2 }
        let bands = contiguousBands(multiIndices)

        var tables: [ExtractedTable] = []
        for band in bands {
            if let table = buildTable(band: band, rowCells: rowCells, pageIndex: pageIndex) {
                tables.append(table)
            }
        }
        return tables
    }

    // MARK: - Rows & cells

    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        let minH = min(a.height, b.height)
        if minH > 0, overlap / minH >= rowYOverlapMin {
            return true
        }
        let tol = max(max(a.height, b.height) * rowMidYFactor, rowMidYFloor)
        return abs(a.midY - b.midY) <= tol
    }

    private static func groupIntoRows(_ blocks: [TableSourceBlock]) -> [[TableSourceBlock]] {
        let sorted = blocks.sorted { a, b in
            if !sameRow(a.boundingBox, b.boundingBox) {
                return a.boundingBox.minY < b.boundingBox.minY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        var rows: [[TableSourceBlock]] = []
        for block in sorted {
            if var last = rows.last, let rep = last.first,
                sameRow(rep.boundingBox, block.boundingBox)
            {
                last.append(block)
                rows[rows.count - 1] = last
            } else {
                rows.append([block])
            }
        }
        return rows
    }

    private struct ProtoCell: Sendable {
        var text: String
        var box: CGRect
    }

    private static func mergeCells(in row: [TableSourceBlock]) -> [ProtoCell] {
        let ordered = row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        var cells: [ProtoCell] = []
        for block in ordered {
            if let last = cells.last {
                let gap = block.boundingBox.minX - last.box.maxX
                if gap <= cellMergeMaxGapX {
                    var merged = last
                    merged.text =
                        last.text.isEmpty
                        ? block.text
                        : last.text + " " + block.text
                    merged.box = last.box.union(block.boundingBox)
                    cells[cells.count - 1] = merged
                    continue
                }
            }
            cells.append(ProtoCell(text: block.text, box: block.boundingBox))
        }
        return cells
    }

    private static func contiguousBands(_ indices: [Int]) -> [[Int]] {
        guard !indices.isEmpty else { return [] }
        var bands: [[Int]] = []
        var current: [Int] = [indices[0]]
        for i in indices.dropFirst() {
            if let last = current.last, i == last + 1 {
                current.append(i)
            } else {
                bands.append(current)
                current = [i]
            }
        }
        bands.append(current)
        return bands
    }

    // MARK: - Table construction

    private static func buildTable(
        band: [Int],
        rowCells: [[ProtoCell]],
        pageIndex: Int
    ) -> ExtractedTable? {
        guard band.count >= minRows else { return nil }

        // Require clear gutters on enough rows.
        var gappyRows = 0
        for ri in band {
            let cells = rowCells[ri].sorted { $0.box.minX < $1.box.minX }
            for i in 0..<(cells.count - 1) {
                if cells[i + 1].box.minX - cells[i].box.maxX >= minInterCellGap {
                    gappyRows += 1
                    break
                }
            }
        }
        guard gappyRows >= minRows else { return nil }

        let allCells = band.flatMap { rowCells[$0] }
        var colCenters = clusterColumnCenters(allCells.map(\.box.minX))
        colCenters = mergeCloseCenters(colCenters)
        guard colCenters.count >= minColumns else { return nil }

        var gridText: [[String?]] = []
        var gridBox: [[CGRect?]] = []
        var colHits = Array(repeating: 0, count: colCenters.count)
        var goodRows = 0

        for ri in band {
            var texts = Array(repeating: Optional<String>.none, count: colCenters.count)
            var boxes = Array(repeating: Optional<CGRect>.none, count: colCenters.count)
            for cell in rowCells[ri] {
                guard let ci = nearestColumn(cell.box.minX, centers: colCenters) else { continue }
                if let existing = texts[ci] {
                    texts[ci] = existing + " " + cell.text
                    if let prev = boxes[ci] {
                        boxes[ci] = prev.union(cell.box)
                    }
                } else {
                    texts[ci] = cell.text
                    boxes[ci] = cell.box
                }
            }
            if texts.compactMap({ $0 }).count >= minColumns {
                goodRows += 1
            }
            for (ci, value) in texts.enumerated() where value != nil {
                colHits[ci] += 1
            }
            gridText.append(texts)
            gridBox.append(boxes)
        }

        let multiColCount = colHits.filter { $0 >= minRowsSharingColumn }.count
        guard multiColCount >= minColumns, goodRows >= minRows else { return nil }

        // Drop pure list-marker columns (bulleted lists).
        let keepCols = colCenters.indices.filter { ci in
            let values = gridText.compactMap { $0[ci] }
            guard !values.isEmpty else { return false }
            return !values.allSatisfy { isListMarker($0) }
        }
        guard keepCols.count >= minColumns else { return nil }

        let hasNumericColumn = keepCols.contains { ci in
            let values = gridText.compactMap { $0[ci] }
            guard !values.isEmpty else { return false }
            let numeric = values.filter { looksNumeric($0) }.count
            return Double(numeric) / Double(values.count) >= numericColumnFraction
        }

        if !hasNumericColumn {
            let texts = keepCols.flatMap { ci in gridText.compactMap { $0[ci] } }
            let widths = keepCols.flatMap { ci in gridBox.compactMap { $0[ci]?.width } }
            let maxWords = texts.map(wordCount).max() ?? 0
            let maxWidth = widths.max() ?? 0
            if maxWords > maxProseWordsWithoutNumeric || maxWidth > maxCellWidthWithoutNumeric {
                return nil
            }
            if goodRows < minRowsWithoutNumeric {
                return nil
            }
        }

        // Remap kept columns to 0..<N in left-to-right order.
        let orderedKeep = keepCols.sorted { colCenters[$0] < colCenters[$1] }
        var cells: [ExtractedTable.Cell] = []
        for (outRow, _) in band.enumerated() {
            for (outCol, srcCol) in orderedKeep.enumerated() {
                guard let text = gridText[outRow][srcCol] else { continue }
                let trimmed = stripLeadingListMarker(
                    text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                guard !trimmed.isEmpty else { continue }
                cells.append(
                    ExtractedTable.Cell(
                        text: trimmed,
                        row: outRow,
                        column: outCol,
                        boundingBox: gridBox[outRow][srcCol]
                    )
                )
            }
        }
        guard !cells.isEmpty else { return nil }

        let rowCount = band.count
        let columnCount = orderedKeep.count
        let header = detectHeaderRow(gridText: gridText, keepCols: orderedKeep)

        return ExtractedTable(
            pageIndex: pageIndex,
            rowCount: rowCount,
            columnCount: columnCount,
            cells: cells,
            headerRowIndex: header
        )
    }

    private static func clusterColumnCenters(_ xs: [CGFloat]) -> [CGFloat] {
        let sorted = xs.sorted()
        guard !sorted.isEmpty else { return [] }
        var clusters: [[CGFloat]] = []
        for x in sorted {
            if var last = clusters.last {
                let mean = last.reduce(0, +) / CGFloat(last.count)
                if abs(x - mean) <= columnClusterTolerance {
                    last.append(x)
                    clusters[clusters.count - 1] = last
                    continue
                }
            }
            clusters.append([x])
        }
        return clusters.map { $0.reduce(0, +) / CGFloat($0.count) }
    }

    private static func mergeCloseCenters(_ centers: [CGFloat]) -> [CGFloat] {
        let sorted = centers.sorted()
        var merged: [CGFloat] = []
        for c in sorted {
            if let last = merged.last, abs(c - last) < minColumnSeparation {
                merged[merged.count - 1] = (last + c) / 2
            } else {
                merged.append(c)
            }
        }
        return merged
    }

    private static func nearestColumn(_ x: CGFloat, centers: [CGFloat]) -> Int? {
        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, center) in centers.enumerated() {
            let distance = abs(x - center)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        // Reject outliers that don't land near any column (avoids wrong-column pull).
        guard bestDistance <= columnClusterTolerance * 1.5 else { return nil }
        return bestIndex
    }

    // MARK: - Heuristics

    private static func isListMarker(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch t {
        case "-", "–", "—", "*", "•", "·", "●", "◦":
            return true
        default:
            return t.count == 1
                && !t.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }
    }

    /// Strip a leading list bullet only when it is clearly decorative.
    ///
    /// PDF/OCR often merges a bullet glyph with the cell (`"- Widget Pro"`). Remove that
    /// prefix when the marker is followed by whitespace and remaining content. Do **not**
    /// strip a lone `-` (nil/none) or a negative amount (`-12.50`) where the dash is
    /// immediately followed by a non-space character.
    private static func stripLeadingListMarker(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return t }
        switch first {
        case "-", "–", "—", "*", "•", "·", "●", "◦":
            break
        default:
            return t
        }
        let afterMarker = t.dropFirst()
        guard let next = afterMarker.first, next.isWhitespace else { return t }
        let stripped = String(afterMarker.drop(while: \.isWhitespace))
        return stripped.isEmpty ? t : stripped
    }

    private static func looksNumeric(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        for currency in ["$", "€", "£", "¥"] {
            t = t.replacingOccurrences(of: currency, with: "")
        }
        t = t.replacingOccurrences(of: ",", with: "")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.contains(where: \.isNumber) else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789.-")
        return t.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func detectHeaderRow(
        gridText: [[String?]],
        keepCols: [Int]
    ) -> Int? {
        guard let first = gridText.first else { return nil }
        let values = keepCols.compactMap { first[$0]?.lowercased() }
        guard values.count >= minColumns else { return nil }
        let hits = values.filter { value in
            let token = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            return headerKeywords.contains(value) || headerKeywords.contains(token)
        }.count
        // Majority of first-row labels look like headers; none look like pure amounts.
        let anyNumeric = values.contains { looksNumeric($0) }
        guard !anyNumeric, Double(hits) / Double(values.count) >= 0.5 else { return nil }
        return 0
    }
}
