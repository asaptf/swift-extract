import Extract
import Foundation
import Security
import SwiftUI

#if canImport(AnyLanguageModel)
    import AnyLanguageModel
#endif

enum ModelBackendKind: String, CaseIterable, Identifiable, Sendable {
    case appleIntelligence
    case openAI
    case anthropic
    case mockDemo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .mockDemo: return "Demo mock (offline)"
        }
    }

    var detail: String {
        switch self {
        case .appleIntelligence: return "On-device Foundation Models (iOS/macOS 26+)"
        case .openAI: return "Cloud API — paste your key"
        case .anthropic: return "Claude Messages API — paste your key"
        case .mockDemo: return "Deterministic offline responses for UI demos"
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

    init() {
        let raw = UserDefaults.standard.string(forKey: "backend") ?? ModelBackendKind.mockDemo.rawValue
        self.backend = ModelBackendKind(rawValue: raw) ?? .mockDemo
        self.openAIKey = KeychainStore.get(account: "openai") ?? ""
        self.anthropicKey = KeychainStore.get(account: "anthropic") ?? ""
    }

    var isConfigured: Bool {
        switch backend {
        case .appleIntelligence:
            return appleIntelligenceAvailable
        case .openAI:
            return !openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .anthropic:
            return !anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .mockDemo:
            return true
        }
    }

    var setupMessage: String {
        switch backend {
        case .appleIntelligence:
            return "Apple Intelligence requires iOS 26 / macOS 26 with Apple Intelligence enabled. Choose another backend in Settings, or use Demo mock."
        case .openAI:
            return "Add your OpenAI API key in Settings to extract with gpt-4o-mini (or another model)."
        case .anthropic:
            return "Add your Anthropic API key in Settings to extract with Claude."
        case .mockDemo:
            return ""
        }
    }

    var appleIntelligenceAvailable: Bool {
        if #available(iOS 26, macOS 26, *) {
            #if canImport(AnyLanguageModel)
                return SystemLanguageModel.default.isAvailable
            #else
                return false
            #endif
        }
        return false
    }

    func makeSession() throws -> ExtractionSession {
        switch backend {
        case .mockDemo:
            return .mock(
                MockLanguageModel { _, user, _ in
                    Self.mockJSON(forPrompt: user)
                }
            )
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
        }
    }

    nonisolated static func mockJSON(forPrompt user: String) -> String {
        if user.localizedCaseInsensitiveContains("Acme")
            || user.localizedCaseInsensitiveContains("Widget Pro")
            || user.localizedCaseInsensitiveContains("INV-2024")
        {
            return """
                {
                  "merchant": "Acme Supplies Co.",
                  "date": "2024-07-31",
                  "total": 1250.00,
                  "currency": "USD",
                  "items": [
                    {"name": "Widget Pro", "price": 500.00, "quantity": 2},
                    {"name": "Support Plan", "price": 250.00, "quantity": 1}
                  ]
                }
                """
        }
        if user.localizedCaseInsensitiveContains("Shop Example")
            || user.localizedCaseInsensitiveContains("88421")
            || user.localizedCaseInsensitiveContains("Wireless Mouse")
        {
            return """
                {
                  "merchant": "Shop Example",
                  "date": "2024-05-02",
                  "total": 89.99,
                  "currency": "USD",
                  "items": [
                    {"name": "Wireless Mouse", "price": 29.99, "quantity": 1},
                    {"name": "USB-C Hub", "price": 59.99, "quantity": 1}
                  ]
                }
                """
        }
        return """
            {
              "merchant": "Cafe Example",
              "date": "2024-06-15",
              "total": 12.50,
              "currency": "USD",
              "items": [
                {"name": "Latte", "price": 4.50, "quantity": 1},
                {"name": "Croissant", "price": 3.00, "quantity": 2}
              ]
            }
            """
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
