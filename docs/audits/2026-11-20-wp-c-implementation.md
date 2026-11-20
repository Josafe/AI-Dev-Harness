# WP-C implementation report: passing `-Mode` through the workflow

**Date:** 2026-11-20
**Spec:** [specs/harness-phase-0-defect-corrections.md](../../specs/harness-phase-0-defect-corrections.md), Revision 3
**Starting point:** `HEAD` = `c06cbf9` (WP-A committed), clean working tree
**Scope:** Work Package C only: FR-008, FR-017 and FR-019, verified by AC-009, AC-010, AC-011, AC-023 and AC-024, under NFR-001, NFR-002, NFR-003, NFR-004 and NFR-006.
**State:** all changes are in the working tree for human review. Nothing is staged, committed or pushed.

**Not done, as instructed:** Ollama was not started; no live test and no `-IncludeLive` run; the spec was not modified; WP-D and WP-E were not started. The FR-014 changes to `test-all.ps1` (WP-E) were not made.

## 1. Summary

- **What `specify.ps1` now does:**
  - It checks once per run, without running the validator, whether the validator declares `Mode`.
  - Both validator calls use one shared argument splat. A validator that declares `Mode` gets `-Mode <mode>`; any other validator is called exactly as before, with `-SpecFile <file>` only.
  - In documentation mode, a validator without confirmed `-Mode` support gets one `Write-Host` warning line, with a literal `WARNING: ` prefix, and a summary note.
- **New suite:** `scripts/test-mode-propagation.ps1`, with 11 scenarios and six new mocks. It runs in a `test-all` sandbox and passes.
- **Mutation check:** against the `2e85dbe` `specify.ps1` the suite fails 7 of 11 scenarios. They are exactly the ones where `-Mode` isn't passed or the warning is missing.
- **A-07 is confirmed:** the `2e85dbe` `specify.ps1` exits 2 for a validator that fails to parse.
- **Offline `test-all`:** the same as the baseline plus the new suite as PASS. Every tripwire is clean.
- **Every in-scope AC is PASS** (section 4).
- **No spec ambiguity or contradiction blocked the work.** Section 7 lists the readings I took.

## 2. Files changed

| File | Status | Requirements |
|---|---|---|
| `scripts/specify.ps1` | modified: 42 lines added, 3 changed | FR-008, FR-019 |
| `scripts/test-all.ps1` | modified: 4 lines added, the sandbox entry only | FR-017 |
| `scripts/test-mode-propagation.ps1` | new | FR-017 |
| `tests/mocks/recording-runner.ps1` | new | FR-017 |
| `tests/mocks/recording-validator.ps1` | new | FR-017 |
| `tests/mocks/recording-validator-legacy.ps1` | new | FR-017, FR-019 |
| `tests/mocks/recording-reviewer.ps1` | new | FR-017 |
| `tests/mocks/recording-reviser.ps1` | new | FR-017 |
| `tests/mocks/runner-documentation.ps1` | new | AC-011 |

**`git status --short`:**

```text
 M scripts/specify.ps1
 M scripts/test-all.ps1
?? scripts/test-mode-propagation.ps1
?? tests/mocks/recording-reviewer.ps1
?? tests/mocks/recording-reviser.ps1
?? tests/mocks/recording-runner.ps1
?? tests/mocks/recording-validator-legacy.ps1
?? tests/mocks/recording-validator.ps1
?? tests/mocks/runner-documentation.ps1
```

This report is the tenth file. `git diff --stat` shows `scripts/specify.ps1 | 45`, `scripts/test-all.ps1 | 4`, and 2 files changed (46 insertions, 3 deletions).

**Compared with the allowed list:** 9 changed, 9 allowed (not counting this report), none extra, none missing.

**Unchanged:** `validator-success.ps1`, `validator-error.ps1`, `validate-spec.ps1`, `specs/` and `.ai/`. No `test-mock-mode-*` file was written into the repository's `specs/`.

**File conventions:**

| File | Convention |
|---|---|
| `specify.ps1` | Mixed line endings, preserved: 331 CRLF lines plus 12 bare-LF lines (8–10 and 102–110). The edits were applied byte-exactly with a scratchpad script that requires exactly one match per edit. New lines are CRLF. No trailing newline, as before. |
| `test-all.ps1` | LF only, as before. |
| New files | CRLF, ASCII, no BOM, like the existing mocks and suites. |

The git warning "LF will be replaced by CRLF" on these two files comes from LF lines they already had before WP-C.

### What changed in `specify.ps1`

