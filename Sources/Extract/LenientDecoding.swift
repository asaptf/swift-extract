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

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: trimmed) { return date }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }

        let isoDateOnly = ISO8601DateFormatter()
        isoDateOnly.formatOptions = [.withFullDate]
        if let date = isoDateOnly.date(from: trimmed) { return date }

        var formats = [
            "yyyy-MM-dd",
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
            formats.insert(contentsOf: dayFirst + monthFirst, at: 2)
        } else {
            formats.insert(contentsOf: monthFirst + dayFirst, at: 2)
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

        // Model output sometimes emits scientific notation as a *string*. Accept only
        // a strict form; never strip `e` and concatenate surrounding digits.
        if sawScientificExponent {
            return parseScientificDecimal(trimmed, forceNegative: parenthesizedNegative)
        }

        // Lone `e` / `E` (no digit before it) with no other letters — e.g. `"e10"` —
        // must not become `10` via letter-stripping. Currency words like `"EUR 12"`
        // contain non-exponent letters and still use the strip path below.
        let asciiLetters = trimmed.filter { $0.isASCII && $0.isLetter }
        if !asciiLetters.isEmpty,
            asciiLetters.allSatisfy({ $0 == "e" || $0 == "E" })
        {
            return parseScientificDecimal(trimmed, forceNegative: parenthesizedNegative)
        }

        let normalized = normalizeSeparators(in: cleaned, locale: locale)
        guard let signed = validatedDecimalLiteral(normalized, forceNegative: parenthesizedNegative)
        else {
            return nil
        }
        // `Decimal(string:)` is itself lenient (trailing junk, multi-dot truncation).
        // We only call it after structural validation so those paths are unreachable.
        return Decimal(string: signed, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Strict scientific-notation path for strings like `"1.5e3"` / `"1E-2"`.
    private static func parseScientificDecimal(
        _ raw: String,
        forceNegative: Bool
    ) -> Decimal? {
        // Keep digits, sign, dot, and a single exponent letter — drop currency etc.
        var kept = ""
        for scalar in raw.unicodeScalars {
            if (48...57).contains(scalar.value) {
                kept.unicodeScalars.append(scalar)
            } else if scalar == "." || scalar == "+" || scalar == "-" || scalar == "e" || scalar == "E" {
                kept.unicodeScalars.append(scalar)
            }
        }
        // Exactly one exponent marker.
        let exponentMarkers = kept.filter { $0 == "e" || $0 == "E" }
        guard exponentMarkers.count == 1,
            let expIndex = kept.firstIndex(where: { $0 == "e" || $0 == "E" })
        else {
            return nil
        }
        let mantissa = String(kept[..<expIndex])
        let exponent = String(kept[kept.index(after: expIndex)...])
        guard let mantLiteral = validatedDecimalLiteral(mantissa, forceNegative: false),
            let expLiteral = validatedDecimalLiteral(exponent, forceNegative: false),
            // Exponent must be an integer (no fractional part).
            !expLiteral.contains("."),
            let expInt = Int(expLiteral)
        else {
            return nil
        }
        guard var value = Decimal(string: mantLiteral, locale: Locale(identifier: "en_US_POSIX"))
        else {
            return nil
        }
        if expInt > 0 {
            for _ in 0..<expInt {
                value *= 10
            }
        } else if expInt < 0 {
            for _ in 0..<(-expInt) {
                value /= 10
            }
        }
        if forceNegative {
            value = -value
        }
        return value
    }

    /// Accept only a single optional leading sign and a mantissa of digits with at most
    /// one decimal point. Rejects multi-sign garbage (`--12`, `+-12`), trailing signs
    /// (`12-`), and multi-dot forms that Foundation would silently truncate.
    private static func validatedDecimalLiteral(
        _ value: String,
        forceNegative: Bool
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
            // European-style `1.234.56` (last group is a 1–2 digit fraction; earlier
            // groups are thousands). Reject ambiguous multi-separator junk (`1.2.3`).
            if looksLikeGroupedNumberWithDecimalFraction(value, separator: separator) {
                guard let last = value.lastIndex(of: separator) else { return value }
                let whole = value[..<last].filter { $0 != separator }
                let fraction = value[value.index(after: last)...]
                return "\(whole).\(fraction)"
            }
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

    /// Thousands groups plus a short final fractional group, e.g. `1.234.56`.
    private static func looksLikeGroupedNumberWithDecimalFraction(
        _ value: String,
        separator: Character
    ) -> Bool {
        let groups = value.split(separator: separator, omittingEmptySubsequences: false)
        guard groups.count >= 2 else { return false }
        let fraction = groups[groups.count - 1]
        guard (1...2).contains(fraction.count), fraction.allSatisfy(\.isNumber) else {
            return false
        }
        let wholeGroups = groups.dropLast()
        guard let first = wholeGroups.first,
            isSignedOrPlainDigitGroup(first, maxDigits: 3)
        else {
            return false
        }
        return wholeGroups.dropFirst().allSatisfy { group in
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
    /// Decode from raw model JSON text using lenient strategies.
    public static func decodeExtracted(from jsonText: String, locale: Locale? = nil) throws -> Self {
        let cleaned = JSONFenceStripper.strip(jsonText, expectedRoot: extractionSchema.type)
        guard let data = cleaned.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "JSON text is not valid UTF-8")
            )
        }
        let decoder = LenientDecoding.makeDecoder(locale: locale)
        return try decoder.decode(Self.self, from: data)
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
