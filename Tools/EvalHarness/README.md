# Evaluation harness (`extract-eval`)

Repeatable measurement for swift-extract: ingestion survey, Factur-X accuracy,
A/B config comparison, and **named anchors** that refuse to let aggregate metrics
paper over broken tables.

This is a **separate SPM package**. It path-depends on the root library and is
**not** a product of the root package — `swift build` at the repo root will not
compile it, and library consumers never see it in their dependency graph.

## Why anchors exist

Aggregate metrics (density, column counts, “no empty column”) can all improve
while the output gets worse. Splitting real line-item tables into fragments did
exactly that. Only named documents with required properties (and the
line-item-shaped recall metric) caught it. Treat anchor failures as release
blockers even when averages look better.

## Quick start (fixtures, mock, CI-shaped)

From the **repo root** (or this directory):

```bash
cd Tools/EvalHarness
swift build
swift run extract-eval --mode survey \
  --repo-root ../.. \
  --fixtures ../../fixtures \
  --backend mock \
  --output /tmp/eval-survey

swift run extract-eval --mode accuracy \
  --repo-root ../.. \
  --fixtures ../../fixtures \
  --backend mock \
  --output /tmp/eval-accuracy
```

Exit code `1` means at least one **non-skipped** anchor failed. Exit code `0`
means every evaluated anchor passed (corpus-only anchors may still be skipped).

## Corpus setup

The real invoice corpus is **never committed**.

```bash
export EXTRACT_EVAL_CORPUS=/path/to/invoice-corpus
# or:
swift run extract-eval --mode survey --corpus /path/to/invoice-corpus ...
```

Supported files: PDF, common images, `.txt` / `.md`. Nested directories are
walked; order is sorted for deterministic JSONL.

Fixtures under `fixtures/` are enough for smoke runs and CI.

## Modes

| Mode | Model? | What it measures |
| --- | --- | --- |
| `survey` | No | Per-file ingest timing, char counts, OCR fallback, table shapes + fill density, line-item-shaped share |
| `accuracy` | Yes | Field accuracy vs embedded Factur-X / ZUGFeRD EN16931 CII ground truth |
| `compare` | Yes | Two named configs; per-field Δ pp and the list of files that changed |
| `anchors` | No (inspect only) | Named pass/fail checks |

### Ground truth & pairing

For each PDF, the harness extracts the embedded CII XML with **`mutool extract`**
(falls back to `pdfdetach` if needed), then parses invoice number, issue date,
currency, seller, grand total, tax total, and line items.

**Pairing guard:** a distinctive ground-truth value (prefer invoice number) must
appear in the library-extracted text. Otherwise the file is counted as
*unpaired* and **not scored** — so a mis-attached XML cannot inflate accuracy.

### Present-in-text accuracy

Overall accuracy scores every field with a non-nil truth value. **Present-in-text**
accuracy only includes fields whose truth value actually appears in the extracted
text. Profiles like ZUGFeRD MINIMUM carry XML values that are never printed;
scoring those as misses understates the pipeline.

### Line-item-shaped share

Share of successfully ingested files that yield at least one table with:

- rows ≥ 3  
- columns 3–6  
- fill density ≥ 0.80  

This is the metric that exposed pure XY-cut fragmentation (36/90 on the pdf/
slice after the corridor discriminator).

## Provenance overlays (debug)

`ProvenanceOverlayRenderer` draws `FieldSignal.provenance` rectangles on a page
raster and writes a PNG. It is **harness-only** — the Extract library returns
geometry and does not render images.

Root `swift test` also writes smoke overlays for the two ingestion paths to:

```
Tools/EvalHarness/eval-out/provenance/invoice-pdf-text-layer.png
Tools/EvalHarness/eval-out/provenance/receipt-vision-ocr.png
```

Open those after a test run to verify PDF text-layer and Vision OCR boxes agree
on the documented top-left normalised convention.

## Backends

| Backend | Default | Notes |
| --- | --- | --- |
| `mock` | **yes** | Deterministic; runs anywhere including CI |
| `mlx` | no | Local Apple Silicon; requires MLX trait + Metal build |

**If a backend cannot initialise, the harness fails loudly.** It never silently
falls back to mock — mock accuracy numbers look precise and mean nothing.

### MLX / xcodebuild

MLX is **not** a silent requirement of the default build.

1. Enable the package trait and direct `mlx-swift-lm` dependency (already declared
   in this package’s `Package.swift`).
2. Build with the trait:

   ```bash
   swift build --traits MLX
   ```

