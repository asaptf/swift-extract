import CoreGraphics
import Foundation

/// A text run from ingestion that carried a position: what was read, and where.
///
/// Same geometry convention as ``FieldProvenance`` — ``pageIndex`` is 0-based (images are
/// page `0`) and ``boundingBox`` is normalised with a **top-left** origin, x right / y
/// down. Both are non-optional here: ``DocumentInspection/positionedBlocks`` contains only
/// blocks that actually carry a position, which is what makes them useful for checking or
/// drawing provenance without a model call.
public struct PositionedBlock: Sendable, Equatable {
    /// Text as the PDF text layer or OCR read it.
    public let text: String
    /// Zero-based page index; images are page `0`.
    public let pageIndex: Int
    /// Normalised top-left bounding box.
    public let boundingBox: CGRect

    public init(text: String, pageIndex: Int, boundingBox: CGRect) {
        self.text = text
        self.pageIndex = pageIndex
        self.boundingBox = boundingBox
    }
}

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
    /// Number of blocks that carried a position (inputs to geometric table detection).
    ///
    /// Derived from ``positionedBlocks`` rather than stored, so the two can never disagree.
    /// Kept as a named member because metrics-only callers report the count without holding
    /// document text — the harness writes reports from real invoices.
    public var positionedBlockCount: Int { positionedBlocks.count }
    /// The positioned blocks themselves — text, page, and box.
    ///
    /// `inspect` previously published only the count, so a caller could not verify or draw
    /// per-page provenance without running an extraction. Carries document text, so the
    /// same privacy note as ``fullText`` applies.
    public let positionedBlocks: [PositionedBlock]
    /// Tables from ``TableDetector`` under the requested mode.
    public let tables: [ExtractedTable]
    /// Clockwise degrees each page was turned by before it was read, keyed by page index.
    ///
    /// The boxes in ``positionedBlocks`` are in the turned frame — the one the text reads
    /// upright in — not the frame the page is stored in. An application that renders a page
    /// for a person to look at must turn it the same way; otherwise every box it draws over
    /// that page lands somewhere the value is not. Pages that were not turned are absent.
    public let pageRotations: [Int: Int]

    public init(
        sourceDescription: String,
        characterCount: Int,
        fullText: String,
        usedOCRFallback: Bool,
        positionedBlocks: [PositionedBlock],
        tables: [ExtractedTable],
        pageRotations: [Int: Int] = [:]
    ) {
        self.sourceDescription = sourceDescription
        self.characterCount = characterCount
        self.fullText = fullText
        self.usedOCRFallback = usedOCRFallback
        self.positionedBlocks = positionedBlocks
        self.tables = tables
        self.pageRotations = pageRotations
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
        let positionedBlocks = document.blocks.compactMap { block -> PositionedBlock? in
            guard let box = block.boundingBox, let page = block.pageIndex else { return nil }
            return PositionedBlock(text: block.text, pageIndex: page, boundingBox: box)
        }
        return DocumentInspection(
            sourceDescription: document.sourceDescription,
            characterCount: text.count,
            fullText: text,
            usedOCRFallback: document.usedOCRFallback,
            positionedBlocks: positionedBlocks,
            tables: tables,
            pageRotations: document.pageRotations
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
