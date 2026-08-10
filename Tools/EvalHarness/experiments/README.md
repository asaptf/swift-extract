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

2. **Required keys + null for absence (OpenAI strict shape)** — optional
   extraction fields used to map to `isOptional: true` on
   `DynamicGenerationSchema.Property`. With every `EvalInvoice` field optional,
   `generateObject` offered `}` on the first key step; Qwen2.5-7B at temperature
   0 took it every time (`{}` in two tokens → 0% accuracy).

   Industry practice (OpenAI strict structured output): **every property key is
   required**; absence is a `null` value, not key omission. The patch:

   - Adds `GenerationSchema.Node.null` / `DynamicGenerationSchema` null scalar
     so nullable values are expressible.
   - `generateAnyOf` samples between `null` and non-null variant starts when
     `anyOf [T, null]` is used (non-committing for non-null, same family as the
     empty-array probe).
   - Library `SchemaBridge` marks **all** properties required and wraps
     extraction-optional fields as `anyOf [T, null]`.

   **Prompt parity:** `PromptBuilder` still embeds
   `ExtractionSchema.renderJSONSchema()` with the original `required` list.
   Only the guided `GenerationSchema` changes. Decoding still accepts a missing
   key as `nil`.

3. **Model-driven optional properties (historical)** — before the strict-null
   change, `generateObject` kept not-yet-emitted keys and masked tokens so the
   model could open any remaining property or close once every **required** key
   was present. That path remains for schemas that still mark keys optional; the
   Extract bridge no longer produces all-optional objects.

   A token-budget floor remains as a **last resort only**: when
   `remainingTokens` drops to `max(8, total/10)` and all required keys are
   present, further optionals are no longer offered and the object is closed
   (`optionalPropertiesOmittedDueToTokenBudget`).

4. **Model-driven array length** — after each element the mask permits both
   continuing (`,`) and closing (`]`), subject to `minItems` / `maxItems`. Empty
   arrays are chosen by a non-committing probe among `]` and item-start tokens.
   Budget pressure may force an early close only once `minItems` is satisfied
   (`arrayTruncatedDueToTokenBudget`).

5. **Number termination (decimal point + digit budgets)** — diagnosis on
   Qwen2.5 tokenizers:

   | finding | detail |
   | --- | --- |
   | Structural terminators | `,` `}` `]` `:` are single tokens (ids 11, 92, 60, 25) and were already in the mask |
   | Digit+delimiter merges | **none** in the Qwen2.5 vocab |
   | Root cause | `buildValidDecimalTokens` required every token to contain a digit, which **excluded standalone `.` and `-`**. Qwen encodes `473.00` as `4` `7` `3` `.` `0` `0`, so the model could not emit a decimal point; after integer digits it padded zeros until `maxDecimalTokenLimit` (32) → values re-serialized as `e+31` |
   | Whitespace | ` ` / `\n` / `\t` are single tokens and are now number terminators (pretty-print end) |

   Fix: include standalone `.` / `-` (ASCII digits only; no fullwidth/`²`),
   number FSM for valid prefixes, whitespace terminators, fractional digit cap
   (6) and integer digit cap (12) so zero-padding cannot run to the token cap,
   and reject pathological unbounded magnitudes (`≥ 1e15` or `> 16` digits).

6. **Free-string termination** — already model-driven: after the first content
   token, `stringContinuationAllowedTokens` includes the closing quote.

7. **Shared response-token default (MLX)** — plain and structured paths resolve
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
   verbose-10 with ~400 tokens of headroom. Keep in lockstep with
   `ExtractionSession.defaultMaximumResponseTokens`.

### `deterministicChoice` (judgement)

Nearby `deterministicChoice(from:)` returns `""` if present, else the longest
candidate. It is **only** on the `generateChoice` path for string enums, and
only when an empty candidate is present or one candidate’s token sequence is a
prefix of another. It is **not** used for object-key selection, array length,
nullable `anyOf`, or multi non-null `anyOf` (multi non-null still picks the
first variant — a pre-existing limitation). Leaving the fallback is correct: it
is a rare tokenizer edge case, not a systematic pre-pass over schema structure.

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

### Library-side SchemaBridge (required + null)

`Sources/Extract/SchemaBridge.swift` converts optional extraction properties to
required keys with `anyOf [value, null]` on the guided path only. The JSON
Schema string in prompts is unchanged.
