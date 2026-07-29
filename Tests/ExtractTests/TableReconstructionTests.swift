import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import Extract

@Suite("Table reconstruction (stage 1)")
struct TableReconstructionTests {

    // MARK: - False-positive guard (highest priority)

    @Test("prose paragraphs produce zero tables")
    func proseParagraphsNoTables() {
        let blocks = [
            source(
                "This is a long paragraph of ordinary prose that should never be treated as a table.",
                x: 0.10, y: 0.10, w: 0.80, h: 0.03
            ),
            source(
                "It continues across several lines with a consistent left margin and no columns.",
                x: 0.10, y: 0.14, w: 0.78, h: 0.03
            ),
            source(
                "A third line of narrative text seals the case for a non-tabular layout.",
                x: 0.10, y: 0.18, w: 0.75, h: 0.03
            ),
            source(
                "Finally, a closing sentence with still more words than any invoice cell would hold.",
                x: 0.10, y: 0.22, w: 0.82, h: 0.03
            ),
        ]
        #expect(TableDetector.detect(in: blocks).isEmpty)
    }

    @Test("bulleted list produces zero tables")
    func bulletedListNoTables() {
        let blocks = [
            source("-", x: 0.10, y: 0.10, w: 0.02, h: 0.03),
            source("First bullet item in a list of chores", x: 0.14, y: 0.10, w: 0.50, h: 0.03),
            source("-", x: 0.10, y: 0.15, w: 0.02, h: 0.03),
            source("Second bullet item in a list of chores", x: 0.14, y: 0.15, w: 0.52, h: 0.03),
            source("-", x: 0.10, y: 0.20, w: 0.02, h: 0.03),
            source("Third bullet item in a list of chores", x: 0.14, y: 0.20, w: 0.50, h: 0.03),
            source("•", x: 0.10, y: 0.25, w: 0.02, h: 0.03),
            source("Fourth item using a real bullet glyph", x: 0.14, y: 0.25, w: 0.48, h: 0.03),
        ]
        #expect(TableDetector.detect(in: blocks).isEmpty)
    }

    @Test("address block produces zero tables")
    func addressBlockNoTables() {
        let blocks = [
            source("Acme Corporation", x: 0.10, y: 0.10, w: 0.30, h: 0.03),
            source("123 Market Street, Suite 400", x: 0.10, y: 0.14, w: 0.45, h: 0.03),
            source("San Francisco, CA 94105", x: 0.10, y: 0.18, w: 0.35, h: 0.03),
            source("United States of America", x: 0.10, y: 0.22, w: 0.32, h: 0.03),
        ]
        #expect(TableDetector.detect(in: blocks).isEmpty)
    }

    @Test("two-column article/sidebar layout produces zero tables")
    func twoColumnLayoutNotTable() {
        let blocks = [
            source(
                "Left column article text that is quite long and narrative for the reader.",
                x: 0.05, y: 0.10, w: 0.40, h: 0.08
            ),
            source("Sidebar A notes", x: 0.55, y: 0.10, w: 0.35, h: 0.04),
            source(
                "More left column prose continuing the story with additional sentences here.",
                x: 0.05, y: 0.22, w: 0.40, h: 0.08
            ),
            source("Sidebar B notes", x: 0.55, y: 0.22, w: 0.35, h: 0.04),
        ]
        #expect(TableDetector.detect(in: blocks).isEmpty)
    }

    // MARK: - Invoice PDF fixture

    @Test("invoice.pdf exposes geometry and detects line-item table")
    func invoicePDFTable() throws {
        let url = repoFixture("invoice.pdf")
        let document = try PDFAdapter.ingest(url: url)

        let boxed = document.blocks.filter { $0.boundingBox != nil }
        #expect(boxed.count >= 10, "text-layer PDF should emit per-word boxes")
        #expect(document.fullText.contains("Acme Supplies Co."))
        #expect(document.fullText.contains("Widget Pro"))
        #expect(document.fullText.contains("$500.00") || document.fullText.contains("500.00"))

        let tables = TableDetector.detect(documentBlocks: document.blocks)
        #expect(!tables.isEmpty, "expected at least one table on the invoice")

        let lineItems = tables.first { table in
            let joined = table.cells.map(\.text).joined(separator: " ").lowercased()
            return joined.contains("widget") && joined.contains("support")
        }
        guard let table = lineItems else {
            Issue.record("No table contained Widget/Support line items: \(tables.map { $0.markdown() })")
            return
        }

        // Two data rows for Widget Pro and Support Plan.
        #expect(table.rowCount == 2)
        #expect(table.columnCount >= 2)

        let allText = table.cells.map(\.text).joined(separator: " ")
        #expect(allText.contains("Widget Pro") || (allText.contains("Widget") && allText.contains("Pro")))
        #expect(
            allText.contains("Support Plan")
                || (allText.contains("Support") && allText.contains("Plan"))
        )
        #expect(allText.contains("500.00") || allText.contains("$500.00"))
        #expect(allText.contains("250.00") || allText.contains("$250.00"))

