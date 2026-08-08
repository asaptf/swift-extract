import Foundation

/// Entry point for typed structured extraction.
public enum Extract {
    /// Type inferred from context: `let r: Receipt = try await Extract.from(url)`.
    public static func from<T: Extractable>(
        _ source: ExtractionSource,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init()
    ) async throws -> T {
        try await detailed(from: source, as: T.self, using: session, options: options).value
    }

    /// Explicit type form.
    public static func from<T: Extractable>(
        _ source: ExtractionSource,
        as type: T.Type,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init()
    ) async throws -> T {
        try await detailed(from: source, as: type, using: session, options: options).value
    }

    /// Full result including attempts and raw model output.
    public static func detailed<T: Extractable>(
        from source: ExtractionSource,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init()
    ) async throws -> ExtractionResult<T> {
        try await detailed(from: source, as: T.self, using: session, options: options)
    }

    public static func detailed<T: Extractable>(
        from source: ExtractionSource,
        as type: T.Type,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init()
    ) async throws -> ExtractionResult<T> {
        let document = try await SourceIngester.ingest(source)
        guard !document.isEmpty else {
            throw ExtractionError.emptyDocument
        }
        return try await extract(from: document, as: type, using: session, options: options)
    }

    // MARK: - Convenience overloads (README hero lines)

    public static func from<T: Extractable>(
        _ text: String,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init()
    ) async throws -> T {
        try await from(.text(text), using: session, options: options)
    }

    public static func from<T: Extractable>(
        _ url: URL,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init()
    ) async throws -> T {
        try await from(.fileURL(url), using: session, options: options)
    }

    // MARK: - Core loop

    static func extract<T: Extractable>(
        from document: ExtractedDocument,
        as type: T.Type,
        using session: ExtractionSession,
        options: ExtractionOptions
    ) async throws -> ExtractionResult<T> {
        // Detect once on the full document (geometry is lost after some chunk splits).
        let tables = TableDetector.detect(
            documentBlocks: document.blocks,
            mode: options.tableDetection
        )
        let chunks = resolveChunks(document: document, options: options)
        let sourceText = document.fullText
        if chunks.count == 1 {
            return try await extractSingle(
                from: chunks[0],
                as: type,
                using: session,
                options: options,
                chunksUsed: 1,
                sourceText: sourceText,
                tables: tables
            )
        }

        // Per-chunk extraction then merge. Assign whole tables to chunks by page;
        // never emit a half table. Fallback: if page filtering drops every table,
        // attach the full set to the first chunk so the section is not lost.
        let tablesByChunk = assignTablesToChunks(tables, chunks: chunks)
        var partials: [String] = []
        var totalAttempts = 0
        for (index, chunk) in chunks.enumerated() {
            let result = try await extractPartial(
                from: chunk,
                as: type,
                using: session,
                options: options,
                tables: tablesByChunk[index]
            )
            partials.append(result.json)
            totalAttempts += result.attempts
        }

        let mergeUser = PromptBuilder.mergePrompt(
            type: type,
            partialJSONObjects: partials,
            locale: options.locale
        )
        let temperature = options.resolvedTemperature(session: session)
        let schema = T.extractionSchema
        var lastError: Error = ExtractionError.mergeFailed("unknown")
        var lastRaw = ""
        let maxAttempts = max(1, options.maxRetries + 1)

        for attempt in 0..<maxAttempts {
            let user: String
            if attempt == 0 {
                user = mergeUser
            } else {
                user =
                    mergeUser
                    + "\n\n## Previous merge failed\n\(ValidationErrorFormatter.describe(lastError))\n\n### Previous output\n\(lastRaw)"
            }
            let raw = try await session.generate(
                system: PromptBuilder.systemInstructions,
                user: user,
                temperature: temperature,
                schema: schema
            )
            lastRaw = raw
            do {
                // Decode without invariants, then validate once. Public
                // `decodeExtracted` also validates; calling it here would run
                // validators twice (non-idempotent validators can then fail the
                // second pass and turn a good extraction into validationFailed).
                let value = try T.decodeExtractedWithoutInvariants(
                    from: raw,
                    locale: options.locale
                )
                try value.validateInvariants()
                let attempts = totalAttempts + attempt + 1
                let signals = FieldGrounding.compute(
                    value: value,
                    sourceText: sourceText,
                    attempts: attempts,
                    chunksUsed: chunks.count,
                    blocks: document.blocks,
                    tables: tables
                )
                return ExtractionResult(
                    value: value,
                    attempts: attempts,
                    rawModelOutput: raw,
                    chunksUsed: chunks.count,
                    signals: signals,
                    tables: tables
                )
            } catch {
                lastError = error
            }
        }

        throw ExtractionError.validationFailed(
            attempts: totalAttempts + maxAttempts,
            lastError: lastError,
            rawOutput: lastRaw
        )
    }

