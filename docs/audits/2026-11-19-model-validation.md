# Model validation: qwen3.5:9b and qwen3.6:35b

**Date:** 2026-11-19, 22:58–23:10 CET (UTC+1).
**Repository state:** HEAD `61e8dcc` ("Canvi a qwen3.5:9b i qwen3.6:35b"), in sync with `origin/master`.

**Labels used:**

| Label | Meaning |
|---|---|
| **FACT** | Observed in this run. The source is given. |
| **OBSERVATION** | A judgment about quality, not a measurement. |
| **ASSUMPTION** | Believed but not verified. |

**Scope.** The test exercises the new model assignment with one task, "Create a specification for a simple CLI that converts CSV to JSON". The developer used a tiny task on the same theme.

**What was not done:**

- No tracked file was changed.
- Phase 0 was not implemented.
- `test-all.ps1 -IncludeLive` was not run.

**Side effects:**

- **Telemetry records.** Three records were appended to `logs/model-calls.jsonl` and `logs/model-calls.csv`. Both are git-ignored.
- **Generated specs.** `specify.ps1` wrote two files that `.gitignore` does not cover, listed in the "Generated files" section below.

## 1. Environment

| Item | Value | Source |
|---|---|---|
| Ollama | 0.40.13, server running | FACT: `ollama --version`, `ollama ps` |
| Installed models | `qwen3.6:35b` (22 GB), `qwen3.5:9b` (6.6 GB), `deepseek-r1:32b` (19 GB), `qwen2.5-coder:7b` (4.7 GB), `qwen2.5-coder:32b` (19 GB) | FACT: `ollama list` |
| GPU | NVIDIA RTX 5070 Ti Laptop, 12,227 MiB VRAM | FACT: `nvidia-smi`, measured earlier the same evening |
| `AI_HARNESS_MODEL` | not set | FACT |

**Effective `.ai/config.json`** (FACT: file content at HEAD; no local changes):

| Key | Value |
|---|---|
| `defaultModel` | `qwen3.5:9b` |
| `agentModels.spec` | `qwen3.5:9b` |
| `agentModels.spec-reviewer` | `qwen3.6:35b` |
| `agentModels.spec-reviser` | `qwen3.5:9b` |
| `agentModels.developer` | `qwen3.6:35b` |
| `options` | `temperature 0.2`, `num_ctx 16384` |
| `timeoutSec` | `900` |
| `stripThinking` | `true` |

**Old models still installed:** `deepseek-r1:32b`, `qwen2.5-coder:32b`, `qwen2.5-coder:7b`.

- The live suite `scripts/test-spec-integration.ps1` still defaults to `qwen2.5-coder:32b`, and `scripts/test-all.ps1:111` checks that this model is installed. These are defects D-04 and D-06.
- Because the old model is still installed, `test-all.ps1 -IncludeLive` would run and pass its precondition, but it would test the **old** model, not the new configuration. It was therefore not run.

## 2. Per-agent results

**Method:**

- Wall-clock time was measured around the call.
- Token counts and durations come from `logs/model-calls.jsonl`.
- Tokens per second are computed from the raw counts: `eval_count / (eval_duration_ns / 1e9)`. The CSV's tokens-per-second columns are not used.
- The GPU share comes from `ollama ps`, sampled every 5 s in a second shell.

| Agent (how it was run) | Model | Wall-clock | Model load | Processor (`ollama ps`) | Context | Output tok/s | `eval_count` | `prompt_eval_count` | Prompt tok/s |
|---|---|---|---|---|---|---|---|---|---|
| spec (`run-agent.ps1`, cold start) | qwen3.5:9b | 53 s | 27.0 s | **100% GPU** (6.1 GB) | 16384 | **63.9** | 796 | 5,383 | 509.6 |
| spec (`specify.ps1`, step 1) | qwen3.5:9b | ~24 s | 13.9 s | 100% GPU | 16384 | 63.2 | 429 | 5,400 | — |
| developer (`run-agent.ps1`) | qwen3.6:35b | 104.9 s | 52.2 s | **58% CPU / 42% GPU** (22 GB) | 16384 | **45.5** | 1,239 | 2,957 | 129.3 |
| spec-reviewer (`specify.ps1`) | qwen3.6:35b | ~81 s, including a model switch | not recorded | 58% CPU / 42% GPU | 16384 | **not recorded (D-02)** | — | — | — |
| spec-reviser | qwen3.5:9b | **not exercised** (0 revisions) | — | — | — | — | — | — | — |

**Notes:**