1. **After the existing `Test-Path` checks (FR-008).**
   - `$validatorArgs = @{}`.
   - `Get-Command -Name $validator -CommandType ExternalScript -ErrorAction Stop` gives the same resolution as `&`, and only parses the script.
   - The result is classified:

     | Result | Classification | `<reason>` |
     |---|---|---|
     | `.Parameters` contains `Mode` (case-insensitive key match) | declared; `$validatorArgs.Mode = $Mode` | — |
     | `.Parameters` without `Mode` | "not declared" | — |
     | `.Parameters` is `$null` | "not confirmed" | `no parameter metadata` |
     | an exception is caught | "not confirmed" | the exception's type name |

   - The check is inside `try/catch`, so the script's `trap` never sees it and the run continues (FR-019).
   - `$validationSummary` becomes the FR-019 note only in documentation mode with a validator that isn't "declared".
2. **Just before Step 1:** in documentation mode, exactly one `Write-Host` line carrying the FR-019 "not declared" or "not confirmed" text, starting with `WARNING: `. `Write-Warning` is not used.
3. **Both invocation points** use `@validatorArgs`:
   - initial validation: `& $validator -SpecFile $specFile @validatorArgs`
   - revision validation: `& $validator -SpecFile $nextSpecFile @validatorArgs`
4. **The summary line** is `Validation   : $validationSummary`. Outside the FR-019 case that is `Validation   : PASS`, as before.

Nothing else changed: the exit codes, how validator exit codes are mapped, and the console markers are all as before.

## 3. test-all before and after (offline, no `-IncludeLive`)

| | Before (baseline, `HEAD` c06cbf9) | After |
|---|---|---|
| Discovered | 7 | 8 (adds `test-mode-propagation.ps1`) |
| `test-syntax.ps1` | PASS, 0.3 s | PASS, 0.3 s (also parses the 7 new files) |
| `test-build-context.ps1` | PASS, 0.6 s | PASS, 0.6 s |
| `test-mode-propagation.ps1` | — | **PASS, 3.9 s**, sandbox: 69 files copied, every SHA-256 verified, TEMP/TMP redirected; `Passed: 11`, `Failed: 0` |
| `test-run-agent.ps1` | PASS, 1.7 s | PASS, 1.5 s |
| `test-scan-repository.ps1` | PASS, 1.7 s | PASS, 1.8 s |
| `test-spec.ps1` | PASS, 4.2 s, `Passed: 17`, `Failed: 0` | PASS, 4.3 s, `Passed: 17`, `Failed: 0` |
| `test-validate-spec.ps1` | PASS, 10.2 s | PASS, 9.9 s, `Passed: 54`, `Failed: 0` |
| `test-spec-integration.ps1` | SKIPPED (NOT VERIFIED, needs Ollama) | SKIPPED (NOT VERIFIED, needs Ollama) |
| Summary line | `Suites discovered: 7 \| Executed: 6 \| Passed: 6 \| Passed with skips: 0 \| Failed: 0 \| Skipped: 1` | `Suites discovered: 8 \| Executed: 7 \| Passed: 7 \| Passed with skips: 0 \| Failed: 0 \| Skipped: 1` |
| Status and exit | `STATUS: PASS WITH SKIPS`, exit 0 | `STATUS: PASS WITH SKIPS`, exit 0 |
| Tripwire | clean, 201 entries, for every executed suite | clean, 208 entries (201 + 7 new files), for every executed suite |

The only difference is the new suite, which appears as PASS.

## 4. Results per acceptance criterion

Evidence:

- **A.** `scripts/test-mode-propagation.ps1` run on its own, from a scratchpad copy of `scripts/` and `tests/` so the repository's `specs/` is not touched: exit 0, `Passed: 11`, `Failed: 0`, `STATUS: PASS`, 4.2 s.
- **B.** The same suite inside offline `test-all` (sandbox): PASS, tripwire clean.
- **C.** Offline `test-all` (section 3).

Every scenario injects all four scripts through one function whose four script parameters are mandatory.

