import Foundation
import Testing

@testable import Extract

// MARK: - Types under test

/// Throws a non-`ExtractionError` / non-`InvariantValidationError` from invariants.
@Extractable
struct ExoticInvariantErrorType {
    let label: String
    let flag: Bool

    func validateInvariants() throws {
        if flag {
            throw ExoticInvariantError.kaboom(label: label)
        }
    }
}

enum ExoticInvariantError: Error, Equatable {
    case kaboom(label: String)
}

/// Nil-unwrap-style guard: would trap under force-unwrap, throws instead.
@Extractable
struct GuardStyleInvariants {
    let title: String
    let items: [String]
    let primaryIndex: Int

    func validateInvariants() throws {
        // Crash-adjacent if written as `items[primaryIndex]` / `items.first!` without checks.
        guard !items.isEmpty else {
            throw InvariantValidationError(
                path: "items",
                expected: "non-empty list",
                found: "[]"
            )
        }
        guard items.indices.contains(primaryIndex) else {
            throw InvariantValidationError(
                path: "primaryIndex",
                expected: "index in 0..<\(items.count)",
                found: "\(primaryIndex)"
            )
        }
        guard let primary = items[primaryIndex] as String? else {
            throw InvariantValidationError(
                path: "items[\(primaryIndex)]",
                expected: "a string",
                found: "missing"
            )
        }
        if primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw InvariantValidationError(
                path: "items[\(primaryIndex)]",
                expected: "non-blank primary item",
                found: "blank"
            )
        }
    }
}

/// Invariants that only run after a successful full-object decode (chunk-merge target).
@Extractable
struct MergeInvariantDoc {
    let name: String
    let total: Decimal
    let parts: [Decimal]

    func validateInvariants() throws {
        let sum = parts.reduce(Decimal.zero, +)
        if !total.isApproximatelyEqual(to: sum) {
            throw InvariantValidationError(
                path: "total",
                expected: "sum(parts) ≈ \(sum)",
                found: "\(total)"
            )
        }
        // Also exercise a non-InvariantValidationError on a secondary condition.
        if name == "THROW_EXOTIC" {
            throw ExoticInvariantError.kaboom(label: name)
        }
    }
}

// MARK: - Tests

