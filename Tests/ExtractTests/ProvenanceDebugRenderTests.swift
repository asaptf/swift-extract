import CoreGraphics
import Foundation
import Testing

@testable import Extract

/// Writes human-inspectable PNGs with field provenance rectangles for the two
/// ingestion paths. Not a public API — test-only debug utility.
///
/// Output directory (created if needed):
///   `<repo>/Tools/EvalHarness/eval-out/provenance/`
///   - `invoice-pdf-text-layer.png`
///   - `receipt-vision-ocr.png`
@Suite("Provenance debug PNGs")
struct ProvenanceDebugRenderTests {

    @Test("render provenance overlays for invoice.pdf and receipt.png")
    func renderFixtureOverlays() throws {
        let outDir = provenanceOutputDirectory()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        try renderInvoicePDF(to: outDir.appendingPathComponent("invoice-pdf-text-layer.png"))
        try renderReceiptPNG(to: outDir.appendingPathComponent("receipt-vision-ocr.png"))

        let invoiceURL = outDir.appendingPathComponent("invoice-pdf-text-layer.png")
        let receiptURL = outDir.appendingPathComponent("receipt-vision-ocr.png")
        #expect(FileManager.default.fileExists(atPath: invoiceURL.path))
        #expect(FileManager.default.fileExists(atPath: receiptURL.path))

        // Print absolute paths so the developer can open them after `swift test`.
        print("PROVENANCE_PNG invoice: \(invoiceURL.path)")
        print("PROVENANCE_PNG receipt: \(receiptURL.path)")
    }

    // MARK: - Renderers

    private func renderInvoicePDF(to url: URL) throws {
        let pdfURL = repoFixture("invoice.pdf")
        let document = try PDFAdapter.ingest(url: pdfURL)
        let tables = TableDetector.detect(documentBlocks: document.blocks)
        let value = ProvenanceProbe(
            merchant: "Acme Supplies Co.",
            total: Decimal(string: "1250")!,
            note: "Thank you for your business.",
            items: [
                .init(name: "Widget Pro", price: Decimal(string: "500")!),
                .init(name: "Support Plan", price: Decimal(string: "250")!),
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
        let overlays = overlays(from: signals)
        #expect(!overlays.isEmpty, "expected at least one provenance box on invoice.pdf")

        let pageImage = try ProvenanceDebugRenderer.renderPDFPage(url: pdfURL, pageIndex: 0)
        try ProvenanceDebugRenderer.writePNG(
            pageImage: pageImage,
            pageIndex: 0,
            overlays: overlays,
            to: url
        )
    }

    private func renderReceiptPNG(to url: URL) throws {
        let imageURL = repoFixture("receipt.png")
        let data = try Data(contentsOf: imageURL)
        guard let image = CGImageLoader.cgImage(from: data) else {
            Issue.record("Could not load receipt.png")
            return
        }
        let blocks: [ExtractedDocument.Block]
        do {
            blocks = try OCRAdapter.recognize(cgImage: image, pageIndex: 0)
        } catch {
            print("SKIP renderReceiptPNG: Vision failed \(error)")
            return
        }
        if blocks.isEmpty {
            print("SKIP renderReceiptPNG: Vision returned empty text")
            return
        }
        let tables = TableDetector.detect(documentBlocks: blocks)
        let fullText = ExtractedDocument(
            blocks: blocks,
            sourceDescription: "receipt.png"
        ).fullText

        // Ground values that commonly appear on the fixture; skip soft if OCR drifts.
        let value = ProvenanceProbe(
            merchant: merchantGuess(from: fullText) ?? "Cafe",
            total: Decimal(string: "12.50")!,
            note: nil,
            items: itemGuesses(from: fullText)
        )
        let signals = FieldGrounding.compute(
            value: value,
            sourceText: fullText,
            attempts: 1,
            chunksUsed: 1,
            blocks: blocks,
            tables: tables
        )
        var overlays = overlays(from: signals)

        // Always draw *something* inspectable: fall back to all positioned blocks if
        // no field localised (OCR token drift). Still validates coordinate convention.
        if overlays.isEmpty {
            overlays = blocks.compactMap { block in
                guard let box = block.boundingBox, let page = block.pageIndex else { return nil }
                return ProvenanceDebugRenderer.Overlay(
                    path: "block",
                    pageIndex: page,
                    boundingBox: box,
                    label: block.text
                )
            }
        }
        #expect(!overlays.isEmpty)

        try ProvenanceDebugRenderer.writePNG(
            pageImage: image,
            pageIndex: 0,
            overlays: overlays,
            to: url
        )
    }

    private func overlays(from signals: ExtractionSignals) -> [ProvenanceDebugRenderer.Overlay] {
        signals.fields.compactMap { field in
            guard let prov = field.provenance else { return nil }
            return ProvenanceDebugRenderer.Overlay(
                path: field.path,
                pageIndex: prov.pageIndex,
                boundingBox: prov.boundingBox,
                label: field.path
            )
        }
    }

    private func merchantGuess(from text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        // Prefer a short header-like line without prices.
        return lines.first { line in
            !line.contains("$") && line.count >= 3 && line.count <= 40
                && !line.localizedCaseInsensitiveContains("total")
                && !line.localizedCaseInsensitiveContains("qty")
        }
    }

    private func itemGuesses(from text: String) -> [ProvenanceProbe.ProvenanceItem] {
        var items: [ProvenanceProbe.ProvenanceItem] = []
        if text.localizedCaseInsensitiveContains("Latte") {
            items.append(.init(name: "Latte", price: Decimal(string: "4.50")!))
        }
        if text.localizedCaseInsensitiveContains("Croissant") {
            items.append(.init(name: "Croissant", price: Decimal(string: "6.00")!))
        }
        if items.isEmpty, text.contains("4.50") {
            items.append(.init(name: "Item", price: Decimal(string: "4.50")!))
        }
        return items
    }

    private func provenanceOutputDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/ExtractTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo
            .appendingPathComponent("Tools")
            .appendingPathComponent("EvalHarness")
            .appendingPathComponent("eval-out")
            .appendingPathComponent("provenance")
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
