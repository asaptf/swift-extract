import Foundation

/// Typed failures produced by the extraction pipeline.
public enum ExtractionError: Error, Sendable, LocalizedError {
    /// The source could not be read or converted into text.
    case unreadableSource(underlying: Error?)
    /// The document produced no extractable text.
    case emptyDocument
    /// No usable language model is configured.
    case modelUnavailable(String)
    /// Decoding/validation failed after the allowed number of repair attempts.
    case validationFailed(attempts: Int, lastError: Error, rawOutput: String)
    /// Chunk merge could not produce a valid combined object.
    case mergeFailed(String)
    /// Internal / unexpected condition.
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableSource(let underlying):
            if let underlying {
                return "Could not read the extraction source: \(underlying.localizedDescription)"
            }
            return "Could not read the extraction source."
        case .emptyDocument:
            return "The document contained no extractable text."
        case .modelUnavailable(let message):
            return message
        case .validationFailed(let attempts, let lastError, _):
            return
                "Extraction failed validation after \(attempts) attempt(s): \(lastError.localizedDescription)"
        case .mergeFailed(let message):
            return "Failed to merge chunked extraction results: \(message)"
        case .internalError(let message):
            return message
        }
    }

    public var rawOutput: String? {
        if case .validationFailed(_, _, let raw) = self {
            return raw
        }
        return nil
    }
}
