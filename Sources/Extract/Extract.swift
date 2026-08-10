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

    // MARK: - Streaming

    /// Stream progressive ``ExtractionUpdate/partial(_:)`` snapshots, then a terminal
    /// ``ExtractionUpdate/final(_:)`` with the same shape as ``detailed(from:as:using:options:)``.
    ///
    /// ```swift
    /// let stream = Extract.stream(from: source, as: Invoice.self, using: session)
    /// for try await update in stream {
    ///     switch update {
    ///     case .partial(let p):  // Invoice.Partial — every field optional
    ///     case .final(let r):    // ExtractionResult<Invoice>
    ///     }
    /// }
    /// ```
    ///
    /// ## Completed-token rule
    ///
    /// Partials only surface values whose JSON tokens are provably complete (closing
    /// quote for strings; a delimiter after a number). Half-written numbers like `47`
    /// while the model is still producing `473.00` are withheld — a wrong total on
    /// screen is worse than an empty field. Growing arrays are fine as elements complete.
    ///
    /// ## Chunking
    ///
    /// When the document is split into multiple chunks, partial snapshots across chunks
    /// would be incoherent (the deterministic merge is what makes the value meaningful).
    /// Chunked runs therefore emit **no** ``ExtractionUpdate/partial(_:)`` updates —
    /// only the terminal ``ExtractionUpdate/final(_:)``.
    ///
    /// ## Repair retries
    ///
    /// Partials stream from the **first** generation attempt only. If decode or
    /// ``Extractable/validateInvariants()`` fails and the loop retries, the retry is
    /// not streamed; the stream still ends with ``ExtractionUpdate/final(_:)`` carrying
    /// the repaired result (or throws if retries are exhausted — same errors as
    /// ``detailed(from:as:using:options:)``).
    ///
    /// ## Signals and tables
    ///
    /// Provenance, grounding, merge conflicts, and tables are computed for the final
    /// result only. A partial is a UI preview, not an evidenced result.
    public static func stream<T: Extractable>(
        from source: ExtractionSource,
        as type: T.Type = T.self,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init()
    ) -> AsyncThrowingStream<ExtractionUpdate<T>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let document = try await SourceIngester.ingest(source)
                    guard !document.isEmpty else {
                        throw ExtractionError.emptyDocument
                    }
                    try await streamExtract(
                        from: document,
                        as: type,
                        using: session,
                        options: options,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Convenience overload for plain text sources.
    public static func stream<T: Extractable>(
        from text: String,
        as type: T.Type = T.self,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init()
    ) -> AsyncThrowingStream<ExtractionUpdate<T>, Error> {
        stream(from: .text(text), as: type, using: session, options: options)
    }

    /// Convenience overload for file URLs (UTType sniff, same as ``from(_:using:options:)``).
    public static func stream<T: Extractable>(
        from url: URL,
        as type: T.Type = T.self,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init()
    ) -> AsyncThrowingStream<ExtractionUpdate<T>, Error> {
        stream(from: .fileURL(url), as: type, using: session, options: options)
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

        // Per-chunk extraction, then deterministic structural merge of partial JSON.
        // Tables attach by cell-text containment (never a half table, no page-index
        // broadcast onto hard-split sub-chunks).
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

        let merged = ChunkJSONMerger.merge(
            partialJSONObjects: partials,
            fullDocumentText: sourceText
        )
        let temperature = options.resolvedTemperature(session: session)
        let schema = T.extractionSchema
        // Schema-gate prompt injection for repair; result.tables stays full-document.
        let promptTables = tablesForPrompt(tables, schema: schema)
        var lastError: Error = ExtractionError.mergeFailed("deterministic merge produced undecodable JSON")
        var lastRaw = merged.json
        var modelRepairAttempts = 0
        let maxRepairAttempts = max(0, options.maxRetries)

        // Attempt 0: decode the deterministically merged tree (no model call).
        // Further attempts: Instructor-style repair against the full document, same as
        // the single-chunk path — invariants and the lenient decoder still run once per try.
        for attempt in 0...maxRepairAttempts {
            let raw: String
            if attempt == 0 {
                raw = merged.json
            } else {
                let repair = PromptBuilder.RepairContext(
                    previousOutput: lastRaw,
                    errorDescription: ValidationErrorFormatter.describe(lastError)
                )
                let user = PromptBuilder.userPrompt(
                    type: type,
                    document: document,
                    locale: options.locale,
                    repair: repair,
                    tables: promptTables
                )
                raw = try await session.generate(
                    system: PromptBuilder.systemInstructions,
                    user: user,
                    temperature: temperature,
                    schema: schema
                )
                modelRepairAttempts += 1
            }
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
                let attempts = totalAttempts + modelRepairAttempts
                let grounded = FieldGrounding.compute(
                    value: value,
                    sourceText: sourceText,
                    attempts: attempts,
                    chunksUsed: chunks.count,
                    blocks: document.blocks,
                    tables: tables
                )
                let signals = ExtractionSignals(
                    attempts: grounded.attempts,
                    chunksUsed: grounded.chunksUsed,
                    fields: grounded.fields,
                    mergeConflicts: merged.conflicts
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
            attempts: totalAttempts + modelRepairAttempts,
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
                // Root null / non-object is not a partial result: contribute nothing
                // (`{}`) so a single empty chunk cannot fail the whole multi-chunk run.
                let json = try PartialJSONValidator.validate(
                    raw,
                    expectedRoot: schema.type,
                    emptyContributionOnNullOrNonObject: true
                )
                return (json, attempt + 1)
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

    // MARK: - Streaming core

    /// Drive the extraction loop while yielding partials (single-chunk) or only
    /// a final result (multi-chunk).
    private static func streamExtract<T: Extractable>(
        from document: ExtractedDocument,
        as type: T.Type,
        using session: ExtractionSession,
        options: ExtractionOptions,
        continuation: AsyncThrowingStream<ExtractionUpdate<T>, Error>.Continuation
    ) async throws {
        let tables = TableDetector.detect(
            documentBlocks: document.blocks,
            mode: options.tableDetection
        )
        let chunks = resolveChunks(document: document, options: options)
        let sourceText = document.fullText

        // Chunked documents: partials across chunks are incoherent — merge is what
        // makes the value meaningful. Emit only `.final` via the existing path.
        if chunks.count > 1 {
            let result = try await extract(
                from: document,
                as: type,
                using: session,
                options: options
            )
            continuation.yield(.final(result))
            return
        }

        try await streamExtractSingle(
            from: chunks[0],
            as: type,
            using: session,
            options: options,
            chunksUsed: 1,
            sourceText: sourceText,
            tables: tables,
            documentBlocks: document.blocks,
            continuation: continuation
        )
    }

    private static func streamExtractSingle<T: Extractable>(
        from document: ExtractedDocument,
        as type: T.Type,
        using session: ExtractionSession,
        options: ExtractionOptions,
        chunksUsed: Int,
        sourceText: String,
        tables: [ExtractedTable],
        documentBlocks: [ExtractedDocument.Block],
        continuation: AsyncThrowingStream<ExtractionUpdate<T>, Error>.Continuation
    ) async throws {
        var lastError: Error = ExtractionError.internalError("no attempt")
        var lastRaw = ""
        let maxAttempts = max(1, options.maxRetries + 1)
        let temperature = options.resolvedTemperature(session: session)
        let schema = T.extractionSchema
        let promptTables = tablesForPrompt(tables, schema: schema)

        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
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

            let raw: String
            if attempt == 0 {
                // Stream partials only on the first attempt.
                raw = try await streamFirstAttempt(
                    system: PromptBuilder.systemInstructions,
                    user: user,
                    temperature: temperature,
                    schema: schema,
                    using: session,
                    locale: options.locale,
                    continuation: continuation
                )
            } else {
                // Retries are not streamed — one-shot generate.
                raw = try await session.generate(
                    system: PromptBuilder.systemInstructions,
                    user: user,
                    temperature: temperature,
                    schema: schema
                )
            }
            lastRaw = raw
            do {
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
                    blocks: documentBlocks,
                    tables: tables
                )
                let result = ExtractionResult(
                    value: value,
                    attempts: attempts,
                    rawModelOutput: raw,
                    chunksUsed: chunksUsed,
                    signals: signals,
                    tables: tables
                )
                continuation.yield(.final(result))
                return
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

    /// Consume the model stream, yield ``ExtractionUpdate/partial`` for each new
    /// completed-token snapshot, and return the full cumulative text.
    private static func streamFirstAttempt<T: Extractable>(
        system: String,
        user: String,
        temperature: Double,
        schema: ExtractionSchema,
        using session: ExtractionSession,
        locale: Locale?,
        continuation: AsyncThrowingStream<ExtractionUpdate<T>, Error>.Continuation
    ) async throws -> String {
        var lastSnapshot: String?
        var lastText = ""
        let textStream = session.streamGenerate(
            system: system,
            user: user,
            temperature: temperature,
            schema: schema
        )
        for try await cumulative in textStream {
            try Task.checkCancellation()
            lastText = cumulative
            guard
                let snapshot = CompletedTokenJSON.snapshot(
                    from: cumulative,
                    expectedRoot: schema.type
                )
            else {
                continue
            }
            // Skip unchanged snapshots (common as non-token chars arrive).
            if snapshot == lastSnapshot {
                continue
            }
            lastSnapshot = snapshot
            if let partial = try? T.decodePartial(from: snapshot, locale: locale) {
                continuation.yield(.partial(partial))
            }
        }
        return lastText
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
    /// Assignment is by **cell-text containment**: a table attaches to a chunk only when
    /// every non-empty cell string appears in that chunk's text. This avoids the old
    /// page-index broadcast that attached every table on a page to every hard-split
    /// sub-chunk of that page (including slices that contain none of the table text).
    /// Tables that match no chunk are omitted from all prompts (linear document text
    /// still carries the content); there is no "attach everything to chunk 0" fallback.
    static func assignTablesToChunks(
        _ tables: [ExtractedTable],
        chunks: [ExtractedDocument]
    ) -> [[ExtractedTable]] {
        guard !tables.isEmpty, !chunks.isEmpty else {
            return Array(repeating: [], count: chunks.count)
        }

        return chunks.map { chunk in
            let text = chunk.fullText
            return tables.filter { table in
                let cells = table.cells.map(\.text).filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                guard !cells.isEmpty else { return false }
                return cells.allSatisfy { text.contains($0) }
            }
        }
    }
}

private enum PartialJSONValidator {
    static func validate(
        _ raw: String,
        expectedRoot: ExtractionSchema.SchemaType,
        emptyContributionOnNullOrNonObject: Bool = false
    ) throws -> String {
        let cleaned = JSONFenceStripper.strip(raw, expectedRoot: expectedRoot)
        guard let data = cleaned.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Partial JSON is not valid UTF-8")
            )
        }
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if expectedRoot == .object {
            if value is [String: Any] {
                return cleaned
            }
            if emptyContributionOnNullOrNonObject {
                // Bare null / array / scalar: not a usable partial object.
                return "{}"
            }
            throw DecodingError.typeMismatch(
                [String: Any].self,
                .init(codingPath: [], debugDescription: "Expected a partial JSON object")
            )
        }
        return cleaned
    }
}
