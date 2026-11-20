# WP-E implementation report: test models and best-effort model resolution in test-all

**Date:** 2026-11-20
**Spec:** [specs/harness-phase-0-defect-corrections.md](../../specs/harness-phase-0-defect-corrections.md), Revision 3
**Starting point:** `HEAD` = `c5f8950` (WP-A, WP-C and WP-D committed), clean working tree
**Scope:** Work Package E only: FR-013, FR-014 and FR-015, verified by AC-018, AC-019, AC-020 (inspection) and AC-028, under NFR-001 to NFR-006.
**State:** all changes are in the working tree for human review. Nothing is staged, committed or pushed.

**Not done, as instructed:**
- Ollama was not started; no live test, no live model call, and no `-IncludeLive` run of the repository's `test-all.ps1`.
- No request went to any server. Every `-IncludeLive` run of AC-028 used a TEMP copy of `test-all.ps1` inside a child process whose `Invoke-RestMethod` is a fake that records and throws (section 5).
- The spec, `.ai/config.json`, `tests/`, `scripts/lib/` and the other scripts were not modified.
- The final QA step (step 5) was not started.

## 1. Summary

- **`test-spec.ps1`** no longer has the unused `-Model` parameter or its hardcoded model (FR-015).
- **`test-spec-integration.ps1`** (FR-013):
  - It has no default model, and passes `-Model` to the reviewer only when its own `-Model` was given.
  - It prints the model resolved through `Resolve-HarnessModel -Agent spec-reviewer`.
- **`test-all.ps1`** (FR-014):
  - The live entry uses `ModelAgent = "spec-reviewer"`, and a live entry must have exactly one of `Model` or `ModelAgent`, as a non-blank string. An invalid live entry is never executed.
  - The model is resolved on a best-effort basis through `lib\config.ps1`. Offline, a failure only appears in the `SKIPPED` detail. With `-IncludeLive` it is a FAIL, sends no request, and the run exits 1.
  - Model names are matched with `-notcontains` (case-insensitive), and the table comment is fixed.
  - The WP-C sandbox entry for `test-mode-propagation.ps1` is kept.
- **AC-018, AC-020 and AC-028 are PASS.** AC-028 passed 17 of 17 cases in its one-time check, with zero requests in every resolution-failure and bad-entry case.
- **AC-019 is PASS against its stated intent** ("the configured `spec-reviewer` model"), but **its literal value is stale**. It names `deepseek-r1:32b`, while the configuration has been `qwen3.6:35b` since commits `61e8dcc` and `984eaba`. See spec issue 1.
- **Mutation checks:** the previous scripts fail where the old behavior differs:
  - AC-018: 3 model names found
  - AC-028: 14 of 17 cases fail
  - FR-013: the old suite forces `qwen2.5-coder:32b`
- **Offline `test-all`:** the same suites and results as the baseline. The only intended difference is the live suite's `SKIPPED` detail, which now names the configured model. Every tripwire is clean.

## 2. Files changed

| File | Status | Requirements |
|---|---|---|
| `scripts/test-all.ps1` | modified: 83 lines added, 9 changed (LF only, as before) | FR-014 |
| `scripts/test-spec-integration.ps1` | modified: 18 lines added, 3 changed (CRLF, no final newline, as before) | FR-013 |
| `scripts/test-spec.ps1` | modified: 4 lines removed (CRLF, final newline, as before) | FR-015 |

**`git status --short`:**

```text
 M scripts/test-all.ps1
 M scripts/test-spec-integration.ps1
 M scripts/test-spec.ps1
```

This report is the fourth file. `git diff --stat`: 3 files changed, 101 insertions, 16 deletions.

**Compared with the allowed list:** 3 changed, 3 allowed (not counting this report), none extra, none missing. `.ai/`, `specs/`, `tests/`, `scripts/lib/` and every other script are unchanged.

**How the edits were made.** They were applied byte-exactly by a scratchpad script that requires exactly one match per edit and writes each file's own line ending. Afterwards there were no TABs and no non-ASCII bytes, and all three files parse without errors.

### What changed in `test-all.ps1`

