import Foundation
import Testing

@testable import Extract

/// Property-based coverage for the ICAO 9303 MRZ parser.
///
/// Strongest property: generate structurally valid records (correct layout + check
/// digits), assert full field round-trip and `allPassed`, then mutate a single
/// character inside a checked field and assert the parse is never all-clear.
@Suite("MRZ property tests")
struct MRZPropertyTests {
    private static let seed: UInt64 = 0x4D52_5A50_524F_5031  // "MRZPROP1"
    private static let referenceDate: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 7, day: 27))!
    }()

    private static let mrzAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<")

    // MARK: - Round-trip + mutation

    @Test("TD3: random valid records round-trip; check-digit mutation never all-clears")
    func td3RoundTripAndMutation() throws {
        var rng = SplitMix64(seed: Self.seed)
        for _ in 0..<80 {
            let generated = MRZGenerator.randomTD3(rng: &rng)
            let result = try MRZParser.parse(generated.lines.joined(separator: "\n"), referenceDate: Self.referenceDate)

            #expect(result.format == .td3)
            #expect(result.checks.allPassed)
            #expect(result.documentCode == generated.documentCode)
            #expect(result.issuingState == generated.issuingState)
            #expect(result.surname == generated.surname)
            #expect(result.givenNames == generated.givenNames)
            #expect(result.documentNumber == generated.documentNumber)
            #expect(result.nationality == generated.nationality)
            #expect(result.dateOfBirth.raw == generated.dobRaw)
            #expect(result.expiryDate.raw == generated.expiryRaw)
            #expect(result.sex == generated.sex)
            #expect(result.optionalData == generated.optionalData)

            // Mutate a single character at a random checked position (includes check digits).
            let mutated = MRZGenerator.mutateCheckedField(lines: generated.lines, format: .td3, rng: &rng)
            let mutatedResult = try MRZParser.parse(
                mutated.joined(separator: "\n"),
                referenceDate: Self.referenceDate
            )
            #expect(
                !mutatedResult.checks.allPassed,
                "mutation left all checks green:\n\(mutated.joined(separator: "\n"))"
            )
        }
    }

    @Test("TD2: random valid records round-trip; check-digit mutation never all-clears")
    func td2RoundTripAndMutation() throws {
        var rng = SplitMix64(seed: Self.seed ^ 0x0000_0000_0000_7D02)
        for _ in 0..<80 {
            let generated = MRZGenerator.randomTD2(rng: &rng)
            let result = try MRZParser.parse(generated.lines.joined(separator: "\n"), referenceDate: Self.referenceDate)

            #expect(result.format == .td2)
            #expect(result.checks.allPassed)
            #expect(result.surname == generated.surname)
            #expect(result.givenNames == generated.givenNames)
            #expect(result.documentNumber == generated.documentNumber)
            #expect(result.dateOfBirth.raw == generated.dobRaw)
            #expect(result.expiryDate.raw == generated.expiryRaw)

            let mutated = MRZGenerator.mutateCheckedField(lines: generated.lines, format: .td2, rng: &rng)
            let mutatedResult = try MRZParser.parse(
                mutated.joined(separator: "\n"),
                referenceDate: Self.referenceDate
            )
            #expect(!mutatedResult.checks.allPassed)
        }
    }

    @Test("TD1: random valid records round-trip; check-digit mutation never all-clears")
    func td1RoundTripAndMutation() throws {
        var rng = SplitMix64(seed: Self.seed ^ 0x0000_0000_0000_7D01)
        for _ in 0..<80 {
            let generated = MRZGenerator.randomTD1(rng: &rng)
            let result = try MRZParser.parse(generated.lines.joined(separator: "\n"), referenceDate: Self.referenceDate)

            #expect(result.format == .td1)
            #expect(result.checks.allPassed)
            #expect(result.surname == generated.surname)
            #expect(result.givenNames == generated.givenNames)
            #expect(result.documentNumber == generated.documentNumber)
            #expect(result.dateOfBirth.raw == generated.dobRaw)
            #expect(result.expiryDate.raw == generated.expiryRaw)

            let mutated = MRZGenerator.mutateCheckedField(lines: generated.lines, format: .td1, rng: &rng)
            let mutatedResult = try MRZParser.parse(
                mutated.joined(separator: "\n"),
                referenceDate: Self.referenceDate
            )
            #expect(!mutatedResult.checks.allPassed)
        }
    }

    @Test("flipping any individual check digit never leaves allPassed true")
    func flipEachCheckDigit() throws {
        var rng = SplitMix64(seed: Self.seed ^ 0x0000_0000_0000_00CD)
        let td3 = MRZGenerator.randomTD3(rng: &rng)
        // TD3 check digit positions on line 2: 9, 19, 27, 42, 43
        for position in [9, 19, 27, 42, 43] {
            var lines = td3.lines
            var chars = Array(lines[1])
            let original = chars[position]
            var replacement: Character = original
            for digit in "0123456789" where digit != original {
                replacement = digit
                break
            }
            chars[position] = replacement
            lines[1] = String(chars)
            let result = try MRZParser.parse(lines.joined(separator: "\n"), referenceDate: Self.referenceDate)
            #expect(
                !result.checks.allPassed,
                "flipping check at line2[\(position)] stayed all-clear"
            )
        }
    }

    // MARK: - Junk of correct dimensions

    @Test("random MRZ-alphabet junk of TD1/TD2/TD3 dimensions: parse or MRZError, never trap")
    func junkOfRightLengths() {
        var rng = SplitMix64(seed: Self.seed ^ 0x0000_0000_4A55_4E4B)
        for _ in 0..<100 {
            let formatRoll = rng.next() % 3
            let lines: [String]
            switch formatRoll {
            case 0:
                lines = (0..<3).map { _ in Self.randomMRZLine(length: 30, rng: &rng) }
            case 1:
                lines = (0..<2).map { _ in Self.randomMRZLine(length: 36, rng: &rng) }
            default:
                lines = (0..<2).map { _ in Self.randomMRZLine(length: 44, rng: &rng) }
            }

            let text = lines.joined(separator: "\n")
            do {
                let result = try MRZParser.parse(text, referenceDate: Self.referenceDate)
                // Parsed: must report checks consistently (allPassed is a pure function of checks).
                let recomputed =
                    result.checks.documentNumber
                    && result.checks.dateOfBirth
                    && result.checks.expiryDate
                    && (result.checks.optionalData ?? true)
                    && result.checks.composite
                #expect(result.checks.allPassed == recomputed)
                #expect(result.rawLines.count == lines.count)
            } catch is MRZError {
                // Expected for most random junk.
            } catch {
                Issue.record("unexpected error type \(error) for junk:\n\(text)")
            }
        }
    }

    @Test("wrong lengths and empty input throw MRZError")
    func structuralRejects() {
        #expect(throws: MRZError.self) {
            try MRZParser.parse("")
        }
        #expect(throws: MRZError.self) {
            try MRZParser.parse("SHORT\nLINE")
        }
        #expect(throws: MRZError.self) {
            try MRZParser.parse(String(repeating: "A", count: 44))  // one line only
        }
        #expect(throws: MRZError.self) {
            try MRZParser.parse(
                String(repeating: "A", count: 44) + "\n" + String(repeating: "B", count: 30)
            )
        }
    }

    // MARK: - Helpers

    private static func randomMRZLine(length: Int, rng: inout SplitMix64) -> String {
        var s = ""
        for _ in 0..<length {
            s.append(mrzAlphabet[Int(rng.next() % UInt64(mrzAlphabet.count))])
        }
        return s
    }
}

