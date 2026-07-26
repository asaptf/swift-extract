# Engineering Decisions — swift-extract

This log records architectural choices and intentional deviations from the original
product brief. Read it before changing public API shape.

## Tools version & concurrency

- **Swift tools-version `6.1`** (brief asked for 6.0). Package traits and the
  `huggingface/AnyLanguageModel` dependency require 6.1+. Language mode remains
  Swift 6 with `-strict-concurrency=complete`.
- Platforms: **iOS 17+ / macOS 14+**. Apple Intelligence / Foundation Models
  paths are gated with `#available(iOS 26, macOS 26, *)`.

## Dependency strategy

- **LLM surface**: only `AnyLanguageModel`. We never ship provider HTTP clients.
- **Package traits** mirror AnyLanguageModel: `MLX`, `CoreML`, `Llama`. Default
  trait set is empty so the default product stays lightweight (text + PDFKit +
  Vision + cloud/Apple backends already available without traits).
- **SPM trait graph bug** (swiftlang/swift-package-manager#9286 /
  AnyLanguageModel#135): documented in the README. Consumers who enable traits
  must also declare the underlying packages explicitly.
- **Macros**: `swift-syntax` only, via a `.macro` target.
- No CocoaPods, no Xcode project for the library; the demo app is a multiplatform
  SwiftUI package product under `Examples/`.

## Session & model abstraction

- Public `ExtractionSession` takes `any LanguageModel` (AnyLanguageModel’s
  protocol) and wraps it with `LanguageModelSession` at call time.
- Generation defaults to **temperature 0** via `GenerationOptions`.
- `ExtractionSession.default` resolves `SystemLanguageModel.default` when
  Foundation Models is importable and available; otherwise extraction fails with
  `ExtractionError.modelUnavailable` and an actionable message. We do **not**
  crash on accessing `.default`.
- For unit tests and the offline CLI path we inject a `MockLanguageModel`
  conforming to `LanguageModel`, or use the package-internal
  `ExtractionGenerating` seam so the extraction loop is free of network.

## Macros vs Apple `@Generable`

| Concept | FoundationModels / AnyLanguageModel | swift-extract |
| --- | --- | --- |
| Type marker | `@Generable` | `@Extractable` |
| Field hint | `@Guide(description:)` | `@Guide("...")` |
| Schema | `generationSchema` / guided gen | `extractionSchema` (JSON-Schema-like) |
| Protocol | `Generable` | `Extractable: Codable & Sendable` |
| Primary use | On-device structured generation | Document → typed value (OCR + repair) |

Schemas are intentionally close (object/properties/required/enum/array/optional)
so a future bridge that maps `ExtractionSchema` → `GenerationSchema` /
`DynamicGenerationSchema` is straightforward. We do **not** re-export or depend
on `@Generable` for extractable types — extraction needs lenient decode and
repair loops that guided generation alone does not provide.

### `@Guide` naming

Both packages export a `@Guide` macro. Ours is a **peer** macro taking a single
string literal (`@Guide("ISO 8601")`). If a module imports both, qualify or
avoid dual import at file scope. Documented as a known friction; renaming would
break the brief’s API surface.

### Schema generation

Macros only — **no `Mirror`**. Unsupported stored-property types emit a compile-time
diagnostic from the macro, not silent `Any` / empty schema nodes.

### Lenient decoding

Custom `init(from:)` generated in an extension (preserves memberwise init):

- `Date`: ISO-8601 (with/without fractional seconds) + common human formats
  (`yyyy-MM-dd`, `MM/dd/yyyy`, `dd/MM/yyyy`, `MMM d, yyyy`, etc.).
- `Decimal`: JSON number **or** numeric string.
- `String`: trim whitespace.
- Locale hint from `ExtractionOptions.locale` influences number/date parsing where
  relevant.

## Extraction loop

1. Ingest → internal `ExtractedDocument` (ordered text blocks + optional
   page / bounding-box provenance).
2. Prompt: system persona + JSON schema render + guides + locale + document.
3. Prefer constrained/JSON generation when the backend supports it; otherwise
   plain string generation. v0.1 always sends schema in the prompt and requests
   a single JSON object (works with all backends).
4. Strip markdown fences; decode with the lenient decoder.
5. On failure: retry with previous output + machine-generated field errors
   (Instructor-style), up to `maxRetries`.
6. Chunking (`.automatic`): if estimated tokens exceed a soft budget, extract
   per chunk then a final merge pass. Correctness over cleverness.

## Adapters

- `ExtractionSource`: `text`, `pdf`, `image(CGImage)`, `fileURL` (UTType sniff).
- PDF: PDFKit text layer first; if average extractable characters/page &lt; 10,
  rasterize pages and run Vision OCR.
- OCR: Vision only (`VNRecognizeTextRequest`; `RecognizeDocumentsRequest` when
  available). Reading order from Vision’s built-in ordering — no layout engine
  in v0.1.
- Image conveniences: `URL`, `Data`, `UIImage`/`NSImage` behind `#if`.

## CLI

- Product name: `extract-cli` (executable target).
- Offline CI path: `--mock` (or `EXTRACT_USE_MOCK=1`) drives a deterministic
  mock model so CI needs no network or Apple Intelligence.
- `--schema` accepts a path used for documentation / validation messaging; the
  CLI embeds known schema types (`Invoice`, `Receipt`) that match
  `Examples/schemas/*.swift`. Runtime Swift compilation of arbitrary schema
  files is out of scope for v0.1 (would require embedding a compiler).

## Demo app

- Multiplatform SwiftUI under `Examples/ReceiptScanner`.
- Real public API only — no hardcoded extraction success path.
- When no backend is configured/available, show a clear setup screen.
- Bundled fixtures: digital PDF invoice, photographed receipt image, email
  screenshot. Zero-config happy path requires Apple Intelligence; otherwise
  user pastes a cloud key or enables a local model.

## Testing policy

- Macro tests: `assertMacroExpansion` via swift-syntax macros test support.
- Core loop: `MockLanguageModel` / mock generator — happy path, repair, fence
  strip, lenient decode, chunk-merge.
- Adapters: tiny PDF fixture (generated or committed); OCR tests skip cleanly
  when Vision is unavailable.
- **No network** in automated tests.

## Deviations from the brief

1. **Swift tools 6.1** instead of 6.0 (traits + AnyLanguageModel).
2. **CLI does not JIT-compile** arbitrary `.swift` schema files; it matches
   embedded types to the example schema sources.
3. **Constrained generation** maps `ExtractionSchema` → AnyLanguageModel
   `DynamicGenerationSchema` / `GenerationSchema` and calls
   `LanguageModelSession.respond(to:schema:)` when conversion succeeds; plain
   string generation is the fallback if the constrained path throws. Schema is
   also always embedded in the prompt for backends without guided decoding.
4. **Temperature**: `ExtractionOptions.temperature` is `Double?` (`nil` by
   default). Resolved as `options.temperature ?? session.temperature` so
   `ExtractionSession(model:temperature:)` is honored unless the call site
   overrides.
4. Demo is an SPM multiplatform executable/library target rather than a full
   `.xcodeproj` when possible; if Xcode project files are needed for iOS device
   camera flows, they live only under `Examples/`.
5. `@Guide` takes a positional `String` (brief’s sample) rather than
   FoundationModels’ `description:` label — closer to the hero snippet.

## Future bridge notes

Mapping sketch for `@Extractable` → guided generation:

```text
ExtractionSchema.object → GenerationSchema / DynamicGenerationSchema object
ExtractionSchema.string(enum:) → string enum node
ExtractionSchema.array → array node with items
@Guide text → Guide description
```

When that lands, `Extract` can short-circuit the JSON parse path for backends
that return typed `Generable` values directly.
