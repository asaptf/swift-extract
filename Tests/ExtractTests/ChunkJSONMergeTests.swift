import Foundation
import Testing

@testable import Extract

@Suite("Deterministic chunk JSON merge")
struct ChunkJSONMergeTests {

    // MARK: - Unit: structural merge

    @Test("agreeing scalars pass through")
    func agreeingScalars() {
        let outcome = ChunkJSONMerger.merge(partialJSONObjects: [
            #"{"name":"Ada","age":36}"#,
            #"{"name":"Ada","age":36,"active":true}"#,
        ])
        let obj = parseObject(outcome.json)
        #expect(obj["name"] as? String == "Ada")
        #expect((obj["age"] as? NSNumber)?.intValue == 36)
        #expect((obj["active"] as? NSNumber)?.boolValue == true)
        #expect(outcome.conflicts.isEmpty)
    }

    @Test("equally ungrounded scalars record conflict and keep first")
    func disagreeingScalarsEquallyUngrounded() {
        let outcome = ChunkJSONMerger.merge(
            partialJSONObjects: [
                #"{"total":10.5,"currency":"EUR"}"#,
                #"{"total":99,"currency":"EUR"}"#,
                #"{"total":10.5,"currency":"USD"}"#,
            ],
            fullDocumentText: "no amounts here still nothing nor here"
        )
        let obj = parseObject(outcome.json)
        #expect((obj["total"] as? NSNumber)?.doubleValue == 10.5)
        #expect(obj["currency"] as? String == "EUR")

        let byPath = Dictionary(uniqueKeysWithValues: outcome.conflicts.map { ($0.path, $0.values) })
        #expect(byPath["total"] != nil)
        #expect(byPath["total"]?.count == 2)
        #expect(byPath["currency"] == ["\"EUR\"", "\"USD\""] || byPath["currency"]?.count == 2)
        // First of equally ungrounded wins deterministically on a second run.
        let again = ChunkJSONMerger.merge(partialJSONObjects: [
            #"{"total":10.5}"#,
            #"{"total":99}"#,
        ])
        #expect((parseObject(again.json)["total"] as? NSNumber)?.doubleValue == 10.5)
    }

    @Test("scalar: only later partial is grounded → later wins, no conflict")
    func laterGroundedScalarWins() {
        // Early invents a total absent from the full document; later carries the real total.
        let outcome = ChunkJSONMerger.merge(
            partialJSONObjects: [
                #"{"grandTotal":12.5,"invoiceNumber":"INV-1"}"#,
                #"{"grandTotal":119.0,"invoiceNumber":"INV-1"}"#,
            ],
            fullDocumentText: """
                Header only. Seller Acme. Invoice INV-1.
                Grand total 119.00 EUR due on receipt.
                """
        )
        let obj = parseObject(outcome.json)
        #expect((obj["grandTotal"] as? NSNumber)?.doubleValue == 119.0)
        #expect(obj["invoiceNumber"] as? String == "INV-1")
        #expect(outcome.conflicts.isEmpty)
    }

    @Test("scalar: both grounded equally → first wins, conflict recorded")
    func bothGroundedFirstWinsWithConflict() {
        let outcome = ChunkJSONMerger.merge(
            partialJSONObjects: [
                #"{"seller":"Acme GmbH"}"#,
                #"{"seller":"Other GmbH"}"#,
            ],
            fullDocumentText: "Seller Acme GmbH ships from Berlin. Also lists Other GmbH as a partner."
        )
        let obj = parseObject(outcome.json)
        #expect(obj["seller"] as? String == "Acme GmbH")
        #expect(outcome.conflicts.count == 1)
        #expect(outcome.conflicts[0].path == "seller")
        #expect(outcome.conflicts[0].values.count == 2)
    }

    @Test("array entry with text nowhere in source is dropped")
    func ungroundedArrayEntryDropped() {
        let outcome = ChunkJSONMerger.merge(
            partialJSONObjects: [
                #"{"items":[{"name":"Tea","price":5},{"name":"Hallucinated Widget XYZ","price":1}]}"#,
                #"{"items":[{"name":"Cake","price":7}]}"#,
            ],
            fullDocumentText: "Tea 5.00 Cake menu Cake 7.00"
        )
        let items = parseObject(outcome.json)["items"] as? [[String: Any]] ?? []
        #expect(items.count == 2)
        let names = items.compactMap { $0["name"] as? String }
        #expect(names.contains("Tea"))
        #expect(names.contains("Cake"))
        #expect(!names.contains("Hallucinated Widget XYZ"))
        #expect(outcome.conflicts.isEmpty)
    }

