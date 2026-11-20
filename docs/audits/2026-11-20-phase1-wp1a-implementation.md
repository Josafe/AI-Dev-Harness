# Phase 1 WP-1A implementation report: registry library

**Date:** 2026-11-20
**Spec:** [specs/harness-phase-1-config-registry.md](../../specs/harness-phase-1-config-registry.md), revision 2 (commit `018d5b6`)
**Branch:** `feat/phase1-wp1a`, created from `docs/phase1-spec` (clean tree, as required). Baseline code: `5ffc33f` (tag `phase0-done`).
**Scope:** Work Package 1A only (Execution Order, step 1): the registry library, its fixtures and its offline suite. No call site, no `.ai/` file, no prompt, no `specify.ps1` change.
**State:** three local commits. Nothing was pushed, merged, tagged, rebased, reset or amended.

**Not done, as instructed:**
- Ollama was not started. No live test, no `-IncludeLive`, and no request to any server (including the local Ollama port). Every test in this report is in-process and offline.
- WP-1B was not started: no change to `Invoke-HarnessGenerate`, `Test-HarnessModelAvailable`, `run-agent.ps1`, `review-spec.ps1`, `revise-spec.ps1`, `benchmark-models.ps1`, `test-all.ps1`, `test-spec-integration.ps1`, and no migration of `.ai/config.json`.

## 1. Summary

- **Part 1: spec revision 2** (commit 1). OQ-101 to OQ-106 became OD-106 to OD-111; Open Questions is now "None". New OD-112 records the three-profile configuration (`fast`, `deep`, `review`), its rationale and the intended later `think` values. New AC-113 (WP-1B) checks that the migrated `.ai/config.json` keeps every model and changes only the reviewer's options (`temperature` 0.1, `seed` 42). NFR-103's list of intentional changes, the Traceability Matrix, Affected Files, Execution Order, Edge Cases, Risks (new RK-105) and Assumptions were kept consistent. `scripts\validate-spec.ps1`: `STATUS: PASS`. An independent check found no duplicate or undefined IDs, exactly one `Verifies:` line per AC, and a matrix identical to the `Verifies:` lines.
- **Part 2: WP-1A** (commit 2). `scripts/lib/config.ps1` gains `Get-HarnessRegistry`, `ConvertTo-HarnessRegistry`, `Resolve-HarnessExecution`, `Get-HarnessRegistryModels` and private helpers. `Resolve-HarnessModel` is now a compatibility wrapper with the same parameters. `Get-HarnessConfig`, `Get-ConfigValue`, `Invoke-HarnessGenerate` and `Test-HarnessModelAvailable` are byte-identical to before.
- **New suite** `scripts/test-registry.ps1`: 67 assertions (cases), offline, in-process, TEMP only, ends with an explicit `exit`. 15 fixtures under `tests/fixtures/`.

## 2. Files

| File | Change |
|---|---|
| `specs/harness-phase-1-config-registry.md` | revised (commit 1; LF endings kept) |
| `scripts/lib/config.ps1` | `Resolve-HarnessModel` replaced by the new functions and the wrapper; CRLF kept, no BOM, no trailing newline (as before). The 8 non-ASCII bytes of the file were all in the Spanish comments of the old `Resolve-HarnessModel`, so the file is now pure ASCII. |
| `scripts/test-registry.ps1` (new) | the suite; CRLF, ASCII, no BOM |
| `tests/fixtures/config-v1-current.json` (new) | byte-identical copy of `.ai/config.json` (checked with `fc /b`) |
| `tests/fixtures/config-v2-current.json` (new) | strict v2 translation of the v1 file (`fast`, `deep`, no `review`) |
| `tests/fixtures/config-v1-minimal.json`, `config-v1-timeout-10.json` (new) | v1 without optional keys; v1 with `timeoutSec` 10; synthetic model names |
| `tests/fixtures/config-v2-invalid-*.json` (9, new) | one per invalid rule (schema, no model, default profile, agent profile, timeout 29, timeout 14401, margin, `num_ctx`, `think`) |
| `tests/fixtures/config-v2-warnings.json`, `config-v2-think.json` (new) | unknown key plus non-loopback URL; `think` true, false, `"default"`, absent |
| `docs/audits/2026-11-20-phase1-wp1a-implementation.md` | this report (commit 3) |

Not created: `tests/fixtures/historical-model-names.txt`. The spec assigns it to AC-107, which is WP-1B (revision 2 now says so in Affected Files).

## 3. Per-AC result

Scope of WP-1A: AC-101, AC-102, AC-103, AC-105 (function part), AC-106, AC-109 (record part), AC-111.

