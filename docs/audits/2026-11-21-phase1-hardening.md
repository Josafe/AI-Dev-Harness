# Phase 1 hardening report

**Date:** 2026-11-21
**Branch:** `fix/phase1-hardening`, created from `master` at `d73cefd` (tag `phase1-done`). Local commits only; nothing was pushed.
**Source of the work:** findings F-01, F-02, F-03, F-07, F-08 and F-09 of `docs/audits/2026-11-20-phase1-final-qa.md` (sections 4 and 8).
**Scope kept small:** no refactoring, no prompt change, no live test, no Ollama call (the tests use the existing fake-host guards).

## 1. Changes

| Commit | Finding | What changed |
|---|---|---|
| `test(registry): cover non-default margin ratio` | F-01 | 7 fixtures `config-v2-margin-*.json` and `config-v2-invalid-margin-*.json`; 7 cases in `scripts/test-registry.ps1`. |
| `fix(config): validate ollama.healthTimeoutSec and url` | F-02 | `Assert-HarnessRegistryV2` (`scripts/lib/config.ps1`) rejects `ollama.healthTimeoutSec` unless it is an integer from 1 to 600, and `ollama.url` unless it is a non-blank string. 8 fixtures; cases in `test-registry.ps1` and `test-registry-callsites.ps1`. |
| `fix(test): surface config errors in live precondition` | F-03 | `Test-OllamaPrecondition` (`scripts/test-all.ps1`) returns `could not read .ai\config.json: <error>` instead of using `http://localhost:11434` silently. |
| `docs(spec): record Phase 1 as implemented and add hardening rules` | F-07, F-08, F-09 | Spec header (Implemented, Revision 3); FR-103 (explicit `schemaVersion` 1 or `null`; the new rules); FR-104 rule 2 (`defaults.profile` for an agent without an entry); new AC-114 with the matrix updated; the Affected Files rows of the two registry suites; roadmap O-16 (`deep` is 8192) and the roadmap status line. |

### F-01: margin tests (expected values are literals worked out by hand)

The rule is `contextWindow > reservedOutputTokens + ceil(ratio x contextWindow)`.

| Ratio | Window | Margin | Accepted | Rejected |
|---|---|---|---|---|
| 0.5 | 1000 | 500 | 499 | 500, 501 |
| 0.15 | 1000 | 150 | 849 | 850 |
| 0.1 | 8191 | 819.1, rounded up to 820 | 7370 | 7371 |

Each case runs through the loader and through the `Resolve-HarnessModel` wrapper. Each rejected fixture also asserts its own `reservedOutputTokens` literal, so a fixture edit cannot go unnoticed.

### F-02: validation

- Accepted: `healthTimeoutSec` 1 and 600. Rejected with `registry_invalid: ollama.healthTimeoutSec`: 0, -5, 601, `"abc"`, 30.5 (loader and wrapper).
- Rejected with `registry_invalid: ollama.url`: `""` (fixture), `"   "` and `5` (temporary files).
- v1 files (`config-v1-minimal.json`, `config-v1-current.json`) keep `healthTimeoutSec` 15; a v1 file with a blank `ollamaUrl` still loads (v1 is never validated); a v2 file without `ollama`, or with `url` only, gets 15.
- Real child run: `review-spec.ps1` with `healthTimeoutSec` `"abc"`, `0` and `601` now exits 2 and prints `registry_invalid: ollama.healthTimeoutSec`, with no request and no telemetry line (3 cases in `test-registry-callsites.ps1`; the 4 guards are unchanged and still pass). Before the fix this suite fails those 3 cases.
- A blank `ollama.url` is not run through a child process, because guard 1 of that suite requires the fake URL in the configuration.
- Design choice (not in the QA text): a non-string `ollama.url` (for example `5`) is also rejected, with the same token. Recorded in FR-103 as "a non-blank string".

### F-03

Checked by extracting the function from `test-all.ps1` with the parser, pointing it at a temporary repository root with `{ "schemaVersion": 3 }`, and calling it: it returned `could not read .ai\config.json: registry_invalid: schemaVersion (schemaVersion=3, expected 2)` without sending any request. The live path itself (`-IncludeLive`) was not run.

### Extra test (small, not requested as a test)

`AC-103 an explicit schemaVersion 1 or null is invalid, not v1` in `test-registry.ps1`: it asserts the F-09 sentence added to the spec (it passes against the unchanged code).

## 2. Mutation proof (temporary local changes, each reverted; the file hash was checked equal to the backup)

| Mutation of `config.ps1` (margin line) | `test-registry.ps1` result |
|---|---|
| `Ceiling` replaced by `Floor` | **FAIL**: 85 passed, 1 failed: `margin rejected: ratio 0.1, window 8191 (margin 819.1), reserved 7371` |
| `Ceiling` replaced by `Round` | **FAIL**: same single failure (819.1 rounds to 819) |
| ratio hardcoded as `0.10` | **FAIL**: 83 passed, 3 failed: `ratio 0.5 reserved 500`, `ratio 0.5 reserved 501`, `ratio 0.15 reserved 850` |

For F-02, the suites were also run against the unchanged `config.ps1` from `HEAD~` (before the fix): `test-registry.ps1` 79 passed, 7 failed; `test-registry-callsites.ps1` 52 passed, 3 failed. With the fix: all pass.

## 3. Counts before and after (offline `scripts\test-all.ps1`, run twice after the change; both runs identical)

| Suite | Before (`d73cefd`) | After |
|---|---|---|
| `test-registry.ps1` | 67 | 86 |
| `test-registry-callsites.ps1` | 52 | 55 |
| `test-agent-telemetry.ps1` | 23 | 23 |
| `test-build-context.ps1` | 15 | 15 |
| `test-mode-propagation.ps1` | 11 | 11 |
| `test-run-agent.ps1` | 5 | 5 |
| `test-scan-repository.ps1` | 26 | 26 |
| `test-spec.ps1` | 17 | 17 |
| `test-validate-spec.ps1` | 54 | 54 |
| `test-syntax.ps1`, `test-spec-integration.ps1` | PASS, SKIPPED | PASS, SKIPPED |

- Final line of both runs: `STATUS: PASS WITH SKIPS` (10 suites executed, 10 PASS, 0 FAIL; `test-spec-integration.ps1` skipped, NOT VERIFIED).
- Tripwire: clean in every suite, both runs. The entry count went from 238 to 253 because 15 new fixtures were added under `tests/fixtures/`.
- `scripts\validate-spec.ps1 specs\harness-phase-1-config-registry.md`: `STATUS: PASS`.
- `git status` after the runs: clean (apart from this report, committed last).

## 4. NOT VERIFIED

- The live suite (`test-all.ps1 -IncludeLive`, `test-spec-integration.ps1`) and any real Ollama call were not run, so the new F-03 message is checked only through the extracted function, not through the live path.
- The claim in the QA report that `-TimeoutSec 0` means no timeout in `Invoke-RestMethod` on PowerShell 5.1 is still documented behavior, not executed. The new lower bound of 1 makes it moot.
- The Execution Order table of the spec was left as the historical plan; AC-114 appears in the matrix and in the Affected Files rows only.
- F-04, F-05, F-06, F-10 to F-14 of the QA report were not addressed (out of the requested scope).
- Not pushed; no pull request.