    @Test("legitimately repeated line item is kept when text is in the source")
    func legitimateLineItemKept() {
        // Same description appears once in the document; two partials both extract it
        // with the same fields → de-dupe to one. Distinct amount keeps a second row.
        let outcome = ChunkJSONMerger.merge(
            partialJSONObjects: [
                #"{"items":[{"name":"Consulting","price":100}]}"#,
                #"{"items":[{"name":"Consulting","price":100},{"name":"Consulting","price":200}]}"#,
            ],
            fullDocumentText: "Consulting services Consulting services continued hours billed"
        )
        let items = parseObject(outcome.json)["items"] as? [[String: Any]] ?? []
        #expect(items.count == 2)
        #expect(items[0]["name"] as? String == "Consulting")
        #expect((items[0]["price"] as? NSNumber)?.intValue == 100)
        #expect((items[1]["price"] as? NSNumber)?.intValue == 200)
    }

    @Test("short numeric match does not outrank a distinctive later total")
    func shortNumericNotDistinctiveForArbitration() {
        // `2` is not distinctive; `119.5` is and appears in the document.
        let outcome = ChunkJSONMerger.merge(
            partialJSONObjects: [
                #"{"total":2}"#,
                #"{"total":119.5}"#,
            ],
            fullDocumentText: "Quantity 2 of tea Amount due 119.50"
        )
        let obj = parseObject(outcome.json)
        #expect((obj["total"] as? NSNumber)?.doubleValue == 119.5)
        #expect(outcome.conflicts.isEmpty)
    }

    @Test("paraphrased line description kept via token coverage")
    func paraphrasedDescriptionKeptByTokens() {
        // Model reorders tokens slightly; still ≥50% significant tokens hit the source.
        let outcome = ChunkJSONMerger.merge(
            partialJSONObjects: [
                #"{"items":[{"name":"Medium Mineralwasser PET","price":5.49}]}"#
            ],
            fullDocumentText: "Mineralwasser Medium 12 x 1,0l PET 5,49"
        )
        let items = parseObject(outcome.json)["items"] as? [[String: Any]] ?? []
        #expect(items.count == 1)
        #expect(items[0]["name"] as? String == "Medium Mineralwasser PET")
    }

    @Test("null yields to a real value without conflict")
    func nullYieldsToValue() {
        let outcome = ChunkJSONMerger.merge(partialJSONObjects: [
            #"{"homepage":null,"name":"Eve"}"#,
            #"{"homepage":"https://eve.test"}"#,
        ])
        let obj = parseObject(outcome.json)
        #expect(obj["homepage"] as? String == "https://eve.test")
        #expect(obj["name"] as? String == "Eve")
        #expect(outcome.conflicts.isEmpty)
    }

    @Test("arrays concatenate then de-dupe equal entries")
    func arrayConcatAndDedupe() {
        // Without fullDocumentText, grounding filter is skipped (pure structural merge).
        let outcome = ChunkJSONMerger.merge(partialJSONObjects: [
            #"{"items":[{"name":"Tea","price":5},{"name":"Cake","price":7}]}"#,
            #"{"items":[{"name":"Cake","price":7},{"name":"Tea","price":5},{"name":"Pie","price":3}]}"#,
        ])
        let obj = parseObject(outcome.json)
        let items = obj["items"] as? [[String: Any]] ?? []
        #expect(items.count == 3)
        #expect(items[0]["name"] as? String == "Tea")
        #expect(items[1]["name"] as? String == "Cake")
        #expect(items[2]["name"] as? String == "Pie")
        #expect(outcome.conflicts.isEmpty)
    }

    @Test("array de-dupe uses string trim but keeps legitimately different rows")
    func arrayDedupeNormalisation() {
        let outcome = ChunkJSONMerger.merge(partialJSONObjects: [
            #"{"items":[{"name":"Tea","price":5}]}"#,
            #"{"items":[{"name":"  Tea  ","price":5},{"name":"Tea","price":6}]}"#,
        ])
        let items = parseObject(outcome.json)["items"] as? [[String: Any]] ?? []
        // Trimmed name+same price collapses; different price stays.
        #expect(items.count == 2)
        #expect((items[1]["price"] as? NSNumber)?.intValue == 6)
    }

    @Test("root null and non-object partials contribute nothing")
    func nullAndGarbageIgnored() {
        let outcome = ChunkJSONMerger.merge(partialJSONObjects: [
            "null",
            "[1,2,3]",
            "not json at all",
            #"{"name":"Only"}"#,
            "```json\nnull\n```",
        ])
        let obj = parseObject(outcome.json)
        #expect(obj["name"] as? String == "Only")
        #expect(obj.count == 1)
        #expect(outcome.conflicts.isEmpty)
    }

    @Test("all unusable partials yield empty object")
    func allNullYieldEmptyObject() {
        let outcome = ChunkJSONMerger.merge(partialJSONObjects: ["null", "null", "42"])
        #expect(outcome.json == "{}")
        #expect(outcome.conflicts.isEmpty)
    }

