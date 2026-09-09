import CoreGraphics
import Foundation
import Testing

@testable import Extract

/// The public inspect surface, exercised the way a caller reaches it.
///
/// Both facts below were broken through the public path while unit tests passed, because
/// the tests passed `pageIndex: 0` to `OCRAdapter.recognize` explicitly and production
/// never did — the parameter defaulted to `nil`.
@Suite("Inspect surface")
struct InspectSurfaceTests {
    @Test("inspect publishes the positioned blocks, not just their count")
    func inspectPublishesPositionedBlocks() async throws {
        let inspection = try await Extract.inspect(.fileURL(fixture("receipt.png")))
        // Not a skip: if this image yields no positioned blocks, OCR geometry is broken and
        // that is exactly what the test exists to catch. A skip here passed happily while
        // image blocks carried no page index.
        #expect(!inspection.positionedBlocks.isEmpty, "no positioned blocks from an OCR'd image")
        #expect(inspection.positionedBlocks.count == inspection.positionedBlockCount)
        for block in inspection.positionedBlocks {
            #expect(!block.text.isEmpty)
            #expect(block.pageIndex == 0, "a standalone image is page zero")
            #expect(block.boundingBox.width > 0 && block.boundingBox.height > 0)
            #expect(block.boundingBox.minX >= -0.01 && block.boundingBox.maxX <= 1.01)
            #expect(block.boundingBox.minY >= -0.01 && block.boundingBox.maxY <= 1.01)
        }
    }

    @Test("an image source gets field provenance, on page zero")
    func imageSourceHasProvenance() async throws {
        let url = fixture("receipt.png")
        let inspection = try await Extract.inspect(.fileURL(url))
        // Take the token from a positioned block, not from `fullText`: linearisation injects
        // page separators into the text, and a value matched against those is verbatim with
        // nowhere to point. Anything drawn from a block is guaranteed to have geometry.
        let words = inspection.positionedBlocks
            .flatMap { $0.text.components(separatedBy: .whitespacesAndNewlines) }
        let token = try #require(
            words.first(where: { $0.count >= 4 && $0.allSatisfy(\.isLetter) }),
            "no positioned block text to match — image blocks are missing geometry or a page"
        )

        let escaped = token.replacingOccurrences(of: "\"", with: "")
        let canned = "{\"title\":\"\(escaped)\",\"body\":\"\(escaped)\"}"
        let session = ExtractionSession.mock(MockLanguageModel(responses: [canned]))
        let result = try await Extract.detailed(from: .fileURL(url), as: TinyDoc.self, using: session)

        let titleSignal = result.signals.fields.first { $0.path == "title" }
        let provenance = try #require(
            titleSignal?.provenance,
            "an image source produced no provenance — image blocks are missing a page index"
        )
        #expect(provenance.pageIndex == 0)
        #expect(provenance.boundingBox.width > 0)
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/\(name)")
    }
}
