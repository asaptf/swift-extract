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

/// Where the first array-of-objects collection is filled from.
///
/// Default ``model`` keeps today's behaviour: the model transcribes every
/// collection element. ``geometry`` is opt-in — see ``ExtractionOptions/lineItemSource``.
public enum LineItemSource: String, Sendable, Equatable {
    /// Model transcribes the collection as part of the extraction JSON (default).
    case model
    /// Map columns with one cheap model call, then parse each row from table geometry.
    case geometry
}

/// Which path produced the first array-of-objects collection on a result.
///
/// Always populated. A geometry run that fell back to the model is
/// ``geometryFallback(reason:)``, never silent ``model`` — otherwise a
/// measurement can compare the model path against itself.
public enum CollectionSource: Sendable, Equatable {
    /// The model transcribed the collection, or geometry was not requested.
    case model
    /// Rows were built from detected table geometry after a column mapping.
    case geometry
    /// Geometry was requested but could not be used; the model transcribed the collection.
    case geometryFallback(reason: String)

    /// Stable token for reports (`model` / `geometry` / `geometryFallback`).
    public var reportToken: String {
        switch self {
        case .model: return "model"
        case .geometry: return "geometry"
        case .geometryFallback: return "geometryFallback"
        }
    }

    /// Why geometry was not used, when this is ``geometryFallback(reason:)``.
    public var fallbackReason: String? {
        if case .geometryFallback(let reason) = self { return reason }
        return nil
    }
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
    /// Where the first array-of-objects collection is filled from (default ``LineItemSource/model``).
    ///
    /// ``LineItemSource/model`` is today's path: the model transcribes the collection
    /// as part of the extraction JSON. Prompts and results are byte-identical to a
    /// build without this option.
    ///
    /// ``LineItemSource/geometry`` asks the model only to map columns, then parses
    /// every row from detected table geometry. Header / scalar fields still come
    /// from the model. Only the first array-of-objects in the schema is handled
    /// this way; later collections stay on the model path.
    public var lineItemSource: LineItemSource

    public init(
        maxRetries: Int = 2,
        chunkingStrategy: ChunkingStrategy = .automatic,
        locale: Locale? = nil,
        softContextCharacterBudget: Int = 12_000,
        temperature: Double? = nil,
        tableDetection: TableDetectionMode = .automatic,
        invariantPolicy: InvariantPolicy = .strict,
        lineItemSource: LineItemSource = .model
    ) {
        self.maxRetries = maxRetries
        self.chunkingStrategy = chunkingStrategy
        self.locale = locale
        self.softContextCharacterBudget = softContextCharacterBudget
        self.temperature = temperature
        self.tableDetection = tableDetection
        self.invariantPolicy = invariantPolicy
        self.lineItemSource = lineItemSource
    }

    /// Resolve sampling temperature: explicit options override, else session.
    public func resolvedTemperature(session: ExtractionSession) -> Double {
        temperature ?? session.temperature
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
    /// Which path produced the first array-of-objects collection.
    ///
    /// ``CollectionSource/model`` when ``ExtractionOptions/lineItemSource`` is
    /// ``LineItemSource/model`` (the default) or the type has no such collection.
    /// ``CollectionSource/geometry`` when rows were parsed from a detected table.
    /// ``CollectionSource/geometryFallback(reason:)`` when geometry was requested
    /// but could not be used (no qualifying table, unusable mapping, …). The
    /// reason is part of the value so a measurement cannot treat fallback as
    /// geometry.
    public let collectionSource: CollectionSource

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
    ///   - collectionSource: Which path produced the first array-of-objects
    ///     collection. Defaults to ``CollectionSource/model`` (source-compatible
    ///     with call sites that omit the field).
    public init(
        value: T,
        attempts: Int,
        rawModelOutput: String,
        chunksUsed: Int = 1,
        signals: ExtractionSignals? = nil,
        tables: [ExtractedTable]? = nil,
        invariantViolations: [InvariantIssue] = [],
        collectionSource: CollectionSource = .model
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
        self.collectionSource = collectionSource
    }
}
