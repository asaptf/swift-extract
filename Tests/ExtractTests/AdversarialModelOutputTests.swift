import Foundation
import Testing

@testable import Extract

/// Corpus of responses a real model emits when it misbehaves, driven through the
/// real `Extract.from` / `detailed` loop with a mock session.
///
/// For every case the only acceptable outcomes are: a correctly decoded value, or
/// a thrown error. Never a trap, never a hang.
@Suite("Adversarial model outputs")
struct AdversarialModelOutputTests {
    private static let validPersonJSON = """
        {"name":"Ada","age":36,"balance":10.5,"birthday":"1815-12-10","active":true,"homepage":"https://example.com"}
        """

    // MARK: - Outcome (a) or (b) for a fixed corpus

    @Test("misbehaved model payloads complete with value or thrown error")
    func adversarialCorpusNeverTraps() async {
        let cases: [(name: String, response: String, expectSuccess: Bool?)] = [
            (
                "markdown fences",
                """
                Sure! Here you go:
                ```json
                \(Self.validPersonJSON)
                ```
                """,
                true
            ),
            (
                "chatty prose before JSON",
                """
                I've carefully read the document and extracted the fields as requested.
                The person appears to be Ada Lovelace based on historical context.
                \(Self.validPersonJSON)
                Hope this helps!
                """,
                true
            ),
            (
                "truncated mid-object",
                #"{"name":"Ada","age":36,"balance":10.5,"birthday":"1815-12-10","acti"#,
                false
            ),
            (
                // Foundation's JSON parser may accept or reject trailing commas across
                // OS versions — either outcome is fine; must not trap.
                "trailing comma",
                #"{"name":"Ada","age":36,"balance":10.5,"birthday":"1815-12-10","active":true,"homepage":null,}"#,
                nil
            ),
            (
                "duplicate keys (last-wins or reject — either is fine)",
                #"{"name":"Ada","name":"Bob","age":36,"balance":10.5,"birthday":"1815-12-10","active":true,"homepage":null}"#,
                nil  // JSONSerialization/Decoder behaviour; must not trap
            ),
            (
                "wrong scalar types",
                #"{"name":1,"age":"thirty-six","balance":true,"birthday":false,"active":"maybe","homepage":[]}"#,
                false
            ),
            (
                "null for required field",
                #"{"name":null,"age":36,"balance":10.5,"birthday":"1815-12-10","active":true,"homepage":null}"#,
                false
            ),
            (
                "empty array where object expected at root",
                "[]",
                false
            ),
            (
                "array for scalar field",
                #"{"name":["Ada"],"age":36,"balance":10.5,"birthday":"1815-12-10","active":true,"homepage":null}"#,
                false
            ),
            (
                "deeply nested irrelevant payload",
                String(repeating: #"{"a":"#, count: 40) + "1" + String(repeating: "}", count: 40),
                false
            ),
            (
                "scientific notation numbers",
                #"{"name":"Sci","age":1,"balance":1.5e2,"birthday":"2020-01-01","active":true,"homepage":null}"#,
                true
            ),
            (
                "integer overflow-scale numbers",
                #"{"name":"Big","age":1,"balance":1e309,"birthday":"2020-01-01","active":true,"homepage":null}"#,
                nil  // may decode as inf/error; must not trap
            ),
            (
                "unicode and RTL strings",
                #"{"name":"عَرَبِيّ 😀 café","age":1,"balance":"١٢ not digits","birthday":"2020-01-01","active":true,"homepage":null}"#,
                false  // balance string has no ASCII digits after strip → decode fail
            ),
            (
                "unicode name succeeds when other fields valid",
                #"{"name":"עברית العربية 日本語","age":2,"balance":3.25,"birthday":"2020-01-01","active":false,"homepage":null}"#,
                true
            ),
            (
                "empty object",
                "{}",
                false
            ),
            (
                "plain text no JSON",
                "I cannot extract structured data from this document.",
                false
            ),
            (
                "JSON null root",
                "null",
                false
            ),
            (
                "boolean root",
                "true",
                false
            ),
            (
                "unclosed fence",
                "```json\n{\"name\":\"X\"",
                false
            ),
        ]

        for testCase in cases {
            let session = ExtractionSession.mock(
                MockLanguageModel(responses: [testCase.response, testCase.response, testCase.response])
            )
            do {
                let person: SimplePerson = try await Extract.from(
                    "document body for \(testCase.name)",
                    using: session,
                    options: ExtractionOptions(maxRetries: 0)
                )
                if testCase.expectSuccess == false {
                    Issue.record(
                        "expected failure for \(testCase.name), got name=\(person.name)"
                    )
                }
                // Success path: value is a real SimplePerson (type system already enforces).
                #expect(!person.name.isEmpty || person.name.isEmpty)  // reachable without trap
            } catch {
                if testCase.expectSuccess == true {
                    Issue.record("expected success for \(testCase.name), got \(error)")
                }
                // Failure path is outcome (b) — any Error is acceptable.
            }
        }
    }

    @Test("multi-megabyte model blob completes in reasonable time")
    func multiMegabyteBlob() async throws {
        // ~1 MB of noise with a valid object after the preamble. Exercises the
        // fence stripper on a large buffer without making the suite glacially slow.
        let noise = String(repeating: "x", count: 1_000_000)
        let blob = """
            preamble \(noise)
            \(Self.validPersonJSON)
            trailing \(noise)
            """

        let session = ExtractionSession.mock(MockLanguageModel(responses: [blob]))
        let clock = ContinuousClock()
        let start = clock.now
        let person: SimplePerson = try await Extract.from(
            "doc",
            using: session,
            options: ExtractionOptions(maxRetries: 0)
        )
        let elapsed = start.duration(to: clock.now)
        #expect(person.name == "Ada")
        // Hang detector only — not a correctness oracle. 30s is generous for ~5MB scan.
        #expect(elapsed < .seconds(30), "multi-megabyte extract took \(elapsed)")
    }

    @Test("multi-megabyte invalid blob fails without hanging")
    func multiMegabyteInvalid() async {
        let blob = String(repeating: "{", count: 500_000) + String(repeating: "a", count: 500_000)
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [blob, blob])
        )
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let _: SimplePerson = try await Extract.from(
                "doc",
                using: session,
                options: ExtractionOptions(maxRetries: 0)
            )
            Issue.record("expected failure for invalid megabyte blob")
        } catch {
            // outcome (b)
        }
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed < .seconds(30), "invalid megabyte blob took \(elapsed)")
    }

    @Test("detailed surfaces raw output on validation failure")
    func detailedRawOnFailure() async {
        let bad = #"{"name":1}"#
        let session = ExtractionSession.mock(MockLanguageModel(responses: [bad, bad]))
        do {
            let _: SimplePerson = try await Extract.from(
                "doc",
                using: session,
                options: ExtractionOptions(maxRetries: 0)
            )
            Issue.record("expected validationFailed")
        } catch let error as ExtractionError {
            guard case .validationFailed(_, _, let raw) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(raw.contains("name"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
