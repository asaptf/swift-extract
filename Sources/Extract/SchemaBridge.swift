import AnyLanguageModel
import Foundation

extension ExtractionSchema {
    /// Convert to AnyLanguageModel ``DynamicGenerationSchema`` for constrained generation.
    public func toDynamicGenerationSchema(name: String = "Root") -> DynamicGenerationSchema {
        switch type {
        case .object:
            let order = propertyOrder ?? Array(properties?.keys.sorted() ?? [])
            var props: [DynamicGenerationSchema.Property] = []
            let requiredSet = Set(required ?? [])
            for key in order {
                guard let child = properties?[key] else { continue }
                let childSchema = child.toDynamicGenerationSchema(name: key)
                props.append(
                    DynamicGenerationSchema.Property(
                        name: key,
                        description: child.description,
                        schema: childSchema,
                        isOptional: !requiredSet.contains(key)
                    )
                )
            }
            // Properties not listed in order
            if let properties {
                for (key, child) in properties where !order.contains(key) {
                    let childSchema = child.toDynamicGenerationSchema(name: key)
                    props.append(
                        DynamicGenerationSchema.Property(
                            name: key,
                            description: child.description,
                            schema: childSchema,
                            isOptional: !requiredSet.contains(key)
                        )
                    )
                }
            }
            return DynamicGenerationSchema(
                name: title ?? name,
                description: description,
                properties: props
            )
        case .array:
            let item =
                items?.toDynamicGenerationSchema(name: "\(name)Item")
                ?? DynamicGenerationSchema(type: String.self)
            return DynamicGenerationSchema(arrayOf: item)
        case .string:
            if let enumValues, !enumValues.isEmpty {
                return DynamicGenerationSchema(
                    name: title ?? name,
                    description: description,
                    anyOf: enumValues
                )
            }
            return DynamicGenerationSchema(type: String.self)
        case .number:
            return DynamicGenerationSchema(type: Double.self)
        case .integer:
            return DynamicGenerationSchema(type: Int.self)
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case .null:
            return DynamicGenerationSchema(type: String.self)
        }
    }

    /// Convert to a resolved ``GenerationSchema`` for guided generation APIs.
    public func toGenerationSchema(name: String = "Root") throws -> GenerationSchema {
        let dynamic = toDynamicGenerationSchema(name: name)
        return try GenerationSchema(root: dynamic, dependencies: [])
    }
}
