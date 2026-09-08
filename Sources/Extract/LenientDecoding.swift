import Foundation

extension CodingUserInfoKey {
    /// Locale propagated by ``Extract`` to macro-generated decoders.
    public static let swiftExtractLocale = CodingUserInfoKey(
        rawValue: "com.swift-extract.decoding-locale"
    )!
}

// MARK: - Decoder factory

enum LenientDecoding {
    static func makeDecoder(locale: Locale?) -> JSONDecoder {
        let decoder = JSONDecoder()
        if let locale {
            decoder.userInfo[.swiftExtractLocale] = locale
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let interval = try? container.decode(Double.self) {
                return date(fromUnixTimestamp: interval)
            }
            let string = try container.decode(String.self)
            if let date = parseDate(string, locale: locale) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: \(string)"
            )
        }
        return decoder
    }

    static func parseDate(_ string: String, locale: Locale?) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Any string that opens with `yyyy-MM-dd` (bare date *or* full ISO
        // timestamp) must survive a strict calendar-day check first.
        // `ISO8601DateFormatter` quietly rolls impossible days
        // (`2012-04-31T00:00:00Z` → May 1), which would let a fabricated
        // expiry agree with a real MRZ date.
        if let datePrefix = leadingISODatePrefix(trimmed) {
            guard let strictDay = parseStrictGregorianDateOnly(datePrefix) else {
                return nil
            }
            if isISODateOnlyShape(trimmed) {
                return strictDay
            }
            // Time portion present — fall through to full parsers; day is valid.
        }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: trimmed) {
            return dateMatchingClaimedISODay(date, raw: trimmed)
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) {
            return dateMatchingClaimedISODay(date, raw: trimmed)
        }

        var formats = [
            "yyyy/MM/dd",
            "MMM d, yyyy",
            "MMMM d, yyyy",
            "d MMM yyyy",
            "d MMMM yyyy",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
        ]
        let monthFirst = ["MM/dd/yyyy", "M/d/yyyy", "MM-dd-yyyy"]
        let dayFirst = ["dd/MM/yyyy", "d/M/yyyy", "dd-MM-yyyy"]
        if locale.map(prefersDayBeforeMonth) == true {
            formats.insert(contentsOf: dayFirst + monthFirst, at: 0)
        } else {
            formats.insert(contentsOf: monthFirst + dayFirst, at: 0)
        }

        let formatter = DateFormatter()
        formatter.locale = locale ?? Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    /// Leading `yyyy-MM-dd` when the string is a bare date or an ISO-like
    /// timestamp (`T` / space separator after the day).
    private static func leadingISODatePrefix(_ string: String) -> String? {
        guard string.count >= 10 else { return nil }
        let prefix = String(string.prefix(10))
        guard isISODateOnlyShape(prefix) else { return nil }
        if string.count == 10 { return prefix }
        let separator = string[string.index(string.startIndex, offsetBy: 10)]
        if separator == "T" || separator == "t" || separator == " " {
            return prefix
        }
        return nil
    }

    /// Reject an ISO parse that rolled the claimed calendar day (defense in depth).
    private static func dateMatchingClaimedISODay(_ date: Date, raw: String) -> Date? {
        guard let prefix = leadingISODatePrefix(raw) else { return date }
        let parts = prefix.split(separator: "-")
        guard let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else {
            return nil
        }
        return date
    }

    /// `yyyy-MM-dd` shape check (exactly three numeric groups).
    private static func isISODateOnlyShape(_ string: String) -> Bool {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
            parts[0].count == 4,
            parts[1].count == 2,
            parts[2].count == 2,
            parts[0].allSatisfy(\.isNumber),
            parts[1].allSatisfy(\.isNumber),
            parts[2].allSatisfy(\.isNumber)
        else {
            return false
        }
        return true
    }

    /// Parse `yyyy-MM-dd` and reject dates the calendar would normalise away
    /// (31 Apr, 30 Feb, etc.).
    private static func parseStrictGregorianDateOnly(_ string: String) -> Date? {
        guard isISODateOnlyShape(string) else { return nil }
        let parts = string.split(separator: "-")
        guard let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)

        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else {
            return nil
        }
        return date
    }

    static func parseDecimal(_ string: String, locale: Locale? = nil) -> Decimal? {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Map unambiguous Unicode minus signs to ASCII so "−12" is negative, not +12.
        for minus in ["\u{2212}", "\u{FE63}", "\u{FF0D}"] {
            trimmed = trimmed.replacingOccurrences(of: minus, with: "-")
        }

        // Parenthesised accounting negatives: strip one outer pair, force sign later.
        // Nested / unbalanced parentheses are rejected (not silently turned into a value).
        let parenthesizedNegative =
            trimmed.hasPrefix("(") && trimmed.hasSuffix(")") && trimmed.count >= 2
        if parenthesizedNegative {
            let inner = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.isEmpty || inner.contains("(") || inner.contains(")") {
                return nil
            }
            trimmed = inner
        }

        // Trailing accounting sign (SAP / German invoice style): `"1,12 -"`, `"12-"`.
        // Peeled before digit cleaning so whitespace between the mantissa and the
        // sign is allowed. Two sign sources stay rejected (`-12-`, `(12)-`, `12--`).
        guard let accounting = peelTrailingAccountingSign(trimmed) else {
            return nil
        }
        trimmed = accounting.body
        let trailingSign = accounting.trailingSign
        if trailingSign != nil, parenthesizedNegative {
            return nil
        }

        // Keep only ASCII digits and structural punctuation. Currency, letters,
        // emoji, control chars, and non-ASCII digits are dropped. Non-ASCII digit
        // scripts therefore cannot silently become a value (no ASCII digit left).
        //
        // `e` / `E` immediately after a digit is scientific notation — never strip the
        // letter and concatenate surrounding digits (`"1e10"` must not become `110`).
        // A leading `E` in currency codes like `EUR 12` is not an exponent marker.
        let allowedPunctuation = CharacterSet(charactersIn: ".,+-")
        var cleaned = ""
        var sawScientificExponent = false
        var lastKeptWasDigit = false
        for scalar in trimmed.unicodeScalars {
            if (48...57).contains(scalar.value) {
                cleaned.unicodeScalars.append(scalar)
                lastKeptWasDigit = true
            } else if allowedPunctuation.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
                lastKeptWasDigit = false
            } else if (scalar == "e" || scalar == "E") && lastKeptWasDigit {
                sawScientificExponent = true
                lastKeptWasDigit = false
            } else {
                lastKeptWasDigit = false
            }
        }
        guard cleaned.unicodeScalars.contains(where: { (48...57).contains($0.value) }) else {
            return nil
        }

        let forceNegative = parenthesizedNegative || trailingSign == "-"

        // Model output sometimes emits scientific notation as a *string*. Accept only
        // a strict form; never strip `e` and concatenate surrounding digits.
        if sawScientificExponent {
            return parseScientificDecimal(
                trimmed,
                forceNegative: forceNegative,
                locale: locale,
                trailingSign: trailingSign
            )
        }

        // Lone `e` / `E` (no digit before it) with no other letters — e.g. `"e10"` —
        // must not become `10` via letter-stripping. Currency words like `"EUR 12"`
        // contain non-exponent letters and still use the strip path below.
        let asciiLetters = trimmed.filter { $0.isASCII && $0.isLetter }
        if !asciiLetters.isEmpty,
            asciiLetters.allSatisfy({ $0 == "e" || $0 == "E" })
        {
            return parseScientificDecimal(
                trimmed,
                forceNegative: forceNegative,
                locale: locale,
                trailingSign: trailingSign
            )
        }

        let normalized = normalizeSeparators(in: cleaned, locale: locale)
        guard
            let signed = validatedDecimalLiteral(
                normalized,
                forceNegative: forceNegative,
                trailingSign: trailingSign
            )
        else {
            return nil
        }
        // `Decimal(string:)` is itself lenient (trailing junk, multi-dot truncation).
        // We only call it after structural validation so those paths are unreachable.
        return finiteDecimal(string: signed)
    }

    /// Peel one trailing accounting sign from a decimal token.
    ///
    /// German / SAP-style amounts often print the sign after the digits
    /// (`"1,12 -"` / `"1,12-"` → −1.12). Optional whitespace before the sign is
    /// allowed. A trailing `+` is accepted as an explicit positive marker (SAP
    /// dual-suffix credit/debit display) — a no-op relative to an unsigned value —
    /// because the same printers that emit trailing minus also emit trailing plus.
    /// Multiple trailing signs (`"12--"`, `"12-+"`) return `nil`.
    private static func peelTrailingAccountingSign(
        _ value: String
    ) -> (body: String, trailingSign: Character?)? {
        // Find the last non-whitespace character.
        guard let signIndex = value.lastIndex(where: { !$0.isWhitespace }) else {
            return (value, nil)
        }
        let sign = value[signIndex]
        guard sign == "-" || sign == "+" else {
            return (value, nil)
        }
        let body = String(value[..<signIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A second trailing sign (possibly with spaces) is ambiguous — reject.
        if let prev = body.lastIndex(where: { !$0.isWhitespace }) {
            let prevChar = body[prev]
            if prevChar == "-" || prevChar == "+" {
                // Only reject when that previous sign is *trailing* on the body
                // (e.g. `"12--"`, `"12 - -"`), not a legitimate leading sign
                // (`"-12-"` peels to `"-12"`, handled as two-sign later).
                let afterPrev = body[body.index(after: prev)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if afterPrev.isEmpty {
                    return nil
                }
            }
        }
        return (body, sign)
    }

    /// Maximum absolute decimal exponent accepted for scientific strings.
    ///
    /// Foundation's `Decimal` is backed by `NSDecimal` whose exponent range is
    /// roughly `[-128, 127]`. Anything outside this either traps (on `Int.min`
    /// negation of the loop counter), hangs (billion multiplications), or yields
    /// `Decimal.nan`. Bound early and reject non-finite results after scaling.
    private static let maxScientificExponent = 127

    /// Strict scientific-notation path for strings like `"1.5e3"` / `"1,5e3"` / `"1E-2"`.
    ///
    /// Validates the original token rather than deleting interior characters (which
    /// turned `"1eUSD3"` into `1000` and `"1,5e3"` under `de_DE` into `15000`). The
    /// mantissa is normalised with the caller's locale; the exponent must be a plain
    /// integer with no junk. Trailing accounting signs are peeled by the caller.
    private static func parseScientificDecimal(
        _ raw: String,
        forceNegative: Bool,
        locale: Locale?,
        trailingSign: Character? = nil
    ) -> Decimal? {
        // Exactly one exponent marker in the original token.
        let expMarkers = raw.indices.filter { raw[$0] == "e" || raw[$0] == "E" }
        guard expMarkers.count == 1, let expIndex = expMarkers.first else {
            return nil
        }

        let mantissaRaw = String(raw[..<expIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let exponentRaw = String(raw[raw.index(after: expIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let expInt = parseIntegerExponent(exponentRaw) else {
            return nil
        }
        // Bound before any scaling so `Int.min` never reaches unary minus and a
        // billion-step loop is unreachable. Compare both sides (do not use
        // `abs(expInt)` — `abs(Int.min)` traps).
        guard expInt >= -maxScientificExponent, expInt <= maxScientificExponent else {
            return nil
        }

        guard let mantissaCleaned = cleanScientificMantissa(mantissaRaw) else {
            return nil
        }
        let normalized = normalizeSeparators(in: mantissaCleaned, locale: locale)
        // Trailing sign already applied via `forceNegative`; reject a leading sign
        // in the mantissa when a trailing accounting sign was also present.
        guard
            let mantLiteral = validatedDecimalLiteral(
                normalized,
                forceNegative: false,
                trailingSign: trailingSign
            ),
            var value = finiteDecimal(string: mantLiteral)
        else {
            return nil
        }

        if expInt != 0 {
            // O(1) scale via Decimal's exponent rather than iterative *10 / ÷10.
            let scale = Decimal(sign: .plus, exponent: expInt, significand: 1)
            value *= scale
        }
        if value.isNaN {
            return nil
        }

        // Parentheses / trailing accounting minus mean "negative". If the mantissa
        // is already negative (`(-1e3)`), do not flip it positive.
        if forceNegative, value > 0 {
            value = -value
        }
        return value
    }

    /// Exponent body: optional leading sign and ASCII digits only.
    private static func parseIntegerExponent(_ raw: String) -> Int? {
        guard !raw.isEmpty else { return nil }
        var index = raw.startIndex
        if raw[index] == "+" || raw[index] == "-" {
            index = raw.index(after: index)
        }
        let body = raw[index...]
        guard !body.isEmpty, body.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        // No second sign, no decimal point, no letters (`USD3` fails here).
        return Int(raw)
    }

    /// Keep digits / signs / separators in a scientific mantissa; strip only
    /// leading currency noise. Any interior letter or trailing junk rejects.
    private static func cleanScientificMantissa(_ raw: String) -> String? {
        var cleaned = ""
        var sawDigit = false
        for scalar in raw.unicodeScalars {
            if (48...57).contains(scalar.value) {
                cleaned.unicodeScalars.append(scalar)
                sawDigit = true
            } else if scalar == "." || scalar == "," || scalar == "+" || scalar == "-" {
                cleaned.unicodeScalars.append(scalar)
            } else if scalar == " " || scalar == "\t" {
                continue
            } else if !sawDigit {
                // Leading currency / symbol (e.g. `$`, `€`) — skip.
                continue
            } else {
                // Interior or trailing non-structural character.
                return nil
            }
        }
        guard sawDigit else { return nil }
        return cleaned
    }

    /// `Decimal(string:)` that rejects non-finite results.
    private static func finiteDecimal(string: String) -> Decimal? {
        guard let value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")),
            !value.isNaN
        else {
            return nil
        }
        return value
    }

    /// Accept only a single optional leading sign and a mantissa of digits with at most
    /// one decimal point.
    ///
    /// Trailing accounting signs (`"12-"`, `"1,12 -"`) are peeled by
    /// ``peelTrailingAccountingSign`` before this runs; when `trailingSign` is set,
    /// a leading sign is rejected (two-sign forms like `"-12-"` / `"+12-"`). Also
    /// rejects multi-sign garbage (`--12`, `+-12`) and multi-dot forms that
    /// Foundation would silently truncate.
    private static func validatedDecimalLiteral(
        _ value: String,
        forceNegative: Bool,
        trailingSign: Character? = nil
    ) -> String? {
        var index = value.startIndex
        var sawSign = false
        var negative = false
        while index < value.endIndex {
            let character = value[index]
            if character == "+" {
                if sawSign { return nil }
                sawSign = true
                index = value.index(after: index)
            } else if character == "-" {
                if sawSign { return nil }
                sawSign = true
                negative = true
                index = value.index(after: index)
            } else {
                break
            }
        }

        // Leading sign + trailing accounting sign is ambiguous — do not guess.
        if sawSign, trailingSign != nil {
            return nil
        }

        let body = value[index...]
        guard !body.isEmpty else { return nil }
        // No additional signs anywhere in the mantissa.
        if body.contains(where: { $0 == "+" || $0 == "-" }) { return nil }

        var sawDigit = false
        var sawDot = false
        for character in body {
            if character.isNumber && character.isASCII {
                sawDigit = true
            } else if character == "." {
                if sawDot { return nil }
                sawDot = true
            } else {
                return nil
            }
        }
        guard sawDigit else { return nil }

        let isNegative = forceNegative || negative
        // Avoid producing "--…" if both parenthesised and an inner minus were present:
        // absolute value with a single leading sign.
        if isNegative {
            return "-\(body)"
        }
        return String(body)
    }

    static func date(fromUnixTimestamp interval: Double) -> Date {
        // Contemporary Unix seconds are ~1e9, while milliseconds are ~1e12.
        // Use the absolute value so pre-1970 millisecond timestamps work too.
        let seconds = abs(interval) >= 10_000_000_000 ? interval / 1000 : interval
        return Date(timeIntervalSince1970: seconds)
    }

    private static func prefersDayBeforeMonth(_ locale: Locale) -> Bool {
        guard
            let pattern = DateFormatter.dateFormat(fromTemplate: "Md", options: 0, locale: locale),
            let day = pattern.firstIndex(of: "d"),
            let month = pattern.firstIndex(of: "M")
        else {
            return false
        }
        return day < month
    }

    private static func normalizeSeparators(in value: String, locale: Locale?) -> String {
        let hasDot = value.contains(".")
        let hasComma = value.contains(",")

        if hasDot && hasComma {
            let dot = value.lastIndex(of: ".")!
            let comma = value.lastIndex(of: ",")!
            let decimalSeparator: Character = dot > comma ? "." : ","
            let groupingSeparator: Character = decimalSeparator == "." ? "," : "."
            return
                value
                .replacingOccurrences(of: String(groupingSeparator), with: "")
                .replacingOccurrences(of: String(decimalSeparator), with: ".")
        }

        guard let separator: Character = hasDot ? "." : (hasComma ? "," : nil) else {
            return value
        }
        let separatorString = String(separator)
        let count = value.filter { $0 == separator }.count

        if locale?.decimalSeparator == separatorString, count == 1 {
            return value.replacingOccurrences(of: separatorString, with: ".")
        }
        if locale?.groupingSeparator == separatorString {
            // Locale says this mark is grouping, never decimal:
            // pure grouped integers (`1.234.567`) and a single mark (`12,50` under
            // en_US → `1250`) strip cleanly. Multi-separator forms that are not
            // valid groups fall through (may still be `1.234.56` style).
            if looksLikeGroupedNumber(value, separator: separator) || count == 1 {
                return value.replacingOccurrences(of: separatorString, with: "")
            }
        }
        if count > 1 {
            if looksLikeGroupedNumber(value, separator: separator) {
                return value.replacingOccurrences(of: separatorString, with: "")
            }
            // Same mark used as both grouping and decimal (e.g. `1.234.56`, `1,234,56`)
            // is not a real locale form. Leave multi-separator junk intact so structural
            // validation rejects it rather than guessing a plausible value.
            return value
        }

        // Without a locale, keep the JSON/POSIX convention for dots. A lone
        // comma with one or two fractional digits is normally a decimal comma;
        // three digits is normally a thousands group.
        if separator == "." {
            return value
        }
        guard let index = value.lastIndex(of: separator) else { return value }
        let whole = value[..<index].filter(\.isNumber)
        let fraction = value[value.index(after: index)...]
        if (1...2).contains(fraction.count) || (whole == "0" && !fraction.isEmpty) {
            return value.replacingOccurrences(of: separatorString, with: ".")
        }
        return value.replacingOccurrences(of: separatorString, with: "")
    }

    private static func looksLikeGroupedNumber(_ value: String, separator: Character) -> Bool {
        let groups = value.split(separator: separator, omittingEmptySubsequences: false)
        guard groups.count > 1 else { return false }
        guard isSignedOrPlainDigitGroup(groups[0], maxDigits: 3) else { return false }
        return groups.dropFirst().allSatisfy { group in
            group.count == 3 && group.allSatisfy(\.isNumber)
        }
    }

    private static func isSignedOrPlainDigitGroup<S: StringProtocol>(
        _ group: S,
        maxDigits: Int
    ) -> Bool {
        var body = String(group)
        if body.hasPrefix("+") || body.hasPrefix("-") {
            body = String(body.dropFirst())
        }
        guard !body.isEmpty, body.count <= maxDigits, body.allSatisfy(\.isNumber) else {
            return false
        }
        return true
    }
}

// MARK: - Keyed container helpers (used by generated init(from:))

extension KeyedDecodingContainer {
    public func decodeLenientString(forKey key: Key) throws -> String {
        let raw = try decode(String.self, forKey: key)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func decodeLenientStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeLenientString(forKey: key)
    }

    public func decodeLenientDecimal(forKey key: Key, locale: Locale? = nil) throws -> Decimal {
        if let value = try? decode(Decimal.self, forKey: key) {
            return value
        }
        if let double = try? decode(Double.self, forKey: key) {
            return Decimal(double)
        }
        if let int = try? decode(Int.self, forKey: key) {
            return Decimal(int)
        }
        let string = try decode(String.self, forKey: key)
        if let decimal = LenientDecoding.parseDecimal(string, locale: locale) {
            return decimal
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "Expected decimal number, got '\(string)'"
        )
    }

    public func decodeLenientDecimalIfPresent(forKey key: Key, locale: Locale? = nil) throws -> Decimal? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeLenientDecimal(forKey: key, locale: locale)
    }

    public func decodeLenientDate(forKey key: Key, locale: Locale? = nil) throws -> Date {
        if let date = try? decode(Date.self, forKey: key) {
            // JSONDecoder with default strategy won't parse human dates;
            // try Double epoch first via single-value re-decode path below.
            return date
        }
        if let double = try? decode(Double.self, forKey: key) {
            return LenientDecoding.date(fromUnixTimestamp: double)
        }
        let string = try decode(String.self, forKey: key)
        if let date = LenientDecoding.parseDate(string, locale: locale) {
            return date
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "Expected date, got '\(string)'"
        )
    }

    public func decodeLenientDateIfPresent(forKey key: Key, locale: Locale? = nil) throws -> Date? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeLenientDate(forKey: key, locale: locale)
    }

    public func decodeLenientURL(forKey key: Key) throws -> URL {
        if let url = try? decode(URL.self, forKey: key) {
            return url
        }
        let string = try decode(String.self, forKey: key)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: string) {
            return url
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "Expected URL, got '\(string)'"
        )
    }

    public func decodeLenientURLIfPresent(forKey key: Key) throws -> URL? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeLenientURL(forKey: key)
    }

    public func decodeLenientBool(forKey key: Key) throws -> Bool {
        if let value = try? decode(Bool.self, forKey: key) {
            return value
        }
        if let int = try? decode(Int.self, forKey: key) {
            return int != 0
        }
        let string = try decode(String.self, forKey: key)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch string {
        case "true", "yes", "y", "1": return true
        case "false", "no", "n", "0": return false
        default:
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Expected bool, got '\(string)'"
            )
        }
    }

    public func decodeLenientBoolIfPresent(forKey key: Key) throws -> Bool? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeLenientBool(forKey: key)
    }
}

// MARK: - Top-level decode for Extractable

extension Extractable {
    /// Decode from raw model JSON text using lenient strategies, then enforce
    /// ``validateInvariants()``.
    ///
    /// A successfully returned value has already passed any type-declared
    /// cross-field invariants — the same guarantee as ``Extract/from`` and as
    /// ``Extract/detailed`` / ``Extract/stream`` under ``InvariantPolicy/strict``.
    ///
    /// The extraction loop uses ``decodeExtractedWithoutInvariants(from:locale:)``
    /// and then validates once, so a non-idempotent or expensive validator is
    /// not invoked twice on the same value.
    public static func decodeExtracted(from jsonText: String, locale: Locale? = nil) throws -> Self {
        let value = try decodeExtractedWithoutInvariants(from: jsonText, locale: locale)
        try value.validateInvariants()
        return value
    }

    /// Lenient decode only — does **not** run ``validateInvariants()``.
    ///
    /// Used by the extraction loop so invariants are checked exactly once
    /// (and can still trigger retries). Direct callers should prefer
    /// ``decodeExtracted(from:locale:)``, which enforces invariants.
    public static func decodeExtractedWithoutInvariants(
        from jsonText: String,
        locale: Locale? = nil
    ) throws -> Self {
        let cleaned = JSONFenceStripper.strip(jsonText, expectedRoot: extractionSchema.type)
        guard let data = cleaned.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "JSON text is not valid UTF-8")
            )
        }
        let decoder = LenientDecoding.makeDecoder(locale: locale)
        return try decoder.decode(Self.self, from: data)
    }

    /// Decode a completed-token partial snapshot into ``Partial``.
    ///
    /// `jsonText` is expected to already be closed, valid JSON from
    /// ``CompletedTokenJSON`` (no fence stripping beyond what the assembler did).
    static func decodePartial(
        from jsonText: String,
        locale: Locale? = nil
    ) throws -> Partial {
        guard let data = jsonText.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Partial JSON is not valid UTF-8")
            )
        }
        let decoder = LenientDecoding.makeDecoder(locale: locale)
        return try decoder.decode(Partial.self, from: data)
    }
}

