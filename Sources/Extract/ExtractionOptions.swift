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
    /// Generation temperature (default 0 for deterministic extraction).
    public var temperature: Double

    public init(
        maxRetries: Int = 2,
        chunkingStrategy: ChunkingStrategy = .automatic,
        locale: Locale? = nil,
        softContextCharacterBudget: Int = 12_000,
        temperature: Double = 0
    ) {
        self.maxRetries = maxRetries
        self.chunkingStrategy = chunkingStrategy
        self.locale = locale
        self.softContextCharacterBudget = softContextCharacterBudget
        self.temperature = temperature
    }
}

/// Full extraction outcome including metadata.
public struct ExtractionResult<T: Extractable>: Sendable {
    public let value: T
    public let attempts: Int
    public let rawModelOutput: String
    public let chunksUsed: Int

    public init(value: T, attempts: Int, rawModelOutput: String, chunksUsed: Int = 1) {
        self.value = value
        self.attempts = attempts
        self.rawModelOutput = rawModelOutput
        self.chunksUsed = chunksUsed
    }
}
