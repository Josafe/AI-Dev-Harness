# Phase 1 migration report: `.ai/config.json` to registry v2

Date: 2026-11-20
Branch: `feat/phase1-migration` (created from `feat/phase1-wp1b`; nothing pushed, merged, tagged or rebased)
Scope: one small fix, then the migration of `.ai/config.json` from v1 to registry v2.
Mode: unattended, offline. Ollama was not started, no live test was run, `-IncludeLive` was not used, and no request was sent to any server.

## 1. Summary

- The live-suite precondition (`Test-OllamaPrecondition` in `scripts/test-all.ps1`) now reads the Ollama URL from the normalized registry, so it works with both v1 and v2 files. A stray literal `\r\n` inside a comment in `scripts/lib/config.ps1` was removed.
- `.ai/config.json` was replaced by the registry v2 content given in the task (profiles `fast`, `deep`, `review`; four agents).
- Every agent keeps the same model, `timeoutSec` 900, `num_ctx` 16384, `stripThinking` and URL. The only behavior change is the effective options of `spec-reviewer`: `temperature 0.1` and `seed 42` instead of `temperature 0.2`.
- `test-all.ps1` (offline): 0 failures before and after every commit. AC-113 was skipped in the baseline and now executes against the real file and passes.
- Approval: the task prompt states that it is the explicit human approval for the migration required by the spec (OD-112 / WP-1B last commit). The prompt arrived through an automated channel, so a human should still read this report and the diff before merging.

## 2. The three commits

| # | Commit | Files |
|---|---|---|
| 1 | `fix(config): read the Ollama URL from the registry in the live-suite precondition` | `scripts/test-all.ps1`, `scripts/lib/config.ps1` |
| 2 | `feat(config): migrate .ai/config.json to registry v2 (fast, deep, review profiles)` | `.ai/config.json` |
| 3 | `docs(audits): add Phase 1 migration report` | this file |

`git diff --stat feat/phase1-wp1b..HEAD` before this report lists only `.ai/config.json` (+43/-11), `scripts/lib/config.ps1` (+2/-1) and `scripts/test-all.ps1` (+6/-5). `scripts/specify.ps1`, prompts, `.ai/agents`, `.claude`, `.gitignore`, the spec, other scripts, tests and fixtures are untouched.

### Commit 1 details

- `Test-OllamaPrecondition` now dot-sources `scripts\lib\config.ps1` (as `Resolve-LiveSuiteModel` does) and takes `(Get-HarnessRegistry -ConfigPath <repo>\.ai\config.json).ollama.url`, trimmed and without a trailing `/`. The `/api/tags` request, the "Ollama is not reachable at ..." message and the "model '...' is not installed at ..." message are unchanged.
- Any failure while reading the registry is swallowed and keeps the fallback URL `http://localhost:11434`. The function never throws.
- Behavior difference to be aware of: the old code returned `could not read .ai\config.json: <reason>` when the file could not be parsed. The task asked for the fallback URL on failure, so that message is no longer produced by this function. A broken configuration still surfaces earlier for suites that declare a `ModelAgent` (`Resolve-LiveSuiteModel` reports "model could not be resolved ... " and the suite is skipped or failed), but a suite without a `ModelAgent` would now proceed against the fallback URL.
- Comment fix: `# ... Callers wrap the\r\n# call in @() ...` became two normal comment lines.
- Byte-level check after editing: no BOM, no TAB, no literal `\r\n`. `scripts/test-all.ps1` stays LF only (CR=0). `scripts/lib/config.ps1` stays CRLF only (CR=LF=592). The size change of `config.ps1` is exactly -2 bytes (4 characters removed, one CRLF added).

### Commit 2 details

