# Phase 1 WP-1B implementation report: call sites (migration not done)

**Date:** 2026-11-20
**Spec:** [specs/harness-phase-1-config-registry.md](../../specs/harness-phase-1-config-registry.md), revision 2
**Branch:** `feat/phase1-wp1b`, created from `feat/phase1-wp1a` (WP-1A, commit `7016743`). Baseline code: `5ffc33f`.
**Scope:** Work Package 1B without the migration of `.ai/config.json` (the last WP-1B commit, which needs a separate human approval). FR-106, FR-107 and the tests of AC-104, AC-105, AC-106, AC-107, AC-108, AC-109, AC-110, AC-111, AC-113.
**State:** two local commits. Nothing was pushed, merged, tagged, rebased, reset or amended.

**Not done, as instructed or by design:**
- `.ai/config.json` is unchanged (still v1). AC-113 is therefore NOT VERIFIED against the real file.
- Ollama was not started. No live test, no `-IncludeLive`, no request to any server. Every child-process case ran against a fake `Invoke-RestMethod` that only accepts `http://127.0.0.1:9/`.
- `benchmark-models.ps1` and `test-spec-integration.ps1` were not run (inspection and a parse check only).
- `.claude/`, `.gitignore`, `.ai/`, prompts, `specify.ps1`, `lib/telemetry.ps1`, `validate-spec.ps1` and the spec were not modified.

## 1. Summary

- **`scripts/lib/config.ps1`:**
  - `ConvertTo-HarnessRegistry` returns an already normalized registry unchanged (type name `Harness.Registry`), so helpers accept a raw configuration or a registry.
  - `Invoke-HarnessGenerate` gets an optional `-Execution` parameter. `-Config` stays mandatory. It reads the URL and `stripThinking` from the registry, and `timeoutSec` and `options` from the record. Without `-Execution` it uses the registry defaults, as before.
  - `Test-HarnessModelAvailable` reads the URL and the health timeout (`ollama.healthTimeoutSec`, default 15) from the registry.
  - The request body never has a `think` member, and `options` is sent only when it has members.
- **`run-agent.ps1`, `review-spec.ps1`, `revise-spec.ps1`:** a new optional `-Profile`. They load the registry, resolve with `Resolve-HarnessExecution` (passing `-Model` and `-Profile` only when bound) and take timeout, options, `stripThinking` and URL from the record and the registry. `run-agent.ps1` also uses the health timeout. System and user prompts, console output, output files and exit codes are unchanged; a configuration error ends with the code each script already gives (1, 2, non-zero) before any request and without telemetry.
- **`benchmark-models.ps1`:** no literal default `-Models`; when `-Models` is not bound, it is the distinct profile models of the registry, in profile order (an empty list is an error). An explicit `-Models` is unchanged.
- **`test-all.ps1` and `test-spec-integration.ps1`:** `Resolve-LiveSuiteModel` and the integration suite resolve the model with `Resolve-HarnessExecution`. The `ModelAgent` field and its contract are unchanged.
- **New suite `scripts/test-registry-callsites.ps1`** (51 assertions, offline, TEMP only) and **fixture `tests/fixtures/historical-model-names.txt`** (the three historical names, as data).

## 2. Files

| File | Change |
|---|---|
| `scripts/lib/config.ps1` | as above (CRLF, ASCII, no BOM, kept) |
| `scripts/run-agent.ps1` | `-Profile`, registry; mixed line endings preserved byte for byte |
| `scripts/review-spec.ps1`, `scripts/revise-spec.ps1` | `-Profile`, registry, `-Execution` |
| `scripts/benchmark-models.ps1` | default `-Models` from the registry (LF kept) |
| `scripts/test-all.ps1` | `Resolve-LiveSuiteModel` only (LF kept) |
| `scripts/test-spec-integration.ps1` | model resolution only |
| `scripts/test-registry-callsites.ps1` (new) | the suite (CRLF, ASCII, no BOM) |
| `tests/fixtures/historical-model-names.txt` (new) | the three names, one per line |
| `docs/audits/2026-11-20-phase1-wp1b-implementation.md` | this report (commit 2) |

