import Extract
import Foundation

public enum TableMetrics {
    /// Fill density: non-empty cells / (rows × cols).
    public static func fillDensity(_ table: ExtractedTable) -> Double {
        let capacity = max(table.rowCount * table.columnCount, 1)
        return Double(table.cells.count) / Double(capacity)
    }

    /// Line-item-shaped grid: rows ≥ 3, columns 3–6, density ≥ 0.80.
    ///
    /// This is the metric that exposed the pure-XY-cut fragmentation trap:
    /// aggregate density/column counts improved while real line-item tables
    /// shattered into half-width fragments.
    public static func isLineItemShaped(_ table: ExtractedTable) -> Bool {
        table.rowCount >= 3
            && table.columnCount >= 3
            && table.columnCount <= 6
            && fillDensity(table) >= 0.80
    }

    public static func hasLineItemShapedTable(_ tables: [ExtractedTable]) -> Bool {
        tables.contains(where: isLineItemShaped)
    }
}
