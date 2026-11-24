# Phase 2: shipped `.ai/config.json` update (FR-217) and the AC-215 check

Branch `feat/phase2-config` (from `master` at `e691177`; `phase2-wp2d2` is an ancestor). Offline, no Ollama, no network, nothing pushed.

## 1. Commits

| # | Commit | Content |
|---|---|---|
| 1 | `4f39e1f` test(config): check the shipped .ai/config.json against the Phase 1 baseline (AC-215) | New suite `scripts/test-shipped-config.ps1` (auto-discovered by `test-all`). Committed with the config still unchanged: red by design. |
| 2 | `9de754d` feat(config): add the Phase 2 engine fields to the shipped configuration (FR-217) | `.ai/config.json`, the diff of section 2. |
| 3 | `6d357a3` test(config): accept the JSON number type of PowerShell 5.1 for charsPerToken (AC-215) | Test-only fix, see section 3. |

`git diff master --stat`: `.ai/config.json` (+5 -1) and `scripts/test-shipped-config.ps1` (+229 at commit time); this report is added after. No other file.

## 2. Diff applied (identical to section 7 of the WP-2D2 report)

```diff
   "ollama": {
     "url": "http://localhost:11434",
-    "healthTimeoutSec": 15
+    "healthTimeoutSec": 15,
+    "maxAttempts": 2,
+    "retryBackoffSec": 5,
+    "warmup": false
   },
@@
     "safetyMarginRatio": 0.10,
+    "charsPerToken": 3.5,
     "stripThinking": true
```

The file was edited at byte level: CRLF (the working-tree form under `core.autocrlf`) kept, no BOM, no change at the end of the file; `git diff` shows only these lines. No `budgetMode` key.

## 3. AC-215 evidence

The suite reads the real `.ai/config.json` and `tests/fixtures/config-v2-phase1-baseline.json`. Expectations are literals or come from the raw baseline JSON; the suite contains no model name. Seven cases:

1. The baseline has none of the four paths and no `budgetMode` (the expectations rest on it).
2. `ollama.maxAttempts` `Int32:2`, `retryBackoffSec` `Int32:5`, `warmup` the JSON boolean false, `defaults.charsPerToken` a JSON number equal to 3.5 (not a string).
3. No `budgetMode` path anywhere in the file.
4. Every leaf of the file equals the baseline leaf at the same path (model, `contextWindow`, `timeoutSec`, `reservedOutputTokens`, `think`, options, agents mapping, profiles, `safetyMarginRatio`, `stripThinking`, `url`, `healthTimeoutSec`), and the set of added paths is exactly the four. Empty objects and arrays count as leaves.
5. `Get-HarnessRegistry` loads with zero warnings (so no `unknown_key`) and carries the four values and `budgetMode` `warn`.
6. For the four agents, `Resolve-HarnessExecution` gives the same record (compared as JSON, plus model, `timeoutSec`, `think`, `contextWindow`, options one by one) as for the baseline file.
7. A reviewer-sized stub (25,638 characters) through `Test-AgentContextBudget` on the shipped registry: the mode asserted is `warn`; the status is data only. Recorded this run: `status=exceeded estTokens=7326 available=6553 over=773 mode=warn`. (The WP-2D2 report measured 7,325 / 772 with the real builders and a one-character specification; the stub is not the real prompt. Not asserted, WP-2E will change it.)

**Red before the change (the right reason).** Run against the unmodified file, before commit 2: 5 passed, 2 failed. Case 2: `maxAttempts : expected 'Int32:2', got '<absent>'`. Case 4: `added paths : expected '.defaults.charsPerToken,.ollama.maxAttempts,.ollama.retryBackoffSec,.ollama.warmup', got ''`. Commit 1 is therefore red on its own, and the history is not bisectable between commits 1 and 2 (same trade-off as in the WP-2D2 report).

**A mistake of mine, fixed in commit 3.** In the first version case 2 expected the parsed type `Double:3.5` for `charsPerToken`; Windows PowerShell 5.1 parses it as `Decimal`, so the suite was red after the config change. My command chain committed the config before I read that output, so commit 2 exists with the suite red at that point. Commit 3 checks "a JSON number (Decimal or Double), not a string, equal to 3.5". It is a test fix; the config is unchanged between commits 2 and 3. Commit 2 is not green on its own.

## 4. Mutation table

16 mutants, each a TEMP copy of the shipped file (CRLF, no BOM), run through `test-shipped-config.ps1 -ConfigPath <copy>` (the parameter defaults to the shipped file; `test-all` passes none). SHA-256 of `.ai/config.json` before and after the whole run: `F8E909727F27B79E65F63A173032EEFD40C40942FBFEC4F9C1D54883DED35217`, equal. The temp folder was removed. The script that generated the mutants lived in TEMP, not in the repository.

