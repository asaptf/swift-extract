import Foundation

/// ICAO 9303 check-digit algorithm (Doc 9303, Part 3).
///
/// Character values: digits `0`–`9` → 0–9, letters `A`–`Z` → 10–35, filler `<` → 0.
/// Weights cycle `7`, `3`, `1`. The check digit is the weighted sum modulo 10.
enum MRZCheckDigit {
    /// Compute the single check digit character (`"0"`…`"9"`) for `field`.
    static func compute(_ field: String) -> Character {
        let weights = [7, 3, 1]
        var sum = 0
        for (index, character) in field.enumerated() {
            sum += value(of: character) * weights[index % 3]
        }
        let digit = sum % 10
        return Character(String(digit))
    }

    /// Whether `expected` matches the check digit computed over `field`.
    static func validates(_ field: String, expected: Character) -> Bool {
        compute(field) == expected
    }

    private static func value(of character: Character) -> Int {
        if character == "<" { return 0 }
        if let digit = character.wholeNumberValue { return digit }
        guard let ascii = character.asciiValue, (65...90).contains(ascii) else {
            // Non-alphabet characters should already have been rejected by the parser.
            return 0
        }
        return Int(ascii - 65) + 10
    }
}
