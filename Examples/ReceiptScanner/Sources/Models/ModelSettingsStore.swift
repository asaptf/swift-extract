import Extract
import Foundation
import Security
import SwiftUI

#if canImport(AnyLanguageModel)
    import AnyLanguageModel
#endif
#if canImport(FoundationModels)
    import FoundationModels
#endif
#if canImport(MLXLMCommon)
    import MLXLMCommon
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
        case .mlx: return "Local Apple Silicon model via MLX — download from Settings"
        case .openAI: return "Cloud API — paste your key"
        case .anthropic: return "Claude Messages API — paste your key"
        }
    }
}

/// Why on-device Foundation Models are or aren't usable right now.
/// Mirrors `SystemLanguageModel.Availability` with human-readable copy for the demo UI.
enum AppleIntelligenceStatus: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case osTooOld
    case frameworkMissing
    case unknown(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// Short status line under the backend picker.
    var shortLabel: String {
        switch self {
        case .available:
            return "Available on this device"
        case .deviceNotEligible:
            return "Device not eligible for Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off"
        case .modelNotReady:
            return "Model still downloading / not ready"
        case .osTooOld:
            return "Requires iOS 26 / macOS 26+"
        case .frameworkMissing:
            return "FoundationModels framework not linked"
        case .unknown(let detail):
            return detail
        }
    }

    /// Longer guidance for the setup screen / errors.
    var guidance: String {
        switch self {
        case .available:
            return "On-device Foundation Models are ready."
        case .deviceNotEligible:
            return """
                This hardware is not eligible for Apple Intelligence / Foundation Models. \
                Choose OpenAI, Anthropic, or MLX in Settings instead.
                """
        case .appleIntelligenceNotEnabled:
            return """
                Apple Intelligence is not enabled on this device. \
                Open Settings → Apple Intelligence & Siri, turn Apple Intelligence on, \
                and wait for the model to finish downloading. \
                Also ensure Siri is enabled (system language must be supported).
                """
        case .modelNotReady:
            return """
                Apple Intelligence is enabled, but the on-device model is not ready yet \
                (still downloading or warming up). Keep the device on Wi‑Fi and power, \
                wait a few minutes, then reopen the app.
                """
        case .osTooOld:
            return """
                Apple Intelligence / Foundation Models require iOS 26 or macOS 26. \
                Choose OpenAI, Anthropic, or MLX in Settings instead.
                """
        case .frameworkMissing:
            return "FoundationModels is not available in this build."
        case .unknown(let detail):
            return detail
        }
    }

    static func resolve() -> AppleIntelligenceStatus {
        if #available(iOS 26, macOS 26, *) {
            #if canImport(FoundationModels)
                // Prefer Apple's API directly so we get the real UnavailableReason
                // (AnyLanguageModel wraps the same model but the demo UI needs precise copy).
                switch FoundationModels.SystemLanguageModel.default.availability {
                case .available:
                    return .available
                case .unavailable(.deviceNotEligible):
                    return .deviceNotEligible
                case .unavailable(.appleIntelligenceNotEnabled):
                    return .appleIntelligenceNotEnabled
                case .unavailable(.modelNotReady):
                    return .modelNotReady
                case .unavailable(let reason):
                    return .unknown("Unavailable (\(String(describing: reason)))")
                }
            #elseif canImport(AnyLanguageModel)
                return AnyLanguageModel.SystemLanguageModel.default.isAvailable
                    ? .available
                    : .unknown("SystemLanguageModel reports unavailable")
            #else
                return .frameworkMissing
            #endif
        }
        return .osTooOld
    }
}

// MARK: - MLX download state