// MARK: - Fence stripping

enum JSONFenceStripper {
    static func strip(
        _ raw: String,
        expectedRoot: ExtractionSchema.SchemaType? = nil
    ) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // ```json ... ``` or ``` ... ```
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            } else {
                text = String(text.dropFirst(3))
            }
            if let range = text.range(of: "```", options: .backwards) {
                text = String(text[..<range.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let container = firstValidContainer(in: text, expectedRoot: expectedRoot) {
            return container
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Upper bound on how many `{` / `[` start positions we will try. Prevents
    /// O(n²) scans over adversarial megabyte floods of open braces.
    private static let maxContainerStartAttempts = 64

    /// Inputs larger than this only attempt extraction from the first opener so a
    /// multi-megabyte preamble + one JSON object stays O(n), while a megabyte of
    /// `{` characters cannot hang the process.
    private static let hugeInputUTF8Threshold = 256_000

    private static func firstValidContainer(
        in text: String,
        expectedRoot: ExtractionSchema.SchemaType?
    ) -> String? {
        let allowedOpeners: Set<Character>
        switch expectedRoot {
        case .object:
            allowedOpeners = ["{"]
        case .array:
            allowedOpeners = ["["]
        default:
            allowedOpeners = ["{", "["]
        }

        let huge = text.utf8.count > hugeInputUTF8Threshold
        var searchStart = text.startIndex
        var attempts = 0
        while searchStart < text.endIndex {
            guard attempts < maxContainerStartAttempts else { return nil }
            guard
                let start = text[searchStart...].firstIndex(where: { allowedOpeners.contains($0) })
            else {
                return nil
            }
            attempts += 1
            if let candidate = balancedContainer(in: text, from: start),
                isValidJSON(candidate)
            {
                return candidate
            }
            // On huge inputs, only the first opener is tried: either the document
            // embeds a complete value starting at the first `{`/`[`, or we give up
            // without walking every subsequent brace (quadratic hang).
            if huge { return nil }
            searchStart = text.index(after: start)
        }
        return nil
    }

    private static func balancedContainer(
        in text: String,
        from start: String.Index
    ) -> String? {
        var stack: [Character] = []
        var inString = false
        var escaped = false
        var index = start

        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{":
                    stack.append("}")
                case "[":
                    stack.append("]")
                case "}", "]":
                    guard stack.last == character else { return nil }
                    stack.removeLast()
                    if stack.isEmpty {
                        return String(text[start...index])
                    }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func isValidJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }
}
