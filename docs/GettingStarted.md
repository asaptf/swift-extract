# Getting started

This guide takes you from an empty app to a working extraction in a few minutes.

## Prerequisites

- Xcode 16+ (or Swift 6.1 toolchain)
- iOS 17 / macOS 14 deployment target
- A language model: Apple Intelligence **or** an API key **or** a local MLX/GGUF setup

## Add the package

### Xcode app

1. **File → Add Package Dependencies…**
2. URL: `https://github.com/asaptf/swift-extract.git`
3. Add product **`Extract`** to your app target.

### Package.swift

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/asaptf/swift-extract.git", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "MyApp",
            dependencies: [
                .product(name: "Extract", package: "swift-extract")
            ]
        )
    ]
)
```

## Define a schema

Use `@Extractable` on a `struct`. Nest types freely. Annotate tricky fields with `@Guide`.

```swift
import Extract
import Foundation

@Extractable
struct BusinessCard {
    let fullName: String
    let title: String?
    let company: String
    @Guide("E.164 or local phone number as printed") let phone: String?
    let email: String?
    let website: URL?
}
```

The macro synthesizes:

- `Extractable` + `Codable` + `Sendable`
- `static var extractionSchema` (JSON-Schema-like)
- Lenient `init(from:)` (dates, decimals, trimmed strings)

## Choose a backend

### A. OpenAI (fastest to try)

```swift
import Extract
import AnyLanguageModel

let session = ExtractionSession(
    model: OpenAILanguageModel(
        apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]!,
        model: "gpt-4o-mini"
    )
)
```

### B. Anthropic

```swift
let session = ExtractionSession(
    model: AnthropicLanguageModel(
        apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!,
        model: "claude-sonnet-4-5-20250929"
    )
)
```

### C. Apple Intelligence (on-device)

```swift
// Uses SystemLanguageModel when available (iOS 26 / macOS 26 + Apple Intelligence).
let session = ExtractionSession.default

// Or explicit:
if #available(iOS 26, macOS 26, *) {
    let session = ExtractionSession(model: SystemLanguageModel.default)
}
```

If unavailable, `Extract` throws `ExtractionError.modelUnavailable` with a clear setup message.

### D. Offline tests / CI

```swift
let session = ExtractionSession.mock(
    MockLanguageModel(responses: [
        #"{"fullName":"Ada Lovelace","title":"Mathematician","company":"Analytical Engines","phone":null,"email":"ada@example.com","website":"https://example.com"}"#
    ])
)
```

## Run an extraction

```swift
let text = """
Ada Lovelace
Mathematician
Analytical Engines Ltd.
ada@example.com
https://example.com
"""

let card: BusinessCard = try await Extract.from(text, using: session)
print(card.fullName)   // Ada Lovelace
print(card.company)    // Analytical Engines Ltd.
```

### From a PDF or image

```swift
let url = Bundle.main.url(forResource: "invoice", withExtension: "pdf")!
let invoice: Invoice = try await Extract.from(url, using: session)

// Explicit source enum
let fromImage = try await Extract.from(
    .image(try ExtractionSource.image(url: photoURL) /* unwrap */),
    using: session
) as Receipt
```

Convenience:

```swift
// fileURL sniffs UTType → PDF / image / text
let value: Receipt = try await Extract.from(fileURL, using: session)

// Or construct sources:
let s1 = ExtractionSource.text(raw)
let s2 = ExtractionSource.pdf(pdfURL)
let s3 = try ExtractionSource.image(data: jpegData)
let s4 = ExtractionSource.fileURL(pathURL)
```

## Tune options

```swift
var options = ExtractionOptions()
options.maxRetries = 3                          // Instructor-style repair loop
options.locale = Locale(identifier: "en_US")  // date/number hints
options.chunkingStrategy = .automatic         // large documents
options.temperature = 0                       // or nil to use session.temperature
options.invariantPolicy = .strict             // or .reportViolations to keep a failed check

let detailed = try await Extract.detailed(
    from: .pdf(url),
    using: session,
    options: options
)
print("attempts:", detailed.attempts)
print("raw:", detailed.rawModelOutput)
```

## Multilingual documents

swift-extract is **not English-only**. Document text may be Chinese, Arabic, Japanese, Korean, or other languages your OCR and model support:

- **PDF / plain text** — Unicode text is passed through unchanged.
- **Photos & scans** — Vision OCR is multi-script (including CJK and Arabic when available on the device).
- **Extraction** — multilingual LLMs map that text into your `@Extractable` fields.

Use `ExtractionOptions.locale` so ambiguous dates and number formats are interpreted correctly (`zh_CN`, `ar_SA`, `ja_JP`, …). Prompts and example `@Guide`s are English-first; field *values* can remain in the document language. See [README → Languages & scripts](../README.md#languages--scripts).

## Next steps

- [API guide](API.md) — full surface
- [Examples cookbook](Examples.md) — receipts, invoices, identity documents, emails, custom enums, tests
- [Backends & traits](Backends.md) — MLX, traits, [small local models](Backends.md#choosing-a-small-local-model), Keychain tips
- [ReceiptScanner](../Examples/ReceiptScanner/README.md) — polished multiplatform demo
