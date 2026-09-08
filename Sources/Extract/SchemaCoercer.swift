import CoreFoundation
import Foundation

/// Walk an ``ExtractionSchema`` and coerce decoded JSON into ``JSONValue`` using the
/// same lenient parsers as macro-generated ``Extractable`` types.
enum SchemaCoercer {
    static func coerce(
        _ json: Any,
        schema: ExtractionSchema,
        locale: Locale?,
        path: String
    ) throws -> JSONValue {
        if json is NSNull {
            return .null
        }
        switch schema.type {
        case .null:
            return .null
        case .string:
            return try coerceString(json, schema: schema, locale: locale, path: path)
        case .number:
            return .number(try coerceDecimal(json, locale: locale, path: path, integer: false))
        case .integer:
            return .number(try coerceDecimal(json, locale: locale, path: path, integer: true))
        case .boolean:
            return .bool(try coerceBool(json, path: path))
        case .array:
            return try coerceArray(json, schema: schema, locale: locale, path: path)
        case .object:
            return try coerceObject(json, schema: schema, locale: locale, path: path)
        }
    }

    private static func coerceObject(
        _ json: Any,
        schema: ExtractionSchema,
        locale: Locale?,
        path: String
    ) throws -> JSONValue {
        guard let dict = json as? [String: Any] else {
            throw typeError(path: path, expected: "object", found: describe(json))
        }
        let properties = schema.properties ?? [:]
        let required = Set(schema.required ?? [])
        var object: [String: JSONValue] = [:]
        let order = schema.propertyOrder ?? Array(properties.keys).sorted()
        var seen = Set<String>()
        for key in order + Array(properties.keys) where !seen.contains(key) {
            seen.insert(key)
            guard let childSchema = properties[key] else { continue }
            let childPath = path.isEmpty ? key : "\(path).\(key)"
            if let raw = dict[key] {
                if raw is NSNull {
                    if required.contains(key) {
                        throw typeError(path: childPath, expected: "value", found: "null")
                    }
                    object[key] = .null
                } else {
                    object[key] = try coerce(raw, schema: childSchema, locale: locale, path: childPath)
                }
            } else if required.contains(key) {
                throw typeError(path: childPath, expected: "value", found: "missing")
            }
        }
        return .object(object)
    }

    private static func coerceArray(
        _ json: Any,
        schema: ExtractionSchema,
        locale: Locale?,
        path: String
    ) throws -> JSONValue {
        guard let array = json as? [Any] else {
            throw typeError(path: path, expected: "array", found: describe(json))
        }
        let itemSchema = schema.items ?? .string()
        var items: [JSONValue] = []
        items.reserveCapacity(array.count)
        for (index, element) in array.enumerated() {
            let childPath = "\(path)[\(index)]"
            items.append(try coerce(element, schema: itemSchema, locale: locale, path: childPath))
        }
        return .array(items)
    }

    private static func coerceString(
        _ json: Any,
        schema: ExtractionSchema,
        locale: Locale?,
        path: String
    ) throws -> JSONValue {
        if schema.format == "date" || schema.format == "date-time" {
            return .string(try coerceDateString(json, format: schema.format, locale: locale, path: path))
        }
        let string: String
        if let value = json as? String {
            string = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let number = jsonNumber(json) {
            string = number.stringValue
        } else if let flag = jsonBool(json) {
            string = flag ? "true" : "false"
        } else {
            throw typeError(path: path, expected: "string", found: describe(json))
        }
        if let allowed = schema.enumValues, !allowed.isEmpty {
            if allowed.contains(string) {
                return .string(string)
            }
            if let match = allowed.first(where: { $0.caseInsensitiveCompare(string) == .orderedSame }) {
                return .string(match)
            }
            throw typeError(path: path, expected: "one of \(allowed.joined(separator: ", "))", found: string)
        }
        return .string(string)
    }

    private static func coerceDateString(
        _ json: Any,
        format: String?,
        locale: Locale?,
        path: String
    ) throws -> String {
        if let date = date(from: json, locale: locale) {
            return format == "date-time" ? isoDateTime(date) : isoDate(date)
        }
        throw typeError(path: path, expected: "date", found: describe(json))
    }

    private static func date(from json: Any, locale: Locale?) -> Date? {
        if let number = jsonNumber(json) {
            return LenientDecoding.date(fromUnixTimestamp: number.doubleValue)
        }
        if let string = json as? String {
            return LenientDecoding.parseDate(string, locale: locale)
        }
        return nil
    }

    private static func coerceDecimal(
        _ json: Any,
        locale: Locale?,
        path: String,
        integer: Bool
    ) throws -> Decimal {
        let decimal: Decimal
        if let number = jsonNumber(json) {
            guard let parsed = Decimal(string: number.stringValue) else {
                throw typeError(path: path, expected: integer ? "integer" : "number", found: describe(json))
            }
            decimal = parsed
        } else if let string = json as? String {
            guard let parsed = LenientDecoding.parseDecimal(string, locale: locale) else {
                throw typeError(path: path, expected: integer ? "integer" : "number", found: string)
            }
            decimal = parsed
        } else if let flag = jsonBool(json) {
            decimal = flag ? 1 : 0
        } else {
            throw typeError(path: path, expected: integer ? "integer" : "number", found: describe(json))
        }
        if integer {
            var value = decimal
            var rounded = Decimal()
            NSDecimalRound(&rounded, &value, 0, .plain)
            if rounded != decimal {
                throw typeError(path: path, expected: "integer", found: "\(decimal)")
            }
            return rounded
        }
        return decimal
    }

    private static func coerceBool(_ json: Any, path: String) throws -> Bool {
        if let flag = jsonBool(json) {
            return flag
        }
        if let number = jsonNumber(json) {
            return number.intValue != 0
        }
        if let string = json as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "y", "1":
                return true
            case "false", "no", "n", "0":
                return false
            default:
                throw typeError(path: path, expected: "bool", found: string)
            }
        }
        throw typeError(path: path, expected: "bool", found: describe(json))
    }

    private static func jsonBool(_ json: Any) -> Bool? {
        if let number = json as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        return json as? Bool
    }

    private static func jsonNumber(_ json: Any) -> NSNumber? {
        if let number = json as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number
        }
        return nil
    }

    private static func typeError(path: String, expected: String, found: String) -> DecodingError {
        let codingPath: [CodingKey] = path.split(separator: ".").flatMap { segment -> [AnyCodingKey] in
            let text = String(segment)
            if text.hasSuffix("]"), let bracket = text.firstIndex(of: "[") {
                let name = String(text[..<bracket])
                let indexText = text[text.index(after: bracket)...].dropLast()
                var keys: [AnyCodingKey] = []
                if !name.isEmpty { keys.append(AnyCodingKey(name)) }
                if let index = Int(indexText) { keys.append(AnyCodingKey(index: index)) }
                return keys
            }
            return [AnyCodingKey(text)]
        }
        return DecodingError.typeMismatch(
            JSONValue.self,
            .init(
                codingPath: codingPath,
                debugDescription: "Expected \(expected) at \(path.isEmpty ? "$" : path), got \(found)"
            )
        )
    }

    private static func describe(_ json: Any) -> String {
        if json is NSNull { return "null" }
        if let flag = jsonBool(json) { return flag ? "true" : "false" }
        if let number = jsonNumber(json) { return number.stringValue }
        if let string = json as? String { return "\"\(string)\"" }
        if json is [Any] { return "array" }
        if json is [String: Any] { return "object" }
        return String(describing: type(of: json))
    }

    private static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func isoDateTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init(index: Int) {
        stringValue = "\(index)"
        intValue = index
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
