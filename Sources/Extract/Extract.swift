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
        let chunks = resolveChunks(document: document, options: options)
        if chunks.count == 1 {
            return try await extractSingle(
                from: chunks[0],
                as: type,
                using: session,
                options: options,
                chunksUsed: 1
            )
        }

        // Per-chunk extraction then merge.
        var partials: [String] = []
        var totalAttempts = 0
        for chunk in chunks {
            let result = try await extractSingle(
                from: chunk,
                as: type,
                using: session,
                options: options,
                chunksUsed: chunks.count
            )
            partials.append(result.rawModelOutput)
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
            do {
                let raw = try await session.generate(
                    system: PromptBuilder.systemInstructions,
                    user: user,
                    temperature: temperature,
                    schema: schema
                )
                lastRaw = raw
                let value = try T.decodeExtracted(from: raw, locale: options.locale)
                return ExtractionResult(
                    value: value,
                    attempts: totalAttempts + attempt + 1,
                    rawModelOutput: raw,
                    chunksUsed: chunks.count
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

    private static func extractSingle<T: Extractable>(
        from document: ExtractedDocument,
        as type: T.Type,
        using session: ExtractionSession,
        options: ExtractionOptions,
        chunksUsed: Int
    ) async throws -> ExtractionResult<T> {
        var lastError: Error = ExtractionError.internalError("no attempt")
        var lastRaw = ""
        let maxAttempts = max(1, options.maxRetries + 1)
        let temperature = options.resolvedTemperature(session: session)
        let schema = T.extractionSchema

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
                repair: repair
            )
            do {
                let raw = try await session.generate(
                    system: PromptBuilder.systemInstructions,
                    user: user,
                    temperature: temperature,
                    schema: schema
                )
                lastRaw = raw
                let value = try T.decodeExtracted(from: raw, locale: options.locale)
                return ExtractionResult(
                    value: value,
                    attempts: attempt + 1,
                    rawModelOutput: raw,
                    chunksUsed: chunksUsed
                )
            } catch let error as ExtractionError {
                // Model unavailable etc. should not be retried as validation.
                if case .modelUnavailable = error {
                    throw error
                }
                lastError = error
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
}
