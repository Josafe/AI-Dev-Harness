# Model validation, round 2: reviewer, reviser, variance, single model, thinking

**Date:** 2026-11-19, 23:11–23:30 CET (UTC+1).
**Repository state:** HEAD `430c01e`. The configuration in use was the committed mixed assignment, except in check D.

**Labels used:**

| Label | Meaning |
|---|---|
| **FACT** | Observed in this run. |
| **OBSERVATION** | A judgment about quality. |
| **INFERENCE** | Consistent with the data, but not confirmed. |

**Sample size.** Every quality statement rests on 1–5 samples at `temperature 0.2`. Treat these results as signals, not benchmarks.

**What was not done:**

- No tracked file was changed.
- Phase 0 was not implemented.
- `test-all.ps1 -IncludeLive` was not run.

**Side effects:**

- **Generated files.** The harness wrote 12 untracked files under `specs/validation2-*` (listed at the end).
- **Telemetry.** Records with run IDs `v2-var-1` to `v2-var-3` and `v2-single-specify` were appended to the git-ignored `logs/`.
- **Probe outputs.** The direct API probes (sections B-diag and E) bypass the harness, so they write no telemetry. Their raw outputs were kept outside the repository; this report contains only their numbers.

Tokens per second are always computed as `eval_count / (eval_duration / 1e9)`.

## Environment

| Item | Value |
|---|---|
| Ollama | 0.40.13, running (FACT) |
| Installed models | `qwen3.6:35b` (22 GB), `qwen3.5:9b` (6.6 GB), plus the old models `deepseek-r1:32b`, `qwen2.5-coder:32b`, `qwen2.5-coder:7b` (FACT: `ollama list`) |
| Committed mixed configuration | `spec` = `qwen3.5:9b`, `spec-reviser` = `qwen3.5:9b`, `spec-reviewer` = `qwen3.6:35b`, `developer` = `qwen3.6:35b`, `defaultModel` = `qwen3.5:9b`, `num_ctx 16384`, `temperature 0.2`, `timeoutSec 900`, `stripThinking true` |
| Single-model configuration (check D) | `AI_HARNESS_MODEL=qwen3.6:35b` set for that process only; `.ai/config.json` unchanged |
| Where each model runs | `qwen3.5:9b`: 100% GPU, 6.1 GB. `qwen3.6:35b`: 58% CPU / 42% GPU, 22 GB. Context 16,384 in both cases. Only one model is loaded at a time (FACT: `ollama ps` sampled every 5 s, 201 samples). |

## A. Can the reviewer reject a bad spec?

**Command:** `review-spec.ps1 -Task "Create a simple user registration feature with email and password" -SpecFile specs\registration-automated-test.md`. The reviewer was `qwen3.6:35b`.

**Result:** **FAIL** (exit 1) in **52.3 s**. The output is in `specs/validation2-A-mixed.review.md`.

**Comparison with the old `deepseek-r1:32b` review's 4 BLOCKING findings:**

| Old BLOCKING finding | New review, run A | New review, rerun in D (same model) |
|---|---|---|
| FR-003, password hashing | **WARNING** only (FINDING-006, "move to technical constraints") | **BLOCKING** |
| NFR-001, performance under 2 seconds | BLOCKING | BLOCKING |
| Edge case, duplicate email | BLOCKING | BLOCKING |
| Dependency, authentication system | **not flagged** | **not flagged** |

**Additional findings, which the old review did not report:**

| Item | Run A | Run D |
|---|---|---|
| AC-001, confirmation message | BLOCKING | BLOCKING |
| AC-003, 8-character minimum password | BLOCKING | BLOCKING |
| AC-002, email-format validation | only in "Unsupported Requirements" | BLOCKING |
| Contradiction between AC-003 and an Open Question | WARNING | — |

**OBSERVATION:**

- The new reviewer rejects this bad spec reliably (2 of 2 runs) and catches more invented acceptance criteria than the old one did.
- In both runs it missed the authentication-system dependency, and it accepted the Context sentence "stored securely … for future use (e.g., authentication)".
- The severity of the same item varies between runs (hashing was a WARNING once and BLOCKING once).

## B. Reviser test (`qwen3.5:9b`)

**Input:** the registration spec plus the review from run A.

