import Extract
import Foundation
import Testing

@Suite("MRZ cross-check")
struct MRZCrossCheckTests {
    static let referenceDate: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: DateComponents(year: 2026, month: 7, day: 27))!
    }()

    /// ICAO TD3 specimen (ERIKSSON / ANNA MARIA).
    static let specimenMRZ = """
        P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<
        L898902C36UTO7408122F1204159ZE184226B<<<<<10
        """

    @Test("matching extracted values all agree")
    func matchingValuesAgree() throws {
        let mrz = try MRZParser.parse(Self.specimenMRZ, referenceDate: Self.referenceDate)
        let extracted: [MRZField: String] = [
            .documentNumber: "L898902C3",
            .surname: "ERIKSSON",
            .givenNames: "ANNA MARIA",
            .nationality: "UTO",
            .sex: "F",
            .dateOfBirth: "1974-08-12",
            .expiryDate: "2012-04-15",
            .issuingState: "UTO",
            .documentCode: "P",
        ]
        let check = mrz.crossCheck(against: extracted)
        #expect(check.allAgree)
        #expect(check.mismatchedFields.isEmpty)
        #expect(check.comparisons.count == 9)
        #expect(check.comparisons.filter { !$0.agrees }.isEmpty)
    }

    @Test("mismatch is flagged on a differing field")
    func mismatchFlagged() throws {
        let mrz = try MRZParser.parse(Self.specimenMRZ, referenceDate: Self.referenceDate)
        let extracted: [MRZField: String] = [
            .documentNumber: "WRONG123",
            .surname: "ERIKSSON",
            .dateOfBirth: "1974-08-12",
        ]
        let check = mrz.crossCheck(against: extracted)
        #expect(!check.allAgree)
        #expect(check.mismatchedFields.contains(.documentNumber))
        #expect(!check.mismatchedFields.contains(.surname))
        #expect(!check.mismatchedFields.contains(.dateOfBirth))

        let doc = check.comparisons.first { $0.field == .documentNumber }
        #expect(doc?.agrees == false)
        #expect(doc?.extractedValue == "WRONG123")
        #expect(doc?.mrzValue == "L898902C3")
    }

    @Test("case and diacritic differences still agree")
    func caseAndDiacriticsAgree() throws {
        let mrz = try MRZParser.parse(Self.specimenMRZ, referenceDate: Self.referenceDate)
        // Given names with mixed case; surname with a diacritic that folds away.
        let extracted: [MRZField: String] = [
            .surname: "ërikssön",
            .givenNames: "Anna Maria",
            .documentNumber: "l898902c3",
            .sex: "f",
        ]
        let check = mrz.crossCheck(against: extracted)
        #expect(check.allAgree)
        #expect(check.mismatchedFields.isEmpty)
    }

    @Test("dates agree across ISO-8601 and raw YYMMDD")
    func dateFormatsAgree() throws {
        let mrz = try MRZParser.parse(Self.specimenMRZ, referenceDate: Self.referenceDate)

        let iso = mrz.crossCheck(against: [
            .dateOfBirth: "1974-08-12",
            .expiryDate: "2012-04-15T00:00:00Z",
        ])
        #expect(iso.allAgree)

        let raw = mrz.crossCheck(against: [
            .dateOfBirth: "740812",
            .expiryDate: "120415",
        ])
        #expect(raw.allAgree)

        let mismatch = mrz.crossCheck(against: [
            .dateOfBirth: "1990-03-15"
        ])
        #expect(!mismatch.allAgree)
        #expect(mismatch.mismatchedFields == [.dateOfBirth])
    }

    @Test("only mapped fields are compared")
    func onlyMappedFieldsCompared() throws {
        let mrz = try MRZParser.parse(Self.specimenMRZ, referenceDate: Self.referenceDate)
        let check = mrz.crossCheck(against: [
            .surname: "ERIKSSON"
        ])
        #expect(check.comparisons.count == 1)
        #expect(check.comparisons[0].field == .surname)
        #expect(check.allAgree)
    }
}
