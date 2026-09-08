import Foundation

/// Untyped JSON tree produced by schema-driven extraction.
///
/// Numbers are ``Decimal`` so invoice amounts stay exact. Dates with
/// ``ExtractionSchema/format`` `"date"` / `"date-time"` are stored as ISO strings
/// after lenient parse. Use ``Extract/detailed(from:schema:invariants:using:options:)``
/// rather than `Extract.detailed(from:as: JSONValue.self)` — the schema (and optional
/// invariant closure) are task-local for the duration of that call.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var numberValue: Decimal? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

enum DynamicExtractionContext {
    @TaskLocal static var schema: ExtractionSchema = .object(properties: [:], required: [])
    @TaskLocal static var invariants: (@Sendable (JSONValue) throws -> Void)?
}

extension JSONValue: Extractable {
    public nonisolated static var extractionSchema: ExtractionSchema {
        DynamicExtractionContext.schema
    }

    public func validateInvariants() throws {
        try DynamicExtractionContext.invariants?(self)
    }

    public static func decodeExtractedWithoutInvariants(
        from jsonText: String,
        locale: Locale?
    ) throws -> JSONValue {
        let schema = extractionSchema
        let cleaned = JSONFenceStripper.strip(jsonText, expectedRoot: schema.type)
        guard let data = cleaned.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "JSON text is not valid UTF-8")
            )
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Invalid JSON: \(error.localizedDescription)")
            )
        }
        return try SchemaCoercer.coerce(json, schema: schema, locale: locale, path: "")
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Decimal.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let flag):
            try container.encode(flag)
        case .number(let number):
            try container.encode(number)
        case .string(let string):
            try container.encode(string)
        case .array(let items):
            try container.encode(items)
        case .object(let object):
            try container.encode(object)
        }
    }
}
