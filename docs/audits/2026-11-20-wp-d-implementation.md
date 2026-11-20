# WP-D implementation report: reviewer and reviser availability checks and telemetry

**Date:** 2026-11-20
**Spec:** [specs/harness-phase-0-defect-corrections.md](../../specs/harness-phase-0-defect-corrections.md), Revision 3
**Starting point:** `HEAD` = `027c979` (WP-A and WP-C committed), clean working tree
**Scope:** Work Package D only: FR-010, FR-011, FR-012 and FR-018, verified by AC-012 to AC-017, AC-027 and AC-030, under NFR-001 to NFR-006.
**State:** all changes are in the working tree for human review. Nothing is staged, committed or pushed.

**Not done, as instructed:** Ollama was not started; no live test, no `-IncludeLive` run and no live model call; WP-E was not started; the spec, `telemetry.ps1`, `run-agent.ps1`, `test-all.ps1`, mocks, fixtures and `.ai/` were not modified.

**Network safety.** No command of this work package sent a request to Ollama or to any server.
- My first inspection command included a read-only `curl` to `http://localhost:11434/api/version`, to learn whether Ollama was running. The permission system refused it before it ran, and I did not retry it.
- Every later check assumed Ollama might be running. Every request attempt went to the fake `Invoke-RestMethod` (section 4).

## 1. Summary

- **What the reviewer and reviser now do:**
  - Before any generation request, they check that Ollama answers on `/api/tags` and that the model is installed, matching names case-insensitively (FR-010).
  - Each generation request actually sent writes exactly one telemetry record through the unchanged `Write-HarnessModelTelemetry`, on success and on failure (FR-011).
  - Prompts, parameters, exit codes, markers and output files are unchanged (FR-012).
- **New suite:** `scripts/test-agent-telemetry.ps1` (FR-018), 23 assertions with all four safety guards. It passes on its own and inside offline `test-all`.
- **A-02 is true**, verified before any code change (section 4).
- **AC-017:** the prompts are byte-identical. The spec's literal method is confounded by line endings, a spec issue (sections 5 and 7).
- **Mutation check:** against the `2e85dbe` reviewer and reviser the suite fails 15 of 23 assertions, at every point where the availability check or telemetry is missing.
- **Offline `test-all`:** the same as the baseline plus the new suite as PASS. Every tripwire is clean.
- **Every in-scope AC is PASS** (section 3).

## 2. Files changed

| File | Status | Requirements |
|---|---|---|
| `scripts/lib/config.ps1` | modified: 51 lines added, 2 changed | FR-010 (`Test-HarnessModelAvailable`), FR-011 (optional `-TelemetryAgent` and `-TelemetryRoot` on `Invoke-HarnessGenerate`) |
| `scripts/review-spec.ps1` | modified: 10 lines added, 1 changed | FR-010, FR-011, FR-012 |
| `scripts/revise-spec.ps1` | modified: 10 lines added, 1 changed | FR-010, FR-011, FR-012 |
| `scripts/test-agent-telemetry.ps1` | new | FR-018 |

**`git status --short`:**

```text
 M scripts/lib/config.ps1
 M scripts/review-spec.ps1
 M scripts/revise-spec.ps1
?? scripts/test-agent-telemetry.ps1
```

This report is the fifth file. `git diff --stat`: 3 files changed, 73 insertions, 4 deletions.

**Compared with the allowed list:** 4 changed, 4 allowed (not counting this report), none extra, none missing.

**File conventions.** Every edit was applied as an exact byte replacement, with new lines in CRLF:

| File | Convention preserved |
|---|---|
| `config.ps1` | CRLF only, its two non-ASCII comment lines unchanged, no final newline |
| `review-spec.ps1` | CRLF plus its 5 bare-LF lines (3, 4, 84–86), no final newline |
| `revise-spec.ps1` | CRLF only, final newline |
| New suite | CRLF, ASCII, no BOM |

### What the code does

- **`Test-HarnessModelAvailable -Model -Config`** (in `config.ps1`), the same check as `run-agent.ps1`:
  - `GET <ollamaUrl>/api/tags` with a 15 s timeout.
  - If that fails, it prints `Ollama is not reachable at <url>. Make sure Ollama is running.`
  - If the model is missing (`-notcontains`, case-insensitive), it prints `Model not found: <model>` and the available models.
  - In either case it returns the problem; when the model is available it returns nothing. It never sends a generation request.
