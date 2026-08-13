import Extract
import Foundation

/// Values of the harness `invariant=` key (one switch, three modes).
///
/// `true` / `false` keep their historical meaning so existing reports stay
/// comparable. `report` turns the arithmetic check on and asks the library for
/// the last decoded value plus remaining issues instead of `validationFailed`.
public enum ArithmeticInvariantMode: Sendable, Equatable {
    /// Arithmetic check disabled (`EvalInvoice.validateInvariants` is a no-op).
    case off
    /// Arithmetic check on; library ``InvariantPolicy/strict`` (default).
    case on
    /// Arithmetic check on; library ``InvariantPolicy/reportViolations``.
    case report

    /// Whether `EvalInvoice` should actually run the sum-equals-total check.
    public var isEnabled: Bool { self != .off }

    /// Library policy installed on ``RunConfig/extractionOptions``.
    public var invariantPolicy: InvariantPolicy {
        switch self {
        case .off, .on: return .strict
        case .report: return .reportViolations
        }
    }

    /// Token printed in report labels (`true` / `false` / `report`).
    public var reportToken: String {
        switch self {
        case .off: return "false"
        case .on: return "true"
        case .report: return "report"
        }
    }

    public static func parse(_ raw: String) throws -> ArithmeticInvariantMode {
        switch raw.lowercased() {
        case "true", "1", "yes", "on", "strict":
            return .on
        case "false", "0", "no", "off":
            return .off
        case "report", "reportviolations", "report-violations":
            return .report
        default:
            throw CLIParseError.invalidInvariantMode(raw)
        }
    }
}

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
    /// Arithmetic invariant mode (`invariant=`). Default ``ArithmeticInvariantMode/on``.
    ///
    /// When ``ArithmeticInvariantMode/on``, `EvalInvoice.validateInvariants()`
    /// enforces sum(lineTotals) + tax ≈ grandTotal and a violation can end the
    /// file in `validationFailed`. ``ArithmeticInvariantMode/off`` skips the
    /// check so low-capacity models still yield scored fields.
    /// ``ArithmeticInvariantMode/report`` keeps the check on and asks the
    /// library for the last decoded value plus remaining issues.
    /// Per-arm in compare runs; observable in ``reportLabel``.
    public var arithmeticInvariant: ArithmeticInvariantMode

    public init(
        name: String,
        backend: BackendKind = .mock,
        modelId: String? = nil,
        tableDetection: TableDetectionMode = .automatic,
        temperature: Double = 0,
        maxRetries: Int = 1,
        softContextCharacterBudget: Int = 12_000,
        chunkingStrategy: ChunkingStrategy = .automatic,
        arithmeticInvariant: ArithmeticInvariantMode = .on
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
            tableDetection: tableDetection,
            invariantPolicy: arithmeticInvariant.invariantPolicy
        )
    }

    /// Human-readable config summary for reports (includes invariant mode).
    public var reportLabel: String {
        var parts = [
            "name=\(name)",
            "backend=\(backend.rawValue)",
            "tableDetection=\(TableDetectionParsing.label(tableDetection))",
            "model=\(modelId ?? "-")",
            "invariant=\(arithmeticInvariant.reportToken)",
        ]
        if arithmeticInvariant == .off {
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
    case invalidInvariantMode(String)

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
        case .invalidInvariantMode(let v):
            return "Invalid invariant mode '\(v)' (use true|false|report)"
        }
    }
}
