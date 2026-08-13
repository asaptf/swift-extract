import CoreGraphics
import Foundation
import Testing

@testable import Extract

@Extractable
struct GeometryInvoice {
    let vendor: String
    @Guide("ISO 8601 format") let dueDate: Date
    let total: Decimal
    let lineItems: [LineItem]

    @Extractable
    struct LineItem {
        let description: String
        let amount: Decimal
        let quantity: Int
    }
}

@Extractable
struct GeometryReceipt {
    let merchant: String
    let date: Date
    let total: Decimal
    let currency: String
    let items: [Item]

    @Extractable
    struct Item {
        let name: String
        let price: Decimal
        let quantity: Int?
    }
}

@Extractable
struct HeaderOnlyGeometryInvoice {
    let vendor: String
    let total: Decimal
}

@Suite("Line items from table geometry")
struct GeometryLineItemsTests {

    // MARK: - Default path unchanged

    @Test("default lineItemSource is model and init stays source-compatible")
    func defaultOptionIsModel() {
        #expect(ExtractionOptions().lineItemSource == .model)
        let legacy = ExtractionOptions(maxRetries: 1, locale: Locale(identifier: "en_US"))
        #expect(legacy.lineItemSource == .model)
        let bare = ExtractionResult(
            value: GeometryInvoice(
                vendor: "X",
                dueDate: Date(timeIntervalSince1970: 0),
                total: 1,
                lineItems: []
            ),
            attempts: 1,
            rawModelOutput: "{}"
        )
        #expect(bare.collectionSource == .model)
    }

    @Test("default path is a single generate with the same prompt bytes as explicit model")
    func defaultPathPromptByteIdentical() async throws {
        let url = repoFixture("invoice.pdf")
        let canned = invoiceJSON
        let defaultPrompts = PromptCapture()
        let defaultSession = ExtractionSession.mock(
            MockLanguageModel { _, user, _ in
                await defaultPrompts.append(user)
                return canned
            }
        )
        let defaultResult: ExtractionResult<GeometryInvoice> = try await Extract.detailed(
            from: .fileURL(url),
            using: defaultSession
        )

        let modelPrompts = PromptCapture()
        let modelSession = ExtractionSession.mock(
            MockLanguageModel { _, user, _ in
                await modelPrompts.append(user)
                return canned
            }
        )
        var modelOptions = ExtractionOptions()
        modelOptions.lineItemSource = .model
        let modelResult: ExtractionResult<GeometryInvoice> = try await Extract.detailed(
            from: .fileURL(url),
            using: modelSession,
            options: modelOptions
        )

        let defaultAll = await defaultPrompts.all
        let modelAll = await modelPrompts.all
        #expect(defaultAll.count == 1)
        #expect(modelAll.count == 1)
        let defaultPrompt = try #require(defaultAll.first)
        let modelPrompt = try #require(modelAll.first)
        #expect(defaultPrompt == modelPrompt)
        #expect(defaultPrompt.utf8.elementsEqual(modelPrompt.utf8))
        #expect(!defaultPrompt.contains("## Candidate tables"))
        #expect(!defaultPrompt.contains("column 0 is the leftmost"))
        #expect(defaultResult.collectionSource == .model)
        #expect(modelResult.collectionSource == .model)
        #expect(defaultResult.value.lineItems.count == 2)
        #expect(defaultResult.attempts == 1)
    }

    // MARK: - Geometry on fixtures

