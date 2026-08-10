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
    /// Soft character budget before automatic chunking (default matches library 12_000).
    public var softContextCharacterBudget: Int
    /// Chunking strategy (default `.automatic`).
    public var chunkingStrategy: ChunkingStrategy
    /// When `true` (default), `EvalInvoice.validateInvariants()` enforces
    /// sum(lineTotals) + tax ≈ grandTotal. Set `false` so low-capacity models
    /// still yield scored fields instead of `validationFailed` with empty scores.
    /// Per-arm in compare runs; observable in ``reportLabel``.
    public var arithmeticInvariant: Bool

    public init(
        name: String,
        backend: BackendKind = .mock,
        modelId: String? = nil,
        tableDetection: TableDetectionMode = .automatic,
        temperature: Double = 0,
        maxRetries: Int = 1,
        softContextCharacterBudget: Int = 12_000,
        chunkingStrategy: ChunkingStrategy = .automatic,
        arithmeticInvariant: Bool = true
    ) {
        self.name = name
        self.backend = backend
        self.modelId = modelId
        self.tableDetection = tableDetection
        self.temperature = temperature
        self.maxRetries = maxRetries
        self.softContextCharacterBudget = softContextCharacterBudget
        self.chunkingStrategy = chunkingStrategy
        self.arithmeticInvariant = arithmeticInvariant
    }

    public var extractionOptions: ExtractionOptions {
        ExtractionOptions(
            maxRetries: maxRetries,
            chunkingStrategy: chunkingStrategy,
            softContextCharacterBudget: softContextCharacterBudget,
            temperature: temperature,
            tableDetection: tableDetection
        )
    }

    /// Human-readable config summary for reports (includes invariant mode).
    public var reportLabel: String {
        var parts = [
            "name=\(name)",
            "backend=\(backend.rawValue)",
            "tableDetection=\(TableDetectionParsing.label(tableDetection))",
            "model=\(modelId ?? "-")",
            "invariant=\(arithmeticInvariant)",
        ]
        if !arithmeticInvariant {
            parts.append("note=arithmetic-invariant-off")
        }
        return parts.joined(separator: " ")
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
    case invalidInteger(String, String)
    case invalidBoolean(String, String)

    public var description: String {
        switch self {
        case .invalidTableDetection(let s):
            return "Invalid table detection mode '\(s)' (use automatic|off)"
        case .missingValue(let o):
            return "Missing value for \(o)"
        case .unknownOption(let o):
            return "Unknown option \(o)"
        case .invalidMode(let m):
            return "Invalid mode '\(m)' (use survey|accuracy|compare|anchors|chunk-merge)"
        case .invalidInteger(let o, let v):
            return "Invalid integer for \(o): '\(v)'"
        case .invalidBoolean(let o, let v):
            return "Invalid boolean for \(o): '\(v)' (use true|false)"
        }
    }
}
