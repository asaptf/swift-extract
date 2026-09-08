import Foundation

/// Result of inspecting a document **without** calling a language model.
///
/// Used by the evaluation harness (survey mode, anchors, pairing checks) and any
/// caller that needs ingestion metrics / geometric tables without extraction cost.
///
/// Privacy note: ``fullText`` may contain private invoice content. Callers that
/// write reports should omit it unless the user explicitly opts in.
public struct DocumentInspection: Sendable, Equatable {
    /// Adapter source label (typically the file name).
    public let sourceDescription: String
    /// Character count of ``fullText``.
    public let characterCount: Int
    /// Linearised document text (same text the extraction prompt would use).
    public let fullText: String
    /// True when a PDF used OCR because the text layer was missing or below the quality gate.
    public let usedOCRFallback: Bool
    /// Blocks that carried a bounding box (inputs to geometric table detection).
    public let positionedBlockCount: Int
    /// Tables from ``TableDetector`` under the requested mode.
    public let tables: [ExtractedTable]

    public init(
        sourceDescription: String,
        characterCount: Int,
        fullText: String,
        usedOCRFallback: Bool,
        positionedBlockCount: Int,
        tables: [ExtractedTable]
    ) {
        self.sourceDescription = sourceDescription
        self.characterCount = characterCount
        self.fullText = fullText
        self.usedOCRFallback = usedOCRFallback
        self.positionedBlockCount = positionedBlockCount
        self.tables = tables
    }
}

extension Extract {
    /// Ingest a source and run geometric table detection — no model call.
    ///
    /// - Parameters:
    ///   - source: Document to inspect.
    ///   - tableDetection: Detection mode (default ``TableDetectionMode/automatic``).
    /// - Returns: Text metrics, OCR-fallback flag, and detected tables.
    public static func inspect(
        _ source: ExtractionSource,
        tableDetection: TableDetectionMode = .automatic,
        options: ExtractionOptions = .init(),
        ingest: IngestContext = IngestContext()
    ) async throws -> DocumentInspection {
        let document = try await SourceIngester.ingest(source, options: options, engines: ingest)
        guard !document.isEmpty else {
            throw ExtractionError.emptyDocument
        }
        let tables = TableDetector.detect(
            documentBlocks: document.blocks,
            mode: tableDetection
        )
        let text = document.fullText
        let positioned = document.blocks.filter { $0.boundingBox != nil }.count
        return DocumentInspection(
            sourceDescription: document.sourceDescription,
            characterCount: text.count,
            fullText: text,
            usedOCRFallback: document.usedOCRFallback,
            positionedBlockCount: positioned,
            tables: tables
        )
    }

    /// Convenience: inspect a file URL (type sniff via ``ExtractionSource/fileURL``).
    public static func inspect(
        _ url: URL,
        tableDetection: TableDetectionMode = .automatic,
        options: ExtractionOptions = .init(),
        ingest: IngestContext = IngestContext()
    ) async throws -> DocumentInspection {
        try await inspect(.fileURL(url), tableDetection: tableDetection, options: options, ingest: ingest)
    }
}
