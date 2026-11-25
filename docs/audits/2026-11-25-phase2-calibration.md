# Phase 2 calibration of the shipped `.ai/config.json` (WP-2E follow-up, decision D-211)

Branch `feat/phase2-calibration` (from `master` at `d2e91f3`; tag `phase2-wp2e` is an ancestor). Offline, no Ollama, no network, nothing pushed. Prompts and script/lib code untouched.

## 1. Verdict

The three values are applied and the shipped-config suite (7 cases) passes. **`scripts\test-all.ps1` is NOT green: one Phase 1 suite, `test-registry-callsites.ps1` (case AC-113), still pins `reservedOutputTokens` 8192 for `deep` and `review`** (section 5). Editing it is outside the file list this task authorised, so I stopped there. It needs an owner decision before the branch can be pushed as green.

## 2. Commits (local, in order)

| # | Commit | Content |
|---|---|---|
| 1 | `8bbc234` test(config): pin the WP-2E calibrated values in the shipped-config suite (D-211) | `scripts/test-shipped-config.ps1` only. Committed with the config unchanged: red by design. |
| 1b | `4c5c059` test(config): compare the registry charsPerToken numerically (D-211) | One-line test fix (my mistake, below). Config unchanged. |
| 2 | `fbca0a8` feat(config): calibrate charsPerToken and reservedOutputTokens from the live measurements (WP-2E) | `.ai/config.json`: exactly three value changes. |
| 3 | `e63e2e9` docs(spec): record the WP-2E calibration of the shipped configuration (revision 3.5, D-211) | Spec text only. |
| 4 | this report | `docs/audits/2026-11-25-phase2-calibration.md` |

`git diff master --stat`: `.ai/config.json` (+3 -3), `scripts/test-shipped-config.ps1`, `specs/harness-phase-2-shared-engine.md` and this report. No other file.

**Mistake of mine (commit 1b).** In commit 1 the registry case compared the decimal 4.0 as a string with `"4"` (`-ceq`), which fails once the value is `4.0`. I saw it when I first ran the suite against the edited config (6 of 7 passing), fixed it as its own commit and applied the config afterwards, so commit 2 is green for the suite. Commit 1 alone is red by design.

## 3. Step 1: the suite, red against the unchanged config (the right reasons)

Run against the unmodified file (commit 1 state): 3 passed, 4 failed.

- Case 2: `charsPerToken is 4.0 (D-211) : condition is false` (the file has 3.5).
- Case 4: `calibrated .profiles.deep.reservedOutputTokens expected Int32:6144, got Int32:8192; calibrated .profiles.review.reservedOutputTokens expected Int32:6144, got Int32:8192`.
- Case 5: `charsPerToken : expected '4', got '3.5'`.
- Case 6: `spec-reviewer reservedOutputTokens : expected '6144', got '8192'`.
- Cases 1, 3 and 7 (baseline sanity, no `budgetMode`, stub budget) passed.

What changed in the suite: the literal `4.0` (JSON number, not a string); case 4 allows exactly two deviations from the Phase 1 baseline, `.profiles.review.reservedOutputTokens` and `.profiles.deep.reservedOutputTokens`, each the literal `Int32:6144` (and fails if either still equals the baseline, so the deviation must be real); case 6 compares every field of the execution record except `reservedOutputTokens`, one by one, and checks `reservedOutputTokens` against literals by the baseline's profile of the agent (review 6144, deep 6144, fast 4096). The stub-budget case still asserts only the mode `warn`; its status is printed as data. After the change: 7 of 7 pass, stub data `status=ok estTokens=6410 available=8601 over=0 mode=warn`.

## 4. Step 4: before and after `Test-AgentContextBudget` for the measured cases

Method: for each of the 16 prompts of section 4.1 of the WP-2E report, `prompt_chars` and `prompt_eval_count` come from `docs/audits/data/2026-11-25-wp2e-resume/telemetry-rows.csv`; the agent's execution record and the budget come from the real registry of the old file (`master`) and of the new file, with a stub of `prompt_chars` characters (only the length matters). S = 1,639 (10 % of 16,384). `warn` prints `budget_exceeded` when the status is `exceeded`. "Real fit" = real count + R + S <= 16,384 with the new R. Every one of the 16 calls was `success`, `done_reason` stop, in the measured run.

