# Phase 0 final QA report

**Date:** 2026-11-20
**Spec:** `specs/harness-phase-0-defect-corrections.md`, Revision 4 (commit `f1e1893` on branch `chore/phase0-final-qa`)
**Code under test:** `master` at `fdbb2ee` (Phase 0 baseline `2e85dbe`)
**Role:** independent QA. I did not implement any work package. Windows PowerShell 5.1, offline only: no Ollama, no `-IncludeLive`, no request to any server.

## 0. Scope and limits of this run (read first)

This was an unattended run with a 25-minute budget. **It overran that budget (about 35 minutes) and I stopped.** What was done and what was not:

| Done | Not done |
|---|---|
| Part A: spec Revision 4, validated, committed | Full line-by-line read of the three new suites (`test-validate-spec.ps1`, `test-mode-propagation.ps1`, `test-agent-telemetry.ps1`) and of the new mocks |
| Offline `test-all.ps1`, two runs, compared | Re-running the one-time checks (AC-017, AC-024 parse case, AC-026, AC-028). They rely on the WP reports |
| AC-018, AC-019, AC-020, AC-022, AC-029 checks | A mapping of each individual assertion to its AC |
| Review of the diff of the 7 modified production scripts and of the `test-all.ps1` diff | Review of the diff of the new suites, mocks and fixtures beyond grep checks |
| AC-031 grep inspection of the three permanent suites | Inspection of the AC-028 one-time script (it was a scratchpad and is not in the repository) |

Legend for the table: **PASS** = verified here by running or reading. **PASS\*** = the criterion is exercised by a suite that passed in my two runs, or by a one-time check recorded in a WP report; I did not re-derive it assertion by assertion or re-run the one-time check. **NOT VERIFIED** = not executable offline.

## 1. Part A: spec Revision 4

Edits made to the spec only, as requested:

- **Model references:** AC-019, the AC-020 deferred note, the FR-014 example, D-06, the Context table, A-03 and RK-05 no longer name `deepseek-r1:32b` as the configured reviewer. They now say "the model configured for `spec-reviewer` (currently `qwen3.6:35b`)" or use `<model>`. The remaining `deepseek-r1:32b` mentions are the historical "installed models" fact (2026-11-19) and the AC-018 historical-name list.
- **AC-018:** now "any model name from `.ai/config.json` and any of the historical names (`qwen2.5-coder:32b`, `qwen2.5-coder:7b`, `deepseek-r1:32b`)".
- **AC-017:** step 3 now says to compare with the same line endings. New FACT, with evidence from `docs/audits/2026-11-20-wp-d-implementation.md` sections 5 and 7: `git show` writes LF, the working tree has CRLF, PowerShell carries a script's line endings into here-string prompts, and the reviewer `system` hashes differ (`60CCC066…` against `FCA4F91A…`) with no code change.
- **A-02** marked VERIFIED (WP-D report, section 4); **A-07** marked VERIFIED (WP-C report, section 5); **A-06** left "to confirm".
- **Header:** the Status and "Applies to" lines now describe the baseline commit `2e85dbe` and the implemented state at `fdbb2ee`. Revision History row and a "Revision 4 changes" list were added. The Traceability Matrix is unchanged because no ID or `Verifies:` line changed.

**Validation:** `scripts\validate-spec.ps1` on the spec: `STATUS: PASS`, exit 0. Independent check (a separate script of mine, not the validator):

| Check | Result |
|---|---|
| `### FR/NFR/AC` heading IDs unique | 55 headings, 55 unique |
| Exactly one `Verifies:` line per AC | 31 ACs, 0 violations |
| Traceability Matrix equals the inverse of the `Verifies:` lines | 0 differences |
| Undefined IDs referenced | Only `FR-009` (retired in Revision 1), `FR-101`, `FR-105`, `FR-304`, `AC-103` (Phase 1+ audit IDs named in the Exclusions). All are deliberate, documented references |

## 2. Per-AC results

