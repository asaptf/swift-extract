import AnyLanguageModel
import Foundation

extension ExtractionSchema {
    /// Convert to AnyLanguageModel ``DynamicGenerationSchema`` for constrained generation.
    ///
    /// ## Required keys + null for absence (guided path only)
    ///
    /// Every property is marked **required** on the generation schema. Properties that are
    /// optional in the extraction schema (Swift `Optional` / not listed in `required`) get a
    /// value schema of `anyOf [T, null]`, matching OpenAI strict structured-output practice:
    /// the model must emit each key and may answer `null` when the document lacks that field.
    ///
    /// This does **not** change ``renderJSONSchema()`` / ``PromptBuilder`` — those still use
    /// the extraction schema's original `required` list so guided and unguided arms share
    /// identical prompts. Decoding continues to accept missing keys as `nil`.
    public func toDynamicGenerationSchema(name: String = "Root") -> DynamicGenerationSchema {
        switch type {
        case .object:
            let order = propertyOrder ?? Array(properties?.keys.sorted() ?? [])
            var props: [DynamicGenerationSchema.Property] = []
            let requiredSet = Set(required ?? [])
            for key in order {
                guard let child = properties?[key] else { continue }
                props.append(bridgedProperty(key: key, child: child, requiredSet: requiredSet, parentName: name))
            }
            // Properties not listed in order
            if let properties {
                for (key, child) in properties where !order.contains(key) {
                    props.append(bridgedProperty(key: key, child: child, requiredSet: requiredSet, parentName: name))
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
            return DynamicGenerationSchema(null: ())
        }
    }

    /// Convert to a resolved ``GenerationSchema`` for guided generation APIs.
    public func toGenerationSchema(name: String = "Root") throws -> GenerationSchema {
        let dynamic = toDynamicGenerationSchema(name: name)
        return try GenerationSchema(root: dynamic, dependencies: [])
    }

    /// Build a guided-generation property: always required; optional extraction fields
    /// become `anyOf [value, null]`.
    private func bridgedProperty(
        key: String,
        child: ExtractionSchema,
        requiredSet: Set<String>,
        parentName: String
    ) -> DynamicGenerationSchema.Property {
        let childSchema = child.toDynamicGenerationSchema(name: key)
        let extractionOptional = !requiredSet.contains(key)
        let valueSchema: DynamicGenerationSchema
        if extractionOptional {
            // Required key, nullable value — model must emit the key, may answer null.
            valueSchema = DynamicGenerationSchema(
                name: "\(parentName)_\(key)_Nullable",
                description: child.description,
                anyOf: [childSchema, DynamicGenerationSchema(null: ())]
            )
        } else {
            valueSchema = childSchema
        }
        return DynamicGenerationSchema.Property(
            name: key,
            description: child.description,
            schema: valueSchema,
            isOptional: false
        )
    }
}
