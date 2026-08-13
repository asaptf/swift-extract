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
   per chunk then **deterministically merge** partial JSON trees (objects key-wise,
   arrays concat → drop text entries unsupported by the full document → dedupe,
   scalar conflicts → grounding rank against the full document, equal rank → first
   wins + `MergeConflict`). An LLM merge pass was measured to invent line items and
   drop headers; structural merge keeps the repair loop only for decode/invariant
   failure on the merged tree. “First occurrence wins” alone was measured to prefer
   early-chunk totals that never saw the real figure; grounding arbitration prefers
   document-supported values over hallucinations without encoding layout rules like
   “totals are at the bottom”. Per-chunk ranking was measured to demote correct early
   values; full-document rank matches public field signals.

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

## License & package identity

- **License:** Apache License 2.0 (with `NOTICE`). Chosen for patent grant clarity
  and alignment with AnyLanguageModel / SwiftSyntax licensing norms.
- **Package name:** `swift-extract` (library product `Extract`). Checked 2026-07
  against GitHub search and Swift Package Index — no published SPM package of the
  same name for structured LLM document extraction. Import remains `import Extract`.

## Deviations from the brief

1. **Swift tools 6.1** instead of 6.0 (traits + AnyLanguageModel).
1b. **License Apache-2.0** instead of MIT (user request; better patent grant).
2. **CLI does not JIT-compile** arbitrary `.swift` schema files; it matches
   embedded types to the example schema sources.
3. **Generation path is plain `String` respond.** AnyLanguageModel’s
   `respond(to:schema:)` currently discards the schema and targets
   `GeneratedContent` (placeholder schema), which can break cloud
   `response_format`. We therefore always call `respond(to:options:)` for
   `String` and put the full JSON Schema in the prompt via `PromptBuilder`.
   `SchemaBridge` (`ExtractionSchema` → `GenerationSchema`) remains for a
   future bridge once ALM passes the schema through correctly.
4. **No `isAvailable` pre-check on generate.** Lazy backends (MLX) report
   `.notLoaded` until the first successful `respond`; pre-checking would
   permanently block them. Permanent unavailability (Apple FM off) is handled
   at `ExtractionSession.default` resolution and by errors from `respond`.