| AC | Result | Evidence |
|---|---|---|
| AC-001 | PASS\* | `test-validate-spec.ps1` passed in both runs (`Validator runs: 39`, `Passed: 54`, `Failed: 0`). Not mapped assertion by assertion |
| AC-002 | PASS\* | Same suite |
| AC-003 | PASS\* | Same suite. Code read: `validate-spec.ps1` exits 3 in documentation mode when Context is empty or `None`, after the required-sections check |
| AC-004 | PASS\* | Same suite. Code read: FR entries without AC entries add "No acceptance criteria found." |
| AC-005 | PASS\* | Same suite |
| AC-006 | PASS\* | Same suite |
| AC-007 | PASS\* | Same suite. Code read: the Source-annotation check applies only when numbered entries exist |
| AC-008 | PASS\* | Same suite. Code read: FR and AC sections must be `None` or contain entries (None marker is case-insensitive) |
| AC-009 | PASS | `test-spec.ps1` in the sandbox: `Passed: 17`, `Failed: 0`, `STATUS: PASS`, both runs |
| AC-010 | PASS\* | `test-mode-propagation.ps1` passed in both runs. Code read: `specify.ps1:106` inspects the validator once, `@validatorArgs` is used at both validator calls |
| AC-011 | PASS\* | Same suite |
| AC-012 | PASS\* | `test-agent-telemetry.ps1` passed in both runs |
| AC-013 | PASS\* | Same suite |
| AC-014 | PASS\* | Same suite. Code read: `lib/config.ps1:135` uses `-notcontains` (case-insensitive) |
| AC-015 | PASS\* | Same suite |
| AC-016 | PASS\* | Same suite |
| AC-017 | PASS\* | One-time check. WP-D report section 5 shows identical hashes for all four fields when line endings match. Independent partial evidence: the `review-spec.ps1` and `revise-spec.ps1` diffs contain no change to any prompt text, only the dot-source, the availability call and the two telemetry arguments. I did not re-run the hash comparison |
| AC-018 | PASS | `Select-String`-equivalent search of the three scripts for `qwen2.5-coder`, `deepseek-r1` and `qwen3`: no matches. Neither current config name (`qwen3.5:9b`, `qwen3.6:35b`) appears either |
| AC-019 | PASS | In the offline run: `[SKIPPED] test-spec-integration.ps1 ... requires Ollama and model 'qwen3.6:35b' (agent 'spec-reviewer'); use -IncludeLive`. No `test-all configuration` result |
| AC-020 | PASS (inspection) | `scripts/test-spec-integration.ps1:12-19`: `$modelWasProvided = $PSBoundParameters.ContainsKey('Model')`, `Resolve-HarnessModel -Agent "spec-reviewer"`, and `-Model` is passed to the reviewer only when given. **Deferred live run: NOT VERIFIED** |
| AC-021 | PASS | See section 3 |
| AC-022 | PASS, with notes | See section 4 |
| AC-023 | PASS\* | `test-mode-propagation.ps1` passed in both runs |
| AC-024 | PASS\* | Same suite for the permanent part. The one-time check against the `2e85dbe` `specify.ps1` is from the WP-C report (section 5), not re-run |
| AC-025 | PASS\* | `test-validate-spec.ps1` |
| AC-026 | PASS\* | Permanent part in `test-validate-spec.ps1`. The one-time full comparison against `2e85dbe` is from the WP-A report, not re-run |
| AC-027 | PASS\* | `test-agent-telemetry.ps1` |
| AC-028 | PASS\* | One-time check recorded in the WP-E report, not re-run. Partial independent evidence: the offline run with a valid config reports the SKIPPED detail with the resolved model, and the code of `Resolve-LiveSuiteModel` (`scripts/test-all.ps1:637`) wraps every step in `try/catch` and returns a reason string |
| AC-029 | PASS (inspection) | `scripts/lib/config.ps1:135` and `scripts/test-all.ps1:628` use `-notcontains`. A search for `-ccontains`, `-cnotcontains` and `-cin` in `scripts/` finds uses only in test assertions on harness lines and in `test-scan-repository.ps1`, never in model matching |
| AC-030 | PASS\* | `test-agent-telemetry.ps1` passed in both runs. I did not read all four guards line by line |
| AC-031 | PASS (partial inspection) | Search of the three permanent suites for `ADVERTENCIA`, `Exception.Message`, error-record text and `Write-Warning`: no assertion uses them. The matches are `ConvertFrom-Json` parsing of the suite's own files, a filter that drops stderr error records (`test-validate-spec.ps1:68`, `test-mode-propagation.ps1:96`, `test-agent-telemetry.ps1:363`), and the exception type name in a failure message (`test-mode-propagation.ps1:152`). Asserted lines (`Review Status: PASS`, `=== OLLAMA ERROR ===`, `Model not found: …`, the summary lines) are harness wording. The AC-028 one-time script was not inspected |

