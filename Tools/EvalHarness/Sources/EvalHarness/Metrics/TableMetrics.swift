import Extract
import Foundation

public enum TableMetrics {
    /// Fill density: non-empty cells / (rows × cols).
    ///
    /// Delegates to ``ExtractedTable/fillDensity`` so the number lives in one place.
    public static func fillDensity(_ table: ExtractedTable) -> Double {
        table.fillDensity
    }

    /// Line-item-shaped grid: rows ≥ 3, columns 3–6, density ≥ 0.80.
    ///
    /// Delegates to ``ExtractedTable/isLineItemShaped`` — the same predicate the
    /// library uses to prefer geometry-path candidates.
    ///
    /// This is the metric that exposed the pure-XY-cut fragmentation trap:
    /// aggregate density/column counts improved while real line-item tables
    /// shattered into half-width fragments.
    public static func isLineItemShaped(_ table: ExtractedTable) -> Bool {
        table.isLineItemShaped
    }

    public static func hasLineItemShapedTable(_ tables: [ExtractedTable]) -> Bool {
        tables.contains(where: isLineItemShaped)
    }
}
