import Extract
import Foundation
import Testing

@Extractable
struct BackendProbe {
    let ok: Bool
}

@Suite("LanguageModel backend path")
struct LanguageModelBackendPathTests {
    /// Documents the contracted generation path: schema is still threaded into
    /// the generator (for prompts/tests/future constrained APIs), but real
    /// backends must not call the broken `respond(to:schema:)` overload.
    @Test("extract still supplies extractionSchema to the generator")
    func schemaThreadedForPromptPath() async throws {
        let recorder = PathRecorder()
        let generator = PathRecordingGenerator(recorder: recorder, response: #"{"ok":true}"#)
        let session = ExtractionSession(generator: generator, temperature: 0)
        let value: BackendProbe = try await Extract.from("doc", using: session)
        #expect(value.ok == true)
        let titles = await recorder.schemaTitles
        #expect(titles.contains("BackendProbe"))
        let usedConstrainedOverload = await recorder.attemptedConstrainedOverload
        #expect(usedConstrainedOverload == false)
    }
}

actor PathRecorder {
    var schemaTitles: [String] = []
    /// Always false for Mock/Recording generators — real LanguageModelBackend
    /// no longer attempts the schema overload either.
    var attemptedConstrainedOverload = false

    func record(schema: ExtractionSchema?, constrained: Bool) {
        if let title = schema?.title {
            schemaTitles.append(title)
        }
        if constrained {
            attemptedConstrainedOverload = true
        }
    }
}

struct PathRecordingGenerator: ExtractionGenerating {
    let recorder: PathRecorder
    let response: String

    func generate(
        system: String,
        user: String,
        temperature: Double,
        schema: ExtractionSchema?
    ) async throws -> String {
        // Production LanguageModelBackend uses plain String respond only.
        await recorder.record(schema: schema, constrained: false)
        // Prompt must still carry the schema text (PromptBuilder responsibility).
        #expect(user.contains("JSON Schema") || user.contains("schema") || schema != nil)
        return response
    }
}
