import Extract
import Foundation

#if canImport(AnyLanguageModel)
    import AnyLanguageModel
#endif

public enum BackendKind: String, Sendable, CaseIterable {
    case mock
    case mlx
}

public enum BackendError: Error, CustomStringConvertible {
    case mlxNotCompiled
    case mlxInitFailed(String)
    case unknownBackend(String)

    public var description: String {
        switch self {
        case .mlxNotCompiled:
            return """
                MLX backend requested but this binary was not built with the MLX trait. \
                Rebuild with: swift build --traits MLX  (or xcodebuild — see Tools/EvalHarness/README.md). \
                Refusing to fall back to mock (mock accuracy numbers look precise and mean nothing).
                """
        case .mlxInitFailed(let m):
            return "MLX backend failed to initialise: \(m). Refusing to fall back to mock."
        case .unknownBackend(let n):
            return "Unknown backend '\(n)'. Supported: mock, mlx."
        }
    }
}

public enum BackendFactory {
    /// Build an ``ExtractionSession``. Never silently falls back between backends.
    public static func makeSession(
        backend: BackendKind,
        modelId: String?,
        temperature: Double = 0
    ) throws -> ExtractionSession {
        switch backend {
        case .mock:
            return .mock(MockLanguageModel(responder: mockResponder), temperature: temperature)
        case .mlx:
            return try makeMLXSession(modelId: modelId, temperature: temperature)
        }
    }

    public static func parseBackend(_ raw: String) throws -> BackendKind {
        guard let b = BackendKind(rawValue: raw.lowercased()) else {
            throw BackendError.unknownBackend(raw)
        }
        return b
    }

    // MARK: - Mock

    /// Deterministic offline responder. Fixture-aware for hermetic CI; generic empty object otherwise.
    private static let mockResponder: MockLanguageModel.Responder = { _, user, _ in
        let lower = user.lowercased()
        if lower.contains("acme supplies") || lower.contains("widget pro") {
            return """
                {
                  "invoiceNumber": "INV-2024-0042",
                  "issueDate": "2024-07-01",
                  "currency": "USD",
                  "sellerName": "Acme Supplies Co.",
                  "grandTotal": 1250.00,
                  "taxTotal": 0.00,
                  "lineItems": [
                    {"description": "Widget Pro", "quantity": 2, "lineTotal": 1000.00},
                    {"description": "Support Plan", "quantity": 1, "lineTotal": 250.00}
                  ]
                }
                """
        }
        if lower.contains("latte") || lower.contains("croissant") {
            return """
                {
                  "invoiceNumber": null,
                  "issueDate": "2024-06-15",
                  "currency": "USD",
                  "sellerName": "Cafe Example",
                  "grandTotal": 12.50,
                  "taxTotal": null,
                  "lineItems": [
                    {"description": "Latte", "quantity": 1, "lineTotal": 4.50},
                    {"description": "Croissant", "quantity": 2, "lineTotal": 6.00}
                  ]
                }
                """
        }
        // Unknown document — valid empty-ish object so decode succeeds; accuracy scores misses.
        return """
            {
              "invoiceNumber": null,
              "issueDate": null,
              "currency": null,
              "sellerName": null,
              "grandTotal": null,
              "taxTotal": null,
              "lineItems": []
            }
            """
    }

    // MARK: - MLX

    private static func makeMLXSession(modelId: String?, temperature: Double) throws -> ExtractionSession {
        #if MLX
            let id = modelId ?? "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
            do {
                let model = MLXLanguageModel(modelId: id)
                return ExtractionSession(model: model, temperature: temperature)
            } catch {
                // MLXLanguageModel init is non-throwing today; keep a catch for API drift.
                throw BackendError.mlxInitFailed(String(describing: error))
            }
        #else
            _ = modelId
            _ = temperature
            throw BackendError.mlxNotCompiled
        #endif
    }
}
