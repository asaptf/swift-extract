import Foundation

/// Letters a Latin-only reader cannot have meant.
///
/// Measured on the customer invoice: the country of origin `KH` came back as `KН` — Latin `K`
/// followed by U+041D CYRILLIC CAPITAL LETTER EN, which is drawn identically. It failed the
/// ISO 3166 list, the model dropped the field rather than emit it, and three single-row
/// articles lost their country outright.
///
/// This is only ever applied to a pass that asked for Latin-script languages and nothing else.
/// Under that restriction a Cyrillic or Greek character in the output is a glyph the recogniser
/// confused, not a character the page contains — it had no Cyrillic model loaded to read one
/// with. A pass that asks for Arabic, Russian or Greek is left exactly as it read.
enum LatinLookalikes {
    /// Homoglyphs shared between Latin and the Cyrillic and Greek alphabets.
    ///
    /// Only characters that are *drawn the same*, so replacing one can never change what a
    /// person reading the page would see.
    static let map: [Character: Character] = [
        "А": "A", "В": "B", "С": "C", "Е": "E", "Н": "H", "К": "K", "М": "M", "О": "O",
        "Р": "P", "Т": "T", "Х": "X", "У": "Y", "І": "I", "Ј": "J", "Ѕ": "S",
        "а": "a", "с": "c", "е": "e", "о": "o", "р": "p", "х": "x", "у": "y", "ѕ": "s",
        "і": "i", "ј": "j",
        "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K", "Μ": "M",
        "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T", "Υ": "Y", "Χ": "X",
        "ο": "o", "ν": "v",
    ]

    /// Whether a language tag names a language written in the Latin alphabet.
    ///
    /// Unknown tags are treated as not Latin: guessing wrong here would rewrite a page in a
    /// script the caller does know about, and doing nothing only forgoes a repair.
    static func isLatinScript(_ tag: String) -> Bool {
        let language = tag.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
        return latinLanguages.contains(language)
    }

    private static let latinLanguages: Set<String> = [
        "en", "de", "fr", "es", "it", "pt", "nl", "sv", "no", "nb", "nn", "da", "fi", "is",
        "pl", "cs", "sk", "sl", "hr", "hu", "ro", "tr", "et", "lv", "lt", "ga", "cy", "ca",
        "eu", "gl", "af", "sq", "id", "ms", "sw", "vi", "tl", "mt", "lb",
    ]

    /// True when every tag asks for a Latin-script language, and there is at least one.
    ///
    /// An empty list means the recogniser chose for itself, and what it chose is not known
    /// here, so nothing is rewritten.
    static func onlyLatinRequested(_ languages: [String]) -> Bool {
        !languages.isEmpty && languages.allSatisfy(isLatinScript)
    }

    /// `text` with Cyrillic and Greek lookalikes replaced by the Latin letters they are drawn as.
    static func normalised(_ text: String) -> String {
        guard text.contains(where: { map[$0] != nil }) else { return text }
        return String(text.map { map[$0] ?? $0 })
    }
}