- **Table comment:** documents `ModelAgent`, and says a live entry has exactly one of `Model` or `ModelAgent`.
- **The `test-spec-integration.ps1` entry:** `ModelAgent = "spec-reviewer"` replaces `Model = "qwen2.5-coder:32b"`. Its `Reason` no longer says "must match the suite's own -Model default".
- **`$allowedOverrideFields`:** gains `ModelAgent`.
- **New `Get-LiveEntryProblem`:** exactly one of `Model` or `ModelAgent`, as a non-blank string, checked using the table only. It is used in two places:
  - by `Get-OverrideProblems`, which reports a `test-all configuration` FAIL, as before, in both modes
  - by `Invoke-Suite`, so an invalid live entry is never executed and its precondition never runs. With `-IncludeLive` the suite is reported `FAIL` ("invalid table entry, NOT executed"); offline it is `SKIPPED` ("invalid table entry").
- **New `Resolve-LiveSuiteModel`:**
  - It dot-sources `scripts\lib\config.ps1` from `test-all`'s own folder, calls `Get-HarnessConfig` on `<root>\.ai\config.json`, then `Resolve-HarnessModel -Agent <ModelAgent> -ModelWasProvided $false`. It trims the result the way the reviewer does, and treats an empty result as a failure.
  - Everything runs inside `try/catch`, and a failure comes back as a reason string. It never throws and sends nothing.
- **`Invoke-Suite` for live entries:**
  - **Offline:** `SKIPPED` with `requires Ollama and model '<m>' (agent '<a>'); use -IncludeLive.` On a resolution failure: `model could not be resolved (agent '<a>'): <reason>; use -IncludeLive.` Neither is ever a FAIL.
  - **With `-IncludeLive`:** a resolution failure gives `FAIL` with `precondition not met, NOT executed: model could not be resolved (agent '<a>'): <reason>`, and no request is sent. On success, the existing precondition runs with the resolved model, and its FAIL detail now ends with `(model '<m>' (agent '<a>'))`.
- **`Test-OllamaPrecondition`:** `-cnotcontains` became `-notcontains`.

## 3. Results per acceptance criterion

| AC | Result | Evidence |
|---|---|---|
| AC-018 | **PASS** | `Select-String -SimpleMatch` for `qwen2.5-coder:32b`, `qwen2.5-coder:7b` and `deepseek-r1:32b` in `test-spec.ps1`, `test-spec-integration.ps1` and `test-all.ps1` finds **0** matches. Extra: the currently configured names, `qwen3.5:9b` and `qwen3.6:35b`, also give 0 matches. The previous (`HEAD`) versions give 3 matches, one per file. |
| AC-019 | **PASS against its intent; literal value stale (spec issue 1)** | Offline `test-all` with the current `.ai/config.json` and `AI_HARNESS_MODEL` unset: `test-spec-integration.ps1` is `SKIPPED` with the detail `NOT VERIFIED (not executed): requires Ollama and model 'qwen3.6:35b' (agent 'spec-reviewer'); use -IncludeLive. …`, and no `test-all configuration` result appears. `qwen3.6:35b` is the configured `agentModels.spec-reviewer`. The AC's literal `deepseek-r1:32b` is no longer configured. |
| AC-020 | **PASS (inspection)** | `test-spec-integration.ps1` computes `$modelWasProvided = $PSBoundParameters.ContainsKey('Model')` at script level, and builds `$reviewerModelArguments` only when it is true, so `-Model` is passed on only if given. It prints `Model: $resolvedModel`, resolved with `Resolve-HarnessModel -Agent "spec-reviewer" -ModelWasProvided $modelWasProvided -ExplicitModel $Model -Config (Get-HarnessConfig …)`. **Extra evidence** (not required; the suite was run in a scratchpad root whose `review-spec.ps1` is a stub that only records its arguments, so no model and no network): see the table below. **The deferred live run** with `-IncludeLive` was not done (NOT VERIFIED, as the AC allows). |
| AC-028 | **PASS** (one-time check) | 17 of 17 cases (section 5). (a)–(d) without `-IncludeLive`: exit 0, `STATUS: PASS WITH SKIPS`, `SKIPPED` with "model could not be resolved" and `spec-reviewer`, no `[FAIL]` line, no `test-all configuration`, no `test-all internal error`. (a)–(d) with `-IncludeLive`: exit 1, `STATUS: FAIL`, `test-spec-integration.ps1` FAIL with "precondition not met, NOT executed: model could not be resolved" and `spec-reviewer`, **zero calls** to the fake, and the stub not executed. (e): exit 0, and the detail names `phase0-fake:1b` (agent `spec-reviewer`). (f): `test-all configuration` FAIL, exit 1 in both modes, zero calls, and the stub not executed. |

