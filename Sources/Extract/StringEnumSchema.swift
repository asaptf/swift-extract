import Foundation

extension ExtractionSchema {
    /// Build a JSON Schema `enum` from a `String`-backed `CaseIterable` type.
    public static func stringEnum<E: CaseIterable & RawRepresentable>(
        _ type: E.Type,
        description: String? = nil
    ) -> ExtractionSchema where E.RawValue == String {
        .string(
            description: description,
            enumValues: E.allCases.map(\.rawValue)
        )
    }
}

/// Manual `Extractable` helpers for string-backed enums that are not nested
/// under `@Extractable` structs with synthesized schemas.
extension Extractable where Self: CaseIterable & RawRepresentable, Self.RawValue == String {
    public static var extractionSchema: ExtractionSchema {
        .stringEnum(Self.self)
    }
}
