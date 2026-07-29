import CoreGraphics
import Foundation

/// A geometrically reconstructed table from positioned document text.
///
/// Produced by ``TableDetector``. Cells keep their grid coordinates and optional
/// bounding boxes (normalized top-left, same convention as OCR / PDF adapters).
/// Stage-2 prompting uses ``markdown()``; the grid is also useful for tests and debugging.
public struct ExtractedTable: Sendable, Equatable {
    /// One cell in the reconstructed grid.
    public struct Cell: Sendable, Equatable {
        /// Visible cell text (words merged left-to-right within the cell).
        public let text: String
        /// Zero-based row index within this table.
        public let row: Int
        /// Zero-based column index within this table.
        public let column: Int
        /// Normalized top-left bounding box covering the cell's source text, when known.
        public let boundingBox: CGRect?

        public init(text: String, row: Int, column: Int, boundingBox: CGRect? = nil) {
            self.text = text
            self.row = row
            self.column = column
            self.boundingBox = boundingBox
        }
    }

    /// Page index (0-based) this table was detected on.
    public let pageIndex: Int
    /// Number of rows in the grid (including an optional header row).
    public let rowCount: Int
    /// Number of columns in the grid.
    public let columnCount: Int
    /// All non-empty cells (sparse rows may omit trailing empties from this list).
    public let cells: [Cell]
    /// Row index of a detected header, when the first row looks like column labels.
    public let headerRowIndex: Int?

    public init(
        pageIndex: Int,
        rowCount: Int,
        columnCount: Int,
        cells: [Cell],
        headerRowIndex: Int? = nil
    ) {
        self.pageIndex = pageIndex
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.cells = cells
        self.headerRowIndex = headerRowIndex
    }

    /// Text of the cell at `(row, column)`, or `nil` when the cell is empty / absent.
    public func text(row: Int, column: Int) -> String? {
        cells.first { $0.row == row && $0.column == column }?.text
    }

    /// Markdown pipe table for prompting, tests, and debugging.
    ///
    /// Empty cells render as blank. When ``headerRowIndex`` is set, that row is emitted
    /// first (above the separator) and every other row is a body row — that path is
    /// correct and unchanged.
    ///
    /// When no header was detected (`headerRowIndex == nil`), **no data row is promoted
    /// into the header position**. GFM still requires a header line before the separator,
    /// so this method emits a placeholder header of empty cells, then the separator, then
    /// every data row in order. Empty placeholders are intentional: inventing labels
    /// (e.g. "Column 1") would mislead a model reading the prompt, and using the first
    /// data row as a header would drop a line item. Debug readers and stage-2 prompts
    /// both see the same honest grid.
    public func markdown() -> String {
        guard rowCount > 0, columnCount > 0 else { return "" }

        var grid = Array(
            repeating: Array(repeating: "", count: columnCount),
            count: rowCount
        )
        for cell in cells {
            guard cell.row >= 0, cell.row < rowCount, cell.column >= 0, cell.column < columnCount
            else { continue }
            grid[cell.row][cell.column] = cell.text
        }

        func pipeRow(_ values: [String]) -> String {
            "| " + values.map(escapeCell).joined(separator: " | ") + " |"
        }

        let separator = "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |"
        var lines: [String] = []
        if let header = headerRowIndex, header >= 0, header < rowCount {
            lines.append(pipeRow(grid[header]))
            lines.append(separator)
            for r in 0..<rowCount where r != header {
                lines.append(pipeRow(grid[r]))
            }
        } else {
            // Placeholder header only — keep every data row in the body.
            lines.append(pipeRow(Array(repeating: "", count: columnCount)))
            lines.append(separator)
            for r in 0..<rowCount {
                lines.append(pipeRow(grid[r]))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func escapeCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A positioned text fragment used as input to ``TableDetector``.
///
/// Coordinates must be **normalized top-left** (origin at the top-left of the page/image,
/// x and y in `0...1`), matching ``ExtractedDocument.Block`` / Vision / PDF adapters.
public struct TableSourceBlock: Sendable, Equatable {
    /// Fragment text.
    public let text: String
    /// Zero-based page index when known.
    public let pageIndex: Int?
    /// Normalized top-left bounding box.
    public let boundingBox: CGRect

    public init(text: String, pageIndex: Int? = nil, boundingBox: CGRect) {
        self.text = text
        self.pageIndex = pageIndex
        self.boundingBox = boundingBox
    }
}

/// Whether table reconstruction runs for an extraction, and how detections feed the prompt.
///
/// Measured extraction accuracy: always appending detected tables to the model prompt
/// hurts header-field accuracy on types without collections (e.g. invoice number, date,
/// seller, total), while helping line-item structure when the target schema has arrays.
///
/// - ``automatic``: run geometric detection when positioned blocks exist; **append
///   tables to the prompt only when the target schema contains a collection**; always
///   expose detected tables on ``ExtractionResult/tables`` so callers can use the grids
///   even for header-only types.
/// - ``off``: skip detection entirely (`result.tables` is empty; no table section in the prompt).
///
/// There is no separate “always prompt” mode: callers who need grids without line items
/// still have ``ExtractionResult/tables``.
public enum TableDetectionMode: Sendable, Equatable {
    /// Detect tables when geometry exists; prompt injection is schema-gated (see enum docs).
    case automatic
    /// Skip table detection entirely.
    case off
}