Count: 31 ACs. PASS: 7 (AC-009, 018, 019, 020 inspection part, 021, 022, 029), PASS\*: 24 (incl. AC-031 partial), FAIL: 0. NOT VERIFIED part: the deferred live run in AC-020.

## 3. AC-021: full offline `test-all.ps1`

Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\test-all.ps1`, run twice.

| | Run 1 | Run 2 |
|---|---|---|
| Exit code | 0 | 0 |
| Suites discovered / executed / passed / failed / skipped | 9 / 8 / 8 / 0 / 1 | 9 / 8 / 8 / 0 / 1 |
| `STATUS` | `PASS WITH SKIPS` | `PASS WITH SKIPS` |
| Skipped | `test-spec-integration.ps1` only | same |
| Tripwires | 8 of 8 `clean (214 entries before, 214 after)` | same |

After normalizing the timing values, the two outputs are identical (0 differing lines). The three new suites were discovered and passed: `test-validate-spec.ps1` (54 passed), `test-mode-propagation.ps1`, `test-agent-telemetry.ps1`. `test-syntax.ps1` passed. `git status --short` was clean afterwards, so the runs left no files in the repository.

## 4. AC-022: changed files since the baseline

`git diff --name-status 2e85dbe HEAD~1` (the state of `master`): 44 files, all accounted for.

| Group | Files | Count |
|---|---|---|
| **Phase 0, modified** (all 8 listed in "Affected Files") | `scripts/validate-spec.ps1`, `specify.ps1`, `lib/config.ps1`, `review-spec.ps1`, `revise-spec.ps1`, `test-spec-integration.ps1`, `test-all.ps1`, `test-spec.ps1` | 8 |
| **Phase 0, new** (all listed) | 3 suites, 12 fixtures, 6 mocks (`recording-*` ×5, `runner-documentation.ps1`) | 21 |
| **Phase 0, spec** | `specs/harness-phase-0-defect-corrections.md` | 1 |
| **Documentation** | 7 files in `docs/audits/` (WP reports, model validation, spec revision 3), `docs/handoff/2026-11-19-harness-context.md`, `docs/roadmap/modernization-roadmap.md` | 9 |
| **Config / housekeeping** | `.ai/config.json` (model changes, commits `61e8dcc`, `984eaba`), `.gitignore` (commits `b8cae9f`, `8ef5aae`, `fdbb2ee`) | 2 |
| **Housekeeping, deletions** | `scripts/lib/telemetry.ps1.bak`, `scripts/run-agent.ps1.bak`, `scripts/specify.ps1.bak` (commit `8ef5aae` "roadmap") | 3 |

Files outside both groups: **none**. Confirmed unchanged: `tests/mocks/validator-success.ps1`, `tests/mocks/validator-error.ps1`, `scripts/run-agent.ps1`, `scripts/lib/telemetry.ps1`, `scripts/benchmark-models.ps1` (no diff). No `.exe`, `.dll`, `.psd1`, `.psm1` or `.nupkg` is tracked.

Notes: the spec's Exclusions say removing tracked `.bak` files is "a separate decision". It was made in the roadmap commit, not by a Phase 0 work package, so it is housekeeping and not a Phase 0 violation. `specs/portfolio-*` and `specs/validation2-*` do not appear in the diff.

## 5. Review of the Phase 0 code diff

Scope: the diff of the 8 modified scripts (production and `test-all`, `test-spec*`) was read in full. The new suites, mocks and fixtures were **not** reviewed line by line (see section 0).

No bug, requirement violation, path escape or network use in tests was found in what was read. Findings:

| # | Severity | Location | Finding |
|---|---|---|---|
| 1 | nit | `scripts/test-spec-integration.ps1:15-19` | `Get-HarnessConfig` and `Resolve-HarnessModel` run at the top of the script, outside any `try/catch`. A missing config file or an unresolvable model ends the live suite with an unhandled error before any test runs. This only affects the live suite, which `test-all` already guards with FR-014. Acceptable, but the failure text will be a PowerShell error rather than a harness message |
| 2 | nit | `scripts/revise-spec.ps1:148-151` | On an availability failure the script prints the helper's messages and then `throw`s. The exit code is non-zero as FR-010 requires, but the user sees the same problem twice (once from `Write-Host`, once from the uncaught error). `review-spec.ps1:112-114` exits 2 cleanly. Cosmetic only |
| 3 | nit | `scripts/lib/config.ps1:116-139` | `Test-HarnessModelAvailable` both prints and returns the problem, and the caller tests the returned string for truthiness. It works, but the contract (empty = available) is only in a comment. A future edit that returns an empty problem text would be read as "available" |
| 4 | info | `scripts/lib/config.ps1:91-104` | Telemetry is written inside the `catch` before the rethrow. This is safe: `Write-HarnessModelTelemetry` has its own `try/catch`, so a logging failure cannot replace the original error. Matches FR-011 |
| 5 | info | `scripts/specify.ps1:106` | A validator path with `[` or `]`: documented limitation (A-05). Not a regression |

Checked and found correct: the validator keeps the requirements and baseline path unchanged (the old FR/AC/Source checks are only guarded with `-not $isDocumentation`); `specify.ps1` builds the validator arguments once and uses them at both call sites; the warning is printed with `Write-Host` and a literal `WARNING: ` prefix, only in documentation mode; the `test-all` live precondition uses `-notcontains`; a live table entry without exactly one of `Model` or `ModelAgent` is never executed; `Resolve-LiveSuiteModel` never throws and sends nothing; the sandbox entry for `test-mode-propagation.ps1` is present.

## 6. NOT VERIFIED

- The live reviewer suite `test-spec-integration.ps1` and the deferred part of AC-020 (needs Ollama and the `spec-reviewer` model).
- Real model behavior in documentation mode.
- Telemetry from a real Ollama response (all telemetry tests use a fake `Invoke-RestMethod`).
- `benchmark-models.ps1` (deferred to Phase 1).
- Re-execution of the one-time checks AC-017, AC-024 (parse case), AC-026 and AC-028: relied on the WP reports.
- Assertion-by-assertion mapping of the three new suites to their ACs, and a review of the new suites, mocks and fixtures.

## 7. Verdict

**Ready for human approval: YES, with the limits below.**

- **Blockers:** none found. No AC failed; both offline runs were identical, exit 0, `PASS WITH SKIPS`, every tripwire clean; no file outside the expected groups changed.
- **Conditions the approver should know:**
  1. The independent review of the new suites, mocks and fixtures was not completed (time limit). The 24 PASS\* rows rest on the suites passing and on the WP reports, not on my own reading of each assertion.
  2. The live suite and real-model behavior are NOT VERIFIED by design.
  3. The three `.bak` deletions in commit `8ef5aae` are housekeeping outside Phase 0.
- **Suggested follow-up (optional, not blocking):** a second, short review pass over `test-agent-telemetry.ps1` (the guards in FR-018) before relying on it as the only barrier against a real request.
