import Foundation
import Testing

@testable import Extract

/// A model that answers nothing is not a model that answered badly.
///
/// Measured: Qwen3.6-27B is a reasoning model, so on a page pass it spent the whole response
/// cap on hidden thinking and returned an empty `content` with `finish_reason: "length"`. The
/// engine handed that empty string to the decoder, which said "the data couldn't be read
/// because it isn't in the correct format", retried twice more, and abandoned a six-page
/// document — fifty-five minutes for an error message that pointed at the wrong thing.
@Suite("Empty model responses")
struct EmptyResponseTests {
    private struct SilentGenerator: ExtractionGenerating {
        let text: String
        func generate(
            system: String, user: String, settings: GenerationSettings, schema: ExtractionSchema?
        ) async throws -> String { text }
    }

    @Test("an empty answer says so, and names the cap that most likely caused it", arguments: ["", "   \n\t "])
    func emptyAnswerIsItsOwnError(text: String) async throws {
        let session = ExtractionSession(generator: SilentGenerator(text: text))
        await #expect(throws: ExtractionError.self) {
            _ = try await session.generate(
                system: "s", user: "u",
                settings: GenerationSettings(temperature: 0, maximumResponseTokens: 8192),
                schema: nil)
        }
        do {
            _ = try await session.generate(
                system: "s", user: "u",
                settings: GenerationSettings(temperature: 0, maximumResponseTokens: 8192),
                schema: nil)
            Issue.record("an empty response must not be passed on as an answer")
        } catch let error as ExtractionError {
            let message = error.localizedDescription
            #expect(message.contains("nothing") || message.contains("empty"))
            #expect(message.contains("8192"), "the cap is the first thing to check: \(message)")
        }
    }

    @Test("an answer with content in it is passed through untouched")
    func realAnswerPassesThrough() async throws {
        let session = ExtractionSession(generator: SilentGenerator(text: "{\"a\":1}"))
        let raw = try await session.generate(
            system: "s", user: "u",
            settings: GenerationSettings(temperature: 0, maximumResponseTokens: nil), schema: nil)
        #expect(raw == "{\"a\":1}")
    }

    @Test("with no cap set, the message says what it can rather than inventing a number")
    func withoutACapTheMessageStaysHonest() async throws {
        let session = ExtractionSession(generator: SilentGenerator(text: ""))
        do {
            _ = try await session.generate(
                system: "s", user: "u",
                settings: GenerationSettings(temperature: 0, maximumResponseTokens: nil), schema: nil)
            Issue.record("expected a throw")
        } catch let error as ExtractionError {
            #expect(!error.localizedDescription.contains("nil"))
        }
    }
}
