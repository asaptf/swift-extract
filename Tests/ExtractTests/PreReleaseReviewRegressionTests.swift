import Foundation
import Testing

@testable import Extract

// Regression tests for the 12 pre-release review findings.
// Each case is written to FAIL on the buggy HEAD and pass after the fix.

// MARK: - Probe types

@Extractable
private struct ReviewAmount {
    let amount: Decimal
}

@Extractable
private struct ReviewInvariantValue {
    let left: Int
    let right: Int

    func validateInvariants() throws {
        if left != right {
            throw InvariantValidationError(
                path: "right",
                expected: "equal to left (\(left))",
                found: "\(right)"
            )
        }
    }
}

/// Counts `validateInvariants` invocations so we can assert the extraction loop
/// does not double-validate after `decodeExtracted` also started enforcing them.
private final class ValidationInvocationCounter: @unchecked Sendable {
    static let shared = ValidationInvocationCounter()
    private let lock = NSLock()
    private var _count = 0

    func reset() {
        lock.lock()
        _count = 0
        lock.unlock()
    }

    func increment() {
        lock.lock()
        _count += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }
}

@Extractable
private struct ReviewCountingInvariant {
    let token: Int

    func validateInvariants() throws {
        ValidationInvocationCounter.shared.increment()
    }
}

@Extractable
private struct ReviewSignalValue {
    let note: String?
    let total: Decimal
}

@Extractable
private struct ReviewCacheItem {
    let name: String
}

@Extractable
private struct ReviewCacheRoot {
    let items: [ReviewCacheItem]
}

@Suite("Pre-release review regressions")
struct PreReleaseReviewRegressionTests {

    // MARK: 1 — Unbounded / non-finite scientific exponents

    @Test("finding 1: huge / Int.min exponents reject; non-finite results rejected")
    func boundedScientificExponents() {
        // Must not hang on a billion multiplications.
        let clock = ContinuousClock()
        let start = clock.now
        #expect(LenientDecoding.parseDecimal("1e1000000000") == nil)
        #expect(start.duration(to: clock.now) < .seconds(1), "unbounded exponent hung")

        // Int.min negation trap: 1e-9223372036854775808
        #expect(LenientDecoding.parseDecimal("1e-9223372036854775808") == nil)

        // Overflow scale previously returned Decimal.nan rather than nil.
        let huge = LenientDecoding.parseDecimal("1e1000")
        #expect(huge == nil, "1e1000 should reject, got \(String(describing: huge))")

        // In-range scientific still works.
        #expect(LenientDecoding.parseDecimal("1e3") == 1000)
        #expect(LenientDecoding.parseDecimal("2e-2") == Decimal(string: "0.02"))
    }

    // MARK: 2 — Locale-aware scientific mantissa; no interior-char stripping

    @Test("finding 2: scientific mantissa respects locale; junk interiors rejected")
    func scientificLocaleAndValidation() {
        let de = Locale(identifier: "de_DE")

        // de_DE: "1,5e3" is 1.5 × 10³ = 1500, not 15 × 10³ from stripping the comma.
        let deSci = LenientDecoding.parseDecimal("1,5e3", locale: de)
        #expect(deSci == Decimal(string: "1500"), "got \(String(describing: deSci))")

        // Interior currency/letters in the exponent must not be deleted into a valid form.
        #expect(LenientDecoding.parseDecimal("1eUSD3") == nil)
        #expect(LenientDecoding.parseDecimal("1eUSD3", locale: de) == nil)
    }

    // MARK: 3 — Parenthesised scientific already negative

    @Test("finding 3: parenthesised scientific with inner minus stays negative")
    func parenthesizedScientificKeepsSign() {
        let value = LenientDecoding.parseDecimal("(-1e3)")
        #expect(value == Decimal(string: "-1000"), "got \(String(describing: value))")

        // Plain accounting paren without inner sign still negates.
        #expect(LenientDecoding.parseDecimal("(1e3)") == Decimal(string: "-1000"))
    }

    // MARK: 4 — Same mark for grouping and decimal is invalid