3. Prefer **`xcodebuild`** for a working MLX binary so Metal shaders compile:

   ```bash
   # Example: generate an Xcode project or open Package.swift in Xcode,
   # enable the MLX trait on the EvalHarness scheme, then:
   xcodebuild -scheme extract-eval -destination 'platform=macOS' build
   ```

4. Run:

   ```bash
   swift run extract-eval --mode accuracy --backend mlx \
     --model mlx-community/Qwen2.5-1.5B-Instruct-4bit \
     --corpus "$EXTRACT_EVAL_CORPUS" --output /tmp/eval-mlx
   ```

If you pass `--backend mlx` on a binary built without the trait, the process
exits with an error instead of measuring mock accuracy under a false label.

## Privacy

Reports are **metrics only** by default (JSONL + Markdown under `--output`).

- No document body text  
- No table cell contents  

Pass **`--include-content`** only when you intentionally need cells/text in the
report (real corpora contain private invoices).

## Anchors

Seed file: `Sources/EvalHarness/Resources/anchors.json` (bundled with the package).

Fixture anchors (always evaluated):

- `fixtures/invoice.pdf` — table must contain Widget Pro / Support Plan  
- `fixtures/receipt.png` — table must contain Latte / Croissant  

Corpus anchors (`requiresCorpus: true`) are **skipped with a clear message** when
the corpus is absent or the path token does not match any file:

- coolblue, sammy, `invoice_table_detect_img1`, kostenrechnung (XY-cut shatter guard)

### Adding an anchor

```json
{
  "id": "my-vendor-line-items",
  "path": "fixtures/my.pdf",
  "requiresCorpus": false,
  "note": "Why this must not regress",
  "checks": [
    { "type": "tableContainsCells", "values": ["Item A", "Item B"] },
    { "type": "minTableCount", "count": 1 },
    { "type": "hasLineItemShapedTable" },
    { "type": "textContains", "values": ["Seller GmbH"] },
    { "type": "exactTableCount", "count": 2 }
  ]
}
```

| Check | Meaning |
| --- | --- |
| `tableContainsCells` | Some table’s cells contain all listed strings (case-insensitive) |
| `minTableCount` / `exactTableCount` | Table count bounds |
| `hasLineItemShapedTable` | ≥1 line-item-shaped grid (see above) |
| `textContains` | Extracted document text contains all strings |
| `sellerEquals` | Text contains the expected seller string (inspect-only; no model) |

Corpus anchors: set `"requiresCorpus": true` and put a path token in `"path"`
(substring match against corpus file paths).

Custom file:

```bash
swift run extract-eval --mode anchors --anchors ./my-anchors.json --repo-root ../..
```

## A/B comparison

Only named configuration fields may differ: backend, model id, table detection,
temperature / retries. Nothing else varies silently.

```bash
swift run extract-eval --mode compare \
  --corpus "$EXTRACT_EVAL_CORPUS" \
  --config-a off:backend=mlx,tableDetection=off,model=mlx-community/Qwen2.5-7B-Instruct-4bit \
  --config-b auto:backend=mlx,tableDetection=automatic,model=mlx-community/Qwen2.5-7B-Instruct-4bit \
  --output /tmp/eval-ab
```

## Output

Under `--output` (default `eval-out`):

| File | Contents |
| --- | --- |
| `survey.jsonl` / `survey.md` | Per-file ingest metrics |
| `accuracy.jsonl` / `accuracy.md` | Per-file field scores + aggregates |
| `compare.jsonl` / `compare.md` | Deltas and changed files |
| `anchors.jsonl` / `anchors.md` | Anchor pass/fail/skip |

JSONL is deterministic for the same inputs so two runs diff cleanly.

## Library surface used

The harness uses public `Extract` APIs only, plus one small inspection API added
for measurement without a model:

- `Extract.inspect(_:tableDetection:)` → `DocumentInspection`  
  (text metrics, OCR-fallback flag, geometric tables)

No private package imports. Root `swift build` / `swift test` stay independent.

## CLI reference

```
extract-eval --mode survey|accuracy|compare|anchors
  --corpus <path> | EXTRACT_EVAL_CORPUS
  --fixtures <path>          # default: <repo>/fixtures
  --repo-root <path>
  --backend mock|mlx         # default mock
  --model <id>
  --table-detection automatic|off
  --anchors <file.json>
  --no-anchors
  --config-a name:backend=…,tableDetection=…
  --config-b name:backend=…,tableDetection=…
  --output <dir>
  --include-content          # privacy opt-in
```
