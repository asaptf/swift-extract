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
/// | Column cluster tol. | `0.05` on anchor-X | Same column when anchors agree across rows; wide enough for OCR jitter and amount width. |
/// | Min column separation | `0.04` | Collapse near-duplicate clusters from ragged left/right edges. |
/// | Column agreement | ≥ `2` rows, and ≥ `25%` of band rows | Columns must be evidenced across the band (anti–single-outlier / empty gutters). |
/// | Region vertical gap | ≥ `max(0.12, 5.0 × median row height)` | Split line-item blocks from totals/payment blocks; still bridges short description lines under items. |
/// | Horizontal corridor | mid-X gap ≥ `0.06`, and ≥ `1.25×` each band's max internal mid-X gap | Side-by-side documents / column bands (recursive XY-cut); refuses evenly spaced table gutters. |
/// | Corridor Y-overlap | ≥ `0.25` of the shorter band's height | Requires true side-by-side layout, not sequential left-then-right stacks. |
/// | Corridor multi-col | ≥ `2` multi-column rows on **each** band | Both sides must look independently tabular before a horizontal cut is kept. |
/// | XY-cut depth | ≤ `3` | Bounds recursive horizontal + vertical region splits. |
/// | Min fill density | `0.55` of row×col cells non-empty | Reject sparse merged grids that poison stage-2 prompts. |
/// | Numeric column | ≥ `50%` of filled cells look like numbers/currency | Strong invoice/receipt signal; relaxes length checks. |
/// | Non-numeric tables | max ≤ `6` words/cell, width ≤ `0.28`, ≥ `3` rows | Allows short label grids; rejects two-column article/sidebar layouts and prose. |
/// | List-marker columns | dropped when every cell is a bullet/dash | Avoids treating bulleted lists as 2-column tables. |
///
/// ## Region decomposition (recursive XY-cut)
///
/// Before row grouping, a page (or band) is optionally split on a **vertical whitespace
/// corridor**: the largest gap between successive block mid-X values, kept only when it is
/// wide relative to each side's internal mid-X structure, both sides have multi-column rows,
/// and their Y-ranges overlap. Each band is then processed independently — vertical gap
/// splits (line items vs totals) run inside the band, and horizontal splits may recurse.
/// This separates side-by-side documents that share Y-ranges (which would otherwise merge
/// into one sparse mega-grid) without cutting ordinary single-document line-item tables.
///
/// ## Known weak spots
///
/// - Tables without a numeric/currency column need short cells and ≥ 3 rows.
/// - Nested or multi-page tables are not merged across pages.
/// - Heavily skewed scans may fail column clustering.
/// - Header detection is keyword-based and optional; many real tables leave it `nil`.
/// - Abutting side-by-side scans with mid-X separation &lt; `0.06` may still merge.
public enum TableDetector {
    // MARK: - Thresholds (see type doc comment)

    private static let rowYOverlapMin: CGFloat = 0.25
    private static let rowMidYFactor: CGFloat = 0.6
    private static let rowMidYFloor: CGFloat = 0.008
    private static let cellMergeMaxGapX: CGFloat = 0.018
    private static let minInterCellGap: CGFloat = 0.03
    private static let minColumns = 2
    private static let minRows = 2
    private static let columnClusterTolerance: CGFloat = 0.05
    private static let minColumnSeparation: CGFloat = 0.04
    private static let minRowsSharingColumn = 2
    private static let minColumnFillFraction = 0.25
    private static let minFillDensity = 0.55
    /// Vertical gap (normalized) above which multi-column rows start a new region.
    /// Must clear short description blocks under a line item (~0.09 on Sammy) while still
    /// splitting line items from totals (Coolblue gap ≈ 0.27).
    private static let regionGapFloor: CGFloat = 0.12
    private static let regionGapFactor: CGFloat = 5.0
    /// Minimum mid-X gap between successive blocks to propose a horizontal (column-band) cut.
    /// Tuned on the invoice corpus: side-by-side docs (hard/invoice_table_detect_img1) sit
    /// around ~0.08; single-document line-item gutters on Coolblue/Sammy peak near ~0.05–0.06.
    private static let horizontalCorridorMinMidGap: CGFloat = 0.06
    /// Corridor must outscale each band's largest internal mid-X gap (avoids bisecting an
    /// evenly spaced multi-column table into two half-grids).
    private static let horizontalCorridorInternalFactor: CGFloat = 1.25
    /// Shared vertical extent of the two bands, as a fraction of the shorter band height.
    private static let horizontalCorridorMinYOverlap: CGFloat = 0.25
    private static let xyCutMaxDepth = 3
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

