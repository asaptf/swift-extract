import Foundation

/// Strategy for documents that may exceed the model context window.
public enum ChunkingStrategy: Sendable, Equatable {
    /// Split large documents into chunks, extract each, then merge.
    case automatic
    /// Never chunk; send the full document (may fail on huge inputs).
    case none
    /// Fixed character budget per chunk.
    case fixed(characterBudget: Int)
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
    /// Stage 1 exposes the flag and ``TableDetector``; wiring into prompts is stage 2.
    /// Callers can set ``TableDetectionMode/off`` to disable detection entirely.
    public var tableDetection: TableDetectionMode

    public init(
        maxRetries: Int = 2,
        chunkingStrategy: ChunkingStrategy = .automatic,
        locale: Locale? = nil,
        softContextCharacterBudget: Int = 12_000,
        temperature: Double? = nil,
        tableDetection: TableDetectionMode = .automatic
    ) {
        self.maxRetries = maxRetries
        self.chunkingStrategy = chunkingStrategy
        self.locale = locale
        self.softContextCharacterBudget = softContextCharacterBudget
        self.temperature = temperature
        self.tableDetection = tableDetection
    }

    /// Resolve sampling temperature: explicit options override, else session.
    public func resolvedTemperature(session: ExtractionSession) -> Double {
        temperature ?? session.temperature
    }
}

/// Full extraction outcome including metadata and grounding signals.
///
/// ``signals`` are **informational evidence, not a calibrated confidence score**.
/// There is no probability attached; do not threshold them for auto-accept.
/// See ``ExtractionSignals`` and ``Grounding``.
public struct ExtractionResult<T: Extractable>: Sendable {
    public let value: T
    public let attempts: Int
    public let rawModelOutput: String
    public let chunksUsed: Int
    /// Per-leaf grounding and run metadata. Always populated by ``Extract``; empty
    /// ``ExtractionSignals/fields`` when constructed without source text.
    public let signals: ExtractionSignals

    /// - Parameters:
    ///   - value: Decoded extractable value.
    ///   - attempts: Total generation attempts.
    ///   - rawModelOutput: Last raw model text.
    ///   - chunksUsed: Document chunks that contributed.
    ///   - signals: Optional precomputed signals. When `nil`, a placeholder with
    ///     matching attempt/chunk counts and no field rows is used (source-compatible
    ///     for call sites that construct results without source text).
    public init(
        value: T,
        attempts: Int,
        rawModelOutput: String,
        chunksUsed: Int = 1,
        signals: ExtractionSignals? = nil
    ) {
        self.value = value
        self.attempts = attempts
        self.rawModelOutput = rawModelOutput
        self.chunksUsed = chunksUsed
        self.signals =
            signals
            ?? ExtractionSignals(attempts: attempts, chunksUsed: chunksUsed, fields: [])
    }
}
