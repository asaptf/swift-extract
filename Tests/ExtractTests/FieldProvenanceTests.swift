import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import Extract

@Extractable
struct ProvenanceProbe {
    let merchant: String
    let total: Decimal
    let note: String?
    let items: [ProvenanceItem]

    @Extractable
    struct ProvenanceItem {
        let name: String
        let price: Decimal
    }
}

@Suite("Field provenance")
struct FieldProvenanceTests {

    // MARK: - Unit: locate from synthetic geometry

    @Test("verbatim single-block value resolves to that block's page and rect")
    func singleBlockProvenance() {
        let box = CGRect(x: 0.10, y: 0.20, width: 0.40, height: 0.05)
        let vendorLabel = CGRect(x: 0.05, y: 0.20, width: 0.08, height: 0.05)
        let totalBox = CGRect(x: 0.10, y: 0.50, width: 0.30, height: 0.04)
        let blocks = [
            ExtractedDocument.Block(text: "Vendor:", pageIndex: 0, boundingBox: vendorLabel),
            ExtractedDocument.Block(text: "Acme Supplies Co.", pageIndex: 0, boundingBox: box),
            ExtractedDocument.Block(text: "Total 12.50", pageIndex: 0, boundingBox: totalBox),
        ]
        let value = ProvenanceProbe(
            merchant: "Acme Supplies Co.",
            total: Decimal(string: "12.5")!,
            note: nil,
            items: []
        )
        let source = blocks.map(\.text).joined(separator: "\n")
        let signals = FieldGrounding.compute(
            value: value,
            sourceText: source,
            attempts: 1,
            chunksUsed: 1,
            blocks: blocks,
            tables: []
        )
        let merchant = signals.fields.first { $0.path == "merchant" }
        #expect(merchant?.grounding == .verbatim)
        #expect(merchant?.provenance?.pageIndex == 0)
        #expect(merchant?.provenance?.boundingBox == box)
    }

    @Test("table-cell match prefers the cell rect over enclosing blocks")
    func tableCellPreferredOverBlock() {
        // A wide block covers the whole line; the cell is a tight sub-rect.
        let wideBlock = CGRect(x: 0.05, y: 0.30, width: 0.80, height: 0.06)
        let cellBox = CGRect(x: 0.05, y: 0.30, width: 0.35, height: 0.06)
        let widgetBox = CGRect(x: 0.05, y: 0.30, width: 0.12, height: 0.06)
        let proBox = CGRect(x: 0.18, y: 0.30, width: 0.08, height: 0.06)
        let amountBox = CGRect(x: 0.55, y: 0.30, width: 0.15, height: 0.06)
        let blocks = [
            ExtractedDocument.Block(text: "Widget Pro  500.00", pageIndex: 0, boundingBox: wideBlock),
            ExtractedDocument.Block(text: "Widget", pageIndex: 0, boundingBox: widgetBox),
            ExtractedDocument.Block(text: "Pro", pageIndex: 0, boundingBox: proBox),
        ]
        let table = ExtractedTable(
            pageIndex: 0,
            rowCount: 1,
            columnCount: 2,
            cells: [
                .init(text: "Widget Pro", row: 0, column: 0, boundingBox: cellBox),
                .init(text: "500.00", row: 0, column: 1, boundingBox: amountBox),
            ]
        )
        let value = ProvenanceProbe(
            merchant: "Other",
            total: 1,
            note: nil,
            items: [.init(name: "Widget Pro", price: Decimal(string: "500")!)]
        )
        let source = "Widget Pro  500.00"
        let signals = FieldGrounding.compute(
            value: value,
            sourceText: source,
            attempts: 1,
            chunksUsed: 1,
            blocks: blocks,
            tables: [table]
        )
        let name = signals.fields.first { $0.path == "items[0].name" }
        #expect(name?.grounding == .verbatim)
        #expect(name?.provenance?.pageIndex == 0)
        #expect(name?.provenance?.boundingBox == cellBox)
        #expect(name?.provenance?.boundingBox != wideBlock)
    }