- **`Invoke-HarnessGenerate`:**
  - It gains two optional parameters, `-TelemetryAgent` and `-TelemetryRoot`. Only when both are given does it write one record: `success` with the response metrics, or `error` with the request's exception message, written before rethrowing.
  - The rethrown text (`Ollama request failed: …`) and the behavior of calls without these parameters are unchanged.
- **`review-spec.ps1`:**
  - It dot-sources `lib\telemetry.ps1` inside its existing input `try`.
  - It runs the check before "Sending specification to reviewer...", and **exits 2** if the check fails.
  - It passes `-TelemetryAgent spec-reviewer -TelemetryRoot $root`.
- **`revise-spec.ps1`:** the same, but it **throws** the problem, keeping its existing "non-zero on any error" style, and passes `spec-reviser`.

During development I found and fixed two of my own mistakes; both are corrected and verified:
- A shell escaping step had turned `lib\telemetry.ps1` into a TAB character. No TAB remains, all three files parse, and the text is exactly `lib\telemetry.ps1`.
- A PowerShell 5.1 `.Count` quirk in the suite: a single `PSCustomObject` has no `.Count`.

## 3. Results per acceptance criterion

Evidence:

- **A.** `scripts/test-agent-telemetry.ps1` run on its own: exit 0, `Passed: 23`, `Failed: 0`, `STATUS: PASS`, about 7 s. Its TEMP root was removed afterwards.
- **B.** The same suite inside offline `test-all`: PASS, tripwire clean.

Every case also checks guards 2 and 3: the child reported the fake as active, and no URL-allowlist violation was recorded.

| AC | Result | Evidence |
|---|---|---|
| AC-012 | **PASS** | **A, B:** the fake `/api/tags` lists `phase0-fake:1b`; the fake `/api/generate` returns `## Status` / `PASS` with `eval_count = 10`. The reviewer exits 0, prints `Review Status: PASS` and writes the output file. The temporary `logs/model-calls.jsonl` has exactly one line: `agent = spec-reviewer`, `model = phase0-fake:1b`, `status = success`, `eval_count = 10`. The CSV header is identical to the header the current `Write-HarnessModelTelemetry` writes (generated as a reference in the same run, 14 columns, same order). |
| AC-013 | **PASS** | **A, B:** with the fake `/api/generate` throwing, the reviewer exits 2 and prints `=== OLLAMA ERROR ===`, and the reviser exits non-zero. Each run adds exactly one line, with `status = error`, a non-empty `error`, and `agent` set to `spec-reviewer` or `spec-reviser`. |
| AC-014 | **PASS** | **A, B:** with the model not listed, the reviewer exits 2 and the reviser non-zero. Both print `Model not found: phase0-fake:1b`. The fake records zero `/api/generate` calls, and zero telemetry lines are written. **Case variant:** the fake lists `PHASE0-FAKE:1B` and the scripts request `phase0-fake:1b`; both scripts treat it as installed and send one generation request. |
| AC-015 | **PASS** | **A, B:** with the fake `/api/tags` throwing, the reviewer exits 2 and the reviser non-zero. Both print a line starting with `Ollama is not reachable at`. Zero `/api/generate` calls and zero telemetry lines. |
| AC-016 | **PASS** | **A, B:** with a fake `/api/generate` that returns a specification, the reviser exits 0 and writes exactly the returned text. One telemetry line, with `agent = spec-reviser` and `status = success`. |
| AC-017 | **PASS** (one-time check; see section 5 for the method) | The system and user prompts of both scripts are byte-identical before and after WP-D, when "before" and "after" are compared with the same line endings. |
| AC-027 | **PASS** | **A, B:** with `AI_HARNESS_RUN_ID=phase0-run-id-test` set in the child, a successful reviewer call and a successful reviser call each write `run_id = phase0-run-id-test`. With the variable unset, and with it set to three spaces, the `run_id` of both scripts parses as a `[guid]`. |
| AC-030 | **PASS** | **A, B, at startup:** guard 1 rejects a missing `.ai\config.json`, invalid JSON, `http://localhost:11434` and `http://127.0.0.1:10`, and accepts the temporary config. The guard 4 static check finds no other HTTP route in the 4 copied scripts. **In every case:** the child reported the fake as active (guard 2), and zero URL violations were recorded (guard 3). **Negative case:** the temporary config is deleted after guard 1, so the reviewer falls back to `http://localhost:11434`. The fake records exactly one violation for `http://localhost:11434/api/tags` and no allowed call; the reviewer exits 2 with no telemetry. |

