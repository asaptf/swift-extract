# Backends & package traits

swift-extract does **not** ship HTTP clients. All models come from
[AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel).

## Quick matrix

| Backend | Trait | Network | Typical use |
| --- | --- | --- | --- |
| Apple Intelligence (`SystemLanguageModel`) | — | No | Default on iOS/macOS 26+ |
| OpenAI | — | Yes | Quality / prototyping |
| Anthropic | — | Yes | Long documents |
| Gemini | — | Yes | Multimodal cloud |
| Ollama | — | Local HTTP | Dev machines |
| MLX | `MLX` | Download once | Apple Silicon offline |
| Core ML | `CoreML` | — | On-device Core ML |
| llama.cpp | `Llama` | — | GGUF files |

## Apple Intelligence

```swift
import Extract
import AnyLanguageModel

// Prefer the default session when targeting latest OS:
let value: Receipt = try await Extract.from(source)  // uses .default

// Explicit:
if #available(iOS 26, macOS 26, *) {
    let model = SystemLanguageModel.default
    guard model.isAvailable else { /* show setup UI */ ; return }
    let session = ExtractionSession(model: model)
}
```

Paths are gated with `#available(iOS 26, macOS 26, *)`.

## OpenAI

```swift
let model = OpenAILanguageModel(
    apiKey: key,
    model: "gpt-4o-mini"
    // apiVariant: .chatCompletions // for compatible gateways
)
let session = ExtractionSession(model: model, temperature: 0)
```

**Never hardcode keys.** Prefer Keychain (see ReceiptScanner) or a backend proxy for production apps.

## Anthropic

```swift
let model = AnthropicLanguageModel(
    apiKey: key,
    model: "claude-sonnet-4-5-20250929"
)
let session = ExtractionSession(model: model)
```

## MLX (local, Apple Silicon)

1. Enable the trait on **your** package:

```swift
.package(
    url: "https://github.com/asaptf/swift-extract.git",
    from: "0.1.0",
    traits: ["MLX"]
)
```

2. If SPM fails to resolve the graph, also add:

```swift
.package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "2.25.5")
```

3. Use a small instruct model (see [Choosing a small local model](#choosing-a-small-local-model)):

```swift
let model = MLXLanguageModel(modelId: "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
// or: "mlx-community/Qwen2.5-3B-Instruct-4bit"
let session = ExtractionSession(model: model, temperature: 0)
```

> **Lazy load:** `MLXLanguageModel.isAvailable` may be `false` until the first
> successful generation (weights not loaded yet). swift-extract does **not**
> pre-check availability on generate, so the first call can load the model.

## Choosing a small local model

swift-extract is **LLM + schema**, not a dedicated document-AI stack. For
receipts and invoices you still want a general instruct model that can emit
JSON. Small Hugging Face weights (especially
[MLX Community](https://huggingface.co/mlx-community) 4-bit builds) work well
on-device when the document text is already good (Vision OCR / PDF text layer).

### Recommended MLX presets

Rough download size after 4-bit quantization. Use any other
`mlx-community/…` id if you prefer.

| Model id | ~Size | Best for |
| --- | --- | --- |
| [`mlx-community/Qwen2.5-0.5B-Instruct-4bit`](https://huggingface.co/mlx-community/Qwen2.5-0.5B-Instruct-4bit) | ~0.4 GB | Fastest phones; merchant / date / total |
| [`mlx-community/Llama-3.2-1B-Instruct-4bit`](https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit) | ~0.7 GB | Balanced small instruct |
| [`mlx-community/Qwen2.5-1.5B-Instruct-4bit`](https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit) | ~1.0 GB | Better JSON; still phone-friendly |
| [`mlx-community/Qwen2.5-3B-Instruct-4bit`](https://huggingface.co/mlx-community/Qwen2.5-3B-Instruct-4bit) | ~1.8 GB | Line items, messier layouts; needs more RAM |

The ReceiptScanner demo ships the same list in Settings (see
[`MLXModelCatalog`](../Examples/ReceiptScanner/Sources/Models/MLXModelCatalog.swift)).

### Practical guidance

| Document complexity | Prefer |
| --- | --- |
| Simple receipt (merchant, date, total, currency) | 0.5B–1.5B MLX, or Apple Intelligence |
| Invoice with nested line items / taxes | 3B+ local, or cloud (`gpt-4o-mini`, Claude, …) |
| Multi-page PDF, poor scan quality | Stronger model **and** good OCR; bad text cannot be fixed by a bigger LLM alone |
| PII must stay on device | MLX / Apple Intelligence / Core ML / llama.cpp — not cloud |

Tips that matter more than chasing another model id:

- Keep **`temperature: 0`** for extraction.
- Lean on **`@Guide`** for formats (ISO dates, ISO currency, “null if missing”).
- Let Vision / PDFKit do reading; the model maps **text → typed fields**.
- Retries and lenient decode already recover many partial JSON failures.

### What this path is *not*

| Approach | In scope? |
| --- | --- |
| Small instruct LLMs from Hugging Face (MLX, GGUF, Ollama) | **Yes** — via AnyLanguageModel |
| Specialized document models (Donut, LayoutLMv3, invoice NER heads) | **No** — different I/O; would need a separate adapter |
| End-to-end vision-language “read the image” without OCR | Not the default path; OCR-first is intentional |

Further reading:

- [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) — unified Swift backends
- [MLX Community on Hugging Face](https://huggingface.co/mlx-community) — Apple Silicon weights
- [Qwen2.5 collection](https://huggingface.co/collections/Qwen/qwen25) — base model family used by several presets

## Core ML / Llama

```swift
// traits: ["CoreML"]
let coreML = CoreMLLanguageModel(url: modelURL)

// traits: ["Llama"]
let llama = LlamaLanguageModel(modelPath: "/path/to/model.gguf")
```

Same SPM workaround pattern as MLX when resolution fails.

## Ollama

```swift
let model = OllamaLanguageModel(model: "qwen3") // ollama pull qwen3
let session = ExtractionSession(model: model)
```

## How generation works

1. System + user prompts include the JSON Schema and field guides.
2. `LanguageModelSession.respond(to:options:)` requests a **String**.
3. Output is fence-stripped and decoded with lenient `Codable`.

We intentionally avoid AnyLanguageModel’s `respond(to:schema:)` overload today:
it does not reliably pass *our* schema through to providers (see `DECISIONS.md`).

## Temperature

```swift
// Session default
let session = ExtractionSession(model: model, temperature: 0)

// Per-call override
var options = ExtractionOptions()
options.temperature = 0.2
try await Extract.from(source, using: session, options: options)

// nil options.temperature → session.temperature
```

## Security checklist

- [ ] No API keys in source or Info.plist
- [ ] Keychain or server-side proxy for production
- [ ] Prefer on-device for PII-heavy documents (receipts, IDs)
- [ ] Log raw model output carefully — it may contain document text