**AC-020 extra evidence** (stub reviewer, stub config with `spec-reviewer` = `stub-reviewer:2b`):

| Case | Model printed | Reviewer received |
|---|---|---|
| no `-Model` | `stub-reviewer:2b` | no `-Model` (both calls) |
| `-Model explicit-model:3b` | `explicit-model:3b` | `-Model explicit-model:3b` |
| `AI_HARNESS_MODEL=env-model:4b` | `env-model:4b` | no `-Model`; the reviewer resolves the same chain itself |

**Non-functional requirements:**

| NFR | Result | Evidence |
|---|---|---|
| NFR-001 | PASS | Windows PowerShell 5.1 only. Nothing added. |
| NFR-002 | PASS | Offline `test-all` contacts nothing; it only reads `.ai/config.json` to name the model. AC-028 shows zero requests for every resolution failure and invalid entry, even with `-IncludeLive`. Every tripwire is clean. |
| NFR-003 | PASS | Every intentional change is in NFR-003's list: the parameter removed from `test-spec.ps1`, the best-effort config read, an unresolvable model failing with `-IncludeLive`, the exactly-one rule, and case-insensitive matching. All other behavior is unchanged: discovery, sandbox, tripwire, summary and exit rule. The offline results equal the baseline. |
| NFR-004 | PASS | The changed files equal the allowed list (section 2). |
| NFR-005 | n/a | No telemetry change. |
| NFR-006 | PASS (by construction; AC-031 is checked in step 5) | AC-028 asserts only `test-all`'s own wording, exit codes, fake call records and a marker file. The `<reason>` text is never asserted: in case (b) it contains localized .NET text ("Se ha pasado un objeto no válido…"), which is displayed but not checked. |

## 4. test-all before and after (offline, no `-IncludeLive`)

| Suite | Before (baseline, `HEAD` c5f8950) | After |
|---|---|---|
| `test-syntax.ps1` | PASS, 0.3 s | PASS, 0.3 s (also parses the three changed files) |
| `test-agent-telemetry.ps1` | PASS, 6.6 s | PASS, 7.3 s |
| `test-build-context.ps1` | PASS, 0.5 s | PASS, 0.5 s |
| `test-mode-propagation.ps1` | PASS, 3.8 s (sandbox) | PASS, 3.9 s (sandbox, entry kept) |
| `test-run-agent.ps1` | PASS, 1.5 s | PASS, 1.5 s |
| `test-scan-repository.ps1` | PASS, 1.8 s | PASS, 1.8 s |
| `test-spec.ps1` | PASS, 4.0 s (sandbox) | PASS, 4.4 s (sandbox); `Passed: 17`, `Failed: 0` also confirmed separately after FR-015 |
| `test-validate-spec.ps1` | PASS, 9.4 s | PASS, 10.3 s |
| `test-spec-integration.ps1` | SKIPPED: `requires Ollama; use -IncludeLive. … needs Ollama and the model above (must match the suite's own -Model default).` | SKIPPED: `requires Ollama and model 'qwen3.6:35b' (agent 'spec-reviewer'); use -IncludeLive. … needs Ollama and the spec-reviewer model resolved from the configuration, exactly as the reviewer resolves it.` |
| Summary line | `Suites discovered: 9 \| Executed: 8 \| Passed: 8 \| Passed with skips: 0 \| Failed: 0 \| Skipped: 1` | identical |
| Status and exit | `STATUS: PASS WITH SKIPS`, exit 0 | identical |
| Tripwire | clean, 211 entries, for every executed suite | clean, 211 entries, for every executed suite |

The only difference is the intended one: the live suite's `SKIPPED` detail now names the configured model and no longer carries the outdated comment. Timing differences are run-to-run noise.