    @Test("finding 4: same-separator grouping+decimal forms are rejected")
    func sameSeparatorRejected() {
        #expect(LenientDecoding.parseDecimal("1.234.56") == nil)
        #expect(LenientDecoding.parseDecimal("1,234,56") == nil)
        // Distinct separators still work.
        #expect(
            LenientDecoding.parseDecimal("1.234,56", locale: Locale(identifier: "de_DE"))
                == Decimal(string: "1234.56")
        )
    }

    // MARK: 5 — decodeExtracted enforces invariants

    @Test("finding 5: decodeExtracted runs validateInvariants")
    func decodeExtractedValidatesInvariants() {
        #expect(throws: InvariantValidationError.self) {
            _ = try ReviewInvariantValue.decodeExtracted(from: #"{"left":1,"right":2}"#)
        }
        // Valid invariants still succeed.
        let ok = try? ReviewInvariantValue.decodeExtracted(from: #"{"left":3,"right":3}"#)
        #expect(ok?.left == 3 && ok?.right == 3)
    }

    // MARK: 5b — extraction validates invariants exactly once

    @Test("finding 5b: extraction path validates invariants exactly once")
    func extractionValidatesInvariantsExactlyOnce() async throws {
        ValidationInvocationCounter.shared.reset()
        let json = #"{"token":1}"#
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
        let result: ExtractionResult<ReviewCountingInvariant> = try await Extract.detailed(
            from: .text("token 1"),
            using: session,
            options: ExtractionOptions(maxRetries: 0)
        )
        #expect(result.value.token == 1)
        #expect(
            ValidationInvocationCounter.shared.count == 1,
            "expected exactly one validateInvariants call, got \(ValidationInvocationCounter.shared.count)"
        )

        // Public decodeExtracted still enforces invariants for direct callers.
        ValidationInvocationCounter.shared.reset()
        _ = try ReviewCountingInvariant.decodeExtracted(from: json)
        #expect(ValidationInvocationCounter.shared.count == 1)
    }

    // MARK: 6 — Expiry century stays inside [ref−50, ref+50]

    @Test("finding 6: expiry 991231 with 2026 ref is 1999, not 2099")
    func expiryCenturyPivotWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let ref = calendar.date(from: DateComponents(year: 2026, month: 7, day: 27))!

        let parsed = MRZDateParser.parse("991231", kind: .expiry, referenceDate: ref)
        #expect(parsed.date != nil)
        let parts = calendar.dateComponents([.year, .month, .day], from: parsed.date!)
        #expect(parts.year == 1999, "expected 1999 inside [1976,2076], got \(String(describing: parts.year))")
        #expect(parts.month == 12 && parts.day == 31)

        // Still prefer 2000-based when it lies inside the window.
        let future = MRZDateParser.parse("301231", kind: .expiry, referenceDate: ref)
        let futureParts = calendar.dateComponents([.year], from: future.date!)
        #expect(futureParts.year == 2030)
    }

    // MARK: 7 — Impossible extracted dates never agree

    @Test("finding 7: impossible calendar day does not agree with MRZ expiry")
    func invalidCrossCheckDateRejected() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let date = calendar.date(from: DateComponents(year: 2012, month: 5, day: 1))!

        let mrz = MRZResult(
            format: .td3,
            rawLines: [],
            documentCode: "P",
            issuingState: "UTO",
            surname: "X",
            givenNames: "Y",
            documentNumber: "1",
            nationality: "UTO",
            dateOfBirth: MRZDate(raw: "000101", date: date),
            sex: "M",
            expiryDate: MRZDate(raw: "120501", date: date),
            optionalData: "",
            checks: MRZCheckResult(
                documentNumber: true,
                dateOfBirth: true,
                expiryDate: true,
                optionalData: true,
                composite: true
            )
        )

        let dateOnly = mrz.crossCheck(against: [.expiryDate: "2012-04-31"])
        let dateOnlyComparison = dateOnly.comparisons.first { $0.field == .expiryDate }
        #expect(
            dateOnlyComparison?.agrees == false,
            "impossible date-only must not agree via formatter rollover"
        )

        // Full ISO timestamps also roll via ISO8601DateFormatter; must reject too.
        let timestamp = mrz.crossCheck(against: [.expiryDate: "2012-04-31T00:00:00Z"])
        let timestampComparison = timestamp.comparisons.first { $0.field == .expiryDate }
        #expect(
            timestampComparison?.agrees == false,
            "impossible full timestamp must not agree via formatter rollover"
        )
        #expect(LenientDecoding.parseDate("2012-04-31T00:00:00Z", locale: nil) == nil)
        #expect(LenientDecoding.parseDate("2012-04-31", locale: nil) == nil)
        // Valid full timestamps still parse.
        #expect(LenientDecoding.parseDate("2012-05-01T00:00:00Z", locale: nil) != nil)
    }

    // MARK: 8 — Prefer checksum-valid MRZ candidate

    @Test("finding 8: discovery prefers checksum-valid passport over earlier noise")
    func preferValidChecksumCandidate() throws {
        // Three 30-char MRZ-alphabet noise lines (structurally TD1-like, bad checks),
        // then prose, then a valid TD3 specimen.
        let noise = String(repeating: "A", count: 30)
        let text = """
            \(noise)
            \(noise)
            \(noise)
            Some OCR prose in between
            P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<
            L898902C36UTO7408122F1204159ZE184226B<<<<<10
            """
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let ref = calendar.date(from: DateComponents(year: 2026, month: 7, day: 27))!

        let result = try MRZParser.findAndParse(in: text, referenceDate: ref)
        #expect(result.format == .td3)
        #expect(result.surname == "ERIKSSON")
        #expect(result.checks.allPassed)
    }

    // MARK: 9 — Two-line windows inside three-line runs

    @Test("finding 9: valid TD3 after one noise line inside a 3-line run is found")
    func twoLineWindowInsideThreeLineRun() throws {
        let noise = String(repeating: "A", count: 44)
        let text = """
            \(noise)
            P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<
            L898902C36UTO7408122F1204159ZE184226B<<<<<10
            """
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let ref = calendar.date(from: DateComponents(year: 2026, month: 7, day: 27))!

        let result = try MRZParser.findAndParse(in: text, referenceDate: ref)
        #expect(result.format == .td3)
        #expect(result.surname == "ERIKSSON")
        #expect(result.checks.allPassed)
    }

    // MARK: 10 — Null optional leaves appear as reformatted

    @Test("finding 10: null optional fields emit an explicit reformatted signal")
    func nullOptionalEmitsSignal() {
        let value = ReviewSignalValue(note: nil, total: 12)
        let signals = FieldGrounding.compute(
            value: value,
            sourceText: "Total: 12",
            attempts: 1,
            chunksUsed: 1
        )
        let note = signals.fields.first { $0.path == "note" }
        #expect(note != nil, "null optional must not be omitted from the report")
        #expect(note?.grounding == .reformatted)
    }

    // MARK: 11 — Numeric signs participate in grounding

    @Test("finding 11: opposite-sign number is reformatted, not normalized")
    func numericSignParticipatesInMatch() {
        // Negative extracted vs positive source (skeleton path).
        let negativeExtracted = ReviewSignalValue(note: nil, total: Decimal(string: "-12.5")!)
        let negativeSignals = FieldGrounding.compute(
            value: negativeExtracted,
            sourceText: "Total: 12.50",
            attempts: 1,
            chunksUsed: 1
        )
        let negativeTotal = negativeSignals.fields.first { $0.path == "total" }
        #expect(
            negativeTotal?.grounding == .reformatted,
            "negative vs positive source: got \(String(describing: negativeTotal?.grounding))"
        )

        // Positive extracted vs negative source (raw substring used to hit inside `-12.50`).
        let positiveExtracted = ReviewSignalValue(note: nil, total: Decimal(string: "12.5")!)
        let positiveSignals = FieldGrounding.compute(
            value: positiveExtracted,
            sourceText: "Refund: -12.50",
            attempts: 1,
            chunksUsed: 1
        )
        let positiveTotal = positiveSignals.fields.first { $0.path == "total" }
        #expect(
            positiveTotal?.grounding == .reformatted,
            "positive vs negative source: got \(String(describing: positiveTotal?.grounding))"
        )

        // Matching sign still normalizes / verbatim.
        let refund = ReviewSignalValue(note: nil, total: Decimal(string: "-12.5")!)
        let refundSignals = FieldGrounding.compute(
            value: refund,
            sourceText: "Refund: -12.50",
            attempts: 1,
            chunksUsed: 1
        )
        let refundTotal = refundSignals.fields.first { $0.path == "total" }
        #expect(
            refundTotal?.grounding == .normalized || refundTotal?.grounding == .verbatim,
            "got \(String(describing: refundTotal?.grounding))"
        )

        let charged = ReviewSignalValue(note: nil, total: Decimal(string: "12.5")!)
        let chargedSignals = FieldGrounding.compute(
            value: charged,
            sourceText: "Total: 12.50",
            attempts: 1,
            chunksUsed: 1
        )
        let chargedTotal = chargedSignals.fields.first { $0.path == "total" }
        #expect(
            chargedTotal?.grounding == .normalized || chargedTotal?.grounding == .verbatim,
            "got \(String(describing: chargedTotal?.grounding))"
        )
    }

    // MARK: 12 — Source normalization cached once per compute

    @Test("finding 12: source normalize runs once per compute, not once per leaf")
    func sourceNormalizationCached() {
        // N string leaves that miss verbatim (so each still normalises its own value).
        // Cached path: 1 source fold + N leaf folds.
        // Uncached path: N source folds + N leaf folds.
        let leafCount = 40
        let items = (0..<leafCount).map { ReviewCacheItem(name: "unique-token-\($0)") }
        let value = ReviewCacheRoot(items: items)
        let source = String(repeating: "background prose without the tokens ", count: 200)
        let stats = FieldGrounding.ComputeStats()

        let signals = FieldGrounding.compute(
            value: value,
            sourceText: source,
            attempts: 1,
            chunksUsed: 1,
            stats: stats
        )

        #expect(signals.fields.count == leafCount)
        // 1 (source) + leafCount (each leaf value) — not 2 * leafCount.
        #expect(
            stats.normalizeForSearchCalls == 1 + leafCount,
            "expected 1 source + \(leafCount) leaf normalizes, got \(stats.normalizeForSearchCalls)"
        )
        // Source numeric skeleton once; no numeric leaves in this fixture.
        #expect(
            stats.numericSkeletonCalls == 1,
            "expected one source numeric skeleton, got \(stats.numericSkeletonCalls)"
        )
    }
}