- UTF-8 without BOM, 2-space indentation, CRLF line endings and a final CRLF, matching the previous file (the working copy was CRLF, the index is LF through git's autocrlf). 1085 bytes, no TAB.
- The values are exactly those in the task. The JSON was reflowed for readability only (objects expanded over several lines; the four `agents` entries kept on one line each).
- The v1 file was saved outside the repository before the edit (`<TEMP>/phase1-migration/config.v1.json`) and used for the comparison below.

## 3. Resolution comparison (offline, in-process, no request)

Obtained by dot-sourcing `scripts\lib\config.ps1` and calling `Get-HarnessRegistry` and `Resolve-HarnessExecution` on the migrated file and on the saved v1 file. Options are the effective options. `think` is `default` everywhere. `stripThinking` is `True` in both registries. The URL (`http://localhost:11434`) and `healthTimeoutSec` (15) are identical in both.

### (a) Migrated file (v2)

| Agent | Model | Profile | modelSource | timeoutSec | Effective options |
|---|---|---|---|---|---|
| spec | qwen3.5:9b | fast | agent | 900 | num_ctx=16384; temperature=0.2 |
| spec-reviewer | qwen3.6:35b | review | agent | 900 | num_ctx=16384; seed=42; temperature=0.1 |
| spec-reviser | qwen3.6:35b | deep | agent | 900 | num_ctx=16384; temperature=0.2 |
| developer | qwen3.6:35b | deep | agent | 900 | num_ctx=16384; temperature=0.2 |
| not-in-file | qwen3.5:9b | fast | default | 900 | num_ctx=16384; temperature=0.2 |

### (b) Saved v1 file

| Agent | Model | Profile | modelSource | timeoutSec | Effective options |
|---|---|---|---|---|---|
| spec | qwen3.5:9b | legacy:qwen3.5:9b | agent | 900 | num_ctx=16384; temperature=0.2 |
| spec-reviewer | qwen3.6:35b | legacy:qwen3.6:35b | agent | 900 | num_ctx=16384; temperature=0.2 |
| spec-reviser | qwen3.6:35b | legacy:qwen3.6:35b | agent | 900 | num_ctx=16384; temperature=0.2 |
| developer | qwen3.6:35b | legacy:qwen3.6:35b | agent | 900 | num_ctx=16384; temperature=0.2 |
| not-in-file | qwen3.5:9b | legacy:qwen3.5:9b | default | 900 | num_ctx=16384; temperature=0.2 |

### What differs

- Profile names: v1 yields synthesized `legacy:<model>` profiles, v2 yields `fast` / `deep` / `review`. This is a label, not a behavior change.
- `spec-reviewer` effective options: `temperature 0.2` becomes `temperature 0.1` and `seed 42` is added. This is the only change in model, timeout, options, think, stripThinking or URL.
- Metadata only: for v2 the execution also carries `contextWindow` 16384 and `reservedOutputTokens` (4096 for `fast`, 8192 for `deep`/`review`); for v1 these are empty. A search of `scripts/` found these names only in `scripts/lib/config.ps1` and the two registry test suites, so no call site consumes them yet and the effective `num_ctx` is the same (16384).
- No warnings were produced for any agent in either file.

### Override rules on the migrated file

| Call | Result |
|---|---|
| `spec-reviewer -Model qwen3.5:9b` | model qwen3.5:9b, profile fast, modelSource `explicit-model`, options num_ctx=16384; temperature=0.2 (the profile's parameters, not the review profile's) |
| `spec-reviewer` with `AI_HARNESS_MODEL=env-model:1b` | model env-model:1b, modelSource `env`, profile empty, options of the agent's own profile (seed=42; temperature=0.1) kept |
| `spec` with `AI_HARNESS_MODEL` set, v1 file | model env-model:1b, modelSource `env`, options temperature=0.2 |
| `spec-reviewer -Model qwen3.5:9b` with `AI_HARNESS_MODEL` set | model qwen3.5:9b, modelSource `explicit-model` (explicit `-Model` beats the environment variable) |
| `spec -Profile review` | model qwen3.6:35b, profile review, modelSource `explicit-profile`, seed=42; temperature=0.1 |
| `developer -Profile fast` | model qwen3.5:9b, profile fast, modelSource `explicit-profile` |
| `spec -Profile nope` | rejected: `registry_invalid: unknown_profile (-Profile 'nope' is not a profile)` |
| `spec -Model qwen3.5:9b -Profile review` | rejected: `invalid_arguments: -Model and -Profile cannot be used together.` |

`AI_HARNESS_MODEL` was unset in the parent session, was set only inside a child process for the check, and is unset afterwards.

## 4. `test-all.ps1` before and after (offline, no `-IncludeLive`)

Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\test-all.ps1`. Every run exited 0 and every suite reported its tripwire as clean (236 entries before and after).

| Run | Executed | Passed | Passed with skips | Failed | Skipped | Final status |
|---|---|---|---|---|---|---|
| Baseline (before any edit) | 10 | 9 | 1 | 0 | 1 | PASS WITH SKIPS |
| After commit 1 | 10 | 9 | 1 | 0 | 1 | PASS WITH SKIPS |
| Migrated file, before committing it | 10 | 10 | 0 | 0 | 1 | PASS WITH SKIPS |
| After commit 2 | 10 | 10 | 0 | 0 | 1 | PASS WITH SKIPS |

The overall status stays `PASS WITH SKIPS` because `test-spec-integration.ps1` is a live suite and is skipped offline (NOT VERIFIED).

Per-suite assertion counts (baseline, then after commit 2): agent-telemetry 23 / 23, build-context 15 / 15, mode-propagation 11 / 11, registry-callsites 51 (+ AC-113 skipped) / 52, registry 67 / 67, run-agent 5 / 5, scan-repository 26 / 26, spec 17 / 17, validate-spec 54 / 54. `test-syntax.ps1` passes in all runs (it prints no count).

## 5. AC-113

- Baseline: skipped, because the repository file was still v1 ("INTERNALLY SKIPPED ASSERTIONS: test-registry-callsites.ps1: AC-113").
- After the migration, `scripts\test-registry-callsites.ps1` alone: exit 0, `Passed: 52`, `Failed: 0`, `SKIPPED_TESTS: none`, `STATUS: PASS`. The section "AC-113 the migrated .ai\config.json" executed 10 assertions: "the repository .ai\config.json keeps every model and changes only the reviewer's options" plus nine checker self-tests (the checker accepts a configuration generated from the v1 fixture and rejects eight mutations such as reviewer temperature 0.2, no seed, developer on `fast`, missing `review` profile, changed timeout).

## 6. Offline test of the precondition fix

A faithful test inside the repository's suites was not possible without editing files outside the allowed ones. Instead, a throwaway script outside the repository extracted `Test-OllamaPrecondition` from `scripts/test-all.ps1` by AST, shadowed `Invoke-RestMethod` with a stub (so no request was ever made) and recorded the URI the function would request. Results:

| Configuration | URI requested | Result |
|---|---|---|
| v2 with `ollama.url` `http://example.invalid:1234/` | `http://example.invalid:1234/api/tags` | installed model accepted; missing model message names that URL |
| v1 with `ollamaUrl` `http://example.invalid:5678/` | `http://example.invalid:5678/api/tags` | same, with that URL |
| invalid JSON | `http://localhost:11434/api/tags` (fallback) | no throw |
| no file | `http://localhost:11434/api/tags` (fallback) | no throw |
| v2 without `ollama` | `http://localhost:11434/api/tags` (fallback) | no throw |

This check is not part of the repository (no test file was added, per the allowed-files rule). It should be treated as an inspection plus an ad-hoc offline probe, not as a regression test.

## 7. What changed in behavior

1. `spec-reviewer` runs with `temperature 0.1` and `seed 42` instead of `temperature 0.2`. All other agents are unchanged in model, timeout, options and URL.
2. `scripts/test-all.ps1` live-suite precondition now follows the registry URL (v1 or v2) and no longer reports `could not read .ai\config.json` from that function (see commit 1 details).
3. The `-Model`/`-Profile`/`AI_HARNESS_MODEL` override rules are unchanged by the migration (section 3).

## 8. How to revert

- Revert the migration only: `git revert <migration commit>` (the `feat(config): migrate .ai/config.json ...` commit). The resulting `.ai/config.json` is identical to the saved v1 file (verified by comparing the pre-migration blob with the saved copy, ignoring CR), and every loader version accepts v1. The fix in commit 1 does not depend on the migration (checked above with a v1 URL).
- Revert the fix only: `git revert <fix commit>`; the precondition then goes back to reading only the v1 key `ollamaUrl`, which a v2 file does not have (it would silently use the fallback URL).

## 9. NOT VERIFIED

- Any live Ollama behavior: nothing was sent to Ollama, `test-spec-integration.ps1` was not run, and the models were not loaded.
- Whether Ollama honors `seed` together with `temperature 0.1` for `qwen3.6:35b` on this machine, and the effect of `seed`/`temperature` on verdict stability of the reviewer.
- `scripts/benchmark-models.ps1` with the migrated file (not run).
- Behavior of `review-spec.ps1`, `revise-spec.ps1`, `run-agent.ps1` and `specify.ps1` against the real file beyond what the offline suites exercise (their call sites are covered by `test-registry-callsites.ps1` through fixtures and stubs).

## 10. Open points

- Decide whether `Test-OllamaPrecondition` should report an unreadable configuration instead of silently falling back (the task asked for the fallback, so that was implemented).
- `contextWindow`, `reservedOutputTokens` and `safetyMarginRatio` are loaded but not yet consumed by any call site.
- The final QA of Phase 1 was not started, per the task.
- Untracked `*.bak` and `*.bak-mode` files exist in `scripts/` (ignored or pre-existing); they were not touched.
