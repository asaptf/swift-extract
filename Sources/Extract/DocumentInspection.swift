import CoreGraphics
import Foundation

/// A text run from ingestion that carried a position: what was read, and where.
///
/// Same geometry convention as ``FieldProvenance`` — ``pageIndex`` is 0-based (an image is
/// page `0`, frame `n` of a multi-frame image page `n`) and ``boundingBox`` is normalised with a **top-left** origin, x right / y
/// down. Both are non-optional here: ``DocumentInspection/positionedBlocks`` contains only
/// blocks that actually carry a position, which is what makes them useful for checking or
/// drawing provenance without a model call.
public struct PositionedBlock: Sendable, Equatable {
    /// Text as the PDF text layer or OCR read it.
    public let text: String
    /// Zero-based page index; an image is page `0`, and frame `n` of a multi-frame image page `n`.
    public let pageIndex: Int
    /// Normalised top-left bounding box.
    public let boundingBox: CGRect
    /// How many OCR passes produced this reading, out of how many actually read
    /// this region. One pass is `1/1`.
    public let agreement: OCRAgreement
    /// What the other passes read at this same place, when they read something else.
    ///
    /// These stay off the page — putting both readings in the text doubled it and cost
    /// thirteen points — but a caller that knows what a field is *supposed* to look like can
    /// use them. Measured on the customer invoice: the primary pass reads `63314` and
    /// `AIRTWIST ... FO HRO SRI` where another pass, at the same geometry, reads `633140` and
    /// `AIRTWIST ... FO HRO SR`. Without this the better reading was taken and thrown away.
    public let alternatives: [String]
    /// Which way up the line stood in the frame ``boundingBox`` is measured in.
    ///
    /// Almost always `.upright`: the page is turned before it is read. A line read upside down
    /// has the right text and the right box, and its words run the opposite way along that box,
    /// so a caller that lays the text back over the page — a searchable text layer — has to lay
    /// such a line turned half a turn inside its box, or every word lands at the mirrored end.
    public let lineOrientation: LineOrientation

    public init(
        text: String,
        pageIndex: Int,
        boundingBox: CGRect,
        agreement: OCRAgreement = OCRAgreement(matchingPasses: 1, observingPasses: 1),
        alternatives: [String] = [],
        lineOrientation: LineOrientation = .unknown
    ) {
        self.text = text
        self.pageIndex = pageIndex
        self.boundingBox = boundingBox
        self.agreement = agreement
        self.alternatives = alternatives
        self.lineOrientation = lineOrientation
    }
}

/// Which way up a line of OCR text stood in the frame its box is measured in.
///
/// Told from the order of the line's words along its box, against the direction its script is
/// written in — Vision reads a line upside down as well as the right way up, and the order is
/// the one thing about the reading that changes.
public enum LineOrientation: String, Sendable, Equatable {
    /// The words run along the box the way the script is written: left to right for Latin,
    /// right to left for Arabic.
    case upright
    /// The words run the other way: the line stood half a turn round in this frame.
    case upsideDown
    /// Nothing to tell it by — a line of one word, a line lying down the page, an OCR engine that
    /// gives no per-character positions — or no reading at all: a text layer's words are laid
    /// as the PDF stores them.
    case unknown
}

/// Where one page's text came from.
///
/// The choice is made per page and it is already made — ``TextLayerQuality/shouldOCR(text:policy:threshold:)``
/// decides it for every page of every PDF — but its answer used to stay inside ingest, where
/// the only thing published was ``DocumentInspection/usedOCRFallback``: one flag saying that
/// *some* page of the document was OCR'd. A caller that wants to give a scan a text layer
/// cannot act on one flag. On a merged PDF — a digital cover sheet bound in front of scanned
/// pages, which is what an office printer produces — it would stamp recognised text over the
/// cover's real text and double it.
public enum PageTextSource: String, Sendable, Equatable {
    /// The page's own text layer, as the PDF stores it.
    case textLayer
    /// OCR over a render of the page.
    case ocr
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
    /// Where each page's text came from, keyed by page index.
    ///
    /// A page is here when it yielded text, and its value says what produced that text —
    /// what actually happened, not what was asked for: a page sent to OCR that came back
    /// with nothing, and fell through to its own text layer, reads ``PageTextSource/textLayer``.
    /// A page that yielded no text at all is absent.
    public let pageSources: [Int: PageTextSource]

    public init(
        sourceDescription: String,
        characterCount: Int,
        fullText: String,
        usedOCRFallback: Bool,
        positionedBlocks: [PositionedBlock],
        tables: [ExtractedTable],
        pageRotations: [Int: Int] = [:],
        pageSources: [Int: PageTextSource] = [:]
    ) {
        self.sourceDescription = sourceDescription
        self.characterCount = characterCount
        self.fullText = fullText
        self.usedOCRFallback = usedOCRFallback
        self.positionedBlocks = positionedBlocks
        self.tables = tables
        self.pageRotations = pageRotations
        self.pageSources = pageSources
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
            return PositionedBlock(
                text: block.text, pageIndex: page, boundingBox: box, agreement: block.agreement,
                alternatives: block.alternatives, lineOrientation: block.lineOrientation)
        }
        return DocumentInspection(
            sourceDescription: document.sourceDescription,
            characterCount: text.count,
            fullText: text,
            usedOCRFallback: document.usedOCRFallback,
            positionedBlocks: positionedBlocks,
            tables: tables,
            pageRotations: document.pageRotations,
            pageSources: document.pageSources
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
