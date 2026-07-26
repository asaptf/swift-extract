import Foundation

/// Curated Hugging Face / MLX-community models that are small enough for a demo
/// (especially on iPhone). Users can still type any model id in Settings.
enum MLXModelCatalog {
    struct Preset: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let detail: String
        /// Rough on-disk size after 4-bit download (for UI copy only).
        let approxSize: String
    }

    static let presets: [Preset] = [
        Preset(
            id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            title: "Qwen2.5 0.5B",
            detail: "Fastest · best for phones",
            approxSize: "~0.4 GB"
        ),
        Preset(
            id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            title: "Llama 3.2 1B",
            detail: "Balanced small instruct model",
            approxSize: "~0.7 GB"
        ),
        Preset(
            id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            title: "Qwen2.5 1.5B",
            detail: "Better quality, still phone-friendly",
            approxSize: "~1.0 GB"
        ),
        Preset(
            id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            title: "Qwen2.5 3B",
            detail: "Higher quality · needs more RAM",
            approxSize: "~1.8 GB"
        ),
    ]

    static let defaultModelId = presets[0].id
}