// MARK: - Independent ICAO check digit (test oracle)

enum TestMRZCheckDigit {
    static func compute(_ field: String) -> Character {
        let weights = [7, 3, 1]
        var sum = 0
        for (index, character) in field.enumerated() {
            sum += value(of: character) * weights[index % 3]
        }
        return Character(String(sum % 10))
    }

    private static func value(of character: Character) -> Int {
        if character == "<" { return 0 }
        if let digit = character.wholeNumberValue, character.isASCII { return digit }
        guard let ascii = character.asciiValue, (65...90).contains(ascii) else { return 0 }
        return Int(ascii - 65) + 10
    }
}

// MARK: - Valid MRZ generator

struct GeneratedMRZ: Sendable {
    var lines: [String]
    var documentCode: String
    var issuingState: String
    var surname: String
    var givenNames: String
    var documentNumber: String
    var nationality: String
    var dobRaw: String
    var expiryRaw: String
    var sex: String
    var optionalData: String
}

enum MRZGenerator {
    private static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let alnum = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let sexes = Array("MF<")

    static func randomTD3(rng: inout SplitMix64) -> GeneratedMRZ {
        let documentCode = "P<"
        let issuingState = randomCode(rng: &rng)
        let surname = randomName(maxLen: 12, rng: &rng)
        let given = randomName(maxLen: 10, rng: &rng)
        let nameField = pad(encodeName(surname: surname, given: given), to: 39)
        let line1 = pad(documentCode + issuingState + nameField, to: 44)

        let docNumRaw = pad(randomAlnum(length: 1 + Int(rng.next() % 9), rng: &rng), to: 9)
        let docCheck = TestMRZCheckDigit.compute(docNumRaw)
        let nationality = randomCode(rng: &rng)
        let dob = randomDateRaw(rng: &rng)
        let dobCheck = TestMRZCheckDigit.compute(dob)
        let sex = String(sexes[Int(rng.next() % 3)])
        let exp = randomDateRaw(rng: &rng)
        let expCheck = TestMRZCheckDigit.compute(exp)
        let optional = pad(randomAlnum(length: Int(rng.next() % 10), rng: &rng), to: 14)
        let optCheck = TestMRZCheckDigit.compute(optional)

        let compositeRange =
            docNumRaw + String(docCheck) + dob + String(dobCheck) + exp + String(expCheck)
            + optional + String(optCheck)
        let composite = TestMRZCheckDigit.compute(compositeRange)

        let line2 =
            docNumRaw + String(docCheck) + nationality + dob + String(dobCheck) + sex + exp
            + String(expCheck) + optional + String(optCheck) + String(composite)

        return GeneratedMRZ(
            lines: [line1, line2],
            documentCode: stripFillers(documentCode),
            issuingState: stripFillers(issuingState),
            surname: surname,
            givenNames: given,
            documentNumber: stripFillers(docNumRaw),
            nationality: stripFillers(nationality),
            dobRaw: dob,
            expiryRaw: exp,
            sex: sex,
            optionalData: stripFillers(optional)
        )
    }