## 3. Per-AC result (WP-1B scope)

| AC | Result | Evidence |
|---|---|---|
| AC-104 | **PASS** | `run-agent` (exit 1), `review-spec` (exit 2) and `revise-spec` (non-zero) with an invalid v2 config each print a line containing `registry_invalid:`, make no request and write no telemetry line. For `revise-spec` the line is printed by the fake host, which catches the script's uncaught error and prints its message. |
| AC-105 | **PASS** (function part in WP-1A) | The three scripts with `-Model` and `-Profile`, under a v1 and a v2 config: configuration-error exit code, a line containing `invalid_arguments:`, no request, no telemetry. |
| AC-106 | **PASS** (function part in WP-1A) | The three scripts with a blank `-Model`, under v1 and v2: same exit code, the line `Model name cannot be empty.`, no request. |
| AC-107 | **PASS** | Names from `.ai/config.json` (through the registry helper) and from `historical-model-names.txt`, searched with `Select-String -SimpleMatch` in every file under `scripts/` (including the git-ignored local backups): no hit. The scanner is proven on a planted name, and the lists are checked to be non-empty. Before this commit the only hits were the three default names of `benchmark-models.ps1`. |
| AC-108 | **PASS** (inspection, not run) | The helper returns the distinct models in profile order on both fixtures; an AST check shows `Models` has no default value, the script calls `Get-HarnessRegistryModels`, and only when `-Models` is not bound. |
| AC-109 | **PASS** | Request bodies recorded by the fake host for the three scripts, with profiles whose `think` is `true`: no `think` member. Inspection: the only `think` text in the changed scripts is the `<think>` tag stripper, and `lib/config.ps1` reads `think` only to validate it and copy it into the profile and the record. |
| AC-110 | **PASS** | `Resolve-LiveSuiteModel`, extracted from `test-all.ps1` and run in-process, gives the same model as the `Model :` line of `review-spec.ps1` under the v1 fixture and its v2 translation, and the same as the v1 raw file. Offline `test-all.ps1` still prints `model 'qwen3.6:35b' (agent 'spec-reviewer')` in the SKIPPED detail. A configuration error is returned as a problem, not thrown. |
| AC-111 | **PASS** | Section 4. |
| AC-112 | **PASS so far** | `git diff --stat 5ffc33f` lists only the files of Affected Files plus the spec, the two audit reports and the roadmap edit made on the docs branch. No change in any system or user prompt string. `.ai/`, `lib/telemetry.ps1` and the other "Not modified" files are untouched. `.ai/config.json` changes only in the migration commit, which has not been made. |
| AC-113 | **NOT VERIFIED** | The repository `.ai/config.json` is still v1, so the suite prints `SKIPPED_TESTS: AC-113`. The checker itself is tested: it accepts a configuration generated from the frozen v1 fixture (profiles `fast`, `deep`, `review`; the assignments, `reservedOutputTokens`, `think`; same models, timeout, `stripThinking` and URL; same options except the reviewer's `temperature` 0.1 and `seed` 42) and rejects 8 mutations. It runs on the real file as soon as that file is v2. |

NFR-103 (v1 behavior): with a v1 config, each of the three scripts keeps the v1 model, timeout, options and default health timeout (15), and a v1 file without `options` sends no `options` member.

## 4. test-all (offline, no `-IncludeLive`)

| | After WP-1A | After WP-1B |
|---|---|---|
| Suites discovered | 10 | 11 |
| Executed / passed / passed with skips / failed / skipped | 9 / 9 / 0 / 0 / 1 | 10 / 9 / 1 / 0 / 1 |
| Status, exit code | `PASS WITH SKIPS`, 0 | `PASS WITH SKIPS`, 0 |
| Tripwire | clean | clean on every suite |

The only difference is the new `test-registry-callsites.ps1`: `PASS WITH SKIPS` (51 passed, 0 failed, `SKIPPED_TESTS: AC-113`). `test-registry` is still 67/0, `test-agent-telemetry` 23/0 (real `review-spec` and `revise-spec` against a v1 stub config), `test-run-agent` 5/0, `test-spec` 17/0, `test-validate-spec` 54/0, `test-mode-propagation` 11/0, `test-build-context` 15/0, `test-scan-repository` 26/0. `test-syntax` parses all new and changed files.

## 5. Mutation check

The new suite was run from a temp copy whose call sites, `test-all.ps1`, `benchmark-models.ps1` and `lib/config.ps1` come from `HEAD` before this work (WP-1A state). Result: exit 1, 33 passed, 18 failed. The failures are exactly the new behavior: AC-104 (3), AC-105 (6), the six request-body cases for the v2 config (profile, `-Profile`, registered `-Model`, unregistered `-Model`, reviser, `run-agent`), the literal scan, the benchmark inspection, and AC-110 under the v2 fixture. The 33 passes are the guards, the v1 regression cases, the blank `-Model` cases (behavior that must not change), the helper and the AC-113 checker.

## 6. Spec issues and notes

1. **Affected Files for `test-registry-callsites.ps1` omits AC-106 and AC-109**, which this suite covers (the script part of AC-106, and the request bodies of AC-109). Execution Order does list AC-109 for WP-1B. Suggested spec fix: add AC-106 and AC-109 to that row. Not edited here.
2. **`test-all.ps1` `Test-OllamaPrecondition` still reads only the v1 key `ollamaUrl`.** FR-106 covers the model resolution of `test-all.ps1`, not this URL. With a v2 file it would fall back to `http://localhost:11434`, which equals the migrated URL, so nothing changes in practice, but a non-default `ollama.url` would be ignored by the `-IncludeLive` precondition. It is only reached with `-IncludeLive`, so it was neither changed nor tested. Recommended before or with the migration commit.
3. **Stale comments** in `test-all.ps1` (header of the table and the comment of `Resolve-LiveSuiteModel`) still list `agentModels` and `defaultModel`. Left as they are, to keep the change minimal.
4. **FR-106 and `-Profile` on `revise-spec.ps1`:** its configuration errors are uncaught throws (as before), so the message goes to the error stream and the exit code is non-zero.

## 7. Assumptions used

- **A-B1.** `Invoke-HarnessGenerate` keeps `-Config` mandatory and takes the record as the optional `-Execution`; callers pass the registry as `-Config`. Existing callers that pass a v1 configuration object still work (their values are the registry defaults).
- **A-B2.** `options` is sent only when it has members. A v1 file with `"options": {}` therefore no longer sends an empty `options` member (it did before); the request is equivalent for Ollama.
- **A-B3.** An empty default model list for the benchmark is an error with a harness message ("No models configured for the benchmark...").
- **A-B4.** The suite scans every file under `scripts/` for AC-107, including git-ignored local backups (none contains a name today).
- **A-B5.** While `.ai/config.json` is v1, AC-113 is reported as `SKIPPED_TESTS` (the suite then ends `PASS WITH SKIPS`), not as a pass.

## 8. Open items

- **Migration (last WP-1B commit):** rewrite `.ai/config.json` as v2 with `fast`, `deep` and `review` (spec OD-112) after your approval. Then AC-113 runs on the real file; the suite must pass with `SKIPPED_TESTS: none`, and offline `test-all` must still show the same resolved model.
- Item 2 of section 6.
- Live checks remain NOT VERIFIED: `test-all -IncludeLive`, `test-spec-integration.ps1`, `benchmark-models.ps1`, and any real call to Ollama.
- Step 3 of the Execution Order (final QA, independent review, human approval) is not started.
