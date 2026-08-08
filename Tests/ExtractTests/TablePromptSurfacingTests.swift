import CoreGraphics
import Foundation
import Testing

@testable import Extract

/// Stage 2: tables in prompts and on ``ExtractionResult``.
@Suite("Table prompt & result surfacing (stage 2)")
struct TablePromptSurfacingTests {

    // MARK: - Byte-identical prompt when no tables

    @Test("empty tables leave user prompt byte-identical")
    func emptyTablesPromptByteIdentical() {
        let document = ExtractedDocument(
            text: "Hello prose document with no geometry.",
            sourceDescription: "text"
        )
        let baseline = PromptBuilder.userPrompt(
            type: PromptProbe.self,
            document: document,
            locale: nil,
            tables: []
        )
        let withDefault = PromptBuilder.userPrompt(
            type: PromptProbe.self,
            document: document,
            locale: nil
        )
        #expect(baseline == withDefault)
        #expect(!baseline.contains("Detected tables"))

        // Explicit empty array vs omitted parameter must match character-for-character.
        #expect(baseline.utf8.elementsEqual(withDefault.utf8))
    }

    @Test("prose PDF/text with automatic detection yields byte-identical prompt")
    func proseDocumentNoTableSection() throws {
        let document = ExtractedDocument(
            text: """
                This is ordinary narrative prose without columns.
                A second paragraph continues the story with more words.
                Nothing here should look like an invoice line-item grid.
                """,
            sourceDescription: "prose.txt"
        )
        let tables = TableDetector.detect(
            documentBlocks: document.blocks,
            mode: .automatic
        )
        #expect(tables.isEmpty)

        let without = PromptBuilder.userPrompt(
            type: PromptProbe.self,
            document: document,
            locale: nil,
            tables: []
        )
        let withDetected = PromptBuilder.userPrompt(
            type: PromptProbe.self,
            document: document,
            locale: nil,
            tables: tables
        )
        #expect(without == withDetected)
        #expect(!withDetected.contains("## Detected tables"))
    }

    @Test("tableDetection off yields empty tables and byte-identical prompt")
    func detectionOffByteIdentical() throws {
        let url = repoFixture("invoice.pdf")
        let document = try PDFAdapter.ingest(url: url)
        let auto = TableDetector.detect(documentBlocks: document.blocks, mode: .automatic)
        #expect(!auto.isEmpty, "invoice should detect tables in automatic mode")

        let off = TableDetector.detect(documentBlocks: document.blocks, mode: .off)
        #expect(off.isEmpty)

        let baseline = PromptBuilder.userPrompt(
            type: PromptProbe.self,
            document: document,
            locale: nil,
            tables: []
        )
        let withOff = PromptBuilder.userPrompt(
            type: PromptProbe.self,
            document: document,
            locale: nil,
            tables: off
        )
        #expect(baseline == withOff)
        #expect(!withOff.contains("## Detected tables"))

        // Automatic mode must still keep all original linear text.
        let withAuto = PromptBuilder.userPrompt(
            type: PromptProbe.self,
            document: document,
            locale: nil,
            tables: auto
        )
        #expect(withAuto.contains(document.fullText))
        #expect(withAuto.contains("## Detected tables"))
        #expect(withAuto.contains("Acme Supplies Co."))
        let returnPhrase = "Return the JSON object now."
        let prefixLen = baseline.count - returnPhrase.count
        #expect(withAuto.hasPrefix(baseline.prefix(prefixLen)))
    }

    @Test("when tables are present, full original document text is still in the prompt")
    func originalTextPreservedWithTables() {
        let document = ExtractedDocument(
            blocks: [
                block("Vendor Acme", x: 0.1, y: 0.05, w: 0.3, h: 0.03),
                block("Widget Pro", x: 0.08, y: 0.20, w: 0.20, h: 0.03),
                block("qty 2", x: 0.35, y: 0.20, w: 0.08, h: 0.03),
                block("$500.00", x: 0.55, y: 0.20, w: 0.12, h: 0.03),
                block("Support Plan", x: 0.08, y: 0.25, w: 0.22, h: 0.03),
                block("qty 1", x: 0.35, y: 0.25, w: 0.08, h: 0.03),
                block("$250.00", x: 0.55, y: 0.25, w: 0.12, h: 0.03),
            ],
            sourceDescription: "synth"
        )
        let tables = TableDetector.detect(documentBlocks: document.blocks)
        #expect(!tables.isEmpty)

        let baseline = PromptBuilder.userPrompt(
            type: PromptProbe.self,
            document: document,
            locale: nil,
            tables: []
        )
        let withTables = PromptBuilder.userPrompt(
            type: PromptProbe.self,
            document: document,
            locale: nil,
            tables: tables
        )

        #expect(withTables.contains(document.fullText))
        // Linear document section is a prefix of the with-tables prompt (before the new section).
        #expect(withTables.contains("## Document (synth)"))
        #expect(baseline.contains(document.fullText))
        #expect(withTables.count > baseline.count)
        #expect(withTables.contains("## Detected tables"))
        #expect(withTables.contains("|"))
    }

