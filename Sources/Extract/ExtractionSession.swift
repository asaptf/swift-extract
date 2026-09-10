import AnyLanguageModel
import Foundation

/// Thin wrapper around an AnyLanguageModel ``LanguageModel``.
public struct ExtractionSession: Sendable {
    /// Resolves Apple Foundation Models when available; otherwise extraction fails
    /// with a clear ``ExtractionError/modelUnavailable`` message when used.
    public static var `default`: ExtractionSession {
        DefaultSessionResolver.resolve()
    }

    let backend: any ExtractionGenerating
    /// Default sampling temperature for this session (used when
    /// ``ExtractionOptions/temperature`` is `nil`).
    public let temperature: Double

    /// Create a session from any AnyLanguageModel-compatible model.
    public init(model: any LanguageModel, temperature: Double = 0) {
        self.backend = LanguageModelBackend(model: model)
        self.temperature = temperature
    }

    /// Test / offline injection point.
    package init(generator: any ExtractionGenerating, temperature: Double = 0) {
        self.backend = generator
        self.temperature = temperature
    }

    func generate(
        system: String,
        user: String,
        settings: GenerationSettings,
        schema: ExtractionSchema?
    ) async throws -> String {
        try await backend.generate(
            system: system,
            user: user,
            settings: settings,
            schema: schema
        )
    }

    /// Stream cumulative model text. Each element is the full text so far (not a delta).
    func streamGenerate(
        system: String,
        user: String,
        settings: GenerationSettings,
        schema: ExtractionSchema?
    ) -> AsyncThrowingStream<String, Error> {
        backend.streamGenerate(
            system: system,
            user: user,
            settings: settings,
            schema: schema
        )
    }
}

// MARK: - Generation settings

/// What the extraction loop asks the model to do, resolved once.
///
/// This is a type rather than two parameters because it is now the *second* sampling knob:
/// threading each new one through the seam and every conformance is how a protocol becomes
/// hard to extend.
public struct GenerationSettings: Sendable, Equatable {
    public var temperature: Double
    /// `nil` leaves the backend's own limit in place.
    public var maximumResponseTokens: Int?

    public init(temperature: Double, maximumResponseTokens: Int? = nil) {
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
    }
}

// MARK: - Generation seam

/// Package-visible generation protocol so tests can inject deterministic models
/// without re-implementing the full AnyLanguageModel stack.
package protocol ExtractionGenerating: Sendable {
    func generate(
        system: String,
        user: String,
        settings: GenerationSettings,
        schema: ExtractionSchema?
    ) async throws -> String

    /// Stream cumulative response text. Default implementation calls ``generate``
    /// once and yields the full string — existing mock conformances keep working.
    func streamGenerate(
        system: String,
        user: String,
        settings: GenerationSettings,
        schema: ExtractionSchema?
    ) -> AsyncThrowingStream<String, Error>
}

extension ExtractionGenerating {
    /// Default: one-shot generate, yield once. Safe for mocks and backends without
    /// true token streaming.
    package func streamGenerate(
        system: String,
        user: String,
        settings: GenerationSettings,
        schema: ExtractionSchema?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await generate(
                        system: system,
                        user: user,
                        settings: settings,
                        schema: schema
                    )
                    continuation.yield(text)
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
}

private struct LanguageModelBackend: ExtractionGenerating {
    let model: any LanguageModel

    func generate(
        system: String,
        user: String,
        settings: GenerationSettings,
        schema: ExtractionSchema?
    ) async throws -> String {
        // Do **not** pre-check `model.isAvailable`.
        // MLXLanguageModel (and similar lazy backends) report `.notLoaded` /
        // `isAvailable == false` until the first successful `respond`, which is
        // what actually loads weights. Blocking here makes local MLX unusable.
        // Permanent unavailability (e.g. SystemLanguageModel off-device) surfaces
        // as an error from `respond` itself.
        //
        // Do **not** call `LanguageModelSession.respond(to:schema:)`.
        // In current AnyLanguageModel that overload discards the schema argument
        // and generates `GeneratedContent` (placeholder schema), which cloud
        // providers can mis-apply as `response_format`. Our JSON Schema is
        // already embedded in the user prompt via `PromptBuilder`; plain
        // `String` generation is the correct primary path.
        _ = schema
        let session = LanguageModelSession(model: model, instructions: system)
        let options = GenerationOptions(
            temperature: settings.temperature,
            maximumResponseTokens: settings.maximumResponseTokens
        )
        let response = try await session.respond(to: user, options: options)
        return response.content
    }

