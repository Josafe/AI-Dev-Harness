# WP-A implementation report: documentation-mode validator

**Date:** 2026-11-20
**Spec:** [specs/harness-phase-0-defect-corrections.md](../../specs/harness-phase-0-defect-corrections.md), Revision 3 (commit `28f6f7a`)
**Scope:** Work Package A only: FR-001 to FR-007 and FR-016, verified by AC-001 to AC-008, AC-025 and AC-026, under NFR-001, NFR-002, NFR-003, NFR-004 and NFR-006.
**State:** all changes are in the working tree for human review. Nothing is staged, committed or pushed.

**Not done, as instructed:** Ollama was not started; no live test and no `-IncludeLive` run; the spec was not modified; WP-C, WP-D and WP-E were not started.

## 1. Summary

- `scripts/validate-spec.ps1` accepts `-Mode requirements|baseline|documentation`, defaulting to `requirements`.
  - **Without `-Mode`, or with `requirements` or `baseline`:** the old code path, unchanged. The output is byte-identical to `2e85dbe` on all 16 fixtures (section 5).
  - **With `documentation`:** applies FR-003 to FR-007.
- The new offline suite `scripts/test-validate-spec.ps1` has 54 assertions over 39 validator runs and passes. It fails against the old validator (34 of 54 assertions), so its passes mean something.
- **Offline `test-all`:** the same result as the baseline, plus the new suite as PASS. Every tripwire is clean.
- **Every in-scope AC is PASS** (section 4).
- **No blocking spec issue** was found. Section 6 lists four points of interpretation and two observations for the reviewer.

## 2. Files changed

| File | Status | Requirements |
|---|---|---|
| `scripts/validate-spec.ps1` | modified, 52 lines added and 5 changed | FR-001 to FR-007 |
| `scripts/test-validate-spec.ps1` | new | FR-016 |
| `tests/fixtures/documentation-none-spec.md` | new | AC-001, AC-002, AC-026 |
| `tests/fixtures/documentation-no-context-spec.md` | new | AC-003 |
| `tests/fixtures/documentation-empty-context-spec.md` | new | AC-003 |
| `tests/fixtures/documentation-fr-without-ac-spec.md` | new | AC-004 |
| `tests/fixtures/documentation-fr-with-ac-spec.md` | new | AC-005 |
| `tests/fixtures/documentation-invalid-source-spec.md` | new | AC-006 |
| `tests/fixtures/documentation-entry-without-source-spec.md` | new | AC-007 |
| `tests/fixtures/documentation-prose-fr-spec.md` | new | AC-008 |
| `tests/fixtures/documentation-prose-ac-spec.md` | new | AC-008 |
| `tests/fixtures/documentation-lowercase-none-spec.md` | new | AC-001, AC-025 |
| `tests/fixtures/documentation-fenced-none-spec.md` | new | AC-001, AC-025 |
| `tests/fixtures/documentation-none-period-spec.md` | new | AC-001, AC-025, AC-026 |

**`git status --short`:** ` M scripts/validate-spec.ps1` plus the 13 new files above as `??`. `git diff --stat` reports `scripts/validate-spec.ps1 | 57 +++++-`, 1 file changed.

**Compared with the spec's Affected Files for WP-A:** 14 changed, 14 expected, none extra, none missing. Unchanged: `tests/mocks/`, `scripts/test-all.ps1`, `scripts/specify.ps1`, `specs/`.

**File conventions:**

| File | Convention followed |
|---|---|
| `validate-spec.ps1` | CRLF only, no BOM, ASCII, no trailing newline, all as before |
| New fixtures | CRLF, ASCII, no trailing newline, like the existing fixtures |
| New suite | CRLF, ASCII, no BOM, like `test-spec.ps1` |

Git normalizes all of them to LF in the index (`core.autocrlf=true`), as it does for the existing files.

### How the validator change is built

