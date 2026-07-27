import Extract
import Foundation
import Testing

@Extractable
struct GroundingProbe {
    let merchant: String
    @Guide("ISO 8601 date") let date: Date
    let total: Decimal
    let note: String?
    let items: [GroundingItem]
    let flagged: Bool

    @Extractable
    struct GroundingItem {
        let name: String
        let price: Decimal
    }
}

@Suite("Extraction grounding signals")
struct GroundingSignalsTests {
    static let sourceText = """
        MERCHANT: Café Müller
        Date: 15 MAR 1990
        Widget Pro  $12.50
        Gadget       $5.00
        Total: $17.50
        Notes: paid in cash
        """

    static let mockJSON = """
        {
          "merchant": "Café Müller",
          "date": "1990-03-15",
          "total": 17.5,
          "note": "paid in cash",
          "flagged": true,
          "items": [
            {"name": "Widget Pro", "price": 12.5},
            {"name": "Gadget", "price": 5}
          ]
        }
        """

    @Test("verbatim, normalized, reformatted date, nested paths, and hallucinated absent")
    func allGroundingCases() async throws {
        // Hallucinated taxId-like value is injected via a richer probe below;
        // here merchant is verbatim (with possible unicode), date reformatted,
        // note normalized-ish, items nested.
        let session = ExtractionSession.mock(MockLanguageModel(responses: [Self.mockJSON]))
        let result: ExtractionResult<GroundingProbe> = try await Extract.detailed(
            from: .text(Self.sourceText),
            using: session
        )

        #expect(result.signals.attempts == 1)
        #expect(result.signals.chunksUsed == 1)
        #expect(!result.signals.fields.isEmpty)

        let byPath = Dictionary(uniqueKeysWithValues: result.signals.fields.map { ($0.path, $0.grounding) })

        // Literal string match.
        #expect(byPath["merchant"] == .verbatim || byPath["merchant"] == .normalized)
        #expect(byPath["note"] == .verbatim)
        #expect(byPath["items[0].name"] == .verbatim)
        #expect(byPath["items[1].name"] == .verbatim)

        // Date reformatted from "15 MAR 1990" → ISO; must NOT be absent.
        #expect(byPath["date"] == .reformatted)
        #expect(byPath["date"] != .absent)

        // Numbers often appear as $12.50 / $17.50 → normalized or reformatted, not absent.
        #expect(byPath["total"] != .absent)
        #expect(byPath["items[0].price"] != .absent)
        #expect(byPath["items[1].price"] != .absent)

        // Booleans are not groundable → reformatted.
        #expect(byPath["flagged"] == .reformatted)

        #expect(result.signals.absentFieldPaths.isEmpty)
    }

    @Test("Date field reformatted from human source is not reported absent")
    func dateNotAbsentWhenReformatted() async throws {
        let canned = """
            {
              "merchant": "Acme",
              "date": "1990-03-15",
              "total": 1,
              "note": null,
              "flagged": false,
              "items": []
            }
            """
        let source = "Acme invoice dated 15 MAR 1990 total 1"
        let session = ExtractionSession.mock(MockLanguageModel(responses: [canned]))
        let result: ExtractionResult<GroundingProbe> = try await Extract.detailed(
            from: .text(source),
            using: session
        )
        let dateSignal = result.signals.fields.first { $0.path == "date" }
        #expect(dateSignal?.grounding == .reformatted)
        #expect(result.signals.absentFieldPaths.contains("date") == false)
    }

    @Test("hallucinated string leaf is absent")
    func hallucinatedAbsent() async throws {
        let canned = """
            {
              "merchant": "Completely Invented Corp",
              "date": "1990-03-15",
              "total": 1,
              "note": "ghost note not in source",
              "flagged": false,
              "items": []
            }
            """
        let source = "Acme invoice dated 15 MAR 1990 total 1"
        let session = ExtractionSession.mock(MockLanguageModel(responses: [canned]))
        let result: ExtractionResult<GroundingProbe> = try await Extract.detailed(
            from: .text(source),
            using: session
        )
        let byPath = Dictionary(uniqueKeysWithValues: result.signals.fields.map { ($0.path, $0.grounding) })
        #expect(byPath["merchant"] == .absent)
        #expect(byPath["note"] == .absent)
        #expect(result.signals.absentFieldPaths.contains("merchant"))
        #expect(result.signals.absentFieldPaths.contains("note"))
        // Date still reformatted, not dragged into absent noise.
        #expect(byPath["date"] == .reformatted)
    }

