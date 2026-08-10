import Foundation
import Testing

@testable import Extract

// MARK: - Fixtures

@Extractable
struct StreamPerson {
    let name: String
    let age: Int
    let total: Decimal
    let note: String?
}

@Extractable
struct StreamLineItem {
    let sku: String
    let qty: Int
}

@Extractable
struct StreamInvoice {
    let vendor: String
    let total: Decimal
    let lineItems: [StreamLineItem]
}

@Extractable
struct StreamPlain {
    let label: String
    let amount: Decimal

    func validateInvariants() throws {
        if amount < 0 {
            throw InvariantValidationError(
                path: "amount",
                expected: "non-negative",
                found: "\(amount)"
            )
        }
    }
}

// MARK: - Completed-token unit tests

@Suite("Completed-token JSON")
struct CompletedTokenJSONTests {
    @Test("number split across pieces is never surfaced early")
    func numberNeverHalfSurfaced() {
        // Simulate cumulative buffers while "473.00" arrives.
        let prefixes = [
            "{\"total\":4",
            "{\"total\":47",
            "{\"total\":473",
            "{\"total\":473.",
            "{\"total\":473.0",
            "{\"total\":473.00",
            "{\"total\":473.00}",
        ]
        for (i, buffer) in prefixes.enumerated() {
            let snap = CompletedTokenJSON.snapshot(from: buffer)
            if i < prefixes.count - 1 {
                // Before the closing `}`, the number has no delimiter → omit total.
                if let snap {
                    #expect(
                        !snap.contains("473") && !snap.contains("\"total\":47")
                            && !snap.contains("\"total\":4"),
                        "half-number leaked in snapshot \(snap) for buffer \(buffer)"
                    )
                }
            } else {
                #expect(snap == "{\"total\":473.00}")
            }
        }
    }

    @Test("string split mid-token is never surfaced truncated")
    func stringNeverTruncated() {
        let mid = "{\"name\":\"Ad"
        let snapMid = CompletedTokenJSON.snapshot(from: mid)
        if let snapMid {
            #expect(!snapMid.contains("Ad"), "truncated string leaked: \(snapMid)")
        }
        let done = "{\"name\":\"Ada\"}"
        #expect(CompletedTokenJSON.snapshot(from: done) == "{\"name\":\"Ada\"}")
    }

    @Test("array grows element by element, each complete")
    func arrayGrowsCompletely() {
        let s0 = "{\"lineItems\":[{\"sku\":\"A\",\"qty\":1"
        let s1 = "{\"lineItems\":[{\"sku\":\"A\",\"qty\":1}"
        let s2 = "{\"lineItems\":[{\"sku\":\"A\",\"qty\":1},{\"sku\":\"B\",\"qty\":2}"
        let s3 = "{\"lineItems\":[{\"sku\":\"A\",\"qty\":1},{\"sku\":\"B\",\"qty\":2}]}"

        // First element incomplete → empty or no array content with incomplete object.
        let p0 = CompletedTokenJSON.snapshot(from: s0)
        if let p0 {
            #expect(!p0.contains("\"sku\""), "incomplete element leaked: \(p0)")
        }

        let p1 = CompletedTokenJSON.snapshot(from: s1)
        #expect(p1 == "{\"lineItems\":[{\"sku\":\"A\",\"qty\":1}]}")

        let p2 = CompletedTokenJSON.snapshot(from: s2)
        #expect(p2 == "{\"lineItems\":[{\"sku\":\"A\",\"qty\":1},{\"sku\":\"B\",\"qty\":2}]}")

        let p3 = CompletedTokenJSON.snapshot(from: s3)
        #expect(p3 == "{\"lineItems\":[{\"sku\":\"A\",\"qty\":1},{\"sku\":\"B\",\"qty\":2}]}")
    }

    @Test("markdown fences and leading prose are tolerated")
    func fencesAndProse() {
        let raw = """
            Here is the JSON:
            ```json
            {"name":"Ada","age":36}
            ```
            """
        let snap = CompletedTokenJSON.snapshot(from: raw)
        #expect(snap == "{\"name\":\"Ada\",\"age\":36}")

        // Progressive fence open mid-stream.
        let partialFence = "```json\n{\"name\":\"Ada\""
        let snap2 = CompletedTokenJSON.snapshot(from: partialFence)
        #expect(snap2 == "{\"name\":\"Ada\"}")
    }
}

// MARK: - Stream integration

