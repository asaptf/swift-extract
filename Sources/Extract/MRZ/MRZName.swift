import Foundation

/// ICAO name field decoding (primary identifier `<<` secondary identifiers).
enum MRZName {
    /// Split a name field into surname and given names.
    ///
    /// - Primary identifier (surname) precedes `<<`.
    /// - Secondary identifiers (given names) follow; `<` is a space separator.
    /// - Trailing `<` padding is discarded.
    /// - Returns uppercase strings with internal whitespace collapsed and ends trimmed.
    static func parse(_ field: String) -> (surname: String, givenNames: String) {
        let trimmedField = field.trimmingCharacters(in: CharacterSet(charactersIn: "<"))
        guard !trimmedField.isEmpty else {
            return ("", "")
        }

        let parts: [String]
        if let range = field.range(of: "<<") {
            let primary = String(field[field.startIndex..<range.lowerBound])
            let secondary = String(field[range.upperBound...])
            parts = [primary, secondary]
        } else {
            parts = [field, ""]
        }

        let surname = cleanIdentifier(parts[0])
        let givenNames = cleanIdentifier(parts[1])
        return (surname, givenNames)
    }

    private static func cleanIdentifier(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