    @Test("multi-line value resolves to the union of matching blocks on one page")
    func multiLineUnion() {
        let b1 = CGRect(x: 0.10, y: 0.20, width: 0.50, height: 0.04)
        let b2 = CGRect(x: 0.10, y: 0.25, width: 0.20, height: 0.04)
        let b3 = CGRect(x: 0.10, y: 0.30, width: 0.55, height: 0.04)
        let otherBox = CGRect(x: 0.10, y: 0.80, width: 0.30, height: 0.04)
        let blocks = [
            ExtractedDocument.Block(text: "123 SAMPLE STREET", pageIndex: 0, boundingBox: b1),
            ExtractedDocument.Block(text: "APT 4B", pageIndex: 0, boundingBox: b2),
            ExtractedDocument.Block(text: "SPRINGFIELD IL 62701", pageIndex: 0, boundingBox: b3),
            ExtractedDocument.Block(text: "Other line", pageIndex: 0, boundingBox: otherBox),
        ]
        let address = "123 SAMPLE STREET, APT 4B, SPRINGFIELD IL 62701"
        let value = ProvenanceProbe(
            merchant: address,
            total: 1,
            note: nil,
            items: []
        )
        let source = blocks.map(\.text).joined(separator: "\n")
        let signals = FieldGrounding.compute(
            value: value,
            sourceText: source,
            attempts: 1,
            chunksUsed: 1,
            blocks: blocks,
            tables: []
        )
        let merchant = signals.fields.first { $0.path == "merchant" }
        #expect(merchant?.grounding == .normalized || merchant?.grounding == .verbatim)
        let expected = b1.union(b2).union(b3)
        #expect(merchant?.provenance?.pageIndex == 0)
        #expect(merchant?.provenance?.boundingBox == expected)
    }

