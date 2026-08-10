# Eval harness experiments

## AnyLanguageModel runtime-schema patch

`anylanguagemodel-runtime-schema-constrained-generation.patch` is the standalone
diff against AnyLanguageModel **0.8.0**
(`163f3855a53235b4ebeb69cf5e9f228215ae35b5`).

It is intended as the seed for a PR to
[huggingface/AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel).

### What it does

1. **Runtime-schema entry point** — adds
   `LanguageModel.respond(within:to:schema:…)` (default = today’s unconstrained
   `GeneratedContent` path) and overrides it on `MLXLanguageModel` so a
   **runtime** `GenerationSchema` reaches `ConstrainedJSONGenerator`.
   `LanguageModelSession.respond(to:schema:)` forwards the schema instead of
   dropping it. Also exposes `supportsSchemaConstrainedGeneration`.

2. **Model-driven optional properties** — `ConstrainedJSONGenerator.generateObject`
   used to pre-filter optional keys with a hash of the field name XOR the token
   budget (`shouldIncludeOptionalProperty`). With a fixed budget that made each
   optional either always present or always absent across every document — a
   measurement confound that looks like “guided generation dropped currency.”

   The generator now keeps a set of not-yet-emitted keys and, at each step,
   **masks tokens** so the model may open any remaining property (`"key":` /
   `,"key":`) or, once every **required** key has been emitted, close the object
   with `}`. Optional inclusion is therefore a function of the model’s next-token
   distribution under the JSON grammar, not of the field name.

   A token-budget floor remains as a **last resort only**: when
   `remainingTokens` drops to `max(8, total/10)` and all required keys are
   present, further optionals are no longer offered and the object is closed.
   That path surfaces as
   `ConstrainedGenerationError.optionalPropertiesOmittedDueToTokenBudget`
   (recovered to valid JSON by `generate()`, with omitted key names in the
   error for observability). It does **not** fire while budget is plentiful.

3. **Model-driven array length** — `generateArray` used to pick a fixed element
   count from the token budget (`totalTokenBudget / 32`, clamped) or, when both
   `minItems` and `maxItems` were set, `minItems + totalTokenBudget % rangeSize`.
   That forced the **same** array length for every document (filler when short,
   truncation when long) — the same family of confound as the name-hash bug, and
   the dominant one for invoice line items (12 of 18 scored fields).

   Length is now model-driven under the JSON grammar: after each element the
   mask permits both continuing (`,`) and closing (`]`), subject to schema
   `minItems` / `maxItems`. Empty arrays (`minItems == 0`) are chosen by a
   non-committing probe among `]` and item-start tokens. Budget pressure may
   force an early close only once `minItems` is satisfied; that path surfaces as
   `ConstrainedGenerationError.arrayTruncatedDueToTokenBudget` (recovered to
   valid JSON by `generate()`, with `emittedCount` in the error).

4. **Free-string termination** — already model-driven: after the first content
   token, `stringContinuationAllowedTokens` includes the closing quote, so the
   model may end a free string at any step. `maxFreeStringTokens` is only a
   per-string cap (and budget a hard stop), not a fixed run-out length. Probe
   garbage like concatenated dates/amounts is the model declining to emit `"`
   until the cap forces a close — not a missing terminator in the mask.

5. **Shared response-token default (MLX)** — plain generation used to pass
   `options.maximumResponseTokens` through as `nil` (MLX = unlimited until EOS)
   while structured generation hard-coded `?? 512`. Both paths now resolve
   through the same default when the option is nil so a guided-vs-plain A/B
   isolates the decoding strategy.

   **Capping the plain path is a measurement-parity behaviour change, not a
   shipping default.** Value **1024** (was 512) is sized from Qwen2.5-1.5B
   tokenizer counts of ideal `EvalInvoice` JSON built from Factur-X ground truth
   under `invoice-mather/examples/pdf` (4 Factur-X files with line items):

   | shape | min | p50 | max (tokens) |
   | --- | ---: | ---: | ---: |
   | compact GT JSON | 117 | 158 | 234 |
   | pretty GT JSON | 166 | 233 | 335 |
   | pretty, padded to 10 lines | 452 | 479 | 494 |
   | verbose 10-line + markdown fence (plain-path proxy) | 587 | 614 | 629 |

   **512 clips** the 10-line proxy (margin −117). **1024** clears max fenced
   verbose-10 with ~400 tokens of headroom (~1.5× the 1.5×-headroom target of
   ~943). Keep in lockstep with
   `ExtractionSession.defaultMaximumResponseTokens`.

### `deterministicChoice` (judgement)

Nearby `deterministicChoice(from:)` returns `""` if present, else the longest
candidate. It is **only** on the `generateChoice` path for string enums, and
only when an empty candidate is present or one candidate’s token sequence is a
prefix of another (the sampler cannot commit without lookahead). It is **not**
used for object-key selection, array length, or the `anyOf` path (`anyOf` still
picks the first variant — a pre-existing limitation, left alone here because it
is a different defect class). Leaving the fallback is correct: it is a rare
tokenizer edge case, not a systematic pre-pass over schema structure.

### Apply locally (not committed)

```bash
# Clone pin outside the repo, apply patch, wire both package graphs:
CLONE=/path/to/AnyLanguageModel
git clone https://github.com/huggingface/AnyLanguageModel.git "$CLONE"
cd "$CLONE" && git checkout 163f3855a53235b4ebeb69cf5e9f228215ae35b5
git apply /path/to/swift-extraction-lib/Tools/EvalHarness/experiments/anylanguagemodel-runtime-schema-constrained-generation.patch

cd /path/to/swift-extraction-lib
swift package edit AnyLanguageModel --path "$CLONE"
cd Tools/EvalHarness && swift package edit AnyLanguageModel --path "$CLONE"
```

Do **not** commit `Packages/` symlinks, the clone, or build artifacts.

### Library-side budget parity

`Sources/Extract/ExtractionSession.swift` sets
`GenerationOptions.maximumResponseTokens = ExtractionSession.defaultMaximumResponseTokens`
(**1024**) for **both** guided and plain arms, matching the MLX shared default.
Real callers of `ExtractionSession` therefore get a comparable budget on both
paths without depending on backend-specific nil handling. See the comment on
that constant: plain-path capping is for A/B parity, not a product default.