    // MARK: - Page pipeline (recursive XY-cut)

    private static func detectOnPage(
        _ blocks: [TableSourceBlock],
        pageIndex: Int
    ) -> [ExtractedTable] {
        detectInRegion(blocks, pageIndex: pageIndex, depth: 0)
    }

    /// Recursive XY-cut: optional horizontal corridor split, then vertical multi-col
    /// region split + table build inside each band.
    private static func detectInRegion(
        _ blocks: [TableSourceBlock],
        pageIndex: Int,
        depth: Int
    ) -> [ExtractedTable] {
        guard blocks.count >= minRows * minColumns else { return [] }

        // Horizontal cut first (column bands), before row grouping merges side-by-side
        // documents that share the same Y ranges into one sparse mega-grid.
        if depth < xyCutMaxDepth, let (left, right) = horizontalSplit(blocks) {
            return detectInRegion(left, pageIndex: pageIndex, depth: depth + 1)
                + detectInRegion(right, pageIndex: pageIndex, depth: depth + 1)
        }

        let rows = groupIntoRows(blocks)
        let rowCells = rows.map { mergeCells(in: $0) }

        let multiIndices = rowCells.indices.filter { rowCells[$0].count >= 2 }
        // Group multi-column rows by vertical proximity, skipping single-column
        // interruptions (e.g. description lines under a line item). A large gap still
        // starts a new region (line items vs totals).
        let regionBands = multiColRegions(multiIndices, rowCells: rowCells)

        var tables: [ExtractedTable] = []
        for band in regionBands {
            tables.append(
                contentsOf: buildTablesFromBand(band, rowCells: rowCells, pageIndex: pageIndex)
            )
        }
        return tables
    }

    /// Propose a left/right column-band split on the largest mid-X gap, if it looks like
    /// a persistent side-by-side corridor rather than an ordinary table gutter.
    private static func horizontalSplit(
        _ blocks: [TableSourceBlock]
    ) -> ([TableSourceBlock], [TableSourceBlock])? {
        // Need enough blocks on each side after a cut for two independent grids.
        guard blocks.count >= minRows * minColumns * 2 else { return nil }

        let sortedByMid = blocks.sorted { $0.boundingBox.midX < $1.boundingBox.midX }
        let mids = sortedByMid.map(\.boundingBox.midX)

        var bestGap: CGFloat = 0
        var bestIndex: Int?  // split after mids[bestIndex] / before mids[bestIndex+1]
        let minSide = minRows * minColumns
        for i in 0..<(mids.count - 1) {
            let leftCount = i + 1
            let rightCount = mids.count - leftCount
            guard leftCount >= minSide, rightCount >= minSide else { continue }
            let gap = mids[i + 1] - mids[i]
            if gap > bestGap {
                bestGap = gap
                bestIndex = i
            }
        }
        guard let bestIndex, bestGap >= horizontalCorridorMinMidGap else { return nil }

        let leftMaxMid = mids[bestIndex]
        let rightMinMid = mids[bestIndex + 1]
        let left = sortedByMid.filter { $0.boundingBox.midX <= leftMaxMid + .ulpOfOne }
        let right = sortedByMid.filter { $0.boundingBox.midX >= rightMinMid - .ulpOfOne }
        guard left.count >= minSide, right.count >= minSide else { return nil }

        // Side-by-side, not sequential: Y ranges must overlap substantially.
        guard yOverlapFraction(left, right) >= horizontalCorridorMinYOverlap else {
            return nil
        }

        // Both bands must look independently multi-column (rejects bisecting a single
        // line-item table into "description | amounts").
        guard multiColumnRowCount(left) >= minRows,
            multiColumnRowCount(right) >= minRows
        else { return nil }

        // Corridor must outscale each band's own largest internal mid-X gap so evenly
        // spaced multi-column tables are not halved.
        let leftInternal = maxSuccessiveMidGap(left)
        let rightInternal = maxSuccessiveMidGap(right)
        let internalScale = max(max(leftInternal, rightInternal), minInterCellGap)
        guard bestGap >= horizontalCorridorInternalFactor * internalScale else {
            return nil
        }

        return (left, right)
    }

    private static func yOverlapFraction(
        _ left: [TableSourceBlock],
        _ right: [TableSourceBlock]
    ) -> CGFloat {
        guard let lMin = left.map(\.boundingBox.minY).min(),
            let lMax = left.map(\.boundingBox.maxY).max(),
            let rMin = right.map(\.boundingBox.minY).min(),
            let rMax = right.map(\.boundingBox.maxY).max()
        else { return 0 }
        let overlap = max(0, min(lMax, rMax) - max(lMin, rMin))
        let shorter = min(lMax - lMin, rMax - rMin)
        guard shorter > rowMidYFloor else { return 0 }
        return overlap / shorter
    }

