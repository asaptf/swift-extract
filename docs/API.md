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
    /// Preview type for ``Extract/stream``; default `Self` keeps hand-written
    /// conformances compiling. The macro generates a nested `Partial` with every
    /// field optional.
    associatedtype Partial: Decodable & Sendable = Self

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
3. After `maxRetries + 1` total attempts the default ``InvariantPolicy/strict`` throws
   `ExtractionError.validationFailed` (same case as decode exhaustion), with the last
   `InvariantValidationError` as `lastError` and the raw model output.

Opt into ``InvariantPolicy/reportViolations`` when a usable extract beats no extract.
The loop still runs the same number of attempts; when they are exhausted,
``Extract/detailed`` and ``Extract/stream`` return the last decoded value with the
remaining ``InvariantIssue``s on ``ExtractionResult/invariantViolations``. Decode
failures still throw. ``Extract/from`` still throws under either policy — it returns
a bare `T` with nowhere to attach the issues.

Both the single-chunk path and the chunk-merge path run `validateInvariants()` on the
fully decoded value (partials from individual chunks are not invariant-checked). On the
chunk path, partial JSON objects are **merged deterministically** (see
[Chunk merge](#chunk-merge-deterministic)) before that decode + invariant step; if the
merged tree fails, the usual repair loop still runs against the full document.

**Useful consequence:** if a type declares invariants and you got a value back, those
invariants held on that value. That is arithmetic, not inference — unlike
`ExtractionSignals`, which are only grounding evidence. That sentence is the default
path (`Extract.from`, and `detailed` / `stream` under `.strict`). Under
`.reportViolations`, read `result.invariantViolations` before treating the value as
arithmetically sound.

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
| `pdf` | Per page: keep a high-quality text layer, else rasterise (honour `/Rotate`, default 300 DPI) + Vision OCR. Auto-orient scans (0/90 axis, 180° from character order). |
| `image` | ``OCRRecognizing`` (default ``VisionOCR`` / `VNRecognizeTextRequest`) |
| `fileURL` | Route by UTType / extension |

Internal model: `ExtractedDocument` (ordered blocks + optional page / bounding box).

### Ingest engines

```swift
public protocol OCRRecognizing: Sendable {
    func recognize(image: CGImage) throws -> [RecognizedLine]
}
public struct VisionOCR: OCRRecognizing { public init() }

public protocol PDFRendering: Sendable {
    func render(page: PDFPage, dpi: Double, extraRotation: Int) -> CGImage?
}
public struct PDFKitRenderer: PDFRendering { public init() }

public struct IngestContext: Sendable {
    public var ocr: any OCRRecognizing        // default VisionOCR()
    public var renderer: any PDFRendering     // default PDFKitRenderer()
}

Extract.from(source, using: session, ingest: IngestContext(ocr: myOCR))
Extract.inspect(url, ingest: IngestContext(renderer: myRenderer))
```

`RecognizedLine` is in oriented page space (top-left, y down, normalised `0...1`).
`characterXs` feeds 180° disambiguation; leave it empty if the engine has no per-glyph boxes.

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

    // Streaming partials → terminal final
    public static func stream<T: Extractable>(
        from source: ExtractionSource,
        as type: T.Type = T.self,
        using session: ExtractionSession = .default,
        options: ExtractionOptions = .init()
    ) -> AsyncThrowingStream<ExtractionUpdate<T>, Error>
}

public enum ExtractionUpdate<T: Extractable>: Sendable {
    case partial(T.Partial)           // completed-token preview; no signals
    case final(ExtractionResult<T>)   // same shape as detailed
}
```

Overloads:

```swift
Extract.from("raw text", using: session)           // String → .text
Extract.from(fileURL, using: session)              // URL → .fileURL
Extract.stream(from: "raw text", as: T.self, using: session)
Extract.stream(from: fileURL, as: T.self, using: session)
```

### Runtime schema (`JSONValue`)

When the field list is not a Swift type (a document type edited at run time), pass
an `ExtractionSchema` and receive `JSONValue`:

```swift
let schema = ExtractionSchema.object(
    properties: [
        "vendor": .string(),
        "total": .number(),
        "items": .array(items: .object(
            properties: ["sku": .string(), "qty": .integer()],
            required: ["sku"]
        )),
    ],
    required: ["vendor", "total"]
)

let value: JSONValue = try await Extract.from(
    source,
    schema: schema,
    invariants: { tree in
        // optional; throw InvariantValidationError to repair
    },
    using: session
)
value["vendor"]?.stringValue
value["items"]?[0]?["qty"]?.numberValue
```

`detailed` and `stream` have the same `schema:` overloads. Decode uses schema-driven
lenient coercion (string `"1,234.50"` → number, `"yes"` → bool, `"March 5, 2020"` →
`yyyy-MM-dd`). Prefer these overloads over `as: JSONValue.self` — the schema is
task-local for the call.

**Streaming rules:** partials surface only completed JSON tokens (no half-numbers /
truncated strings). Arrays may grow as elements complete. Chunked documents emit
no `.partial` — only `.final` after merge. Repair retries are not streamed; the
stream still ends with `.final` or throws (under ``InvariantPolicy/reportViolations``,
`.final` is yielded with remaining issues listed). Signals / tables attach to
`.final` only.

### Extraction loop

1. Ingest → normalized text (+ page markers)
2. Build prompt (persona + schema + guides + locale + document)
3. Generate (`String` via AnyLanguageModel)
4. Strip markdown fences → lenient decode
5. Run ``Extractable/validateInvariants()`` (default no-op)
6. On decode **or** invariant failure: repair prompt with field-level errors; retry up to `maxRetries`.
   Exhausted invariants throw under ``InvariantPolicy/strict`` (default); under
   ``InvariantPolicy/reportViolations`` the last decoded value is returned with
   ``ExtractionResult/invariantViolations``.
7. Large docs: chunk extract → **deterministic** JSON-tree merge → decode + invariants
   (repair loop on the full document if the merged tree fails)

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
    public var tableDetection: TableDetectionMode  // .automatic (default) | .off
    public var invariantPolicy: InvariantPolicy    // .strict (default) | .reportViolations
    public var textLayerPolicy: TextLayerPolicy    // .auto (default) | .always | .never
    public var textLayerQualityThreshold: Double   // default 0.85
    public var rasterDPI: Double                   // default 300, clamped 72...400
    public var autoOrient: Bool                    // default true
}

public enum InvariantPolicy: Sendable {
    case strict             // repair, then throw validationFailed (today)
    case reportViolations   // repair, then return value + remaining InvariantIssues
}

public struct ExtractionResult<T: Extractable>: Sendable {
    public let value: T
    public let attempts: Int
    public let rawModelOutput: String
    public let chunksUsed: Int
    public let signals: ExtractionSignals   // grounding evidence (not a score)
    public let tables: [ExtractedTable]     // geometric grids; empty when none / off
    public let invariantViolations: [InvariantIssue]  // empty unless .reportViolations exhausted
}

public enum TableDetectionMode: Sendable {
    // Detect when geometry exists; prompt injection only if schema has a collection
    case automatic
    case off        // skip detection; result.tables empty; no table section in prompt
}

public struct ExtractedTable: Sendable {
    public let pageIndex: Int
    public let rowCount: Int
    public let columnCount: Int
    public let cells: [Cell]
    public let headerRowIndex: Int?
    public func markdown() -> String   // GFM pipe table for prompts / debugging
}
```

`tableDetection` defaults to `.automatic`. Detection runs when positioned blocks exist
and `result.tables` always reflects full-document detection (not a per-chunk subset),
including for header-only target types. Tables are **appended** to the model prompt as
a labelled Markdown section **only when the target schema contains a collection**
(array property, including nested). Header-only types under `.automatic` therefore get
a prompt byte-identical to `.off`. The linearised document text is left unchanged either
way (cell merge is lossy, so substituting would drop content). When no tables are found
or mode is `.off`, the prompt is also byte-identical to a build without this feature.

```swift
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

public struct FieldProvenance: Sendable {
    public let pageIndex: Int     // 0-based
    public let boundingBox: CGRect  // normalised top-left (see coordinate convention)
}

public struct FieldSignal: Sendable {
    public let path: String       // e.g. "total", "items[0].name"
    public let grounding: Grounding
    public let provenance: FieldProvenance?  // nil when reformatted / absent / no geometry
}

public struct MergeConflict: Sendable {
    public let path: String       // e.g. "total", "seller.name"
    public let values: [String]   // competing compact JSON fragments, chunk order
}

public struct ExtractionSignals: Sendable {
    public let attempts: Int
    public let chunksUsed: Int
    public let fields: [FieldSignal]
    public let mergeConflicts: [MergeConflict]  // empty on single-chunk runs
    public var absentFieldPaths: [String] { get }
}
```

Each ``FieldSignal`` carries both **whether** the value was found (`grounding`) and
**where** (`provenance`). There is no parallel array to zip by index.

### Merge conflicts

When a document is split into chunks, each chunk returns a partial JSON object. Those
partials are merged **structurally** (no model call): objects key-wise, arrays by
concatenation with an ungrounded-entry drop and equality de-dupe, scalars by agreement
or **grounding rank**. If two chunks disagree on a scalar, the better-grounded value
(against **its own chunk** text) wins silently. Only **equal** grounding ranks are a
genuine conflict: the library keeps the first equally-grounded occurrence and appends a
``MergeConflict`` with the field path and the competing JSON values. There is no
confidence number — inspect `result.signals.mergeConflicts` the same way you inspect
`absent` grounding.

```swift
for conflict in result.signals.mergeConflicts {
    print(conflict.path, "candidates:", conflict.values)
}
```

A partial that is root `null` or a non-object contributes nothing (it does not fail the
run). See [Chunk merge](#chunk-merge-deterministic).

### Coordinate convention

PDF text-layer geometry and Vision OCR both convert into **one** space before boxes
leave the adapters:

| Property | Convention |
| --- | --- |
| Origin | **Top-left** of the page (PDF media box) or image |
| X axis | Increases to the **right** |
| Y axis | Increases **downward** |
| Units | **Normalised** to page/image size (`x`, `y`, `width`, `height` ∈ `[0, 1]`) |
| Page | `pageIndex` is **0-based**; one provenance = one page |

Map to pixels (top-left image origin): `(x * W, y * H, width * W, height * H)`.

### Multi-block and multi-page values

- **Same page:** multi-word / multi-line matches use the **axis-aligned union** of the
  matching blocks’ boxes.
- **Across pages:** a single `CGRect` cannot span pages. Provenance reports the
  **lowest `pageIndex`** that contributes matching blocks and unions **only that
  page’s** boxes; later pages are omitted (not guessed).
- **Table cells:** when the value matches a reconstructed cell, the **cell** rect is
  preferred over a wider enclosing text block.

`provenance` is `nil` for `reformatted` and `absent` leaves, for plain-text sources
without boxes, and whenever a textual match cannot be tied to a rectangle — never a
guessed box. The library returns geometry only; it does not draw or ship an
image-rendering API.

### How grounding is computed

1. The decoded value is re-encoded with `JSONEncoder` (dates as ISO strings).
2. The JSON tree is walked in parallel with `T.extractionSchema` so each leaf knows its
   declared type / `format`.
3. Paths use dotted and indexed notation: `merchant`, `lineItems[0].amount`.
4. Strings are searched in the source text (verbatim, then normalized). Normalization
   case-folds, strips diacritics, treats punctuation as word boundaries, and collapses
   whitespace — so a comma-joined address still matches the same content printed across
   newlines.
5. When grounding is `verbatim` or `normalized` and the document has positioned blocks
   (and optional table cells), the same match is localised per block / cell to fill
   `provenance` (cell preferred; multi-block union as above).
6. Leaves with `format == "date-time"` and numeric leaves are reported as
   **`reformatted`** when they do not appear literally — the model routinely rewrites
   `15 MAR 1990` → `1990-03-15` and `12.50` / `$12.50` → `12.5`. Treating those as
   `absent` would make the signal pure noise. Those leaves carry no provenance.
7. Booleans and nulls are not groundable against free text; they are reported as
   `reformatted` with no provenance.

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

// Highlight boxes in a review UI (coordinates: top-left normalised — see above).
for field in result.signals.fields {
    if let box = field.provenance {
        print(field.path, "page", box.pageIndex, box.boundingBox)
    }
}
```

Signals are computed on every extraction (substring search over the document text, plus
geometry location when boxes exist). There is no opt-out flag.

---

## Chunk merge (deterministic)

Long documents (`.automatic` over the soft budget, or `.fixed(characterBudget:)`) are
split into chunks, each extracted as a partial JSON object. **Merging is not delegated
to the model.** The library merges the raw JSON trees, then runs the same lenient
decode + `validateInvariants()` + repair path used for a single-chunk result.

| Rule | Behaviour |
| --- | --- |
| Objects | Key-wise recursive merge |
| Arrays | Concatenate → drop entries whose text is not in the full document → equality de-dupe |
| Scalars | Agree → take it; disagree → **better grounding wins**; equal rank → first + ``MergeConflict`` |
| Null field | Yields to a non-null without conflict |
| Root `null` / non-object partial | Contributes nothing (`{}`) |

### Scalar arbitration (grounding as arbiter)

Each disagreeing scalar is ranked against the **full document** text (the same source
``FieldGrounding`` uses for public signals after a chunked run — not a per-chunk slice,
and not by chunk position):

1. **verbatim** — exact substring (or sign-aware numeric hit)
2. **normalized** — found after the same folding used for field signals / numeric skeleton
3. **ungrounded** — no usable match

Higher rank wins. Equal ranks keep the **first** candidate and record a
``MergeConflict``. This deliberately does **not** encode domain layout rules such as
“totals are at the bottom”; it only prefers values the document can support over pure
hallucinations. (Ranking per-chunk was measured to demote correct early values whose
supporting text sits in a later slice.)

**Short numerics.** Bare 1–2 digit integers (`2`, `19`) match almost any document, so
for **merge ranking only** a numeric candidate counts as grounded when it is
*distinctive*: at least **3 digit characters**, or a decimal separator (`.` / `,`)
with at least one digit. Examples: `2` / `19` → ungrounded for arbitration; `119` /
`12.5` / `2,50` → may rank as verbatim/normalized. Public per-leaf ``Grounding``
signals are unchanged (numbers still never report `absent`).

### Array entry filter

After concatenation, an entry that has at least one non-empty **string** leaf is kept
if **some** of those strings are supported by the **full document**: verbatim or
normalized containment, **or** ≥50% of significant tokens (length ≥ 3 after the usual
search normalisation) appear in the normalised source. Token coverage keeps slightly
rephrased line descriptions. Pure numeric / bool entries (no text to ground) are kept
so legitimate bare rows are not deleted. Tax-table debris that literally appears in the
source can still survive — there is no line-item-context classifier.

**Array de-dupe** then collapses entries that match on every field after string trim
(the same light normalisation the decoder applies before type conversion). Two line
items that share a description but differ in amount are kept. Truly identical rows in
the source can collapse — that is the tradeoff for suppressing cross-chunk duplicates.

**Table assignment:** whole tables attach to a chunk only when every non-empty cell
string appears in that chunk’s text (no page-index broadcast onto hard-split slices,
no “attach all tables to chunk 0” fallback). Linear document text still carries the
content when a table matches no chunk.

**Hard-split boundaries:** when a single page exceeds the budget, the cut prefers a
newline, then any whitespace, within a window around the budget — never mid-token when
a boundary exists in that window.

`attempts` counts model generations (partials + any post-merge repairs). Deterministic
merge itself is free. `chunksUsed` is the number of document chunks in the run.

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
