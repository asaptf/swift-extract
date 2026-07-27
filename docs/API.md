# API guide

## Macros

### `@Extractable`

Attached member + extension macro. Apply to a `struct`.

```swift
@Extractable
struct Order {
    let id: String
    let total: Decimal
    let createdAt: Date
}
```

Generates:

| Member | Purpose |
| --- | --- |
| `CodingKeys` | Stable coding keys |
| `extractionSchema` | JSON-Schema-like description |
| `init(from:)` / `encode(to:)` | Lenient Codable (memberwise init preserved) |
| Conformance | `Extractable`, `Codable`, `Sendable` |

Nested types work:

```swift
@Extractable
struct Order {
    let items: [Line]

    @Extractable
    struct Line {
        let sku: String
        let qty: Int
    }
}
```

### `@Guide(_:)`

Peer macro on a stored property. The string is embedded in the schema and the extraction prompt.

```swift
@Guide("ISO 4217 currency code, uppercase")
let currency: String
```

> **Note:** AnyLanguageModel also exports `@Guide`. Prefer a single import of `Extract` in files that only use extraction, or qualify carefully if both modules are imported.

### `Extractable` protocol

```swift
public protocol Extractable: Codable, Sendable {
    nonisolated static var extractionSchema: ExtractionSchema { get }
}
```

Prefer the macro. Manual conformance is useful for string enums:

```swift
enum Status: String, Codable, Sendable, CaseIterable {
    case open, closed
}
extension Status: Extractable {} // uses default string-enum schema
```

---

## `ExtractionSchema`

JSON-Schema-like value used for prompts (and future guided-generation bridges).

```swift
let schema = Receipt.extractionSchema
print(schema.renderJSONSchema())
// {
//   "type": "object",
//   "title": "Receipt",
//   "properties": { ... },
//   "required": [ ... ]
// }
```

Factories: `.object`, `.string`, `.number`, `.integer`, `.boolean`, `.array`, `.stringEnum`, `.optional()`.

`SchemaBridge` maps to AnyLanguageModel `GenerationSchema` for future constrained APIs; the live generation path embeds this schema in the prompt (see `DECISIONS.md`).

---

## Sources

```swift
public enum ExtractionSource: Sendable {
    case text(String)
    case pdf(URL)
    case image(CGImage)
    case fileURL(URL)   // UTType sniff
}
```

### Conveniences

```swift
try ExtractionSource.image(data: data)
try ExtractionSource.image(url: url)
#if canImport(UIKit)
try ExtractionSource.image(uiImage)
#endif
#if canImport(AppKit)
try ExtractionSource.image(nsImage)
#endif
```

### What happens under the hood

| Source | Pipeline |
| --- | --- |
| `text` | Normalize → blocks |
| `pdf` | PDFKit text layer; if **&lt; 10 chars/page avg** → rasterize + Vision OCR |
| `image` | Vision `VNRecognizeTextRequest` (reading order by geometry) |
| `fileURL` | Route by UTType / extension |

Internal model: `ExtractedDocument` (ordered blocks + optional page / bounding box).

---

## Entry points

```swift
public enum Extract {
    // Inferred type
    public static func from<T: Extractable>(
        _ source: ExtractionSource,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init()
    ) async throws -> T

    // Explicit type
    public static func from<T: Extractable>(
        _ source: ExtractionSource,
        as type: T.Type,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init()
    ) async throws -> T

    // Metadata
    public static func detailed<T: Extractable>(...) async throws -> ExtractionResult<T>
}
```

Overloads:

```swift
Extract.from("raw text", using: session)           // String → .text
Extract.from(fileURL, using: session)              // URL → .fileURL
```

### Extraction loop

1. Ingest → normalized text (+ page markers)
2. Build prompt (persona + schema + guides + locale + document)
3. Generate (`String` via AnyLanguageModel)
4. Strip markdown fences → lenient decode
5. On failure: repair prompt with field-level errors; retry up to `maxRetries`
6. Large docs: chunk extract → merge pass

---

## Session

```swift
public struct ExtractionSession: Sendable {
    public static var `default`: ExtractionSession
    public init(model: any LanguageModel, temperature: Double = 0)
    public let temperature: Double

    public static func mock(_ model: MockLanguageModel, temperature: Double = 0) -> ExtractionSession
}
```

- `.default` → Apple `SystemLanguageModel` when available; else fails clearly on use.
- `temperature` on the session is used when `ExtractionOptions.temperature == nil`.

```swift
let session = ExtractionSession(
    model: OpenAILanguageModel(apiKey: key, model: "gpt-4o-mini"),
    temperature: 0
)
```

---

## Options, results, errors

```swift
public struct ExtractionOptions: Sendable {
    public var maxRetries: Int                 // default 2
    public var chunkingStrategy: ChunkingStrategy  // .automatic | .none | .fixed(characterBudget:)
    public var locale: Locale?                 // date/number parse + prompt hint (zh_CN, ar_SA, …)
    public var softContextCharacterBudget: Int // default 12_000
    public var temperature: Double?            // nil → session.temperature
}

public struct ExtractionResult<T: Extractable>: Sendable {
    public let value: T
    public let attempts: Int
    public let rawModelOutput: String
    public let chunksUsed: Int
}

public enum ExtractionError: Error {
    case unreadableSource(underlying: Error?)
    case emptyDocument
    case modelUnavailable(String)
    case validationFailed(attempts: Int, lastError: Error, rawOutput: String)
    case mergeFailed(String)
    case internalError(String)
}
```

`locale` does not restrict input language: document content may be Chinese, Arabic, or other
scripts. It only steers ambiguous date/number interpretation and a prompt locale hint.
Multilingual scope: [README → Languages & scripts](../README.md#languages--scripts).

---

## Lenient decoding helpers

Generated `init(from:)` uses package helpers such as:

- `decodeLenientString` / `Decimal` / `Date` / `URL` / `Bool`
- `Extractable.decodeExtracted(from:locale:)` for top-level JSON text (also strips fences)

These are public so hand-written `Extractable` types can share behavior.