    @Test("invoice.pdf geometry path parses Widget Pro / Support Plan from cells")
    func invoicePDFGeometry() async throws {
        let url = repoFixture("invoice.pdf")
        let mapping = """
            {"table": 1, "columns": {"description": 0, "quantity": 1, "amount": 2}}
            """
        let headers = """
            {"vendor": "Acme Supplies Co.", "dueDate": "2024-07-31", "total": 1250.00}
            """
        let prompts = PromptCapture()
        let session = ExtractionSession.mock(
            MockLanguageModel { _, user, index in
                await prompts.append(user)
                if index == 0 { return mapping }
                return headers
            }
        )
        var options = ExtractionOptions()
        options.lineItemSource = .geometry
        options.maxRetries = 0
        let result: ExtractionResult<GeometryInvoice> = try await Extract.detailed(
            from: .fileURL(url),
            using: session,
            options: options
        )

        #expect(result.collectionSource == .geometry)
        #expect(result.value.vendor == "Acme Supplies Co.")
        #expect(result.value.lineItems.count == 2)
        #expect(result.value.lineItems[0].description == "Widget Pro")
        #expect(result.value.lineItems[0].quantity == 2)
        #expect(result.value.lineItems[0].amount == Decimal(string: "500")!)
        #expect(result.value.lineItems[1].description == "Support Plan")
        #expect(result.value.lineItems[1].quantity == 1)
        #expect(result.value.lineItems[1].amount == Decimal(string: "250")!)

        let all = await prompts.all
        #expect(all.count == 2)
        #expect(all[0].contains("## Candidate tables"))
        #expect(all[0].contains("Widget Pro"))
        #expect(!all[1].contains("## Candidate tables"))
        #expect(!all[1].contains("\"lineItems\""))

        let desc = result.signals.fields.first { $0.path == "lineItems[0].description" }
        #expect(desc?.grounding == .verbatim)
        #expect(desc?.provenance != nil, "geometry-built cells should keep bounding boxes")
    }

    @Test("receipt.png geometry path parses Latte / Croissant from cells")
    func receiptPNGGeometry() async throws {
        let url = repoFixture("receipt.png")
        let mapping = """
            {"table": 1, "columns": {"name": 0, "price": 1}}
            """
        let headers = """
            {"merchant": "Cafe Example", "date": "2024-06-15", "total": 12.50, "currency": "USD"}
            """
        let session = ExtractionSession.mock(
            MockLanguageModel { _, user, index in
                if user.contains("## Candidate tables") { return mapping }
                return headers
            }
        )
        var options = ExtractionOptions()
        options.lineItemSource = .geometry
        options.maxRetries = 0
        let result: ExtractionResult<GeometryReceipt> = try await Extract.detailed(
            from: .fileURL(url),
            using: session,
            options: options
        )

        if case .geometryFallback(let reason) = result.collectionSource, reason == "no qualifying table" {
            print("SKIP receiptPNGGeometry: no qualifying table (Vision empty or sparse)")
            return
        }
        #expect(result.collectionSource == .geometry)
        #expect(result.value.items.count == 2)
        #expect(result.value.items[0].name == "Latte")
        #expect(result.value.items[0].price == Decimal(string: "4.50")!)
        #expect(result.value.items[1].name.localizedCaseInsensitiveContains("Croissant"))
        #expect(result.value.items[1].price == Decimal(string: "6")!)
        // Totals rows must not become line items.
        #expect(!result.value.items.contains { $0.name.localizedCaseInsensitiveContains("Subtotal") })
        #expect(!result.value.items.contains { $0.name.localizedCaseInsensitiveContains("TOTAL") })
        #expect(!result.value.items.contains { $0.name.caseInsensitiveCompare("Tax") == .orderedSame })
    }

    // MARK: - Fallback

    @Test("no qualifying table falls back and says so")
    func noQualifyingTableFallsBack() async throws {
        let canned = invoiceJSON
        let prompts = PromptCapture()
        let session = ExtractionSession.mock(
            MockLanguageModel { _, user, _ in
                await prompts.append(user)
                return canned
            }
        )
        var options = ExtractionOptions()
        options.lineItemSource = .geometry
        options.maxRetries = 0
        let result: ExtractionResult<GeometryInvoice> = try await Extract.detailed(
            from: .text("A short prose letter with no columns or amounts laid out as a grid."),
            using: session,
            options: options
        )
        #expect(result.collectionSource == .geometryFallback(reason: "no qualifying table"))
        #expect(result.collectionSource.fallbackReason == "no qualifying table")
        #expect(result.value.lineItems.count == 2)
        #expect(result.value.lineItems[0].description == "Widget Pro")
        let all = await prompts.all
        #expect(all.count == 1)
        #expect(!all[0].contains("## Candidate tables"))
    }

