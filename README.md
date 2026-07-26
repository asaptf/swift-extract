# swift-extract

**Define a Swift type. Point the library at anything — a PDF, a receipt photo, a screenshot, or plain text — and get back a fully typed, validated instance.**

Powered by any LLM: Apple Intelligence on-device, MLX / Core ML / llama.cpp locally, or OpenAI / Anthropic / Gemini in the cloud — via [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel).

[![CI](https://github.com/asaptf/swift-extract/actions/workflows/ci.yml/badge.svg)](https://github.com/asaptf/swift-extract/actions/workflows/ci.yml)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fasaptf%2Fswift-extract%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/asaptf/swift-extract)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fasaptf%2Fswift-extract%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/asaptf/swift-extract)
![Swift 6.1](https://img.shields.io/badge/Swift-6.1-F05138.svg)
![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)
![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)

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
> *(Author note: record the ReceiptScanner flow for the launch tweet.)*

---

## Why swift-extract?

**The Python stack works — until you ship to a phone.**  
Instructor + unstructured + OCR glue is the de-facto pattern for structured LLM output. On iOS/macOS that usually means a backend: network latency, cost per page, and receipts leaving the device.

**On-device models change the product equation.**  
Apple Foundation Models, MLX, and llama.cpp make private, offline extraction realistic. Cloud models stay one configuration flip away when you need max quality.

**Swift is ready now.**  
Macros give compile-time schemas (no `Mirror`). Vision and PDFKit are first-party. [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) unifies providers with an API close to Apple’s Foundation Models. **swift-extract** is Instructor for Swift — document-first and multimodal.

---

## Contents

| Doc | What it covers |
| --- | --- |
| [Getting started](docs/GettingStarted.md) | Install, first extraction, backends |
| [API reference guide](docs/API.md) | Macros, sources, session, options, errors |
| [Examples cookbook](docs/Examples.md) | Receipts, invoices, emails, retries, tests |
| [Backends & traits](docs/Backends.md) | Apple Intelligence, MLX, OpenAI, Anthropic, SPM traits |
| [ReceiptScanner demo](Examples/ReceiptScanner/README.md) | One-click Xcode project |

---

## Install

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/asaptf/swift-extract.git", from: "0.1.0")
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

In Xcode: **File → Add Package Dependencies…** and paste the repository URL.

**Requirements:** Swift 6.1+, iOS 17+ / macOS 14+.

---

## 60-second tour

### 1. Mark your type

```swift
import Extract
import Foundation

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

### 2. Configure a model

```swift
import AnyLanguageModel

// Cloud
let session = ExtractionSession(
    model: OpenAILanguageModel(apiKey: apiKey, model: "gpt-4o-mini")
)

// Or on-device when available (iOS 26 / macOS 26 + Apple Intelligence)
// let session = ExtractionSession.default
```

### 3. Extract

```swift
// From a PDF
let receipt: Receipt = try await Extract.from(pdfURL, using: session)

// From plain text
let receipt: Receipt = try await Extract.from(emailBody, using: session)

// From an image file
let receipt: Receipt = try await Extract.from(
    try ExtractionSource.image(url: photoURL),
    using: session
)

// With metadata (attempts, raw model output)
let result = try await Extract.detailed(from: .pdf(pdfURL), using: session)
print(result.value.total, result.attempts, result.rawModelOutput)
```

### 4. Handle errors

```swift
do {
    let invoice: Invoice = try await Extract.from(url, using: session)
} catch let error as ExtractionError {
    switch error {
    case .emptyDocument:
        print("Nothing to extract")
    case .modelUnavailable(let message):
        print("Configure a model: \(message)")
    case .validationFailed(let attempts, let last, let raw):
        print("Failed after \(attempts) tries: \(last)\n\(raw)")
    case .unreadableSource(let underlying):
        print("Could not read file: \(underlying?.localizedDescription ?? "?")")
    default:
        print(error.localizedDescription)
    }
}
```

---

## Package traits (optional heavy backends)

Default build is **lightweight**: text + PDFKit + Vision OCR + cloud/Apple backends.

| Trait | Backend | When you need it |
| --- | --- | --- |
| `MLX` | Local MLX models | Apple Silicon offline inference |
| `CoreML` | Core ML models | On-device Core ML LLMs |
| `Llama` | llama.cpp / GGUF | Local GGUF models |

```swift
.package(
    url: "https://github.com/asaptf/swift-extract.git",
    from: "0.1.0",
    traits: ["MLX"]
)
```

### SPM trait resolution workaround

If enabling traits fails with *“exhausted attempts to resolve the dependencies graph”* ([swift-package-manager#9286](https://github.com/swiftlang/swift-package-manager/issues/9286) / [AnyLanguageModel#135](https://github.com/huggingface/AnyLanguageModel/issues/135)), also declare the underlying packages:

```swift
dependencies: [
    .package(
        url: "https://github.com/asaptf/swift-extract.git",
        from: "0.1.0",
        traits: ["MLX", "CoreML", "Llama"]
    ),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "2.25.5"),       // MLX
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0"), // CoreML
    .package(url: "https://github.com/mattt/llama.swift", from: "2.0.0"),              // Llama
]
```

---

## CLI

```bash
# Offline / CI (deterministic mock model)
swift run extract-cli fixtures/invoice.pdf \
  --schema Examples/schemas/Invoice.swift \
  --mock

# Live (uses ExtractionSession.default when Apple Intelligence is available)
swift run extract-cli fixtures/invoice.pdf --type Invoice
```

---

## Demo app

Open **one click**:

```text
Examples/ReceiptScanner/ReceiptScanner.xcodeproj
```

Or from the command line:

```bash
cd Examples/ReceiptScanner
open ReceiptScanner.xcodeproj
# or: swift run ReceiptScanner
```

Bundled fixtures: digital invoice PDF, café receipt image, email screenshot. Configure Apple Intelligence, OpenAI, Anthropic, or MLX in **Settings**. No hardcoded extraction results.

---

## Supported property types

| Type | Schema | Notes |
| --- | --- | --- |
| `String` | string | Whitespace trimmed |
| `Bool` | boolean | Also `"yes"` / `"1"` |
| Integers / floats / `Decimal` | integer / number | `Decimal` accepts `"$1,234.50"` |
| `Date` | string `date-time` | ISO-8601 + common human formats |
| `URL` | string `uri` | |
| `Optional` / `Array` | — | Nested as expected |
| Nested `@Extractable` | object | |
| String `CaseIterable` enums | string enum | Conform to `Extractable` |

Unsupported types (`UUID`, `Data`, dictionaries, …) produce a **compile-time** diagnostic.

---

## Limitations (v0.1)

- Handwriting OCR quality is not guaranteed.
- Table structure is linearized text — not a table model.
- Prompts are English-first.
- Guided generation uses schema-in-prompt (AnyLanguageModel’s `respond(to:schema:)` is not used; see `DECISIONS.md`).
- CLI does not JIT-compile arbitrary `.swift` schema files; use embedded types matching `Examples/schemas/`.

---

## Roadmap

- [ ] Audio input (Speech framework)
- [ ] Streaming partials for `@Extractable`
- [ ] Per-field provenance (bounding boxes)
- [ ] Evaluation harness
- [ ] First-class guided-generation bridge when AnyLanguageModel passes schemas through

Architecture notes: [`DECISIONS.md`](DECISIONS.md).

---

## Development

```bash
swift build
swift test
swift run extract-cli fixtures/invoice.pdf --schema Examples/schemas/Invoice.swift --mock
swift format lint --configuration .swift-format --recursive Sources Tests
```

---

## License

Licensed under the **Apache License, Version 2.0**. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

---

## Package identity

| | |
| --- | --- |
| Repository | https://github.com/asaptf/swift-extract |
| Package name | `swift-extract` |
| Library product | `Extract` |
| License | Apache-2.0 |

```swift
import Extract
```

After the first release is indexed, add the package to the [Swift Package Index](https://swiftpackageindex.com/add-a-package) with that repository URL.