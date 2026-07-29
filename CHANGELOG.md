# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Structural tables surface to the model and callers (stage 2).** Detected tables
  from geometric reconstruction are appended to the extraction prompt as a labelled
  Markdown section (linear document text is left unchanged — additive, not a
  substitute) and returned on `ExtractionResult.tables`. When no tables are found or
  `tableDetection` is `.off`, the prompt is byte-identical to the pre-feature shape.
  Chunked runs assign whole tables by page (never a half table); if page filtering
  would drop every table, the full set is attached to the first chunk. Docs:
  [API](docs/API.md), [Examples](docs/Examples.md), [README limitations](README.md).

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