    func streamGenerate(
        system: String,
        user: String,
        settings: GenerationSettings,
        schema: ExtractionSchema?
    ) -> AsyncThrowingStream<String, Error> {
        _ = schema
        let model = self.model
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(model: model, instructions: system)
                    let options = GenerationOptions(
                        temperature: settings.temperature,
                        maximumResponseTokens: settings.maximumResponseTokens
                    )
                    let stream = session.streamResponse(to: user, options: options)
                    for try await snapshot in stream {
                        // String.PartiallyGenerated == String; cumulative text so far.
                        continuation.yield(snapshot.content)
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
}

private enum DefaultSessionResolver {
    static func resolve() -> ExtractionSession {
        if #available(iOS 26, macOS 26, *) {
            #if canImport(FoundationModels)
                let system = SystemLanguageModel.default
                // SystemLanguageModel availability is permanent (on-device gate),
                // not a lazy-load flag — safe to check before wrapping.
                if system.isAvailable {
                    return ExtractionSession(model: system)
                }
            #endif
        }
        return ExtractionSession(generator: UnavailableGenerator())
    }
}

private struct UnavailableGenerator: ExtractionGenerating {
    func generate(
        system: String,
        user: String,
        settings: GenerationSettings,
        schema: ExtractionSchema?
    ) async throws -> String {
        throw ExtractionError.modelUnavailable(
            """
            No language model is configured. ExtractionSession.default requires Apple Intelligence \
            (iOS 26+ / macOS 26+ with Apple Intelligence enabled), or pass an explicit model:

              let session = ExtractionSession(model: OpenAILanguageModel(apiKey: "…", model: "gpt-4o-mini"))
              let value: Receipt = try await Extract.from(source, using: session)

            See the README for MLX, Anthropic, Gemini, and Ollama setup.
            """
        )
    }
}

// MARK: - Mock model (public for tests & CLI offline mode)

/// Deterministic language model for tests and offline CLI runs.
///
/// Not used by the demo app success path — only tests, CLI `--mock`, and explicit
/// ``ExtractionSession/mock(_:temperature:)`` callers.
///
/// ## Streaming
///
/// By default ``streamGenerate`` yields each configured response as a single
/// cumulative string (via the protocol default that calls ``generate``). Construct
/// with ``init(streamingPieces:)`` or ``init(streamingResponses:)`` to emit a
/// document in several pieces — used by streaming partial tests.
public struct MockLanguageModel: ExtractionGenerating, Sendable {
    public typealias Responder = @Sendable (_ system: String, _ user: String, _ callIndex: Int) async throws -> String

    private let responder: Responder
    private let counter: CallCounter
    /// When non-nil, ``streamGenerate`` yields cumulative joins of these pieces
    /// per call index instead of a single generate().
    private let streamingPieces: [[String]]?

    public init(responses: [String]) {
        let list = responses
        self.counter = CallCounter()
        self.streamingPieces = nil
        self.responder = { _, _, index in
            if index < list.count {
                return list[index]
            }
            return list.last ?? "{}"
        }
    }

    public init(responder: @escaping Responder) {
        self.counter = CallCounter()
        self.streamingPieces = nil
        self.responder = responder
    }

    /// Single-call mock that streams `pieces` in order (each yield is the
    /// cumulative concatenation so far, matching real backends).
    public init(streamingPieces: [String]) {
        let pieces = streamingPieces
        self.counter = CallCounter()
        self.streamingPieces = [pieces]
        let full = pieces.joined()
        self.responder = { _, _, _ in full }
    }

    /// Multi-call mock: `streamingResponses[callIndex]` is the piece list for that
    /// generate/stream invocation. ``generate`` returns the joined string.
    public init(streamingResponses: [[String]]) {
        let responses = streamingResponses
        self.counter = CallCounter()
        self.streamingPieces = responses
        self.responder = { _, _, index in
            if index < responses.count {
                return responses[index].joined()
            }
            return responses.last?.joined() ?? "{}"
        }
    }

    public func generate(
        system: String,
        user: String,
        settings: GenerationSettings,
        schema: ExtractionSchema?
    ) async throws -> String {
        _ = schema
        let index = await counter.next()
        return try await responder(system, user, index)
    }

    public func streamGenerate(
        system: String,
        user: String,
        settings: GenerationSettings,
        schema: ExtractionSchema?
    ) -> AsyncThrowingStream<String, Error> {
        _ = settings
        _ = schema
        if let streamingPieces {
            let counter = self.counter
            let responder = self.responder
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let index = await counter.next()
                        if index < streamingPieces.count {
                            var cumulative = ""
                            for piece in streamingPieces[index] {
                                cumulative += piece
                                continuation.yield(cumulative)
                            }
                        } else {
                            // Fall back to full generate text for extra calls (repairs).
                            let text = try await responder(system, user, index)
                            continuation.yield(text)
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
        // One-shot: yield the full generate() result once.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await generate(
                        system: system,
                        user: user,
                        settings: settings,
                        schema: schema
                    )
                    continuation.yield(text)
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
}

private actor CallCounter {
    private var value = 0
    func next() -> Int {
        defer { value += 1 }
        return value
    }
}

extension ExtractionSession {
    /// Convenience for tests and the offline CLI (`--mock`).
    public static func mock(_ model: MockLanguageModel, temperature: Double = 0) -> ExtractionSession {
        ExtractionSession(generator: model, temperature: temperature)
    }
}
