# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.2] — 2026-09-09

Fixes the deadlock listed as a known issue in 0.7.1.

### Fixed

- **Concurrent extraction no longer deadlocks.** PDFKit rasterisation and
  `VNImageRequestHandler.perform` are synchronous, and the ingest path called them straight
  from `async` code. That parks a cooperative-pool thread for the whole operation, and the
  pool holds about one thread per core — so enough concurrent extractions park every thread
  and nothing is left to run the work that would release them. Measured on a 15-core
  machine: 8 concurrent OCR extractions finished in 1.3s, **16 never finished**.

  Moving the blocking section off the pool exposed a second limit: Vision dispatches
  synchronously onto its own capacity-limited queue (`VNControlledCapacityTasksQueue`) and
  oversubscribing that wedges just as hard — **64 hung**. Blocking ingest work now runs on
  a queue bounded to `activeProcessorCount`. That bound is not a tuning constant picked by
  feel: OCR is CPU-bound, so more in-flight requests than cores buys no throughput and only
  starves Vision. 64 and 256 concurrent extractions now finish in 7.8s and 30.7s.

  A lock around PDFKit and a lock around Vision were both tried first and neither helps —
  they move where the blocking happens without taking it off the cooperative pool.

  CI is back to plain `swift test`: the `--no-parallel` stopgap from 0.7.1 is no longer
  needed, and the full suite now completes in parallel in 6.9s. Before this it hung forever,
  which is why the 0.7.0 Build & Test job was cancelled on timeout and that release went out
  unverified.


## [0.7.1] — 2026-09-09

Rasterised PDF pages were mirrored. **Do not use 0.7.0 (or 0.6.0) for scanned PDFs.**

### Fixed

- **Rasterised PDF pages are no longer mirrored.** `PDFKitRenderer` translated by the
  bitmap height and negated y before drawing — the recipe for a flipped UIKit/AppKit
  context. A `CGBitmapContext` and PDF user space are both y-up and `makeImage()` already
  accounts for row order, so the transform mirrored every page. Vision read a probe page
  back as `380Я9 ИОІТАТИЗІЯО` instead of `ORIENTATION PROBE`.

  The same flip was in `OCRAdapter` as far back as 0.6.0, so **every OCR'd PDF page has
  been mirrored for two releases** — anything that fell back to OCR (scans, garbled text
  layers) returned garbage. The typed and dynamic extraction paths on documents with a
  clean text layer were unaffected.

  The suite stayed green because the mixed-PDF fixture mirrored its own scanned page
  before writing it into the PDF: two mirrors cancelled, so the assertion passed on
  synthetic input while real scans came out backwards. The fixture now draws straight, and
  `RasterOrientationTests` renders a known line, runs Vision, and asserts both the text and
  where the line sits — the three existing rasteriser tests assert only pixel dimensions,
  which a flip and a mirror both preserve.

### Known issues

- **Concurrent extraction of PDFs that need OCR can deadlock.** The ingest path calls
  Vision synchronously from `async` code, so parallel callers block Swift's cooperative
  thread pool and exhaust Vision's capacity-limited internal queue. CI now runs
  `swift test --no-parallel` for the same reason; the 0.7.0 Build & Test job was cancelled
  on timeout, which is why that release went out unverified. Locks on PDFKit and on Vision
  do not help — the blocking is on the cooperative pool itself. The fix needs an async seam
  for the non-`Sendable` `CGImage` / `PDFPage` work and is the next piece of work.


## [0.7.0] — 2026-09-08

Runtime schemas, and PDF ingest that does not trust a bad text layer.

The typed `@Extractable` path is unchanged. Callers that only have a field list at
run time pass an `ExtractionSchema` and get `JSONValue`. PDF pages with a garbled
OCR text layer are re-read at 300 DPI with `/Rotate` and scan orientation applied.
OCR and PDF rasterisation sit behind protocols so a later Linux build can inject
other engines without forking the loop.

### Added

