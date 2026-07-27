import Foundation

/// ICAO 9303 travel-document layout detected from line count and line length.
public enum MRZFormat: String, Sendable, Equatable, CaseIterable {
    /// ID-1 sized cards: 3 lines × 30 characters.
    case td1
    /// ID-2 sized documents: 2 lines × 36 characters.
    case td2
    /// Passports (ID-3): 2 lines × 44 characters.
    case td3

    /// Expected line count for this format.
    public var lineCount: Int {
        switch self {
        case .td1: return 3
        case .td2, .td3: return 2
        }
    }

    /// Expected character count per line for this format.
    public var lineLength: Int {
        switch self {
        case .td1: return 30
        case .td2: return 36
        case .td3: return 44
        }
    }
}

/// Per-field ICAO check-digit outcomes.
///
/// A failed check does **not** prevent parsing — it is a trust signal for the
/// caller (transcription / OCR error detection). Check digits are not
/// anti-forgery, chip/NFC verification, or identity verification.
public struct MRZCheckResult: Sendable, Equatable {
    /// Document-number field check digit.
    public let documentNumber: Bool
    /// Date-of-birth field check digit.
    public let dateOfBirth: Bool
    /// Date-of-expiry field check digit.
    public let expiryDate: Bool
    /// Optional-data / personal-number check digit when the format defines one
    /// (TD3 always; TD1/TD2 report `nil` because optional data is folded into
    /// the composite range without a separate optional check digit).
    public let optionalData: Bool?
    /// Composite check digit over the format-specified character ranges.
    public let composite: Bool

    public init(
        documentNumber: Bool,
        dateOfBirth: Bool,
        expiryDate: Bool,
        optionalData: Bool?,
        composite: Bool
    ) {
        self.documentNumber = documentNumber
        self.dateOfBirth = dateOfBirth
        self.expiryDate = expiryDate
        self.optionalData = optionalData
        self.composite = composite
    }

    /// `true` when every check the format defines succeeded.
    public var allPassed: Bool {
        let optionalOK = optionalData ?? true
        return documentNumber && dateOfBirth && expiryDate && optionalOK && composite
    }
}

/// Structured fields extracted from an ICAO 9303 Machine Readable Zone.
public struct MRZResult: Sendable, Equatable {
    /// Detected document layout.
    public let format: MRZFormat
    /// Normalized MRZ lines as parsed (uppercase, exact format length).
    public let rawLines: [String]
    /// Document code (e.g. `P`, `P<`, `I`, `ID`).
    public let documentCode: String
    /// Issuing state or organization (3-letter code, fillers stripped).
    public let issuingState: String
    /// Primary identifier (surname), cleaned of `<` padding.
    public let surname: String
    /// Secondary identifiers (given names), space-separated, cleaned.
    public let givenNames: String
    /// Document number with trailing fillers removed (check digit not included).
    public let documentNumber: String
    /// Nationality (3-letter code, fillers stripped).
    public let nationality: String
    /// Date of birth (`YYMMDD` raw + resolved UTC `Date`).
    public let dateOfBirth: MRZDate
    /// Sex / gender character as encoded (`M`, `F`, or `<`).
    public let sex: String
    /// Date of expiry (`YYMMDD` raw + resolved UTC `Date`).
    public let expiryDate: MRZDate
    /// Optional / personal data with trailing fillers removed.
    public let optionalData: String
    /// Per-field check-digit results (failed checks do not throw).
    public let checks: MRZCheckResult

    public init(
        format: MRZFormat,
        rawLines: [String],
        documentCode: String,
        issuingState: String,
        surname: String,
        givenNames: String,
        documentNumber: String,
        nationality: String,
        dateOfBirth: MRZDate,
        sex: String,
        expiryDate: MRZDate,
        optionalData: String,
        checks: MRZCheckResult
    ) {
        self.format = format
        self.rawLines = rawLines
        self.documentCode = documentCode
        self.issuingState = issuingState
        self.surname = surname
        self.givenNames = givenNames
        self.documentNumber = documentNumber
        self.nationality = nationality
        self.dateOfBirth = dateOfBirth
        self.sex = sex
        self.expiryDate = expiryDate
        self.optionalData = optionalData
        self.checks = checks
    }
}