1. **New parameter.** `[ValidateSet("requirements", "baseline", "documentation")][string]$Mode = "requirements"`, the same values as `specify.ps1`.
2. **`$isDocumentation`.** It guards the existing FR `None` exit 3 and the three existing content checks. In requirements and baseline modes each of these lines evaluates exactly as before, in the same order, with the same text.
3. **Documentation mode only:**
   - **Context check:** Context is captured and normalized the way FR already is. If it is empty or the None marker, the run exits 3 with the existing two insufficient-input lines (FR-004).
   - **FR-007:** the FR and AC sections must each be the None marker or contain a matching `### FR-n` or `### AC-n` entry. Otherwise the run fails with one of these messages:
     - `- Functional Requirements section must be None or contain at least one '### FR-n' entry.`
     - `- Acceptance Criteria section must be None or contain at least one '### AC-n' entry.`
   - **FR-005:** if `### FR-n` entries exist and there is no `### AC-n`, the run fails with the existing "No acceptance criteria found."
   - **FR-006:** "No requirement source annotations found." applies only when a `### FR-n`, `### NFR-n` or `### AC-n` entry exists. The invalid-Source check is unchanged and applies in every mode.
4. **No mode line is printed.** FR-002 allows one but doesn't require it, and leaving it out keeps the non-documentation output byte-identical.

## 3. test-all before and after (offline, no `-IncludeLive`)

| | Before (baseline, `HEAD` 28f6f7a, clean tree) | After |
|---|---|---|
| Discovered | 6 | 7 (adds `test-validate-spec.ps1`) |
| `test-syntax.ps1` | PASS, 0.4 s | PASS, 0.4 s (also parses the new suite) |
| `test-build-context.ps1` | PASS, 0.7 s | PASS, 0.6 s |
| `test-run-agent.ps1` | PASS, 1.9 s | PASS, 1.8 s |
| `test-scan-repository.ps1` | PASS, 2.6 s | PASS, 2.0 s |
| `test-spec.ps1` | PASS, 5.1 s | PASS, 5.2 s |
| `test-validate-spec.ps1` | — | **PASS, 11.7 s** |
| `test-spec-integration.ps1` | SKIPPED (NOT VERIFIED, needs Ollama) | SKIPPED (NOT VERIFIED, needs Ollama) |
| Summary line | `Suites discovered: 6 \| Executed: 5 \| Passed: 5 \| Passed with skips: 0 \| Failed: 0 \| Skipped: 1` | `Suites discovered: 7 \| Executed: 6 \| Passed: 6 \| Passed with skips: 0 \| Failed: 0 \| Skipped: 1` |
| Status and exit | `STATUS: PASS WITH SKIPS`, exit 0 | `STATUS: PASS WITH SKIPS`, exit 0 |
| Tripwire | not captured: only the summary tail of the baseline run was recorded | `clean (200 entries before, 200 after)` for every executed suite |

The only difference is the new suite, which appears as PASS. Timing differences are run-to-run noise.

## 4. Results per acceptance criterion

Evidence:

- **A.** The `scripts/test-validate-spec.ps1` run on its own (exit 0, `Passed: 54`, `Failed: 0`, `STATUS: PASS`) and inside offline `test-all` (PASS, tripwire clean).
- **B.** The AC-026 one-time comparison (section 5).
- **C.** The baseline run of the `2e85dbe` validator.

