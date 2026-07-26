import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ExtractableMacro: MemberMacro, ExtensionMacro {
    // MARK: - Members

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let typeName = try typeName(of: declaration)
        // Diagnose unsupported properties only here (member expansion) to avoid duplicates.
        let properties = try extractProperties(from: declaration, in: context, diagnose: true)
        return [
            generateCodingKeys(properties: properties),
            generateExtractionSchema(typeName: typeName, properties: properties),
        ]
    }

    // MARK: - Extension

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let properties = try extractProperties(from: declaration, in: context, diagnose: false)
        let initFrom = generateInitFrom(properties: properties)
        let encodeTo = generateEncodeTo(properties: properties)

        let extensionDecl: DeclSyntax = """
            extension \(type.trimmed): Extractable, Codable, Sendable {
                \(initFrom)
                \(encodeTo)
            }
            """

        guard let ext = extensionDecl.as(ExtensionDeclSyntax.self) else {
            return []
        }
        return [ext]
    }

    // MARK: - Models

    struct PropertyInfo {
        var name: String
        var typeSyntax: TypeSyntax
        var isOptional: Bool
        var guide: String?
        var baseTypeSyntax: TypeSyntax
    }

    // MARK: - Parsing

    private static func typeName(of declaration: some DeclGroupSyntax) throws -> String {
        if let s = declaration.as(StructDeclSyntax.self) {
            return s.name.text
        }
        if let e = declaration.as(EnumDeclSyntax.self) {
            return e.name.text
        }
        throw MacroError.message("@Extractable can only be applied to a struct.")
    }

    private static func extractProperties(
        from declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext,
        diagnose: Bool
    ) throws -> [PropertyInfo] {
        var result: [PropertyInfo] = []
        for member in declaration.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            if varDecl.modifiers.contains(where: { $0.name.text == "static" }) { continue }
            for binding in varDecl.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    continue
                }
                if binding.accessorBlock != nil { continue }
                guard let typeAnnotation = binding.typeAnnotation?.type else {
                    if diagnose {
                        context.diagnose(
                            Diagnostic(
                                node: Syntax(binding),
                                message: MacroDiagnostic.missingType(pattern.identifier.text)
                            )
                        )
                    }
                    continue
                }
                let guide = extractGuide(from: varDecl.attributes)
                let (isOptional, base) = unwrapOptional(typeAnnotation)
                if !isSupportedType(base) {
                    if diagnose {
                        context.diagnose(
                            Diagnostic(
                                node: Syntax(typeAnnotation),
                                message: MacroDiagnostic.unsupportedType(
                                    property: pattern.identifier.text,
                                    typeName: base.trimmedDescription
                                )
                            )
                        )
                    }
                    continue
                }
                result.append(
                    PropertyInfo(
                        name: pattern.identifier.text,
                        typeSyntax: typeAnnotation,
                        isOptional: isOptional,
                        guide: guide,
                        baseTypeSyntax: base
                    )
                )
            }
        }
        return result
    }

    private static func extractGuide(from attributes: AttributeListSyntax) -> String? {
        for attribute in attributes {
            guard let attr = attribute.as(AttributeSyntax.self) else { continue }
            guard attr.attributeName.trimmedDescription == "Guide" else { continue }
            guard let arguments = attr.arguments?.as(LabeledExprListSyntax.self),
                let first = arguments.first,
                let literal = first.expression.as(StringLiteralExprSyntax.self)
            else {
                continue
            }
            return stringLiteralValue(literal)
        }
        return nil
    }

    private static func stringLiteralValue(_ literal: StringLiteralExprSyntax) -> String {
        var result = ""
        for segment in literal.segments {
            if let s = segment.as(StringSegmentSyntax.self) {
                result += s.content.text
            }
        }
        return result
    }

    private static func unwrapOptional(_ type: TypeSyntax) -> (Bool, TypeSyntax) {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return (true, optional.wrappedType)
        }
        if let iuo = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return (true, iuo.wrappedType)
        }
        if let ident = type.as(IdentifierTypeSyntax.self),
            ident.name.text == "Optional",
            let generic = ident.genericArgumentClause?.arguments.first
        {
            let argType = TypeSyntax(stringLiteral: generic.argument.trimmedDescription)
            return (true, argType)
        }
        return (false, type)
    }

    /// Leaf types the macro emits first-class schema nodes for.
    private static let supportedPrimitives: Set<String> = [
        "String", "Bool",
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Float", "Double", "Decimal", "CGFloat",
        "Date", "URL",
    ]

    /// Known Foundation / stdlib types that are *not* supported — must diagnose,
    /// not silently expand to `Type.extractionSchema`.
    private static let unsupportedKnownTypes: Set<String> = [
        "UUID", "Data", "NSData", "NSString", "NSNumber", "NSDate",
        "Set", "Dictionary", "NSDictionary", "NSArray", "NSSet",
        "CGPoint", "CGRect", "CGSize", "CGVector", "CGAffineTransform",
        "IndexPath", "IndexSet", "DateComponents", "DateInterval", "Calendar",
        "TimeZone", "Locale", "Measurement", "URLComponents", "URLRequest",
        "Any", "AnyObject", "AnyHashable", "Never", "Result", "Error",
        "ClosedRange", "Range", "PartialRangeFrom", "PartialRangeThrough",
        "Character", "Substring", "StaticString", "ObjectIdentifier",
        "Mirror", "Selector", "NSObject",
    ]

    private static func isSupportedType(_ type: TypeSyntax) -> Bool {
        if let array = type.as(ArrayTypeSyntax.self) {
            return isSupportedType(array.element)
        }
        if let ident = type.as(IdentifierTypeSyntax.self),
            ident.name.text == "Array",
            let generic = ident.genericArgumentClause?.arguments.first
        {
            let arg = TypeSyntax(stringLiteral: generic.argument.trimmedDescription)
            return isSupportedType(arg)
        }
        if type.is(DictionaryTypeSyntax.self) {
            return false
        }
        if type.is(TupleTypeSyntax.self) {
            return false
        }
        if type.is(FunctionTypeSyntax.self) {
            return false
        }
        if type.is(SomeOrAnyTypeSyntax.self) {
            return false
        }
        if type.is(AttributedTypeSyntax.self) {
            return false
        }

        let name = baseTypeName(type)
        if supportedPrimitives.contains(name) {
            return true
        }
        if unsupportedKnownTypes.contains(name) {
            return false
        }
        // Nested @Extractable types / user string enums: simple or member identifiers
        // only (e.g. `Item`, `Receipt.Item`, `Status`). Not generic specializations
        // of unknown system types.
        if let ident = type.as(IdentifierTypeSyntax.self) {
            // Bare identifier without generics → nested extractable / enum.
            if ident.genericArgumentClause == nil {
                return true
            }
            // Generic user types are unsupported in v0.1 (except Array, handled above).
            return false
        }
        if type.is(MemberTypeSyntax.self) {
            return true
        }
        return false
    }

    private static func baseTypeName(_ type: TypeSyntax) -> String {
        if let ident = type.as(IdentifierTypeSyntax.self) {
            return ident.name.text
        }
        if let member = type.as(MemberTypeSyntax.self) {
            return member.name.text
        }
        return type.trimmedDescription
    }

    private static func escapeString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - Schema expressions

    private static func schemaExpression(for prop: PropertyInfo) -> String {
        let expr = schemaExpressionForType(prop.baseTypeSyntax, guide: prop.guide)
        if prop.isOptional {
            if let guide = prop.guide {
                return "\(expr).optional(description: \"\(escapeString(guide))\")"
            }
            return "\(expr).optional()"
        }
        return expr
    }

    private static func schemaExpressionForType(_ type: TypeSyntax, guide: String?) -> String {
        if let array = type.as(ArrayTypeSyntax.self) {
            let item = schemaExpressionForType(array.element, guide: nil)
            if let guide {
                return ".array(items: \(item), description: \"\(escapeString(guide))\")"
            }
            return ".array(items: \(item))"
        }
        if let ident = type.as(IdentifierTypeSyntax.self),
            ident.name.text == "Array",
            let generic = ident.genericArgumentClause?.arguments.first
        {
            let elementType = TypeSyntax(stringLiteral: generic.argument.trimmedDescription)
            let item = schemaExpressionForType(elementType, guide: nil)
            if let guide {
                return ".array(items: \(item), description: \"\(escapeString(guide))\")"
            }
            return ".array(items: \(item))"
        }

        let name = baseTypeName(type)
        switch name {
        case "String":
            return guide.map { ".string(description: \"\(escapeString($0))\")" } ?? ".string()"
        case "Bool":
            return guide.map { ".boolean(description: \"\(escapeString($0))\")" } ?? ".boolean()"
        case "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            return guide.map { ".integer(description: \"\(escapeString($0))\")" } ?? ".integer()"
        case "Float", "Double", "Decimal", "CGFloat":
            return guide.map { ".number(description: \"\(escapeString($0))\")" } ?? ".number()"
        case "Date":
            if let guide {
                return ".string(description: \"\(escapeString(guide))\", format: \"date-time\")"
            }
            return ".string(format: \"date-time\")"
        case "URL":
            if let guide {
                return ".string(description: \"\(escapeString(guide))\", format: \"uri\")"
            }
            return ".string(format: \"uri\")"
        default:
            // Nested @Extractable type or String-backed enum with extractionSchema.
            let typeName = type.trimmedDescription
            if let guide {
                return """
                    {
                        var s = \(typeName).extractionSchema
                        s.description = "\(escapeString(guide))"
                        return s
                    }()
                    """
            }
            return "\(typeName).extractionSchema"
        }
    }

    // MARK: - Member generation

    private static func generateCodingKeys(properties: [PropertyInfo]) -> DeclSyntax {
        if properties.isEmpty {
            return "public enum CodingKeys: String, CodingKey {}"
        }
        let cases = properties.map { "case \($0.name)" }.joined(separator: "\n")
        return """
            public enum CodingKeys: String, CodingKey {
                \(raw: cases)
            }
            """
    }

    private static func generateExtractionSchema(
        typeName: String, properties: [PropertyInfo]
    )
        -> DeclSyntax
    {
        var propertyEntries: [String] = []
        var required: [String] = []
        var order: [String] = []

        for prop in properties {
            order.append(prop.name)
            if !prop.isOptional {
                required.append(prop.name)
            }
            propertyEntries.append("\"\(prop.name)\": \(schemaExpression(for: prop))")
        }

        let propsLiteral: String
        if propertyEntries.isEmpty {
            propsLiteral = "[:]"
        } else {
            propsLiteral =
                "[\n"
                + propertyEntries.map { "            \($0)" }.joined(separator: ",\n")
                + "\n        ]"
        }
        let requiredLiteral =
            required.isEmpty
            ? "[String]()"
            : "[\(required.map { "\"\($0)\"" }.joined(separator: ", "))]"
        let orderLiteral =
            order.isEmpty
            ? "[String]()"
            : "[\(order.map { "\"\($0)\"" }.joined(separator: ", "))]"

        return """
            public nonisolated static var extractionSchema: ExtractionSchema {
                .object(
                    title: "\(raw: typeName)",
                    properties: \(raw: propsLiteral),
                    required: \(raw: requiredLiteral),
                    propertyOrder: \(raw: orderLiteral)
                )
            }
            """
    }

    private static func generateInitFrom(properties: [PropertyInfo]) -> DeclSyntax {
        if properties.isEmpty {
            return """
                public init(from decoder: Decoder) throws {
                    let _ = try decoder.container(keyedBy: CodingKeys.self)
                }
                """
        }
        var lines: [String] = [
            "public init(from decoder: Decoder) throws {",
            "    let container = try decoder.container(keyedBy: CodingKeys.self)",
        ]
        for prop in properties {
            lines.append("    \(decodeLine(for: prop))")
        }
        lines.append("}")
        return DeclSyntax(stringLiteral: lines.joined(separator: "\n"))
    }

    private static func decodeLine(for prop: PropertyInfo) -> String {
        let name = prop.name
        let key = ".\(name)"
        let base = prop.baseTypeSyntax
        let baseName = baseTypeName(base)
        let optional = prop.isOptional

        if base.is(ArrayTypeSyntax.self)
            || (base.as(IdentifierTypeSyntax.self)?.name.text == "Array")
        {
            if optional {
                return
                    "self.\(name) = try container.decodeIfPresent(\(base.trimmedDescription).self, forKey: \(key))"
            }
            return
                "self.\(name) = try container.decode(\(base.trimmedDescription).self, forKey: \(key))"
        }

        switch baseName {
        case "String":
            return optional
                ? "self.\(name) = try container.decodeLenientStringIfPresent(forKey: \(key))"
                : "self.\(name) = try container.decodeLenientString(forKey: \(key))"
        case "Decimal":
            return optional
                ? "self.\(name) = try container.decodeLenientDecimalIfPresent(forKey: \(key))"
                : "self.\(name) = try container.decodeLenientDecimal(forKey: \(key))"
        case "Date":
            return optional
                ? "self.\(name) = try container.decodeLenientDateIfPresent(forKey: \(key))"
                : "self.\(name) = try container.decodeLenientDate(forKey: \(key))"
        case "URL":
            return optional
                ? "self.\(name) = try container.decodeLenientURLIfPresent(forKey: \(key))"
                : "self.\(name) = try container.decodeLenientURL(forKey: \(key))"
        case "Bool":
            return optional
                ? "self.\(name) = try container.decodeLenientBoolIfPresent(forKey: \(key))"
                : "self.\(name) = try container.decodeLenientBool(forKey: \(key))"
        default:
            if optional {
                return
                    "self.\(name) = try container.decodeIfPresent(\(base.trimmedDescription).self, forKey: \(key))"
            }
            return
                "self.\(name) = try container.decode(\(base.trimmedDescription).self, forKey: \(key))"
        }
    }

    private static func generateEncodeTo(properties: [PropertyInfo]) -> DeclSyntax {
        if properties.isEmpty {
            return """
                public func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    _ = container
                }
                """
        }
        var lines: [String] = [
            "public func encode(to encoder: Encoder) throws {",
            "    var container = encoder.container(keyedBy: CodingKeys.self)",
        ]
        for prop in properties {
            if prop.isOptional {
                lines.append(
                    "    try container.encodeIfPresent(self.\(prop.name), forKey: .\(prop.name))"
                )
            } else {
                lines.append("    try container.encode(self.\(prop.name), forKey: .\(prop.name))")
            }
        }
        lines.append("}")
        return DeclSyntax(stringLiteral: lines.joined(separator: "\n"))
    }
}

// MARK: - Diagnostics

enum MacroDiagnostic: DiagnosticMessage {
    case unsupportedType(property: String, typeName: String)
    case missingType(String)

    var severity: DiagnosticSeverity { .error }

    var message: String {
        switch self {
        case .unsupportedType(let property, let typeName):
            return """
                @Extractable does not support property `\(property)` of type `\(typeName)`. \
                Supported: String, Bool, integer/float types, Decimal, Date, URL, Optional, Array, \
                nested @Extractable types, and String-backed enums providing extractionSchema.
                """
        case .missingType(let name):
            return "Property `\(name)` must have an explicit type annotation for @Extractable."
        }
    }

    var diagnosticID: MessageID {
        switch self {
        case .unsupportedType: return MessageID(domain: "ExtractMacros", id: "unsupportedType")
        case .missingType: return MessageID(domain: "ExtractMacros", id: "missingType")
        }
    }
}

enum MacroError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let s): return s
        }
    }
}
