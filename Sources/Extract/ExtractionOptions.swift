import Foundation

/// Strategy for documents that may exceed the model context window.
public enum ChunkingStrategy: Sendable, Equatable {
    /// Split large documents into chunks, extract each, then merge deterministically.
    case automatic
    /// Never chunk; send the full document (may fail on huge inputs).
    case none
    /// Fixed character budget per chunk.
    case fixed(characterBudget: Int)
}

/// What happens after the repair loop cannot satisfy ``Extractable/validateInvariants()``.
///
/// Decode failures always throw ``ExtractionError/validationFailed`` — this policy
/// only applies when a value decoded and its invariants failed. The repair loop
/// still runs the same number of attempts either way.
///
/// ``Extract/from`` ignores this and always throws: it returns a bare `T` with
/// nowhere to attach remaining issues. Use ``Extract/detailed`` or
/// ``Extract/stream`` to receive the value with
/// ``ExtractionResult/invariantViolations``.
public enum InvariantPolicy: Sendable, Equatable {
    /// Repair, then throw ``ExtractionError/validationFailed`` (default; today's behaviour).
    case strict
    /// Repair, then return the last successfully decoded value with remaining
    /// ``InvariantIssue``s on ``ExtractionResult/invariantViolations``.
    case reportViolations
}

/// When to trust a PDF text layer versus rasterising the page and running OCR.
public enum TextLayerPolicy: String, Sendable, Equatable {
    /// Per page: missing or low-quality text layer → OCR (default).
    case auto
    /// Always use the PDF text layer; never OCR.
    case always
    /// Always OCR; ignore the text layer.
    case never
}

/// Options controlling a single extraction run.
public struct ExtractionOptions: Sendable, Equatable {
    /// Instructor-style repair retries after the first attempt (default 2 → up to 3 total tries).
    public var maxRetries: Int
    /// How to handle documents larger than the soft context budget.
    public var chunkingStrategy: ChunkingStrategy
    /// Locale hint for date/number parsing and the prompt.
    public var locale: Locale?
    /// Soft character budget before automatic chunking kicks in.
    public var softContextCharacterBudget: Int
    /// Generation temperature override. When `nil` (default), uses
    /// ``ExtractionSession/temperature`` so session configuration is honored.
    public var temperature: Double?
    /// Geometric table reconstruction from positioned blocks (default ``TableDetectionMode/automatic``).
    ///
    /// Under ``TableDetectionMode/automatic``, detection still runs when positioned
    /// blocks exist and detections are always returned on ``ExtractionResult/tables``.
    /// Tables are appended to the model prompt only when the target type’s schema
    /// contains a collection (array); header-only types get a prompt byte-identical
    /// to ``TableDetectionMode/off``. Set ``TableDetectionMode/off`` to skip detection
    /// entirely.
    public var tableDetection: TableDetectionMode
    /// How exhausted invariant retries are reported (default ``InvariantPolicy/strict``).
    public var invariantPolicy: InvariantPolicy
    /// When a PDF page's text layer is used versus OCR (default ``TextLayerPolicy/auto``).
    public var textLayerPolicy: TextLayerPolicy
    /// Minimum ``TextLayerQuality/score(_:)`` to keep a text layer under ``TextLayerPolicy/auto``.
    /// Default `0.85`.
    public var textLayerQualityThreshold: Double
    /// Rasterisation resolution for OCR, in DPI. Default `300`, clamped to `72...400`.
    public var rasterDPI: Double
    /// Detect scan orientation (0/90 axis, then 180° via character order) when OCR runs.
    /// `/Rotate` is always honoured. Default `true`.
    public var autoOrient: Bool
    /// Scripts the pages may be printed in, as Vision language codes — `["ar-SA", "en-US"]`
    /// for an Arabic invoice with Latin part numbers.
    ///
    /// Empty means **detect the script**, not "English". Vision does not refuse a script it
    /// was not asked for, it approximates it: `الكمية 12 الوزن 1,285` came back as
    /// `1,285 ja|| 12 tall` — plausible, wrong, and carrying no signal that anything was
    /// missed. Detection reads that page properly.
    ///
    /// Say the scripts when you know them. Detection weighs every script it supports, so on
    /// dense small print a smudge can become a character from a script the page does not
    /// contain: on one scanned invoice it read the article number `644610` as `544610` and
    /// produced fragments of CJK. Naming the script is measurably better than detecting it
    /// — and both are better than assuming.
    public var recognitionLanguages: [String]
    /// Vision's language correction, which fits a word to the recognition languages. Worth
    /// having on a single-script page and worth turning off on a mixed one, where correcting
    /// one script mangles the other. Default `true`, the engine's own default.
    public var usesLanguageCorrection: Bool
    /// Hard cap on how many tokens the model may produce for one request.
    ///
    /// Nothing downstream can stop a model that will not stop: a repair-prone page can
    /// generate until the request times out, and on an unattended machine that is a queue
    /// wedged behind one document. `nil` leaves the backend's own default in place.
    public var maximumResponseTokens: Int?