| AC | Result | What was run and checked |
|---|---|---|
| AC-001 | **PASS** | **A:** 24 cases (8 fixtures × no `-Mode`, `requirements`, `baseline`), with exit codes 1, 0, 0, 1, 3, 3, 3, 1 as in the spec's table. `-Mode foo` gives a non-zero exit with no `STATUS: PASS` line. **C:** the old validator gives the same codes (1, 0, 0, 1) for the four existing fixtures. |
| AC-002 | **PASS** | **A:** `documentation-none-spec.md` with `-Mode documentation` exits 0 and prints `STATUS: PASS`. The fixture has a descriptive Context, `None` in every optional section, and no `**Source:**` line. |
| AC-003 | **PASS** | **A:** `documentation-no-context-spec.md` (Context `None`) and `documentation-empty-context-spec.md` (empty Context) exit 3 and print `STATUS: INSUFFICIENT INPUT`. |
| AC-004 | **PASS** | **A:** `documentation-fr-without-ac-spec.md` exits 1 and prints `- No acceptance criteria found.` |
| AC-005 | **PASS** | **A:** `documentation-fr-with-ac-spec.md`, `minimal-valid-spec.md` and `semantic-invalid-spec.md` exit 0 in documentation mode. |
| AC-006 | **PASS** | **A:** `documentation-invalid-source-spec.md` exits 1 and prints `- Invalid requirement source: 'GUESS'. Allowed values: USER, PROJECT, FACT, ASSUMPTION.` |
| AC-007 | **PASS** | **A:** `documentation-entry-without-source-spec.md` exits 1 and prints `- No requirement source annotations found.` |
| AC-008 | **PASS** | **A:** `documentation-prose-fr-spec.md` exits 1 with the "Functional Requirements" message and without the AC one. `documentation-prose-ac-spec.md` exits 1 with the "Acceptance Criteria" message and without the FR one. |
| AC-025 | **PASS** | **A:** in documentation mode, `documentation-lowercase-none-spec.md` and `documentation-fenced-none-spec.md` exit 0. `documentation-none-period-spec.md` exits 1, prints the Functional Requirements message, and prints no `STATUS: INSUFFICIENT INPUT`. In non-documentation modes they exit 3, 3 and 1 (AC-001 cases), and `None.` gives the three errors (AC-026 case). |
| AC-026 | **PASS** | **A:** 15 exact line-sequence checks (5 fixtures × 3 non-documentation modes), after removing blank lines and the `File:` line; there is no mode line. **B:** the complete outputs of the old and new validator are identical on every fixture. |

**Non-functional requirements in scope:**

| NFR | Result | Evidence |
|---|---|---|
| NFR-001 | PASS | Windows PowerShell 5.1.26100 only. No module, package, executable or network service added. |
| NFR-002 | PASS | The suite opens no network connection and writes no files: it reads fixtures and runs from the temp folder. It has no mandatory parameters and ends with an explicit `exit`; `test-all`'s contract check passed. Its tripwire is clean. |
| NFR-003 | PASS | Without `-Mode` the validator keeps its parameters, exit codes and output (section 5). The only intentional change is the new optional `-Mode`. |
| NFR-004 | PASS | The changed files equal WP-A's Affected Files (section 2). Nothing was refactored or reformatted. |
| NFR-006 | PASS (by construction; AC-031 is checked in step 5) | The suite asserts only exit codes and exact validator lines, compared case-sensitively. Child stderr (PowerShell error records) is dropped and never asserted on. For `-Mode foo`, the suite checks only a non-zero exit and the absence of `STATUS: PASS`, not the localized binding-error text. |

**Mutation check (extra evidence, not an AC).** A scratchpad copy of the suite and fixtures was run against the `2e85dbe` validator. Result: exit 1, `Passed: 20`, `Failed: 34`.
- **Every documentation-mode case failed**, and so did every `requirements` or `baseline` case whose expected exit code is not 1. The old validator rejects `-Mode`, which gives exit 1.
- **The 20 that passed are the expected ones:**
  - every no-`-Mode` case
  - `-Mode foo`
  - the four `-Mode` cases whose expected exit code is already 1

## 5. AC-026 one-time comparison

**Method:**