    @Test("multi-page span reports the first page only")
    func multiPageFirstPageOnly() {
        let p0a = CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.05)
        let p0b = CGRect(x: 0.1, y: 0.9, width: 0.4, height: 0.05)
        let p1 = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05)
        let blocks = [
            ExtractedDocument.Block(text: "LINE ONE", pageIndex: 0, boundingBox: p0a),
            ExtractedDocument.Block(text: "LINE TWO", pageIndex: 0, boundingBox: p0b),
            ExtractedDocument.Block(text: "LINE THREE", pageIndex: 1, boundingBox: p1),
        ]
        let value = ProvenanceProbe(
            merchant: "LINE ONE LINE TWO LINE THREE",
            total: 1,
            note: nil,
            items: []
        )
        let source = blocks.map(\.text).joined(separator: " ")
        let signals = FieldGrounding.compute(
            value: value,
            sourceText: source,
            attempts: 1,
            chunksUsed: 1,
            blocks: blocks,
            tables: []
        )
        let merchant = signals.fields.first { $0.path == "merchant" }
        #expect(merchant?.grounding == .verbatim)
        #expect(merchant?.provenance?.pageIndex == 0)
        #expect(merchant?.provenance?.boundingBox == p0a.union(p0b))
        // Must not include page-1 geometry in a page-0 rect.
        #expect(merchant?.provenance?.boundingBox != p0a.union(p0b).union(p1))
    }

    @Test("reformatted and absent fields carry no provenance")
    func noProvenanceWhenNotFoundOrReformatted() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05)
        let blocks = [
            ExtractedDocument.Block(text: "Acme invoice 15 MAR 1990", pageIndex: 0, boundingBox: box)
        ]
        let value = ProvenanceProbe(
            merchant: "Completely Invented",
            total: Decimal(string: "99999")!,
            note: nil,
            items: []
        )
        let signals = FieldGrounding.compute(
            value: value,
            sourceText: "Acme invoice 15 MAR 1990 total 1",
            attempts: 1,
            chunksUsed: 1,
            blocks: blocks,
            tables: []
        )
        let byPath = Dictionary(uniqueKeysWithValues: signals.fields.map { ($0.path, $0) })
        #expect(byPath["merchant"]?.grounding == .absent)
        #expect(byPath["merchant"]?.provenance == nil)
        #expect(byPath["note"]?.grounding == .reformatted)
        #expect(byPath["note"]?.provenance == nil)
        #expect(byPath["total"]?.grounding == .reformatted)
        #expect(byPath["total"]?.provenance == nil)
    }

    @Test("plain text source without boxes yields nil provenance even when verbatim")
    func noGeometryNoProvenance() {
        let value = ProvenanceProbe(
            merchant: "Acme",
            total: 1,
            note: "hello",
            items: []
        )
        let signals = FieldGrounding.compute(
            value: value,
            sourceText: "Acme hello total 1",
            attempts: 1,
            chunksUsed: 1
        )
        let merchant = signals.fields.first { $0.path == "merchant" }
        #expect(merchant?.grounding == .verbatim)
        #expect(merchant?.provenance == nil)
    }

    // MARK: - Coordinate convention on real fixtures

    @Test("PDF text-layer boxes use top-left normalised convention on invoice.pdf")
    func pdfCoordinateConvention() throws {
        let url = repoFixture("invoice.pdf")
        let document = try PDFAdapter.ingest(url: url)
        let boxed = document.blocks.filter { $0.boundingBox != nil }
        #expect(boxed.count >= 10)

        for block in boxed {
            let box = try #require(block.boundingBox)
            assertNormalisedTopLeft(box, label: block.text)
            #expect(block.pageIndex == 0)
        }

        // "INVOICE" (or first title token) should sit near the top of the page:
        // top-left y is small. Bottom-left convention would put top text near y≈1.
        let title = boxed.first {
            $0.text.localizedCaseInsensitiveContains("INVOICE")
                || $0.text.localizedCaseInsensitiveContains("INV")
        }
        if let title, let box = title.boundingBox {
            #expect(
                box.minY < 0.35,
                "title y=\(box.minY) should be near top under top-left convention; got \(title.text)"
            )
        }

        // Vendor line sits below the title → larger minY under top-left.
        let vendor = boxed.first { $0.text.localizedCaseInsensitiveContains("Acme") }
        if let titleBox = title?.boundingBox, let vendorBox = vendor?.boundingBox {
            #expect(
                vendorBox.minY >= titleBox.minY - 0.02,
                "vendor should not be above title under top-left y-down"
            )
        }
    }

    @Test("Vision OCR boxes use the same top-left normalised convention on receipt.png")
    func ocrCoordinateConvention() throws {
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
            print("SKIP ocrCoordinateConvention: Vision failed \(error)")
            return
        }
        if blocks.isEmpty {
            print("SKIP ocrCoordinateConvention: Vision returned empty text")
            return
        }

        let boxed = blocks.filter { $0.boundingBox != nil }
        #expect(!boxed.isEmpty)
        for block in boxed {
            let box = try #require(block.boundingBox)
            assertNormalisedTopLeft(box, label: block.text)
        }

        // Café / merchant name should appear in the upper portion of the receipt.
        let merchant = boxed.first {
            $0.text.localizedCaseInsensitiveContains("Cafe")
                || $0.text.localizedCaseInsensitiveContains("Café")
                || $0.text.localizedCaseInsensitiveContains("Receipt")
        }
        if let box = merchant?.boundingBox {
            #expect(
                box.minY < 0.45,
                "merchant/header y=\(box.minY) should be upper half under top-left convention"
            )
        }

        // A total line should sit below the header under y-down.
        let totalish = boxed.first {
            $0.text.localizedCaseInsensitiveContains("Total")
                || $0.text.contains("12.50")
                || $0.text.contains("12,50")
        }
        if let headerBox = merchant?.boundingBox, let totalBox = totalish?.boundingBox {
            #expect(
                totalBox.minY >= headerBox.minY - 0.02,
                "total should not be above header under top-left y-down"
            )
        }
    }

    @Test("invoice.pdf grounding attaches provenance for a known vendor token")
    func invoicePDFProvenanceEndToEnd() throws {
        let url = repoFixture("invoice.pdf")
        let document = try PDFAdapter.ingest(url: url)
        let tables = TableDetector.detect(documentBlocks: document.blocks)
        let value = ProvenanceProbe(
            merchant: "Acme Supplies Co.",
            total: Decimal(string: "1250")!,
            note: nil,
            items: [
                .init(name: "Widget Pro", price: Decimal(string: "500")!)
            ]
        )
        let signals = FieldGrounding.compute(
            value: value,
            sourceText: document.fullText,
            attempts: 1,
            chunksUsed: 1,
            blocks: document.blocks,
            tables: tables
        )
        let merchant = signals.fields.first { $0.path == "merchant" }
        #expect(merchant?.grounding == .verbatim || merchant?.grounding == .normalized)
        #expect(merchant?.provenance != nil)
        if let prov = merchant?.provenance {
            #expect(prov.pageIndex == 0)
            assertNormalisedTopLeft(prov.boundingBox, label: "merchant")
        }

        let item = signals.fields.first { $0.path == "items[0].name" }
        #expect(item?.grounding == .verbatim || item?.grounding == .normalized)
        // Prefer cell when table detection found Widget Pro.
        if let prov = item?.provenance {
            assertNormalisedTopLeft(prov.boundingBox, label: "item")
            if let cell = tables.flatMap(\.cells).first(where: {
                $0.text.localizedCaseInsensitiveContains("Widget") && $0.boundingBox != nil
            }) {
                #expect(prov.boundingBox == cell.boundingBox)
            }
        }
    }

    // MARK: - Helpers

    private func assertNormalisedTopLeft(_ box: CGRect, label: String) {
        #expect(box.minX >= -0.05, "\(label) minX=\(box.minX)")
        #expect(box.minY >= -0.05, "\(label) minY=\(box.minY)")
        #expect(box.maxX <= 1.05, "\(label) maxX=\(box.maxX)")
        #expect(box.maxY <= 1.05, "\(label) maxY=\(box.maxY)")
        #expect(box.width >= 0, "\(label) width")
        #expect(box.height >= 0, "\(label) height")
        #expect(box.width <= 1.05, "\(label) width too large")
        #expect(box.height <= 1.05, "\(label) height too large")
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
