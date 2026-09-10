import Extract
import Foundation
import Testing

@Extractable
struct TempProbe {
    let label: String
}

@Suite("Session temperature")
struct SessionTemperatureTests {
    @Test("options.temperature nil uses session.temperature")
    func sessionTemperatureHonored() async throws {
        let recorded = TemperatureRecorder()
        let generator = RecordingGenerator(recorder: recorded, response: #"{"label":"ok"}"#)
        let session = ExtractionSession(generator: generator, temperature: 0.42)
        let options = ExtractionOptions(temperature: nil)
        let value: TempProbe = try await Extract.from("x", using: session, options: options)
        #expect(value.label == "ok")
        let temps = await recorded.temperatures
        #expect(temps == [0.42])
    }

    @Test("options.temperature overrides session.temperature")
    func optionsOverrideSession() async throws {
        let recorded = TemperatureRecorder()
        let generator = RecordingGenerator(recorder: recorded, response: #"{"label":"ok"}"#)
        let session = ExtractionSession(generator: generator, temperature: 0.9)
        let options = ExtractionOptions(temperature: 0.1)
        let _: TempProbe = try await Extract.from("x", using: session, options: options)
        let temps = await recorded.temperatures
        #expect(temps == [0.1])
    }

    @Test("schema is passed to the generator for constrained generation")
    func schemaPassed() async throws {
        let recorded = TemperatureRecorder()
        let generator = RecordingGenerator(recorder: recorded, response: #"{"label":"ok"}"#)
        let session = ExtractionSession(generator: generator, temperature: 0)
        let _: TempProbe = try await Extract.from("x", using: session)
        let schemas = await recorded.schemaTitles
        #expect(schemas.contains("TempProbe"))
    }
}

@Suite("Response cap")
struct ResponseCapTests {
    /// Nothing downstream can stop a model that will not stop: without a cap a repair-prone
    /// page generates until the request times out, and on an unattended machine that is a
    /// queue wedged behind one document.
    @Test("options.maximumResponseTokens reaches the generation seam")
    func capReachesTheSeam() async throws {
        let recorded = TemperatureRecorder()
        let generator = RecordingGenerator(recorder: recorded, response: #"{"value":"x"}"#)
        let session = ExtractionSession(generator: generator, temperature: 0)
        let options = ExtractionOptions(maximumResponseTokens: 512)
        _ = try? await Extract.from(.text("text"), as: Probe.self, using: session, options: options)
        let caps = await recorded.responseCaps
        #expect(caps.allSatisfy { $0 == 512 })
        #expect(!caps.isEmpty, "the seam was reached at least once")
    }

    @Test("no cap leaves the backend default in place")
    func absentCapStaysNil() async throws {
        let recorded = TemperatureRecorder()
        let generator = RecordingGenerator(recorder: recorded, response: #"{"value":"x"}"#)
        let session = ExtractionSession(generator: generator, temperature: 0)
        _ = try? await Extract.from(.text("text"), as: Probe.self, using: session, options: ExtractionOptions())
        let caps = await recorded.responseCaps
        #expect(caps.allSatisfy { $0 == nil })
    }

    @Test("settings resolve temperature from the session and the cap from the options")
    func resolutionCombinesBoth() {
        let generator = RecordingGenerator(recorder: TemperatureRecorder(), response: "")
        let session = ExtractionSession(generator: generator, temperature: 0.7)
        let resolved = ExtractionOptions(maximumResponseTokens: 64).resolvedGeneration(session: session)
        #expect(resolved == GenerationSettings(temperature: 0.7, maximumResponseTokens: 64))
    }
}

@Extractable
struct Probe {
    let value: String
}

actor TemperatureRecorder {
    var temperatures: [Double] = []
    var responseCaps: [Int?] = []
    var schemaTitles: [String] = []

    func record(settings: GenerationSettings, schema: ExtractionSchema?) {
        temperatures.append(settings.temperature)
        responseCaps.append(settings.maximumResponseTokens)
        if let title = schema?.title {
            schemaTitles.append(title)
        }
    }
}

struct RecordingGenerator: ExtractionGenerating {
    let recorder: TemperatureRecorder
    let response: String

    func generate(
        system: String,
        user: String,
        settings: GenerationSettings,
        schema: ExtractionSchema?
    ) async throws -> String {
        await recorder.record(settings: settings, schema: schema)
        return response
    }
}
