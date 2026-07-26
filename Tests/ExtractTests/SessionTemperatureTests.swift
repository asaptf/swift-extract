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

actor TemperatureRecorder {
    var temperatures: [Double] = []
    var schemaTitles: [String] = []

    func record(temperature: Double, schema: ExtractionSchema?) {
        temperatures.append(temperature)
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
        temperature: Double,
        schema: ExtractionSchema?
    ) async throws -> String {
        await recorder.record(temperature: temperature, schema: schema)
        return response
    }
}
