import Foundation
import Testing

@testable import Extract

@Extractable
private struct AccountingTaxTotal {
    let taxTotal: Decimal
}

/// Adversarial / property coverage for lenient decimal and date parsing.
///
/// These APIs are intentionally forgiving for model and OCR output. Forgiving
/// parsers are also where silent coercion hides — every case here is hunting for
/// "returned a value that is not justified by the input".
@Suite("Lenient decoding fuzz / properties")
struct LenientDecodingFuzzTests {
    /// Fixed seed so any failure is reproducible across hosts.
    private static let seed: UInt64 = 0x51F7_7E01_C0DE_F00D

    // MARK: - Fixed adversarial corpus (decimal)

    private static let digitFreeInputs: [String] = [
        "",
        "   ",
        "\t\n",
        "abc",
        "NaN",
        "nan",
        "Infinity",
        "∞",
        "null",
        "nil",
        "true",
        "false",
        "$",
        "€",
        "£",
        "¥",
        "USD",
        "() ",
        "(abc)",
        "(-)",
        "++++",
        "----",
        "....",
        ",,,,",
        "+,+",
        ".,.",
        "emoji 😀 🎉",
        "−",  // unicode minus alone
        "﹣",
        "－",
        "\u{0000}",
        "\u{200E}\u{200F}",  // LTR/RTL marks
        "١٢٣",  // Arabic-Indic digits only
        "۱۲۳",  // Eastern Arabic-Indic
        "１２３",  // fullwidth digits only
        "Ⅳ",
        "½",
        "no digits here!!!",
        "   \u{00A0}  ",  // nbsp
    ]

    private static let malformedButDigitBearing: [String] = [
        "--12",
        "++12",
        "+-12",
        "-+12",
        "-12-",
        "1-2",
        "+12+",
        "1.2.3",
        "1..2",
        "..12",
        "12..",
        "((12))",
        "0-0",
        "+-0",
        "--0",
        "12.34.56.78",
        "1e",
        "e10",
        "1ee10",
        "1e2.5",  // fractional exponent rejected
        "1e+",
        "e",
        "12--",
        "-12 -",
        "+12-",
        "12-+",
    ]

    private static let wellFormedSamples: [(input: String, locale: Locale?, expected: Decimal)] = [
        ("0", nil, 0),
        ("0.0", nil, Decimal(string: "0.0")!),
        ("12", nil, 12),
        ("12.50", nil, Decimal(string: "12.50")!),
        ("12,50", nil, Decimal(string: "12.50")!),  // lone comma + 2 frac → decimal
        ("$1,234.50", nil, Decimal(string: "1234.50")!),
        ("(12.5)", nil, Decimal(string: "-12.5")!),
        ("(12,50)", nil, Decimal(string: "-12.50")!),
        ("-3.14", nil, Decimal(string: "-3.14")!),
        ("+7", nil, 7),
        ("  42  ", nil, 42),
        ("1.234,56", Locale(identifier: "de_DE"), Decimal(string: "1234.56")!),
        ("1,234.56", Locale(identifier: "en_US"), Decimal(string: "1234.56")!),
        ("−12.5", nil, Decimal(string: "-12.5")!),  // U+2212
        ("﹣9", nil, -9),  // U+FE63
        ("－3.5", nil, Decimal(string: "-3.5")!),  // U+FF0D
        (".5", nil, Decimal(string: "0.5")!),
        ("5.", nil, 5),
        ("1e3", nil, 1000),
        ("1.5E2", nil, 150),
        ("2e-2", nil, Decimal(string: "0.02")!),
        // Trailing accounting notation (SAP / German invoice style).
        ("12-", nil, -12),
        ("12+", nil, 12),
        ("12,50-", nil, Decimal(string: "-12.50")!),
        ("1,12 -", nil, Decimal(string: "-1.12")!),
        ("1,12-", nil, Decimal(string: "-1.12")!),
    ]

    // MARK: - Digit-free never yields