    public init(
        maxRetries: Int = 2,
        chunkingStrategy: ChunkingStrategy = .automatic,
        locale: Locale? = nil,
        softContextCharacterBudget: Int = 12_000,
        temperature: Double? = nil,
        tableDetection: TableDetectionMode = .automatic,
        invariantPolicy: InvariantPolicy = .strict,
        textLayerPolicy: TextLayerPolicy = .auto,
        textLayerQualityThreshold: Double = 0.85,
        rasterDPI: Double = 300,
        autoOrient: Bool = true,
        recognitionLanguages: [String] = [],
        usesLanguageCorrection: Bool = true,
        maximumResponseTokens: Int? = nil
    ) {
        self.maxRetries = maxRetries
        self.chunkingStrategy = chunkingStrategy
        self.locale = locale
        self.softContextCharacterBudget = softContextCharacterBudget
        self.temperature = temperature
        self.tableDetection = tableDetection
        self.invariantPolicy = invariantPolicy
        self.textLayerPolicy = textLayerPolicy
        self.textLayerQualityThreshold = textLayerQualityThreshold
        self.rasterDPI = rasterDPI
        self.autoOrient = autoOrient
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.maximumResponseTokens = maximumResponseTokens
    }

    /// Resolve sampling temperature: explicit options override, else session.
    public func resolvedTemperature(session: ExtractionSession) -> Double {
        temperature ?? session.temperature
    }

    /// Sampling knobs resolved once, so every generation path sends the same thing.
    public func resolvedGeneration(session: ExtractionSession) -> GenerationSettings {
        GenerationSettings(
            temperature: resolvedTemperature(session: session),
            maximumResponseTokens: maximumResponseTokens
        )
    }
}

/// Full extraction outcome including metadata, grounding signals, and tables.
///
/// ``signals`` are **informational evidence, not a calibrated confidence score**.
/// There is no probability attached; do not threshold them for auto-accept.
/// See ``ExtractionSignals`` and ``Grounding``.
///
/// ``tables`` are geometrically reconstructed grids from OCR/PDF positions (not a
/// trained table model). Empty when detection is off, finds nothing, or the source
/// has no geometry.
///
/// ``invariantViolations`` is empty on the default ``InvariantPolicy/strict`` path
/// (a returned result means invariants held). It is non-empty only when the caller
/// opted into ``InvariantPolicy/reportViolations`` and retries could not satisfy
/// the checks — the same ``InvariantIssue`` values ``InvariantValidationError``
/// carries. ``Extract/from`` never returns in that state: it throws instead.
public struct ExtractionResult<T: Extractable>: Sendable {
    public let value: T
    public let attempts: Int
    public let rawModelOutput: String
    public let chunksUsed: Int
    /// Per-leaf grounding and run metadata. Always populated by ``Extract``; empty
    /// ``ExtractionSignals/fields`` when constructed without source text.
    public let signals: ExtractionSignals
    /// Tables detected for this document (full-document detection, not per-chunk).
    /// Empty array when none were found or ``TableDetectionMode/off`` was set.
    public let tables: [ExtractedTable]
    /// Remaining field-addressable invariant issues after the repair loop.
    /// Empty unless ``InvariantPolicy/reportViolations`` was set and retries
    /// were exhausted with a decoded value.
    public let invariantViolations: [InvariantIssue]

    /// ``InvariantValidationError`` wrapping ``invariantViolations``, or `nil`
    /// when there are none.
    public var invariantValidationError: InvariantValidationError? {
        guard !invariantViolations.isEmpty else { return nil }
        return InvariantValidationError(issues: invariantViolations)
    }

    /// - Parameters:
    ///   - value: Decoded extractable value.
    ///   - attempts: Total generation attempts.
    ///   - rawModelOutput: Last raw model text.
    ///   - chunksUsed: Document chunks that contributed.
    ///   - signals: Optional precomputed signals. When `nil`, a placeholder with
    ///     matching attempt/chunk counts and no field rows is used (source-compatible
    ///     for call sites that construct results without source text).
    ///   - tables: Optional detected tables. When `nil`, defaults to `[]`
    ///     (source-compatible with call sites that omit tables).
    ///   - invariantViolations: Remaining issues after an opted-in report. Defaults
    ///     to `[]` (source-compatible with call sites that omit the field).
    public init(
        value: T,
        attempts: Int,
        rawModelOutput: String,
        chunksUsed: Int = 1,
        signals: ExtractionSignals? = nil,
        tables: [ExtractedTable]? = nil,
        invariantViolations: [InvariantIssue] = []
    ) {
        self.value = value
        self.attempts = attempts
        self.rawModelOutput = rawModelOutput
        self.chunksUsed = chunksUsed
        self.signals =
            signals
            ?? ExtractionSignals(attempts: attempts, chunksUsed: chunksUsed, fields: [])
        self.tables = tables ?? []
        self.invariantViolations = invariantViolations
    }
}
