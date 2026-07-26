import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var modelStore: ModelSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            formContent
                .formStyle(.grouped)
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    @ViewBuilder
    private var formContent: some View {
        Form {
            backendSection
            if modelStore.backend == .openAI {
                openAISection
            }
            if modelStore.backend == .anthropic {
                anthropicSection
            }
            if modelStore.backend == .mlx {
                MLXSettingsSection()
            }
            aboutSection
        }
    }

    private var backendSection: some View {
        Section("Model backend") {
            ForEach(ModelBackendKind.allCases) { kind in
                BackendRow(kind: kind)
            }
        }
    }

    private var openAISection: some View {
        Section("OpenAI") {
            SecureField("API key", text: $modelStore.openAIKey)
            TextField("Model", text: $modelStore.openAIModel)
            Text(
                "Keys are stored in the Keychain and never leave this device except to the provider you chose."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var anthropicSection: some View {
        Section("Anthropic") {
            SecureField("API key", text: $modelStore.anthropicKey)
            TextField("Model", text: $modelStore.anthropicModel)
            Text("Keys are stored in the Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            Text(
                "ReceiptScanner is a demo for the swift-extract library. Extraction always goes through the public Extract API with a real configured model — never a hardcoded success path."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Backend row

private struct BackendRow: View {
    @EnvironmentObject private var modelStore: ModelSettingsStore
    let kind: ModelBackendKind

    var body: some View {
        Button {
            modelStore.backend = kind
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .foregroundStyle(.primary)
                    Text(kind.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    extraStatus
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private var selected: Bool {
        modelStore.backend == kind
    }

    @ViewBuilder
    private var extraStatus: some View {
        switch kind {
        case .appleIntelligence:
            let status = modelStore.appleIntelligenceStatus
            Text(status.shortLabel)
                .font(.caption2)
                .foregroundStyle(status.isAvailable ? .green : .orange)
            if !status.isAvailable {
                Text(status.guidance)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .mlx:
            Text(mlxStatusLabel)
                .font(.caption2)
                .foregroundStyle(mlxStatusColor)
        case .openAI, .anthropic:
            EmptyView()
        }
    }

    private var mlxStatusLabel: String {
        if !modelStore.mlxBackendCompiledIn {
            return "MLX not linked in this build"
        }
        if modelStore.mlxIsOnDisk {
            return "Model on disk — ready"
        }
        return "Download a model below to use offline"
    }

    private var mlxStatusColor: Color {
        if modelStore.mlxIsOnDisk { return .green }
        if modelStore.mlxBackendCompiledIn { return .orange }
        return .red
    }
}

// MARK: - MLX settings

private struct MLXSettingsSection: View {
    @EnvironmentObject private var modelStore: ModelSettingsStore

    var body: some View {
        Group {
            presetsSection
            modelSection
        }
    }

    private var presetsSection: some View {
        Section("MLX presets") {
            ForEach(MLXModelCatalog.presets) { preset in
                PresetRow(preset: preset)
            }
        }
    }

    private var modelSection: some View {
        Section("MLX model") {
            modelIdField
            MLXDownloadControls()
            Text(
                """
                Models are downloaded from Hugging Face into the app cache and run fully on-device via MLX. \
                Prefer the smaller presets on iPhone. First load after download can take a moment while weights map into memory.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var modelIdField: some View {
        let field = TextField("Hugging Face model id", text: $modelStore.mlxModelId)
            .autocorrectionDisabled()
        #if os(iOS)
            field
                .textInputAutocapitalization(.never)
                .textContentType(.none)
                .keyboardType(.asciiCapable)
        #else
            field
        #endif
    }
}

private struct PresetRow: View {
    @EnvironmentObject private var modelStore: ModelSettingsStore
    let preset: MLXModelCatalog.Preset

    private var selected: Bool {
        modelStore.mlxModelId == preset.id
    }

    var body: some View {
        Button {
            modelStore.selectMLXPreset(preset)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .foregroundStyle(.primary)
                    Text(preset.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(preset.id) · \(preset.approxSize)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}

private struct MLXDownloadControls: View {
    @EnvironmentObject private var modelStore: ModelSettingsStore

    var body: some View {
        switch modelStore.mlxDownloadPhase {
        case .idle:
            idleControls
        case .downloading(let fraction):
            downloadingControls(fraction: fraction)
        case .ready:
            readyControls
        case .failed(let message):
            failedControls(message: message)
        }
    }

    @ViewBuilder
    private var idleControls: some View {
        Button {
            modelStore.downloadMLXModel()
        } label: {
            Label(
                modelStore.mlxIsOnDisk ? "Re-download Model" : "Download Model",
                systemImage: "arrow.down.circle"
            )
        }
        .disabled(!modelStore.mlxBackendCompiledIn || modelStore.mlxModelId.isEmpty)

        if modelStore.mlxIsOnDisk {
            Label("Weights found in cache", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private func downloadingControls(fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: fraction)
            HStack {
                Text("Downloading… \(Int(fraction * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    modelStore.cancelMLXDownload()
                }
                .font(.caption)
            }
        }
    }

    private var readyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Model ready on device", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Button {
                modelStore.downloadMLXModel()
            } label: {
                Label("Re-download", systemImage: "arrow.clockwise")
            }
        }
    }

    private func failedControls(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Button {
                modelStore.downloadMLXModel()
            } label: {
                Label("Retry download", systemImage: "arrow.down.circle")
            }
        }
    }
}

struct SetupView: View {
    var message: String
    var onSettings: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Model setup needed")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button("Open Settings", action: onSettings)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                Button("Back", action: onDismiss)
                    .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