@Suite("Streaming partials")
struct StreamingPartialTests {
    @Test("fields appear progressively; every snapshot decodable; ends with final")
    func progressiveFields() async throws {
        let pieces = [
            "{\"name\":",
            "\"Ada\",\"age\":",
            "36,\"total\":",
            "10.5,\"note\":null}",
        ]
        let session = ExtractionSession.mock(MockLanguageModel(streamingPieces: pieces))
        var partials: [StreamPerson.Partial] = []
        var finalResult: ExtractionResult<StreamPerson>?

        for try await update in Extract.stream(
            from: "Ada 36 total 10.5",
            as: StreamPerson.self,
            using: session,
            options: ExtractionOptions(maxRetries: 0)
        ) {
            switch update {
            case .partial(let p):
                partials.append(p)
            case .final(let r):
                finalResult = r
            }
        }

        #expect(!partials.isEmpty)
        // Name appears before age before total (completed-token order).
        let firstWithName = partials.firstIndex(where: { $0.name != nil })
        let firstWithAge = partials.firstIndex(where: { $0.age != nil })
        let firstWithTotal = partials.firstIndex(where: { $0.total != nil })
        #expect(firstWithName != nil)
        #expect(firstWithAge != nil)
        #expect(firstWithTotal != nil)
        if let n = firstWithName, let a = firstWithAge, let t = firstWithTotal {
            #expect(n <= a)
            #expect(a <= t)
        }

        let result = try #require(finalResult)
        #expect(result.value.name == "Ada")
        #expect(result.value.age == 36)
        #expect(result.value.total == Decimal(string: "10.5")!)
        #expect(result.value.note == nil)
    }

    @Test("number split across stream pieces never surfaces half-value")
    func numberRegressionInStream() async throws {
        // Full JSON: {"name":"X","age":1,"total":473.00,"note":null}
        // Split so "473" and ".00" arrive separately.
        let pieces = [
            "{\"name\":\"X\",\"age\":1,\"total\":",
            "473",
            ".00",
            ",\"note\":null}",
        ]
        let session = ExtractionSession.mock(MockLanguageModel(streamingPieces: pieces))
        var totals: [Decimal?] = []

        for try await update in Extract.stream(
            from: "doc",
            as: StreamPerson.self,
            using: session,
            options: ExtractionOptions(maxRetries: 0)
        ) {
            switch update {
            case .partial(let p):
                totals.append(p.total)
            case .final(let r):
                #expect(r.value.total == Decimal(string: "473.00")!)
            }
        }

        // At least one partial before the number completed should have total == nil.
        #expect(totals.contains(where: { $0 == nil }))
        // Stronger: no partial should carry anything other than the full 473.00 once present.
        for t in totals {
            if let t {
                #expect(t == Decimal(string: "473.00")!)
            }
        }
    }

    @Test("string split mid-token never surfaces truncated")
    func stringRegressionInStream() async throws {
        let pieces = [
            "{\"name\":\"Ad",
            "a Lovelace\",\"age\":1,\"total\":1,\"note\":null}",
        ]
        let session = ExtractionSession.mock(MockLanguageModel(streamingPieces: pieces))
        var names: [String?] = []

        for try await update in Extract.stream(
            from: "doc",
            as: StreamPerson.self,
            using: session,
            options: ExtractionOptions(maxRetries: 0)
        ) {
            switch update {
            case .partial(let p):
                names.append(p.name)
                if let n = p.name {
                    #expect(n == "Ada Lovelace", "truncated name leaked: \(n)")
                }
            case .final(let r):
                #expect(r.value.name == "Ada Lovelace")
            }
        }
        #expect(names.contains(where: { $0 == nil }))
    }

    @Test("array grows element by element")
    func arrayGrowsInStream() async throws {
        let pieces = [
            "{\"vendor\":\"Acme\",\"total\":10,\"lineItems\":[",
            "{\"sku\":\"A\",\"qty\":1}",
            ",",
            "{\"sku\":\"B\",\"qty\":2}",
            "]}",
        ]
        let session = ExtractionSession.mock(MockLanguageModel(streamingPieces: pieces))
        var itemCounts: [Int] = []

        for try await update in Extract.stream(
            from: "doc",
            as: StreamInvoice.self,
            using: session,
            options: ExtractionOptions(maxRetries: 0)
        ) {
            switch update {
            case .partial(let p):
                itemCounts.append(p.lineItems?.count ?? 0)
                // Every surfaced element must be complete (sku + qty present via decode).
                if let items = p.lineItems {
                    for item in items {
                        #expect(item.sku != nil)
                        #expect(item.qty != nil)
                    }
                }
            case .final(let r):
                #expect(r.value.lineItems.count == 2)
                #expect(r.value.lineItems[0].sku == "A")
                #expect(r.value.lineItems[1].sku == "B")
            }
        }
        #expect(itemCounts.contains(1))
        #expect(itemCounts.contains(2) || itemCounts.last == 2)
    }