- **Dynamic schema API.** `Extract.from` / `detailed` / `stream` now accept a runtime
  `ExtractionSchema` and return `JSONValue` instead of a compile-time `@Extractable`
  type. Lenient coercion (decimals, dates, bools, enums) walks the schema with the
  same parsers the macro uses. Optional `invariants: (JSONValue) throws -> Void`
  is the dynamic equivalent of `validateInvariants()`. Grounding still runs against
  that schema. Existing typed `Extract.from<T: Extractable>` is unchanged.

- **PDF ingest quality and orientation.** Per-page text-layer quality gate
  (`TextLayerPolicy.auto`, threshold 0.85) OCRs garbled layers instead of trusting
  character count. Rasterisation honours `/Rotate`, defaults to 300 DPI (cap 400),
  and auto-orients scans (0°/90° axis score, 180° from character x-order).
  Configure via `ExtractionOptions.textLayerPolicy`, `rasterDPI`, `autoOrient`.

- **Ingest engine protocols.** `OCRRecognizing` (default `VisionOCR`) and
  `PDFRendering` (default `PDFKitRenderer`) are public. Pass them through
  `IngestContext` on `Extract.from` / `detailed` / `stream` / `inspect`. No new
  engines yet — this is the injection seam for tests and later Tesseract/PDFium.

## [0.6.0] — 2026-08-24

Stop throwing away extractions that were good enough.

One opt-in feature and one recorded failure. The feature lets a caller keep a decoded
value whose cross-field invariants could not be reconciled, with the violations listed
instead of an exception — measured to recover **9 of 23** documents on the Factur-X
corpus. The failure is an optimisation proposed on the strength of that measurement,
implemented, measured, and dropped because it never fires.

### Added

- **Opt-in invariant policy (`InvariantPolicy`).** `validateInvariants()` still couples the fields
  it names — that is the point of the check — but the caller can now say what should happen when
  retries cannot reconcile them. Default `ExtractionOptions.invariantPolicy` is `.strict`: repair,
  then throw `ExtractionError.validationFailed`. Same value, same error, same attempt count as
  0.5.0. Opt into `.reportViolations` and `Extract.detailed` / `Extract.stream` return the last
  decoded value with the remaining `InvariantIssue`s on `ExtractionResult.invariantViolations`
  (the existing field-addressable type; not a parallel representation). The repair loop still
  runs the same number of attempts; only exhaustion changes.

  `Extract.from` still throws under either policy. It returns a bare `T` with nowhere to attach
  the issues, and handing one back silently would make the documented guarantee — *if you received
  a value, those invariants held* — a lie. The doc comment, README, and `DECISIONS.md` spell that
  out.

  Harness: the existing `invariant=` key grows a third value rather than a second switch.
  `true` / `false` keep their meaning; `invariant=report` turns the check on and uses
  `.reportViolations`, so an A/B can compare the gate against a scored extract on the same
  documents.

### Documented

- **Stopping the repair loop at a byte-identical fixed point — never fires.** The
  invariant measurement showed repair retries costing 47% wall clock (116s → 171s on 30
  Factur-X documents, Qwen2.5-7B-4bit, `temperature = 0`) while producing *identical field
  scores* to the invariant-off run. The inference: the model reaches a fixed point, since
  told the line items do not sum to the total it re-emits the same numbers. So the provable
  version was implemented — if an attempt reproduces the previous attempt's raw output at
  temperature 0, the next prompt would be identical and a deterministic model cannot
  differ.

  On the same 30 documents, **zero files got faster** (169s → 167s, noise). The inference
  was wrong: identical *field scores* are not identical *raw output*. The model varies
  formatting, ordering, and fields no metric scores while the scored values land the same,
  so a byte-identical fixed point never occurs.

  Not shipped. The costs were real where the benefit was not — a source-breaking fourth
  associated value on `ExtractionError.validationFailed`, a changed repair prompt, and
  eleven tests. Comparing *decoded values* instead would fire, but that is a heuristic
  rather than a proof, and this project spends its effort removing arbitrary decision rules.
  The transferable conclusion is that **the repair loop cannot fix arithmetic** — the lever
  is not stopping more cleverly, it is not asking the model to do arithmetic at all. Details
  in `DECISIONS.md`.

## [0.5.0] — 2026-08-10

Streaming partial results, and two changes to how this project reports its own numbers.