| Label | Agent (profile) | chars | Real tokens | Est. old (3.5) | Avail. old | Warn old | Est. new (4.0) | Avail. new | Warn new | Real fit (new R) | Measured outcome |
|---|---|---|---|---|---|---|---|---|---|---|---|
| rev-invalid-1 | reviewer (review) | 26,431 | 4,986 | 7,552 | 6,553 | yes | 6,608 | 8,601 | **no** | yes (12,769) | ok, 4,296 out |
| rev-valid-1 | reviewer | 26,386 | 4,971 | 7,539 | 6,553 | yes | 6,597 | 8,601 | **no** | yes | ok, 1,699 out |
| cal-rev-2k | reviewer | 27,786 | 5,279 | 7,939 | 6,553 | yes | 6,947 | 8,601 | **no** | yes | ok, 3,001 out |
| cal-rev-8k | reviewer | 33,939 | 6,737 | 9,697 | 6,553 | yes | 8,485 | 8,601 | **no** | yes (14,520) | ok, 2,142 out |
| cal-rev-16k | reviewer | 41,770 | 8,573 | 11,935 | 6,553 | yes | 10,443 | 8,601 | yes (over 1,842) | yes by 28 tokens (16,356) | ok, `possible_prompt_truncation` printed, 3,102 out |
| reviser-1 | reviser (deep) | 29,441 | 5,649 | 8,412 | 6,553 | yes | 7,361 | 8,601 | **no** | yes | ok, 1,779 out |
| cal-reviser-2k | reviser | 30,800 | 5,943 | 8,800 | 6,553 | yes | 7,700 | 8,601 | **no** | yes | ok, 1,524 out |
| cal-reviser-8k | reviser | 36,953 | 7,401 | 10,558 | 6,553 | yes | 9,239 | 8,601 | yes (over 638) | yes (15,184) | ok, 3,665 out |
| cal-reviser-16k | reviser | 44,784 | 9,237 | 12,796 | 6,553 | yes | 11,196 | 8,601 | yes (over 2,595) | **no** (17,020) | ok, `possible_prompt_truncation` printed, 1,908 out |
| spec-1 | spec (fast) | 29,247 | 5,384 | 8,357 | 10,649 | no | 7,312 | 10,649 | no | yes | ok |
| dev-small | developer (deep) | 14,776 | 3,116 | 4,222 | 6,553 | no | 3,694 | 8,601 | no | yes | ok |
| cal-dev-task12k | developer | 25,899 | 5,638 | 7,400 | 6,553 | yes | 6,475 | 8,601 | **no** | yes | ok, 2,619 out |
| cal-dev-ctx-en | developer | 22,123 | 4,773 | 6,321 | 6,553 | no | 5,531 | 8,601 | no | yes | ok |
| cal-dev-ctx-code | developer | 22,125 | 4,932 | 6,322 | 6,553 | no | 5,532 | 8,601 | no | yes | ok |
| cal-dev-ctx-es | developer | 22,123 | 5,196 | 6,321 | 6,553 | no | 5,531 | 8,601 | no | yes | ok |
| cal-dev-ctx-ca | developer | 22,123 | 5,627 | 6,321 | 6,553 | no | **5,531** | 8,601 | no | yes (13,410) | ok |

(Raw output of the evidence script: `chars|real|est old|avail old|status old|est new|avail new|status new|over|real fit new R|real fit old R` for each label; the script lived in `%TEMP%`, not in the repository.)

**Findings.**

- **No longer warn (7 of the 10 that warned):** the fixture-size reviewer (both fixtures), the 2 KB and 8 KB reviewer, the fixture-size reviser, the 2 KB reviser and the 12 KB-task developer. All of them fit in reality. The 8 KB reviewer passes by 116 tokens (8,485 against 8,601), so it is near the edge.
- **Still warn (3):** the 16 KB reviewer, the 8 KB reviser and the 16 KB reviser. The first two are still **false positives** (real fit yes: 16,356 and 15,184), the 16 KB reviser is a **true positive by the formula** (17,020 > 16,384) although the call worked (it printed `possible_prompt_truncation`; the output was 1,908 tokens, far below R). Section 12 of the WP-2E report predicted exactly these.
- **Never warned, before or after:** `spec`, the 826-char developer and the four developer-with-context prompts.
- **Under-estimation:** at 4.0 the estimate is below the real count for one prompt only, the Catalan developer case: 5,531 against 5,627 (96 tokens, 1.7 % low). It still fits with a wide margin (13,410 of 16,384), and no warning is expected or wrong there. The 16 KB Catalan specification case argued in section 4.4 of the WP-2E report (error about 1,460 tokens, below S = 1,639) is not a measured case.
- The formula is conservative by construction: it assumes the output uses all of R. The measured outputs (at most 4,296 tokens) never came near 6,144.

## 5. Why `test-all` is not green (blocker, owner decision needed)

`scripts\test-all.ps1`, offline, once, after commit 3: 19 discovered, 18 executed, **17 PASS, 1 FAIL**, 1 skipped (`test-spec-integration.ps1`, needs Ollama); `STATUS: FAIL`; `FAILED_SUITES: test-registry-callsites.ps1`; tripwire clean in every suite (368 entries before and after); `git status` empty after the run. Baseline before any change on this branch: 19 / 18 PASS / 1 skipped, `PASS WITH SKIPS`.

The failing case, from the suite output:

```
[FAIL] AC-113 the repository .ai\config.json keeps every model and changes only the reviewer's options
       profile deep reservedOutputTokens is not 8192; profile review reservedOutputTokens is not 8192
```

