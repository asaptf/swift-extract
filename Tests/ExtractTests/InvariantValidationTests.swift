import Extract
import Foundation
import Testing

// MARK: - Types under test

/// No custom invariants — exercises the default no-op path.
@Extractable
struct PlainTotal {
    let label: String
    let total: Decimal
}

/// Receipt-shaped type with items + tax ≈ total.
@Extractable
struct InvariantReceipt {
    let merchant: String
    let total: Decimal
    let tax: Decimal
    let items: [Line]

    @Extractable
    struct Line {
        let name: String
        let price: Decimal
    }

    func validateInvariants() throws {
        let itemsSum = items.reduce(Decimal.zero) { $0 + $1.price }
        let expectedTotal = itemsSum + tax
        // Explicit tolerance: receipts round; never use bare == on money.
        if !Extract.isApproximatelyEqual(
            total,
            to: expectedTotal,
            tolerance: Extract.defaultMoneyTolerance
        ) {
            throw InvariantValidationError(
                path: "total",
                expected:
                    "items sum + tax ≈ \(expectedTotal) (tolerance \(Extract.defaultMoneyTolerance))",
                found: "\(total)"
            )
        }
    }
}

// MARK: - Tolerance helper (unit)

@Suite("Money tolerance helper")
struct MoneyToleranceTests {
    @Test("accepts legitimately rounded totals")
    func acceptsRounding() {
        let printed = Decimal(string: "12.50")!
        let summed = Decimal(string: "12.499")!
        #expect(
            Extract.isApproximatelyEqual(
                printed,
                to: summed,
                tolerance: Extract.defaultMoneyTolerance
            )
        )
        #expect(Extract.isApproximatelyEqual(printed, to: Decimal(string: "12.50")!))
        #expect(Extract.isApproximatelyEqual(printed, to: Decimal(string: "12.51")!))
    }

    @Test("rejects a genuinely wrong total")
    func rejectsWrong() {
        let printed = Decimal(string: "12.50")!
        let wrong = Decimal(string: "99.99")!
        #expect(
            !Extract.isApproximatelyEqual(
                printed,
                to: wrong,
                tolerance: Extract.defaultMoneyTolerance
            )
        )
        #expect(!Extract.isApproximatelyEqual(printed, to: Decimal(string: "12.52")!))
    }

    @Test("caller-chosen tolerance is honored")
    func customTolerance() {
        let a = Decimal(string: "10.00")!
        let b = Decimal(string: "10.05")!
        #expect(
            !Extract.isApproximatelyEqual(a, to: b, tolerance: Extract.defaultMoneyTolerance)
        )
        #expect(Extract.isApproximatelyEqual(a, to: b, tolerance: Decimal(string: "0.10")!))
    }
}

// MARK: - Repair-loop integration

@Suite("Cross-field invariants")
struct InvariantValidationTests {
    private static let correctJSON = """
        {"merchant":"Cafe","total":13.50,"tax":1.00,"items":[{"name":"Tea","price":5.00},{"name":"Cake","price":7.50}]}
        """

    /// Headline case: well-typed JSON with a confidently wrong total that decodes fine
    /// but violates items + tax == total.
    private static let wrongTotalJSON = """
        {"merchant":"Cafe","total":99.99,"tax":1.00,"items":[{"name":"Tea","price":5.00},{"name":"Cake","price":7.50}]}
        """