| Attempt | How | Time | Result |
|---|---|---|---|
| B1 | `revise-spec.ps1` (harness) | 177.3 s | **Failure:** exit 1, "Reviser returned an empty response" ([revise-spec.ps1:156](../../scripts/revise-spec.ps1#L156)). No file was written, so the validation and the re-review could not run. |
| B-diag default | direct API call, exact reconstructed reviser prompt, default thinking | 11.6 s | `done_reason: stop`. The output **deletes every acceptance criterion**, so the validator fails with "No acceptance criteria found". |
| B-diag `think: false` | the same call with `"think": false` | 4.4 s | The same content as B-diag default, so the same validator **FAIL**. |
| B2 (retry) | `revise-spec.ps1` (harness) | 11.6 s | Exit 0. `validate-spec.ps1`: **PASS**. Re-review: **PASS** in 126.2 s (that time includes reloading the 35b model). |

**What B2 did** (FACT, `specs/validation2-B-revised.md`):

- **Removed correctly:** FR-003, NFR-001, all three original acceptance criteria, the edge cases (including the duplicate-email one), the dependency, and "stored securely … authentication" from Context.
- **Kept:** FR-001 and FR-002, which the request supports.
- **Rewrote** AC-001 as "A user account is created when the registration request is processed successfully". That is a reasonable, supported acceptance criterion, though it carries the label `USER`.
- **Nothing valid was lost in B2.**

**Why B1 returned nothing.** INFERENCE, not confirmed: the reviser writes no telemetry (D-02), so `done_reason` and `eval_count` are unknown.

- The reconstructed prompt is 6,373 tokens.
- `num_ctx 16384` leaves about 10,000 tokens for the output.
- At about 67 tok/s that takes about 150 s, close to the observed 177 s.
- The direct probe of round 1 showed that thinking can use the whole output budget and leave `response` empty.
- So thinking that ran until the context was full is the likely cause.

**OBSERVATION.** `qwen3.5:9b` is unreliable as a reviser: in 4 attempts it gave 1 empty response, 2 outputs that fail validation, and 1 good result. When it deletes every acceptance criterion, a `specify.ps1` workflow ends with exit 2 ("Revised specification failed structural validation").

## C. Variance (`spec` = `qwen3.5:9b`, the same task 3 times)

**Task:** "Create a specification for a simple CLI that converts CSV to JSON". Each run took about 12 s, with the model already loaded (FACT: telemetry and wall-clock time).

| Run | Wall-clock | `eval_count` | Output tok/s | FR / AC | Source labels | Unsupported items labelled `USER` (OBSERVATION) | Open Questions | Validator |
|---|---|---|---|---|---|---|---|---|
| 1 | 12.1 s | 487 | 64.3 | 2 / 2 | all `USER` | output to stdout or a file (FR-001); error on bad input with no partial output (AC-002) | None | PASS |
| 2 | 12.8 s | 655 | 66.4 | 3 / 3 | all `USER` | path as an argument (FR-001); stdout or file (FR-002); header-keyed objects (FR-003); stdout default (AC-001); output-file argument (AC-002); empty rows and missing values (AC-003) | None | PASS |
| 3 | 12.4 s | 599 | 61.6 | 2 / 3 | all `USER` | stdout (FR-001); optional output file (FR-002, AC-002); error on unreadable input (AC-003) | None | PASS |

**OBSERVATION:**

- Scope varies from run to run (2–3 FR, 2–3 AC).
- **Every run** adds design choices that the request doesn't contain, all labelled `USER`.
- **No run** uses Open Questions or Assumptions.
- The validator can't see any of this.

**The reviewer on the worst run** (run 2, `qwen3.6:35b`): **FAIL** in 49.5 s (`specs/validation2-C-run2.review.md`).

- **Flagged** as BLOCKING: the output-file argument (FR-002/AC-002) and the missing-value handling (AC-003), including the wrong `USER` labels.
- **Accepted** as reasonable: FR-001 (input path) and FR-003 (rows mapped to header-keyed objects).

It therefore caught some of the items in the table above, but not all.

## D. Single model (`qwen3.6:35b` for every agent)

**D-A, the run A review repeated.** **FAIL** in 65.6 s, with 6 BLOCKING findings (see section A). The reviewer is the same model in both configurations, so this repeat measures the reviewer's run-to-run variance rather than a configuration difference.

**D-specify:** `specify.ps1 -Name validation2-single`, with the same CSV task. `qwen3.6:35b` was already loaded at the start.

| Stage | Start → end | Time | Result |
|---|---|---|---|
| Step 1, spec | 23:24:19 → 23:25:32 | 73 s (telemetry: 69.3 s, **`eval_count` 3,404**, 50.0 tok/s, no load) | 3 FR / 3 AC, **2 open questions**, 1 assumption |
| Step 2, validation | — | under 1 s | PASS |
| Review 1 | 23:25:33 → 23:27:12 | 99 s | **FAIL**: output-file argument (FR-003/AC-003) is BLOCKING |
| Revision 1 (reviser on `qwen3.6:35b`) | 23:27:14 → 23:27:42 | 28 s | It removed exactly FR-003 and AC-003 and kept the open questions and the assumption |
| Validation of the revision | — | under 1 s | PASS |
| Review 2 | 23:27:42 → 23:29:03 | 81 s | **PASS** (1 WARNING, 1 INFO) |
| **Total** | 23:24:18 → 23:29:04 | **286 s** | exit 0, **1 revision**, **0 model reloads** (FACT: `qwen3.6:35b` stayed loaded the whole time) |

## Mixed versus single model

The mixed figures come from round 1 (`docs/audits/2026-11-19-model-validation.md`) and from rounds B and C above.

| | Mixed (`spec`/reviser = 9b, reviewer = 35b) | Single (all 35b) |
|---|---|---|
| End-to-end on the CSV task | 107 s, 0 revisions (round 1) | 286 s, 1 revision |
| Model loads per workflow | 2 so far (9b for spec, 35b for review), plus 2 more for each revision cycle (9b for the reviser, 35b for the re-review) | **0** once 35b is loaded |
| Cost of a load (FACT) | 9b about 14 s (27 s cold); 35b about 42–52 s (no `ollama ps` rows while loading) | — |
| Spec stage | 10–24 s | 36–73 s (thinking: 1,401–3,404 output tokens) |
| Reviser | 9b: 1 empty, 2 invalid, 1 good result (in 4) | 35b: 1 good result in 1 (28 s) |
| Spec quality (OBSERVATION) | 5 of 5 specs from `qwen3.5:9b` labelled unsupported design choices as `USER`; none used Open Questions | 2 of 2 specs from `qwen3.6:35b` with default thinking raised pertinent open questions (header row, JSON structure, formatting); one was fully minimal |

**OBSERVATION.** The two end-to-end runs aren't directly comparable, because one needed a revision and the other didn't.

- **Per stage, single is slower** at spec generation.
- **Single avoids model reloads.** The mixed setup pays about 42–52 s each time the 35b model reloads, which offsets much of that difference once a revision is needed.
- **Quality favored the single 35b model** in these samples: open questions, a cleaner revision, and no reviser failures.

## E. Effect of `think: false`

**Method:** direct `/api/generate` calls with the system prompt rebuilt from the template in `scripts/run-agent.ps1` (29,160 characters) and the same options. All outputs were validated with `validate-spec.ps1` (FACT).

| Model / prompt | Setting | Time | `eval_count` | Output tok/s | `thinking` field | Visible characters | Validator | Content (OBSERVATION) |
|---|---|---|---|---|---|---|---|---|
| qwen3.5:9b / spec | default | 11.3 s | 584 | 66.1 | present, 1,848 chars | 871 | PASS | 3 FR / 2 AC, all `USER`, no open questions |
| qwen3.5:9b / spec | `think: false` | 6.8 s | 326 | 71.4 | absent | 1,312 | PASS | **5 FR** / 2 AC; a JSON output **file** made mandatory; less minimal |
| qwen3.5:9b / reviser | default | 11.6 s | 623 | 67.8 | present, 2,001 chars | 731 | **FAIL** (no AC) | deleted every acceptance criterion |
| qwen3.5:9b / reviser | `think: false` | 4.4 s | 157 | 70.6 | absent | 731 | **FAIL** (no AC) | the same content |
| qwen3.6:35b / spec | default | 35.7 s | 1,401 | 51.0 | present, 5,407 chars | 693 | PASS | **1 FR / 1 AC plus an open question**: the most minimal output |
| qwen3.6:35b / spec | `think: false` | 6.8 s | 247 | 54.9 | absent | 1,017 | PASS | 3 FR / 2 AC; assumes header-keyed objects; no open questions |

**Thinking in Ollama 0.40.13** (FACT, confirmed again):

- By default the reasoning comes back in a separate `thinking` field. `response` never contained `<think>` tags.
- With `"think": false` the `thinking` field is absent.
- `prompt_eval_count` changed by +2 tokens.

**Effect of `think: false`:**

- `eval_count` dropped by 44–82% and the time by 40–81%.
- **Quality:** in both spec samples, turning thinking off made the output **less** minimal and dropped open questions (OBSERVATION, n = 1 per model).
- For the reviser it made no difference to the (bad) content.

## Problems

1. **The 9b reviser is unreliable.** One empty response after 177 s, and two outputs that delete every acceptance criterion and therefore fail validation. In a `specify.ps1` run, either outcome ends with exit 2. (FACT for the observed outcomes.)
2. **The reviewer's advice and the reviser's rules conflict.** The reviewer says "Remove AC-001 or rephrase". The reviser's rule "Do not replace removed items with new ones" ([revise-spec.ps1:99](../../scripts/revise-spec.ps1#L99)) can push it toward deleting everything, after which the requirements-mode validator rejects the spec. (INFERENCE from the outputs.)
3. **Empty responses can't be diagnosed.** The harness reads only `response`, discards `thinking`, and writes no reviewer or reviser telemetry (D-02). An empty answer therefore carries no `done_reason`, `eval_count` or thinking length. (FACT)
4. **Spec quality with `qwen3.5:9b`** (OBSERVATION): design choices labelled `USER` in 5 of 5 samples, and Open Questions never used. The structural validator can't detect either.
5. **Reviewer gaps** (OBSERVATION): it doesn't review Context and Dependencies for unsupported scope (2 of 2 runs missed the authentication dependency), and its severity for the same item is inconsistent.
6. **Model reloads** cost 14–52 s each in the mixed setup, and every revision cycle adds two.
7. **The live tests still name the old models** (D-04/D-06), and those models are still installed. A `-IncludeLive` run would test the wrong model.

## Recommendation per agent

These are provisional, given the small samples.

| Agent | Current model | Recommendation |
|---|---|---|
| spec | qwen3.5:9b | **Change to `qwen3.6:35b`**, if 40–70 s per spec is acceptable. In these samples it was more minimal and used open questions. Keep the default (thinking on): `think: false` made specs worse in 2 of 2 samples. If speed matters more, keep 9b and expect the reviewer to catch scope creep, which it does only partly. |
| spec-reviewer | qwen3.6:35b | **Keep.** It rejects bad specs (3 of 3 expected FAILs), and its PASS verdicts on good specs were coherent. **Keep thinking on**: there is no reviewer data with `think: false`. Its gaps (Context, Dependencies, inconsistent severity) are prompt issues. |
| spec-reviser | qwen3.5:9b | **Change to `qwen3.6:35b`.** The 9b model failed 3 times in 4. The single 35b revision was correct and took 28 s. `think: false` did not fix the 9b output. |
| developer | qwen3.6:35b | **Keep.** It was not retested in this round; round 1 showed good quality. |

**Implication.** Following these recommendations amounts to the single-model setup (`qwen3.6:35b` everywhere). That also removes the model reloads. Applying it means editing `.ai/config.json`, which is a human decision; it was not done here.

**Candidates for Phase 2** (no code was changed):

- a per-agent `think` setting, with thinking left on by default for these models
- recording `done_reason`, `eval_count` and thinking length for every call, including the reviewer and reviser (this extends D-02)
- detecting an empty `response` together with `done_reason: length` and reporting it as "context or thinking budget exhausted"
- reconsidering the conflict between the reviser's "do not replace" rule and the requirement for acceptance criteria

## Generated files

None of these is covered by `.gitignore`, so they were left in place:

```text
specs/validation2-A-mixed.review.md
specs/validation2-B-revised.md
specs/validation2-B-revised.review.md
specs/validation2-C-run1.md
specs/validation2-C-run2.md
specs/validation2-C-run2.review.md
specs/validation2-C-run3.md
specs/validation2-D-single-A.review.md
specs/validation2-single.md
specs/validation2-single.review.md
specs/validation2-single.revised-v1.md
specs/validation2-single.revised-v1.review.md
```

## Final `git status --short`

Recorded when this report was written:

```text
?? docs/audits/2026-11-19-model-validation-2.md
?? specs/validation2-A-mixed.review.md
?? specs/validation2-B-revised.md
?? specs/validation2-B-revised.review.md
?? specs/validation2-C-run1.md
?? specs/validation2-C-run2.md
?? specs/validation2-C-run2.review.md
?? specs/validation2-C-run3.md
?? specs/validation2-D-single-A.review.md
?? specs/validation2-single.md
?? specs/validation2-single.review.md
?? specs/validation2-single.revised-v1.md
?? specs/validation2-single.revised-v1.review.md
```
