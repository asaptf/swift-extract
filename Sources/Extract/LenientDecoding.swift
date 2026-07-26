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
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let parenthesizedNegative = trimmed.hasPrefix("(") && trimmed.hasSuffix(")")
        let allowedPunctuation = CharacterSet(charactersIn: ".,+-")
        var cleaned = ""
        for scalar in trimmed.unicodeScalars {
            if (48...57).contains(scalar.value) || allowedPunctuation.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        guard cleaned.unicodeScalars.contains(where: { (48...57).contains($0.value) }) else {
            return nil
        }

        let normalized = normalizeSeparators(in: cleaned, locale: locale)
        let signed =
            parenthesizedNegative && !normalized.hasPrefix("-")
            ? "-\(normalized)"
            : normalized
        return Decimal(string: signed, locale: Locale(identifier: "en_US_POSIX"))
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
            return value.replacingOccurrences(of: separatorString, with: "")
        }
        if count > 1 {
            if looksLikeGroupedNumber(value, separator: separator) {
                return value.replacingOccurrences(of: separatorString, with: "")
            }
            guard let last = value.lastIndex(of: separator) else { return value }
            let whole = value[..<last].filter { $0 != separator }
            let fraction = value[value.index(after: last)...]
            return "\(whole).\(fraction)"
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
        let first = groups[0].filter(\.isNumber)
        guard (1...3).contains(first.count) else { return false }
        return groups.dropFirst().allSatisfy { group in
            group.count == 3 && group.allSatisfy(\.isNumber)
        }
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

        var searchStart = text.startIndex
        while searchStart < text.endIndex {
            guard
                let start = text[searchStart...].firstIndex(where: { allowedOpeners.contains($0) })
            else {
                return nil
            }
            if let candidate = balancedContainer(in: text, from: start),
                isValidJSON(candidate)
            {
                return candidate
            }
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