Cause: `scripts/test-registry-callsites.ps1` (a Phase 1 suite) pins the migrated file in its helper `Get-MigrationProblems` (line 478: `$reserved = [ordered]@{ "fast" = 4096; "deep" = 8192; "review" = 8192 }`) and builds its generated "good" configuration with 8192 (lines 516 and 523). Its mutation list even has a case "deep reservedOutputTokens is 6144" (line 865) that expects the checker to reject 6144. The task named `test-shipped-config.ps1` as the suite that pins the old values and limited the diff to four files, so I did **not** edit this suite. (The Phase 2 config report, section 5, said this suite reads the shipped file for AC-113 but did not note that it pins `reservedOutputTokens`.)

Options for the owner:

1. **Edit `Get-MigrationProblems` and the generated good configuration** in `test-registry-callsites.ps1` to the calibrated 6144 (and turn the line-865 mutation into one that uses a value other than 6144, for example 8192, which must now be rejected). One small commit, then `test-all` should be `PASS WITH SKIPS` again. This is my recommendation: AC-113 is about "models kept, only the reviewer's options changed", so the reserved values it pins are a leftover of the Phase 1 numbers, not part of its intent.
2. Leave the Phase 1 check at 8192 and do not apply the calibration (not recommended: the owner already decided D-211).

Until then the branch has a red suite and should not be merged. I did not run `test-all` a second time: the failure is deterministic and caused by one assertion (the suite counts of every other suite were identical to the baseline; `test-shipped-config` is 7, as before).

## 6. Mutation proof of the shipped file

20 mutants, each a TEMP copy of the new shipped file (CRLF, no BOM), run through `test-shipped-config.ps1 -ConfigPath <copy>`. SHA-256 of `.ai/config.json` before and after the whole run: `91171725CB873E3DCCE5E8D10EAAC66DD1A414DD645586F648B80BCECCF535DC`, equal; the temp folder was removed; the generator lived in `%TEMP%`.

| # | Mutant | Result | Cases failed (of 7) |
|---|---|---|---|
| M01 | `charsPerToken` reverted to 3.5 | KILLED | 2, 5 |
| M02 | `charsPerToken` 4.5 | KILLED | 2, 5 |
| M03 | `charsPerToken` as the string `"4.0"` | KILLED | 2, 5, 6, 7 |
| M04 | `review` `reservedOutputTokens` reverted to 8192 | KILLED | 4, 6 |
| M05 | `deep` `reservedOutputTokens` reverted to 8192 | KILLED | 4, 6 |
| M06 | `fast` `reservedOutputTokens` 4096 to 6144 | KILLED | 4, 6 |
| M07 | `deep` `reservedOutputTokens` 7000 | KILLED | 4, 6 |
| M08 | extra `defaults.budgetMode` `"enforce"` | KILLED | 3, 4, 5, 7 |
| M09 | extra `defaults.budgetMode` `"warn"` | KILLED | 3, 4 |
| M10 | `fast` `contextWindow` 32768 | KILLED | 4, 6 |
| M11 | `review` `contextWindow` 32768 | KILLED | 4, 6 |
| M12 | `fast` model changed | KILLED | 4, 6 |
| M13 | `warmup` true | KILLED | 2, 5 |
| M14 | `fast` `think` false | KILLED | 4, 6 |
| M15 | `maxAttempts` 3 | KILLED | 2, 5 |
| M16 | `spec-reviser` profile deep to fast | KILLED | 4, 6 |
| M17 | `spec-reviewer` profile review to deep (same R, different options) | KILLED | 4, 6 |
| M18 | `review` `seed` 42 to 43 | KILLED | 4, 6 |
| M19 | unknown extra key `ollama.colour` | KILLED | 4, 5 |
| M20 | `review` `reservedOutputTokens` removed | KILLED | 4, 6 |

20 of 20 killed (the task asked for 8). M08 to M11 and M13 to M15 prove that `budgetMode`, every `contextWindow`, `warmup`, `think` and `maxAttempts` stay as they were.

## 7. The diff of the configuration

```diff
-    "charsPerToken": 3.5,
+    "charsPerToken": 4.0,
@@ profiles.deep
-      "reservedOutputTokens": 8192,
+      "reservedOutputTokens": 6144,
@@ profiles.review
-      "reservedOutputTokens": 8192,
+      "reservedOutputTokens": 6144,
```

CRLF kept, no BOM, no other byte changed. The spec text (revision 3.5) says the same in FR-217, AC-215, "Affected Files", a note at OQ-201 and the new decision D-211; `scripts\validate-spec.ps1` PASS; the `Verifies:` lines and the traceability matrix are untouched. The code default of `charsPerToken` (3.5, used when the key is absent) is unchanged on purpose.

## 8. NOT VERIFIED

- Anything that needs Ollama: no call was made, the "measured outcome" column is the WP-2E data, not a new run. The new `reservedOutputTokens` 6144 with long developer answers (prompt plus output above the window) was not measured in WP-2E either.
- A second `test-all` run (see section 5).
- That the new `warn` lines print as predicted on a real run: they are computed with `Test-AgentContextBudget` on stubs of the real prompt length, not on the real prompts.
- PowerShell 7 (Windows PowerShell 5.1 only).