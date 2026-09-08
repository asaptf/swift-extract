import Foundation

/// Heuristic quality of a PDF text layer, in `0...1`.
///
/// A garbled OCR layer can be thousands of characters and still be worse than a
/// fresh Vision pass. Under ``TextLayerPolicy/auto``, a page is OCRed when this
/// score is below ``ExtractionOptions/textLayerQualityThreshold`` (default 0.85).
public enum TextLayerQuality {
    public static func score(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return 0
        }

        let scalars = trimmed.unicodeScalars
        let junkControls = CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines)
        let hasReplacement = scalars.contains { $0 == "\u{FFFD}" || junkControls.contains($0) }

        let nonSpace = scalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !nonSpace.isEmpty else {
            return 0
        }
        let alnum = nonSpace.filter { CharacterSet.alphanumerics.contains($0) }.count
        let alnumRatio = Double(alnum) / Double(nonSpace.count)

        let tokens = trimmed.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else {
            return alnumRatio
        }
        let wellFormed = tokens.filter { isWellFormed(String($0)) }.count
        let tokenRatio = Double(wellFormed) / Double(tokens.count)

        var score = 0.5 * alnumRatio + 0.5 * tokenRatio
        if hasReplacement {
            score = min(score, 0.3)
        }
        return min(max(score, 0), 1)
    }

    static func shouldOCR(
        text: String,
        policy: TextLayerPolicy,
        threshold: Double
    ) -> Bool {
        switch policy {
        case .always:
            return false
        case .never:
            return true
        case .auto:
            return score(text) < threshold
        }
    }

    static func isWellFormed(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .punctuationCharacters)
        if trimmed.isEmpty {
            return false
        }
        if looksLikeNumber(trimmed) {
            return true
        }
        if trimmed.allSatisfy(\.isNumber), trimmed.count >= 2 {
            return true
        }
        let letters = trimmed.filter(\.isLetter)
        guard letters.count >= 2, letters.count >= trimmed.count - 1 else {
            return false
        }
        return containsLatinVowel(letters)
    }

    private static func looksLikeNumber(_ token: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789.,-+/%")
        guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return false
        }
        return token.contains(where: \.isNumber)
    }

    private static func containsLatinVowel<S: StringProtocol>(_ letters: S) -> Bool {
        let vowels = CharacterSet(charactersIn: "aeiouAEIOUäöüÄÖÜàèéìòùyY")
        return letters.unicodeScalars.contains { vowels.contains($0) }
    }
}