    static func randomTD2(rng: inout SplitMix64) -> GeneratedMRZ {
        let documentCode = "I<"
        let issuingState = randomCode(rng: &rng)
        let surname = randomName(maxLen: 10, rng: &rng)
        let given = randomName(maxLen: 8, rng: &rng)
        let nameField = pad(encodeName(surname: surname, given: given), to: 31)
        let line1 = pad(documentCode + issuingState + nameField, to: 36)

        let docNumRaw = pad(randomAlnum(length: 1 + Int(rng.next() % 9), rng: &rng), to: 9)
        let docCheck = TestMRZCheckDigit.compute(docNumRaw)
        let nationality = randomCode(rng: &rng)
        let dob = randomDateRaw(rng: &rng)
        let dobCheck = TestMRZCheckDigit.compute(dob)
        let sex = String(sexes[Int(rng.next() % 3)])
        let exp = randomDateRaw(rng: &rng)
        let expCheck = TestMRZCheckDigit.compute(exp)
        let optional = pad(randomAlnum(length: Int(rng.next() % 7), rng: &rng), to: 7)

        let compositeRange =
            docNumRaw + String(docCheck) + dob + String(dobCheck) + exp + String(expCheck) + optional
        let composite = TestMRZCheckDigit.compute(compositeRange)

        let line2 =
            docNumRaw + String(docCheck) + nationality + dob + String(dobCheck) + sex + exp
            + String(expCheck) + optional + String(composite)

        return GeneratedMRZ(
            lines: [line1, line2],
            documentCode: stripFillers(documentCode),
            issuingState: stripFillers(issuingState),
            surname: surname,
            givenNames: given,
            documentNumber: stripFillers(docNumRaw),
            nationality: stripFillers(nationality),
            dobRaw: dob,
            expiryRaw: exp,
            sex: sex,
            optionalData: stripFillers(optional)
        )
    }