    private static func extractPartial<T: Extractable>(
        from document: ExtractedDocument,
        as type: T.Type,
        using session: ExtractionSession,
        options: ExtractionOptions,
        tables: [ExtractedTable]
    ) async throws -> (json: String, attempts: Int) {
        var lastError: Error = ExtractionError.internalError("no attempt")
        var lastRaw = ""
        let maxAttempts = max(1, options.maxRetries + 1)
        let temperature = options.resolvedTemperature(session: session)
        var schema = T.extractionSchema
        if schema.type == .object {
            schema.required = []
        }
        // Schema-gate prompt injection; detection list on the result is unfiltered.
        let promptTables = tablesForPrompt(tables, schema: T.extractionSchema)

        for attempt in 0..<maxAttempts {
            let repair: PromptBuilder.RepairContext?
            if attempt == 0 {
                repair = nil
            } else {
                repair = PromptBuilder.RepairContext(
                    previousOutput: lastRaw,
                    errorDescription: ValidationErrorFormatter.describe(lastError)
                )
            }
            let user = PromptBuilder.userPrompt(
                type: type,
                document: document,
                locale: options.locale,
                schema: schema,
                allowsPartialObject: true,
                repair: repair,
                tables: promptTables
            )
            let raw = try await session.generate(
                system: PromptBuilder.systemInstructions,
                user: user,
                temperature: temperature,
                schema: schema
            )
            lastRaw = raw
            do {
                return (try PartialJSONValidator.validate(raw, expectedRoot: schema.type), attempt + 1)
            } catch {
                lastError = error
            }
        }

        throw ExtractionError.validationFailed(
            attempts: maxAttempts,
            lastError: lastError,
            rawOutput: lastRaw
        )
    }

    private static func extractSingle<T: Extractable>(
        from document: ExtractedDocument,
        as type: T.Type,
        using session: ExtractionSession,
        options: ExtractionOptions,
        chunksUsed: Int,
        sourceText: String,
        tables: [ExtractedTable]
    ) async throws -> ExtractionResult<T> {
        var lastError: Error = ExtractionError.internalError("no attempt")
        var lastRaw = ""
        let maxAttempts = max(1, options.maxRetries + 1)
        let temperature = options.resolvedTemperature(session: session)
        let schema = T.extractionSchema
        // Schema-gate prompt injection; `tables` on the result stays unfiltered.
        let promptTables = tablesForPrompt(tables, schema: schema)

        for attempt in 0..<maxAttempts {
            let repair: PromptBuilder.RepairContext?
            if attempt == 0 {
                repair = nil
            } else {
                repair = PromptBuilder.RepairContext(
                    previousOutput: lastRaw,
                    errorDescription: ValidationErrorFormatter.describe(lastError)
                )
            }
            let user = PromptBuilder.userPrompt(
                type: type,
                document: document,
                locale: options.locale,
                repair: repair,
                tables: promptTables
            )
            let raw = try await session.generate(
                system: PromptBuilder.systemInstructions,
                user: user,
                temperature: temperature,
                schema: schema
            )
            lastRaw = raw
            do {
                // Decode without invariants, then validate once (see merge path).
                let value = try T.decodeExtractedWithoutInvariants(
                    from: raw,
                    locale: options.locale
                )
                try value.validateInvariants()
                let attempts = attempt + 1
                let signals = FieldGrounding.compute(
                    value: value,
                    sourceText: sourceText,
                    attempts: attempts,
                    chunksUsed: chunksUsed,
                    blocks: document.blocks,
                    tables: tables
                )
                return ExtractionResult(
                    value: value,
                    attempts: attempts,
                    rawModelOutput: raw,
                    chunksUsed: chunksUsed,
                    signals: signals,
                    tables: tables
                )
            } catch {
                lastError = error
            }
        }

        throw ExtractionError.validationFailed(
            attempts: maxAttempts,
            lastError: lastError,
            rawOutput: lastRaw
        )
    }

