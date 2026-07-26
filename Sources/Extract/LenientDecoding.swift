import Foundation

// MARK: - Decoder factory

enum LenientDecoding {
    static func makeDecoder(locale: Locale?) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let interval = try? container.decode(Double.self) {
                // Heuristic: ms vs s
                if interval > 1_000_000_000_000 {
                    return Date(timeIntervalSince1970: interval / 1000)
                }
                return Date(timeIntervalSince1970: interval)
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

        let formats = [
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "MM/dd/yyyy",
            "M/d/yyyy",
            "dd/MM/yyyy",
            "d/M/yyyy",
            "MMM d, yyyy",
            "MMMM d, yyyy",
            "d MMM yyyy",
            "d MMMM yyyy",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "MM-dd-yyyy",
            "dd-MM-yyyy",
        ]

        let formatter = DateFormatter()
        formatter.locale = locale ?? Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    static func parseDecimal(_ string: String) -> Decimal? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // Strip currency symbols and thousands separators commonly seen on receipts.
        var cleaned = trimmed
        let currencyScalars = CharacterSet(charactersIn: "$€£¥₹₩₪₫₴₦₱₡₵₺")
        cleaned = cleaned.components(separatedBy: currencyScalars).joined()
        cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: cleaned)
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

    public func decodeLenientDecimal(forKey key: Key) throws -> Decimal {
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
        if let decimal = LenientDecoding.parseDecimal(string) {
            return decimal
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "Expected decimal number, got '\(string)'"
        )
    }

    public func decodeLenientDecimalIfPresent(forKey key: Key) throws -> Decimal? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeLenientDecimal(forKey: key)
    }

    public func decodeLenientDate(forKey key: Key, locale: Locale? = nil) throws -> Date {
        if let date = try? decode(Date.self, forKey: key) {
            // JSONDecoder with default strategy won't parse human dates;
            // try Double epoch first via single-value re-decode path below.
            return date
        }
        if let double = try? decode(Double.self, forKey: key) {
            if double > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: double / 1000)
            }
            return Date(timeIntervalSince1970: double)
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
        let cleaned = JSONFenceStripper.strip(jsonText)
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
    static func strip(_ raw: String) -> String {
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
        // Leading prose before first { or [
        if let obj = text.firstIndex(of: "{"), let arr = text.firstIndex(of: "[") {
            let start = min(obj, arr)
            text = String(text[start...])
        } else if let obj = text.firstIndex(of: "{") {
            text = String(text[obj...])
        } else if let arr = text.firstIndex(of: "[") {
            text = String(text[arr...])
        }
        // Trailing prose after last } or ]
        if let lastObj = text.lastIndex(of: "}"), let lastArr = text.lastIndex(of: "]") {
            let end = max(lastObj, lastArr)
            text = String(text[...end])
        } else if let lastObj = text.lastIndex(of: "}") {
            text = String(text[...lastObj])
        } else if let lastArr = text.lastIndex(of: "]") {
            text = String(text[...lastArr])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