- **Speed of `qwen3.6:35b`.** It generates at 45.5 tok/s even though 58% of it runs on the CPU. That is about 18 times faster than the old 32b models measured on this machine (2.4–2.6 tok/s). ASSUMPTION: it is a mixture-of-experts model, with only part of the weights active per token.
- **Context.** Both models load with the configured 16,384-token context. The prompts (about 5,400 tokens for spec, about 3,000 for developer) fit with a large margin.
- **One model at a time.** Only one model was loaded at any moment (FACT: `ollama ps` samples). Every switch between `spec` (9b) and `spec-reviewer` (35b) reloads a model, which costs 14–52 s. The reviewer's 81 s includes such a switch.
- **Sampling gaps.** `ollama ps` returned no rows while a model was loading, so those gaps appear in the samples.

## 3. Thinking behavior

**The models' replies as seen by the harness** (FACT):

- `run-agent.ps1` gets the full reply but keeps only the `response` field. It removes `<think>` blocks only from that field (`stripThinking`).
- The visible outputs contain no `<think>` text.

**Hidden output tokens.** The visible output is much smaller than `eval_count`. These are ASSUMPTION estimates, using characters ÷ 4 for the visible tokens:

| Run | `eval_count` | Visible output | Estimated hidden tokens |
|---|---|---|---|
| spec (`run-agent.ps1`) | 796 | 958 chars, about 240 tokens | about 550 (about 70%) |
| spec (`specify.ps1` step 1) | 429 | 538 chars, about 135 tokens | about 295 (about 70%) |
| developer | 1,239 | 2,838 chars, about 710 tokens | about 530 (about 43%) |

**Direct check against the raw reply.** One request per model went directly to `/api/generate`, with the same task, no system prompt, the same options, and `num_predict 400`. These requests are not in the harness telemetry. Result (FACT):

| Model | `thinking` field | Thinking chars | `<think>` in `response` | `response` chars | `done_reason` | `eval_count` |
|---|---|---|---|---|---|---|
| qwen3.5:9b | present | 1,656 | no | **0** | `length` | 400 |
| qwen3.6:35b | present | 1,678 | no | **0** | `length` | 400 |

**Conclusion** (FACT for this Ollama version and these models):

- Both models think by default.
- Ollama returns the reasoning in a **separate `thinking` field**, not as `<think>` tags.

**Consequences for the harness:**

- **`stripThinking` has no effect** with these models, because there are no tags to strip.
- **The reasoning is discarded unseen:** `run-agent.ps1` and `Invoke-HarnessGenerate` read only `response`.
- **Thinking costs time:** it is counted in `eval_count` and uses generation time, roughly 40–70% of the output tokens in these runs.
- **A request can return an empty answer.** If thinking uses the whole output budget, `response` comes back empty. The two probes show this with a 400-token cap. The harness sets no `num_predict`, so this is unlikely today; it would surface as "Agent returned an empty response".

**Phase 2 candidate** (no code was changed):

- Add a per-agent `think` setting (`false`, or a level), so it can be turned off for agents that don't benefit from reasoning.
- Optionally record the length of the `thinking` text in telemetry.
- Whether turning thinking off lowers quality has **not been tested**.

## 4. End-to-end `specify.ps1` result

**Command:** `scripts\specify.ps1 -Task "Create a specification for a simple CLI that converts CSV to JSON" -Name model-validation-1`. Mode: default (`requirements`).

| Item | Result |
|---|---|
| Exit code | **0** (FACT) |
| Total wall-clock | 107 s (23:06:18 → 23:08:05) |
| Step 1, spec generation (qwen3.5:9b) | 23:06:19 → 23:06:43, about 24 s |
| Step 2, structural validation | under 1 s, `STATUS: PASS` |
| Review iteration 1 (qwen3.6:35b) | 23:06:44 → 23:08:05, about 81 s including the model switch; `Review Status: PASS` |
| Revision iterations | **0**, so the reviser (`qwen3.5:9b`) was not exercised |
| `scripts\validate-spec.ps1` on the final spec, run separately afterwards | `STATUS: PASS`, exit 0 (FACT) |

Stage times come from timestamps on each output line. The reviewer and reviser write no telemetry (known defect D-02), and this run confirmed that no reviewer record was added.

## 5. Quality observations

All of these are OBSERVATIONS, from one sample each.

**Spec from `run-agent.ps1`** (the standalone call):

- **Template:** follows the template (10 headings, `**Source:**` labels, `None` for empty sections).
- **Not minimal.** It adds three items the task doesn't contain, all labelled `USER`:
  - FR-002, an input-path argument
  - FR-003, an output-path argument
  - AC-002, a non-zero exit code for invalid input

  They should have been `ASSUMPTION`s or open questions.