    @Test("markdown fences tolerated on stream path")
    func fencesOnStream() async throws {
        let pieces = [
            "Here you go:\n```json\n",
            "{\"name\":\"Bob\",\"age\":20,\"total\":\"3.14\",\"note\":null}\n```",
        ]
        let session = ExtractionSession.mock(MockLanguageModel(streamingPieces: pieces))
        var sawPartial = false
        var finalResult: ExtractionResult<StreamPerson>?

        for try await update in Extract.stream(
            from: "doc",
            as: StreamPerson.self,
            using: session,
            options: ExtractionOptions(maxRetries: 0)
        ) {
            switch update {
            case .partial:
                sawPartial = true
            case .final(let r):
                finalResult = r
            }
        }
        #expect(sawPartial)
        let result = try #require(finalResult)
        #expect(result.value.name == "Bob")
        #expect(result.value.total == Decimal(string: "3.14")!)
    }

    @Test("final equals detailed for same input")
    func finalMatchesDetailed() async throws {
        let json = """
            {"name":"Cy","age":2,"total":9.9,"note":"hi"}
            """
        // Same full response for both paths.
        let sessionA = ExtractionSession.mock(MockLanguageModel(responses: [json]))
        let sessionB = ExtractionSession.mock(MockLanguageModel(responses: [json]))

        let detailed: ExtractionResult<StreamPerson> = try await Extract.detailed(
            from: .text("doc"),
            using: sessionA,
            options: ExtractionOptions(maxRetries: 0)
        )

        var streamFinal: ExtractionResult<StreamPerson>?
        for try await update in Extract.stream(
            from: "doc",
            as: StreamPerson.self,
            using: sessionB,
            options: ExtractionOptions(maxRetries: 0)
        ) {
            if case .final(let r) = update {
                streamFinal = r
            }
        }
        let streamed = try #require(streamFinal)
        #expect(streamed.value.name == detailed.value.name)
        #expect(streamed.value.age == detailed.value.age)
        #expect(streamed.value.total == detailed.value.total)
        #expect(streamed.value.note == detailed.value.note)
        #expect(streamed.attempts == detailed.attempts)
        #expect(streamed.rawModelOutput == detailed.rawModelOutput)
        #expect(streamed.chunksUsed == detailed.chunksUsed)
    }

    @Test("chunked document yields final only")
    func chunkedFinalOnly() async throws {
        // Document longer than budget with fixed chunking.
        let doc = String(repeating: "line item alpha beta gamma delta ", count: 4)
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [
                "{\"vendor\":\"Acme\",\"total\":10,\"lineItems\":[{\"sku\":\"A\",\"qty\":1}]}",
                "{\"vendor\":\"Acme\",\"total\":10,\"lineItems\":[{\"sku\":\"B\",\"qty\":2}]}",
            ])
        )
        var partialCount = 0
        var finals: [ExtractionResult<StreamInvoice>] = []

        for try await update in Extract.stream(
            from: doc,
            as: StreamInvoice.self,
            using: session,
            options: ExtractionOptions(
                maxRetries: 0,
                chunkingStrategy: .fixed(characterBudget: 40)
            )
        ) {
            switch update {
            case .partial:
                partialCount += 1
            case .final(let r):
                finals.append(r)
            }
        }
        #expect(partialCount == 0)
        #expect(finals.count == 1)
        #expect(finals[0].chunksUsed > 1)
    }

    @Test("repair after bad first attempt still ends with correct final")
    func repairEndsWithFinal() async throws {
        let bad = "{\"label\":\"x\",\"amount\":-5}"
        let good = "{\"label\":\"x\",\"amount\":5}"
        // First attempt streams the bad JSON (partials may appear); repair is one-shot.
        let session = ExtractionSession.mock(
            MockLanguageModel(streamingResponses: [
                [bad],
                [good],
            ])
        )
        var finalResult: ExtractionResult<StreamPlain>?
        var partialCount = 0

        for try await update in Extract.stream(
            from: "amount 5",
            as: StreamPlain.self,
            using: session,
            options: ExtractionOptions(maxRetries: 2)
        ) {
            switch update {
            case .partial:
                partialCount += 1
            case .final(let r):
                finalResult = r
            }
        }

        let result = try #require(finalResult)
        #expect(result.value.amount == Decimal(5))
        #expect(result.attempts == 2)
        // First attempt still streams (bad JSON is complete and decodes; invariant fails after).
        #expect(partialCount >= 1)
    }
}