**Non-functional requirements:**

| NFR | Result | Evidence |
|---|---|---|
| NFR-001 | PASS | Windows PowerShell 5.1 only. No module, package or service added. |
| NFR-002 | PASS | No connection to Ollama or any server (guards 1–4). The suite writes only under its TEMP root, which it deletes. No mandatory parameters; explicit `exit`. Tripwire clean. |
| NFR-003 | PASS | Parameters, exit codes, markers and output files of both scripts are unchanged. A missing model now fails before generation, with the same exit code (reviewer 2, reviser non-zero). The only additions are the FR-010 messages and the telemetry records. |
| NFR-004 | PASS | The changed files equal the allowed list (section 2). |
| NFR-005 | PASS | The same `Write-HarnessModelTelemetry` and the same 14-column schema (AC-012). The repository's `logs/` was never written: the tripwire hashes the whole repository except `.git` and stayed clean. |
| NFR-006 | PASS (by construction; AC-031 is checked in step 5) | Assertions use exit codes, call and telemetry records, and harness lines: `Review Status: PASS`, `=== OLLAMA ERROR ===`, `Model not found: …`, `Ollama is not reachable at`. Child stderr (localized error records) is dropped and never asserted on. |

## 4. A-02 and the guard proof (step 3a, before any code change)

**Method.** A scratchpad "probe host" started a child `powershell.exe`, defined `function global:Invoke-RestMethod` (recording each call, allowlisting only `http://127.0.0.1:9/`), and checked that `(Get-Command Invoke-RestMethod).CommandType` is `Function` (guard 2). It then ran real script files with `&`. The first three targets used only `http://127.0.0.1:9`, a loopback port with nothing listening, so even a false A-02 could not have reached Ollama.

| Target script, run with `&` | Result |
|---|---|
| Calls `Invoke-RestMethod` directly | Fake used: it returned the fake's marker object; call recorded |
| Calls it from a function in a dot-sourced lib | Fake used; call recorded |
| Calls the **unchanged** `lib\config.ps1` `Invoke-HarnessGenerate` (the reviewer and reviser path) | Fake used: `POST http://127.0.0.1:9/api/generate` recorded, fake text returned |

**A-02 is TRUE.** A function named `Invoke-RestMethod`, defined in the child process, takes precedence over the cmdlet for script files run with `&`, including from dot-sourced libraries.

**Guard proof.** Only after that was confirmed, a fourth script attempted `http://localhost:11434/api/tags`. Result:
- exit 2
- message `FAKE-IRM: blocked, no request sent: http://localhost:11434/api/tags`
- call log `VIOLATION|Get|http://localhost:11434/api/tags`

The attempt failed inside the harness, not on the network. The permanent suite repeats this proof as its AC-030 negative case.

## 5. AC-017: prompt comparison and SHA-256 hashes

**Method.**
1. The FR-018 harness, with the suite's stub inputs, captured the `system` and `prompt` fields of the successful reviewer and reviser calls inside the fake, and printed their SHA-256.
2. The "after" scripts are the current working tree. The "before" scripts are `2e85dbe`, in two forms (see section 7, issue 1).

