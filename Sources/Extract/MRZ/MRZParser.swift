import Foundation

/// Deterministic ICAO 9303 Machine Readable Zone parser with check-digit reporting.
///
/// Parses TD1 (3×30), TD2 (2×36), and TD3 (2×44) layouts. Structural problems throw
/// ``MRZError``; individual check-digit failures are reported on
/// ``MRZResult/checks`` without failing the parse.
///
/// Checksums detect transcription / OCR errors. They are **not** anti-forgery,
/// chip/NFC verification, or identity verification.
public enum MRZParser {
    private static let mrzAlphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<")

    /// Parse a complete MRZ string (lines separated by newlines).
    ///
    /// - Parameters:
    ///   - mrz: Raw MRZ text (one block of 2 or 3 lines).
    ///   - referenceDate: Pivot for two-digit year century resolution.
    public static func parse(
        _ mrz: String,
        referenceDate: Date = Date()
    ) throws -> MRZResult {
        let lines = normalizeLines(mrz)
        return try parse(lines: lines, referenceDate: referenceDate)
    }

    /// Parse already-separated MRZ lines.
    public static func parse(
        lines: [String],
        referenceDate: Date = Date()
    ) throws -> MRZResult {
        let normalized = lines.map { normalizeLine($0) }.filter { !$0.isEmpty }
        guard let format = detectFormat(lines: normalized) else {
            throw MRZError.unsupportedFormat(
                lineCount: normalized.count,
                lineLengths: normalized.map(\.count)
            )
        }
        for (index, line) in normalized.enumerated() {
            if line.unicodeScalars.contains(where: { !mrzAlphabet.contains($0) }) {
                throw MRZError.invalidCharacters(lineIndex: index, line: line)
            }
        }
        switch format {
        case .td1:
            return try parseTD1(normalized, referenceDate: referenceDate)
        case .td2:
            return try parseTD2(normalized, referenceDate: referenceDate)
        case .td3:
            return try parseTD3(normalized, referenceDate: referenceDate)
        }
    }

    /// Locate an MRZ embedded in a larger OCR / plain-text blob and parse it.
    ///
    /// Ignores surrounding prose and blank lines. Candidates are contiguous runs
    /// of MRZ-alphabet lines whose lengths match a supported format.
    ///
    /// When several blocks parse structurally, the candidate with
    /// ``MRZCheckResult/allPassed`` is preferred; otherwise the strongest check
    /// result wins. Returning the first structurally-parseable block would let
    /// MRZ-alphabet OCR noise ahead of a valid passport win with failed checks.
    public static func findAndParse(
        in text: String,
        referenceDate: Date = Date()
    ) throws -> MRZResult {
        let candidates = findCandidateBlocks(in: text)
        var best: MRZResult?
        var bestScore = -1
        for block in candidates {
            guard let result = try? parse(lines: block, referenceDate: referenceDate) else {
                continue
            }
            if result.checks.allPassed {
                return result
            }
            let score = checkScore(result.checks)
            if score > bestScore {
                bestScore = score
                best = result
            }
        }
        if let best {
            return best
        }
        throw MRZError.notFound
    }

    /// Count of checks that passed (optional treated as pass when absent).
    private static func checkScore(_ checks: MRZCheckResult) -> Int {
        var score = 0
        if checks.documentNumber { score += 1 }
        if checks.dateOfBirth { score += 1 }
        if checks.expiryDate { score += 1 }
        if checks.optionalData ?? true { score += 1 }
        if checks.composite { score += 1 }
        return score
    }

    // MARK: - Format detection & normalization

    private static func detectFormat(lines: [String]) -> MRZFormat? {
        guard !lines.isEmpty else { return nil }
        let lengths = Set(lines.map(\.count))
        guard lengths.count == 1, let length = lengths.first else { return nil }
        switch (lines.count, length) {
        case (3, 30): return .td1
        case (2, 36): return .td2
        case (2, 44): return .td3
        default: return nil
        }
    }

