# Eval harness experiments

## AnyLanguageModel runtime-schema patch

`anylanguagemodel-runtime-schema-constrained-generation.patch` is the standalone
diff against AnyLanguageModel **0.8.0**
(`163f3855a53235b4ebeb69cf5e9f228215ae35b5`).

It adds a schema-taking entry point on `LanguageModel` (default = today’s
unconstrained `GeneratedContent` path) and overrides it on `MLXLanguageModel` so
a **runtime** `GenerationSchema` reaches `ConstrainedJSONGenerator`.
`LanguageModelSession.respond(to:schema:)` forwards the schema instead of
dropping it.

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