| AC | Result | Evidence |
|---|---|---|
| AC-009 | **PASS** | **C:** `test-spec.ps1` reports `Passed: 17`, `Failed: 0`, `STATUS: PASS` after the change. It injects the unchanged `validator-success.ps1` and `validator-error.ps1`, which don't declare `-Mode`. FR-015's removal of its parameter belongs to WP-E, so the suite file itself is unchanged here. |
| AC-010 | **PASS** | **A, B:** for `-Mode requirements`, `baseline`, `documentation` and no `-Mode`, `specify.ps1` exits 0 with the recording runner, validator, reviewer (FAIL, then PASS) and reviser. Each record is exactly `runner\|M`, `validator\|M`, `reviewer\|M`, `reviser\|M`, `validator\|M`, `reviewer\|M`, with M = `requirements` for the no-`-Mode` run. |
| AC-011 | **PASS** | **A, B:** `-Mode documentation` with `runner-documentation.ps1`, the real `validate-spec.ps1` (passed explicitly), `reviewer-pass.ps1` and `reviser-success.ps1` exits 0, with no line starting with `WARNING: `. The same run without `-Mode` exits 3 and prints `=== Specification Needs Human Input ===`. |
| AC-023 | **PASS** | **A, B:** with `runner-success`, the unchanged `validator-success`, `reviewer-pass` and `reviser-success`. **Documentation mode:** exit 0. Exactly one line starts with `WARNING: `, and it contains that prefix exactly once, "does not declare a -Mode parameter" and "documentation-mode validation rules are NOT applied". No `WARNING: WARNING:` appears anywhere. The summary line reads exactly `Validation   : PASS (validator called without -Mode; documentation-mode rules NOT applied)`. **Baseline mode:** exit 0, no `WARNING: ` line, and the summary line is exactly `Validation   : PASS`. |
| AC-024 | **PASS** | **A, B, simple validator:** documentation mode with `recording-validator-legacy.ps1` exits 0, and the record has exactly two validator entries, both `validator-legacy\|args=0`. **Validator that fails to parse**, generated under TEMP: with `-Mode requirements` and with `-Mode documentation`, the run exits 2 and the record is exactly the runner's entry. The requirements run prints no `WARNING: ` line. The documentation run prints exactly one, containing the prefix once, "support for -Mode could not be confirmed" and "documentation-mode validation rules are NOT applied", and not "does not declare". `<reason>` is not checked. **One-time check against `2e85dbe`:** section 5. |

**Non-functional requirements in scope:**

| NFR | Result | Evidence |
|---|---|---|
| NFR-001 | PASS | Windows PowerShell 5.1 only. Nothing added apart from scripts. |
| NFR-002 | PASS | No Ollama and no network: all four scripts are mocks or the real validator in every scenario. The suite writes only to its TEMP folder (record files and the generated validator, deleted at the end; none was left over) and, through `specify.ps1`, to `<root>\specs` inside the sandbox. It has no mandatory parameters and ends with an explicit `exit`. Tripwire clean. |
| NFR-003 | PASS | Exit codes, markers and exit-code mapping are unchanged. AC-009 passes (17 of 17) with validators that don't declare `-Mode`. Without `-Mode`, a validator that declares it now receives `-Mode requirements`, which is the intended FR-008 change; for the real validator this is byte-identical to calling it without `-Mode` (WP-A report, section 5). |
| NFR-004 | PASS | The changed files equal the allowed list (section 2). Nothing unrelated was touched. |
| NFR-006 | PASS (by construction; AC-031 is checked in step 5) | Assertions use only exit codes, record entries, and exact harness lines or harness phrases. Child stderr is dropped. The localized error text of the parse failure (A-07 output: `ERROR: En C:\…`) is never asserted on. |

### Sample output from the changed `specify.ps1`

Each sample is one physical line, shortened here only by `<HOME>…`:

```text
WARNING: Validator '<HOME>\…\tests\mocks\validator-success.ps1' does not declare a -Mode parameter. It is called without -Mode, so documentation-mode validation rules are NOT applied; the validator's own default rules are used instead.
Validation   : PASS (validator called without -Mode; documentation-mode rules NOT applied)

WARNING: Could not read the parameters of validator '<HOME>\…\validator-parse-error.ps1' (no parameter metadata), so support for -Mode could not be confirmed. It is called without -Mode, so documentation-mode validation rules are NOT applied; the validator's own default rules are used instead.

WARNING: Could not read the parameters of validator '<HOME>\…\validator.cmd' (CommandNotFoundException), so support for -Mode could not be confirmed. It is called without -Mode, so documentation-mode validation rules are NOT applied; the validator's own default rules are used instead.
```

The last line is an extra demonstration, not an AC: a `.cmd` validator in the scratchpad. It shows that the exception branch uses the exception type name. The `.cmd` was still called with only `-SpecFile <file>`. In requirements mode the same run printed no warning and `Validation   : PASS`.

## 5. A-07 one-time check (AC-024)

**Claim:** "A validator that fails to parse makes `specify.ps1` exit 2", for the unchanged `specify.ps1`.

**Method:**