| Run | Reviewer `system` | Reviewer `prompt` | Reviser `system` | Reviser `prompt` |
|---|---|---|---|---|
| **After**, working tree (CRLF) | `FCA4F91AE0EE6254005017C70C67D9CA3EE8FBF60B426A2607D3D37220091750` | `AF3831B2CC98D93732556D50CBE396627AE5B8CC67523081BA6A7744F4C443FA` | `513BAAA959FB78C23598811F8515945376372BAC1AE0556A2BA86AC132DD1D69` | `4E6E3AF435D96E35FDA743E661D21CEAE19D6117938544634A3FEE2B28FC72D4` |
| **Before**, exact pre-edit working-tree bytes | `FCA4F91AE0EE6254005017C70C67D9CA3EE8FBF60B426A2607D3D37220091750` | `AF3831B2CC98D93732556D50CBE396627AE5B8CC67523081BA6A7744F4C443FA` | `513BAAA959FB78C23598811F8515945376372BAC1AE0556A2BA86AC132DD1D69` | `4E6E3AF435D96E35FDA743E661D21CEAE19D6117938544634A3FEE2B28FC72D4` |
| **After**, normalized to LF (as git stores it) | `60CCC06674C4BC2D5732E743B90F0DC408F41FB4C2C6FFB10D498301D010617F` | `AF3831B2CC98D93732556D50CBE396627AE5B8CC67523081BA6A7744F4C443FA` | `2450CF5FDF06C3C885D873C4F64025C3620440860BC2687781489450226AA454` | `4E6E3AF435D96E35FDA743E661D21CEAE19D6117938544634A3FEE2B28FC72D4` |
| **Before**, `git show 2e85dbe` (LF) | `60CCC06674C4BC2D5732E743B90F0DC408F41FB4C2C6FFB10D498301D010617F` | `AF3831B2CC98D93732556D50CBE396627AE5B8CC67523081BA6A7744F4C443FA` | `2450CF5FDF06C3C885D873C4F64025C3620440860BC2687781489450226AA454` | `4E6E3AF435D96E35FDA743E661D21CEAE19D6117938544634A3FEE2B28FC72D4` |

**Result.** With the same line endings, before equals after, in both pairs, for all four fields. **The prompts are byte-identical.**

**How the pre-edit working-tree bytes were obtained.** I reversed the WP-D edits on copies, with a scratchpad script. The rebuilt files have exactly the line-ending profile recorded before editing:

| File | Profile |
|---|---|
| `review-spec.ps1` | 164 CRLF, bare LF on lines 3, 4, 84, 85, 86, no final newline |
| `revise-spec.ps1` | 168 CRLF, final newline |
| `config.ps1` | 89 CRLF |

Normalized to LF, each is identical to `git show 2e85dbe:<file>`.

## 6. Mutation check

**Method.** The new suite was run from a scratchpad `scripts\` folder holding the `2e85dbe` versions of `review-spec.ps1`, `revise-spec.ps1` and `lib\config.ps1`, plus the unchanged `lib\telemetry.ps1`. All four guards were active, so the old scripts could not reach a server either.

**Result:** exit 1, `Passed: 8`, `Failed: 15`, `STATUS: FAIL`.

| Assertion | Against `2e85dbe` | Why |
|---|---|---|
| AC-012, AC-016, AC-013 (×2), AC-027 (×6) | **FAIL** | No telemetry line is written. |
| AC-014 missing model (×2), AC-015 unreachable (×2) | **FAIL** | No availability check: a generation request is sent; no `Model not found` or `Ollama is not reachable` line; the wrong exit code. |
| AC-030 negative case | **FAIL** | The expected violation for `/api/tags` is missing. The old reviewer went straight to `http://localhost:11434/api/generate`, which the fake refused (`violation=True`), so no request went out. |
| AC-030 startup checks (×6), AC-014 case variant (×2) | PASS | Expected: guards 1 and 4 don't depend on the scripts' behavior, and the old scripts also generate when the case-differing model is listed. |

The same run against the rebuilt pre-edit working-tree bytes gave the same counts (8 passed, 15 failed).

## 7. Spec issues and interpretations

**Spec issue 1: AC-017's method is confounded by line endings.**
- **The problem.** AC-017 says to extract the "before" scripts with `git show 2e85dbe:<path>`. This repository uses `core.autocrlf=true`, so `git show` produces LF-only files, while the scripts actually run here are CRLF, and `review-spec.ps1` even has mixed endings.
- **Why it matters.** A PowerShell here-string takes its line endings from the file. Comparing a `git show` copy with the working tree therefore gives different `system` hashes (`60CCC066…` vs `FCA4F91A…` for the reviewer) **without any code change**. The `prompt` field is a one-line literal and is unaffected.
- **How I resolved it.** I compared like with like, both ways, with identical results (section 5).
- **Suggested spec wording:** "compare with the same line endings (both normalized to LF, or both as checked out)".
- I did not edit the spec, as instructed. This needs a decision only if you want the literal wording kept.