5. **Temperature**: `ExtractionOptions.temperature` is `Double?` (`nil` by
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

That mapping now exists (`SchemaBridge.toDynamicGenerationSchema`), and it has been
tried end to end. It did not land — see *Guided (constrained) JSON generation* under
measured negatives for what blocks it and what a repeat attempt should know.

## Measured negatives (things we tried and did not ship)

Recording these so they are not retried blind.

### Tuning `@Guide` wording to fix seller-vs-buyer confusion — no effect

On German letter layouts the letterhead and the address window interleave in the
extracted text, and the model can return the addressee where the seller was asked
for. We A/B-tested three `@Guide` phrasings for the seller field — the existing one
plus two candidates naming the seller as the issuing party / letterhead and
explicitly excluding the recipient — over 76 Factur-X invoices with embedded EN16931
ground truth, Qwen2.5 7B 4-bit via MLX, `temperature = 0`, everything else held.

Result: **the returned seller string was identical across all three arms on every
file.** Wording moved nothing. One candidate also cost 2.7 pp on `invoice_number`,
so it would have been a net loss. Nothing shipped.

Inspecting the three remaining seller misses individually mattered more than the
aggregate:

| Case | What actually happened |
| --- | --- |
| Both party names printed | Model returned the buyer — a genuine confusion |
| Ground-truth seller absent from the page | Model returned the printed letterhead; the XML names a company the document never prints, so this was never a model error |
| Hallucinated a supplier name | Returned a name not present in the source at all — the kind of thing `ExtractionResult.signals` flags as `absent` |

So measured seller accuracy is ~97% rather than the 96% the raw score suggested, and
the residue is not a prompt-wording problem.

### Guided (constrained) JSON generation — the engine is not ready, the question is still open

Read the conclusion precisely: **AnyLanguageModel 0.8.0's constrained JSON generator
is unusable for extraction.** That is *not* the same as "constrained decoding hurts
extraction" — we never managed to measure the technique at all, and writing it off
would close a promising direction on a false basis.

AnyLanguageModel does implement token-level constrained JSON
(`ConstrainedJSONGenerator` + a per-backend `TokenBackend`, wired into MLX, Core ML
and llama.cpp). It is unreachable for us: `LanguageModelSession.respond(to:schema:)`
accepts a `GenerationSchema` and then discards it, forwarding to `GeneratedContent`,
whose static schema is a placeholder string node. Our schemas are built at runtime,
so no static `Generable` type can carry them. We patched the clone to pass a runtime
schema through, then measured on 30 Factur-X documents (arithmetic invariant off on
both arms, identical prompts, equal token budgets, `temperature = 0`).

Four measurements, four artifacts — none of them a property of constrained decoding:

| Reading | What it turned out to be |
| --- | --- |
| −41.4 pp | Optional properties were included by a **hash of the field name** mod 2 — constant per field across every document |
| −44.3 pp | Array length came from `totalTokenBudget / divisor`; the model could not choose how many line items to emit |
| −83.8 pp (7B guided **0.0%**) | With no required properties, `{}` is schema-valid; 7B at temperature 0 took it every time, in two tokens |
| −67.2 pp | The decimal point was excluded from the number mask (Qwen encodes `473.00` as `4` `7` `3` `.` `0` `0`), so amounts padded to `4.73e+31`; and the `null`-vs-string branch collapses strings |

Each artifact had a **fingerprint**, and the fingerprints are the transferable part:

- A field at exactly **−100 pp across all documents** means it is never emitted —
  a schema/engine decision, not a model weakness. Predicting parity from the field
  names in advance correctly called which fields would collapse (`currency`,
  `taxTotal`, `issueDate`) and which would survive (`invoiceNumber`, `grandTotal`).
- **The guided arm running faster than the unconstrained one** (68 s vs 115 s over
  30 files, where the same pair was 2.5× slower on the smaller model) means it is
  terminating early, not decoding carefully.
- **Numbers working while strings collapse** (`grandTotal` −13 pp against
  `invoiceNumber`/`issueDate`/`sellerName` all ≈ −95 pp) points at branch selection,
  not at capability — a model that reads 87% of grand totals correctly is not
  "preferring null" for the invoice number.

Two process notes worth keeping. The 7B run was added only as a guard against a
small-model artifact — the precedent being table injection, which was −11.4 pp on
1.5B and +0.8 pp on 7B — and it is what exposed the `{}` collapse; a single model
would have produced a coherent and entirely false story. And one fix we specified
ourselves (allow `}` once required properties are satisfied) is what *made* the
empty object legal: the previous code was wrong, and its wrongness had been hiding
the hole.

Four of the five defects are fixed, with tests, in
`Tools/EvalHarness/experiments/anylanguagemodel-runtime-schema-constrained-generation.patch`
on the `experiment/guided-generation` branch — intended for upstream, since they
reproduce outside our scenario. The fifth (the `null`-vs-string branch bias) is
diagnosed but unfixed. Also worth knowing before any repeat attempt: ~85% of a
corpus run's wall clock goes to `NaiveStreamingDetokenizer`, which re-decodes the
whole token array each step — quadratic in output length, and enough on its own to
make a full-corpus run on a local model impractical.

Revisit when upstream takes the fixes or the generator matures. The design question
worth carrying over: **optional-in-Swift is not optional-in-JSON for constrained
decoding.** The shape that works is the one strict structured-output modes converged
on — every key required to appear, absence expressed as `null` — so the model can
neither skip everything nor be forced to invent a value.

### Stopping the repair loop at a byte-identical fixed point — never fires

Measured that repair retries driven by the arithmetic invariant cost 47% wall clock
(116s → 171s on 30 Factur-X documents, Qwen2.5-7B-4bit, `temperature = 0`) while
producing **identical field scores** to the invariant-off run. The inference was that
the model reaches a fixed point: told the line items do not sum to the total, it
re-emits the same numbers. So we implemented the provable version — if a repair
attempt reproduces the previous attempt's raw output verbatim, and temperature is 0,
the next prompt would be identical and further attempts cannot differ, so stop.

It never fires. On the same 30 documents, **zero files got faster** (169s → 167s, noise).

The inference was wrong, and the mistake is worth naming: identical *field scores* are
not identical *raw output*. The model varies formatting, ordering, and fields that no
metric scores, while the scored values land the same. A byte-identical fixed point does
not occur, so a rule predicated on one is dead code.

Not shipped, because the costs were real where the benefit was not: a source-breaking
fourth associated value on `ExtractionError.validationFailed` (payload-binding switches
stop compiling), a changed repair prompt, and tests to maintain.

Comparing *decoded values* instead of raw text would fire — but that is a heuristic, not
a proof: the prompt genuinely differs between those attempts, so the model could answer
differently next time. This project spends its effort removing arbitrary decision rules,
not adding them.

The transferable conclusion: **the repair loop cannot fix arithmetic.** The model
re-derives the same numbers from the same document because it does not consider them
wrong. The lever is not stopping more cleverly — it is not asking the model to do
arithmetic. That is what `InvariantPolicy.reportViolations` provides, and why line items
reconstructed from detected table geometry are the more promising direction.

### General caution on this corpus

Several synthetic ZUGFeRD/Factur-X samples disagree with their own visual layer: a
1997 invoice prints `Währung DEM` while its XML says `EUR`; credit notes typed
EN16931 code 381 carry positive amounts in the XML against negatives on the page.
A document-reading library that follows the page is *correct* in those cases, so
ground-truth mismatches cap measurable accuracy and should be reported separately
rather than chased as defects.

## Streaming partials (`Extract.stream`)

### Why `Partial` is a separate generated type

`Extractable` gains `associatedtype Partial: Decodable & Sendable = Self`. The
default keeps hand-written conformances (string enums, custom schemas) compiling
without changes — the protocol doc has always allowed those.

The `@Extractable` macro synthesizes a nested `Partial` struct where every stored
property is optional, nested extractables use *their* `Partial`, and arrays become
arrays of the element partial. That shape is what UI code needs: “not yet known”
is `nil`, which collides with neither a decoded value nor JSON `null` once the
token is complete.

Using `Self` with all-optional decoding, or a single shared “partial JSON
dictionary”, would either break required-field types mid-stream or force callers
into untyped maps. A generated sibling type is the smallest addition that keeps
the non-streaming path byte-stable and the streaming path fully typed.

### Why half-tokens are withheld

A partial snapshot must never show a value that a later snapshot contradicts
*within the same token*. While the model is still writing `473.00`, surfacing
`47` puts a wrong total on screen — worse than an empty field. The assembler
(`CompletedTokenJSON`) therefore emits a scalar only when its JSON token is
provably complete: closing quote for strings, a delimiter (`,`, `}`, `]`, or
whitespace) after a number, full keyword for `true`/`false`/`null`. Nested
objects used as property values or array elements surface only when closed;
arrays themselves may grow element by element as each element completes.

This is a deliberate trade of latency for truthfulness. Do not “optimise” it by
streaming half-tokens.

### Generation seam and honesty over cleverness

`ExtractionGenerating` has a streaming counterpart with a default implementation
that calls `generate` once and yields — so `MockLanguageModel` and every existing
test conformance keep working. The real `LanguageModelBackend` path uses
AnyLanguageModel’s `LanguageModelSession.streamResponse`.

Repair retries stream partials from the **first** attempt only; retries are
one-shot and the stream still ends with `.final` (or throws). Chunked documents
emit no `.partial` updates: per-chunk snapshots are incoherent before the
deterministic merge. Signals, provenance, grounding, and tables attach to
`.final` only — a partial is a preview, not an evidenced result.

## Invariant policy (`InvariantPolicy`)

0.4.0 documented the cost of `validateInvariants()`: on single-pass runs the
sum-equals-total check took correct grand totals from 96.0% to 61.3%, with 24
outright failures where there had been none, because a correct total dies when
the line items come back messy. The check was doing its job. The missing piece
was a way for the caller to say "give me the value, tell me what did not add
up, I will decide."

### What we shipped

`ExtractionOptions.invariantPolicy` is `.strict` by default — repair, then throw
`ExtractionError.validationFailed`. Byte-identical to today. `.reportViolations`
keeps the same retry budget and, when it is exhausted, returns the last
successfully decoded value with the existing `InvariantIssue` list on
`ExtractionResult.invariantViolations`. Decode failures still throw: there is
no value to hand back. A later repair attempt that fails to decode does not
discard an earlier decoded-but-invalid value.

Violations reuse `InvariantIssue` / `InvariantValidationError` rather than a
new type. Field-level repair (re-asking the model for only the failing fields)
is out of scope; this change is measurable on its own.

### Why `Extract.from` still throws

`Extract.from` returns a bare `T`. Under `.reportViolations` that value can have
failed its invariants, and the convenience path has nowhere to say so. Two
options were acceptable: keep `from` throwing, or rewrite the headline
guarantee so the opt-in is in the sentence.

We kept `from` throwing. The guarantee in `Extractable.swift` and the README
then stays true for every value that API can produce, and `detailed` / `stream`
are the surfaces that can carry `invariantViolations`. Silently weakening the
promise — returning a broken `T` from `from` — is the option that was not
acceptable.

`Extract.stream` matches `detailed`: under `.reportViolations` the terminal
`.final` carries the result with the issues listed; under `.strict` the stream
throws. A partial is still a preview and is not invariant-checked.

### Harness

The existing `invariant=` key is a three-way, not a second switch:

| Value | Arithmetic check | Library policy |
| --- | --- | --- |
| `true` (default) | on | `.strict` |
| `false` | off | n/a |
| `report` | on | `.reportViolations` |

An A/B of `invariant=true` vs `invariant=report` measures the gate against a
scored extract on the same documents. `true`/`false` labels are unchanged so
historical reports stay comparable.

## Line items from geometry (`LineItemSource`)

Line items are the weakest field on every measurement we have run. The repair
loop cannot fix arithmetic — the model re-derives the same numbers because it
does not consider them wrong. The rows already exist on `ExtractionResult.tables`.
Asking the model to transcribe them is the one job it is worst at.

### What we shipped

`ExtractionOptions.lineItemSource` is `.model` by default. Prompts and results
are byte-identical to today. `.geometry` is opt-in:

1. Prefer `ExtractedTable.isLineItemShaped` (rows ≥ 3, columns 3–6, density ≥
   0.80 — the same numbers the harness already used). When none match, any
   dense 2×2+ grid is offered so a two-item invoice is not dropped.
2. One mapping call: header + sample rows of every candidate. The model
   chooses the table and maps columns onto the **first** array-of-objects in
   the schema. Later collections stay on the model path.
3. Every data row is parsed with `LenientDecoding` (German commas, trailing
   minus, currency). Totals / tax / subtotal rows are skipped by exact token.
4. Header fields are extracted with the collection omitted from the prompt
   schema, then the geometry-built array is spliced in before decode.

An unusable mapping (named column out of range, omitted required field, no
usable rows) **falls back** to the model path. The fallback is visible:
`ExtractionResult.collectionSource` is `.geometryFallback(reason:)`, never
silent `.model`. A measurement that cannot tell those two apart is comparing
the model path to itself — a mistake this project has already made once.

Provenance is not a special case. Geometry-built values are ordinary leaves;
`FieldGrounding` already prefers table-cell boxes, so those fields get tighter
rects than the model path.

### Harness

`lineItemSource=model|geometry` on a compare arm (aliases `line-item-source`,
`lineItems`). The accuracy report always prints how many scored files used
geometry versus fell back. An A/B that cannot show that split is not a
geometry measurement.