    private static func maxSuccessiveMidGap(_ blocks: [TableSourceBlock]) -> CGFloat {
        let mids = blocks.map(\.boundingBox.midX).sorted()
        guard mids.count >= 2 else { return 0 }
        var best: CGFloat = 0
        for i in 0..<(mids.count - 1) {
            best = max(best, mids[i + 1] - mids[i])
        }
        return best
    }

    /// Count rows that contain ≥ `minColumns` cells after local merge (used to validate
    /// horizontal split candidates without building a full table).
    private static func multiColumnRowCount(_ blocks: [TableSourceBlock]) -> Int {
        let rows = groupIntoRows(blocks)
        var count = 0
        for row in rows {
            if mergeCells(in: row).count >= minColumns {
                count += 1
            }
        }
        return count
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

    /// Group multi-column rows into layout regions.
    ///
    /// Consecutive multi-column rows (in reading order) stay in the same region while
    /// their vertical gap is small. Single-column rows between them are ignored for
    /// membership — that bridges invoice line items separated by description/notes
    /// lines without pulling in a distant totals block after a larger gap.
    private static func multiColRegions(
        _ multiIndices: [Int],
        rowCells: [[ProtoCell]]
    ) -> [[Int]] {
        guard !multiIndices.isEmpty else { return [] }

        let heights: [CGFloat] = multiIndices.compactMap { ri in
            let boxes = rowCells[ri].map(\.box)
            guard let minY = boxes.map(\.minY).min(), let maxY = boxes.map(\.maxY).max()
            else { return nil }
            return max(maxY - minY, rowMidYFloor)
        }
        let medianHeight = median(heights) ?? rowMidYFloor
        // Bridge threshold: allow a few single-col description lines under an item.
        // Split threshold: same scale — a deliberate whitespace gap starts a new region.
        let gapThreshold = max(regionGapFloor, medianHeight * regionGapFactor)

        var regions: [[Int]] = []
        var current: [Int] = [multiIndices[0]]
        for next in multiIndices.dropFirst() {
            let prev = current[current.count - 1]
            let prevMaxY = rowCells[prev].map(\.box.maxY).max() ?? 0
            let nextMinY = rowCells[next].map(\.box.minY).min() ?? 0
            let gap = nextMinY - prevMaxY
            if gap < gapThreshold {
                current.append(next)
            } else {
                if current.count >= minRows {
                    regions.append(current)
                } else if let last = regions.last {
                    // Short orphan after a split: attach only if still near previous region.
                    let joinFrom = last[last.count - 1]
                    let fromMax = rowCells[joinFrom].map(\.box.maxY).max() ?? 0
                    let toMin = rowCells[current[0]].map(\.box.minY).min() ?? 0
                    if toMin - fromMax < gapThreshold * 1.25 {
                        regions[regions.count - 1] = last + current
                    }
                }
                current = [next]
            }
        }
        if current.count >= minRows {
            regions.append(current)
        } else if let last = regions.last, !current.isEmpty {
            let joinFrom = last[last.count - 1]
            let fromMax = rowCells[joinFrom].map(\.box.maxY).max() ?? 0
            let toMin = rowCells[current[0]].map(\.box.minY).min() ?? 0
            if toMin - fromMax < gapThreshold * 1.25 {
                regions[regions.count - 1] = last + current
            }
        }
        return regions
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    // MARK: - Table construction

    /// Build zero or more tables from a region band, splitting further when a single
    /// grid would be too sparse (merged layout blocks with incompatible columns).
    private static func buildTablesFromBand(
        _ band: [Int],
        rowCells: [[ProtoCell]],
        pageIndex: Int,
        depth: Int = 0
    ) -> [ExtractedTable] {
        guard band.count >= minRows else { return [] }

        if let table = buildTable(band: band, rowCells: rowCells, pageIndex: pageIndex) {
            return [table]
        }

        // Sparse / incompatible column structure: try splitting at the largest internal gap.
        guard depth < 3, band.count >= minRows * 2 else { return [] }
        guard let split = largestInternalGapSplit(band, rowCells: rowCells) else { return [] }
        let left = Array(band[..<split])
        let right = Array(band[split...])
        guard left.count >= minRows, right.count >= minRows else { return [] }
        return buildTablesFromBand(left, rowCells: rowCells, pageIndex: pageIndex, depth: depth + 1)
            + buildTablesFromBand(right, rowCells: rowCells, pageIndex: pageIndex, depth: depth + 1)
    }

    private static func largestInternalGapSplit(
        _ band: [Int],
        rowCells: [[ProtoCell]]
    ) -> Int? {
        guard band.count >= 4 else { return nil }
        var bestSplit: Int?
        var bestGap: CGFloat = 0
        for i in 1..<(band.count) {
            let prev = band[i - 1]
            let next = band[i]
            let prevMaxY = rowCells[prev].map(\.box.maxY).max() ?? 0
            let nextMinY = rowCells[next].map(\.box.minY).min() ?? 0
            let gap = nextMinY - prevMaxY
            // Prefer splits that leave both sides with enough rows.
            let leftCount = i
            let rightCount = band.count - i
            guard leftCount >= minRows, rightCount >= minRows else { continue }
            if gap > bestGap {
                bestGap = gap
                bestSplit = i
            }
        }
        // Only split when the gap is meaningful (at least the region floor).
        guard let bestSplit, bestGap >= regionGapFloor * 0.75 else { return nil }
        return bestSplit
    }

    private static func buildTable(
        band: [Int],
        rowCells: [[ProtoCell]],
        pageIndex: Int
    ) -> ExtractedTable? {
        guard band.count >= minRows else { return nil }

        // Prefer "spine" rows: wide multi-column rows that look like line items (multiple
        // numeric cells) or a header (keyword labels). Description / notes under an item
        // often have many word boxes but no amount column — including them when clustering
        // invents phantom gutters and then density-rejects the real grid.
        let maxCellsInBand = band.map { rowCells[$0].count }.max() ?? 0
        let spineMinCells = max(minColumns, maxCellsInBand - 1)
        var spineBand = band.filter { ri in
            isSpineRow(rowCells[ri], minCells: spineMinCells)
        }
        // Fallback: if the numeric/header gate is too strict (e.g. pure label grids),
        // keep the wide rows only.
        if spineBand.count < minRows {
            spineBand = band.filter { rowCells[$0].count >= spineMinCells }
        }
        guard spineBand.count >= minRows else { return nil }

        // Require clear gutters on enough spine rows.
        var gappyRows = 0
        for ri in spineBand {
            let cells = rowCells[ri].sorted { $0.box.minX < $1.box.minX }
            for i in 0..<(cells.count - 1) {
                if cells[i + 1].box.minX - cells[i].box.maxX >= minInterCellGap {
                    gappyRows += 1
                    break
                }
            }
        }
        guard gappyRows >= minRows else { return nil }

        let allCells = spineBand.flatMap { rowCells[$0] }
        // Anchor on minX (left edge). Invoice amounts may be right-aligned, but headers
        // in the same column are left-of-column; minX + a slightly wider cluster tolerance
        // keeps header+value together without inventing mid-description phantom columns.
        var colCenters = clusterColumnCenters(allCells.map(\.box.minX))
        colCenters = mergeCloseCenters(colCenters)
        guard colCenters.count >= minColumns else { return nil }

        var gridText: [[String?]] = []
        var gridBox: [[CGRect?]] = []
        var colHits = Array(repeating: 0, count: colCenters.count)
        var goodRows = 0

        for ri in spineBand {
            var texts = Array(repeating: Optional<String>.none, count: colCenters.count)
            var boxes = Array(repeating: Optional<CGRect>.none, count: colCenters.count)
            for cell in rowCells[ri] {
                guard let ci = nearestColumn(cell.box.minX, centers: colCenters) else {
                    continue
                }
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

        let bandRowCount = spineBand.count
        let minHitsForColumn = max(
            minRowsSharingColumn,
            Int(ceil(Double(bandRowCount) * minColumnFillFraction))
        )

        // Drop pure list-marker columns, all-empty columns, and sparse phantom columns.
        let keepCols = colCenters.indices.filter { ci in
            let values = gridText.compactMap { $0[ci] }
            guard !values.isEmpty else { return false }
            guard colHits[ci] >= minHitsForColumn else { return false }
            return !values.allSatisfy { isListMarker($0) }
        }
        guard keepCols.count >= minColumns else { return nil }
        guard goodRows >= minRows else { return nil }

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
        let columnCount = orderedKeep.count
        // Drop under-filled spine rows (stragglers that only touch part of the grid).
        let minFilledPerRow = max(minColumns, columnCount - 1)

        var keptLocalRows: [Int] = []
        for outRow in gridText.indices {
            let filled = orderedKeep.filter { gridText[outRow][$0] != nil }.count
            if filled >= minFilledPerRow {
                keptLocalRows.append(outRow)
            }
        }
        guard keptLocalRows.count >= minRows else { return nil }

        // Recompute column keep on the filtered rows only.
        let filteredHits: [Int] = orderedKeep.map { srcCol in
            keptLocalRows.reduce(0) { acc, outRow in
                acc + (gridText[outRow][srcCol] != nil ? 1 : 0)
            }
        }
        let minHitsFiltered = max(
            minRowsSharingColumn,
            Int(ceil(Double(keptLocalRows.count) * minColumnFillFraction))
        )
        let finalKeepLocal = orderedKeep.indices.filter { li in
            filteredHits[li] >= minHitsFiltered
        }
        guard finalKeepLocal.count >= minColumns else { return nil }
        let finalKeep = finalKeepLocal.map { orderedKeep[$0] }
        let finalColumnCount = finalKeep.count
        let finalMinFilled = max(minColumns, finalColumnCount - 1)

        var finalLocalRows: [Int] = []
        for outRow in keptLocalRows {
            let filled = finalKeep.filter { gridText[outRow][$0] != nil }.count
            if filled >= finalMinFilled {
                finalLocalRows.append(outRow)
            }
        }
        guard finalLocalRows.count >= minRows else { return nil }

        var cells: [ExtractedTable.Cell] = []
        for (newRow, outRow) in finalLocalRows.enumerated() {
            for (outCol, srcCol) in finalKeep.enumerated() {
                guard let text = gridText[outRow][srcCol] else { continue }
                let trimmed = stripLeadingListMarker(
                    text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                guard !trimmed.isEmpty else { continue }
                cells.append(
                    ExtractedTable.Cell(
                        text: trimmed,
                        row: newRow,
                        column: outCol,
                        boundingBox: gridBox[outRow][srcCol]
                    )
                )
            }
        }
        guard !cells.isEmpty else { return nil }

        let rowCount = finalLocalRows.count

        // Hard requirement: never emit an all-empty column.
        for c in 0..<finalColumnCount {
            let filled = cells.contains { $0.column == c }
            guard filled else { return nil }
        }

        let capacity = rowCount * finalColumnCount
        let density = Double(cells.count) / Double(max(capacity, 1))
        guard density >= minFillDensity else { return nil }

        var finalGoodRows = 0
        for r in 0..<rowCount {
            let filled = cells.filter { $0.row == r }.count
            if filled >= minColumns { finalGoodRows += 1 }
        }
        guard finalGoodRows >= minRows else { return nil }

        let headerGrid = finalLocalRows.map { gridText[$0] }
        let header = detectHeaderRow(gridText: headerGrid, keepCols: finalKeep)

        return ExtractedTable(
            pageIndex: pageIndex,
            rowCount: rowCount,
            columnCount: finalColumnCount,
            cells: cells,
            headerRowIndex: header
        )
    }

    /// Whether a row should contribute to column clustering for a region.
    ///
    /// Line-item rows almost always carry ≥2 numeric tokens (qty + amount, or unit +
    /// total). Header rows are short keyword labels. Free-text description/notes lines
    /// fail both checks even when they happen to have many word boxes.
    private static func isSpineRow(_ cells: [ProtoCell], minCells: Int) -> Bool {
        guard cells.count >= minColumns else { return false }
        // Wide enough relative to the band's richest rows, or a short header/label row.
        let wideEnough = cells.count >= minCells
        let numericCount = cells.filter { looksNumeric($0.text) }.count
        // Any numeric token on a multi-col row is line-item-like (qty and/or amount).
        // Description/notes lines under items are usually non-numeric free text.
        if numericCount >= 1, wideEnough || cells.count >= 3 { return true }
        if numericCount >= 2 { return true }
        // Placeholder cells like a lone "-" (nil amount) still belong on the spine.
        if cells.contains(where: { isListMarker($0.text) }), wideEnough || cells.count >= minColumns {
            return true
        }
        let labels = cells.map { $0.text.lowercased() }
        let headerHits = labels.filter { value in
            let token = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            return headerKeywords.contains(value) || headerKeywords.contains(token)
        }.count
        return headerHits >= 2
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
        // Common invoice currency prefixes that appear before an amount token.
        let upper = t.uppercased()
        for prefix in ["EUR", "USD", "GBP", "CHF", "CAD", "AUD"] {
            if upper.hasPrefix(prefix) {
                t = String(t.dropFirst(prefix.count))
                break
            }
        }
        t = t.replacingOccurrences(of: ",", with: "")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Percentages count as numeric column signal (tax rates).
        if t.hasSuffix("%") {
            t = String(t.dropLast()).trimmingCharacters(in: .whitespaces)
        }
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