        // Description and amount should land in consistent columns across rows.
        let amountCol = table.cells.first { $0.text.contains("500") }?.column
        let amountCol2 = table.cells.first { $0.text.contains("250") }?.column
        #expect(amountCol != nil && amountCol == amountCol2)

        let widgetCell = table.cells.first { $0.text.localizedCaseInsensitiveContains("Widget") }
        let supportCell = table.cells.first { $0.text.localizedCaseInsensitiveContains("Support") }
        #expect(widgetCell != nil && supportCell != nil)
        #expect(widgetCell?.column == supportCell?.column)
    }

    // MARK: - Receipt OCR fixture

    @Test("receipt.png OCR reconstructs item/price columns (skip if Vision empty)")
    func receiptOCRTable() throws {
        let url = repoFixture("receipt.png")
        let data = try Data(contentsOf: url)
        guard let image = CGImageLoader.cgImage(from: data) else {
            Issue.record("Could not load receipt.png")
            return
        }

        let blocks: [ExtractedDocument.Block]
        do {
            blocks = try OCRAdapter.recognize(cgImage: image, pageIndex: 0)
        } catch {
            print("SKIP receiptOCRTable: Vision failed \(error)")
            return
        }
        if blocks.isEmpty {
            print("SKIP receiptOCRTable: Vision returned empty text")
            return
        }

        let tables = TableDetector.detect(documentBlocks: blocks)
        let items = tables.first { table in
            let joined = table.cells.map(\.text).joined(separator: " ").lowercased()
            return joined.contains("latte") || joined.contains("croissant")
        }
        guard let table = items else {
            // Totals-only detection is acceptable if items merged elsewhere; still require prices.
            let anyPrices = tables.contains { table in
                let joined = table.cells.map(\.text).joined(separator: " ")
                return joined.contains("4.50") || joined.contains("6.00") || joined.contains("12.50")
            }
            #expect(anyPrices, "expected item or total prices in \(tables.map { $0.markdown() })")
            return
        }

        let joined = table.cells.map(\.text).joined(separator: " ")
        #expect(joined.localizedCaseInsensitiveContains("Latte") || joined.contains("4.50"))
        #expect(
            joined.localizedCaseInsensitiveContains("Croissant") || joined.contains("6.00")
                || table.rowCount >= 2
        )
        #expect(table.columnCount >= 2)
    }

    // MARK: - Ragged rows

    @Test("missing trailing cell does not shift remaining columns")
    func raggedRowNoShift() {
        let blocks = [
            source("Item", x: 0.10, y: 0.10, w: 0.15, h: 0.03),
            source("Qty", x: 0.40, y: 0.10, w: 0.10, h: 0.03),
            source("Price", x: 0.60, y: 0.10, w: 0.15, h: 0.03),
            source("Apple", x: 0.10, y: 0.15, w: 0.18, h: 0.03),
            source("1", x: 0.40, y: 0.15, w: 0.05, h: 0.03),
            // missing price on this row
            source("Banana", x: 0.10, y: 0.20, w: 0.20, h: 0.03),
            source("2", x: 0.40, y: 0.20, w: 0.05, h: 0.03),
            source("9.00", x: 0.60, y: 0.20, w: 0.10, h: 0.03),
        ]
        let tables = TableDetector.detect(in: blocks)
        #expect(tables.count == 1)
        guard let table = tables.first else { return }
        #expect(table.columnCount == 3)
        #expect(table.rowCount == 3)

        #expect(table.text(row: 1, column: 0)?.localizedCaseInsensitiveContains("Apple") == true)
        #expect(table.text(row: 1, column: 1) == "1")
        #expect(table.text(row: 1, column: 2) == nil, "missing price must stay empty, not shift")

        #expect(table.text(row: 2, column: 0)?.localizedCaseInsensitiveContains("Banana") == true)
        #expect(table.text(row: 2, column: 1) == "2")
        #expect(table.text(row: 2, column: 2) == "9.00")
    }

    // MARK: - Determinism & options

    @Test("detection is deterministic for the same input")
    func deterministicOutput() {
        let blocks = [
            source("Widget Pro", x: 0.08, y: 0.20, w: 0.20, h: 0.03),
            source("qty 2", x: 0.35, y: 0.20, w: 0.08, h: 0.03),
            source("$500.00", x: 0.55, y: 0.20, w: 0.12, h: 0.03),
            source("Support Plan", x: 0.08, y: 0.25, w: 0.22, h: 0.03),
            source("qty 1", x: 0.35, y: 0.25, w: 0.08, h: 0.03),
            source("$250.00", x: 0.55, y: 0.25, w: 0.12, h: 0.03),
        ]
        let a = TableDetector.detect(in: blocks)
        let b = TableDetector.detect(in: blocks)
        #expect(a == b)
        #expect(a.first?.markdown() == b.first?.markdown())
    }

    @Test("tableDetection off yields no tables")
    func detectionOff() {
        let blocks = [
            source("Latte", x: 0.05, y: 0.20, w: 0.20, h: 0.03),
            source("4.50", x: 0.65, y: 0.20, w: 0.12, h: 0.03),
            source("Croissant", x: 0.05, y: 0.25, w: 0.25, h: 0.03),
            source("6.00", x: 0.65, y: 0.25, w: 0.12, h: 0.03),
        ]
        #expect(!TableDetector.detect(in: blocks, mode: .automatic).isEmpty)
        #expect(TableDetector.detect(in: blocks, mode: .off).isEmpty)

        let optionsOff = ExtractionOptions(tableDetection: .off)
        #expect(optionsOff.tableDetection == .off)
        #expect(ExtractionOptions().tableDetection == .automatic)

        // Source-compatible default init still compiles with prior argument lists.
        let legacy = ExtractionOptions(maxRetries: 1, locale: Locale(identifier: "en_US"))
        #expect(legacy.tableDetection == .automatic)
        #expect(
            TableDetector.detect(in: blocks, mode: legacy.tableDetection).count
                == TableDetector.detect(in: blocks).count
        )
        #expect(
            TableDetector.detect(in: blocks, mode: optionsOff.tableDetection).isEmpty
        )
    }

    @Test("markdown rendering is stable and includes cell text")
    func markdownRendering() {
        let table = ExtractedTable(
            pageIndex: 0,
            rowCount: 2,
            columnCount: 2,
            cells: [
                .init(text: "Item", row: 0, column: 0),
                .init(text: "Price", row: 0, column: 1),
                .init(text: "Latte", row: 1, column: 0),
                .init(text: "4.50", row: 1, column: 1),
            ],
            headerRowIndex: 0
        )
        let md = table.markdown()
        #expect(md.contains("Item"))
        #expect(md.contains("Latte"))
        #expect(md.contains("4.50"))
        #expect(md.contains("---"))
        // Detected header stays above the separator; data row below.
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].contains("Item"))
        #expect(lines[1].contains("---"))
        #expect(lines[2].contains("Latte"))
    }

    @Test("markdown with nil header uses placeholders; no data row above separator")
    func markdownNilHeaderNoDataAsHeader() {
        let table = ExtractedTable(
            pageIndex: 0,
            rowCount: 2,
            columnCount: 3,
            cells: [
                .init(text: "Widget Pro", row: 0, column: 0),
                .init(text: "qty 2", row: 0, column: 1),
                .init(text: "$500.00", row: 0, column: 2),
                .init(text: "Support Plan", row: 1, column: 0),
                .init(text: "qty 1", row: 1, column: 1),
                .init(text: "$250.00", row: 1, column: 2),
            ],
            headerRowIndex: nil
        )
        #expect(table.headerRowIndex == nil)
        let md = table.markdown()
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 4, "placeholder header + separator + 2 data rows")

        guard let sepIndex = lines.firstIndex(where: { $0.contains("---") }) else {
            Issue.record("missing separator in \(md)")
            return
        }
        #expect(sepIndex == 1)

        let above = lines[..<sepIndex].joined(separator: "\n")
        let below = lines[(sepIndex + 1)...].joined(separator: "\n")

        // No data content above the separator.
        #expect(!above.localizedCaseInsensitiveContains("Widget"))
        #expect(!above.localizedCaseInsensitiveContains("Support"))
        #expect(!above.contains("500"))
        #expect(!above.contains("250"))

        // Every data row appears in the body.
        #expect(below.localizedCaseInsensitiveContains("Widget"))
        #expect(below.localizedCaseInsensitiveContains("Support"))
        #expect(below.contains("500.00") || below.contains("$500.00"))
        #expect(below.contains("250.00") || below.contains("$250.00"))
    }

    @Test("invoice.pdf markdown keeps both line items as body rows")
    func invoicePDFMarkdownNoDataAsHeader() throws {
        let url = repoFixture("invoice.pdf")
        let document = try PDFAdapter.ingest(url: url)
        let tables = TableDetector.detect(documentBlocks: document.blocks)

        let lineItems = tables.first { table in
            let joined = table.cells.map(\.text).joined(separator: " ").lowercased()
            return joined.contains("widget") && joined.contains("support")
        }
        guard let table = lineItems else {
            Issue.record("No table contained Widget/Support line items: \(tables.map { $0.markdown() })")
            return
        }

        #expect(table.headerRowIndex == nil, "fixture has no keyword header row")
        #expect(table.rowCount == 2)

        let md = table.markdown()
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let sepIndex = lines.firstIndex(where: { $0.contains("---") }) else {
            Issue.record("missing separator in \(md)")
            return
        }

        let above = lines[..<sepIndex].joined(separator: "\n")
        let below = lines[(sepIndex + 1)...].joined(separator: "\n")

        // First data row must not be promoted into the header position.
        #expect(!above.localizedCaseInsensitiveContains("Widget"))
        #expect(!above.localizedCaseInsensitiveContains("Support"))
        #expect(!above.contains("500"))
        #expect(!above.contains("250"))

        // Both line items must appear as body rows (not lost as a false header).
        #expect(below.localizedCaseInsensitiveContains("Widget"))
        #expect(below.localizedCaseInsensitiveContains("Support"))
        #expect(below.contains("500.00") || below.contains("$500.00"))
        #expect(below.contains("250.00") || below.contains("$250.00"))
        #expect(lines.count == table.rowCount + 2, "placeholder + separator + every data row")
    }

    @Test("leading list markers stripped; lone dash and negatives preserved")
    func listMarkerStripping() {
        // Dash + label merge (gap ≤ cellMergeMaxGapX) into "- Widget Pro" style cells.
        let bulleted = [
            source("-", x: 0.08, y: 0.20, w: 0.015, h: 0.03),
            source("Widget Pro", x: 0.10, y: 0.20, w: 0.20, h: 0.03),
            source("qty 2", x: 0.35, y: 0.20, w: 0.08, h: 0.03),
            source("$500.00", x: 0.55, y: 0.20, w: 0.12, h: 0.03),
            source("-", x: 0.08, y: 0.25, w: 0.015, h: 0.03),
            source("Support Plan", x: 0.10, y: 0.25, w: 0.22, h: 0.03),
            source("qty 1", x: 0.35, y: 0.25, w: 0.08, h: 0.03),
            source("$250.00", x: 0.55, y: 0.25, w: 0.12, h: 0.03),
        ]
        let bulletedTables = TableDetector.detect(in: bulleted)
        #expect(bulletedTables.count == 1)
        if let table = bulletedTables.first {
            let texts = table.cells.map(\.text)
            #expect(texts.contains { $0 == "Widget Pro" || $0.hasPrefix("Widget") })
            #expect(texts.contains { $0 == "Support Plan" || $0.hasPrefix("Support") })
            #expect(!texts.contains { $0.hasPrefix("- ") || $0.hasPrefix("-W") })
            #expect(texts.allSatisfy { !$0.hasPrefix("- ") })
        }

        // Negative amounts must keep the leading minus (no whitespace after it).
        let negatives = [
            source("Refund", x: 0.08, y: 0.20, w: 0.15, h: 0.03),
            source("-12.50", x: 0.55, y: 0.20, w: 0.12, h: 0.03),
            source("Credit", x: 0.08, y: 0.25, w: 0.15, h: 0.03),
            source("-3.00", x: 0.55, y: 0.25, w: 0.10, h: 0.03),
        ]
        let negTables = TableDetector.detect(in: negatives)
        #expect(negTables.count == 1)
        if let table = negTables.first {
            let joined = table.cells.map(\.text).joined(separator: " ")
            #expect(joined.contains("-12.50"))
            #expect(joined.contains("-3.00"))
        }

        // A cell that is only "-" (nil / none) must not be erased.
        let loneDash = [
            source("Status", x: 0.08, y: 0.10, w: 0.15, h: 0.03),
            source("Amount", x: 0.55, y: 0.10, w: 0.15, h: 0.03),
            source("None", x: 0.08, y: 0.15, w: 0.12, h: 0.03),
            source("-", x: 0.55, y: 0.15, w: 0.05, h: 0.03),
            source("Paid", x: 0.08, y: 0.20, w: 0.12, h: 0.03),
            source("10.00", x: 0.55, y: 0.20, w: 0.10, h: 0.03),
            source("Due", x: 0.08, y: 0.25, w: 0.12, h: 0.03),
            source("5.00", x: 0.55, y: 0.25, w: 0.10, h: 0.03),
        ]
        let loneTables = TableDetector.detect(in: loneDash)
        #expect(!loneTables.isEmpty)
        if let table = loneTables.first {
            #expect(table.cells.contains { $0.text == "-" })
        }
    }

    // MARK: - Precision guards (real-invoice failure shapes)

    /// Coolblue-style layout: line items, then a vertical gap, then a totals block with
    /// different x-anchors. Merging them produced an 8-column sparse grid (dens ~0.45)
    /// with empty middle columns and values landing in unrelated columns.
    @Test("vertical gap splits line-item block from totals block")
    func regionSplitOnVerticalGap() {
        // Line-item grid (4 cols): description | qty | unit | total
        var blocks: [TableSourceBlock] = [
            source("Decoded Leather Slim Cover", x: 0.08, y: 0.30, w: 0.32, h: 0.018),
            source("1", x: 0.48, y: 0.30, w: 0.04, h: 0.018),
            source("EUR 69,99", x: 0.58, y: 0.30, w: 0.12, h: 0.018),
            source("EUR 69,99", x: 0.78, y: 0.30, w: 0.12, h: 0.018),

            source("Nintendo 3DS XL Wit + Blauw", x: 0.08, y: 0.33, w: 0.30, h: 0.018),
            source("1", x: 0.48, y: 0.33, w: 0.04, h: 0.018),
            source("EUR 189,00", x: 0.58, y: 0.33, w: 0.12, h: 0.018),
            source("EUR 189,00", x: 0.78, y: 0.33, w: 0.12, h: 0.018),

            source("Mario Kart 7", x: 0.08, y: 0.36, w: 0.22, h: 0.018),
            source("1", x: 0.48, y: 0.36, w: 0.04, h: 0.018),
            source("EUR 39,99", x: 0.58, y: 0.36, w: 0.12, h: 0.018),
            source("EUR 39,99", x: 0.78, y: 0.36, w: 0.12, h: 0.018),

            source("New Super Mario Bros. 2", x: 0.08, y: 0.39, w: 0.28, h: 0.018),
            source("1", x: 0.48, y: 0.39, w: 0.04, h: 0.018),
            source("EUR 39,99", x: 0.58, y: 0.39, w: 0.12, h: 0.018),
            source("EUR 39,99", x: 0.78, y: 0.39, w: 0.12, h: 0.018),
        ]

        // Significant vertical gap (~0.06) then a totals block with different anchors.
        blocks += [
            source("Exclusief BTW", x: 0.45, y: 0.50, w: 0.14, h: 0.018),
            source("EUR 593,36", x: 0.78, y: 0.50, w: 0.12, h: 0.018),
            source("Subtotaal", x: 0.55, y: 0.53, w: 0.12, h: 0.018),
            source("EUR 717,97", x: 0.78, y: 0.53, w: 0.12, h: 0.018),
            source("Totaal", x: 0.55, y: 0.56, w: 0.10, h: 0.018),
            source("EUR 717,97", x: 0.78, y: 0.56, w: 0.12, h: 0.018),
        ]

        let tables = TableDetector.detect(in: blocks)
        #expect(!tables.isEmpty, "expected at least the line-item table")

        let lineItems = tables.first { table in
            let joined = table.cells.map(\.text).joined(separator: " ").lowercased()
            return joined.contains("nintendo") && joined.contains("mario")
        }
        guard let items = lineItems else {
            Issue.record("No table contained line items: \(tables.map { $0.markdown() })")
            return
        }

        // Line items must not swallow the totals block as extra rows.
        #expect(items.rowCount == 4, "line-item rows only; got \(items.rowCount): \(items.markdown())")
        #expect(items.columnCount >= 2 && items.columnCount <= 5, "got \(items.columnCount) cols")

        let joined = items.cells.map(\.text).joined(separator: " ").lowercased()
        #expect(!joined.contains("subtotaal") && !joined.contains("exclusief"))
        #expect(joined.contains("nintendo") || joined.contains("3ds"))
        #expect(joined.contains("69,99") || joined.contains("69.99") || joined.contains("189"))

        // Density and no all-empty columns (hard requirements).
        let density = Double(items.cells.count) / Double(items.rowCount * items.columnCount)
        #expect(density >= 0.55, "density \(density) for \(items.markdown())")
        for c in 0..<items.columnCount {
            #expect(items.cells.contains { $0.column == c }, "column \(c) is all-empty")
        }
    }

    /// Side-by-side documents with a wide mid-X corridor and *unrelated* row baselines must
    /// come back as TWO tables. (Aligned baselines across a gap look like one table's
    /// column gutter and must not cut — see `wideGridPreservedVsSideBySideSplit`.)
    @Test("horizontal corridor splits side-by-side tables (XY-cut)")
    func regionSplitOnHorizontalCorridor() {
        // Left document: Item | Qty | Price  (x ≈ 0.05–0.38)
        var blocks: [TableSourceBlock] = [
            source("Item", x: 0.05, y: 0.20, w: 0.10, h: 0.02),
            source("Qty", x: 0.18, y: 0.20, w: 0.06, h: 0.02),
            source("Price", x: 0.28, y: 0.20, w: 0.08, h: 0.02),
            source("Widget", x: 0.05, y: 0.25, w: 0.10, h: 0.02),
            source("2", x: 0.18, y: 0.25, w: 0.04, h: 0.02),
            source("10.00", x: 0.28, y: 0.25, w: 0.08, h: 0.02),
            source("Gadget", x: 0.05, y: 0.30, w: 0.10, h: 0.02),
            source("1", x: 0.18, y: 0.30, w: 0.04, h: 0.02),
            source("5.00", x: 0.28, y: 0.30, w: 0.08, h: 0.02),
            source("Cable", x: 0.05, y: 0.35, w: 0.10, h: 0.02),
            source("3", x: 0.18, y: 0.35, w: 0.04, h: 0.02),
            source("7.50", x: 0.28, y: 0.35, w: 0.08, h: 0.02),
        ]

        // Wide corridor (~0.20 of page width), then right document: SKU | Desc | Amt.
        // Y positions deliberately offset from the left grid so baselines fail to align —
        // that is the region-boundary signal (vs a shared table row).
        blocks += [
            source("SKU", x: 0.58, y: 0.22, w: 0.08, h: 0.02),
            source("Desc", x: 0.70, y: 0.22, w: 0.10, h: 0.02),
            source("Amt", x: 0.84, y: 0.22, w: 0.08, h: 0.02),
            source("A1", x: 0.58, y: 0.285, w: 0.06, h: 0.02),
            source("Alpha", x: 0.70, y: 0.285, w: 0.10, h: 0.02),
            source("1.00", x: 0.84, y: 0.285, w: 0.08, h: 0.02),
            source("B2", x: 0.58, y: 0.35, w: 0.06, h: 0.02),
            source("Beta", x: 0.70, y: 0.35, w: 0.10, h: 0.02),
            source("2.00", x: 0.84, y: 0.35, w: 0.08, h: 0.02),
            source("C3", x: 0.58, y: 0.415, w: 0.06, h: 0.02),
            source("Gamma", x: 0.70, y: 0.415, w: 0.10, h: 0.02),
            source("3.00", x: 0.84, y: 0.415, w: 0.08, h: 0.02),
        ]

        let tables = TableDetector.detect(in: blocks)
        #expect(
            tables.count == 2,
            "expected two independent tables, got \(tables.count): \(tables.map { $0.markdown() })"
        )

        let left = tables.first { t in
            let j = t.cells.map(\.text).joined(separator: " ").lowercased()
            return j.contains("widget") && j.contains("gadget")
        }
        let right = tables.first { t in
            let j = t.cells.map(\.text).joined(separator: " ").lowercased()
            return j.contains("alpha") && j.contains("beta")
        }
        #expect(left != nil, "left grid missing: \(tables.map { $0.markdown() })")
        #expect(right != nil, "right grid missing: \(tables.map { $0.markdown() })")

        if let left {
            #expect(left.rowCount >= 3, "left rows: \(left.markdown())")
            #expect(left.columnCount == 3, "left cols: \(left.markdown())")
            let j = left.cells.map(\.text).joined(separator: " ").lowercased()
            #expect(!j.contains("alpha") && !j.contains("sku"))
            let density = Double(left.cells.count) / Double(left.rowCount * left.columnCount)
            #expect(density >= 0.55)
        }
        if let right {
            #expect(right.rowCount >= 3, "right rows: \(right.markdown())")
            #expect(right.columnCount == 3, "right cols: \(right.markdown())")
            let j = right.cells.map(\.text).joined(separator: " ").lowercased()
            #expect(!j.contains("widget") && !j.contains("gadget"))
            let density = Double(right.cells.count) / Double(right.rowCount * right.columnCount)
            #expect(density >= 0.55)
        }

        // Not one merged mega-grid.
        #expect(tables.allSatisfy { $0.columnCount <= 4 })
    }

    /// Pins the corridor discriminator: a dense 6-column line-item grid (shared baselines
    /// across every gutter) must stay ONE table, while two independent 3-column grids
    /// separated by a real region boundary (unrelated baselines) must stay TWO.
    @Test("wide dense grid preserved; misaligned side-by-side grids split")
    func wideGridPreservedVsSideBySideSplit() {
        // --- Case A: one genuine 6-column line-item table (uneven gutters) ---
        // Columns at ~0.05, 0.18, 0.30, 0.48, 0.62, 0.78 with a wider gap between col3
        // and col4 (~0.12 mid-X) that a width-only XY-cut would treat as a corridor.
        let wideGrid: [TableSourceBlock] = [
            // header
            source("Pos", x: 0.05, y: 0.15, w: 0.06, h: 0.018),
            source("Art", x: 0.14, y: 0.15, w: 0.08, h: 0.018),
            source("Desc", x: 0.26, y: 0.15, w: 0.12, h: 0.018),
            source("Qty", x: 0.48, y: 0.15, w: 0.06, h: 0.018),
            source("Price", x: 0.60, y: 0.15, w: 0.08, h: 0.018),
            source("Amount", x: 0.76, y: 0.15, w: 0.10, h: 0.018),
            // data rows — shared baselines across all six columns
            source("1", x: 0.05, y: 0.20, w: 0.04, h: 0.018),
            source("A100", x: 0.14, y: 0.20, w: 0.08, h: 0.018),
            source("Widget Pro", x: 0.26, y: 0.20, w: 0.14, h: 0.018),
            source("2", x: 0.48, y: 0.20, w: 0.04, h: 0.018),
            source("10.00", x: 0.60, y: 0.20, w: 0.08, h: 0.018),
            source("20.00", x: 0.76, y: 0.20, w: 0.08, h: 0.018),
            source("2", x: 0.05, y: 0.25, w: 0.04, h: 0.018),
            source("B200", x: 0.14, y: 0.25, w: 0.08, h: 0.018),
            source("Gadget Plus", x: 0.26, y: 0.25, w: 0.14, h: 0.018),
            source("1", x: 0.48, y: 0.25, w: 0.04, h: 0.018),
            source("15.50", x: 0.60, y: 0.25, w: 0.08, h: 0.018),
            source("15.50", x: 0.76, y: 0.25, w: 0.08, h: 0.018),
            source("3", x: 0.05, y: 0.30, w: 0.04, h: 0.018),
            source("C300", x: 0.14, y: 0.30, w: 0.08, h: 0.018),
            source("Cable Kit", x: 0.26, y: 0.30, w: 0.12, h: 0.018),
            source("4", x: 0.48, y: 0.30, w: 0.04, h: 0.018),
            source("5.00", x: 0.60, y: 0.30, w: 0.06, h: 0.018),
            source("20.00", x: 0.76, y: 0.30, w: 0.08, h: 0.018),
            source("4", x: 0.05, y: 0.35, w: 0.04, h: 0.018),
            source("D400", x: 0.14, y: 0.35, w: 0.08, h: 0.018),
            source("Mount Bracket", x: 0.26, y: 0.35, w: 0.16, h: 0.018),
            source("1", x: 0.48, y: 0.35, w: 0.04, h: 0.018),
            source("8.00", x: 0.60, y: 0.35, w: 0.06, h: 0.018),
            source("8.00", x: 0.76, y: 0.35, w: 0.08, h: 0.018),
        ]

        let wideTables = TableDetector.detect(in: wideGrid)
        #expect(
            wideTables.count == 1,
            "6-col grid must stay one table, got \(wideTables.count): \(wideTables.map { $0.markdown() })"
        )
        if let t = wideTables.first {
            #expect(t.rowCount >= 3, "rows: \(t.markdown())")
            #expect(
                t.columnCount >= 5 && t.columnCount <= 6,
                "expected ~6 cols, got \(t.columnCount): \(t.markdown())"
            )
            let density = Double(t.cells.count) / Double(t.rowCount * t.columnCount)
            #expect(density >= 0.80, "density \(density): \(t.markdown())")
            let joined = t.cells.map(\.text).joined(separator: " ").lowercased()
            #expect(joined.contains("widget") && joined.contains("gadget"))
            #expect(joined.contains("20.00") || joined.contains("15.50"))
        }

        // --- Case B: two independent 3-column grids, real region boundary ---
        var sideBySide: [TableSourceBlock] = [
            source("Item", x: 0.05, y: 0.18, w: 0.10, h: 0.02),
            source("Qty", x: 0.18, y: 0.18, w: 0.06, h: 0.02),
            source("Price", x: 0.28, y: 0.18, w: 0.08, h: 0.02),
            source("Alpha", x: 0.05, y: 0.24, w: 0.10, h: 0.02),
            source("1", x: 0.18, y: 0.24, w: 0.04, h: 0.02),
            source("9.00", x: 0.28, y: 0.24, w: 0.08, h: 0.02),
            source("Beta", x: 0.05, y: 0.30, w: 0.10, h: 0.02),
            source("2", x: 0.18, y: 0.30, w: 0.04, h: 0.02),
            source("8.00", x: 0.28, y: 0.30, w: 0.08, h: 0.02),
            source("Gamma", x: 0.05, y: 0.36, w: 0.10, h: 0.02),
            source("3", x: 0.18, y: 0.36, w: 0.04, h: 0.02),
            source("7.00", x: 0.28, y: 0.36, w: 0.08, h: 0.02),
        ]
        // Right document: different row Ys (no shared baselines).
        sideBySide += [
            source("SKU", x: 0.58, y: 0.20, w: 0.08, h: 0.02),
            source("Name", x: 0.70, y: 0.20, w: 0.10, h: 0.02),
            source("Amt", x: 0.84, y: 0.20, w: 0.08, h: 0.02),
            source("X1", x: 0.58, y: 0.265, w: 0.06, h: 0.02),
            source("One", x: 0.70, y: 0.265, w: 0.08, h: 0.02),
            source("1.00", x: 0.84, y: 0.265, w: 0.08, h: 0.02),
            source("X2", x: 0.58, y: 0.33, w: 0.06, h: 0.02),
            source("Two", x: 0.70, y: 0.33, w: 0.08, h: 0.02),
            source("2.00", x: 0.84, y: 0.33, w: 0.08, h: 0.02),
            source("X3", x: 0.58, y: 0.395, w: 0.06, h: 0.02),
            source("Three", x: 0.70, y: 0.395, w: 0.10, h: 0.02),
            source("3.00", x: 0.84, y: 0.395, w: 0.08, h: 0.02),
        ]

        let splitTables = TableDetector.detect(in: sideBySide)
        #expect(
            splitTables.count == 2,
            "expected two tables across region boundary, got \(splitTables.count): \(splitTables.map { $0.markdown() })"
        )
        let hasLeft = splitTables.contains { t in
            t.cells.map(\.text).joined(separator: " ").localizedCaseInsensitiveContains("Alpha")
        }
        let hasRight = splitTables.contains { t in
            t.cells.map(\.text).joined(separator: " ").localizedCaseInsensitiveContains("Three")
        }
        #expect(hasLeft && hasRight, "both grids required: \(splitTables.map { $0.markdown() })")
        #expect(splitTables.allSatisfy { $0.columnCount == 3 })
    }

    /// Phantom mid-description columns that never receive a cell must be dropped, not
    /// emitted as blank pipe cells (coolblue failure: 3 empty columns between desc and qty).
    @Test("all-empty columns are never emitted")
    func neverEmitAllEmptyColumns() {
        // Shared qty/price columns plus a few stray words at unique x that only appear
        // once — previously those became empty columns for every other row.
        let blocks = [
            source("Decoded Leather Slim Cover Apple iPad", x: 0.08, y: 0.20, w: 0.35, h: 0.02),
            source("1", x: 0.50, y: 0.20, w: 0.04, h: 0.02),
            source("EUR 69,99", x: 0.62, y: 0.20, w: 0.12, h: 0.02),
            source("EUR 69,99", x: 0.80, y: 0.20, w: 0.12, h: 0.02),

            source("Nintendo 3DS XL", x: 0.08, y: 0.24, w: 0.22, h: 0.02),
            // One-off fragment that would invent a column at x≈0.30 if agreement is weak.
            source("Wit", x: 0.30, y: 0.24, w: 0.05, h: 0.02),
            source("1", x: 0.50, y: 0.24, w: 0.04, h: 0.02),
            source("EUR 189,00", x: 0.62, y: 0.24, w: 0.12, h: 0.02),
            source("EUR 189,00", x: 0.80, y: 0.24, w: 0.12, h: 0.02),

            source("Mario Kart 7", x: 0.08, y: 0.28, w: 0.18, h: 0.02),
            source("1", x: 0.50, y: 0.28, w: 0.04, h: 0.02),
            source("EUR 39,99", x: 0.62, y: 0.28, w: 0.12, h: 0.02),
            source("EUR 39,99", x: 0.80, y: 0.28, w: 0.12, h: 0.02),

            source("New Super Mario Bros. 2", x: 0.08, y: 0.32, w: 0.28, h: 0.02),
            source("1", x: 0.50, y: 0.32, w: 0.04, h: 0.02),
            source("EUR 39,99", x: 0.62, y: 0.32, w: 0.12, h: 0.02),
            source("EUR 39,99", x: 0.80, y: 0.32, w: 0.12, h: 0.02),
        ]

        let tables = TableDetector.detect(in: blocks)
        #expect(!tables.isEmpty)
        for table in tables {
            for c in 0..<table.columnCount {
                #expect(
                    table.cells.contains { $0.column == c },
                    "table has all-empty column \(c): \(table.markdown())"
                )
            }
            let density = Double(table.cells.count) / Double(table.rowCount * table.columnCount)
            #expect(density >= 0.55, "density \(density): \(table.markdown())")
        }

        let lineItems = tables.first { t in
            t.cells.map(\.text).joined(separator: " ").localizedCaseInsensitiveContains("Nintendo")
        }
        #expect(lineItems != nil)
        if let t = lineItems {
            // Phantom "Wit"-only column must not pad the grid to 5+ with empties.
            #expect(t.columnCount <= 5, "over-segmented: \(t.markdown())")
        }
    }

    // MARK: - Helpers

    private func source(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        w: CGFloat,
        h: CGFloat,
        page: Int = 0
    ) -> TableSourceBlock {
        TableSourceBlock(
            text: text,
            pageIndex: page,
            boundingBox: CGRect(x: x, y: y, width: w, height: h)
        )
    }

    private func repoFixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures")
            .appendingPathComponent(name)
    }
}