The feature is `Extract.stream`. The theme underneath it is the same one as 0.4.0 — say
what is actually known, and when. A partial result withholds half-written values; the
accuracy report stops hiding extractions that failed outright; and a direction we
investigated at length is recorded as a negative about the *engine* rather than about the
idea, because those are not the same claim.

### Added

- **Streaming partials for `@Extractable` (`Extract.stream`).** One
  `AsyncThrowingStream<ExtractionUpdate<T>, Error>` whose terminal element is `.final`
  carrying the same `ExtractionResult<T>` that `detailed` returns, so a caller never needs
  a second call.

  ```swift
  for try await update in Extract.stream(from: pdfURL, as: Receipt.self, using: session) {
      switch update {
      case .partial(let p):   // Receipt.Partial — every field optional
      case .final(let r):     // ExtractionResult<Receipt>
      }
  }
  ```

  **A partial never shows a value that a later snapshot contradicts within the same
  token.** While the model is writing `473.00`, the caller does not see `47` — a wrong
  total on screen is worse than an empty field. A scalar surfaces only once its JSON token
  is provably complete: closing quote for strings, a delimiter after a number, the full
  keyword for `true`/`false`/`null`. This trades latency for truthfulness on purpose.
  Pinned as a table so the boundary is visible in one place:

  | Buffer | Snapshot |
  | --- | --- |
  | `{"total":473` | `{}` |
  | `{"total":473.00` | `{}` |
  | `{"total":473.00}` | `{"total":473.00}` |
  | `{"name":"Ada","total":47` | `{"name":"Ada"}` |
  | `{"lineItems":[{"sku":"A","qty":1` | `{"lineItems":[]}` |
  | `{"lineItems":[{"sku":"A","qty":1}` | `{"lineItems":[{"sku":"A","qty":1}]}` |

  Arrays grow element by element as each element completes.

  Limits, stated rather than papered over: **chunked documents emit no `.partial`**, only
  `.final`, because per-chunk snapshots are incoherent before the deterministic merge;
  **signals, provenance, grounding and tables attach to `.final` only** — a partial is a
  UI preview, not an evidenced result; and **repair retries are not streamed** — partials
  come from the first attempt, and the stream still ends with `.final` or throws exactly
  as `detailed` does.

  Additive throughout: `Extractable` gains `associatedtype Partial: Decodable & Sendable =
  Self`, so hand-written conformances keep compiling, and the macro generates a real
  `Partial` (nested extractables use *their* `Partial`, arrays become arrays of the element
  partial). The package-internal generation seam gains a streaming method whose default
  implementation calls the existing one once, so `MockLanguageModel` and every existing
  test conformance are untouched.

- **Hard extraction failures are visible in harness accuracy.** A failed extraction used to
  contribute *nothing* to the denominator — so a run where every file failed printed
  `0.0% (0/0)`, which reads as "very low accuracy" but means "nothing was scored at all",
  and a run where half the files failed silently reported the accuracy of the survivors.
  Both mislead in the same direction. Hard failures are now counted, shown as a share, and
  listed with their errors, and a **failure-inclusive accuracy** scores every
  ground-truth-bearing field on a failed file as incorrect.

  The existing `overallAccuracy` / `presentAccuracy` keep their definition, because the
  numbers published for 0.3.0 and 0.4.0 were computed with it and silently changing what
  those names mean would make this project's own history incomparable. Every row in the
  report now states which definition it uses. In compare reports, a field the baseline got
  right and the other arm never produced was previously an invisible Δ 0; it is now a
  visible −1.

- **Run-level switch for the harness arithmetic invariant** (`invariant=true|false` on a
  compare arm, `--invariant` on the accuracy path; default unchanged). The
  sum-equals-total check rejects nearly every extraction from a small model — measured on
  Factur-X, 6 of 6 files ended in `validationFailed` and the report scored nothing — which
  makes an A/B measure the gate instead of the extractor. The mode is always printed in the
  report label.

- **Per-file progress on stderr during harness runs** (`[arm i/n] path (elapsed s)`).
  Model-backed runs print nothing until the end, which makes a slow run indistinguishable
  from a hung one; one corpus run here was left going for seven hours before that became
  clear. Reports stay metrics-only — progress never goes into them.

