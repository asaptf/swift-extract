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

    /// Cross-field semantic checks after a successful decode.
    /// Default is a no-op; override to throw ``InvariantValidationError``.
    func validateInvariants() throws
}
```

Prefer the macro. Manual conformance is useful for string enums:

```swift
enum Status: String, Codable, Sendable, CaseIterable {
    case open, closed
}
extension Status: Extractable {} // uses default string-enum schema
```

### Cross-field invariants

JSON Schema (and lenient decoding) only catch *malformed* output. A response that is
well-typed and **wrong** — e.g. `total: 99.99` when line items sum to `12.50` — decodes
cleanly. Grounding signals deliberately never flag fabricated numbers as `absent`.

Declare arithmetic or temporal constraints in plain Swift by overriding
`validateInvariants()`:

```swift
@Extractable
struct Receipt {
    let total: Decimal
    let tax: Decimal
    let items: [Item]
    // ...

    func validateInvariants() throws {
        let sum = items.reduce(0) { $0 + $1.price } + tax
        if !Extract.isApproximatelyEqual(total, to: sum) {
            throw InvariantValidationError(
                path: "total",
                expected: "items + tax ≈ \(sum)",
                found: "\(total)"
            )
        }
    }
}
```

| Type | Role |
| --- | --- |
| `InvariantIssue` | One field-addressable complaint (`path`, `expected`, `found`) |
| `InvariantValidationError` | Thrown from `validateInvariants()`; holds one or more issues |
| `Extract.isApproximatelyEqual(_:to:tolerance:)` | Money comparison with **explicit** tolerance (default `Extract.defaultMoneyTolerance` / `0.01`) |

**Retry semantics:** a thrown invariant error is treated exactly like a decode failure:

1. The issue is rendered into the same field-shaped repair prompt as `DecodingError`.
2. The previous JSON is attached; the model retries.
3. After `maxRetries + 1` total attempts the call throws
   `ExtractionError.validationFailed` (same case as decode exhaustion), with the last
   `InvariantValidationError` as `lastError` and the raw model output.

Both the single-chunk path and the chunk-merge path run `validateInvariants()` on the
fully decoded value (partials from individual chunks are not invariant-checked).

**Useful consequence:** if a type declares invariants and you got a value back, those
invariants held on that value. That is arithmetic, not inference — unlike
`ExtractionSignals`, which are only grounding evidence.

See [Examples → Cross-field invariants](Examples.md#9-cross-field-invariants-repair-loop)
for a full Receipt recipe.

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
5. Run ``Extractable/validateInvariants()`` (default no-op)
6. On decode **or** invariant failure: repair prompt with field-level errors; retry up to `maxRetries`
7. Large docs: chunk extract → merge pass (invariants checked on the merged value)

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
    public let signals: ExtractionSignals   // grounding evidence (not a score)
}

public enum ExtractionError: Error {
    case unreadableSource(underlying: Error?)
    case emptyDocument
    case modelUnavailable(String)
    /// Decode *or* invariant validation exhausted retries.
    /// `lastError` is a `DecodingError` or `InvariantValidationError`.
    case validationFailed(attempts: Int, lastError: Error, rawOutput: String)
    case mergeFailed(String)
    case internalError(String)
}
```

`locale` does not restrict input language: document content may be Chinese, Arabic, or other
scripts. It only steers ambiguous date/number interpretation and a prompt locale hint.
Multilingual scope: [README → Languages & scripts](../README.md#languages--scripts).

---

## Extraction signals (grounding)

Every successful `Extract.detailed` result includes ``ExtractionSignals``: **informational
facts about how each leaf relates to the source text**, not a calibrated confidence score.
There is no probability, percentage, or single aggregate number. Do not threshold these
for auto-accept.

```swift
public enum Grounding: String, Sendable {
    case verbatim      // exact substring of the source
    case normalized    // found after case / whitespace / diacritic / punctuation folding
    case reformatted   // type-converted (dates, numbers, bools) — literal match N/A
    case absent        // not found in source (inferred or hallucinated) — look, don't auto-reject
}

public struct FieldSignal: Sendable {
    public let path: String       // e.g. "total", "items[0].name"
    public let grounding: Grounding
}

public struct ExtractionSignals: Sendable {
    public let attempts: Int
    public let chunksUsed: Int
    public let fields: [FieldSignal]
    public var absentFieldPaths: [String] { get }
}
```

### How grounding is computed

1. The decoded value is re-encoded with `JSONEncoder` (dates as ISO strings).
2. The JSON tree is walked in parallel with `T.extractionSchema` so each leaf knows its
   declared type / `format`.
3. Paths use dotted and indexed notation: `merchant`, `lineItems[0].amount`.
4. Strings are searched in the source text (verbatim, then normalized). Normalization
   case-folds, strips diacritics, treats punctuation as word boundaries, and collapses
   whitespace — so a comma-joined address still matches the same content printed across
   newlines.
5. Leaves with `format == "date-time"` and numeric leaves are reported as
   **`reformatted`** when they do not appear literally — the model routinely rewrites
   `15 MAR 1990` → `1990-03-15` and `12.50` / `$12.50` → `12.5`. Treating those as
   `absent` would make the signal pure noise.
6. Booleans and nulls are not groundable against free text; they are reported as
   `reformatted`.

### When `absent` can fire

**In practice `absent` only ever fires for string leaves.** Numeric and date fields are
never reported as `absent`:

| Leaf type | No match found → |
| --- | --- |
| String | `absent` |
| Number / integer | `reformatted` (never `absent`) |
| Date-time | `reformatted` (never `absent`) |
| Bool / null | `reformatted` |

For **numbers** this is deliberate and conservative: small integers like `quantity: 2`
would otherwise match spuriously throughout free text, so a **fabricated number is never
flagged**. `absentFieldPaths` therefore cannot be used to catch invented totals or
quantities — only invented strings.

**`absent` means “not found in the source text”.** That is a prompt to inspect the field,
not proof of error (the model may have correctly inferred a value that is only implied).

```swift
let result: ExtractionResult<Receipt> = try await Extract.detailed(from: photo, using: session)
for field in result.signals.fields where field.grounding == .absent {
    print("Review:", field.path)
}
print(result.signals.absentFieldPaths)
```

Signals are computed on every extraction (substring search over the document text). There
is no opt-out flag.

---

## MRZ cross-check

When a document has a Machine Readable Zone, `MRZParser` yields an independent
deterministic source for several fields. Cross-check those against LLM-extracted values
with an **explicit** mapping — the library does not guess property names.

```swift
public enum MRZField: String, Sendable {
    case documentNumber, surname, givenNames, nationality, sex
    case dateOfBirth, expiryDate, issuingState, documentCode
}

extension MRZResult {
    public func crossCheck(against extracted: [MRZField: String]) -> MRZCrossCheckResult
}
```

Comparison normalizes before deciding: MRZ is uppercase, diacritic-free, and `<`-padded;
extracted values may look like `Jane Alexandra Doe`. Dates compare by calendar day and
accept ISO-8601 or raw `YYMMDD` on the caller’s side.

Like grounding, this is an **informational signal, not a confidence score**. Agreement is
real evidence; disagreement is a prompt to look. See
[Examples → Identity document](Examples.md#3-identity-document-passport--id--driver-license)
for a full `IdentityDocument` mapping recipe.

---

## Lenient decoding helpers

Generated `init(from:)` uses package helpers such as:

- `decodeLenientString` / `Decimal` / `Date` / `URL` / `Bool`
- `Extractable.decodeExtracted(from:locale:)` for top-level JSON text (also strips fences)

These are public so hand-written `Extractable` types can share behavior.