**Readings I took** (none changes an AC):

1. **Placement of the check.** It runs after the existing header lines and right before "Sending specification to …". That is after inputs and config are read, and before any generation request.
2. **No new marker for availability failures.** The reviewer prints the FR-010 message lines and exits 2. The reviser prints them and throws, which exits non-zero (and maps to 2 under `specify.ps1`, as before).
3. **The telemetry `error` field** holds the raw exception message of the failed request, as in `run-agent.ps1`. The rethrown text keeps its existing `Ollama request failed:` prefix.
4. **Guard 1 runs before every case**, not only once, which is stricter than "before any case". The AC-030 negative case deletes the config only after guard 1 has passed, as the spec describes.
5. **Guard 4 also refuses the aliases `irm`, `iwr`, `curl` and `wget`** (whole words), in addition to the five routes the spec lists. These aliases could reach the network without the function name. This is stricter than the spec and finds nothing in the current scripts.
6. **AC-014's case variant and AC-027's unset and blank variants** are exercised for both the reviewer and the reviser.

**Observations:**

- **`Invoke-HarnessGenerate` with the telemetry parameters** relies on `Write-HarnessModelTelemetry` being defined, which means `lib\telemetry.ps1` dot-sourced. Both callers do this, and a comment in `config.ps1` says so. Calls without the parameters don't need it.
- **RK-08 as designed:** when Ollama hangs, the extra `/api/tags` call can add up to 15 s before failing.

## 8. Assumptions used

| Assumption | Status |
|---|---|
| **A-02** | **Verified true** (section 4). It can be marked verified in the spec at its next revision. |
| **A-01, A-03 to A-07** | Not needed for WP-D. |

## 9. Open items

- **WP-E has not started**, as instructed.
- **Checked later in Phase 0:**
  - AC-021 (the full offline run with all three new suites) is effectively shown by the `test-all` run above: 9 discovered, 8 passed, `test-spec-integration` skipped. It is formally checked in step 5, after WP-E.
  - AC-029 (case-insensitive matching inspection; the helper uses `-notcontains`).
  - AC-031 (the NFR-006 inspection).
- **Spec issue 1 (AC-017 wording)** needs an amendment or an explicit acceptance of the like-with-like method.
- **Human review and commit** are still to be done.

## 10. test-all before and after (offline, no `-IncludeLive`)

| | Before (baseline, `HEAD` 027c979) | After |
|---|---|---|
| Discovered | 8 | 9 (adds `test-agent-telemetry.ps1`) |
| `test-syntax.ps1` | PASS, 0.3 s | PASS, 0.3 s (also parses the new suite) |
| `test-agent-telemetry.ps1` | — | **PASS, 6.5 s**, `Passed: 23`, `Failed: 0` |
| `test-build-context.ps1` | PASS, 0.5 s | PASS, 0.5 s |
| `test-mode-propagation.ps1` | PASS, 3.9 s | PASS, 3.7 s (sandbox) |
| `test-run-agent.ps1` | PASS, 1.5 s | PASS, 1.4 s |
| `test-scan-repository.ps1` | PASS, 1.7 s | PASS, 1.6 s |
| `test-spec.ps1` | PASS, 4.5 s | PASS, 3.9 s (sandbox), `Passed: 17` |
| `test-validate-spec.ps1` | PASS, 10.0 s | PASS, 9.1 s, `Passed: 54` |
| `test-spec-integration.ps1` | SKIPPED (NOT VERIFIED, needs Ollama) | SKIPPED (NOT VERIFIED, needs Ollama) |
| Summary line | `Suites discovered: 8 \| Executed: 7 \| Passed: 7 \| Passed with skips: 0 \| Failed: 0 \| Skipped: 1` | `Suites discovered: 9 \| Executed: 8 \| Passed: 8 \| Passed with skips: 0 \| Failed: 0 \| Skipped: 1` |
| Status and exit | `STATUS: PASS WITH SKIPS`, exit 0 | `STATUS: PASS WITH SKIPS`, exit 0 |
| Tripwire | clean, 209 entries, for every executed suite | clean, 210 entries (209 + the new suite), for every executed suite |

The only difference is the new suite, which appears as PASS.