## 5. AC-028 one-time check

**Method.** A scratchpad driver (`ac028.ps1`, not part of the repository) built a separate temporary root under TEMP for each case, containing:
- a copy of the `test-all.ps1` under test
- a copy of `scripts\lib\config.ps1`
- an `exit 0` stub for each table suite: `test-syntax`, `test-spec`, `test-mode-propagation` and `test-spec-integration`. The last one writes a marker file **outside** the root if it is ever executed.
- the case's `.ai\config.json`. Any URL in it is `http://127.0.0.1:9`.

Every run of the copied `test-all` happened inside a child `powershell.exe`:
- **The fake:** `function global:Invoke-RestMethod` records each call and **always throws**. This is the approach validated in WP-D; A-02 was verified there.
- **The guard:** the child confirms `Invoke-RestMethod` is the function before starting `test-all`, or exits 97.
- **The environment:** `AI_HARNESS_MODEL` is removed, except in extra case (h).

Every TEMP folder was deleted afterwards; none was left over.

**Result for the changed `test-all.ps1`: 17 passed, 0 failed.**

| Case | Without `-IncludeLive` | With `-IncludeLive` |
|---|---|---|
| (a) `.ai/config.json` missing | exit 0, SKIPPED: `model could not be resolved (agent 'spec-reviewer'): No model configured. …` | exit 1, FAIL: `precondition not met, NOT executed: model could not be resolved (agent 'spec-reviewer'): …`; **0 calls**; stub not run |
| (b) invalid JSON | exit 0, SKIPPED with the reason (`Invalid JSON in config file: …`, localized .NET text) | exit 1, FAIL, same pattern; **0 calls**; stub not run |
| (c) neither `agentModels.spec-reviewer` nor `defaultModel` | exit 0, SKIPPED with the reason | exit 1, FAIL; **0 calls**; stub not run |
| (d) `agentModels.spec-reviewer` = `"  "` | exit 0, SKIPPED: `… the resolved model is empty` | exit 1, FAIL; **0 calls**; stub not run |
| (e) valid config, `spec-reviewer` = `phase0-fake:1b` | exit 0, SKIPPED: `requires Ollama and model 'phase0-fake:1b' (agent 'spec-reviewer')`; 0 calls | (extra case g) |
| (f) table entry with neither `Model` nor `ModelAgent` | exit 1, `test-all configuration` FAIL: `… needs exactly one of Model or ModelAgent`; 0 calls; stub not run | exit 1, configuration FAIL, and `test-spec-integration.ps1` FAIL `invalid table entry, NOT executed`; **0 calls**; stub not run |
| extra (f-both): both `Model` and `ModelAgent` | exit 1, configuration FAIL; 0 calls | exit 1, configuration FAIL and `invalid table entry, NOT executed`; **0 calls** |
| extra (f-blank): `ModelAgent = "  "` | exit 1, configuration FAIL `ModelAgent must be a non-blank string`; 0 calls | exit 1, same; **0 calls** |
| extra (g): valid config | — | exit 1, exactly **one** call, `GET http://127.0.0.1:9/api/tags`, to the fake. FAIL: `precondition not met, NOT executed: Ollama is not reachable at http://127.0.0.1:9 (…) (model 'phase0-fake:1b' (agent 'spec-reviewer'))` |
| extra (h): no config, `AI_HARNESS_MODEL=env-model:1b` | exit 0, SKIPPED names `env-model:1b` (agent `spec-reviewer`), the same chain as the reviewer; 0 calls | — |

## 6. Mutation checks