- **No open questions.** `Open Questions` is `None`, despite real ambiguities: header row, output destination (file or stdout), encoding.

**Spec from `specify.ps1`:**

- **Minimal:** 1 FR and 1 AC.
- **One unflagged assumption.** "produces a JSON file as output" assumes the output is a file, but it is labelled `USER`. It is a minor point.
- **No open questions:** `Open Questions` is `None` again.

**Same model, different scope.** The two spec outputs used the same model and task, at temperature 0.2, and differ clearly in scope (3 FR / 2 AC versus 1 FR / 1 AC). The `specify.ps1` prompt adds a `SPECIFICATION MODE (AUTHORITATIVE): requirements` header, so whether the difference comes from that header or from sampling variation cannot be told from one pair.

**Reviewer:**

- **Coherent:** it produced a PASS with a valid `## Status` and the expected sections, and its reasoning matches the spec it reviewed.
- **Possibly lenient.** It reported no findings and did not mention the missing open questions or the output-is-a-file assumption.
- **Not tested on a bad spec.** This run tells nothing about whether the reviewer rejects a spec that should FAIL, because no such spec was reviewed.

**Developer:**

- **Good quality.** It returned the expected sections, and the script uses only the standard library (`argparse`, `csv`, `json`): input from a file or stdin, output to a file or stdout.
- **Honest about limits.** It lists assumptions, risks and open questions that make sense, and marks its suggested checks "NOT EXECUTED".
- **No invented requirements** beyond reasonable defaults, which it declared as assumptions.

## 6. Problems found

1. **Thinking output is ignored and costs time** (section 3). `stripThinking` doesn't work with the separate `thinking` field. This is a FACT.
2. **Models switch at every stage.** `spec` and `spec-reviser` (9b) alternate with `spec-reviewer` (35b), and only one model is loaded at a time. Each switch costs 14–52 s, so a workflow with revisions pays a reload at every stage. FACT for the observed swaps; how much it adds up to over revisions is an ASSUMPTION.
3. **No reviewer or reviser telemetry (D-02).** The reviewer's speed and token counts on `qwen3.6:35b` are unknown. FACT.
4. **The live tests still name the old model** (D-04/D-06). Because that model is still installed, a `-IncludeLive` run would test the wrong model without any error. FACT.
5. **Spec quality** (OBSERVATION): invented requirements labelled `USER` in one of the two spec outputs, open questions never used, and the reviewer didn't catch either.
6. **Untested:** the reviser model, documentation mode, a spec the reviewer should reject, and `think: false`.

## 7. Recommendation per agent

| Agent | Model | Recommendation |
|---|---|---|
| spec | qwen3.5:9b | **Keep.** It is fast (about 64 tok/s, entirely on the GPU, 24–53 s per call). It **needs a `think: false` evaluation**: about 70% of its output tokens are hidden thinking. Compare quality with thinking off on the same task. Watch minimality and source labels, which are prompt issues, not speed issues. |
| spec-reviewer | qwen3.6:35b | **Keep provisionally.** It isn't too slow (about 81 s including a model switch), and the PASS it gave was coherent. Its strictness is **not established**. Before relying on it, run `review-spec.ps1` on `tests/fixtures/semantic-invalid-spec.md` (it should FAIL), after D-06 is fixed or with `-Model qwen3.6:35b` given explicitly. Thinking is probably useful for a reviewer, so don't turn it off without a comparison. |
| spec-reviser | qwen3.5:9b | **Not validated.** It was not exercised (0 revisions). There is no reason to change it yet; validate it with a run that gets a FAIL. Using the same model as `spec` avoids a model switch between those two stages. |
| developer | qwen3.6:35b | **Keep.** Good output quality, 45.5 tok/s even with 58% on the CPU, and about 105 s per call including a 52 s cold load. `think: false` is an optional speed-up (about 43% of its tokens were hidden). |

**General:**

- **Timeout.** `timeoutSec 900` now leaves a lot of headroom at these speeds. The timeout question (O-01) is much less urgent than with the old models.
- **Old models.** Consider removing the old models only after D-04/D-06 are fixed, so live tests can't silently use them. That is a human decision.

## Generated files

`specify.ps1` created these. They are **not** covered by `.gitignore` (FACT: `git check-ignore` exit 1), so they were **left in place**:

- `specs/model-validation-1.md` (538 bytes)
- `specs/model-validation-1.review.md` (1,157 bytes)

## Final `git status --short`

Recorded when this report was written:

```text
?? docs/audits/
?? specs/model-validation-1.md
?? specs/model-validation-1.review.md
```
