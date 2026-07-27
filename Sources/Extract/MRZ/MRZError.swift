import Foundation

/// Failures that prevent reading an MRZ structure.
///
/// Checksum mismatches are **not** reported here — they are field-level trust
/// signals on ``MRZResult/checks``. Only genuinely unreadable input (wrong line
/// count/length, unsupported layout, or no MRZ found in text) throws.
public enum MRZError: Error, Sendable, LocalizedError {
    /// The supplied lines do not match TD1 (3×30), TD2 (2×36), or TD3 (2×44).
    case unsupportedFormat(lineCount: Int, lineLengths: [Int])
    /// A candidate line contained characters outside the ICAO MRZ alphabet.
    case invalidCharacters(lineIndex: Int, line: String)
    /// No contiguous MRZ block could be located in the provided text.
    case notFound

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let lineCount, let lineLengths):
            let lengths = lineLengths.map(String.init).joined(separator: ", ")
            return
                "Unsupported MRZ layout: \(lineCount) line(s) with length(s) [\(lengths)]. "
                + "Expected TD1 (3×30), TD2 (2×36), or TD3 (2×44)."
        case .invalidCharacters(let lineIndex, let line):
            return "MRZ line \(lineIndex + 1) contains non-MRZ characters: \(line)"
        case .notFound:
            return "No ICAO 9303 MRZ block was found in the provided text."
        }
    }
}
