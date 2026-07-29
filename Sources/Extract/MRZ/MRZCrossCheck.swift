import Foundation

// MARK: - Field keys

/// Typed keys for MRZ fields that a caller may cross-check against LLM extraction.
///
/// The library does **not** guess property names on the caller's extractable type.
/// Pass an explicit `[MRZField: String]` mapping (see docs/Examples.md).
public enum MRZField: String, Sendable, Equatable, CaseIterable, Hashable {
    /// Document number (passport / ID number), fillers stripped.
    case documentNumber
    /// Primary identifier (surname).
    case surname
    /// Secondary identifiers (given names), space-separated.
    case givenNames
    /// Nationality (typically a 3-letter code).
    case nationality
    /// Sex / gender character as encoded (`M`, `F`, or `<`).
    case sex
    /// Date of birth — ISO-8601 or raw `YYMMDD` accepted on the caller's side.
    case dateOfBirth
    /// Date of expiry — ISO-8601 or raw `YYMMDD` accepted on the caller's side.
    case expiryDate
    /// Issuing state or organization (typically a 3-letter code).
    case issuingState
    /// Document code (e.g. `P`, `P<`, `I`, `ID`).
    case documentCode
}

// MARK: - Result types

/// Per-field outcome of comparing a parsed MRZ to caller-supplied extracted values.
///
/// This is an **informational signal, not a calibrated confidence score**. Agreement
/// is real evidence (independent deterministic source); disagreement is a prompt to
/// inspect, not automatic rejection.
public struct MRZFieldComparison: Sendable, Equatable {
    /// Which MRZ field was compared.
    public let field: MRZField
    /// `true` when the extracted value agrees with the MRZ after normalization.
    public let agrees: Bool
    /// MRZ-side value used for comparison (normalized display form).
    public let mrzValue: String
    /// Caller-supplied extracted value (as provided), or `nil` when omitted from the mapping.
    public let extractedValue: String?

    public init(field: MRZField, agrees: Bool, mrzValue: String, extractedValue: String?) {
        self.field = field
        self.agrees = agrees
        self.mrzValue = mrzValue
        self.extractedValue = extractedValue
    }
}

/// Aggregate MRZ ↔ extraction cross-check.
public struct MRZCrossCheckResult: Sendable, Equatable {
    /// One comparison per key present in the caller's mapping (and always for mapped fields only).
    public let comparisons: [MRZFieldComparison]

    public init(comparisons: [MRZFieldComparison]) {
        self.comparisons = comparisons
    }

    /// `true` when every compared field agrees.
    public var allAgree: Bool {
        comparisons.allSatisfy(\.agrees)
    }

    /// Fields that did not agree (or were empty on the MRZ side while extracted was non-empty).
    public var mismatchedFields: [MRZField] {
        comparisons.filter { !$0.agrees }.map(\.field)
    }
}

// MARK: - API

extension MRZResult {
    /// Compare this MRZ to caller-supplied extracted field values.
    ///
    /// Only keys present in `extracted` are compared — the library stays domain-agnostic
    /// and does not invent a mapping from any particular extractable type.
    ///
    /// Text fields are compared after case folding, diacritic stripping, whitespace
    /// collapse, and removal of MRZ filler `<`. Dates compare by **calendar day** (UTC),
    /// accepting ISO-8601 (`1990-03-15`, full timestamps) and raw `YYMMDD` on the
    /// caller's side.
    ///
    /// These results are informational signals, not a confidence score.
    public func crossCheck(against extracted: [MRZField: String]) -> MRZCrossCheckResult {
        var comparisons: [MRZFieldComparison] = []
        // Stable order following MRZField declaration order.
        for field in MRZField.allCases {
            guard let extractedValue = extracted[field] else { continue }
            let mrzValue = mrzStringValue(for: field)
            let agrees = MRZCrossCheck.compare(
                field: field,
                mrz: self,
                mrzValue: mrzValue,
                extracted: extractedValue
            )
            comparisons.append(
                MRZFieldComparison(
                    field: field,
                    agrees: agrees,
                    mrzValue: mrzValue,
                    extractedValue: extractedValue
                )
            )
        }
        return MRZCrossCheckResult(comparisons: comparisons)
    }
}

// MARK: - Comparison logic

enum MRZCrossCheck {
    static func compare(
        field: MRZField,
        mrz: MRZResult,
        mrzValue: String,
        extracted: String
    ) -> Bool {
        switch field {
        case .dateOfBirth:
            return datesAgree(mrzDate: mrz.dateOfBirth, extracted: extracted)
        case .expiryDate:
            return datesAgree(mrzDate: mrz.expiryDate, extracted: extracted)
        case .documentNumber, .surname, .givenNames, .nationality, .sex, .issuingState, .documentCode:
            return textAgrees(mrz: mrzValue, extracted: extracted)
        }
    }

    /// Uppercase, strip diacritics, collapse whitespace, drop `<` fillers.
    static func normalizeText(_ value: String) -> String {
        let withoutFillers = value.replacingOccurrences(of: "<", with: " ")
        let folded =
            withoutFillers
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .uppercased()
        return
            folded
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    static func textAgrees(mrz: String, extracted: String) -> Bool {
        normalizeText(mrz) == normalizeText(extracted)
    }

    static func datesAgree(mrzDate: MRZDate, extracted: String) -> Bool {
        let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Empty extracted vs filler-only MRZ date.
            return mrzDate.date == nil || mrzDate.raw.allSatisfy({ $0 == "<" })
        }

        // Raw YYMMDD on the caller side.
        if trimmed.count == 6, trimmed.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            return trimmed == mrzDate.raw
        }

        guard let extractedDay = parseCalendarDay(trimmed) else {
            return false
        }
        guard let mrzResolved = mrzDate.date else {
            return false
        }
        return sameUTCCalendarDay(extractedDay, mrzResolved)
    }

    /// Parse ISO-8601 (date-only or full) and a few common human formats into a Date.
    ///
    /// Impossible calendar days (e.g. `2012-04-31`) are rejected. Foundation's
    /// `ISO8601DateFormatter` quietly rolls them over (→ May 1), which would
    /// produce a false agreement against a real MRZ expiry — unacceptable when
    /// agreement is sold as deterministic evidence. Shared with
    /// ``LenientDecoding/parseDate(_:locale:)``, which uses the same strict
    /// date-only path.
    static func parseCalendarDay(_ string: String) -> Date? {
        // LenientDecoding already rejects impossible `yyyy-MM-dd` days before any
        // rolling ISO formatter can invent a different calendar day.
        return LenientDecoding.parseDate(string, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func sameUTCCalendarDay(_ lhs: Date, _ rhs: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let l = calendar.dateComponents([.year, .month, .day], from: lhs)
        let r = calendar.dateComponents([.year, .month, .day], from: rhs)
        return l.year == r.year && l.month == r.month && l.day == r.day
    }
}

extension MRZResult {
    fileprivate func mrzStringValue(for field: MRZField) -> String {
        switch field {
        case .documentNumber: return documentNumber
        case .surname: return surname
        case .givenNames: return givenNames
        case .nationality: return nationality
        case .sex: return sex
        case .dateOfBirth: return dateOfBirth.raw
        case .expiryDate: return expiryDate.raw
        case .issuingState: return issuingState
        case .documentCode: return documentCode
        }
    }
}