| # | Mutant | Result | Cases that failed (by number above) |
|---|---|---|---|
| 01 | model name changed (review profile) | KILLED | 4, 6 |
| 02 | `contextWindow` 16384 to 8192 (fast) | KILLED | 4, 6 |
| 03 | extra `defaults.budgetMode` | KILLED | 3, 4 |
| 04 | `charsPerToken` removed | KILLED | 2, 4 |
| 05 | `maxAttempts` 3 | KILLED | 2, 5 |
| 06 | `warmup` true | KILLED | 2, 5 |
| 07 | `spec-reviewer` profile review to deep | KILLED | 4, 6 |
| 08 | `profiles.deep.timeoutSec` removed | KILLED | 4, 6 |
| 09 | `retryBackoffSec` 6 | KILLED | 2, 5 |
| 10 | `maxAttempts` as the string `"2"` | KILLED | 2, 5, 6, 7 (loader rejects it) |
| 11 | `charsPerToken` 4 | KILLED | 2, 5 |
| 12 | `review.options.seed` 42 to 43 | KILLED | 4, 6 |
| 13 | one `think` changed to false | KILLED | 4, 6 |
| 14 | unknown extra key `ollama.colour` | KILLED | 4, 5 |
| 15 | `url` changed | KILLED | 4 |
| 16 | `stripThinking` false | KILLED | 4 |

16 of 16 killed (the task asked for 8). Mutants 15 and 16 are killed only by the leaf comparison, which is by design.

## 5. Counts

Baseline before any change: `test-all` 18 discovered, 17 PASS, 1 skipped, `PASS WITH SKIPS`.

After (two consecutive offline runs, both identical in outcome): 19 discovered, 18 executed, 18 PASS, 1 skipped (`test-spec-integration.ps1`, needs Ollama), `STATUS: PASS WITH SKIPS`; every tripwire clean (358 entries before and after); `git status` empty after each run.

| Suite | Before | After |
|---|---|---|
| test-agent-budget | 41 | 41 |
| test-agent-errors | 39 | 39 |
| test-agent-exec | 109 | 109 |
| test-agent-prompts | 23 | 23 |
| test-agent-telemetry-v2 | 34 | 34 |
| test-agent-telemetry | 23 | 23 |
| test-build-context | 15 | 15 |
| test-engine-callsites | 133 | 133 |
| test-mode-propagation | 11 | 11 |
| test-registry-callsites | 55 | 55 |
| test-registry-engine | 61 | 61 |
| test-registry | 86 | 86 |
| test-run-agent | 5 | 5 |
| test-scan-repository | 26 | 26 |
| test-spec | 17 | 17 |
| test-validate-spec | 54 | 54 |
| test-shipped-config (new) | - | 7 |

No existing count changed; `test-syntax` now checks 52 files (was 51: the new suite).

The suites `test-agent-prompts`, `test-registry*`, `test-registry-engine` and `test-engine-callsites` ran inside the two `test-all` runs above with the new configuration (all PASS); I did not run each of them a third time on its own.

**Which suites read the shipped file** (this corrects the premise of the task, which said none besides the new check does):

- `test-registry-engine.ps1`, `test-agent-prompts.ps1`, `test-agent-budget.ps1`: do not read it (their header says so for the first; they use fixtures).
- `test-registry-callsites.ps1` reads it: AC-107 (`Get-HarnessRegistryModels` of the shipped registry, for the no-model-name scan) and AC-113 (`Get-MigrationProblems` against the v1 raw data). Both still pass with the added keys.
- `test-engine-callsites.ps1` has `Get-HarnessConfig -ConfigPath (Join-Path $Root ".ai\config.json")` in its child-process host (line 347); I did not trace whether `$Root` there is the repository or the temporary harness root. It passes either way.
- `test-spec-integration.ps1` (skipped here) and `benchmark-models.ps1` read it at run time.

## 6. NOT VERIFIED

- Everything that needs Ollama: `test-spec-integration.ps1` (skipped), the real `Warning: budget_exceeded` numbers of the shipped configuration (the stub figure above is not the real prompt), whether `maxAttempts` 2 behaves well against a real model.
- That `test-registry-callsites.ps1` AC-113 and the `test-engine-callsites.ps1` host would catch a wrong value in the shipped file: they were not mutated here (the new suite is the check for the values).
- Behavior of the shipped file through `review-spec.ps1` and `revise-spec.ps1` end to end: their cases use synthetic configurations.
- PowerShell 7 (the numeric type check was written to accept `Double`; only Windows PowerShell 5.1 was run).
- The expected `budget_exceeded` warning on every real reviewer and reviser run (WP-2D2 report, section 7) is unchanged by this commit and still the owner's accepted behavior.
