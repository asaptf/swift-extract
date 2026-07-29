import Foundation
import Testing

@testable import Extract

/// Concurrency stress for the extraction loop and mock session.
///
/// The library is annotated `Sendable` end-to-end; these tests check that the
/// annotations are honest under real concurrent use (including a shared session).
@Suite("Concurrent extraction")
struct ConcurrencyExtractionTests {
    private static let validJSON = """
        {"name":"Concurrent","age":7,"balance":3.25,"birthday":"2020-01-01","active":true,"homepage":null}
        """

    @Test("many concurrent extractions on a shared session all succeed")
    func sharedSessionTaskGroup() async throws {
        let session = ExtractionSession.mock(
            MockLanguageModel { _, _, _ in
                // Independent of call index so concurrent callers each get a valid body.
                Self.validJSON
            }
        )

        let count = 64
        let names = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<count {
                group.addTask {
                    let person: SimplePerson = try await Extract.from(
                        "document \(index)",
                        using: session,
                        options: ExtractionOptions(maxRetries: 0)
                    )
                    #expect(person.name == "Concurrent")
                    #expect(person.age == 7)
                    #expect(person.balance == Decimal(string: "3.25"))
                    return person.name
                }
            }
            var collected: [String] = []
            for try await name in group {
                collected.append(name)
            }
            return collected
        }

        #expect(names.count == count)
        #expect(names.allSatisfy { $0 == "Concurrent" })
    }

    @Test("concurrent extractions with distinct sessions all succeed")
    func distinctSessionsTaskGroup() async throws {
        let count = 32
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<count {
                group.addTask {
                    let json = """
                        {"name":"P\(index)","age":\(index),"balance":1,"birthday":"2020-01-01","active":true,"homepage":null}
                        """
                    let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
                    let person: SimplePerson = try await Extract.from(
                        "doc \(index)",
                        using: session,
                        options: ExtractionOptions(maxRetries: 0)
                    )
                    #expect(person.age == index)
                    return person.age
                }
            }
            var ages: [Int] = []
            for try await age in group {
                ages.append(age)
            }
            return ages
        }
        #expect(Set(results) == Set(0..<count))
    }

    @Test("concurrent mix of success and validation failure does not corrupt shared session")
    func mixedSuccessAndFailure() async throws {
        let session = ExtractionSession.mock(
            MockLanguageModel { _, user, _ in
                // Alternate by document content so outcomes are deterministic per task.
                if user.contains("GOOD_DOC") {
                    return Self.validJSON
                }
                return #"{"name":1}"#
            }
        )

        try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<40 {
                let good = index.isMultiple(of: 2)
                group.addTask {
                    do {
                        let person: SimplePerson = try await Extract.from(
                            good ? "GOOD_DOC \(index)" : "BAD_DOC \(index)",
                            using: session,
                            options: ExtractionOptions(maxRetries: 0)
                        )
                        #expect(good, "bad doc unexpectedly decoded \(person.name)")
                        return true
                    } catch {
                        #expect(!good, "good doc unexpectedly failed \(error)")
                        return false
                    }
                }
            }
            var successes = 0
            var failures = 0
            for try await ok in group {
                if ok { successes += 1 } else { failures += 1 }
            }
            #expect(successes == 20)
            #expect(failures == 20)
        }
    }

    @Test("concurrent detailed extractions preserve per-call attempts")
    func concurrentDetailedAttempts() async throws {
        let bad = #"{"name":1}"#
        let good = Self.validJSON

        // Per-task sessions avoid cross-talk on the shared call counter affecting
        // a single logical extraction's repair loop.
        try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<24 {
                group.addTask {
                    let local = ExtractionSession.mock(
                        MockLanguageModel(responses: [bad, good])
                    )
                    let result: ExtractionResult<SimplePerson> = try await Extract.detailed(
                        from: .text("doc \(i)"),
                        using: local,
                        options: ExtractionOptions(maxRetries: 2)
                    )
                    #expect(result.value.name == "Concurrent")
                    #expect(result.attempts == 2)
                    return result.attempts
                }
            }
            for try await attempts in group {
                #expect(attempts == 2)
            }
        }
    }
}