    @Test("normalized match ignores case and diacritics")
    func normalizedCaseAndDiacritics() async throws {
        let canned = """
            {
              "merchant": "cafe muller",
              "date": "1990-03-15",
              "total": 1,
              "note": null,
              "flagged": false,
              "items": []
            }
            """
        // Source has Café Müller (diacritics + capitals).
        let source = "CAFÉ MÜLLER receipt 15 MAR 1990 total 1"
        let session = ExtractionSession.mock(MockLanguageModel(responses: [canned]))
        let result: ExtractionResult<GroundingProbe> = try await Extract.detailed(
            from: .text(source),
            using: session
        )
        let merchant = result.signals.fields.first { $0.path == "merchant" }?.grounding
        #expect(merchant == .normalized || merchant == .verbatim)
    }

    @Test("nested array and sub-struct paths use indexed notation")
    func nestedPaths() async throws {
        let session = ExtractionSession.mock(MockLanguageModel(responses: [Self.mockJSON]))
        let result: ExtractionResult<GroundingProbe> = try await Extract.detailed(
            from: .text(Self.sourceText),
            using: session
        )
        let paths = Set(result.signals.fields.map(\.path))
        #expect(paths.contains("items[0].name"))
        #expect(paths.contains("items[0].price"))
        #expect(paths.contains("items[1].name"))
        #expect(paths.contains("items[1].price"))
        #expect(paths.contains("merchant"))
        #expect(paths.contains("total"))
    }

    @Test("ExtractionResult init without signals stays source-compatible")
    func resultInitCompatibility() throws {
        let value = try GroundingProbe.decodeExtracted(
            from: """
                {"merchant":"X","date":"2020-01-01","total":1,"note":null,"flagged":false,"items":[]}
                """
        )
        let result = ExtractionResult(value: value, attempts: 2, rawModelOutput: "{}", chunksUsed: 3)
        #expect(result.attempts == 2)
        #expect(result.chunksUsed == 3)
        #expect(result.signals.attempts == 2)
        #expect(result.signals.chunksUsed == 3)
        #expect(result.signals.fields.isEmpty)
    }

    @Test("multi-line address with comma-joined value grounds as normalized")
    func multiLineAddressNormalized() async throws {
        // Real fixture shape (fixtures/identity_document.txt): address across newlines;
        // model often returns a single comma-joined string.
        let source = """
            Address (optional, as printed on supporting ID):
            123 SAMPLE STREET
            APT 4B
            SPRINGFIELD, IL 62701
            UNITED STATES
            """
        let address = "123 SAMPLE STREET, APT 4B, SPRINGFIELD, IL 62701, UNITED STATES"
        let canned = """
            {
              "merchant": "\(address)",
              "date": "1990-03-15",
              "total": 1,
              "note": null,
              "flagged": false,
              "items": []
            }
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [canned]))
        let result: ExtractionResult<GroundingProbe> = try await Extract.detailed(
            from: .text(source),
            using: session
        )
        let merchant = result.signals.fields.first { $0.path == "merchant" }?.grounding
        #expect(merchant == .normalized)
        #expect(result.signals.absentFieldPaths.contains("merchant") == false)
    }

    @Test("fabricated number is reformatted never absent")
    func fabricatedNumberNotAbsent() async throws {
        // Documented limitation: numberGrounding returns .reformatted when no match is
        // found, so a fabricated total is never flagged as absent.
        let canned = """
            {
              "merchant": "Acme",
              "date": "1990-03-15",
              "total": 99999.99,
              "note": null,
              "flagged": false,
              "items": [{"name": "Widget", "price": 88888.88}]
            }
            """
        let source = "Acme invoice dated 15 MAR 1990 for one Widget"
        let session = ExtractionSession.mock(MockLanguageModel(responses: [canned]))
        let result: ExtractionResult<GroundingProbe> = try await Extract.detailed(
            from: .text(source),
            using: session
        )
        let byPath = Dictionary(uniqueKeysWithValues: result.signals.fields.map { ($0.path, $0.grounding) })
        #expect(byPath["total"] == .reformatted)
        #expect(byPath["items[0].price"] == .reformatted)
        #expect(byPath["total"] != .absent)
        #expect(byPath["items[0].price"] != .absent)
        #expect(result.signals.absentFieldPaths.contains("total") == false)
        #expect(result.signals.absentFieldPaths.contains("items[0].price") == false)
        // Merchant is still present; only strings can be absent.
        #expect(byPath["merchant"] == .verbatim)
    }
}
