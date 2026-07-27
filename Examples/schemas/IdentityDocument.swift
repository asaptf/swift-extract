import Extract
import Foundation

/// Example schema for identity-document recognition (passport, national ID, driver license).
/// Keep in sync with the embedded `IdentityDocument` type in `Sources/ExtractCLI`.
///
/// **Privacy:** Use only synthetic / redacted samples. Never ship real PII or government ID photos
/// in fixtures, logs, or CI. Prefer on-device backends when processing real documents in production.
@Extractable
struct IdentityDocument {
    @Guide(
        "Document kind as printed or clearly implied: passport, nationalId, driverLicense, residencePermit, or other"
    )
    let documentType: DocumentType

    @Guide("Full legal name as printed on the document, given names then surname when both appear")
    let fullName: String

    @Guide("Primary document / passport / ID number as printed (alphanumeric, no spaces if possible)")
    let documentNumber: String

    @Guide("Date of birth in ISO 8601 when possible")
    let dateOfBirth: Date

    @Guide("Expiry date if printed; null when the document has no expiry")
    let expiryDate: Date?

    @Guide("Issue / date of issue if printed; null when not present")
    let issueDate: Date?

    @Guide("Nationality as printed (country name or ISO code), or null if only issuing authority is shown")
    let nationality: String?

    @Guide("Issuing authority or country of issue as printed (e.g. U.S. DEPARTMENT OF STATE)")
    let issuingAuthority: String?

    @Guide("Sex or gender as printed (e.g. F, M, X); null if not present")
    let sex: String?

    @Guide("Address as printed when present on the document; null otherwise")
    let address: String?

    /// Coarse document kind for product demos; extend as needed for country-specific flows.
    enum DocumentType: String, Codable, Sendable, CaseIterable {
        case passport
        case nationalId
        case driverLicense
        case residencePermit
        case other
    }
}

extension IdentityDocument.DocumentType: Extractable {}
