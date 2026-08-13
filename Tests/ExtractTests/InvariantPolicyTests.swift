import Foundation
import Testing

@testable import Extract

/// Throws `InvariantValidationError` with an empty issue list (legal, not useful).
@Extractable
struct EmptyIssueInvariant {
    let label: String
    let flag: Bool

    func validateInvariants() throws {
        if flag {
            throw InvariantValidationError(issues: [])
        }
    }
}

@Suite("Invariant policy")
struct InvariantPolicyTests {
    private static let correctJSON = """
        {"merchant":"Cafe","total":13.50,"tax":1.00,"items":[{"name":"Tea","price":5.00},{"name":"Cake","price":7.50}]}
        """

    private static let wrongTotalJSON = """
        {"merchant":"Cafe","total":99.99,"tax":1.00,"items":[{"name":"Tea","price":5.00},{"name":"Cake","price":7.50}]}
        """

    private static let undecodableJSON = #"{"merchant":"Cafe""#

    fileprivate static let document = "Tea 5.00 Cake 7.50 tax 1.00 total 13.50"

    // MARK: - Default path unchanged

    @Test("default options use strict policy")
    func defaultIsStrict() {
        #expect(ExtractionOptions().invariantPolicy == .strict)
        #expect(
            ExtractionOptions(maxRetries: 1, locale: Locale(identifier: "en_US")).invariantPolicy
                == .strict
        )
    }

    @Test("strict and unspecified options throw the same error after the same attempts")
    func defaultMatchesExplicitStrict() async {
        let responses = [Self.wrongTotalJSON, Self.wrongTotalJSON, Self.wrongTotalJSON]
        let implicitError = await captureValidationFailed(
            responses: responses,
            options: ExtractionOptions(maxRetries: 2)
        )
        let explicitError = await captureValidationFailed(
            responses: responses,
            options: ExtractionOptions(maxRetries: 2, invariantPolicy: .strict)
        )
        guard let implicitError, let explicitError else {
            Issue.record("expected both paths to throw validationFailed")
            return
        }
        #expect(implicitError.attempts == 3)
        #expect(explicitError.attempts == implicitError.attempts)
        #expect(explicitError.raw == implicitError.raw)
        #expect(explicitError.raw.contains("99.99"))
        #expect(implicitError.last is InvariantValidationError)
        #expect(explicitError.last is InvariantValidationError)
        if let a = implicitError.last as? InvariantValidationError,
            let b = explicitError.last as? InvariantValidationError
        {
            #expect(a == b)
            #expect(a.issues[0].path == "total")
            #expect(a.issues[0].found.contains("99.99"))
        }
    }

    @Test("successful strict extract has empty violations and the decoded value")
    func strictSuccessEmptyViolations() async throws {
        let session = ExtractionSession.mock(MockLanguageModel(responses: [Self.correctJSON]))
        let result: ExtractionResult<InvariantReceipt> = try await Extract.detailed(
            from: .text(Self.document),
            using: session,
            options: ExtractionOptions(maxRetries: 0)
        )
        #expect(result.value.total == Decimal(string: "13.50")!)
        #expect(result.invariantViolations.isEmpty)
        #expect(result.invariantValidationError == nil)
        #expect(result.attempts == 1)
    }

    // MARK: - Report policy

    @Test("reportViolations returns the value with the expected issues listed")
    func reportReturnsValueWithViolations() async throws {
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [
                Self.wrongTotalJSON,
                Self.wrongTotalJSON,
                Self.wrongTotalJSON,
            ])
        )
        let result: ExtractionResult<InvariantReceipt> = try await Extract.detailed(
            from: .text(Self.document),
            using: session,
            options: ExtractionOptions(maxRetries: 2, invariantPolicy: .reportViolations)
        )
        #expect(result.value.merchant == "Cafe")
        #expect(result.value.total == Decimal(string: "99.99")!)
        #expect(result.attempts == 3)
        #expect(result.rawModelOutput.contains("99.99"))
        #expect(result.invariantViolations.count == 1)
        #expect(result.invariantViolations[0].path == "total")
        #expect(result.invariantViolations[0].found.contains("99.99"))
        #expect(result.invariantValidationError?.issues == result.invariantViolations)
    }

    @Test("reportViolations uses the same attempt count as the strict throw")
    func reportAttemptCountMatchesStrict() async throws {
        let responses = [Self.wrongTotalJSON, Self.wrongTotalJSON]
        let thrown = await captureValidationFailed(
            responses: responses,
            options: ExtractionOptions(maxRetries: 1, invariantPolicy: .strict)
        )
        let session = ExtractionSession.mock(MockLanguageModel(responses: responses))
        let result: ExtractionResult<InvariantReceipt> = try await Extract.detailed(
            from: .text(Self.document),
            using: session,
            options: ExtractionOptions(maxRetries: 1, invariantPolicy: .reportViolations)
        )
        #expect(thrown?.attempts == 2)
        #expect(result.attempts == 2)
        #expect(!result.invariantViolations.isEmpty)
    }

    @Test("from still throws under reportViolations")
    func fromAlwaysThrowsOnInvariantFailure() async {
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [Self.wrongTotalJSON, Self.wrongTotalJSON])
        )
        do {
            let _: InvariantReceipt = try await Extract.from(
                Self.document,
                using: session,
                options: ExtractionOptions(maxRetries: 0, invariantPolicy: .reportViolations)
            )
            Issue.record("from must throw when invariants fail")
        } catch let error as ExtractionError {
            guard case .validationFailed(let attempts, let last, let raw) = error else {
                Issue.record("Wrong error \(error)")
                return
            }
            #expect(attempts == 1)
            #expect(raw.contains("99.99"))
            #expect(last is InvariantValidationError)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("empty-issue InvariantValidationError still throws under reportViolations")
    func emptyIssueListDoesNotLookLikeSuccess() async {
        let json = #"{"label":"x","flag":true}"#
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json, json]))
        do {
            let _: ExtractionResult<EmptyIssueInvariant> = try await Extract.detailed(
                from: .text("doc"),
                using: session,
                options: ExtractionOptions(maxRetries: 0, invariantPolicy: .reportViolations)
            )
            Issue.record("empty-issue invariant must not look like success")
        } catch let error as ExtractionError {
            guard case .validationFailed(_, let last, _) = error else {
                Issue.record("Wrong error \(error)")
                return
            }
            #expect(last is InvariantValidationError)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("reportViolations still throws when nothing decoded")
    func reportStillThrowsOnDecodeFailure() async {
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [Self.undecodableJSON, Self.undecodableJSON])
        )
        do {
            let _: ExtractionResult<InvariantReceipt> = try await Extract.detailed(
                from: .text(Self.document),
                using: session,
                options: ExtractionOptions(maxRetries: 0, invariantPolicy: .reportViolations)
            )
            Issue.record("expected validationFailed when decode never succeeded")
        } catch let error as ExtractionError {
            guard case .validationFailed(let attempts, let last, _) = error else {
                Issue.record("Wrong error \(error)")
                return
            }
            #expect(attempts == 1)
            #expect(!(last is InvariantValidationError))
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("reportViolations returns the last decoded value if a later attempt fails to decode")
    func reportKeepsLastDecodedWhenLaterAttemptFails() async throws {
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [Self.wrongTotalJSON, Self.undecodableJSON])
        )
        let result: ExtractionResult<InvariantReceipt> = try await Extract.detailed(
            from: .text(Self.document),
            using: session,
            options: ExtractionOptions(maxRetries: 1, invariantPolicy: .reportViolations)
        )
        #expect(result.value.total == Decimal(string: "99.99")!)
        #expect(result.attempts == 2)
        #expect(result.rawModelOutput.contains("99.99"))
        #expect(result.invariantViolations[0].path == "total")
    }

    @Test("reportViolations yields empty violations when a retry repairs the invariant")
    func reportRepairStillSucceedsCleanly() async throws {
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [Self.wrongTotalJSON, Self.correctJSON])
        )
        let result: ExtractionResult<InvariantReceipt> = try await Extract.detailed(
            from: .text(Self.document),
            using: session,
            options: ExtractionOptions(maxRetries: 2, invariantPolicy: .reportViolations)
        )
        #expect(result.value.total == Decimal(string: "13.50")!)
        #expect(result.attempts == 2)
        #expect(result.invariantViolations.isEmpty)
    }

    @Test("reportViolations surfaces remaining issues on the chunk-merge path")
    func reportOnChunkMerge() async throws {
        let partial1 = """
            {"merchant":"Cafe","total":99.99,"tax":1.00,"items":[{"name":"Tea","price":5.00}]}
            """
        let partial2 = """
            {"merchant":"Cafe","items":[{"name":"Cake","price":7.50}]}
            """
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [partial1, partial2, Self.wrongTotalJSON])
        )
        let result: ExtractionResult<InvariantReceipt> = try await Extract.detailed(
            from: .text(String(repeating: "document ", count: 8)),
            using: session,
            options: ExtractionOptions(
                maxRetries: 0,
                chunkingStrategy: .fixed(characterBudget: 40),
                invariantPolicy: .reportViolations
            )
        )
        #expect(result.chunksUsed == 2)
        #expect(result.value.total == Decimal(string: "99.99")!)
        #expect(result.invariantViolations[0].path == "total")
    }

    // MARK: - Type with no invariants

    @Test("type with no invariants is identical under both policies")
    func noInvariantsIdenticalUnderBothPolicies() async throws {
        let json = """
            {"label":"ok","total":99.99}
            """
        let strict: ExtractionResult<PlainTotal> = try await Extract.detailed(
            from: .text("anything"),
            using: ExtractionSession.mock(MockLanguageModel(responses: [json])),
            options: ExtractionOptions(maxRetries: 0, invariantPolicy: .strict)
        )
        let report: ExtractionResult<PlainTotal> = try await Extract.detailed(
            from: .text("anything"),
            using: ExtractionSession.mock(MockLanguageModel(responses: [json])),
            options: ExtractionOptions(maxRetries: 0, invariantPolicy: .reportViolations)
        )
        #expect(strict.value.label == report.value.label)
        #expect(strict.value.total == report.value.total)
        #expect(strict.attempts == report.attempts)
        #expect(strict.invariantViolations.isEmpty)
        #expect(report.invariantViolations.isEmpty)
        #expect(strict.rawModelOutput == report.rawModelOutput)
    }

    // MARK: - Stream

    @Test("stream .final under reportViolations carries the value and the issues")
    func streamFinalReportsViolations() async throws {
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [Self.wrongTotalJSON, Self.wrongTotalJSON])
        )
        var finals: [ExtractionResult<InvariantReceipt>] = []
        for try await update in Extract.stream(
            from: Self.document,
            as: InvariantReceipt.self,
            using: session,
            options: ExtractionOptions(maxRetries: 0, invariantPolicy: .reportViolations)
        ) {
            if case .final(let result) = update {
                finals.append(result)
            }
        }
        #expect(finals.count == 1)
        let result = try #require(finals.first)
        #expect(result.value.total == Decimal(string: "99.99")!)
        #expect(result.attempts == 1)
        #expect(result.invariantViolations[0].path == "total")
    }

    @Test("stream still throws under strict when invariants fail")
    func streamStrictStillThrows() async {
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [Self.wrongTotalJSON, Self.wrongTotalJSON])
        )
        do {
            for try await _ in Extract.stream(
                from: Self.document,
                as: InvariantReceipt.self,
                using: session,
                options: ExtractionOptions(maxRetries: 0, invariantPolicy: .strict)
            ) {}
            Issue.record("expected stream to throw under strict")
        } catch let error as ExtractionError {
            guard case .validationFailed(let attempts, let last, _) = error else {
                Issue.record("Wrong error \(error)")
                return
            }
            #expect(attempts == 1)
            #expect(last is InvariantValidationError)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("stream .final is clean when a retry repairs the invariant")
    func streamRepairStillFinalWithoutViolations() async throws {
        let session = ExtractionSession.mock(
            MockLanguageModel(streamingResponses: [
                [Self.wrongTotalJSON],
                [Self.correctJSON],
            ])
        )
        var finalResult: ExtractionResult<InvariantReceipt>?
        for try await update in Extract.stream(
            from: Self.document,
            as: InvariantReceipt.self,
            using: session,
            options: ExtractionOptions(maxRetries: 2, invariantPolicy: .reportViolations)
        ) {
            if case .final(let result) = update {
                finalResult = result
            }
        }
        let result = try #require(finalResult)
        #expect(result.value.total == Decimal(string: "13.50")!)
        #expect(result.attempts == 2)
        #expect(result.invariantViolations.isEmpty)
    }
}

// MARK: - Helpers

private struct CapturedValidationFailed: Sendable {
    var attempts: Int
    var last: Error
    var raw: String
}

private func captureValidationFailed(
    responses: [String],
    options: ExtractionOptions
) async -> CapturedValidationFailed? {
    let session = ExtractionSession.mock(MockLanguageModel(responses: responses))
    do {
        let _: ExtractionResult<InvariantReceipt> = try await Extract.detailed(
            from: .text(InvariantPolicyTests.document),
            using: session,
            options: options
        )
        Issue.record("expected validationFailed")
        return nil
    } catch let error as ExtractionError {
        guard case .validationFailed(let attempts, let last, let raw) = error else {
            Issue.record("Wrong error \(error)")
            return nil
        }
        return CapturedValidationFailed(attempts: attempts, last: last, raw: raw)
    } catch {
        Issue.record("Unexpected error \(error)")
        return nil
    }
}
