import Foundation

/// Heuristic quality of a PDF text layer, in `0...1`.
///
/// A garbled OCR layer can be thousands of characters and still be worse than a
/// fresh Vision pass. Under ``TextLayerPolicy/auto``, a page is OCRed when this
/// score is below ``ExtractionOptions/textLayerQualityThreshold`` (default 0.85).
public enum TextLayerQuality {
    public static func score(_ text: String) -> Double {
        let trimmed = withoutFormatCharacters(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return 0
        }

        let scalars = trimmed.unicodeScalars
        let hasReplacement = scalars.contains { $0 == "\u{FFFD}" || isStrayControlCode($0) }

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

    /// The text without its format characters, general category Cf.
    ///
    /// No format character is junk. Each is invisible text the page's author put there: the bidi
    /// marks and isolates of an Arabic or Hebrew line, the non-joiner Persian spelling needs, a
    /// soft hyphen, a byte-order mark, a word joiner, an Arabic number sign, the joiner inside
    /// an emoji. A text layer that lost a glyph's character puts U+FFFD or a control code in its
    /// place, and those still cap the score. That goes for the deprecated format characters
    /// (U+206A–U+206F) and the interlinear annotation anchors (U+FFF9–U+FFFB) too: odd in a PDF,
    /// but they come from whoever made it, not from a misread page.
    ///
    /// Dropped before anything is counted, so a page scores as it would without them. Kept, they
    /// would count as non-letters, and a word with two soft hyphens would stop being a word.
    private static func withoutFormatCharacters(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
    }

    /// A C0 or C1 control code other than a tab or a line break: what a font's raw glyph code
    /// looks like where the text layer lost the character it stood for.
    ///
    /// Not `CharacterSet.controlCharacters`, which on Apple platforms holds every format
    /// character as well, so one right-to-left mark capped a clean Arabic page at 0.3.
    private static func isStrayControlCode(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control && !CharacterSet.whitespacesAndNewlines.contains(scalar)
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
        // Marks and letters no script in the table claims (a combining accent, the modifier-letter
        // apostrophe) take no side, so a Latin word that has one is judged as it always was.
        let scripts = Set(letters.unicodeScalars.compactMap(script(of:)))
        if scripts.isEmpty || scripts == [.latin] {
            return containsLatinVowel(letters)
        }
        // A vowel rule is for Latin: Arabic and Hebrew leave most vowels unwritten, and Chinese
        // has none to write. What gives a garbled word away in any script is a letter from
        // another one.
        return !scripts.contains(.latin) && isOneWritingSystem(scripts)
    }

    private static func looksLikeNumber(_ token: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789.,-+/%")
        guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return false
        }
        return token.contains(where: \.isNumber)
    }

    /// Whether any of the letters is a vowel once its marks are taken off.
    ///
    /// Canonical decomposition takes each mark off the letter it sits on, so á, ợ and ǿ are the a,
    /// o and ø beneath them, and a word is judged the same whether its accents are precomposed or
    /// combining. Every vowel counted before is still one, and a consonant with its marks off is
    /// still a consonant.
    private static func containsLatinVowel<S: StringProtocol>(_ letters: S) -> Bool {
        letters.decomposedStringWithCanonicalMapping.unicodeScalars.contains { latinVowels.contains($0) }
    }

    /// Past a, e, i, o, u and y, the vowels that are letters of their own, with nothing to
    /// decompose to: the ones the CLDR letter sets give Turkish and Azerbaijani (ı, ə), the Nordic
    /// languages and French (æ, ø, œ), and languages of Africa and the Americas (ɛ, ɔ, ǝ, ɨ, ʉ, ɩ,
    /// ʊ). Letters only IPA uses are left out.
    private static let latinVowels: CharacterSet = {
        let vowels = "aeiouy" + "ıəæøœɛɔǝɨʉɩʊ"
        return CharacterSet(charactersIn: vowels + vowels.uppercased())
    }()

    private enum Script {
        case latin, greek, cyrillic, armenian, georgian, hebrew, arabic, syriac, thaana, ethiopic
        case devanagari, bengali, gurmukhi, gujarati, oriya, tamil, telugu, kannada, malayalam, sinhala
        case thai, lao, tibetan, myanmar, khmer
        case han, hiragana, katakana, bopomofo, hangul
    }

