import Extract
import Foundation

public struct SurveyFileRecord: Sendable {
    public var file: String
    public var relativePath: String
    public var ingestionSeconds: Double
    public var characterCount: Int
    public var positionedBlockCount: Int
    public var usedOCRFallback: Bool
    public var tableCount: Int
    public var tables: [TableShape]
    public var hasLineItemShaped: Bool
    public var error: String?

    public struct TableShape: Sendable {
        public var pageIndex: Int
        public var rowCount: Int
        public var columnCount: Int
        public var fillDensity: Double
        public var isLineItemShaped: Bool
        /// Cell texts only when privacy opt-in is enabled.
        public var cells: [[String]]?
    }
}

public struct SurveySummary: Sendable {
    public var records: [SurveyFileRecord]
    public var filesTotal: Int
    public var filesOK: Int
    public var filesError: Int
    public var ocrFallbackCount: Int
    public var filesWithLineItemShaped: Int
    /// Share of successfully ingested files with a line-item-shaped grid.
    public var lineItemShapedShare: Double
    public var meanIngestionSeconds: Double
    public var meanCharacterCount: Double
    public var meanTablesPerFile: Double

    public static func reduce(_ records: [SurveyFileRecord]) -> SurveySummary {
        let ok = records.filter { $0.error == nil }
        let n = max(ok.count, 1)
        let shaped = ok.filter(\.hasLineItemShaped).count
        return SurveySummary(
            records: records,
            filesTotal: records.count,
            filesOK: ok.count,
            filesError: records.count - ok.count,
            ocrFallbackCount: ok.filter(\.usedOCRFallback).count,
            filesWithLineItemShaped: shaped,
            lineItemShapedShare: Double(shaped) / Double(n),
            meanIngestionSeconds: ok.map(\.ingestionSeconds).reduce(0, +) / Double(n),
            meanCharacterCount: ok.map { Double($0.characterCount) }.reduce(0, +) / Double(n),
            meanTablesPerFile: ok.map { Double($0.tableCount) }.reduce(0, +) / Double(n)
        )
    }
}

public enum SurveyRunner {
    public static func run(
        files: [URL],
        rootForRelative: URL,
        tableDetection: TableDetectionMode = .automatic,
        includeContent: Bool = false
    ) async -> SurveySummary {
        var records: [SurveyFileRecord] = []
        for url in files {
            let record = await surveyOne(
                url: url,
                rootForRelative: rootForRelative,
                tableDetection: tableDetection,
                includeContent: includeContent
            )
            records.append(record)
        }
        // Deterministic order
        records.sort { $0.relativePath < $1.relativePath }
        return SurveySummary.reduce(records)
    }

    private static func surveyOne(
        url: URL,
        rootForRelative: URL,
        tableDetection: TableDetectionMode,
        includeContent: Bool
    ) async -> SurveyFileRecord {
        let relative = relativePath(url, root: rootForRelative)
        let start = ContinuousClock.now
        do {
            let inspection = try await Extract.inspect(url, tableDetection: tableDetection)
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            let shapes: [SurveyFileRecord.TableShape] = inspection.tables.map { table in
                let density = TableMetrics.fillDensity(table)
                var cells: [[String]]? = nil
                if includeContent {
                    cells = gridCells(table)
                }
                return SurveyFileRecord.TableShape(
                    pageIndex: table.pageIndex,
                    rowCount: table.rowCount,
                    columnCount: table.columnCount,
                    fillDensity: density,
                    isLineItemShaped: TableMetrics.isLineItemShaped(table),
                    cells: cells
                )
            }
            return SurveyFileRecord(
                file: url.path,
                relativePath: relative,
                ingestionSeconds: seconds,
                characterCount: inspection.characterCount,
                positionedBlockCount: inspection.positionedBlockCount,
                usedOCRFallback: inspection.usedOCRFallback,
                tableCount: inspection.tables.count,
                tables: shapes,
                hasLineItemShaped: TableMetrics.hasLineItemShapedTable(inspection.tables),
                error: nil
            )
        } catch {
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            return SurveyFileRecord(
                file: url.path,
                relativePath: relative,
                ingestionSeconds: seconds,
                characterCount: 0,
                positionedBlockCount: 0,
                usedOCRFallback: false,
                tableCount: 0,
                tables: [],
                hasLineItemShaped: false,
                error: String(describing: error)
            )
        }
    }

    private static func gridCells(_ table: ExtractedTable) -> [[String]] {
        var grid = Array(
            repeating: Array(repeating: "", count: table.columnCount),
            count: table.rowCount
        )
        for cell in table.cells {
            guard cell.row >= 0, cell.row < table.rowCount,
                cell.column >= 0, cell.column < table.columnCount
            else { continue }
            grid[cell.row][cell.column] = cell.text
        }
        return grid
    }

    public static func relativePath(_ url: URL, root: URL) -> String {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if path.hasPrefix(rootPath) {
            let rest = path.dropFirst(rootPath.count)
            return rest.hasPrefix("/") ? String(rest.dropFirst()) : String(rest)
        }
        return url.lastPathComponent
    }
}