    static func randomTD1(rng: inout SplitMix64) -> GeneratedMRZ {
        let documentCode = "I<"
        let issuingState = randomCode(rng: &rng)
        let docNumRaw = pad(randomAlnum(length: 1 + Int(rng.next() % 9), rng: &rng), to: 9)
        let docCheck = TestMRZCheckDigit.compute(docNumRaw)
        let optional1 = pad(randomAlnum(length: Int(rng.next() % 8), rng: &rng), to: 15)
        let line1 = pad(documentCode + issuingState + docNumRaw + String(docCheck) + optional1, to: 30)

        let dob = randomDateRaw(rng: &rng)
        let dobCheck = TestMRZCheckDigit.compute(dob)
        let sex = String(sexes[Int(rng.next() % 3)])
        let exp = randomDateRaw(rng: &rng)
        let expCheck = TestMRZCheckDigit.compute(exp)
        let nationality = randomCode(rng: &rng)
        let optional2 = pad(randomAlnum(length: Int(rng.next() % 6), rng: &rng), to: 11)

        let compositeRange =
            docNumRaw + String(docCheck) + optional1 + dob + String(dobCheck) + exp + String(expCheck)
            + optional2
        let composite = TestMRZCheckDigit.compute(compositeRange)

        let line2 =
            dob + String(dobCheck) + sex + exp + String(expCheck) + nationality + optional2
            + String(composite)

        let surname = randomName(maxLen: 10, rng: &rng)
        let given = randomName(maxLen: 8, rng: &rng)
        let line3 = pad(encodeName(surname: surname, given: given), to: 30)

        return GeneratedMRZ(
            lines: [line1, line2, line3],
            documentCode: stripFillers(documentCode),
            issuingState: stripFillers(issuingState),
            surname: surname,
            givenNames: given,
            documentNumber: stripFillers(docNumRaw),
            nationality: stripFillers(nationality),
            dobRaw: dob,
            expiryRaw: exp,
            sex: sex,
            optionalData: stripFillers(optional1 + optional2)
        )
    }

    /// Flip one character inside a field that contributes to check digits.
    static func mutateCheckedField(lines: [String], format: MRZFormat, rng: inout SplitMix64) -> [String] {
        var result = lines
        // Prefer flipping a check digit — guaranteed to fail that field's check.
        let checkPositions: [(line: Int, index: Int)]
        switch format {
        case .td3:
            checkPositions = [(1, 9), (1, 19), (1, 27), (1, 42), (1, 43)]
        case .td2:
            checkPositions = [(1, 9), (1, 19), (1, 27), (1, 35)]
        case .td1:
            checkPositions = [(0, 14), (1, 6), (1, 14), (1, 29)]
        }
        let pick = checkPositions[Int(rng.next() % UInt64(checkPositions.count))]
        var chars = Array(result[pick.line])
        let original = chars[pick.index]
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ<")
        var next = original
        for _ in 0..<16 {
            let candidate = alphabet[Int(rng.next() % UInt64(alphabet.count))]
            if candidate != original {
                next = candidate
                break
            }
        }
        chars[pick.index] = next
        result[pick.line] = String(chars)
        return result
    }

    // MARK: - Private builders

    private static func encodeName(surname: String, given: String) -> String {
        let primary = surname.replacingOccurrences(of: " ", with: "<")
        let secondary = given.replacingOccurrences(of: " ", with: "<")
        return primary + "<<" + secondary
    }

    private static func randomName(maxLen: Int, rng: inout SplitMix64) -> String {
        let len = 1 + Int(rng.next() % UInt64(max(1, maxLen)))
        var s = ""
        for _ in 0..<len {
            s.append(letters[Int(rng.next() % UInt64(letters.count))])
        }
        return s
    }

    private static func randomCode(rng: inout SplitMix64) -> String {
        var s = ""
        for _ in 0..<3 {
            s.append(letters[Int(rng.next() % UInt64(letters.count))])
        }
        return s
    }

    private static func randomAlnum(length: Int, rng: inout SplitMix64) -> String {
        if length <= 0 { return "" }
        var s = ""
        for _ in 0..<length {
            s.append(alnum[Int(rng.next() % UInt64(alnum.count))])
        }
        return s
    }

    private static func randomDateRaw(rng: inout SplitMix64) -> String {
        // Valid calendar-ish YYMMDD: month 01–12, day 01–28 (always valid).
        let yy = Int(rng.next() % 100)
        let mm = 1 + Int(rng.next() % 12)
        let dd = 1 + Int(rng.next() % 28)
        return String(format: "%02d%02d%02d", yy, mm, dd)
    }

    private static func pad(_ value: String, to length: Int) -> String {
        if value.count >= length {
            return String(value.prefix(length))
        }
        return value + String(repeating: "<", count: length - value.count)
    }

    private static func stripFillers(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "<"))
    }
}
