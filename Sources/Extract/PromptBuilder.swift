import Foundation

enum PromptBuilder {
    static let systemInstructions = """
        You are a precise structured data extraction engine.
        Extract the requested fields from the document text.
        Respond with a single JSON object only — no prose, no markdown fences, no comments.
        Use null for unknown optional fields.
        Follow the JSON Schema exactly (types, required fields, enums).
        Dates should be ISO 8601 (YYYY-MM-DD or full date-time) when possible.
        Numbers must be JSON numbers (not words).
        """

    static func userPrompt<T: Extractable>(
        type: T.Type,
        document: ExtractedDocument,
        locale: Locale?,
        schema: ExtractionSchema? = nil,
        allowsPartialObject: Bool = false,
        repair: RepairContext? = nil,
        tables: [ExtractedTable] = []
    ) -> String {
        let targetSchema = schema ?? T.extractionSchema
        let renderedSchema = targetSchema.renderJSONSchema(prettyPrinted: true)
        let guides = targetSchema.guideLines()
        var parts: [String] = []

        parts.append("## Target type\n\(String(describing: type))")
        parts.append("## JSON Schema\n```json\n\(renderedSchema)\n```")

        if allowsPartialObject {
            parts.append(
                """
                ## Partial chunk
                This is one chunk of a larger document. Return only fields supported by this chunk.
                Omit fields that are absent; the partial objects will be merged and validated later.
                """
            )
        }

        if !guides.isEmpty {
            parts.append("## Field guides\n\(guides.joined(separator: "\n"))")
        }

        if let locale {
            let id = locale.identifier
            parts.append(
                "## Locale hint\nInterpret dates and numbers using locale `\(id)` when ambiguous."
            )
        }

        if let repair {
            parts.append(
                """
                ## Previous attempt failed
                Your previous JSON output was invalid. Fix it.

                ### Validation errors
                \(repair.errorDescription)

                ### Previous output
                ```json
                \(repair.previousOutput)
                ```
                """
            )
        }

        parts.append(
            """
            ## Document (\(document.sourceDescription))
            \(document.fullText)
            """
        )

        // Additive only: when empty, omit entirely so the prompt is byte-identical
        // to pre-table builds (prose docs, `tableDetection: .off`, and header-only
        // schemas under `.automatic` where `Extract.tablesForPrompt` returns []).
        if !tables.isEmpty {
            parts.append(tablesSection(tables))
        }

        parts.append(repair == nil ? "Return the JSON object now." : "Return the corrected JSON object now.")
        return parts.joined(separator: "\n\n")
    }

    /// Markdown section listing reconstructed tables for the model.
    ///
    /// Intentionally duplicates content already present in linearised document text:
    /// cell merge is lossy, so the original lines must stay in the prompt.
    static func tablesSection(_ tables: [ExtractedTable]) -> String {
        let intro = """
            ## Detected tables
            The following tables were reconstructed from document layout (geometry of \
            positioned text). They duplicate content already present in the document text \
            above. Prefer the table structure for multi-column line items when it clarifies \
            columns; prefer the linear document text when they disagree.
            """
        var parts: [String] = [intro]
        for (index, table) in tables.enumerated() {
            let md = table.markdown()
            guard !md.isEmpty else { continue }
            parts.append("### Table \(index + 1) (page \(table.pageIndex + 1))\n\n\(md)")
        }
        return parts.joined(separator: "\n\n")
    }

    static func mergePrompt<T: Extractable>(
        type: T.Type,
        partialJSONObjects: [String],
        locale: Locale?
    ) -> String {
        let schema = T.extractionSchema.renderJSONSchema(prettyPrinted: true)
        var parts: [String] = []
        parts.append("## Task\nMerge the following partial JSON extractions into one complete object.")
        parts.append("## Target type\n\(String(describing: type))")
        parts.append("## JSON Schema\n```json\n\(schema)\n```")
        if let locale {
            parts.append("## Locale hint\n\(locale.identifier)")
        }
        for (index, json) in partialJSONObjects.enumerated() {
            parts.append("## Partial \(index + 1)\n```json\n\(json)\n```")
        }
        parts.append(
            """
            Rules:
            - Prefer non-null values over null.
            - Concatenate arrays and de-duplicate when clearly identical.
            - Resolve conflicts by choosing the more complete / higher-confidence value.
            - Respond with a single JSON object only.
            """
        )
        return parts.joined(separator: "\n\n")
    }

    struct RepairContext: Sendable {
        var previousOutput: String
        var errorDescription: String
    }
}

enum ValidationErrorFormatter {
    static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            return describeDecoding(decoding)
        }
        if let invariant = error as? InvariantValidationError {
            return describeInvariant(invariant)
        }
        return error.localizedDescription
    }

    private static func describeDecoding(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            let path = codingPath(context.codingPath)
            return "field `\(path)`: expected \(type), \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            let path = codingPath(context.codingPath)
            return "field `\(path)`: expected \(type) but found null/missing — \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            let path = codingPath(context.codingPath + [key])
            return "field `\(path)`: key not found — \(context.debugDescription)"
        case .dataCorrupted(let context):
            let path = codingPath(context.codingPath)
            return "field `\(path)`: \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    /// Same field-addressable shape as decode errors so the model can repair invariants.
    private static func describeInvariant(_ error: InvariantValidationError) -> String {
        if error.issues.isEmpty {
            return error.localizedDescription
        }
        return error.issues.map(\.description).joined(separator: "\n")
    }

    private static func codingPath(_ path: [CodingKey]) -> String {
        if path.isEmpty { return "$" }
        return path.map(\.stringValue).joined(separator: ".")
    }
}