    @Test("type with no invariants behaves as before (regression)")
    func noInvariantsRegression() async throws {
        let json = """
            {"label":"ok","total":99.99}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
        let result: ExtractionResult<PlainTotal> = try await Extract.detailed(
            from: .text("anything"),
            using: session,
            options: ExtractionOptions(maxRetries: 0)
        )
        #expect(result.value.label == "ok")
        #expect(result.value.total == Decimal(string: "99.99")!)
        #expect(result.attempts == 1)
    }

    @Test("confidently-wrong total is caught even though it decodes")
    func headlineWrongTotalCaught() async throws {
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [Self.wrongTotalJSON, Self.wrongTotalJSON])
        )
        do {
            let _: InvariantReceipt = try await Extract.from(
                "Tea 5.00 Cake 7.50 tax 1.00 total 13.50",
                using: session,
                options: ExtractionOptions(maxRetries: 0)
            )
            Issue.record("Expected validationFailed for wrong total")
        } catch let error as ExtractionError {
            guard case .validationFailed(let attempts, let last, let raw) = error else {
                Issue.record("Wrong error \(error)")
                return
            }
            #expect(attempts == 1)
            #expect(raw.contains("99.99"))
            #expect(last is InvariantValidationError)
            if let inv = last as? InvariantValidationError {
                #expect(inv.issues.count == 1)
                #expect(inv.issues[0].path == "total")
                #expect(inv.issues[0].found.contains("99.99"))
            }
        }
    }

    @Test("violated invariant triggers retry and succeeds when fixed")
    func retryThenSucceed() async throws {
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [Self.wrongTotalJSON, Self.correctJSON])
        )
        let result: ExtractionResult<InvariantReceipt> = try await Extract.detailed(
            from: .text("Tea 5.00 Cake 7.50 tax 1.00 total 13.50"),
            using: session,
            options: ExtractionOptions(maxRetries: 2)
        )
        #expect(result.value.total == Decimal(string: "13.50")!)
        #expect(result.value.merchant == "Cafe")
        #expect(result.attempts == 2)
    }

    @Test("persistently violated invariant ends in validationFailed with raw output")
    func exhaustRetries() async throws {
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [
                Self.wrongTotalJSON,
                Self.wrongTotalJSON,
                Self.wrongTotalJSON,
            ])
        )
        do {
            let _: InvariantReceipt = try await Extract.from(
                "doc",
                using: session,
                options: ExtractionOptions(maxRetries: 2)
            )
            Issue.record("Expected validationFailed")
        } catch let error as ExtractionError {
            guard case .validationFailed(let attempts, let last, let raw) = error else {
                Issue.record("Wrong error \(error)")
                return
            }
            // maxRetries + 1 attempts
            #expect(attempts == 3)
            #expect(raw.contains("99.99"))
            #expect(last is InvariantValidationError)
        }
    }

    @Test("repair prompt contains the field-level invariant complaint")
    func repairPromptContainsComplaint() async throws {
        let prompts = PromptCapture()
        let session = ExtractionSession.mock(
            MockLanguageModel { _, user, index in
                await prompts.append(user)
                if index == 0 {
                    return Self.wrongTotalJSON
                }
                return Self.correctJSON
            }
        )
        let result: ExtractionResult<InvariantReceipt> = try await Extract.detailed(
            from: .text("doc"),
            using: session,
            options: ExtractionOptions(maxRetries: 2)
        )
        #expect(result.attempts == 2)

        let all = await prompts.all
        #expect(all.count >= 2)
        let repair = all[1]
        #expect(repair.contains("Previous attempt failed") || repair.contains("Validation errors"))
        #expect(repair.contains("field `total`"))
        #expect(repair.contains("invariant violated"))
        #expect(repair.contains("99.99"))
        #expect(repair.contains("Previous output"))
    }

    @Test("invariants are enforced on the chunk-merge path")
    func chunkMergeEnforcesInvariants() async throws {
        // Two partials merge deterministically to a wrong total; model repair fixes it.
        let partial1 = """
            {"merchant":"Cafe","total":99.99,"tax":1.00,"items":[{"name":"Tea","price":5.00}]}
            """
        let partial2 = """
            {"merchant":"Cafe","items":[{"name":"Cake","price":7.50}]}
            """
        let goodRepair = Self.correctJSON

        let prompts = PromptCapture()
        let session = ExtractionSession.mock(
            MockLanguageModel { _, user, index in
                await prompts.append(user)
                switch index {
                case 0: return partial1
                case 1: return partial2
                default: return goodRepair
                }
            }
        )

        // "document " × 8 = 72 chars; budget 40 → exactly 2 chunks (matches sibling tests).
        let options = ExtractionOptions(
            maxRetries: 2,
            chunkingStrategy: .fixed(characterBudget: 40)
        )
        let result: ExtractionResult<InvariantReceipt> = try await Extract.detailed(
            from: .text(String(repeating: "document ", count: 8)),
            using: session,
            options: options
        )

        #expect(result.value.total == Decimal(string: "13.50")!)
        #expect(result.chunksUsed == 2)
        // Two partials + one document repair generation (deterministic merge is free).
        #expect(result.attempts == 3)

        let all = await prompts.all
        #expect(all.count == 3)
        // Repair reuses the single-chunk-style "Previous attempt failed" prompt on the full doc.
        let repair = all[2]
        #expect(repair.contains("Previous attempt failed") || repair.contains("Validation errors"))
        #expect(repair.contains("field `total`"))
        #expect(repair.contains("invariant violated"))
        #expect(repair.contains("99.99"))
    }

    @Test("InvariantIssue description matches repair formatting")
    func issueDescriptionShape() {
        let issue = InvariantIssue(
            path: "total",
            expected: "items + tax ≈ 13.5",
            found: "99.99"
        )
        #expect(
            issue.description
                == "field `total`: invariant violated — expected items + tax ≈ 13.5, found 99.99"
        )
        let error = InvariantValidationError(issues: [issue])
        #expect(error.errorDescription == issue.description)
    }
}

// MARK: - Helpers

private actor PromptCapture {
    private(set) var all: [String] = []

    func append(_ prompt: String) {
        all.append(prompt)
    }
}