| AC | Result | Evidence |
|---|---|---|
| AC-101 | **PASS** | 20 cases (5 agents x 4 cases: none, `-Model`, variable, both). Each compares `Resolve-HarnessModel` and `Resolve-HarnessExecution`, under `config-v1-current.json` and `config-v2-current.json`, with a value computed from the raw v1 JSON. The suite sets and restores `AI_HARNESS_MODEL`. |
| AC-102 | **PASS** | v1 conversion (schemaVersion 2, profiles `legacy:<model>`, 4 agent assignments, `defaults.profile`, url, timeout, options, stripThinking); effective `timeoutSec` and `options` (key and value pairs) equal for all 5 agents under both fixtures; url and `stripThinking` equal; minimal v1 gets 600, true, default url, no options; missing file, empty file and `{}` load as empty registries; the wrapper resolves with the variable and throws the rule 7 message without it. |
| AC-103 | **PASS** | 9 invalid fixtures rejected with `registry_invalid: <rule>` (loader and wrapper); boundary cases (30 and 14400 accepted, margin exactly met rejected, non-object `profiles`, blank model, non-numeric ratio); v1 `timeoutSec` 10 loads; the warning fixture carries `unknown_key:` and `non_loopback_ollama_url`; the loopback URLs `localhost`, `127.0.0.1` and `[::1]` raise none; `think` is `"default"` when absent and `true`, `false`, `"default"` are kept. |
| AC-105 | **PASS (function part), NOT VERIFIED (script part)** | `invalid_arguments:` under v1 and v2, also with a blank model, a blank profile, and the variable set. The script part (child processes with the fake-host guards) is WP-1B. |
| AC-106 | **PASS (function part), NOT VERIFIED (script part)** | Order `-Profile` > `AI_HARNESS_MODEL` > agent > default with `modelSource` `explicit-profile`, `env`, `agent`, `default`; unknown or blank `-Profile` gives `registry_invalid:`; `-Model` matching one profile (also with different case) takes its parameters, no warning; unregistered `-Model` or variable takes the agent's profile and adds `unregistered_model_override`; a model matching two profiles uses the agent's profile, no warning; blank `-Model` is passed through and returned unchanged by the wrapper; the record has exactly the 11 fields of FR-104. The scripts' "Model name cannot be empty." wording was only inspected (still present in the three scripts, which this change does not touch); no behavioral test runs it (see 6.1). |
| AC-109 | **PASS (record part), inspection only for the rest** | `think` is `"default"` (absent and named), `True` and `False` (booleans) in the registry and in the record; a v1 file gives `"default"`. Inspection: `Invoke-HarnessGenerate` is unchanged and its payload has no `think` member; the only `think` text in `run-agent.ps1` is the `<think>` tag stripper; no other script reads `think`. |
| AC-111 | **PASS** | See section 4: offline `test-all` ends with `STATUS: PASS WITH SKIPS`, exit 0; the 8 baseline suites pass with the same counts (`test-spec` 17/0); `test-syntax.ps1` passes and parses the new files (it scans `scripts\` and `tests\`); every tripwire is clean. "The new registry suites" is one suite in WP-1A (the second is WP-1B). |
| Others | NOT VERIFIED | AC-104, AC-107, AC-108, AC-110, AC-112 and AC-113 belong to WP-1B or the final QA. |

## 4. test-all, before and after (offline, no `-IncludeLive`)

| | Baseline (before any change) | After WP-1A |
|---|---|---|
| Suites discovered | 9 | 10 |
| Executed / passed / failed / skipped | 8 / 8 / 0 / 1 | 9 / 9 / 0 / 1 |
| Status, exit code | `PASS WITH SKIPS`, 0 | `PASS WITH SKIPS`, 0 |
| Tripwire | clean, 216 entries before and after | clean on every suite, 232 entries before and after (the 16 new files) |
| Skipped suite | `test-spec-integration.ps1` | the same, and its detail still names the same resolved model and agent (`spec-reviewer`), so the wrapper behaves as before |

The only difference is the new suite `test-registry.ps1`: `PASS`, `Passed: 67`, `Failed: 0`. `test-spec` 17/0, `test-validate-spec` 54/0, `test-build-context` 15/0, `test-agent-telemetry` 23/0, `test-mode-propagation` 11/0, `test-run-agent` 5/0 and `test-scan-repository` 26/0 are unchanged. `test-all` ran twice after the code was complete (once before and once after a small robustness edit of the suite); both runs gave the same result. The suite was also run alone with `AI_HARNESS_MODEL` set in the calling process: 67/0, and the variable was restored.

## 5. Mutation check

The suite was run from a temp copy (`scripts\test-registry.ps1`, `tests\fixtures`, and `scripts\lib\config.ps1` taken from `HEAD` before the library commit, i.e. without the registry):

- Result: exit 1, `Passed: 4`, `Failed: 66`.
- The 4 passing cases are exactly the ones about behavior that must not change: the wrapper on an empty configuration, v1 oddities, a blank explicit model, and a sanity check of the fixture formats. Every case that exercises new behavior failed (loader, golden table under v2, conversion, validation, selection rules, record, `think`).
- The temp copy was deleted afterwards.

## 6. Spec issues found

1. **AC-106 script part has no owner.** AC-106 asks that the three scripts still reject a blank `-Model` with "Model name cannot be empty.", but Affected Files lists AC-106 only for `test-registry.ps1` (in-process), not for `test-registry-callsites.ps1`. Not changed in the spec (out of the requested edits). Suggested fix: add AC-106 to the callsites row, or limit AC-106 to the function part.
2. **OD-105 cited "RK-105"; the risk is RK-104.** Fixed in revision 2 (and RK-105 now exists for another risk, the reviewer's options).
3. **FR-104 does not define the record's `profile` field for rules 2 and 4**, nor `-Model` for an agent with no registry entry. See the assumptions below.
4. **FR-103 is silent on** `safetyMarginRatio` validity, `ollama.healthTimeoutSec` validity, and non-object sections or entries.
5. **The two facts from the 2026-11-20 live runs are in no repository document:** "opposite verdicts in 1 of 5 runs" and "5,076 output tokens". Revision 2 records them as reported by the user. Only "1 good reviser output in 4" is recorded in `docs/audits/2026-11-19-model-validation-2.md`.
6. **Today's `Resolve-HarnessModel` returns a blank or null agent entry as is.** FR-105 requires "today's behavior", so the conversion keeps it (see assumptions).

## 7. Assumptions used (not requirements)

- **A-A1.** `config-v2-current.json` uses `reservedOutputTokens` 8192 for `deep` (the draft example said 6144). v1 has no such value, so it does not affect the golden equality; 8192 avoids a value the spec itself supersedes (OD-112).
- **A-A2.** The record's `profile` is the selected profile for `-Profile`, agent and default; for `-Model` and the variable it is the matched profile when exactly one profile has that model, otherwise empty. `parametersFrom` is the profile that supplied the parameters (the match, else the agent's profile, else the default profile, else empty). The fallback to the default profile for an agent with no entry follows the Edge Cases section.
- **A-A3.** v1 conversion order of profiles: models of `agentModels` in file order, then `defaultModel`. Models are told apart exactly (case included); a collision of names that differ only by case gets a `#2` suffix, so the v1 model string is always returned unchanged. A blank or null agent entry is kept (profile `legacy:` with a blank model), because today it is returned and does not fall back to the default.
- **A-A4.** v2 validation additions (messages start with the token, rule code first): `safetyMarginRatio` must be a number >= 0 (`safetyMarginRatio`); a non-object section, profile, agent entry or options object is `structure`; an agent entry without a valid profile is `agent_profile`; integers must be JSON integers (a string or `900.0` is rejected); `think` strings are compared case-sensitively; `schemaVersion` present with any value other than integer 2 (including null) is invalid; a missing `schemaVersion` means v1. `healthTimeoutSec` is not validated.
- **A-A5.** An unparsable `ollama.url` counts as non-loopback. Loopback means `localhost`, 127.0.0.1 and `::1` (the IPv6 host is compared as an address, because .NET expands `[::1]`).
- **A-A6.** The wrapper returns an explicit model before reading the configuration (as today), so an explicit model works even with a broken or invalid configuration. Every other path normalizes the configuration, so an invalid v2 file throws `registry_invalid:` there.
- **A-A7.** The record's `warnings` holds only the resolution warnings (`unregistered_model_override`); the registry's own warnings (`unknown_key:`, `non_loopback_ollama_url`) stay in `registry.warnings`. v1 files never produce warnings.
- **A-A8.** AC-106's "plus one extra profile" is built in TEMP from `config-v2-current.json` by the suite, not stored as another fixture.

## 8. Open items and notes for WP-1B

- **Empty `options` is truthy.** The record's `options` is always an object, empty when nothing is configured, and `if ([pscustomobject]@{})` is true in Windows PowerShell 5.1. Today `Invoke-HarnessGenerate` adds `options` to the body only when the value is not null. WP-1B must test for an empty object (`@($options.PSObject.Properties).Count -gt 0`) to keep the request body identical for a v1 file without `options`.
- **Raw values.** For a v1 file, `timeoutSec`, `stripThinking`, `ollamaUrl` and `options` are copied unvalidated and uncast, as today. Call sites keep their casts (`[int]`, `[bool]`) and `.TrimEnd('/')`.
- **Helper usage.** `Get-HarnessRegistryModels` must be wrapped in `@()` by its callers so that zero or one model still gives an array.
- **Not covered by any test yet:** child-process behavior (AC-104, AC-105 script part, AC-106 script part), the literal scan (AC-107), the benchmark default (AC-108), the live-suite model (AC-110), the migration (AC-113).
- **Risk RK-105 / AC-113** depend on a human-approved migration of `.ai/config.json`, which is the last commit of WP-1B.
- Open questions in the spec: none.
