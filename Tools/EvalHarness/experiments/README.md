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

3. **Shared response-token default (MLX)** — plain generation used to pass
   `options.maximumResponseTokens` through as `nil` (MLX = unlimited until EOS)
   while structured generation hard-coded `?? 512`. Both paths now resolve
   through the same default (`512` when the option is nil) so a guided-vs-plain
   A/B isolates the decoding strategy.

### `deterministicChoice` (judgement)

Nearby `deterministicChoice(from:)` returns `""` if present, else the longest
candidate. It is **only** on the `generateChoice` path for string enums, and
only when an empty candidate is present or one candidate’s token sequence is a
prefix of another (the sampler cannot commit without lookahead). It is **not**
used for object-key selection and is **not** on the `anyOf` path (`anyOf` still
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
(**512**) for **both** guided and plain arms, matching the MLX shared default.
Real callers of `ExtractionSession` therefore get a comparable budget on both
paths without depending on backend-specific nil handling.
