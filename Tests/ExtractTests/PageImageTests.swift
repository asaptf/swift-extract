import CoreGraphics
import Foundation
import Testing

@testable import Extract

/// Reading the page instead of its text.
///
/// OCR is where this product's remaining errors come from: a tariff `64039993900` read as
/// `54039993900`, a part number `S1PL ESD` glued into `SIPLESD`. A model only copies what OCR
/// hands it, so two models three sizes apart make the same mistakes — measured at 97.29% and
/// 97.38% on the same document. A vision model reading the page image read both correctly in
/// twenty seconds, so the page has to be able to reach the model as a picture.
@Suite("Page images")
struct PageImageTests {
    private final class RecordingGenerator: ExtractionGenerating, @unchecked Sendable {
        let answer: String
        let canSeeImages: Bool
        private let lock = NSLock()
        private var seen: [[PageImage]] = []

        init(answer: String = "{\"a\":1}", canSeeImages: Bool = true) {
            self.answer = answer
            self.canSeeImages = canSeeImages
        }

        var calls: [[PageImage]] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }

        var readsImages: Bool { canSeeImages }

        func generate(
            system: String, user: String, settings: GenerationSettings, schema: ExtractionSchema?
        ) async throws -> String {
            try await generate(system: system, user: user, images: [], settings: settings, schema: schema)
        }

        func generate(
            system: String, user: String, images: [PageImage], settings: GenerationSettings,
            schema: ExtractionSchema?
        ) async throws -> String {
            record(images)
            return answer
        }

        private func record(_ images: [PageImage]) {
            lock.lock()
            seen.append(images)
            lock.unlock()
        }
    }

    private var png: PageImage {
        PageImage(data: Data("not really a png".utf8), mediaType: "image/png", pageIndex: 0)
    }

    @Test("a page image reaches the model")
    func imageReachesTheModel() async throws {
        let generator = RecordingGenerator()
        let session = ExtractionSession(generator: generator)
        let raw = try await session.generate(
            system: "s", user: "u", images: [png],
            settings: GenerationSettings(temperature: 0, maximumResponseTokens: nil), schema: nil)
        #expect(raw == "{\"a\":1}")
        #expect(generator.calls == [[png]])
    }

    /// An engine written before images existed reads only text. Handing it a page and calling
    /// that "reading the page" would be the quiet kind of wrong this product keeps finding, so
    /// it is refused with the reason.
    @Test("an engine that cannot see is told so, not handed a page it will ignore")
    func blindEngineIsRefused() async throws {
        let generator = RecordingGenerator(canSeeImages: false)
        let session = ExtractionSession(generator: generator)
        await #expect(throws: ExtractionError.self) {
            _ = try await session.generate(
                system: "s", user: "u", images: [png],
                settings: GenerationSettings(temperature: 0, maximumResponseTokens: nil), schema: nil)
        }
        do {
            _ = try await session.generate(
                system: "s", user: "u", images: [png],
                settings: GenerationSettings(temperature: 0, maximumResponseTokens: nil), schema: nil)
            Issue.record("expected a refusal")
        } catch let error as ExtractionError {
            #expect(error.localizedDescription.lowercased().contains("image"))
        }
    }

    @Test("text-only generation still works on an engine that cannot see")
    func blindEngineStillReadsText() async throws {
        let generator = RecordingGenerator(canSeeImages: false)
        let session = ExtractionSession(generator: generator)
        let raw = try await session.generate(
            system: "s", user: "u", images: [],
            settings: GenerationSettings(temperature: 0, maximumResponseTokens: nil), schema: nil)
        #expect(raw == "{\"a\":1}")
    }

    @Test("a page renders to a PNG the model can be handed")
    func pageRendersToPNG() throws {
        let context = CGContext(
            data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let image = try #require(context?.makeImage())
        let page = try #require(PageImage(image, pageIndex: 3))
        #expect(page.mediaType == "image/png")
        #expect(page.pageIndex == 3)
        #expect(page.data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "PNG magic bytes")
    }
}

/// The whole way through: a `.page` source hands the picture to the model and keeps the text
/// for grounding, which is what an operator's "where did this come from" depends on.
@Suite("Reading a page as a picture")
struct PageSourceTests {
    private struct SeeingModel: ExtractionGenerating, @unchecked Sendable {
        let answer: String
        let box: SendableBox
        var readsImages: Bool { true }

        func generate(
            system: String, user: String, settings: GenerationSettings, schema: ExtractionSchema?
        ) async throws -> String {
            box.record(images: [], user: user)
            return answer
        }

        func generate(
            system: String, user: String, images: [PageImage], settings: GenerationSettings,
            schema: ExtractionSchema?
        ) async throws -> String {
            box.record(images: images, user: user)
            return answer
        }
    }

    final class SendableBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var images: [PageImage] = []
        private(set) var user = ""
        func record(images: [PageImage], user: String) {
            lock.lock()
            self.images = images
            self.user = user
            lock.unlock()
        }
    }

    @Test("a page source sends the picture and still grounds against the text")
    func pageSourceSendsPictureAndKeepsText() async throws {
        let box = SendableBox()
        let session = ExtractionSession(
            generator: SeeingModel(answer: #"{"invoiceNumber":"VR1493952"}"#, box: box))
        let image = PageImage(data: Data([0x89, 0x50]), mediaType: "image/png", pageIndex: 0)
        let schema = ExtractionSchema.object(
            properties: ["invoiceNumber": .string(description: nil)], required: [])
        let result = try await Extract.detailed(
            from: .page(text: "Invoice No.: VR1493952", images: [image]),
            schema: schema, using: session)
        #expect(result.value["invoiceNumber"]?.stringValue == "VR1493952")
        #expect(box.images == [image], "the page never reached the model")
        #expect(box.user.contains("VR1493952"), "the text is still there to ground against")
    }

    @Test("a text source sends no picture at all")
    func textSourceSendsNothing() async throws {
        let box = SendableBox()
        let session = ExtractionSession(
            generator: SeeingModel(answer: #"{"invoiceNumber":"VR1"}"#, box: box))
        let schema = ExtractionSchema.object(
            properties: ["invoiceNumber": .string(description: nil)], required: [])
        _ = try await Extract.detailed(from: .text("Invoice No.: VR1"), schema: schema, using: session)
        #expect(box.images.isEmpty)
    }
}
