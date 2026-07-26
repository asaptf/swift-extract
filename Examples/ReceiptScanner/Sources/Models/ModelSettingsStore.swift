import Extract
import Foundation
import Security
import SwiftUI

#if canImport(AnyLanguageModel)
    import AnyLanguageModel
#endif

enum ModelBackendKind: String, CaseIterable, Identifiable, Sendable {
    case appleIntelligence
    case mlx
    case openAI
    case anthropic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .mlx: return "MLX (local)"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    var detail: String {
        switch self {
        case .appleIntelligence: return "On-device Foundation Models (iOS/macOS 26+)"
        case .mlx: return "Local Apple Silicon model via MLX (requires MLX package trait)"
        case .openAI: return "Cloud API — paste your key"
        case .anthropic: return "Claude Messages API — paste your key"
        }
    }
}

@MainActor
final class ModelSettingsStore: ObservableObject {
    @Published var backend: ModelBackendKind {
        didSet { UserDefaults.standard.set(backend.rawValue, forKey: "backend") }
    }
    @Published var openAIKey: String = "" {
        didSet { KeychainStore.set(openAIKey, account: "openai") }
    }
    @Published var anthropicKey: String = "" {
        didSet { KeychainStore.set(anthropicKey, account: "anthropic") }
    }
    @Published var openAIModel: String = "gpt-4o-mini"
    @Published var anthropicModel: String = "claude-sonnet-4-5-20250929"
    @Published var mlxModelId: String = "mlx-community/Qwen2.5-3B-Instruct-4bit" {
        didSet { UserDefaults.standard.set(mlxModelId, forKey: "mlxModelId") }
    }

    init() {
        self.openAIKey = KeychainStore.get(account: "openai") ?? ""
        self.anthropicKey = KeychainStore.get(account: "anthropic") ?? ""
        if let saved = UserDefaults.standard.string(forKey: "mlxModelId"), !saved.isEmpty {
            self.mlxModelId = saved
        }

        // Prefer a configured backend; never default to a canned-success mock.
        // Resolve Apple Intelligence availability without touching `self` early.
        let appleAvailable = Self.isAppleIntelligenceAvailable()
        if let raw = UserDefaults.standard.string(forKey: "backend"),
            let kind = ModelBackendKind(rawValue: raw)
        {
            self.backend = kind
        } else if appleAvailable {
            self.backend = .appleIntelligence
        } else {
            // Unconfigured cloud backend → setup screen until the user adds a key.
            self.backend = .openAI
        }
    }

    private static func isAppleIntelligenceAvailable() -> Bool {
        if #available(iOS 26, macOS 26, *) {
            #if canImport(AnyLanguageModel)
                return SystemLanguageModel.default.isAvailable
            #else
                return false
            #endif
        }
        return false
    }

    var isConfigured: Bool {
        switch backend {
        case .appleIntelligence:
            return appleIntelligenceAvailable
        case .mlx:
            // Session construction reports concrete availability / trait errors.
            return !mlxModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openAI:
            return !openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .anthropic:
            return !anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var setupMessage: String {
        switch backend {
        case .appleIntelligence:
            return """
                Apple Intelligence requires iOS 26 / macOS 26 with Apple Intelligence enabled. \
                Open Settings to choose OpenAI, Anthropic, or an MLX local model instead.
                """
        case .mlx:
            return """
                MLX local models require the MLX package trait and an Apple Silicon Mac. \
                Set a model ID (e.g. mlx-community/Qwen2.5-3B-Instruct-4bit) in Settings. \
                If the MLX trait is not enabled in Package.swift, enable it and rebuild.
                """
        case .openAI:
            return "Add your OpenAI API key in Settings to extract with a cloud model. Keys stay in the Keychain."
        case .anthropic:
            return "Add your Anthropic API key in Settings to extract with Claude. Keys stay in the Keychain."
        }
    }

    var appleIntelligenceAvailable: Bool {
        Self.isAppleIntelligenceAvailable()
    }

    func makeSession() throws -> ExtractionSession {
        switch backend {
        case .openAI:
            let key = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw ExtractionError.modelUnavailable(setupMessage)
            }
            #if canImport(AnyLanguageModel)
                let model = OpenAILanguageModel(apiKey: key, model: openAIModel)
                return ExtractionSession(model: model)
            #else
                throw ExtractionError.modelUnavailable("AnyLanguageModel is not linked.")
            #endif
        case .anthropic:
            let key = anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw ExtractionError.modelUnavailable(setupMessage)
            }
            #if canImport(AnyLanguageModel)
                let model = AnthropicLanguageModel(apiKey: key, model: anthropicModel)
                return ExtractionSession(model: model)
            #else
                throw ExtractionError.modelUnavailable("AnyLanguageModel is not linked.")
            #endif
        case .appleIntelligence:
            if #available(iOS 26, macOS 26, *) {
                #if canImport(AnyLanguageModel)
                    let model = SystemLanguageModel.default
                    guard model.isAvailable else {
                        throw ExtractionError.modelUnavailable(setupMessage)
                    }
                    return ExtractionSession(model: model)
                #endif
            }
            throw ExtractionError.modelUnavailable(setupMessage)
        case .mlx:
            let modelId = mlxModelId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelId.isEmpty else {
                throw ExtractionError.modelUnavailable(setupMessage)
            }
            // MLXLanguageModel is only available when the MLX package trait is enabled.
            // Attempt dynamic construction via type lookup would be fragile; use compile-time
            // availability through a thin helper that fails clearly without the trait.
            return try MLXSessionFactory.makeSession(modelId: modelId)
        }
    }
}

// MARK: - MLX factory (clear error when trait disabled)

enum MLXSessionFactory {
    static func makeSession(modelId: String) throws -> ExtractionSession {
        #if MLX
            #if canImport(AnyLanguageModel)
                let model = MLXLanguageModel(modelId: modelId)
                return ExtractionSession(model: model)
            #else
                throw ExtractionError.modelUnavailable("AnyLanguageModel is not linked.")
            #endif
        #else
            throw ExtractionError.modelUnavailable(
                """
                MLX backend is not compiled into this build. Enable the MLX package trait \
                on swift-extract (and declare mlx-swift-lm per the README SPM workaround), \
                then rebuild ReceiptScanner.
                """
            )
        #endif
    }
}

// MARK: - Keychain

enum KeychainStore {
    private static let service = "com.swiftextract.ReceiptScanner"

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