### Documented

- **Guided (constrained) JSON generation, recorded as a measured negative about the
  engine.** AnyLanguageModel 0.8.0 does implement token-level constrained JSON, but
  `respond(to:schema:)` discards a runtime schema, so it is unreachable for schemas built
  at runtime. We patched around that and measured on 30 Factur-X documents. Four readings
  — −41.4, −44.3, −83.8 (7B guided at **0.0%**) and −67.2 pp — were each an artifact of a
  distinct defect in the generator, not a property of constrained decoding: optional
  properties chosen by a hash of the field *name*; array length derived from the token
  budget; `{}` being schema-valid when nothing is required; and the decimal point missing
  from the number mask, so `473.00` became `4.73e+31`.

  So the honest statement is that **the engine is not usable for extraction**, and the
  original question — whether constrained decoding helps a small model — is still
  unanswered. Recording the stronger-sounding claim would close a promising direction on a
  false basis. `DECISIONS.md` keeps the fingerprints that separated artifact from result,
  since those transfer: a field at exactly −100 pp across all documents is never being
  emitted; a guided arm running *faster* than the unconstrained one is terminating early;
  numbers working while strings collapse points at branch selection, not capability. Four
  of the five defects are fixed with tests in `Tools/EvalHarness/experiments/`, intended
  for upstream.

## [0.4.0] — 2026-08-08

Measurement, provenance, and a merge that no longer asks a model to do arithmetic.

The theme is verifiability. The evaluation harness moves into the repository, so the
numbers in these notes can be reproduced rather than trusted. Per-field provenance says
*where* on the page each value came from, so a human can check a result instead of
re-reading the document. And chunked extraction merges deterministically.

Two design rules of mine were measured and thrown out along the way, and the most
useful finding is about a feature shipped in 0.2.0 — see the invariant note under
**Changed**. Where something did not improve, it says so.

### Changed