@Suite("Invariant edge cases")
struct InvariantEdgeCaseTests {
    @Test("invariant that throws a non-ExtractionError surfaces as validationFailed")
    func exoticErrorSurfaces() async {
        let json = #"{"label":"x","flag":true}"#
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json, json]))
        do {
            let _: ExoticInvariantErrorType = try await Extract.from(
                "doc",
                using: session,
                options: ExtractionOptions(maxRetries: 0)
            )
            Issue.record("expected validationFailed wrapping exotic error")
        } catch let error as ExtractionError {
            guard case .validationFailed(_, let last, let raw) = error else {
                Issue.record("wrong ExtractionError \(error)")
                return
            }
            #expect(raw.contains("flag"))
            #expect(last is ExoticInvariantError)
            if let exotic = last as? ExoticInvariantError {
                #expect(exotic == .kaboom(label: "x"))
            }
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test("exotic invariant error is retried and can recover")
    func exoticErrorRetryThenSuccess() async throws {
        let bad = #"{"label":"x","flag":true}"#
        let good = #"{"label":"x","flag":false}"#
        let session = ExtractionSession.mock(MockLanguageModel(responses: [bad, good]))
        let result: ExtractionResult<ExoticInvariantErrorType> = try await Extract.detailed(
            from: .text("doc"),
            using: session,
            options: ExtractionOptions(maxRetries: 2)
        )
        #expect(result.value.flag == false)
        #expect(result.attempts == 2)
    }

    @Test("nil-unwrap-style invariant throws rather than traps on empty items")
    func guardStyleEmptyItems() async {
        let json = #"{"title":"t","items":[],"primaryIndex":0}"#
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
        do {
            let _: GuardStyleInvariants = try await Extract.from(
                "doc",
                using: session,
                options: ExtractionOptions(maxRetries: 0)
            )
            Issue.record("expected thrown error for empty items")
        } catch let error as ExtractionError {
            guard case .validationFailed(_, let last, _) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(last is InvariantValidationError)
            if let inv = last as? InvariantValidationError {
                #expect(inv.issues.contains { $0.path == "items" })
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("out-of-range primaryIndex throws, does not trap")
    func guardStyleOutOfRange() async {
        let json = #"{"title":"t","items":["a","b"],"primaryIndex":99}"#
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
        do {
            let _: GuardStyleInvariants = try await Extract.from(
                "doc",
                using: session,
                options: ExtractionOptions(maxRetries: 0)
            )
            Issue.record("expected thrown error for OOB index")
        } catch let error as ExtractionError {
            guard case .validationFailed(_, let last, _) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(last is InvariantValidationError)
            if let inv = last as? InvariantValidationError {
                #expect(inv.issues.contains { $0.path == "primaryIndex" })
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("guard-style invariants accept a valid primary")
    func guardStyleHappyPath() async throws {
        let json = #"{"title":"t","items":["alpha","beta"],"primaryIndex":1}"#
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
        let value: GuardStyleInvariants = try await Extract.from(
            "doc",
            using: session,
            options: ExtractionOptions(maxRetries: 0)
        )
        #expect(value.items[value.primaryIndex] == "beta")
    }

    @Test("chunk-merge path enforces sum invariant and can repair")
    func chunkMergeSumInvariant() async throws {
        let partial1 = #"{"name":"Doc","parts":[1.00,2.00]}"#
        let partial2 = #"{"total":9.99}"#
        let badMerge = #"{"name":"Doc","total":9.99,"parts":[1.00,2.00]}"#
        let goodMerge = #"{"name":"Doc","total":3.00,"parts":[1.00,2.00]}"#

        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [partial1, partial2, badMerge, goodMerge])
        )
        let options = ExtractionOptions(
            maxRetries: 2,
            chunkingStrategy: .fixed(characterBudget: 40)
        )
        let result: ExtractionResult<MergeInvariantDoc> = try await Extract.detailed(
            from: .text(String(repeating: "document ", count: 8)),
            using: session,
            options: options
        )
        #expect(result.value.total == Decimal(string: "3.00"))
        #expect(result.chunksUsed == 2)
        #expect(result.attempts == 4)
    }

    @Test("chunk-merge path surfaces exotic invariant errors")
    func chunkMergeExoticError() async {
        let partial1 = #"{"name":"THROW_EXOTIC","parts":[1]}"#
        let partial2 = #"{"total":1}"#
        let merge = #"{"name":"THROW_EXOTIC","total":1,"parts":[1]}"#

        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [partial1, partial2, merge, merge])
        )
        let options = ExtractionOptions(
            maxRetries: 0,
            chunkingStrategy: .fixed(characterBudget: 40)
        )
        do {
            let _: MergeInvariantDoc = try await Extract.from(
                String(repeating: "document ", count: 8),
                using: session,
                options: options
            )
            Issue.record("expected validationFailed from exotic merge invariant")
        } catch let error as ExtractionError {
            guard case .validationFailed(_, let last, _) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(last is ExoticInvariantError)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("chunk-merge exhausts retries when invariant stays broken")
    func chunkMergeExhaustsInvariant() async {
        let partial1 = #"{"name":"Doc","parts":[5]}"#
        let partial2 = #"{"total":1}"#
        let badMerge = #"{"name":"Doc","total":1,"parts":[5]}"#

        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [partial1, partial2, badMerge, badMerge, badMerge])
        )
        let options = ExtractionOptions(
            maxRetries: 1,
            chunkingStrategy: .fixed(characterBudget: 40)
        )
        do {
            let _: MergeInvariantDoc = try await Extract.from(
                String(repeating: "document ", count: 8),
                using: session,
                options: options
            )
            Issue.record("expected validationFailed")
        } catch let error as ExtractionError {
            guard case .validationFailed(let attempts, let last, let raw) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(last is InvariantValidationError)
            #expect(raw.contains("total") || raw.contains("1"))
            // two partials + (maxRetries+1) merge attempts = 2 + 2 = 4
            #expect(attempts == 4)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