| Check | Against the previous (`HEAD`) version | Result |
|---|---|---|
| AC-018 scan | `test-all.ps1:115 Model = "qwen2.5-coder:32b"`, `test-spec-integration.ps1:2` and `test-spec.ps1:3` | **3 matches**, so it fails as expected |
| AC-028 driver | previous `test-all.ps1` | **exit 1, 14 of 17 failed.** (a)–(d) offline: no "model could not be resolved" detail, because the old version never reads the config. (a), (c), (d) live: the old version **called the fake** (`GET http://127.0.0.1:9/api/tags`; in (a), `GET http://localhost:11434/api/tags`, intercepted by the fake, so no request was sent). (b) live: wrong wording. (e) and (h): the model is not named. (f), (f-both), (f-blank) live: the precondition still ran and called the fake. (g): the model is not named. **The 3 passes** are the offline bad-entry variants, which the old table validation also reports as configuration failures. |
| FR-013 stub-reviewer check | previous `test-spec-integration.ps1` | Without `-Model`, and even with `AI_HARNESS_MODEL=env-model:4b`, the old suite printed and **passed `-Model qwen2.5-coder:32b`** to the reviewer: defect D-06. It fails as expected. |

## 7. Spec issues and interpretations

**Spec issue 1: AC-019 (and related text) names a model that is no longer configured.**
- **The stale text.** AC-019 expects the `SKIPPED` detail to name `deepseek-r1:32b`, "the configured `spec-reviewer` model". The same value appears in the Context table "Ollama and model configuration at review time", in A-03, in RK-05, in AC-020's deferred note and in FR-014's example.
- **The actual configuration.** Since commits `61e8dcc` and `984eaba`, `agentModels.spec-reviewer` is `qwen3.6:35b`.
- **What I did.** The implementation doesn't depend on the value: FR-014 resolves it from config. So I implemented the spec as written and verified AC-019 against its stated intent. As instructed, I did not edit the spec or `.ai/config.json`.
- **Suggested amendment:** "names the model configured for `spec-reviewer` (currently `qwen3.6:35b`)", or no literal value at all. Also update A-03 and RK-05.

**Spec issue 2 (minor): AC-018's name list is fixed to three historical names.** I also checked the two currently configured names, with no match. A future-proof wording would be "no model name from `.ai/config.json` and none of the historical names".

**Readings I took** (none changes an AC):

1. **An invalid live entry without `-IncludeLive`.** The spec fixes the configuration FAIL and "never executed", and the FAIL only for `-IncludeLive`. Offline, the suite itself is reported `SKIPPED` ("invalid table entry: …"), and the run still fails through the configuration result.
2. **"Its messages name the resolved model"** (successful resolution with `-IncludeLive`). The precondition's FAIL detail now ends with `(model '<m>' (agent '<a>'))`, or `(model '<m>')` for a literal `Model` entry. `Test-OllamaPrecondition`'s own messages are unchanged.
3. **Offline `SKIPPED` details** keep the existing `NOT VERIFIED (not executed):` prefix and the entry's `Reason` at the end.
4. **The resolved model is trimmed**, as `review-spec.ps1` does (`"$Model".Trim()`). A blank result is a failure ("the resolved model is empty").
5. **In `test-spec-integration.ps1`**, a resolution failure ends the suite with a non-zero exit. It is a live suite, and `test-all` resolves the model first anyway.
6. **FR-015** also removed the blank line that followed the `param` block, so the file still starts with a single blank line.

## 8. Assumptions used

| Assumption | Status |
|---|---|
| **A-02** (a function stands in for `Invoke-RestMethod`) | Relied on for the AC-028 fake; verified true in WP-D. Here too, every run confirmed the fake was active before `test-all` started. |
| **A-03** ("`deepseek-r1:32b` is the model the live reviewer test is meant to exercise") | **Outdated.** The configured reviewer is now `qwen3.6:35b`. The spec's underlying intent, "use the configured reviewer model", is what FR-013 and FR-014 now implement (spec issue 1). |
| **A-01, A-04 to A-07** | Not needed for WP-E. |

## 9. Open items

- **The final QA step (step 5) has not started**, as instructed: AC-021, AC-022, AC-029 (the case-insensitive matching inspection) and AC-031 (the NFR-006 inspection), plus the independent review and human approval.
- **AC-020's deferred live run** (`-IncludeLive` with Ollama and the configured reviewer model) remains NOT VERIFIED, as the spec allows.
- **Spec amendments to decide at the next revision:**
  - AC-019, A-03 and RK-05: stale model name
  - AC-018: name list
  - AC-017 wording: line endings (from WP-D)
  - A-02 and A-07 marked verified (from WP-C and WP-D)
- **Human review and commit** are still to be done.
