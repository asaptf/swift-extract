# swift-extract

**Define a Swift struct. Point the library at *anything* — a PDF, a photo of a receipt, a screenshot, plain text — and get back a fully typed, validated instance.**

[![CI](https://github.com/swift-extract/swift-extract/actions/workflows/ci.yml/badge.svg)](https://github.com/swift-extract/swift-extract/actions/workflows/ci.yml)
![Swift 6.1](https://img.shields.io/badge/Swift-6.1-orange.svg)
![Platforms](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014-lightgrey.svg)
![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)

```swift
import Extract

@Extractable
struct Invoice {
    let vendor: String
    @Guide("ISO 8601 format") let dueDate: Date
    let total: Decimal
    let lineItems: [LineItem]
}

let invoice: Invoice = try await Extract.from(pdfURL)
```

> **Demo GIF** — drop a screen recording at [`docs/demo.gif`](docs/demo.gif).  
> *(Author note: record the ReceiptScanner flow on a sample PDF for the launch tweet.)*

---

## Why

Python already has the pattern: [Instructor](https://python.useinstructor.com) for schema-constrained LLM output, plus a pile of glue for PDF text layers, OCR, retries, and multimodal inputs. Shipping that stack to a phone means shipping a backend — and your users’ receipts leave the device.

On-device models change the economics. Apple Foundation Models, MLX, and llama.cpp make private, offline extraction realistic. Cloud models stay one config flip away for quality when you need them.

Swift is ready for this now: macros for compile-time schemas, strict concurrency, Vision + PDFKit as first-party frameworks, and [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) as a single provider abstraction. **swift-extract** is Instructor for Swift — document-first and multimodal.

---

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/swift-extract/swift-extract.git", from: "0.1.0")
]
```

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Extract", package: "swift-extract")
    ]
)
```

Requires **Swift 6.1+**, **iOS 17+** / **macOS 14+**.

---

## Quick start by backend

### Apple Intelligence (on-device)

```swift
import Extract
import AnyLanguageModel

// Default session uses SystemLanguageModel when available (iOS 26 / macOS 26+).
let receipt: Receipt = try await Extract.from(imageURL)
```

If Apple Intelligence is unavailable, configure an explicit model (below).

### OpenAI / Anthropic / Gemini

```swift
import Extract
import AnyLanguageModel

let session = ExtractionSession(
    model: OpenAILanguageModel(apiKey: apiKey, model: "gpt-4o-mini")
)
let invoice: Invoice = try await Extract.from(pdfURL, using: session)

// Or Anthropic:
let claude = ExtractionSession(
    model: AnthropicLanguageModel(apiKey: key, model: "claude-sonnet-4-5-20250929")
)
```

### MLX (local, Apple Silicon)

Enable the `MLX` package trait (see [Package traits](#package-traits)), then:

```swift
let model = MLXLanguageModel(modelId: "mlx-community/Qwen2.5-3B-Instruct-4bit")
// or: "mlx-community/Llama-3.2-3B-Instruct-4bit"
let session = ExtractionSession(model: model)
let value: Receipt = try await Extract.from(source, using: session)
```

### Offline / tests

```swift
let session = ExtractionSession.mock(
    MockLanguageModel(responses: [#"{"merchant":"Cafe","date":"2024-06-15","total":12.5,"currency":"USD","items":[]}"#])
)
let receipt: Receipt = try await Extract.from("Cafe total 12.50", using: session)
```

---

## Package traits

Heavy local backends are **opt-in** so the default product stays lean (text + PDFKit + Vision OCR + cloud/Apple backends).

| Trait    | Enables                         | Underlying dependency (if resolution fails)      |
| -------- | ------------------------------- | ------------------------------------------------ |
| `MLX`    | MLX Swift models                | `ml-explore/mlx-swift-lm`                        |
| `CoreML` | Core ML models                  | `huggingface/swift-transformers`                 |
| `Llama`  | llama.cpp / GGUF                | `mattt/llama.swift`                              |

```swift
.package(
    url: "https://github.com/swift-extract/swift-extract.git",
    from: "0.1.0",
    traits: ["MLX"] // optional
)
```

### SPM trait resolution workaround

Due to a [Swift Package Manager bug](https://github.com/swiftlang/swift-package-manager/issues/9286) (tracked for AnyLanguageModel as [issue #135](https://github.com/huggingface/AnyLanguageModel/issues/135)), enabling traits may fail with:

> exhausted attempts to resolve the dependencies graph

**Workaround:** also declare the trait’s underlying package(s) in *your* `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/swift-extract/swift-extract.git",
        from: "0.1.0",
        traits: ["MLX", "CoreML", "Llama"]
    ),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "2.25.5"),       // MLX
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0"), // CoreML
    .package(url: "https://github.com/mattt/llama.swift", from: "2.0.0"),              // Llama
]
```

Include only the packages for the traits you enable.

---

## API tour

### `@Extractable` + `@Guide`

```swift
@Extractable
struct Receipt {
    let merchant: String
    let date: Date
    let total: Decimal
    @Guide("3-letter ISO currency code") let currency: String
    let items: [Item]

    @Extractable
    struct Item {
        let name: String
        let price: Decimal
        @Guide("null if not printed on the receipt") let quantity: Int?
    }
}
```

The macro synthesizes:

- `Extractable` (`Codable` + `Sendable`)
- `static var extractionSchema: ExtractionSchema` (JSON-Schema-like)
- Lenient `init(from:)` (ISO-8601 + human dates, `Decimal` from number or string, trimmed strings)

### Sources

```swift
public enum ExtractionSource {
    case text(String)
    case pdf(URL)
    case image(CGImage)
    case fileURL(URL)  // UTType sniff → routes above
}
```

Convenience: `Extract.from("raw text")`, `Extract.from(fileURL)`, `Extract.from(.image(data:))`.

### Entry points

```swift
let value: Receipt = try await Extract.from(source, using: session, options: options)
let detailed: ExtractionResult<Receipt> = try await Extract.detailed(from: source, using: session)
```

### Options & errors

```swift
var options = ExtractionOptions()
options.maxRetries = 2                    // Instructor-style repair loop
options.chunkingStrategy = .automatic     // chunk + merge for large docs
options.locale = Locale(identifier: "en_US")
options.temperature = 0

// ExtractionError: unreadableSource, emptyDocument, modelUnavailable, validationFailed
```

---

## Supported property types

| Type | Schema | Notes |
| ---- | ------ | ----- |
| `String` | string | trimmed |
| `Bool` | boolean | also `"yes"` / `"1"` |
| `Int`…`UInt64` | integer | |
| `Float` / `Double` / `Decimal` | number | `Decimal` accepts numeric strings / currency |
| `Date` | string `date-time` | ISO-8601 + common human formats |
| `URL` | string `uri` | |
| `Optional<T>` | same + null | |
| `Array<T>` | array | |
| Nested `@Extractable` | object | |
| `String` + `CaseIterable` enums | string enum | conform to `Extractable` (default schema helper) |

Unsupported types (e.g. `[String: Int]`) produce a **compile-time** diagnostic.

---

## CLI

```bash
swift run extract-cli fixtures/invoice.pdf --schema Examples/schemas/Invoice.swift --mock
```

`--mock` / `EXTRACT_USE_MOCK=1` runs offline with a deterministic model (used in CI). Without `--mock`, the CLI uses `ExtractionSession.default` (Apple Intelligence when available).

---

## Demo app

```bash
cd Examples/ReceiptScanner
swift build
swift run ReceiptScanner   # macOS
```

Bundled fixtures: digital invoice PDF, café receipt image, email screenshot. Default backend is **Demo mock** so the app works with zero configuration; switch to Apple Intelligence / OpenAI / Anthropic in Settings (keys stored in Keychain).

---

## Limitations (v0.1 — honest)

- **Handwriting** OCR quality is not guaranteed.
- **Table structure** is not reconstructed — the model sees linearized text.
- Prompts are **English-first**.
- Constrained / guided generation is best-effort via schema-in-prompt; a full `@Extractable` → `@Generable` bridge is on the roadmap.
- Arbitrary `.swift` schema files are not JIT-compiled by the CLI; use embedded types matching `Examples/schemas/`.

---

## Roadmap

- [ ] Audio input (Speech framework)
- [ ] Streaming partials for `@Extractable`
- [ ] Per-field provenance (bounding boxes)
- [ ] Evaluation harness
- [ ] First-class guided-generation bridge to Foundation Models / AnyLanguageModel `@Generable`

See [`DECISIONS.md`](DECISIONS.md) for architecture notes and the `@Extractable` ↔ `@Generable` correspondence.

---

## Development

```bash
swift build
swift test
swift run extract-cli fixtures/invoice.pdf --schema Examples/schemas/Invoice.swift --mock
```

Format check:

```bash
swift format lint --configuration .swift-format --recursive Sources Tests
```

---

## License

MIT — see [LICENSE](LICENSE).
