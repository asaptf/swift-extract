# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