    /// Whether one word can hold letters of all these scripts: it can hold one, or the ones a
    /// language writes together. Japanese runs kanji and both kanas into a word, Korean hanja and
    /// hangul, and Chinese glosses characters with bopomofo.
    private static func isOneWritingSystem(_ scripts: Set<Script>) -> Bool {
        scripts.count == 1 || writtenTogether.contains { scripts.isSubset(of: $0) }
    }

    private static let writtenTogether: [Set<Script>] = [
        [.han, .hiragana, .katakana], [.han, .hangul], [.han, .bopomofo],
    ]

    /// The script of the block `scalar` is in, or `nil` for a block the table does not name.
    ///
    /// Blocks rather than the Unicode Script property, which Swift does not expose: a harakah or
    /// a vowel sign sits in its letters' block, and that is all a word needs. A word in a script
    /// left out here is judged as it was before, by the Latin vowel rule.
    private static func script(of scalar: Unicode.Scalar) -> Script? {
        scriptBlocks.first { $0.range.contains(scalar.value) }?.script
    }

    private static let scriptBlocks: [(range: ClosedRange<UInt32>, script: Script)] = [
        (0x0041...0x005A, .latin), (0x0061...0x007A, .latin), (0x00AA...0x00AA, .latin), (0x00BA...0x00BA, .latin),
        (0x00C0...0x02AF, .latin), (0x1E00...0x1EFF, .latin), (0x2C60...0x2C7F, .latin), (0xA720...0xA7FF, .latin),
        (0xAB30...0xAB6F, .latin), (0xFB00...0xFB06, .latin), (0xFF21...0xFF3A, .latin), (0xFF41...0xFF5A, .latin),
        (0x0370...0x03FF, .greek), (0x1F00...0x1FFF, .greek),
        (0x0400...0x052F, .cyrillic), (0x1C80...0x1C8F, .cyrillic), (0x2DE0...0x2DFF, .cyrillic),
        (0xA640...0xA69F, .cyrillic),
        (0x0530...0x058F, .armenian), (0xFB13...0xFB17, .armenian),
        (0x10A0...0x10FF, .georgian), (0x1C90...0x1CBF, .georgian), (0x2D00...0x2D2F, .georgian),
        (0x0590...0x05FF, .hebrew), (0xFB1D...0xFB4F, .hebrew),
        (0x0600...0x06FF, .arabic), (0x0750...0x077F, .arabic), (0x0870...0x08FF, .arabic),
        (0xFB50...0xFDFF, .arabic), (0xFE70...0xFEFF, .arabic),
        (0x0700...0x074F, .syriac), (0x0860...0x086F, .syriac),
        (0x0780...0x07BF, .thaana),
        (0x1200...0x139F, .ethiopic), (0x2D80...0x2DDF, .ethiopic),
        (0x0900...0x097F, .devanagari), (0xA8E0...0xA8FF, .devanagari),
        (0x0980...0x09FF, .bengali), (0x0A00...0x0A7F, .gurmukhi), (0x0A80...0x0AFF, .gujarati),
        (0x0B00...0x0B7F, .oriya), (0x0B80...0x0BFF, .tamil), (0x0C00...0x0C7F, .telugu),
        (0x0C80...0x0CFF, .kannada), (0x0D00...0x0D7F, .malayalam), (0x0D80...0x0DFF, .sinhala),
        (0x0E00...0x0E7F, .thai), (0x0E80...0x0EFF, .lao), (0x0F00...0x0FFF, .tibetan),
        (0x1000...0x109F, .myanmar), (0x1780...0x17FF, .khmer),
        (0x3005...0x3007, .han), (0x3021...0x3029, .han), (0x3038...0x303B, .han), (0x3400...0x4DBF, .han),
        (0x4E00...0x9FFF, .han), (0xF900...0xFAFF, .han), (0x20000...0x323AF, .han),
        (0x3040...0x309F, .hiragana),
        (0x30A0...0x30FF, .katakana), (0x31F0...0x31FF, .katakana), (0xFF66...0xFF9F, .katakana),
        (0x3100...0x312F, .bopomofo), (0x31A0...0x31BF, .bopomofo),
        (0x1100...0x11FF, .hangul), (0x3130...0x318F, .hangul), (0xA960...0xA97F, .hangul),
        (0xAC00...0xD7FF, .hangul), (0xFFA0...0xFFDC, .hangul),
    ]
}