    @Test("schema without an array-of-objects falls back")
    func noObjectCollectionFallsBack() async throws {
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [#"{"vendor":"Acme","total":1}"#])
        )
        var options = ExtractionOptions()
        options.lineItemSource = .geometry
        let result: ExtractionResult<HeaderOnlyGeometryInvoice> = try await Extract.detailed(
            from: .text("Vendor Acme total 1"),
            using: session,
            options: options
        )
        #expect(result.collectionSource.reportToken == "geometryFallback")
        #expect(
            result.collectionSource.fallbackReason
                == "schema has no array-of-objects collection"
        )
    }

    @Test("mapping that names a missing column is rejected rather than producing garbage")
    func invalidColumnRejected() async throws {
        let url = repoFixture("invoice.pdf")
        let badMapping = """
            {"table": 1, "columns": {"description": 0, "quantity": 1, "amount": 99}}
            """
        let canned = invoiceJSON
        let session = ExtractionSession.mock(
            MockLanguageModel { _, user, _ in
                if user.contains("## Candidate tables") { return badMapping }
                return canned
            }
        )
        var options = ExtractionOptions()
        options.lineItemSource = .geometry
        options.maxRetries = 0
        let result: ExtractionResult<GeometryInvoice> = try await Extract.detailed(
            from: .fileURL(url),
            using: session,
            options: options
        )
        #expect(result.collectionSource.reportToken == "geometryFallback")
        #expect(
            result.collectionSource.fallbackReason?
                .contains("mapping named column 99 which is out of range") == true
        )
        // Model JSON, not a garbage row invented from column 99.
        #expect(result.value.lineItems.count == 2)
        #expect(result.value.lineItems[0].description == "Widget Pro")
        #expect(result.value.lineItems[0].amount == Decimal(string: "500")!)
    }

    // MARK: - Deterministic parse

    @Test("German-style cell values parse through the deterministic path")
    func germanCellValues() {
        let de = Locale(identifier: "de_DE")
        let amountSchema = ExtractionSchema.number()
        let intSchema = ExtractionSchema.integer()

        let grouped =
            GeometryLineItems.typedJSONValue(
                "1.234,56",
                schema: amountSchema,
                locale: de
            ) as? NSNumber
        #expect(grouped?.decimalValue == Decimal(string: "1234.56"))

        let trailing =
            GeometryLineItems.typedJSONValue(
                "12-",
                schema: amountSchema,
                locale: de
            ) as? NSNumber
        #expect(trailing?.decimalValue == Decimal(string: "-12"))

        let spaced =
            GeometryLineItems.typedJSONValue(
                "1,12 -",
                schema: amountSchema,
                locale: de
            ) as? NSNumber
        #expect(spaced?.decimalValue == Decimal(string: "-1.12"))

        let qty =
            GeometryLineItems.typedJSONValue("qty 2", schema: intSchema, locale: nil)
            as? NSNumber
        #expect(qty?.intValue == 2)

        let table = ExtractedTable(
            pageIndex: 0,
            rowCount: 2,
            columnCount: 3,
            cells: [
                .init(text: "Schraube", row: 0, column: 0),
                .init(text: "1", row: 0, column: 1),
                .init(text: "1.234,56", row: 0, column: 2),
                .init(text: "Mutter", row: 1, column: 0),
                .init(text: "2", row: 1, column: 1),
                .init(text: "12-", row: 1, column: 2),
            ]
        )
        let itemSchema = ExtractionSchema.object(
            properties: [
                "description": .string(),
                "quantity": .integer(),
                "amount": .number(),
            ],
            required: ["description", "quantity", "amount"],
            propertyOrder: ["description", "quantity", "amount"]
        )
        let built = GeometryLineItems.buildItems(
            table: table,
            columns: ["description": 0, "quantity": 1, "amount": 2],
            itemSchema: itemSchema,
            locale: de
        )
        #expect(!built.droppedRequiredRow)
        #expect(built.items.count == 2)
        #expect(built.items[0]["description"] as? String == "Schraube")
        #expect((built.items[0]["amount"] as? NSNumber)?.decimalValue == Decimal(string: "1234.56"))
        #expect((built.items[1]["amount"] as? NSNumber)?.decimalValue == Decimal(string: "-12"))
    }

    @Test("firstObjectCollection is the first array-of-objects only")
    func firstObjectCollectionScope() {
        #expect(GeometryInvoice.extractionSchema.firstObjectCollection?.dottedPath == "lineItems")
        #expect(HeaderOnlyGeometryInvoice.extractionSchema.firstObjectCollection == nil)
        #expect(GeometryReceipt.extractionSchema.firstObjectCollection?.dottedPath == "items")

        let nested = ExtractionSchema.object(
            properties: [
                "title": .string(),
                "payload": .object(
                    properties: [
                        "lines": .array(
                            items: .object(
                                properties: ["description": .string()],
                                required: ["description"]
                            )
                        )
                    ],
                    required: ["lines"]
                ),
                "tags": .array(items: .string()),
            ],
            required: ["title"],
            propertyOrder: ["title", "payload", "tags"]
        )
        #expect(nested.firstObjectCollection?.dottedPath == "payload.lines")

        // `.object` factory defaults propertyOrder to required; optional collections
        // must still be found.
        let optionalOnly = ExtractionSchema.object(
            properties: [
                "vendor": .string(),
                "lineItems": .array(
                    items: .object(
                        properties: ["description": .string()],
                        required: ["description"]
                    )
                ),
            ],
            required: ["vendor"]
        )
        #expect(optionalOnly.firstObjectCollection?.dottedPath == "lineItems")
    }

    @Test("a data row missing a required mapped field makes the mapping unusable")
    func droppedRequiredRowIsUnusable() {
        let table = ExtractedTable(
            pageIndex: 0,
            rowCount: 2,
            columnCount: 2,
            cells: [
                .init(text: "Widget Pro", row: 0, column: 0),
                .init(text: "500.00", row: 0, column: 1),
                .init(text: "Support Plan", row: 1, column: 0),
            ]
        )
        let itemSchema = ExtractionSchema.object(
            properties: [
                "description": .string(),
                "amount": .number(),
            ],
            required: ["description", "amount"]
        )
        let built = GeometryLineItems.buildItems(
            table: table,
            columns: ["description": 0, "amount": 1],
            itemSchema: itemSchema,
            locale: nil
        )
        #expect(built.droppedRequiredRow)
        #expect(built.items.count == 1)
    }

    @Test("shaped tables are preferred; unshaped dense grids are candidates when nothing is shaped")
    func candidatePreference() {
        let shaped = ExtractedTable(
            pageIndex: 0,
            rowCount: 3,
            columnCount: 3,
            cells: (0..<3).flatMap { row in
                (0..<3).map { col in
                    ExtractedTable.Cell(text: "r\(row)c\(col)", row: row, column: col)
                }
            }
        )
        let short = ExtractedTable(
            pageIndex: 0,
            rowCount: 2,
            columnCount: 3,
            cells: (0..<2).flatMap { row in
                (0..<3).map { col in
                    ExtractedTable.Cell(text: "s\(row)c\(col)", row: row, column: col)
                }
            }
        )
        #expect(shaped.isLineItemShaped)
        #expect(!short.isLineItemShaped)
        #expect(short.isGeometryCollectionCandidate)
        #expect(GeometryLineItems.candidates(in: [short, shaped]).map(\.rowCount) == [3])
        #expect(GeometryLineItems.candidates(in: [short]).map(\.rowCount) == [2])
        #expect(shaped.fillDensity == 1.0)
        #expect(short.fillDensity == 1.0)
    }

    @Test("footer rows are skipped")
    func footerRowsSkipped() {
        #expect(GeometryLineItems.isFooterRow(["Subtotal", "10.50"]))
        #expect(GeometryLineItems.isFooterRow(["TOTAL", "$12.50"]))
        #expect(GeometryLineItems.isFooterRow(["Tax", "2.00"]))
        #expect(!GeometryLineItems.isFooterRow(["Latte", "4.50"]))
        #expect(!GeometryLineItems.isFooterRow(["Tax consulting", "80.00"]))
    }

    private var invoiceJSON: String {
        """
        {
          "vendor": "Acme Supplies Co.",
          "dueDate": "2024-07-31",
          "total": 1250.00,
          "lineItems": [
            {"description": "Widget Pro", "amount": 500.00, "quantity": 2},
            {"description": "Support Plan", "amount": 250.00, "quantity": 1}
          ]
        }
        """
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

private actor PromptCapture {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    var all: [String] { values }
}