    @Test("digit-free input never yields a decimal")
    func digitFreeNeverYields() {
        for input in Self.digitFreeInputs {
            let once = LenientDecoding.parseDecimal(input)
            let twice = LenientDecoding.parseDecimal(input)
            #expect(once == nil, "digit-free \(input.debugDescription) yielded \(String(describing: once))")
            #expect(once == twice, "non-deterministic on \(input.debugDescription)")
        }
    }

    // MARK: - Malformed digit-bearing must not silently coerce

    @Test("malformed multi-sign / multi-dot forms never yield a value")
    func malformedNeverSilentlyCoerces() {
        for input in Self.malformedButDigitBearing {
            let result = LenientDecoding.parseDecimal(input)
            #expect(
                result == nil,
                "malformed \(input.debugDescription) silently became \(String(describing: result))"
            )
        }
    }

    // MARK: - Well-formed samples

    @Test("well-formed samples parse to expected values")
    func wellFormedSamples() {
        for sample in Self.wellFormedSamples {
            let result = LenientDecoding.parseDecimal(sample.input, locale: sample.locale)
            #expect(
                result == sample.expected,
                "\(sample.input.debugDescription) → \(String(describing: result)), expected \(sample.expected)"
            )
        }
    }

    // MARK: - Locale: 12,50 vs 12.50

    @Test("locale controls 12,50 vs 12.50")
    func localeCommaVsDot() {
        let en = Locale(identifier: "en_US")
        let es = Locale(identifier: "es_ES")
        let de = Locale(identifier: "de_DE")

        // POSIX/JSON convention without locale: dot is decimal.
        #expect(LenientDecoding.parseDecimal("12.50") == Decimal(string: "12.50"))
        // Lone comma with 1–2 fractional digits is treated as decimal when locale is nil.
        #expect(LenientDecoding.parseDecimal("12,50") == Decimal(string: "12.50"))

        // en_US: comma is grouping → 1250; dot is decimal → 12.50
        #expect(LenientDecoding.parseDecimal("12,50", locale: en) == Decimal(string: "1250"))
        #expect(LenientDecoding.parseDecimal("12.50", locale: en) == Decimal(string: "12.50"))

        // es_ES / de_DE: comma is decimal → 12.50; dot may be grouping
        #expect(LenientDecoding.parseDecimal("12,50", locale: es) == Decimal(string: "12.50"))
        #expect(LenientDecoding.parseDecimal("12,50", locale: de) == Decimal(string: "12.50"))
        #expect(LenientDecoding.parseDecimal("12.50", locale: de) == Decimal(string: "1250"))
    }

    // MARK: - Trailing accounting sign (SAP / German invoice notation)

    @Test("trailing minus is accounting negation under comma and dot locales")
    func trailingAccountingMinus() {
        let expected = Decimal(string: "-1.12")
        let en = Locale(identifier: "en_US")  // dot-decimal
        let de = Locale(identifier: "de_DE")  // comma-decimal

        // Corpus document form: "Steuerbetrag in EUR 1,12 -" → −1.12.
        // Comma is the decimal mark in the printed amount; assert under both a
        // comma-decimal locale and the nil/POSIX path (1–2 digit fractional comma).
        for input in ["1,12 -", "1,12-"] {
            #expect(
                LenientDecoding.parseDecimal(input) == expected,
                "nil-locale \(input.debugDescription)"
            )
            #expect(
                LenientDecoding.parseDecimal(input, locale: de) == expected,
                "de_DE \(input.debugDescription)"
            )
        }
        // Dot-decimal locale: same trailing-minus rule on a dot mantissa.
        for input in ["1.12 -", "1.12-"] {
            #expect(
                LenientDecoding.parseDecimal(input, locale: en) == expected,
                "en_US \(input.debugDescription)"
            )
        }

        #expect(LenientDecoding.parseDecimal("12-") == -12)
        #expect(LenientDecoding.parseDecimal("12,50-") == Decimal(string: "-12.50"))
        // Trailing + is SAP dual-suffix positive (no-op).
        #expect(LenientDecoding.parseDecimal("12+") == 12)
        #expect(LenientDecoding.parseDecimal("12,50 +") == Decimal(string: "12.50"))
    }

    /// Boundary table: every hardening rejection that must stay rejected after
    /// trailing-minus acceptance. Kept in one place so the line is visible.
    private static let stillRejectedInputs: [String] = [
        "--12",
        "+-12",
        "++12",
        "1.2.3",
        "1..2",
        "1.234.56",
        "1,234,56",
        "e10",
        "1eUSD3",
        "-12-",
        "12--",
        "-12 -",
        "12 - 5",
        "-",
        "(-1e3-)",  // paren + trailing = two signs
        "+12-",
        "-12+",
    ]

    @Test("hardening rejections stay rejected after trailing-minus acceptance")
    func hardeningRejectionsStillRejected() {
        for input in Self.stillRejectedInputs {
            let result = LenientDecoding.parseDecimal(input)
            #expect(
                result == nil,
                "\(input.debugDescription) should stay rejected, got \(String(describing: result))"
            )
        }
        // Parenthesised forms still negate once (no double negation).
        #expect(LenientDecoding.parseDecimal("(12.50)") == Decimal(string: "-12.50"))
        #expect(LenientDecoding.parseDecimal("(-1e3)") == Decimal(string: "-1000"))
    }

    @Test("public decodeExtracted round-trips trailing-minus taxTotal")
    func trailingMinusRoundTripThroughPublicAPI() throws {
        let json = #"{"taxTotal":"1,12-"}"#
        let value = try AccountingTaxTotal.decodeExtracted(from: json)
        #expect(value.taxTotal == Decimal(string: "-1.12"))

        let spaced = try AccountingTaxTotal.decodeExtracted(from: #"{"taxTotal":"1,12 -"}"#)
        #expect(spaced.taxTotal == Decimal(string: "-1.12"))
    }

    // MARK: - Property: generated adversarial corpus

    @Test("generated corpus: never traps, deterministic, digit-implies-ASCII-digit")
    func generatedDecimalCorpus() {
        var rng = SplitMix64(seed: Self.seed)
        let locales: [Locale?] = [
            nil,
            Locale(identifier: "en_US"),
            Locale(identifier: "es_ES"),
            Locale(identifier: "de_DE"),
            Locale(identifier: "fr_FR"),
        ]

        let corpus = Self.buildAdversarialDecimalCorpus(count: 2_000, rng: &rng)
        for input in corpus {
            let locale = locales[Int(rng.next() % UInt64(locales.count))]
            let a = LenientDecoding.parseDecimal(input, locale: locale)
            let b = LenientDecoding.parseDecimal(input, locale: locale)
            #expect(a == b, "non-deterministic for \(input.debugDescription)")

            if a != nil {
                #expect(
                    Self.containsASCIIDigit(input),
                    "value from input with no ASCII digit: \(input.debugDescription) → \(String(describing: a))"
                )
            }

            if !Self.containsASCIIDigit(input) {
                #expect(
                    a == nil,
                    "digit-free input yielded \(String(describing: a)): \(input.debugDescription)"
                )
            }
        }
    }

    // MARK: - Dates

    @Test("date parsing: empty / junk never yields; known forms work; deterministic")
    func dateProperties() {
        let junk = [
            "", "   ", "not-a-date", "32/13/2020", "2020-13-01", "😀", "null",
            "yesterday", "12345", "----", "00/00/0000",
        ]
        for input in junk {
            let a = LenientDecoding.parseDate(input, locale: nil)
            let b = LenientDecoding.parseDate(input, locale: nil)
            #expect(a == b)
        }
        #expect(LenientDecoding.parseDate("", locale: nil) == nil)
        #expect(LenientDecoding.parseDate("   ", locale: nil) == nil)
        #expect(LenientDecoding.parseDate("not-a-date", locale: nil) == nil)

        #expect(LenientDecoding.parseDate("2020-03-05", locale: nil) != nil)
        #expect(LenientDecoding.parseDate("March 5, 2020", locale: Locale(identifier: "en_US")) != nil)
        #expect(LenientDecoding.parseDate("2020-03-05T12:00:00Z", locale: nil) != nil)

        // Ambiguous 03/04/2020: en_US → March 4; es_ES → 3 April
        let en = LenientDecoding.parseDate("03/04/2020", locale: Locale(identifier: "en_US"))
        let es = LenientDecoding.parseDate("03/04/2020", locale: Locale(identifier: "es_ES"))
        #expect(en != nil && es != nil)
        if let en, let es {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: 0)!
            let enC = cal.dateComponents([.month, .day], from: en)
            let esC = cal.dateComponents([.month, .day], from: es)
            #expect(enC.month == 3 && enC.day == 4)
            #expect(esC.month == 4 && esC.day == 3)
        }

        var rng = SplitMix64(seed: Self.seed ^ 0xD8E)
        for _ in 0..<500 {
            let s = Self.randomJunkString(length: Int(rng.next() % 40), rng: &rng)
            let a = LenientDecoding.parseDate(s, locale: nil)
            let c = LenientDecoding.parseDate(s, locale: nil)
            #expect(a == c, "non-deterministic date parse for \(s.debugDescription)")
            // Alternate locale must not trap.
            _ = LenientDecoding.parseDate(s, locale: Locale(identifier: "en_US"))
        }
    }

    @Test("unix timestamp helper is deterministic for seconds and milliseconds")
    func unixTimestampHelper() {
        let seconds = LenientDecoding.date(fromUnixTimestamp: 1_609_459_200)
        let millis = LenientDecoding.date(fromUnixTimestamp: 1_609_459_200_000)
        #expect(seconds == millis)
        #expect(seconds == LenientDecoding.date(fromUnixTimestamp: 1_609_459_200))
    }

    // MARK: - Corpus builders

    private static func buildAdversarialDecimalCorpus(count: Int, rng: inout SplitMix64) -> [String] {
        var out: [String] = []
        out.append(contentsOf: digitFreeInputs)
        out.append(contentsOf: malformedButDigitBearing)
        out.append(contentsOf: wellFormedSamples.map(\.input))

        let fragments = [
            "", " ", "$", "€", "£", "+", "-", "−", ".", ",", "(", ")",
            "0", "1", "9", "12", "50", "000", "1234", "12.50", "12,50",
            "1.234,56", "1,234.56", "e", "E", "10", "NaN", "null",
            "١٢", "１２", "😀", "\u{0000}", "\u{200E}", "true", "false",
        ]

        while out.count < count {
            let partCount = 1 + Int(rng.next() % 6)
            var s = ""
            for _ in 0..<partCount {
                s += fragments[Int(rng.next() % UInt64(fragments.count))]
            }
            if rng.next() % 5 == 0 {
                s = String(repeating: "9", count: 1 + Int(rng.next() % 80))
            }
            if rng.next() % 7 == 0 {
                s = "(\(s))"
            }
            out.append(s)
        }
        return out
    }

    private static func randomJunkString(length: Int, rng: inout SplitMix64) -> String {
        let alphabet = Array("AZaz09 .-/:TZ$,;()[]{}")
        if length == 0 { return "" }
        var s = ""
        for _ in 0..<length {
            s.append(alphabet[Int(rng.next() % UInt64(alphabet.count))])
        }
        return s
    }

    private static func containsASCIIDigit(_ string: String) -> Bool {
        string.unicodeScalars.contains { (48...57).contains($0.value) }
    }
}

// MARK: - Deterministic PRNG (SplitMix64)

/// Tiny deterministic generator so fuzz failures are reproducible.
struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xDEAD_BEEF_CAFE_BABE : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
