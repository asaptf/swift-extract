import Foundation

/// A JSON-Schema-like description of an extractable type.
///
/// Intentionally close to Foundation Models / AnyLanguageModel generation schemas
/// so a future bridge is straightforward (see `DECISIONS.md`).
public struct ExtractionSchema: Sendable, Equatable, Codable {
    public enum SchemaType: String, Sendable, Equatable, Codable {
        case object
        case string
        case number
        case integer
        case boolean
        case array
        case null
    }

    public var type: SchemaType
    public var title: String?
    public var description: String?
    public var properties: [String: ExtractionSchema]?
    public var required: [String]?
    /// Array item schema stored as a single-element array to avoid recursive
    /// value-type cycles (`Optional<ExtractionSchema>` is not a valid stored property).
    private var itemsStorage: [ExtractionSchema]
    public var enumValues: [String]?
    public var format: String?
    /// Property order for stable prompt rendering.
    public var propertyOrder: [String]?

    public var items: ExtractionSchema? {
        get { itemsStorage.first }
        set {
            if let newValue {
                itemsStorage = [newValue]
            } else {
                itemsStorage = []
            }
        }
    }

    public init(
        type: SchemaType,
        title: String? = nil,
        description: String? = nil,
        properties: [String: ExtractionSchema]? = nil,
        required: [String]? = nil,
        items: ExtractionSchema? = nil,
        enumValues: [String]? = nil,
        format: String? = nil,
        propertyOrder: [String]? = nil
    ) {
        self.type = type
        self.title = title
        self.description = description
        self.properties = properties
        self.required = required
        self.itemsStorage = items.map { [$0] } ?? []
        self.enumValues = enumValues
        self.format = format
        self.propertyOrder = propertyOrder
    }

    enum CodingKeys: String, CodingKey {
        case type, title, description, properties, required, items, format
        case enumValues = "enum"
        case propertyOrder = "x-propertyOrder"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(SchemaType.self, forKey: .type)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        properties = try container.decodeIfPresent([String: ExtractionSchema].self, forKey: .properties)
        required = try container.decodeIfPresent([String].self, forKey: .required)
        if let single = try container.decodeIfPresent(ExtractionSchema.self, forKey: .items) {
            itemsStorage = [single]
        } else {
            itemsStorage = []
        }
        enumValues = try container.decodeIfPresent([String].self, forKey: .enumValues)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        propertyOrder = try container.decodeIfPresent([String].self, forKey: .propertyOrder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(properties, forKey: .properties)
        try container.encodeIfPresent(required, forKey: .required)
        try container.encodeIfPresent(items, forKey: .items)
        try container.encodeIfPresent(enumValues, forKey: .enumValues)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encodeIfPresent(propertyOrder, forKey: .propertyOrder)
    }

    // MARK: - Factories

    public static func object(
        title: String? = nil,
        description: String? = nil,
        properties: [String: ExtractionSchema],
        required: [String],
        propertyOrder: [String]? = nil
    ) -> ExtractionSchema {
        ExtractionSchema(
            type: .object,
            title: title,
            description: description,
            properties: properties,
            required: required,
            propertyOrder: propertyOrder ?? required
        )
    }

    public static func string(
        description: String? = nil,
        format: String? = nil,
        enumValues: [String]? = nil
    ) -> ExtractionSchema {
        ExtractionSchema(
            type: .string,
            description: description,
            enumValues: enumValues,
            format: format
        )
    }

    public static func number(description: String? = nil) -> ExtractionSchema {
        ExtractionSchema(type: .number, description: description)
    }

    public static func integer(description: String? = nil) -> ExtractionSchema {
        ExtractionSchema(type: .integer, description: description)
    }

    public static func boolean(description: String? = nil) -> ExtractionSchema {
        ExtractionSchema(type: .boolean, description: description)
    }

    public static func array(items: ExtractionSchema, description: String? = nil) -> ExtractionSchema {
        ExtractionSchema(type: .array, description: description, items: items)
    }

    public static func null(description: String? = nil) -> ExtractionSchema {
        ExtractionSchema(type: .null, description: description)
    }

    /// Optional wrapper: same schema with a description note that null is allowed.
    public func optional(description: String? = nil) -> ExtractionSchema {
        var copy = self
        let nullNote = "May be null if not present."
        if let description {
            copy.description = description
        } else if let existing = copy.description {
            copy.description = "\(existing) \(nullNote)"
        } else {
            copy.description = nullNote
        }
        return copy
    }

    /// Returns a copy with an overridden description (used by nested schema guides).
    public func withDescription(_ description: String) -> ExtractionSchema {
        var copy = self
        copy.description = description
        return copy
    }


    // MARK: - Rendering

    /// Pretty-printed JSON Schema document suitable for prompts.
    public func renderJSONSchema(prettyPrinted: Bool = true) -> String {
        let object = asJSONObject()
        guard JSONSerialization.isValidJSONObject(object) else {
            return "{}"
        }
        let options: JSONSerialization.WritingOptions =
            prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    public func asJSONObject() -> [String: Any] {
        var dict: [String: Any] = ["type": type.rawValue]
        if let title { dict["title"] = title }
        if let description { dict["description"] = description }
        if let format { dict["format"] = format }
        if let enumValues { dict["enum"] = enumValues }
        if let items { dict["items"] = items.asJSONObject() }
        if let properties {
            let order = propertyOrder ?? Array(properties.keys).sorted()
            var props: [String: Any] = [:]
            for key in order {
                if let schema = properties[key] {
                    props[key] = schema.asJSONObject()
                }
            }
            // Include any keys not listed in order
            for (key, schema) in properties where props[key] == nil {
                props[key] = schema.asJSONObject()
            }
            dict["properties"] = props
        }
        if let required { dict["required"] = required }
        if let propertyOrder { dict["x-propertyOrder"] = propertyOrder }
        return dict
    }

    /// Flattened per-field guide lines for the prompt.
    public func guideLines(prefix: String = "") -> [String] {
        var lines: [String] = []
        if let properties {
            let order = propertyOrder ?? Array(properties.keys).sorted()
            for key in order {
                guard let schema = properties[key] else { continue }
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                if let description = schema.description, !description.isEmpty {
                    lines.append("- `\(path)`: \(description)")
                }
                lines.append(contentsOf: schema.guideLines(prefix: path))
                if schema.type == .array, let items = schema.items {
                    lines.append(contentsOf: items.guideLines(prefix: "\(path)[]"))
                }
            }
        }
        return lines
    }
}
