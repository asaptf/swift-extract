import ExtractMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class ExtractableMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Extractable": ExtractableMacro.self,
        "Guide": GuideMacro.self,
    ]

    func testBasicStringAndInt() {
        assertMacroExpansion(
            """
            @Extractable
            struct Person {
                let name: String
                let age: Int
            }
            """,
            expandedSource: """
                struct Person {
                    let name: String
                    let age: Int

                    public enum CodingKeys: String, CodingKey {
                        case name
                        case age
                    }

                    public nonisolated static var extractionSchema: ExtractionSchema {
                        .object(
                            title: "Person",
                            properties: [
                                "name": .string(),
                                "age": .integer()
                            ],
                            required: ["name", "age"],
                            propertyOrder: ["name", "age"]
                        )
                    }
                }

                extension Person: Extractable, Codable, Sendable {
                    public init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        self.name = try container.decodeLenientString(forKey: .name)
                        self.age = try container.decode(Int.self, forKey: .age)
                    }
                    public func encode(to encoder: Encoder) throws {
                        var container = encoder.container(keyedBy: CodingKeys.self)
                        try container.encode(self.name, forKey: .name)
                        try container.encode(self.age, forKey: .age)
                    }
                }
                """,
            macros: macros
        )
    }

    func testGuideOptionalDateDecimalURL() {
        assertMacroExpansion(
            """
            @Extractable
            struct Payment {
                @Guide("ISO currency") let currency: String
                let amount: Decimal
                let due: Date
                let link: URL?
            }
            """,
            expandedSource: """
                struct Payment {
                    let currency: String
                    let amount: Decimal
                    let due: Date
                    let link: URL?

                    public enum CodingKeys: String, CodingKey {
                        case currency
                        case amount
                        case due
                        case link
                    }

                    public nonisolated static var extractionSchema: ExtractionSchema {
                        .object(
                            title: "Payment",
                            properties: [
                                "currency": .string(description: "ISO currency"),
                                "amount": .number(),
                                "due": .string(format: "date-time"),
                                "link": .string(format: "uri").optional()
                            ],
                            required: ["currency", "amount", "due"],
                            propertyOrder: ["currency", "amount", "due", "link"]
                        )
                    }
                }

                extension Payment: Extractable, Codable, Sendable {
                    public init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        let extractionLocale = decoder.userInfo[.swiftExtractLocale] as? Locale
                        self.currency = try container.decodeLenientString(forKey: .currency)
                        self.amount = try container.decodeLenientDecimal(forKey: .amount, locale: extractionLocale)
                        self.due = try container.decodeLenientDate(forKey: .due)
                        self.link = try container.decodeLenientURLIfPresent(forKey: .link)
                    }
                    public func encode(to encoder: Encoder) throws {
                        var container = encoder.container(keyedBy: CodingKeys.self)
                        try container.encode(self.currency, forKey: .currency)
                        try container.encode(self.amount, forKey: .amount)
                        try container.encode(self.due, forKey: .due)
                        try container.encodeIfPresent(self.link, forKey: .link)
                    }
                }
                """,
            macros: macros
        )
    }

    func testArrayAndBool() {
        assertMacroExpansion(
            """
            @Extractable
            struct Flags {
                let enabled: Bool
                let tags: [String]
            }
            """,
            expandedSource: """
                struct Flags {
                    let enabled: Bool
                    let tags: [String]

                    public enum CodingKeys: String, CodingKey {
                        case enabled
                        case tags
                    }

                    public nonisolated static var extractionSchema: ExtractionSchema {
                        .object(
                            title: "Flags",
                            properties: [
                                "enabled": .boolean(),
                                "tags": .array(items: .string())
                            ],
                            required: ["enabled", "tags"],
                            propertyOrder: ["enabled", "tags"]
                        )
                    }
                }

                extension Flags: Extractable, Codable, Sendable {
                    public init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        self.enabled = try container.decodeLenientBool(forKey: .enabled)
                        self.tags = try container.decode([String].self, forKey: .tags)
                    }
                    public func encode(to encoder: Encoder) throws {
                        var container = encoder.container(keyedBy: CodingKeys.self)
                        try container.encode(self.enabled, forKey: .enabled)
                        try container.encode(self.tags, forKey: .tags)
                    }
                }
                """,
            macros: macros
        )
    }

    func testNestedTypeSchemaReference() {
        assertMacroExpansion(
            """
            @Extractable
            struct Parent {
                let child: Child
            }
            """,
            expandedSource: """
                struct Parent {
                    let child: Child

                    public enum CodingKeys: String, CodingKey {
                        case child
                    }

                    public nonisolated static var extractionSchema: ExtractionSchema {
                        .object(
                            title: "Parent",
                            properties: [
                                "child": Child.extractionSchema
                            ],
                            required: ["child"],
                            propertyOrder: ["child"]
                        )
                    }
                }

                extension Parent: Extractable, Codable, Sendable {
                    public init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        self.child = try container.decode(Child.self, forKey: .child)
                    }
                    public func encode(to encoder: Encoder) throws {
                        var container = encoder.container(keyedBy: CodingKeys.self)
                        try container.encode(self.child, forKey: .child)
                    }
                }
                """,
            macros: macros
        )
    }

    func testUnsupportedDictionaryDiagnoses() {
        assertMacroExpansion(
            """
            @Extractable
            struct Bad {
                let map: [String: Int]
            }
            """,
            expandedSource: """
                struct Bad {
                    let map: [String: Int]

                    public enum CodingKeys: String, CodingKey {
                    }

                    public nonisolated static var extractionSchema: ExtractionSchema {
                        .object(
                            title: "Bad",
                            properties: [:],
                            required: [String](),
                            propertyOrder: [String]()
                        )
                    }
                }

                extension Bad: Extractable, Codable, Sendable {
                    public init(from decoder: Decoder) throws {
                        let _ = try decoder.container(keyedBy: CodingKeys.self)
                    }
                    public func encode(to encoder: Encoder) throws {
                        var container = encoder.container(keyedBy: CodingKeys.self)
                        _ = container
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Extractable does not support property `map` of type `[String: Int]`. Supported: String, Bool, integer/float types, Decimal, Date, URL, Optional, Array, nested @Extractable types, and String-backed enums providing extractionSchema.",
                    line: 3,
                    column: 14
                )
            ],
            macros: macros
        )
    }

    func testUnsupportedUUIDDiagnoses() {
        assertMacroExpansion(
            """
            @Extractable
            struct WithUUID {
                let id: UUID
                let name: String
            }
            """,
            expandedSource: """
                struct WithUUID {
                    let id: UUID
                    let name: String

                    public enum CodingKeys: String, CodingKey {
                        case name
                    }

                    public nonisolated static var extractionSchema: ExtractionSchema {
                        .object(
                            title: "WithUUID",
                            properties: [
                                "name": .string()
                            ],
                            required: ["name"],
                            propertyOrder: ["name"]
                        )
                    }
                }

                extension WithUUID: Extractable, Codable, Sendable {
                    public init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        self.name = try container.decodeLenientString(forKey: .name)
                    }
                    public func encode(to encoder: Encoder) throws {
                        var container = encoder.container(keyedBy: CodingKeys.self)
                        try container.encode(self.name, forKey: .name)
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Extractable does not support property `id` of type `UUID`. Supported: String, Bool, integer/float types, Decimal, Date, URL, Optional, Array, nested @Extractable types, and String-backed enums providing extractionSchema.",
                    line: 3,
                    column: 13
                )
            ],
            macros: macros
        )
    }

    func testInitializedLetDiagnoses() {
        assertMacroExpansion(
            """
            @Extractable
            struct Defaults {
                let name: String = "unknown"
            }
            """,
            expandedSource: """
                struct Defaults {
                    let name: String = "unknown"

                    public enum CodingKeys: String, CodingKey {
                    }

                    public nonisolated static var extractionSchema: ExtractionSchema {
                        .object(
                            title: "Defaults",
                            properties: [:],
                            required: [String](),
                            propertyOrder: [String]()
                        )
                    }
                }

                extension Defaults: Extractable, Codable, Sendable {
                    public init(from decoder: Decoder) throws {
                        let _ = try decoder.container(keyedBy: CodingKeys.self)
                    }
                    public func encode(to encoder: Encoder) throws {
                        var container = encoder.container(keyedBy: CodingKeys.self)
                        _ = container
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Property `name` is a let constant with a default value and cannot be decoded. Remove the default value or change it to var.",
                    line: 3,
                    column: 9
                )
            ],
            macros: macros
        )
    }

    func testEnumDiagnoses() {
        assertMacroExpansion(
            """
            @Extractable
            enum Status {
                case ready
            }
            """,
            expandedSource: """
                enum Status {
                    case ready
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Extractable can only be applied to a struct.",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    func testGuideInterpolationDiagnoses() {
        assertMacroExpansion(
            """
            struct Guided {
                @Guide("value \\(1)") let name: String
            }
            """,
            expandedSource: """
                struct Guided {
                    let name: String
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Guide requires a static string literal without interpolation.",
                    line: 2,
                    column: 5
                )
            ],
            macros: macros
        )
    }
}