1. `git show 2e85dbe:scripts/validate-spec.ps1` was written to a file in the session scratchpad (`<HOME>\AppData\Local\Temp\claude\…\scratchpad\wpa\`, outside the repository). The working-tree validator was identical to `2e85dbe` before the change (`git diff --quiet 2e85dbe -- scripts/validate-spec.ps1`).
2. Each of the 16 fixtures in `tests/fixtures/` was run through the old validator without `-Mode`, and through the changed validator three times: without `-Mode`, with `-Mode requirements` and with `-Mode baseline`.
3. Each pair was compared on exit code, complete stdout (bytes) and stderr.

**Result: ALL IDENTICAL, 48 of 48 comparisons.** Stderr was empty in every run.

| Fixture | Exit (old = new) | Stdout bytes | Stdout SHA-256 (first 12 hex) |
|---|---|---|---|
| documentation-empty-context-spec.md | 3 | 183 | 4bb0b9a96d25 |
| documentation-entry-without-source-spec.md | 1 | 174 | ce4a4c170499 |
| documentation-fenced-none-spec.md | 3 | 181 | 7315831e3d65 |
| documentation-fr-with-ac-spec.md | 0 | 144 | 6e3a2bc51578 |
| documentation-fr-without-ac-spec.md | 1 | 156 | c841fa17f53d |
| documentation-invalid-source-spec.md | 3 | 184 | 21671bb2b54d |
| documentation-lowercase-none-spec.md | 3 | 184 | 59c5bc31eb3c |
| documentation-no-context-spec.md | 3 | 180 | 1bf138bc5d2b |
| documentation-none-period-spec.md | 1 | 233 | a858c8679cf8 |
| documentation-none-spec.md | 3 | 174 | 09e99718abde |
| documentation-prose-ac-spec.md | 3 | 178 | d9d5ef6d2661 |
| documentation-prose-fr-spec.md | 1 | 230 | 820ff16d75d2 |
| invalid-spec.md | 1 | 283 | 89cf331d92a4 |
| minimal-valid-spec.md | 0 | 133 | 0b9833f27655 |
| semantic-invalid-spec.md | 0 | 136 | f186f301404f |
| valid-spec.md | 1 | 145 | fedc7044d530 |

Each row holds for all three runs of the changed validator. The baseline exit codes of the four existing fixtures (1, 0, 0, 1) match the spec's Context table.

## 6. Spec issues and interpretations

**No contradiction or blocking ambiguity was found.** Where the spec leaves wording or order open, I took the reading closest to existing behavior:

1. **The second line of documentation-mode insufficient input.** FR-004 fixes only exit 3 and `STATUS: INSUFFICIENT INPUT`. The validator reuses its existing second line ("The task did not contain enough information. See Open Questions."), so no new message was invented. No test asserts that line in documentation mode.
2. **The wording of the FR-007 messages.** The spec requires only that the message names the section. The chosen texts are quoted in section 2, and the suite asserts them exactly, so changing the wording later means changing the suite too.
3. **Check order in documentation mode:** required sections (exit 1), then Context (exit 3), then the content checks (exit 1). I read FR-004's "the required-sections check still runs first" as keeping the Context check where the FR `None` check sits today. So a spec with Context `None` and a prose FR section exits 3, not 1. No AC covers that combination.
4. **No mode line** (section 2, item 4). AC-026's filter allows one, so adding one later doesn't break the suite's line checks.

**Observations for the reviewer.** Neither breaks an AC, and I didn't change anything for them:

- **Last-section capture.** As the spec's Edge Cases require, a section that can't be captured counts as empty. The section pattern `(?=^## )` needs a following `## ` heading. A documentation-mode spec whose `## Acceptance Criteria` is the **last** section, after reordering, would fail FR-007 even with AC entries. Specs in template order are not affected.
- **Positional binding.** `-Mode` is the second parameter, so `validate-spec.ps1 <file> documentation` now selects documentation mode. Before, it failed with a binding error (exit 1). Only calls that used to fail behave differently, and every harness call uses named parameters.

**Your requirement "the suite must run in a temp directory", reconciled with FR-016 ("needs no sandbox").** The suite does `Push-Location` to the temp folder, writes nothing anywhere, and has no `test-all` table entry. Adding one would mean editing `test-all.ps1`, which is not a WP-A file.

## 7. Assumptions relied on

- **None of A-01 to A-07 is needed for WP-A.** They concern the workflow (WP-C), the fake HTTP layer (WP-D) or the live suite.
- **WP-A relies only on Context FACTs** (the current exit codes and the None-marker normalization). Both were re-checked here: in the baseline run, and in the comparison against `2e85dbe`.

## 8. Open items

- **WP-C has not started**, as instructed. AC-011 (the end-to-end documentation run with the real validator) depends on this WP and belongs to WP-C.
- **Checked later in Phase 0, not here:**
  - AC-009 (`test-spec.ps1` at `Passed: 17`), in WP-C. `test-spec.ps1` itself passes in the run above.
  - AC-021 (the full regression run with all three new suites), in step 5.
  - AC-031 (the NFR-006 inspection), in step 5.
- **The tripwire entry count of the baseline run** was not captured. Only the after-run counts are recorded (200 entries).
- **Human review and commit** are still to be done.