enum MLXDownloadPhase: Equatable, Sendable {
    case idle
    case downloading(fraction: Double)
    case ready
    case failed(String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
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
    @Published var mlxModelId: String = MLXModelCatalog.defaultModelId {
        didSet {
            UserDefaults.standard.set(mlxModelId, forKey: "mlxModelId")
            refreshMLXLocalStatus()
        }
    }
    @Published private(set) var mlxDownloadPhase: MLXDownloadPhase = .idle
    @Published private(set) var mlxIsOnDisk: Bool = false

    private var downloadTask: Task<Void, Never>?

    init() {
        self.openAIKey = KeychainStore.get(account: "openai") ?? ""
        self.anthropicKey = KeychainStore.get(account: "anthropic") ?? ""
        if let saved = UserDefaults.standard.string(forKey: "mlxModelId"), !saved.isEmpty {
            self.mlxModelId = saved
        }

        // Prefer a configured backend; never default to a canned-success mock.
        // Resolve Apple Intelligence availability without touching `self` early.
        let appleStatus = AppleIntelligenceStatus.resolve()
        if let raw = UserDefaults.standard.string(forKey: "backend"),
            let kind = ModelBackendKind(rawValue: raw)
        {
            self.backend = kind
        } else if appleStatus.isAvailable {
            self.backend = .appleIntelligence
        } else {
            // Unconfigured cloud backend → setup screen until the user adds a key.
            self.backend = .openAI
        }

        refreshMLXLocalStatus()
    }

    var isConfigured: Bool {
        switch backend {
        case .appleIntelligence:
            return appleIntelligenceAvailable
        case .mlx:
            // Configured once a model id is set; download is optional pre-step
            // (first extraction also downloads). Prefer on-disk for a smooth first run.
            return !mlxModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && mlxBackendCompiledIn
        case .openAI:
            return !openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .anthropic:
            return !anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var setupMessage: String {
        switch backend {
        case .appleIntelligence:
            return appleIntelligenceStatus.guidance
        case .mlx:
            if !mlxBackendCompiledIn {
                return """
                    MLX is not linked in this build. Rebuild ReceiptScanner with the MLX package \
                    trait enabled (see Examples/ReceiptScanner/project.yml).
                    """
            }
            if mlxModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Pick an MLX model id in Settings, then tap Download."
            }
            if !mlxIsOnDisk {
                return """
                    MLX model “\(mlxModelId)” is not downloaded yet. \
                    Open Settings → MLX, tap Download Model, then try again. \
                    First generation will also download automatically if you skip that step.
                    """
            }
            return "MLX model is ready."
        case .openAI:
            return "Add your OpenAI API key in Settings to extract with a cloud model. Keys stay in the Keychain."
        case .anthropic:
            return "Add your Anthropic API key in Settings to extract with Claude. Keys stay in the Keychain."
        }
    }

    var appleIntelligenceStatus: AppleIntelligenceStatus {
        AppleIntelligenceStatus.resolve()
    }

    var appleIntelligenceAvailable: Bool {
        appleIntelligenceStatus.isAvailable
    }

    /// Whether the MLX stack (AnyLanguageModel + MLXLMCommon) is compiled into this app.
    var mlxBackendCompiledIn: Bool {
        #if canImport(MLXLMCommon) && canImport(AnyLanguageModel)
            return true
        #else
            return false
        #endif
    }

    func selectMLXPreset(_ preset: MLXModelCatalog.Preset) {
        mlxModelId = preset.id
    }

    func refreshMLXLocalStatus() {
        let id = mlxModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            mlxIsOnDisk = false
            if !mlxDownloadPhase.isDownloading {
                mlxDownloadPhase = .idle
            }
            return
        }
        let onDisk = MLXModelDownloader.isDownloaded(modelId: id)
        mlxIsOnDisk = onDisk
        if !mlxDownloadPhase.isDownloading {
            mlxDownloadPhase = onDisk ? .ready : .idle
        }
    }

    func downloadMLXModel() {
        let id = mlxModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            mlxDownloadPhase = .failed("Enter a Hugging Face model id first.")
            return
        }
        guard mlxBackendCompiledIn else {
            mlxDownloadPhase = .failed(
                "MLX is not linked. Rebuild with the MLX trait enabled."
            )
            return
        }
        guard !mlxDownloadPhase.isDownloading else { return }

        downloadTask?.cancel()
        mlxDownloadPhase = .downloading(fraction: 0)

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await MLXModelDownloader.download(modelId: id) { [weak self] fraction in
                    Task { @MainActor in
                        self?.mlxDownloadPhase = .downloading(fraction: fraction)
                    }
                }
                guard !Task.isCancelled else { return }
                self.mlxIsOnDisk = true
                self.mlxDownloadPhase = .ready
            } catch is CancellationError {
                self.refreshMLXLocalStatus()
            } catch {
                self.mlxDownloadPhase = .failed(error.localizedDescription)
                self.refreshMLXLocalStatus()
            }
        }
    }

    func cancelMLXDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        refreshMLXLocalStatus()
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
                    // AnyLanguageModel's wrapper (not FoundationModels.SystemLanguageModel).
                    let model = AnyLanguageModel.SystemLanguageModel.default
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
            return try MLXSessionFactory.makeSession(modelId: modelId)
        }
    }
}

// MARK: - MLX download helper

enum MLXModelDownloader {
    /// Returns true when the Hub cache already has weight files for this model id.
    static func isDownloaded(modelId: String) -> Bool {
        #if canImport(MLXLMCommon)
            let configuration = ModelConfiguration(id: modelId)
            let directory = configuration.modelDirectory(hub: defaultHubApi)
            return directoryContainsWeights(directory)
        #else
            return false
        #endif
    }

    /// Downloads model weights/config from Hugging Face with progress callbacks.
    static func download(
        modelId: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        #if canImport(MLXLMCommon)
            let configuration = ModelConfiguration(id: modelId)
            _ = try await downloadModel(
                hub: defaultHubApi,
                configuration: configuration
            ) { p in
                // Progress can report values outside 0...1 during some Hub phases.
                let fraction = min(max(p.fractionCompleted, 0), 1)
                progress(fraction)
            }
        #else
            throw ExtractionError.modelUnavailable(
                "MLXLMCommon is not linked — rebuild with the MLX trait / mlx-swift-lm dependency."
            )
        #endif
    }

    #if canImport(MLXLMCommon)
        private static func directoryContainsWeights(_ directory: URL) -> Bool {
            let fm = FileManager.default
            guard fm.fileExists(atPath: directory.path) else { return false }
            guard let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { return false }
            for case let url as URL in enumerator {
                if url.pathExtension == "safetensors" {
                    return true
                }
            }
            return false
        }
    #endif
}

// MARK: - MLX factory (clear error when trait disabled)

enum MLXSessionFactory {
    static func makeSession(modelId: String) throws -> ExtractionSession {
        #if canImport(AnyLanguageModel) && canImport(MLXLMCommon)
            let model = MLXLanguageModel(modelId: modelId)
            return ExtractionSession(model: model)
        #elseif canImport(AnyLanguageModel) && MLX
            let model = MLXLanguageModel(modelId: modelId)
            return ExtractionSession(model: model)
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
