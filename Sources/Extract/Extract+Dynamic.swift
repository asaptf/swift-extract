import Foundation

extension Extract {
    /// Extract into an untyped ``JSONValue`` tree described by `schema`.
    ///
    /// Same loop as ``from(_:as:using:options:)``: prompt, lenient decode, repair.
    /// `invariants` is the dynamic equivalent of ``Extractable/validateInvariants()``.
    /// ``from(_:schema:invariants:using:options:)`` still throws when they fail;
    /// use ``detailed(from:schema:invariants:using:options:)`` with
    /// ``InvariantPolicy/reportViolations`` to keep the value.
    public static func from(
        _ source: ExtractionSource,
        schema: ExtractionSchema,
        invariants: (@Sendable (JSONValue) throws -> Void)? = nil,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init(),
        ingest: IngestContext = IngestContext()
    ) async throws -> JSONValue {
        try await withDynamicSchema(schema, invariants: invariants) {
            try await from(source, as: JSONValue.self, using: session, options: options, ingest: ingest)
        }
    }

    public static func from(
        _ text: String,
        schema: ExtractionSchema,
        invariants: (@Sendable (JSONValue) throws -> Void)? = nil,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init(),
        ingest: IngestContext = IngestContext()
    ) async throws -> JSONValue {
        try await from(
            .text(text),
            schema: schema,
            invariants: invariants,
            using: session,
            options: options,
            ingest: ingest
        )
    }

    public static func from(
        _ url: URL,
        schema: ExtractionSchema,
        invariants: (@Sendable (JSONValue) throws -> Void)? = nil,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init(),
        ingest: IngestContext = IngestContext()
    ) async throws -> JSONValue {
        try await from(
            .fileURL(url),
            schema: schema,
            invariants: invariants,
            using: session,
            options: options,
            ingest: ingest
        )
    }

    /// Full result for a runtime schema, including grounding against that schema.
    public static func detailed(
        from source: ExtractionSource,
        schema: ExtractionSchema,
        invariants: (@Sendable (JSONValue) throws -> Void)? = nil,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init(),
        ingest: IngestContext = IngestContext()
    ) async throws -> ExtractionResult<JSONValue> {
        try await withDynamicSchema(schema, invariants: invariants) {
            try await detailed(
                from: source,
                as: JSONValue.self,
                using: session,
                options: options,
                ingest: ingest
            )
        }
    }

    public static func stream(
        from source: ExtractionSource,
        schema: ExtractionSchema,
        invariants: (@Sendable (JSONValue) throws -> Void)? = nil,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init(),
        ingest: IngestContext = IngestContext()
    ) -> AsyncThrowingStream<ExtractionUpdate<JSONValue>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await withDynamicSchema(schema, invariants: invariants) {
                        let inner = stream(
                            from: source,
                            as: JSONValue.self,
                            using: session,
                            options: options,
                            ingest: ingest
                        )
                        for try await update in inner {
                            continuation.yield(update)
                        }
                    }
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

    private static func withDynamicSchema<T: Sendable>(
        _ schema: ExtractionSchema,
        invariants: (@Sendable (JSONValue) throws -> Void)?,
        operation: () async throws -> T
    ) async throws -> T {
        try await DynamicExtractionContext.$schema.withValue(schema) {
            try await DynamicExtractionContext.$invariants.withValue(invariants) {
                try await operation()
            }
        }
    }
}