    private static func normalizeLines(_ text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { normalizeLine(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeLine(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private static func findCandidateBlocks(in text: String) -> [[String]] {
        let rawLines = text.split(whereSeparator: \.isNewline).map(String.init)
        var mrzLines: [(index: Int, line: String)] = []
        for (index, raw) in rawLines.enumerated() {
            let line = normalizeLine(raw)
            guard !line.isEmpty, line.count >= 30, line.count <= 44 else { continue }
            guard line.unicodeScalars.allSatisfy({ mrzAlphabet.contains($0) }) else { continue }
            mrzLines.append((index, line))
        }

        var blocks: [[String]] = []
        var current: [String] = []
        var lastIndex: Int?

        for item in mrzLines {
            if let last = lastIndex, item.index == last + 1 {
                current.append(item.line)
            } else {
                if current.count >= 2 {
                    blocks.append(current)
                }
                current = [item.line]
            }
            lastIndex = item.index
        }
        if current.count >= 2 {
            blocks.append(current)
        }

        // Sliding windows of 2 and 3 consecutive MRZ-looking lines for any run
        // longer than the target format. A 3-line run that is really noise + TD3
        // must still yield the two-line passport window (`count > 3` previously
        // skipped exactly that case and made `findAndParse` throw `notFound`).
        var expanded: [[String]] = blocks
        for block in blocks where block.count > 2 {
            for start in 0...(block.count - 2) {
                expanded.append(Array(block[start..<(start + 2)]))
                if start + 3 <= block.count {
                    expanded.append(Array(block[start..<(start + 3)]))
                }
            }
        }
        // Prefer longer / more complete candidates first.
        return expanded.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return (lhs.first?.count ?? 0) > (rhs.first?.count ?? 0)
        }
    }

    // MARK: - TD3 (passport, 2 × 44)

    private static func parseTD3(_ lines: [String], referenceDate: Date) throws -> MRZResult {
        let line1 = lines[0]
        let line2 = lines[1]

        let documentCode = stripFillers(substring(line1, 0, 2))
        let issuingState = stripFillers(substring(line1, 2, 5))
        let nameField = substring(line1, 5, 44)
        let names = MRZName.parse(nameField)

        let documentNumberField = substring(line2, 0, 9)
        let documentNumberCheck = character(line2, 9)
        let nationality = stripFillers(substring(line2, 10, 13))
        let dobField = substring(line2, 13, 19)
        let dobCheck = character(line2, 19)
        let sex = String(character(line2, 20))
        let expiryField = substring(line2, 21, 27)
        let expiryCheck = character(line2, 27)
        let optionalField = substring(line2, 28, 42)
        let optionalCheck = character(line2, 42)
        let compositeCheck = character(line2, 43)

        let compositeRange =
            substring(line2, 0, 10)
            + substring(line2, 13, 20)
            + substring(line2, 21, 28)
            + substring(line2, 28, 43)

        let checks = MRZCheckResult(
            documentNumber: MRZCheckDigit.validates(documentNumberField, expected: documentNumberCheck),
            dateOfBirth: MRZCheckDigit.validates(dobField, expected: dobCheck),
            expiryDate: MRZCheckDigit.validates(expiryField, expected: expiryCheck),
            optionalData: MRZCheckDigit.validates(optionalField, expected: optionalCheck),
            composite: MRZCheckDigit.validates(compositeRange, expected: compositeCheck)
        )

        return MRZResult(
            format: .td3,
            rawLines: [line1, line2],
            documentCode: documentCode,
            issuingState: issuingState,
            surname: names.surname,
            givenNames: names.givenNames,
            documentNumber: stripFillers(documentNumberField),
            nationality: nationality,
            dateOfBirth: MRZDateParser.parse(dobField, kind: .birth, referenceDate: referenceDate),
            sex: sex,
            expiryDate: MRZDateParser.parse(expiryField, kind: .expiry, referenceDate: referenceDate),
            optionalData: stripFillers(optionalField),
            checks: checks
        )
    }

    // MARK: - TD2 (2 × 36)

    private static func parseTD2(_ lines: [String], referenceDate: Date) throws -> MRZResult {
        let line1 = lines[0]
        let line2 = lines[1]

        let documentCode = stripFillers(substring(line1, 0, 2))
        let issuingState = stripFillers(substring(line1, 2, 5))
        let nameField = substring(line1, 5, 36)
        let names = MRZName.parse(nameField)

        let documentNumberField = substring(line2, 0, 9)
        let documentNumberCheck = character(line2, 9)
        let nationality = stripFillers(substring(line2, 10, 13))
        let dobField = substring(line2, 13, 19)
        let dobCheck = character(line2, 19)
        let sex = String(character(line2, 20))
        let expiryField = substring(line2, 21, 27)
        let expiryCheck = character(line2, 27)
        let optionalField = substring(line2, 28, 35)
        let compositeCheck = character(line2, 35)

        // Composite: doc(9)+cd(1) + dob(6)+cd(1) + exp(6)+cd(1) + optional(7)
        let compositeRange =
            substring(line2, 0, 10)
            + substring(line2, 13, 20)
            + substring(line2, 21, 35)

        let checks = MRZCheckResult(
            documentNumber: MRZCheckDigit.validates(documentNumberField, expected: documentNumberCheck),
            dateOfBirth: MRZCheckDigit.validates(dobField, expected: dobCheck),
            expiryDate: MRZCheckDigit.validates(expiryField, expected: expiryCheck),
            optionalData: nil,
            composite: MRZCheckDigit.validates(compositeRange, expected: compositeCheck)
        )

        return MRZResult(
            format: .td2,
            rawLines: [line1, line2],
            documentCode: documentCode,
            issuingState: issuingState,
            surname: names.surname,
            givenNames: names.givenNames,
            documentNumber: stripFillers(documentNumberField),
            nationality: nationality,
            dateOfBirth: MRZDateParser.parse(dobField, kind: .birth, referenceDate: referenceDate),
            sex: sex,
            expiryDate: MRZDateParser.parse(expiryField, kind: .expiry, referenceDate: referenceDate),
            optionalData: stripFillers(optionalField),
            checks: checks
        )
    }

    // MARK: - TD1 (3 × 30)

    private static func parseTD1(_ lines: [String], referenceDate: Date) throws -> MRZResult {
        let line1 = lines[0]
        let line2 = lines[1]
        let line3 = lines[2]

        let documentCode = stripFillers(substring(line1, 0, 2))
        let issuingState = stripFillers(substring(line1, 2, 5))
        let documentNumberField = substring(line1, 5, 14)
        let documentNumberCheck = character(line1, 14)
        let optional1 = substring(line1, 15, 30)

        let dobField = substring(line2, 0, 6)
        let dobCheck = character(line2, 6)
        let sex = String(character(line2, 7))
        let expiryField = substring(line2, 8, 14)
        let expiryCheck = character(line2, 14)
        let nationality = stripFillers(substring(line2, 15, 18))
        let optional2 = substring(line2, 18, 29)
        let compositeCheck = character(line2, 29)

        let names = MRZName.parse(line3)

        // Composite: line1[5..<30] + line2[0..<7] + line2[8..<15] + line2[18..<29]
        let compositeRange =
            substring(line1, 5, 30)
            + substring(line2, 0, 7)
            + substring(line2, 8, 15)
            + substring(line2, 18, 29)

        let checks = MRZCheckResult(
            documentNumber: MRZCheckDigit.validates(documentNumberField, expected: documentNumberCheck),
            dateOfBirth: MRZCheckDigit.validates(dobField, expected: dobCheck),
            expiryDate: MRZCheckDigit.validates(expiryField, expected: expiryCheck),
            optionalData: nil,
            composite: MRZCheckDigit.validates(compositeRange, expected: compositeCheck)
        )

        let optionalCombined = stripFillers(optional1 + optional2)

        return MRZResult(
            format: .td1,
            rawLines: [line1, line2, line3],
            documentCode: documentCode,
            issuingState: issuingState,
            surname: names.surname,
            givenNames: names.givenNames,
            documentNumber: stripFillers(documentNumberField),
            nationality: nationality,
            dateOfBirth: MRZDateParser.parse(dobField, kind: .birth, referenceDate: referenceDate),
            sex: sex,
            expiryDate: MRZDateParser.parse(expiryField, kind: .expiry, referenceDate: referenceDate),
            optionalData: optionalCombined,
            checks: checks
        )
    }

    // MARK: - String helpers

    private static func substring(_ line: String, _ start: Int, _ end: Int) -> String {
        let chars = Array(line)
        guard start >= 0, end <= chars.count, start <= end else { return "" }
        return String(chars[start..<end])
    }

    private static func character(_ line: String, _ index: Int) -> Character {
        let chars = Array(line)
        guard index >= 0, index < chars.count else { return "<" }
        return chars[index]
    }

    private static func stripFillers(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "<"))
    }
}
