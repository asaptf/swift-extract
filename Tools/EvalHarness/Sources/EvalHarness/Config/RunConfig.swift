import Extract
import Foundation

/// Named extraction configuration for A/B runs.
///
/// Only these fields may differ between arms — nothing else varies silently.
public struct RunConfig: Sendable, Equatable {
    public var name: String
    public var backend: BackendKind
    public var modelId: String?
    public var tableDetection: TableDetectionMode
    public var temperature: Double
    public var maxRetries: Int

    public init(
        name: String,
        backend: BackendKind = .mock,
        modelId: String? = nil,
        tableDetection: TableDetectionMode = .automatic,
        temperature: Double = 0,
        maxRetries: Int = 1
    ) {
        self.name = name
        self.backend = backend
        self.modelId = modelId
        self.tableDetection = tableDetection
        self.temperature = temperature
        self.maxRetries = maxRetries
    }

    public var extractionOptions: ExtractionOptions {
        ExtractionOptions(
            maxRetries: maxRetries,
            temperature: temperature,
            tableDetection: tableDetection
        )
    }

    public func makeSession() throws -> ExtractionSession {
        try BackendFactory.makeSession(
            backend: backend,
            modelId: modelId,
            temperature: temperature
        )
    }
}

public enum TableDetectionParsing {
    public static func parse(_ raw: String) throws -> TableDetectionMode {
        switch raw.lowercased() {
        case "automatic", "auto", "on":
            return .automatic
        case "off", "none", "false":
            return .off
        default:
            throw CLIParseError.invalidTableDetection(raw)
        }
    }

    public static func label(_ mode: TableDetectionMode) -> String {
        switch mode {
        case .automatic: return "automatic"
        case .off: return "off"
        }
    }
}

public enum CLIParseError: Error, CustomStringConvertible {
    case invalidTableDetection(String)
    case missingValue(String)
    case unknownOption(String)
    case invalidMode(String)

    public var description: String {
        switch self {
        case .invalidTableDetection(let s):
            return "Invalid table detection mode '\(s)' (use automatic|off)"
        case .missingValue(let o):
            return "Missing value for \(o)"
        case .unknownOption(let o):
            return "Unknown option \(o)"
        case .invalidMode(let m):
            return "Invalid mode '\(m)' (use survey|accuracy|compare|anchors)"
        }
    }
}
