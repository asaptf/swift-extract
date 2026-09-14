import Foundation
import Testing

@testable import Extract

@Test("probe: what geometry alone reconstructs from the scanned invoice")
func tempGridProbe() async throws {
    let url = URL(fileURLWithPath: "/Users/andrey/ZCode/Rimz/fixtures/private/customer/invoice-scan.pdf")
    var options = ExtractionOptions()
    options.textLayerPolicy = .never
    let started = Date()
    let inspection = try await Extract.inspect(.fileURL(url), options: options)
    print("PROBE ingest+detect: \(String(format: "%.1f", Date().timeIntervalSince(started)))s, tables: \(inspection.tables.count)")
    for table in inspection.tables {
        print("PROBE page \(table.pageIndex + 1): \(table.rowCount) rows x \(table.columnCount) cols, header row \(String(describing: table.headerRowIndex)), cells \(table.cells.count)")
    }
    if let first = inspection.tables.first {
        let rows = Dictionary(grouping: first.cells, by: \.row)
        for index in rows.keys.sorted().prefix(8) {
            let row = rows[index]!.sorted { $0.column < $1.column }
            print("PROBE   r\(index): " + row.map { "[\($0.column)]\($0.text)" }.joined(separator: " | "))
        }
    }
}