    @Test("nested objects merge key-wise")
    func nestedObjects() {
        let outcome = ChunkJSONMerger.merge(partialJSONObjects: [
            #"{"seller":{"name":"Acme","city":"Berlin"},"total":1}"#,
            #"{"seller":{"name":"Acme","country":"DE"},"total":1}"#,
        ])
        let seller = parseObject(outcome.json)["seller"] as? [String: Any] ?? [:]
        #expect(seller["name"] as? String == "Acme")
        #expect(seller["city"] as? String == "Berlin")
        #expect(seller["country"] as? String == "DE")
        #expect(outcome.conflicts.isEmpty)
    }

    @Test("nested scalar conflict records dotted path when equally ungrounded")
    func nestedConflictPath() {
        let outcome = ChunkJSONMerger.merge(
            partialJSONObjects: [
                #"{"seller":{"name":"Acme"}}"#,
                #"{"seller":{"name":"Other"}}"#,
            ],
            fullDocumentText: "x y"
        )
        #expect(outcome.conflicts.count == 1)
        #expect(outcome.conflicts[0].path == "seller.name")
        let seller = parseObject(outcome.json)["seller"] as? [String: Any] ?? [:]
        #expect(seller["name"] as? String == "Acme")
    }

    @Test("nested arrays concatenate with de-dupe")
    func nestedArrays() {
        let outcome = ChunkJSONMerger.merge(partialJSONObjects: [
            #"{"outer":{"lines":[1,2]}}"#,
            #"{"outer":{"lines":[2,3]}}"#,
        ])
        let outer = parseObject(outcome.json)["outer"] as? [String: Any] ?? [:]
        let lines = outer["lines"] as? [NSNumber] ?? []
        #expect(lines.map(\.intValue) == [1, 2, 3])
    }

    // MARK: - Hard-split boundaries

    @Test("hard-split prefers newline over mid-token cut")
    func hardSplitPrefersNewline() {
        // budget lands inside "secondline…" but a newline is nearby.
        let text = String(repeating: "a", count: 30) + "\n" + String(repeating: "b", count: 50)
        let slices = ExtractedDocument.hardSplit(text, budget: 35)
        #expect(slices.count >= 2)
        #expect(slices[0].hasSuffix("\n") || !slices[0].contains("b"))
        // First slice should end at the newline, not mid-"aaa…".
        #expect(slices[0] == String(repeating: "a", count: 30) + "\n")
    }

    @Test("hard-split prefers whitespace when no newline in window")
    func hardSplitPrefersWhitespace() {
        let text = String(repeating: "word ", count: 20)  // 100 chars
        let slices = ExtractedDocument.hardSplit(text, budget: 40)
        #expect(slices.count >= 2)
        // No slice should start mid-word with a partial "ord".
        for slice in slices {
            let trimmed = slice.trimmingCharacters(in: .whitespaces)
            #expect(trimmed.hasPrefix("word") || trimmed.isEmpty)
        }
    }

    @Test("hard-split falls back to budget when token exceeds window")
    func hardSplitLongToken() {
        let text = String(repeating: "x", count: 200)
        let slices = ExtractedDocument.hardSplit(text, budget: 50)
        #expect(slices.count == 4)
        #expect(slices.allSatisfy { $0.count == 50 })
    }

    // MARK: - End-to-end mock backend

    @Test("chunked extract reports merged value and merge conflicts")
    func endToEndMergedValueAndConflicts() async throws {
        // Ages 30 vs 31 are short numerics → ungrounded for arbitration → first wins.
        let partial1 = """
            {"name":"Eve","age":30,"balance":1,"birthday":"1990-01-01","active":true,"homepage":null}
            """
        let partial2 = """
            {"name":"Eve","age":31,"balance":1,"birthday":"1990-01-01","active":true,"homepage":"https://eve.test"}
            """
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [partial1, partial2])
        )
        let options = ExtractionOptions(
            maxRetries: 0,
            chunkingStrategy: .fixed(characterBudget: 40)
        )
        let result: ExtractionResult<SimplePerson> = try await Extract.detailed(
            from: .text(String(repeating: "document ", count: 8)),
            using: session,
            options: options
        )

        #expect(result.value.name == "Eve")
        #expect(result.value.age == 30)  // equal ungrounded ranks → first wins
        #expect(result.value.balance == Decimal(1))
        #expect(result.value.homepage?.host == "eve.test")
        #expect(result.chunksUsed == 2)
        #expect(result.attempts == 2)

        let ageConflict = result.signals.mergeConflicts.first { $0.path == "age" }
        #expect(ageConflict != nil)
        #expect(ageConflict?.values.count == 2)
        #expect(result.signals.mergeConflicts.allSatisfy { !$0.values.isEmpty })
    }

    // MARK: - Helpers

    private func parseObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Issue.record("not an object: \(json)")
            return [:]
        }
        return obj
    }
}