    private static func resolveChunks(
        document: ExtractedDocument,
        options: ExtractionOptions
    ) -> [ExtractedDocument] {
        switch options.chunkingStrategy {
        case .none:
            return [document]
        case .fixed(let budget):
            return document.chunks(budget: budget)
        case .automatic:
            if document.fullText.count <= options.softContextCharacterBudget {
                return [document]
            }
            return document.chunks(budget: options.softContextCharacterBudget)
        }
    }

    /// Tables to pass into ``PromptBuilder`` for a given target schema.
    ///
    /// When the schema has no collection (array) property anywhere, returns `[]` so
    /// the prompt stays free of the detected-tables section (byte-identical to
    /// ``TableDetectionMode/off``). Detected tables are still reported on
    /// ``ExtractionResult/tables`` by the caller — this only filters the prompt list.
    static func tablesForPrompt(
        _ tables: [ExtractedTable],
        schema: ExtractionSchema
    ) -> [ExtractedTable] {
        schema.containsCollection ? tables : []
    }

    /// Map whole tables onto chunks without splitting a table's Markdown.
    ///
    /// Prefer page-index membership. When a chunk has no page indices (rare unpaged
    /// hard splits), require every non-empty cell text to appear in the chunk so we
    /// never attach a table that mostly lives elsewhere. If filtering would drop all
    /// tables, attach the full set to the first chunk (graceful fallback).
    static func assignTablesToChunks(
        _ tables: [ExtractedTable],
        chunks: [ExtractedDocument]
    ) -> [[ExtractedTable]] {
        guard !tables.isEmpty, !chunks.isEmpty else {
            return Array(repeating: [], count: chunks.count)
        }

        var assigned: [[ExtractedTable]] = chunks.map { chunk in
            let pages = Set(chunk.blocks.compactMap(\.pageIndex))
            if pages.isEmpty {
                let text = chunk.fullText
                return tables.filter { table in
                    let cells = table.cells.map(\.text).filter {
                        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    guard !cells.isEmpty else { return false }
                    return cells.allSatisfy { text.contains($0) }
                }
            }
            return tables.filter { pages.contains($0.pageIndex) }
        }

        if assigned.allSatisfy(\.isEmpty) {
            assigned[0] = tables
        }
        return assigned
    }
}

private enum PartialJSONValidator {
    static func validate(
        _ raw: String,
        expectedRoot: ExtractionSchema.SchemaType
    ) throws -> String {
        let cleaned = JSONFenceStripper.strip(raw, expectedRoot: expectedRoot)
        guard let data = cleaned.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Partial JSON is not valid UTF-8")
            )
        }
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if expectedRoot == .object, !(value is [String: Any]) {
            throw DecodingError.typeMismatch(
                [String: Any].self,
                .init(codingPath: [], debugDescription: "Expected a partial JSON object")
            )
        }
        return cleaned
    }
}