    // MARK: - Schema collection walk

    @Test("containsCollection: object with no arrays is false")
    func containsCollectionHeaderOnly() {
        let schema = ExtractionSchema.object(
            properties: [
                "vendor": .string(),
                "total": .number(),
                "issueDate": .string(format: "date"),
            ],
            required: ["vendor", "total"]
        )
        #expect(!schema.containsCollection)
        #expect(!HeaderOnlyInvoice.extractionSchema.containsCollection)
    }

    @Test("containsCollection: top-level array property is true")
    func containsCollectionTopLevelArray() {
        let schema = ExtractionSchema.object(
            properties: [
                "vendor": .string(),
                "lineItems": .array(
                    items: .object(
                        properties: ["description": .string()],
                        required: ["description"]
                    )),
            ],
            required: ["vendor", "lineItems"]
        )
        #expect(schema.containsCollection)
        #expect(Invoice.extractionSchema.containsCollection)
    }

    @Test("containsCollection: nested object with array is true")
    func containsCollectionNestedArray() {
        let schema = ExtractionSchema.object(
            properties: [
                "header": .string(),
                "details": .object(
                    properties: [
                        "rows": .array(items: .string())
                    ],
                    required: ["rows"]
                ),
            ],
            required: ["header", "details"]
        )
        #expect(schema.containsCollection)
        #expect(NestedCollectionProbe.extractionSchema.containsCollection)
    }

    @Test("containsCollection: optional array still counts")
    func containsCollectionOptionalArray() {
        // Optionality is a description note; type remains .array.
        let optionalArray = ExtractionSchema.array(items: .string()).optional()
        #expect(optionalArray.type == .array)
        #expect(optionalArray.containsCollection)

        let objectWithOptionalArray = ExtractionSchema.object(
            properties: [
                "name": .string(),
                "tags": optionalArray,
            ],
            required: ["name"]
        )
        #expect(objectWithOptionalArray.containsCollection)
    }

