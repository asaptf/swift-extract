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
                                        Text(
                                            modelStore.appleIntelligenceAvailable
                                                ? "Available on this device"
                                                : "Not available on this device"
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(
                                            modelStore.appleIntelligenceAvailable ? .green : .orange
                                        )
                                    }
                                    if kind == .mlx {
                                        Text("Requires MLX package trait + Apple Silicon")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
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
                    Section("MLX local model") {
                        TextField("Model ID", text: $modelStore.mlxModelId)
                        Text(
                            "Example: mlx-community/Qwen2.5-3B-Instruct-4bit or mlx-community/Llama-3.2-3B-Instruct-4bit. Enable the MLX trait on the swift-extract package dependency."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
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
            .frame(minWidth: 420, minHeight: 480)
        #endif
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