- **Deterministic chunk merge (no LLM merge pass).** Multi-chunk runs still extract each
  partial with the model, then merge raw JSON trees structurally: objects key-wise;
  arrays concatenate, drop entries whose text is unsupported by the full document
  (verbatim/normalized match or ≥50% significant-token coverage), then equality de-dupe
  (string trim + structural equality — not soft description match); scalars take the
  sole / agreeing value. Disagreeing scalars are arbitrated by **grounding rank against
  the full document** (`verbatim` > `normalized` > ungrounded) — same source text as
  public field signals. Only equal ranks keep the first occurrence and record a
  ``MergeConflict`` on ``ExtractionSignals/mergeConflicts`` (path + competing compact
  JSON values; no confidence score). Short 1–2 digit integers are treated as ungrounded
  for this ranking only (they match free text too freely); distinctive numerics need
  ≥3 digits or a decimal separator. Root `null` / non-object partials contribute nothing
  instead of failing the run. The lenient decoder, invariant check, and repair loop still
  run once on the merged tree (repair uses the full document). Table-to-chunk assignment
  uses **cell-text containment** (drops the page-index broadcast and the “attach all
  tables to chunk 0” fallback). Hard-splits prefer line boundaries, then whitespace,
  within a window so tokens are not cut mid-word when avoidable. Docs:
  [API](docs/API.md#chunk-merge-deterministic), README limitations.

  Measured on 75 Factur-X invoices, Qwen2.5 7B 4-bit, `temperature = 0`, chunking forced
  with a 400-character budget:

  | | single pass | LLM merge | deterministic |
  | --- | ---: | ---: | ---: |
  | invoice number | 98.7% | 26.5% | **97.3%** |
  | issue date | 93.2% | 32.8% | **91.8%** |
  | grand total | 96.0% | 45.6% | 18.9% |
  | duplicate line descriptions | 2 | 25 | **14** |
  | hard failures | 0 | 7 | **0** |

  Stated plainly because it is the part that matters: **chunking costs real accuracy and
  no merge rule recovers it.** Totals collapse because no single chunk holds both the line
  items and the totals block, and a merge can only choose among what the partials produced.
  Two rules were measured and discarded on the way here — "keep the first occurrence" is
  deterministic but reliably wrong, since totals print at the end and the first chunk's
  guess wins; grounding as arbiter fails too, because the dominant error is a wrong number
  that genuinely appears in the document (a line amount used as a total). Avoid chunking
  when the document fits.

- **Documented what an invariant costs.** `validateInvariants()` couples the fields it
  names, so the least reliable one decides the fate of all of them — and the README only
  told the flattering half of that ("if you got a value, the invariants held"). Measured
  with the documented sum-equals-total check on the same 75 invoices: on **chunked** runs
  it roughly doubles correct totals (18.9% → 38.7%), because the total is what goes wrong
  there. On **single-pass** runs it makes matters worse in absolute terms — grand total
  96.0% → 61.3%, with 24 outright failures where there had been none — because a correct
  total is discarded whenever the line items come back messy. The check is behaving
  exactly as designed; the cost is that a usable extract dies with it. No behaviour change,
  only honest documentation: couple fields of comparable reliability, expect extra
  attempts, and decide deliberately whether a partial answer beats no answer.

### Added

- **Per-field provenance** on `FieldSignal.provenance` (`FieldProvenance`: page index +
  bounding box). Extends the existing grounding row so each leaf answers both *was it
  found* and *where* — no parallel array to zip. Geometry is resolved per positioned
  block (and prefers a reconstructed **table-cell** rect when the value matches a cell).
  Multi-block values on one page use the axis-aligned **union**; cross-page values report
  the **first page only** (a single `CGRect` cannot span pages). `reformatted` / `absent`
  leaves and sources without boxes carry `nil` provenance rather than a guess. Coordinate
  convention (PDF text layer and Vision OCR): **top-left origin, y down, normalised
  `0…1`, per page** — documented on `FieldProvenance` and in [API](docs/API.md). Debug
  PNGs (test / harness helpers only, not public library API) can overlay boxes on
  `fixtures/invoice.pdf` and `fixtures/receipt.png`. Docs: README trust section,
  [API signals](docs/API.md#extraction-signals-grounding).

- **Evaluation harness** (`Tools/EvalHarness/`). Separate SPM package (not linked
  from the root package) that path-depends on `Extract` so library consumers never
  pull measurement code into their graph. Modes: **survey** (ingest timing, char
  counts, OCR fallback, table shape/density, line-item-shaped share), **accuracy**
  (Factur-X / ZUGFeRD EN16931 CII ground truth via `mutool extract`, pairing guard,
  overall + present-in-text field accuracy), **A/B compare** (named configs only),
  and **anchors** (named documents with required properties — the defence against
  aggregate metrics improving while tables fragment). Default backend is the
  deterministic mock; MLX is opt-in via package trait and fails loudly rather than
  falling back to mock. Corpus path from `--corpus` / `EXTRACT_EVAL_CORPUS` (never
  committed); reports are metrics-only unless `--include-content`. Seed anchors
  cover `fixtures/invoice.pdf` and `fixtures/receipt.png`; corpus anchors skip
  cleanly when the corpus is absent. Public `Extract.inspect` + `DocumentInspection`
  expose ingestion metrics and geometric tables without a model call (minimal
  surface for the harness). CI runs survey + accuracy over `fixtures/` with mock
  and anchors. See [`Tools/EvalHarness/README.md`](Tools/EvalHarness/README.md).

## [0.3.0] — 2026-07-30

Structural tables: documents are no longer flattened before the model sees them.
Everything here was tuned against a 314-file corpus of real invoices and then
measured for accuracy against 76 Factur-X documents with embedded EN16931 ground
truth, rather than against intuition. Two of those measurements changed the design
and one stopped a change from shipping — details inline.

### Fixed

- **Trailing-minus accounting notation in `LenientDecoding.parseDecimal`.** SAP /
  German invoice amounts print the sign after the digits (`"1,12 -"`, `"12-"`), and
  a real corpus document does exactly that. Those forms now decode as negatives
  (−1.12, −12) instead of being rejected. Optional whitespace before the sign is
  allowed; a trailing `+` is accepted as an explicit positive. Two-sign forms
  (`-12-`, `12--`, `+12-`, parenthesised-plus-trailing) stay rejected, as do the
  existing multi-dot / multi-sign / junk-exponent hardenings, pinned as a table so
  the boundary is visible in one place. Parenthesised negatives and the scientific
  path are unchanged.

### Added

- **Structural tables surface to the model and callers (stage 2).** Detected tables
  from geometric reconstruction are returned on `ExtractionResult.tables` and may be
  appended to the extraction prompt as a labelled Markdown section (linear document
  text is left unchanged — additive, not a substitute). When no tables are found or
  `tableDetection` is `.off`, the prompt is byte-identical to the pre-feature shape.
  Chunked runs assign whole tables by page (never a half table); if page filtering
  would drop every table, the full set is attached to the first chunk. Docs:
  [API](docs/API.md), [Examples](docs/Examples.md), [README limitations](README.md).

### Changed

- **Schema-gated table prompt injection under `.automatic`.** Always appending
  detected tables to the prompt hurt header-field accuracy on types without
  collections (measured −11.4 pp header accuracy on 76 invoices) while helping
  line-item structure when the schema has arrays. `.automatic` still runs geometric
  detection and always exposes grids on `result.tables`; the prompt section is
  included only when the target `extractionSchema` contains a collection (array)
  anywhere, including nested. Header-only types get a prompt byte-identical to
  `.off`. No new enum case; callers who need grids without line items still use
  `result.tables`.

  Measured on 76 Factur-X invoices with embedded EN16931 ground truth, same local
  MLX model per run, `temperature = 0`, tables `.automatic` vs `.off`:

  | | Qwen2.5 1.5B 4-bit | Qwen2.5 7B 4-bit |
  | --- | ---: | ---: |
  | header accuracy, tables off | 62.7% | 95.2% |
  | header accuracy, tables on | 51.3% | 95.8% |
  | Δ on the files where tables were injected | **−11.4 pp** | **+0.8 pp** |
  | Δ line description | −1.0 pp | **+7.1 pp** |

  So the distraction is a **small-model artefact, not a property of the approach**:
  at 7B the table section no longer costs header accuracy and clearly helps line
  descriptions. Schema gating is kept because it is exactly right for weak models
  and for header-only schemas, and costs a strong model nothing. On header-only
  types the two arms produced **byte-identical extractions on all 76 documents** —
  only the reported `tables` count differs, which is the intended behaviour.
- **Table detection precision against real invoices.** `TableDetector` now splits
  multi-column regions on large vertical gaps (line items vs totals), bridges short
  single-column description lines under items, keeps only “spine” rows (numeric /
  header-like) when clustering columns, drops sparse and all-empty columns, and
  requires fill density ≥ 0.55 before emission. On a 314-file invoice corpus this
  raised median density from ~0.71 to 1.0, cut `pdf/` average tables/file from 3.4
  to 1.8, and eliminated all-empty columns, while preserving line-item recall on
  Coolblue, Sammy Maystone, `fixtures/invoice.pdf`, and `fixtures/receipt.png`.
  Unit tests cover a Coolblue-style merged-region layout and an empty-column case.
- **Recursive XY-cut (horizontal column bands).** Before row grouping, the detector
  splits a page on a vertical whitespace corridor — the largest mid-X gap between
  blocks — when the gap is ≥ 0.06, ≥ 1.25× each band’s internal mid-X structure,
  both bands have ≥ 2 multi-column rows, and their Y-ranges overlap (≥ 25% of the
  shorter band). Each band then runs the existing vertical region split. This
  recovers side-by-side documents that previously merged into one sparse mega-grid
  (or density-rejected to zero), e.g. `hard/invoice_table_detect_img1.jpg`, without
  bisecting single-document line-item tables (Coolblue, Sammy). Unit test covers two
  independent 3-column grids separated by a wide corridor.
- **XY-cut corridor vs table-gutter discrimination.** Width alone cannot tell a
  vertical region boundary from a table’s inter-column gutter, so pure XY-cut
  shattered genuine line-item grids (e.g. Kostenrechnung `4×6` → six half-width
  fragments; Hetzner `8×4` → `8×2`/`4×2`/`11×2`). A candidate corridor is now kept
  only when multi-column row baselines across the gap largely fail to align: the cut
  is refused when the shorter multi-col side’s mid-Y match is ≥ 0.80 (strong
  co-tabular signal, even if one side has extra chrome rows) or when both directed
  matches are ≥ 0.50 (balanced shared grid). Side-by-side documents with unrelated
  line positions still split (`hard/invoice_table_detect_img1.jpg` → `4×4` + `6×5`).
  On the 90-file `pdf/` set, line-item-shaped grids (rows ≥ 3, cols 3–6, density
  ≥ 0.80) recover to 36/90 (40%) from 32/90 under pure XY-cut, matching the
  pre-horizontal-cut tightening rate, while median density stays 1.0, p90 columns
  5, and `pdf/` avg tables/file 1.79. Unit test pins a dense 6-column grid staying
  one table against two misaligned 3-column grids staying two.

## [0.2.0] — 2026-07-29

Everything in this release was reviewed twice by an independent model and attacked
by property-based and adversarial tests before tagging. That process found a
process-killing trap, a hang, several silent numeric coercions, and two guarantees
the documentation stated but the code did not keep — none of which the
example-based suite or ThreadSanitizer had caught. Details under **Fixed**.

### Added

- **Cross-field invariants wired into the repair loop.** Callers override
  `Extractable.validateInvariants()` (default no-op — existing types and macro
  conformances compile unchanged) and throw `InvariantValidationError` with
  field-addressable `InvariantIssue`s. Violations are formatted like decode errors,
  retried on both the single-chunk and chunk-merge paths, and surface as
  `ExtractionError.validationFailed` after retries are exhausted. Money comparisons
  use `Extract.isApproximatelyEqual(_:to:tolerance:)` with an explicit default of
  `Extract.defaultMoneyTolerance` (`0.01`) so legitimate receipt rounding does not
  thrash the model. Docs:
  [API](docs/API.md#cross-field-invariants),
  [Examples](docs/Examples.md#9-cross-field-invariants-repair-loop).
- **ICAO 9303 MRZ parser** (`MRZParser`) for TD1 / TD2 / TD3, verifying every check
  digit including the composite. A failed digit does **not** throw: the structure
  still parses and per-field results come back in `MRZCheckResult`, because a
  document with one bad digit is worth surfacing and those flags are the trust
  signal. `findAndParse(in:)` locates an MRZ inside a page of OCR text.
  `MRZResult.crossCheck(against:)` compares MRZ fields with values from any other
  source, keyed by a typed `MRZField`; the caller supplies the mapping, so the
  library stays domain-agnostic. For these fields the result is arithmetic rather
  than model inference. Docs: [Examples](docs/Examples.md).
- **Per-field grounding signals** (`ExtractionResult.signals`). For each leaf,
  whether that value was found in the source text — `verbatim`, `normalized`,
  `reformatted` or `absent` — plus `attempts` and `chunksUsed`. Deliberately **not**
  a confidence score: nothing behind it is calibrated, and a single number invites
  auto-accept thresholding. Known and documented limit: `absent` only fires for
  string leaves, because small integers (`quantity: 2`) match spuriously against
  arbitrary text — cross-field invariants, not grounding, are what catch a
  confidently wrong number. Docs: [API](docs/API.md).
- **Identity-document recognition as a first-class product path.**
  - Published example schema [`Examples/schemas/IdentityDocument.swift`](Examples/schemas/IdentityDocument.swift) with field `@Guide`s for document type, full name, document number, date of birth, expiry/issue dates, nationality, issuing authority, optional sex/gender and address.
  - Synthetic offline fixture [`fixtures/identity_document.txt`](fixtures/identity_document.txt) (no real PII).
  - CLI support: `--type IdentityDocument` / `--schema Examples/schemas/IdentityDocument.swift` with deterministic `--mock` defaults.
  - Cookbook recipe and privacy guidance in [`docs/Examples.md`](docs/Examples.md); README links the ID path as a primary use case.
  - Offline unit tests driving shipped `Extract.from` + `ExtractionSession.mock` for the identity schema.

### Fixed

- **Pre-release review hardenings (numeric parsing, invariants, MRZ, signals):**
  - Scientific decimals bound the exponent to the defensible `Decimal` range
    (`±127`), reject non-finite results, and never trap on `Int.min` negation or
    hang on unbounded multiplications (`1e1000000000`).
  - Scientific mantissas normalise locale-aware separators (so `1,5e3` under
    `de_DE` is `1500`, not `15000`) and validate the original token instead of
    deleting interior characters (`1eUSD3` is rejected).
  - Parenthesised scientific values that already carry a minus (`(-1e3)`) stay
    negative instead of double-negating to a positive amount.
  - Same-separator grouping+decimal forms (`1.234.56`, `1,234,56`) are rejected;
    no locale uses one mark for both roles.
  - Public `Extractable.decodeExtracted(from:)` now runs `validateInvariants()`
    so the documented "value implies invariants held" guarantee is true on every
    decode path, not only the extraction loop. The extraction loop uses an
    internal decode-only entry point and validates once, so each returned value
    is checked exactly once on every path.
  - MRZ expiry century resolution keeps both bounds of the documented
    `[ref−50, ref+50]` window (raw `99…` under a 2026 reference → 1999, not 2099).
  - MRZ cross-check / date parsing validates calendar components for bare
    `yyyy-MM-dd` **and** full ISO timestamps so impossible days like
    `2012-04-31` / `2012-04-31T00:00:00Z` cannot agree via
    `ISO8601DateFormatter` rollover.
  - `MRZParser.findAndParse` prefers checksum-valid candidates over earlier
    MRZ-alphabet noise, and windows any run longer than the target format so a
    two-line TD3 after a noise line inside a three-line run is still found.
  - Grounding signals emit an explicit `reformatted` row for nil optional fields
    (macro `encodeIfPresent` drops the key), keep numeric signs in both raw
    substring and skeleton matching so opposite-sign amounts are not labelled
    `verbatim`/`normalized`, and cache source normalisation once per `compute`
    call (was O(N×M) per leaf).
  - Money approximate-equality lives on `Extract` (`isApproximatelyEqual` +
    `defaultMoneyTolerance`) rather than as a public `Decimal` extension, avoiding
    Foundation-type surface collisions with helpers such as swift-numerics.
- ReceiptScanner's Xcode project now bundles its sample fixtures. XcodeGen has no `resources:` target key, so that block in `project.yml` was silently ignored and every "Try a sample" tap failed with *"Fixture … is missing from the app bundle."* The fixtures are declared under `sources:` with `buildPhase: resources` instead.

### Testing

- 106 tests, clean under ThreadSanitizer, ~80% line coverage on `Sources/Extract`.
  Beyond example-based tests: fuzzed lenient decoders against a fixed-seed adversarial
  corpus; MRZ property tests that generate structurally valid TD1/TD2/TD3 with an
  independent check-digit oracle, round-trip them, then assert single-character
  mutations never come back all-clear; a corpus of malformed model responses (fences,
  prose, truncation, duplicate keys, null-for-required, sci-notation, RTL, multi-MB
  blobs) asserting every input ends in a correct value or a thrown error; 64 concurrent
  extractions including a shared session; and one regression test per review finding.

### Documentation

- README opens with a **"general-purpose extractor, not a receipt scanner"** section: the document-agnostic pipeline, a table of use cases (receipts, invoices, identity documents, email, forms, tickets, contracts), and the privacy/scope caveats for ID handling.
- Documented **multilingual document support** (Unicode text, Vision multi-script OCR including Chinese and Arabic, multilingual LLMs) with locale guidance and English-first prompt caveats.
- Added [`docs/demo.gif`](docs/demo.gif) — the ReceiptScanner flow running a real on-device MLX extraction (Qwen2.5 1.5B, 4-bit) — replacing the README placeholder.

### Notes

- MRZ check digits **are** verified as of this release, and cross-field invariants are
  enforced. Neither makes this a KYC or identity-verification product: there is still
  no NFC/chip ePassport reading, no biometrics, no forgery or liveness detection, and
  no certification. Check digits catch transcription and OCR errors; invariants catch
  internally inconsistent documents. Everything outside those two is typed OCR + LLM
  field extraction, and should be treated as model output that needs review.
- Install product remains **`Extract`** (SPM); license remains **Apache-2.0**.