    @Test("containsCollection: empty object / scalars are false")
    func containsCollectionScalars() {
        #expect(!ExtractionSchema.string().containsCollection)
        #expect(!ExtractionSchema.number().containsCollection)
        #expect(
            !ExtractionSchema.object(properties: [:], required: []).containsCollection
        )
    }

    // MARK: - tablesForPrompt policy

    @Test("tablesForPrompt passes through when schema has a collection")
    func tablesForPromptWithCollection() {
        let tables = [sampleTable()]
        let out = Extract.tablesForPrompt(tables, schema: Invoice.extractionSchema)
        #expect(out.count == 1)
        #expect(out == tables)
    }

    @Test("tablesForPrompt returns empty when schema has no collection")
    func tablesForPromptHeaderOnly() {
        let tables = [sampleTable()]
        let out = Extract.tablesForPrompt(tables, schema: HeaderOnlyInvoice.extractionSchema)
        #expect(out.isEmpty)
    }

    // MARK: - Extract path: schema-gated prompt injection

    @Test("collection-bearing type gets Detected tables section under automatic")
    func collectionBearingPromptIncludesTables() async throws {
        let url = repoFixture("invoice.pdf")
        let canned = """
            {
              "vendor": "Acme Supplies Co.",
              "dueDate": "2024-07-31",
              "total": 1250.00,
              "lineItems": [
                {"description": "Widget Pro", "amount": 500.00, "quantity": 2}
              ]
            }
            """
        let prompts = TablePromptCapture()
        let session = ExtractionSession.mock(
            MockLanguageModel { _, user, _ in
                await prompts.append(user)
                return canned
            }
        )
        let result: ExtractionResult<Invoice> = try await Extract.detailed(
            from: .fileURL(url),
            using: session
        )
        let all = await prompts.all
        let prompt = try #require(all.first)
        #expect(prompt.contains("## Detected tables"))
        #expect(!result.tables.isEmpty)
    }

    @Test("header-only type under automatic is byte-identical to off")
    func headerOnlyPromptByteIdenticalToOff() async throws {
        let url = repoFixture("invoice.pdf")
        let canned = """
            {
              "vendor": "Acme Supplies Co.",
              "dueDate": "2024-07-31",
              "total": 1250.00
            }
            """
        let autoPrompts = TablePromptCapture()
        let autoSession = ExtractionSession.mock(
            MockLanguageModel { _, user, _ in
                await autoPrompts.append(user)
                return canned
            }
        )
        var autoOptions = ExtractionOptions()
        autoOptions.tableDetection = .automatic
        let autoResult: ExtractionResult<HeaderOnlyInvoice> = try await Extract.detailed(
            from: .fileURL(url),
            using: autoSession,
            options: autoOptions
        )

        let offPrompts = TablePromptCapture()
        let offSession = ExtractionSession.mock(
            MockLanguageModel { _, user, _ in
                await offPrompts.append(user)
                return canned
            }
        )
        var offOptions = ExtractionOptions()
        offOptions.tableDetection = .off
        let offResult: ExtractionResult<HeaderOnlyInvoice> = try await Extract.detailed(
            from: .fileURL(url),
            using: offSession,
            options: offOptions
        )

        let auto = try #require(await autoPrompts.all.first)
        let off = try #require(await offPrompts.all.first)
        #expect(auto == off)
        #expect(auto.utf8.elementsEqual(off.utf8))
        #expect(!auto.contains("## Detected tables"))
        // Detection still ran under automatic; off skips it.
        #expect(!autoResult.tables.isEmpty)
        #expect(offResult.tables.isEmpty)
    }

    @Test("nested collection still injects tables into the prompt")
    func nestedCollectionPromptIncludesTables() async throws {
        let document = ExtractedDocument(
            blocks: [
                block("Vendor Acme", x: 0.1, y: 0.05, w: 0.3, h: 0.03),
                block("Widget Pro", x: 0.08, y: 0.20, w: 0.20, h: 0.03),
                block("qty 2", x: 0.35, y: 0.20, w: 0.08, h: 0.03),
                block("$500.00", x: 0.55, y: 0.20, w: 0.12, h: 0.03),
                block("Support Plan", x: 0.08, y: 0.25, w: 0.22, h: 0.03),
                block("qty 1", x: 0.35, y: 0.25, w: 0.08, h: 0.03),
                block("$250.00", x: 0.55, y: 0.25, w: 0.12, h: 0.03),
            ],
            sourceDescription: "synth"
        )
        let tables = TableDetector.detect(documentBlocks: document.blocks, mode: .automatic)
        #expect(!tables.isEmpty)

        let canned = """
            {
              "title": "Order",
              "payload": {
                "lines": [
                  {"description": "Widget Pro", "amount": 500.0}
                ]
              }
            }
            """
        let prompts = TablePromptCapture()
        let session = ExtractionSession.mock(
            MockLanguageModel { _, user, _ in
                await prompts.append(user)
                return canned
            }
        )
        let result: ExtractionResult<NestedCollectionProbe> = try await Extract.extract(
            from: document,
            as: NestedCollectionProbe.self,
            using: session,
            options: ExtractionOptions()
        )
        let prompt = try #require(await prompts.all.first)
        #expect(prompt.contains("## Detected tables"))
        #expect(!result.tables.isEmpty)
    }

    // MARK: - Result.tables

    @Test("result.tables populated for invoice.pdf with real line items")
    func resultTablesInvoice() async throws {
        let url = repoFixture("invoice.pdf")
        let canned = """
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
        let session = ExtractionSession.mock(MockLanguageModel(responses: [canned]))
        let result: ExtractionResult<Invoice> = try await Extract.detailed(
            from: .fileURL(url),
            using: session
        )

        #expect(result.value.vendor == "Acme Supplies Co.")
        #expect(!result.tables.isEmpty, "expected tables on result for invoice.pdf")

        let joined = result.tables.flatMap(\.cells).map(\.text).joined(separator: " ")
        #expect(
            joined.localizedCaseInsensitiveContains("Widget")
                || joined.localizedCaseInsensitiveContains("Support")
        )
        #expect(joined.contains("500") || joined.contains("250"))

        // Source-compatible: constructing without tables still yields empty array.
        let bare = ExtractionResult(
            value: result.value,
            attempts: 1,
            rawModelOutput: "{}"
        )
        #expect(bare.tables.isEmpty)
    }

    @Test("result.tables populated for header-only type under automatic")
    func resultTablesHeaderOnlyAutomatic() async throws {
        let url = repoFixture("invoice.pdf")
        let canned = """
            {
              "vendor": "Acme Supplies Co.",
              "dueDate": "2024-07-31",
              "total": 1250.00
            }
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [canned]))
        var options = ExtractionOptions()
        options.tableDetection = .automatic
        let result: ExtractionResult<HeaderOnlyInvoice> = try await Extract.detailed(
            from: .fileURL(url),
            using: session,
            options: options
        )
        #expect(!result.tables.isEmpty, "header-only types still get result.tables")
    }

    @Test("tableDetection off produces empty result.tables")
    func resultTablesOff() async throws {
        let url = repoFixture("invoice.pdf")
        let canned = """
            {
              "vendor": "Acme Supplies Co.",
              "dueDate": "2024-07-31",
              "total": 1250.00,
              "lineItems": []
            }
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [canned]))
        var options = ExtractionOptions()
        options.tableDetection = .off
        let result: ExtractionResult<Invoice> = try await Extract.detailed(
            from: .fileURL(url),
            using: session,
            options: options
        )
        #expect(result.tables.isEmpty)
    }

    // MARK: - Chunking

    @Test("chunked run keeps whole tables and does not crash")
    func chunkedRunWithTables() async throws {
        // Two pages with a table on page 2; force chunking with a tiny budget.
        var blocks: [ExtractedDocument.Block] = []
        // Page 0: long prose so the first chunk is mostly this page.
        for i in 0..<20 {
            blocks.append(
                .init(
                    text: "Page zero prose line \(i) with enough characters to force a split boundary.",
                    pageIndex: 0,
                    boundingBox: CGRect(x: 0.1, y: 0.05 + CGFloat(i) * 0.04, width: 0.7, height: 0.03)
                )
            )
        }
        // Page 1: invoice-like table.
        blocks.append(contentsOf: [
            block("Widget Pro", x: 0.08, y: 0.20, w: 0.20, h: 0.03, page: 1),
            block("qty 2", x: 0.35, y: 0.20, w: 0.08, h: 0.03, page: 1),
            block("$500.00", x: 0.55, y: 0.20, w: 0.12, h: 0.03, page: 1),
            block("Support Plan", x: 0.08, y: 0.25, w: 0.22, h: 0.03, page: 1),
            block("qty 1", x: 0.35, y: 0.25, w: 0.08, h: 0.03, page: 1),
            block("$250.00", x: 0.55, y: 0.25, w: 0.12, h: 0.03, page: 1),
        ])
        let document = ExtractedDocument(blocks: blocks, sourceDescription: "multi")
        let tables = TableDetector.detect(documentBlocks: document.blocks, mode: .automatic)
        #expect(!tables.isEmpty)

        let chunks = document.chunks(budget: 200)
        #expect(chunks.count >= 2, "expected multiple chunks under budget 200")

        let assigned = Extract.assignTablesToChunks(tables, chunks: chunks)
        #expect(assigned.count == chunks.count)
        // Every assigned table is whole (has full markdown, not truncated).
        for (chunkTables, chunk) in zip(assigned, chunks) {
            for table in chunkTables {
                let md = table.markdown()
                #expect(!md.isEmpty)
                #expect(md.contains("---"))
                // Prompt for this chunk includes the full table section when non-empty.
                let prompt = PromptBuilder.userPrompt(
                    type: PromptProbe.self,
                    document: chunk,
                    locale: nil,
                    allowsPartialObject: true,
                    tables: chunkTables
                )
                #expect(prompt.contains(md))
                #expect(prompt.contains(chunk.fullText))
            }
        }
        // Tables are not lost entirely across the chunked assignment.
        #expect(assigned.contains { !$0.isEmpty })

        // End-to-end extract with forced chunking (deterministic merge of partials).
        let cannedPartial = """
            {"vendor":"Acme","dueDate":"2024-07-31","total":1250,"lineItems":[]}
            """
        // One response per chunk; no LLM merge call.
        let responses = Array(repeating: cannedPartial, count: max(chunks.count, 2))
        let session = ExtractionSession.mock(MockLanguageModel(responses: responses))
        var options = ExtractionOptions()
        options.chunkingStrategy = .fixed(characterBudget: 200)
        options.maxRetries = 0

        let result: ExtractionResult<Invoice> = try await Extract.extract(
            from: document,
            as: Invoice.self,
            using: session,
            options: options
        )
        #expect(result.chunksUsed >= 2)
        #expect(!result.tables.isEmpty)
        #expect(result.value.vendor == "Acme")
    }

    @Test("tables attach only when all cell text appears in the chunk (no chunk-0 fallback)")
    func cellTextAssignmentNoFallback() {
        let table = ExtractedTable(
            pageIndex: 0,
            rowCount: 2,
            columnCount: 2,
            cells: [
                .init(text: "A", row: 0, column: 0),
                .init(text: "1", row: 0, column: 1),
                .init(text: "B", row: 1, column: 0),
                .init(text: "2", row: 1, column: 1),
            ]
        )
        // Neither chunk contains every cell → table attaches to no chunk.
        let chunks = [
            ExtractedDocument(
                blocks: [.init(text: "only half of nothing", pageIndex: 5, boundingBox: nil)],
                sourceDescription: "c1"
            ),
            ExtractedDocument(
                blocks: [.init(text: "other half", pageIndex: 6, boundingBox: nil)],
                sourceDescription: "c2"
            ),
        ]
        let assigned = Extract.assignTablesToChunks([table], chunks: chunks)
        #expect(assigned[0].isEmpty)
        #expect(assigned[1].isEmpty)
    }

    @Test("table attaches to the hard-split slice that contains its cell text")
    func cellTextAssignmentOnHardSplit() {
        let table = ExtractedTable(
            pageIndex: 0,
            rowCount: 1,
            columnCount: 2,
            cells: [
                .init(text: "WidgetProSKU", row: 0, column: 0),
                .init(text: "999.00", row: 0, column: 1),
            ]
        )
        // Same pageIndex on both hard-split chunks; only the second has the cell text.
        let chunks = [
            ExtractedDocument(
                blocks: [
                    .init(text: String(repeating: "padding ", count: 20), pageIndex: 0, boundingBox: nil)
                ],
                sourceDescription: "c1"
            ),
            ExtractedDocument(
                blocks: [
                    .init(text: "line WidgetProSKU qty 1 999.00", pageIndex: 0, boundingBox: nil)
                ],
                sourceDescription: "c2"
            ),
        ]
        let assigned = Extract.assignTablesToChunks([table], chunks: chunks)
        #expect(assigned[0].isEmpty)
        #expect(assigned[1].count == 1)
    }

    // MARK: - Helpers

    @Extractable
    fileprivate struct PromptProbe {
        let name: String
    }

    /// Header fields only — no collection; schema-gated prompt must omit tables.
    @Extractable
    fileprivate struct HeaderOnlyInvoice {
        let vendor: String
        @Guide("ISO 8601 format") let dueDate: Date
        let total: Decimal
    }

    /// Collection nested inside a struct property.
    @Extractable
    fileprivate struct NestedCollectionProbe {
        let title: String
        let payload: Payload

        @Extractable
        struct Payload {
            let lines: [Line]

            @Extractable
            struct Line {
                let description: String
                let amount: Double
            }
        }
    }

    private func sampleTable() -> ExtractedTable {
        ExtractedTable(
            pageIndex: 0,
            rowCount: 2,
            columnCount: 2,
            cells: [
                .init(text: "A", row: 0, column: 0),
                .init(text: "1", row: 0, column: 1),
                .init(text: "B", row: 1, column: 0),
                .init(text: "2", row: 1, column: 1),
            ]
        )
    }

    private func block(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        w: CGFloat,
        h: CGFloat,
        page: Int = 0
    ) -> ExtractedDocument.Block {
        ExtractedDocument.Block(
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

/// Records user prompts from ``MockLanguageModel`` responders (Sendable).
private actor TablePromptCapture {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    var all: [String] { values }
}
