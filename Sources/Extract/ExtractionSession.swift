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
    /// When `true`, generation routes through token-level constrained JSON decoding
    /// for a runtime schema. Default `false` preserves the prompt-only path.
    public let guidedGeneration: Bool

    /// Create a session from any AnyLanguageModel-compatible model.
    ///
    /// - Parameters:
    ///   - model: Backend language model.
    ///   - temperature: Default sampling temperature for this session.
    ///   - guidedGeneration: Opt-in constrained JSON path. Off by default so prompt
    ///     bytes and free-form decoding stay unchanged. When enabled, the model must
    ///     report ``LanguageModel/supportsSchemaConstrainedGeneration``; there is no
    ///     silent fallback to the prompt-only path.
    public init(
        model: any LanguageModel,
        temperature: Double = 0,
        guidedGeneration: Bool = false
    ) {
        self.backend = LanguageModelBackend(model: model, guidedGeneration: guidedGeneration)
        self.temperature = temperature
        self.guidedGeneration = guidedGeneration
    }

    /// Test / offline injection point.
    package init(
        generator: any ExtractionGenerating,
        temperature: Double = 0,
        guidedGeneration: Bool = false
    ) {
        self.backend = generator
        self.temperature = temperature
        self.guidedGeneration = guidedGeneration
    }

    func generate(
        system: String,
        user: String,
        temperature: Double,
        schema: ExtractionSchema?
    ) async throws -> String {
        try await backend.generate(
            system: system,
            user: user,
            temperature: temperature,
            schema: schema
        )
    }
}

// MARK: - Generation seam

/// Package-visible generation protocol so tests can inject deterministic models
/// without re-implementing the full AnyLanguageModel stack.
package protocol ExtractionGenerating: Sendable {
    func generate(
        system: String,
        user: String,
        temperature: Double,
        schema: ExtractionSchema?
    ) async throws -> String
}

private struct LanguageModelBackend: ExtractionGenerating {
    let model: any LanguageModel
    let guidedGeneration: Bool

    func generate(
        system: String,
        user: String,
        temperature: Double,
        schema: ExtractionSchema?
    ) async throws -> String {
        // Do **not** pre-check `model.isAvailable`.
        // MLXLanguageModel (and similar lazy backends) report `.notLoaded` /
        // `isAvailable == false` until the first successful `respond`, which is
        // what actually loads weights. Blocking here makes local MLX unusable.
        // Permanent unavailability (e.g. SystemLanguageModel off-device) surfaces
        // as an error from `respond` itself.
        //
        // Generation paths:
        // - Default (guidedGeneration == false): plain-string `respond`. AnyLanguageModel
        //   does implement token-level constrained JSON (`ConstrainedJSONGenerator` +
        //   `TokenBackend` on MLX / Core ML / llama.cpp), but
        //   `LanguageModelSession.respond(to:schema:)` historically discarded the runtime
        //   schema and forwarded to `GeneratedContent` (placeholder static schema). Cloud
        //   providers can also mis-apply that overload as `response_format`. Our JSON Schema
        //   is already embedded in the user prompt via `PromptBuilder`, so free-form
        //   `String` generation is the correct default / measurement baseline.
        // - Guided (opt-in): convert `ExtractionSchema` → `GenerationSchema` via
        //   `SchemaBridge` and call the patched schema-taking model entry point (reached
        //   through `LanguageModelSession.respond(to:schema:)`). Requires
        //   `supportsSchemaConstrainedGeneration`; no silent fallback to the prompt-only path.
        let session = LanguageModelSession(model: model, instructions: system)
        let options = GenerationOptions(temperature: temperature)

        if guidedGeneration {
            guard model.supportsSchemaConstrainedGeneration else {
                throw ExtractionError.modelUnavailable(
                    """
                    Guided generation is enabled, but this language model does not support \
                    token-level constrained JSON for a runtime schema \
                    (supportsSchemaConstrainedGeneration == false). Refusing to fall back to \
                    the prompt-only path so A/B measurements stay honest.
                    """
                )
            }
            guard let schema else {
                throw ExtractionError.internalError(
                    "Guided generation requires an ExtractionSchema, but none was supplied."
                )
            }
            let generationSchema = try schema.toGenerationSchema()
            // Schema text is already in the user prompt (PromptBuilder). Do not inject a
            // second copy via the model layer — keep the prompt comparable to the baseline arm.
            let response = try await session.respond(
                to: user,
                schema: generationSchema,
                includeSchemaInPrompt: false,
                options: options
            )
            return response.content.jsonString
        }

        let response = try await session.respond(to: user, options: options)
        return response.content
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
        temperature: Double,
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
/// The mock has no token-level schema engine. A ``guidedGeneration`` flag on the
/// surrounding session is therefore ignored (same free-form canned responses).
public struct MockLanguageModel: ExtractionGenerating, Sendable {
    public typealias Responder = @Sendable (_ system: String, _ user: String, _ callIndex: Int) async throws -> String

    private let responder: Responder
    private let counter: CallCounter

    public init(responses: [String]) {
        let list = responses
        self.counter = CallCounter()
        self.responder = { _, _, index in
            if index < list.count {
                return list[index]
            }
            return list.last ?? "{}"
        }
    }

    public init(responder: @escaping Responder) {
        self.counter = CallCounter()
        self.responder = responder
    }

    public func generate(
        system: String,
        user: String,
        temperature: Double,
        schema: ExtractionSchema?
    ) async throws -> String {
        _ = schema
        let index = await counter.next()
        return try await responder(system, user, index)
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
    public static func mock(
        _ model: MockLanguageModel,
        temperature: Double = 0,
        guidedGeneration: Bool = false
    ) -> ExtractionSession {
        // Mock has no constrained decoder; flag is stored for reporting only.
        ExtractionSession(
            generator: model,
            temperature: temperature,
            guidedGeneration: guidedGeneration
        )
    }
}