1. `git show 2e85dbe:scripts/specify.ps1` was written into a scratchpad harness root (`<HOME>\AppData\Local\Temp\claude\…\scratchpad\wpc\a07\scripts\`), together with a copy of `tests/mocks/`.
2. The validator that fails to parse was the same content the suite generates: `param([Parameter(Mandatory = $true)][string]$SpecFile)` followed by `if ($true {`.
3. The run used `-Mode requirements` with `recording-runner`, `recording-reviewer` and `recording-reviser`, and `AI_HARNESS_TEST_RECORD_FILE` set.

**Result: TRUE.**
- The run exits **2**, and the record contains only `runner|requirements`.
- The output shows `Step 1`, then `Step 2`, then `=== Specification Workflow Failed ===` from the existing `trap`, with a localized `ERROR:` line.
- The changed `specify.ps1` gives the same exit code and record: AC-024 in the suite.

A-07 can be marked verified.

## 6. Mutation check

**Method:** the new suite was run from a scratchpad copy of `scripts/` and `tests/` in which `scripts/specify.ps1` was replaced by the `2e85dbe` version.

**Result:** exit 1, `Passed: 4`, `Failed: 7`, `STATUS: FAIL`.

| Scenario | Against `2e85dbe` | Why |
|---|---|---|
| AC-010 × 4 (requirements, baseline, documentation, no `-Mode`) | **FAIL** | Both validator entries are `validator\|(not passed)`: the old workflow never passes `-Mode` to the validator. The reviewer and reviser entries were correct, since they already received `-Mode`. |
| AC-011 documentation run with the real validator | **FAIL** | Exit was not 0: without `-Mode`, the real validator treats FR `None` as insufficient input (D-01). |
| AC-023 documentation | **FAIL** | No warning line and no summary note. |
| AC-024 parse failure, documentation | **FAIL** | No warning line. |
| AC-011 without `-Mode`, AC-023 baseline, AC-024 simple validator, AC-024 parse failure (requirements) | PASS | Expected: these describe behavior that is the same before and after WP-C. |

So the suite detects missing mode passing at both validator invocation points, and missing FR-019 output.

The recording mocks write `(not passed)` when `-Mode` isn't bound, rather than a default value. That is why even the requirements run detects missing mode passing.

## 7. Spec issues and interpretations

**No ambiguity or contradiction required stopping.** These are the readings I took; none changes an AC:

1. **"A file named by the environment variable `AI_HARNESS_TEST_RECORD_FILE`, under `TEMP`" (FR-017).** The variable holds the full path, and the suite places that path in a TEMP folder (the sandbox's redirected TEMP under `test-all`). The recording mocks stop with exit 1 and a message if the variable isn't set, rather than silently not recording.
2. **"FAIL on its first call per record file" (recording reviewer).** The mock counts earlier `reviewer|` lines in the record file. Each scenario deletes its record file first.
3. **Where the warning goes.** "Before Step 1" is met by printing it after the `=== Specification Workflow ===` header (Name, Model and Mode lines) and directly before `Step 1 - Generating specification...`. The parameter check itself runs right after the existing `Test-Path` checks, as FR-008 says.
4. **"No FR-019 warning" in AC-011, AC-023 (baseline) and AC-024 (requirements)** is asserted as: no output line starts with `WARNING: `.
5. **`runner-documentation.ps1` does not record.** The spec doesn't ask it to, and AC-011 checks only exit codes and output.
6. **The recording validator, reviewer and reviser declare `-Mode` without a default**, and record `(not passed)` when it is missing (section 6). The recording validator has no `ValidateSet`, which matches the Edge Case "declaring `Mode` means accepting the three harness values".

**Observations for the reviewer (no change made):**

- **The exception branch.** A missing validator path, including a missing `.cmd`, is still rejected first by the existing `Test-Path` check ("Specification validator not found", exit 2), so the parameter check never sees it. In practice the exception branch is reached by an existing non-`.ps1` file, such as the `.cmd` in section 4. The suite covers the `$null` branch (parse failure) but not the exception branch. No AC requires it.
- **A-06.** `no parameter metadata` is implemented as the spec states, and A-06 still marks it as "to confirm". No test checks it.

## 8. Assumptions used

| Assumption | How it was used |
|---|---|
| **A-01** (the injected scripts are test seams) | Used as the spec describes. FR-019 does not depend on it. |
| **A-05** (paths with `[` or `]` are not supported) | Unchanged. The new check passes the path to `Get-Command -Name` as given, so the existing `Test-Path` checks still reject such paths first. |
| **A-06** (`no parameter metadata`) | Implemented as written. |
| **A-07** | Verified true (section 5). |
| **A-02, A-03, A-04** | Not used by WP-C. |

**FACTs verified in this session before editing:**

- `.Parameters` matches `Mode` regardless of case, so a lowercase `$mode` counts as declared.
- An empty splat adds nothing to a simple script's `$args` (`args=0`).
- `Get-Command` on a missing file throws `CommandNotFoundException`.

## 9. Open items

- **WP-D and WP-E have not started**, as instructed. WP-E edits `test-all.ps1` again (FR-014), so it must keep the new `test-mode-propagation.ps1` entry.
- **AC-021** (the full offline regression run with all three new suites) and **AC-031** (the NFR-006 inspection) are checked in step 5. `test-agent-telemetry.ps1` (WP-D) doesn't exist yet.
- **A-07** can be marked verified in the spec's Assumptions when the spec is next revised. I did not edit the spec, as instructed.
- **Human review and commit** are still to be done.
