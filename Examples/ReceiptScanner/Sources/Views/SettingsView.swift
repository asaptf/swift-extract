import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var modelStore: ModelSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Model backend") {
                    ForEach(ModelBackendKind.allCases) { kind in
                        Button {
                            modelStore.backend = kind
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(
                                    systemName: modelStore.backend == kind
                                        ? "checkmark.circle.fill" : "circle"
                                )
                                .foregroundStyle(modelStore.backend == kind ? .orange : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.title)
                                        .foregroundStyle(.primary)
                                    Text(kind.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if kind == .appleIntelligence {
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
                                    }
                                    if kind == .mlx {
                                        Text(
                                            modelStore.mlxBackendCompiledIn
                                                ? (modelStore.mlxIsOnDisk
                                                    ? "Model on disk — ready"
                                                    : "Download a model below to use offline")
                                                : "MLX not linked in this build"
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(
                                            modelStore.mlxIsOnDisk
                                                ? .green
                                                : (modelStore.mlxBackendCompiledIn ? .orange : .red)
                                        )
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if modelStore.backend == .openAI {
                    Section("OpenAI") {
                        SecureField("API key", text: $modelStore.openAIKey)
                        TextField("Model", text: $modelStore.openAIModel)
                        Text("Keys are stored in the Keychain and never leave this device except to the provider you chose.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if modelStore.backend == .anthropic {
                    Section("Anthropic") {
                        SecureField("API key", text: $modelStore.anthropicKey)
                        TextField("Model", text: $modelStore.anthropicModel)
                        Text("Keys are stored in the Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if modelStore.backend == .mlx {
                    MLXSettingsSection()
                }

                Section("About") {
                    Text(
                        "ReceiptScanner is a demo for the swift-extract library. Extraction always goes through the public Extract API with a real configured model — never a hardcoded success path."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
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
}

// MARK: - MLX settings

private struct MLXSettingsSection: View {
    @EnvironmentObject private var modelStore: ModelSettingsStore

    var body: some View {
        Section("MLX presets") {
            ForEach(MLXModelCatalog.presets) { preset in
                Button {
                    modelStore.selectMLXPreset(preset)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(
                            systemName: modelStore.mlxModelId == preset.id
                                ? "checkmark.circle.fill" : "circle"
                        )
                        .foregroundStyle(
                            modelStore.mlxModelId == preset.id ? .orange : .secondary
                        )
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

        Section("MLX model") {
            TextField("Hugging Face model id", text: $modelStore.mlxModelId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textContentType(.none)
                    .keyboardType(.asciiCapable)
                #endif

            downloadControls

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
    private var downloadControls: some View {
        switch modelStore.mlxDownloadPhase {
        case .idle:
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

        case .downloading(let fraction):
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

        case .ready:
            VStack(alignment: .leading, spacing: 8) {
                Label("Model ready on device", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button {
                    modelStore.downloadMLXModel()
                } label: {
                    Label("Re-download", systemImage: "arrow.clockwise")
                }
            }

        case .failed(let message):
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
