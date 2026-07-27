import Extract
import Foundation
import Testing

@Suite("MRZ parser (ICAO 9303)")
struct MRZParserTests {
    /// Fixed pivot so century resolution is deterministic across hosts.
    static let referenceDate: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: DateComponents(year: 2026, month: 7, day: 27))!
    }()

    // MARK: - ICAO specimens (checksums verified independently)

    /// TD3 specimen from ICAO Doc 9303 (UTOPIA / ERIKSSON ANNA MARIA).
    @Test("TD3 specimen parses with all check digits valid")
    func td3Specimen() throws {
        let mrz = """
            P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<
            L898902C36UTO7408122F1204159ZE184226B<<<<<10
            """
        let result = try MRZParser.parse(mrz, referenceDate: Self.referenceDate)

        #expect(result.format == .td3)
        #expect(result.documentCode == "P")
        #expect(result.issuingState == "UTO")
        #expect(result.surname == "ERIKSSON")
        #expect(result.givenNames == "ANNA MARIA")
        #expect(result.documentNumber == "L898902C3")
        #expect(result.nationality == "UTO")
        #expect(result.sex == "F")
        #expect(result.dateOfBirth.raw == "740812")
        #expect(result.expiryDate.raw == "120415")
        #expect(result.optionalData == "ZE184226B")
        #expect(result.checks.allPassed)
        #expect(result.checks.documentNumber)
        #expect(result.checks.dateOfBirth)
        #expect(result.checks.expiryDate)
        #expect(result.checks.optionalData == true)
        #expect(result.checks.composite)

        assertUTCDate(result.dateOfBirth.date, year: 1974, month: 8, day: 12)
        assertUTCDate(result.expiryDate.date, year: 2012, month: 4, day: 15)
    }

    /// TD2 specimen from ICAO Doc 9303.
    @Test("TD2 specimen parses with all check digits valid")
    func td2Specimen() throws {
        let mrz = """
            I<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<
            D231458907UTO7408122F1204159<<<<<<<6
            """
        let result = try MRZParser.parse(mrz, referenceDate: Self.referenceDate)

        #expect(result.format == .td2)
        #expect(result.documentCode == "I")
        #expect(result.issuingState == "UTO")
        #expect(result.surname == "ERIKSSON")
        #expect(result.givenNames == "ANNA MARIA")
        #expect(result.documentNumber == "D23145890")
        #expect(result.nationality == "UTO")
        #expect(result.sex == "F")
        #expect(result.dateOfBirth.raw == "740812")
        #expect(result.expiryDate.raw == "120415")
        #expect(result.checks.allPassed)
        #expect(result.checks.optionalData == nil)
        assertUTCDate(result.dateOfBirth.date, year: 1974, month: 8, day: 12)
    }

    /// TD1 specimen from ICAO Doc 9303.
    @Test("TD1 specimen parses with all check digits valid")
    func td1Specimen() throws {
        let mrz = """
            I<UTOD231458907<<<<<<<<<<<<<<<
            7408122F1204159UTO<<<<<<<<<<<6
            ERIKSSON<<ANNA<MARIA<<<<<<<<<<
            """
        let result = try MRZParser.parse(mrz, referenceDate: Self.referenceDate)

        #expect(result.format == .td1)
        #expect(result.documentCode == "I")
        #expect(result.issuingState == "UTO")
        #expect(result.surname == "ERIKSSON")
        #expect(result.givenNames == "ANNA MARIA")
        #expect(result.documentNumber == "D23145890")
        #expect(result.nationality == "UTO")
        #expect(result.sex == "F")
        #expect(result.dateOfBirth.raw == "740812")
        #expect(result.expiryDate.raw == "120415")
        #expect(result.checks.allPassed)
        #expect(result.checks.optionalData == nil)
        assertUTCDate(result.dateOfBirth.date, year: 1974, month: 8, day: 12)
        assertUTCDate(result.expiryDate.date, year: 2012, month: 4, day: 15)
    }

    // MARK: - Corrupted check digit

    @Test("corrupted check digit still parses; affected check fails; allPassed is false")
    func corruptedCheckDigit() throws {
        // Valid TD3 with document-number check digit flipped 6 → 0.
        let mrz = """
            P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<
            L898902C30UTO7408122F1204159ZE184226B<<<<<10
            """
        let result = try MRZParser.parse(mrz, referenceDate: Self.referenceDate)

        #expect(result.format == .td3)
        #expect(result.documentNumber == "L898902C3")
        #expect(result.surname == "ERIKSSON")
        #expect(!result.checks.documentNumber)
        #expect(result.checks.dateOfBirth)
        #expect(result.checks.expiryDate)
        // Composite range includes the document check digit, so it fails too.
        #expect(!result.checks.composite)
        #expect(!result.checks.allPassed)
    }

    // MARK: - Find-in-text + repo fixture

    @Test("findAndParse locates fixture MRZ with every check digit valid")
    func fixtureFindInText() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/identity_document.txt")
        let text = try String(contentsOf: fixtureURL, encoding: .utf8)
        let result = try MRZParser.findAndParse(in: text, referenceDate: Self.referenceDate)

        #expect(result.format == .td3)
        #expect(result.surname == "DOE")
        #expect(result.givenNames == "JANE ALEXANDRA")
        #expect(result.documentNumber == "X12345678")
        #expect(result.nationality == "USA")
        #expect(result.issuingState == "USA")
        #expect(result.sex == "F")
        #expect(result.dateOfBirth.raw == "900315")
        #expect(result.expiryDate.raw == "301231")
        #expect(result.checks.allPassed)
        assertUTCDate(result.dateOfBirth.date, year: 1990, month: 3, day: 15)
        assertUTCDate(result.expiryDate.date, year: 2030, month: 12, day: 31)
    }

    // MARK: - Names and dates

    @Test("name parsing: multiple given names and filler padding")
    func nameParsing() throws {
        let mrz = """
            P<USADOE<<JANE<ALEXANDRA<<<<<<<<<<<<<<<<<<<<
            X123456785USA9003152F3012316<<<<<<<<<<<<<<06
            """
        let result = try MRZParser.parse(mrz, referenceDate: Self.referenceDate)
        #expect(result.surname == "DOE")
        #expect(result.givenNames == "JANE ALEXANDRA")
        #expect(!result.givenNames.contains("<"))
        #expect(!result.surname.hasSuffix(" "))
    }

    @Test("date-of-birth century rule is backward-looking")
    func birthCenturyRule() throws {
        // YY=90 with reference 2026 must resolve to 1990, not 2090.
        let result = try MRZParser.parse(
            """
            P<USADOE<<JANE<ALEXANDRA<<<<<<<<<<<<<<<<<<<<
            X123456785USA9003152F3012316<<<<<<<<<<<<<<06
            """,
            referenceDate: Self.referenceDate
        )
        #expect(result.dateOfBirth.raw == "900315")
        assertUTCDate(result.dateOfBirth.date, year: 1990, month: 3, day: 15)

        // Specimen DOB 74 → 1974 under the same rule.
        let specimen = try MRZParser.parse(
            """
            P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<
            L898902C36UTO7408122F1204159ZE184226B<<<<<10
            """,
            referenceDate: Self.referenceDate
        )
        assertUTCDate(specimen.dateOfBirth.date, year: 1974, month: 8, day: 12)
    }

    @Test("unsupported layout throws MRZError")
    func unsupportedLayout() {
        #expect(throws: MRZError.self) {
            try MRZParser.parse("NOT AN MRZ\nALSO NOT")
        }
        #expect(throws: MRZError.self) {
            try MRZParser.findAndParse(in: "No machine readable zone here at all.")
        }
    }

    // MARK: - Helpers

    private func assertUTCDate(
        _ date: Date?,
        year: Int,
        month: Int,
        day: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let date else {
            Issue.record("Expected non-nil date", sourceLocation: sourceLocation)
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        #expect(parts.year == year, sourceLocation: sourceLocation)
        #expect(parts.month == month, sourceLocation: sourceLocation)
        #expect(parts.day == day, sourceLocation: sourceLocation)
    }
}
