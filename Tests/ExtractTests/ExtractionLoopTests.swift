import Extract
import Foundation
import Testing

@Extractable
struct SimplePerson {
    let name: String
    let age: Int
    let balance: Decimal
    let birthday: Date
    let active: Bool
    let homepage: URL?
}

@Suite("Extraction loop")
struct ExtractionLoopTests {
    @Test("happy path")
    func happyPath() async throws {
        let json = """
            {"name":"Ada","age":36,"balance":10.5,"birthday":"1815-12-10","active":true,"homepage":"https://example.com"}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
        let person: SimplePerson = try await Extract.from(
            "Ada Lovelace, age 36",
            using: session
        )
        #expect(person.name == "Ada")
        #expect(person.age == 36)
        #expect(person.balance == Decimal(string: "10.5")!)
        #expect(person.active == true)
        #expect(person.homepage?.absoluteString == "https://example.com")
    }

    @Test("strips markdown fences")
    func fenceStrip() async throws {
        let fenced = """
            Here is the JSON:
            ```json
            {"name":"Bob","age":20,"balance":"3.14","birthday":"2000-01-02","active":false,"homepage":null}
            ```
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [fenced]))
        let person: SimplePerson = try await Extract.from("doc", using: session)
        #expect(person.name == "Bob")
        #expect(person.balance == Decimal(string: "3.14")!)
        #expect(person.homepage == nil)
    }

    @Test("extracts JSON around bracketed prose")
    func bracketedProse() async throws {
        let response = """
            Notes [not JSON].
            {"name":"Bracket } [ text","age":20,"balance":"12,50","birthday":"2000-01-02","active":false,"homepage":null}
            Sources [1]
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [response]))
        let person: SimplePerson = try await Extract.from("doc", using: session)
        #expect(person.name == "Bracket } [ text")
        #expect(person.balance == Decimal(string: "12.50"))
    }

    @Test("lenient date and decimal decoding")
    func lenientDecode() async throws {
        let json = """
            {"name":"Cy","age":1,"balance":"$1,234.50","birthday":"March 5, 2020","active":"yes","homepage":"https://x.test"}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
        let person: SimplePerson = try await Extract.from("doc", using: session)
        #expect(person.balance == Decimal(string: "1234.50")!)
        let comps = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: person.birthday)
        #expect(comps.year == 2020)
        #expect(comps.month == 3)
        #expect(comps.day == 5)
        #expect(person.active == true)
    }

    @Test("locale controls ambiguous dates and decimal separators")
    func localeAwareDecode() async throws {
        let json = """
            {"name":"Eva","age":1,"balance":"EUR 1.234,56","birthday":"03/04/2020","active":true,"homepage":null}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
        let person: SimplePerson = try await Extract.from(
            "doc",
            using: session,
            options: ExtractionOptions(locale: Locale(identifier: "es_ES"))
        )
        #expect(person.balance == Decimal(string: "1234.56"))
        let components = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: person.birthday)
        #expect(components.year == 2020)
        #expect(components.month == 4)
        #expect(components.day == 3)
    }

    @Test("generation errors are not retried as validation failures")
    func generationErrorPropagation() async throws {
        let attempts = AttemptCounter()
        let session = ExtractionSession.mock(
            MockLanguageModel { _, _, _ in
                await attempts.increment()
                throw GenerationProbeError.failed
            }
        )

        do {
            let _: SimplePerson = try await Extract.from(
                "doc",
                using: session,
                options: ExtractionOptions(maxRetries: 2)
            )
            Issue.record("Expected generation failure")
        } catch GenerationProbeError.failed {
            #expect(await attempts.value == 1)
        } catch {
            Issue.record("Wrong error \(error)")
        }
    }

    @Test("cancellation propagates immediately")
    func cancellationPropagation() async throws {
        let attempts = AttemptCounter()
        let session = ExtractionSession.mock(
            MockLanguageModel { _, _, _ in
                await attempts.increment()
                throw CancellationError()
            }
        )

        do {
            let _: SimplePerson = try await Extract.from(
                "doc",
                using: session,
                options: ExtractionOptions(maxRetries: 2)
            )
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(await attempts.value == 1)
        } catch {
            Issue.record("Wrong error \(error)")
        }
    }

    @Test("initial prompt has one return instruction")
    func initialPromptInstruction() async throws {
        let json = """
            {"name":"Prompt","age":1,"balance":0,"birthday":"2020-01-01","active":true,"homepage":null}
            """
        let session = ExtractionSession.mock(
            MockLanguageModel { _, user, _ in
                #expect(user.hasSuffix("Return the JSON object now."))
                #expect(!user.contains("Return the corrected JSON object now."))
                return json
            }
        )
        let person: SimplePerson = try await Extract.from("doc", using: session)
        #expect(person.name == "Prompt")
    }

    @Test("repair retry path")
    func repairRetry() async throws {
        let bad = """
            {"name":"Dana","age":"twenty","balance":1,"birthday":"2020-01-01","active":true}
            """
        let good = """
            {"name":"Dana","age":20,"balance":1,"birthday":"2020-01-01","active":true,"homepage":null}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [bad, good]))
        let result: ExtractionResult<SimplePerson> = try await Extract.detailed(
            from: .text("Dana is twenty"),
            using: session,
            options: ExtractionOptions(maxRetries: 2)
        )
        #expect(result.value.name == "Dana")
        #expect(result.value.age == 20)
        #expect(result.attempts == 2)
    }

    @Test("validationFailed after exhausting retries")
    func exhaustRetries() async throws {
        let bad = """
            {"name":1}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [bad, bad, bad]))
        do {
            let _: SimplePerson = try await Extract.from(
                "x",
                using: session,
                options: ExtractionOptions(maxRetries: 1)
            )
            Issue.record("Expected validationFailed")
        } catch let error as ExtractionError {
            guard case .validationFailed(let attempts, _, let raw) = error else {
                Issue.record("Wrong error \(error)")
                return
            }
            #expect(attempts == 2)
            #expect(raw.contains("name"))
        }
    }

    @Test("empty document")
    func emptyDocument() async throws {
        let session = ExtractionSession.mock(MockLanguageModel(responses: ["{}"]))
        do {
            let _: SimplePerson = try await Extract.from("   \n  ", using: session)
            Issue.record("Expected emptyDocument")
        } catch let error as ExtractionError {
            guard case .emptyDocument = error else {
                Issue.record("Wrong error \(error)")
                return
            }
        }
    }

    @Test("chunk-merge path")
    func chunkMerge() async throws {
        // First two calls are per-chunk; third is merge.
        let partial1 = """
            {"name":"Eve","age":30,"balance":1,"birthday":"1990-01-01","active":true,"homepage":null}
            """
        let partial2 = """
            {"name":"Eve","age":30,"balance":99,"birthday":"1990-01-01","active":true,"homepage":"https://eve.test"}
            """
        let merged = """
            {"name":"Eve","age":30,"balance":99,"birthday":"1990-01-01","active":true,"homepage":"https://eve.test"}
            """
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [partial1, partial2, merged])
        )
        // Build a document large enough to force chunking with a tiny budget.
        let pageA = String(repeating: "Section A about Eve. ", count: 20)
        let pageB = String(repeating: "Section B balance info. ", count: 20)
        let text = pageA + "\n\n" + pageB
        let options = ExtractionOptions(
            maxRetries: 0,
            chunkingStrategy: .fixed(characterBudget: 80)
        )
        let result: ExtractionResult<SimplePerson> = try await Extract.detailed(
            from: .text(text),
            using: session,
            options: options
        )
        #expect(result.value.name == "Eve")
        #expect(result.value.balance == Decimal(99))
        #expect(result.value.homepage?.host == "eve.test")
        #expect(result.chunksUsed >= 2)
    }

    @Test("chunks may contain incomplete objects")
    func chunkMergeAcceptsPartials() async throws {
        let partial1 = """
            {"name":"Eve"}
            """
        let partial2 = """
            {"age":30,"balance":99,"birthday":"1990-01-01","active":true,"homepage":"https://eve.test"}
            """
        let merged = """
            {"name":"Eve","age":30,"balance":99,"birthday":"1990-01-01","active":true,"homepage":"https://eve.test"}
            """
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [partial1, partial2, merged])
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
        #expect(result.value.balance == Decimal(99))
        #expect(result.chunksUsed == 2)
        #expect(result.attempts == 3)
    }

    @Test("trims strings")
    func trimStrings() async throws {
        let json = """
            {"name":"  Frank  ","age":2,"balance":0,"birthday":"2020-01-01","active":false,"homepage":null}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
        let person: SimplePerson = try await Extract.from("doc", using: session)
        #expect(person.name == "Frank")
    }
}

private enum GenerationProbeError: Error {
    case failed
}

private actor AttemptCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
