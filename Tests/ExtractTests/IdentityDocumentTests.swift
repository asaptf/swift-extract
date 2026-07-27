import Extract
import Foundation
import Testing

/// Mirrors `Examples/schemas/IdentityDocument.swift` and the CLI-embedded twin.
/// Tests drive the real `Extract.from` entry point with `ExtractionSession.mock`.
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

    enum DocumentType: String, Codable, Sendable, CaseIterable {
        case passport
        case nationalId
        case driverLicense
        case residencePermit
        case other
    }
}

extension IdentityDocument.DocumentType: Extractable {}

@Suite("Identity document extraction")
struct IdentityDocumentTests {
    /// Synthetic fixture text aligned with `fixtures/identity_document.txt`.
    static let syntheticDocumentText = """
        UNITED STATES OF AMERICA
        PASSPORT
        Passport No.: X12345678
        Full Name: JANE ALEXANDRA DOE
        Nationality: UNITED STATES OF AMERICA
        Date of birth: 15 MAR 1990
        Sex: F
        Date of issue: 01 JAN 2020
        Date of expiry: 31 DEC 2030
        Authority: U.S. DEPARTMENT OF STATE
        Address: 123 SAMPLE STREET, APT 4B, SPRINGFIELD, IL 62701, UNITED STATES
        *** SYNTHETIC SAMPLE — NO REAL PII ***
        """

    /// Canned model JSON matching the synthetic fixture (offline, deterministic).
    static let syntheticMockJSON = """
        {
          "documentType": "passport",
          "fullName": "JANE ALEXANDRA DOE",
          "documentNumber": "X12345678",
          "dateOfBirth": "1990-03-15",
          "expiryDate": "2030-12-31",
          "issueDate": "2020-01-01",
          "nationality": "UNITED STATES OF AMERICA",
          "issuingAuthority": "U.S. DEPARTMENT OF STATE",
          "sex": "F",
          "address": "123 SAMPLE STREET, APT 4B, SPRINGFIELD, IL 62701, UNITED STATES"
        }
        """

    @Test("schema exposes defining ID fields with guides")
    func schemaShape() {
        let schema = IdentityDocument.extractionSchema
        #expect(schema.type == .object)
        #expect(schema.title == "IdentityDocument")

        let required = ["documentType", "fullName", "documentNumber", "dateOfBirth"]
        for key in required {
            #expect(schema.required?.contains(key) == true, "missing required \(key)")
            #expect(schema.properties?[key] != nil, "missing property \(key)")
        }

        for optional in ["expiryDate", "issueDate", "nationality", "issuingAuthority", "sex", "address"] {
            #expect(schema.required?.contains(optional) != true, "\(optional) should be optional")
            #expect(schema.properties?[optional] != nil, "missing optional property \(optional)")
        }

        #expect(schema.properties?["fullName"]?.description?.localizedCaseInsensitiveContains("name") == true)
        #expect(schema.properties?["documentNumber"]?.description?.localizedCaseInsensitiveContains("number") == true)
        #expect(schema.properties?["dateOfBirth"]?.format == "date-time")

        let docType = schema.properties?["documentType"]
        #expect(docType?.type == .string)
        #expect(docType?.enumValues?.contains("passport") == true)
        #expect(docType?.enumValues?.contains("driverLicense") == true)
    }

    @Test("Extract.from returns typed fields for synthetic passport text")
    func mockExtractFromSyntheticText() async throws {
        let session = ExtractionSession.mock(
            MockLanguageModel(responses: [Self.syntheticMockJSON])
        )
        let document: IdentityDocument = try await Extract.from(
            Self.syntheticDocumentText,
            using: session
        )

        #expect(document.documentType == .passport)
        #expect(document.fullName == "JANE ALEXANDRA DOE")
        #expect(document.documentNumber == "X12345678")
        #expect(document.nationality == "UNITED STATES OF AMERICA")
        #expect(document.issuingAuthority == "U.S. DEPARTMENT OF STATE")
        #expect(document.sex == "F")
        #expect(document.address?.contains("123 SAMPLE STREET") == true)

        let calendar = Calendar(identifier: .gregorian)
        let tz = TimeZone(secondsFromGMT: 0)!
        let dob = calendar.dateComponents(in: tz, from: document.dateOfBirth)
        #expect(dob.year == 1990)
        #expect(dob.month == 3)
        #expect(dob.day == 15)

        let expiry = try #require(document.expiryDate)
        let exp = calendar.dateComponents(in: tz, from: expiry)
        #expect(exp.year == 2030)
        #expect(exp.month == 12)
        #expect(exp.day == 31)

        let issue = try #require(document.issueDate)
        let iss = calendar.dateComponents(in: tz, from: issue)
        #expect(iss.year == 2020)
        #expect(iss.month == 1)
        #expect(iss.day == 1)
    }

    @Test("mock extraction is deterministic across two runs")
    func consistentAcrossRuns() async throws {
        let session1 = ExtractionSession.mock(
            MockLanguageModel(responses: [Self.syntheticMockJSON])
        )
        let session2 = ExtractionSession.mock(
            MockLanguageModel(responses: [Self.syntheticMockJSON])
        )
        let a: IdentityDocument = try await Extract.from(Self.syntheticDocumentText, using: session1)
        let b: IdentityDocument = try await Extract.from(Self.syntheticDocumentText, using: session2)

        #expect(a.fullName == b.fullName)
        #expect(a.documentNumber == b.documentNumber)
        #expect(a.documentType == b.documentType)
        #expect(a.dateOfBirth == b.dateOfBirth)
        #expect(a.expiryDate == b.expiryDate)
        #expect(a.issueDate == b.issueDate)
        #expect(a.nationality == b.nationality)
        #expect(a.issuingAuthority == b.issuingAuthority)
        #expect(a.sex == b.sex)
        #expect(a.address == b.address)
    }

    @Test("optional fields decode as null when absent")
    func optionalNulls() async throws {
        let sparse = """
            {
              "documentType": "nationalId",
              "fullName": "ALEX SAMPLE",
              "documentNumber": "ID-0001",
              "dateOfBirth": "1985-06-01",
              "expiryDate": null,
              "issueDate": null,
              "nationality": null,
              "issuingAuthority": "CITY REGISTRY",
              "sex": null,
              "address": null
            }
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [sparse]))
        let document: IdentityDocument = try await Extract.from("national id synthetic", using: session)
        #expect(document.documentType == .nationalId)
        #expect(document.fullName == "ALEX SAMPLE")
        #expect(document.documentNumber == "ID-0001")
        #expect(document.expiryDate == nil)
        #expect(document.issueDate == nil)
        #expect(document.nationality == nil)
        #expect(document.sex == nil)
        #expect(document.address == nil)
        #expect(document.issuingAuthority == "CITY REGISTRY")
    }
}
