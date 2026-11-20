# Phase 0 spec, Revision 3: report

**Date:** 2026-11-20 (the file name keeps the 2026-11-19 series the request named)
**Spec:** [specs/harness-phase-0-defect-corrections.md](../../specs/harness-phase-0-defect-corrections.md)
**Repository state:** `HEAD` = `8ef5aae`. Only the spec is modified (86 insertions, 23 deletions). This report is the only other file written. Nothing is staged, committed or pushed.

**Not done, as instructed:** nothing was implemented; Ollama was not started; no live tests were run; `.gitignore`, `scripts/`, `tests/` and `.ai/` were not touched.

Labels: **FACT** (verified, with the evidence named), **DECISION** (approved by the user), **ASSUMPTION** (stated, not verified), **UNVERIFIED**.

## 1. Verdict

- **WP-A is unblocked.** It was never blocked by the warning defect V-1. NFR-006 applies to its suite, and none of its criteria asserts on localized text.
- **WP-C is unblocked.** V-1 is resolved by OD-07. AC-023 and AC-024 now assert only on the harness's own wording, and on the line being whole.
- **Two items stay open and block neither WP:**
  - A-06 needs your confirmation: the `<reason>` text when `.Parameters` is `$null`. No test depends on it.
  - A-07 is UNVERIFIED: exit 2 for a validator that fails to parse. AC-024's one-time check confirms it during WP-C.

## 2. New facts found while editing

These came from small probe scripts in the session scratchpad. They ran in a child `powershell.exe` 5.1.26100 and wrote nothing to the repository.

| # | FACT (2026-11-20) | Effect |
|---|---|---|
| F-1 | UI culture and culture are both `es-ES`. | NFR-006 evidence. |
| F-2 | With redirected output, `Write-Warning` with a 300-character message printed `ADVERTENCIA: ` and split the text over three lines of at most 119 characters. `Write-Host` printed a 309-character line as one line. | NFR-006 evidence; confirms that OD-07 fixes V-1. |
| F-3 | For four different scripts that fail to parse, `Get-Command -CommandType ExternalScript` succeeds and `.Parameters` returns **`$null` without throwing**, even under `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`. Valid scripts always return a dictionary, which is empty when there is no `param` block. | **This corrects a Context FACT from Revisions 1 and 2** ("reading `.Parameters` throws"). The earlier probe called `.Parameters.ContainsKey('Mode')`; its `RuntimeException` came from calling a method on `$null`. The spec now counts `$null` as a failed inspection, so a script that fails to parse still gets the "not confirmed" warning that AC-024 expects. |
| F-4 | A missing script path makes `Get-Command` throw `CommandNotFoundException`. | Used as the `<reason>` example instead of `ParseException`, which this code path never raises. |
| F-5 | For a validator under a `br[1]` folder, `Test-Path` returned `False`; `Test-Path -LiteralPath`, `Get-Command` and `&` all worked. `specify.ps1:83` uses plain `Test-Path`, so it throws "Specification validator not found" before any FR-008 check. | Basis for the decision on bracket paths (A-05). |

## 3. Diff summary of the spec

| Request item | Where | Change |
|---|---|---|
| 1. Warning via `Write-Host` | FR-019 | The warning is printed with `Write-Host` as one line. The literal `WARNING: ` prefix is now part of both message texts, exactly once. The claim that `Write-Warning` adds the prefix is removed. One sentence notes that `-WarningAction` no longer suppresses the line, a consequence of leaving the warning stream. |
| | FR-019 | `<reason>` is `$_.Exception.GetType().Name`, never the message. When `.Parameters` is `$null`, it is the fixed text `no parameter metadata` (A-06). |
| | FR-019 | A new "When the warning appears" bullet keeps the distinction: no warning without `-Mode` or in requirements and baseline modes, whether inspection worked or not; exactly one line with one prefix in documentation mode. |
| | AC-023, AC-024 | Exactly one line starts with `WARNING: `; it contains the prefix exactly once and two phrases of the same warning text, which proves the line was not split. AC-024 explicitly does not check `<reason>`. Both gain NFR-006 in `Verifies:`. |
| | Revision History (Revision 2 list) | The Revision 2 bullet now reads "relied on `Write-Warning` … Superseded in Revision 3 (OD-07)". |
| | Resolved Decisions | New OD-07 (approved 2026-11-20). |
| 2. General rule | New NFR-006 | No assertion may depend on PowerShell or .NET text (localized prefixes, exception messages, `ConvertFrom-Json` errors) or on console wrapping. Evidence F-1 and F-2. |
| | New AC-031 | An inspection of the three new suites and the AC-028 check. It runs in Execution Order step 5 and in the Offline Verification Strategy static checks. |
| 3. AC-028 | AC-028 | The SKIPPED and FAIL details are asserted only on "model could not be resolved", "precondition not met, NOT executed" and `spec-reviewer`. A new "Reason text" paragraph says the reason is never checked. "No unhandled exception text" is replaced by the `test-all internal error` check: `test-all.ps1:779` and `:783` report unexpected exceptions with that wording. Gains NFR-006. |
| 4. FR-017 | FR-017, "Every scenario injects all four scripts" | AC-011 sets `-ValidatorScript` explicitly to the real `validate-spec.ps1`; every other injected script, in every scenario, is a mock. |
| 5. Paths with `[` or `]` | Edge Cases, A-05 | **Chose to document the limitation** (the smaller change). The existing `Test-Path` checks already reject such paths before FR-008 runs (F-5). Switching to `-LiteralPath` would change existing behavior outside Phase 0's defects (NFR-004). Recorded as an explicit assumption that nobody relies on such paths. |
| 6. Traceability, history, assumptions | Matrix | New row `NFR-006 → AC-023, AC-024, AC-028, AC-031`. |
| | Assumptions | A-02 marked "(UNVERIFIED for script files)". New A-05 (bracket paths), A-06 (`<reason>` for `$null`, to confirm) and A-07 (exit 2 for a validator that fails to parse, UNVERIFIED). |
| | Revision History | Revision 3 row and a "Revision 3 changes" list. |
| (from F-3) | Context, FR-008, FR-019 | Context corrected: `.Parameters` returns `$null`. FR-008 lists `$null` as a failed check, and FR-019's "not confirmed" case includes it. |
| | Header | Status: Revision 3 (2026-11-20). Context gains a "Revision 3 applies …" line. |

Unchanged: the requirement IDs, the work packages, the exit codes, the two warning texts apart from the prefix, and every other AC.

## 4. Validator result

```text
> powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\validate-spec.ps1 -SpecFile specs\harness-phase-0-defect-corrections.md
=== Specification Validator ===
File: specs\harness-phase-0-defect-corrections.md

STATUS: PASS

All required specification checks passed.
EXIT=0
```

No other script was run against the repository.

## 5. Independent traceability check

A Python script in the session scratchpad parsed the spec. Results:

| Check | Result |
|---|---|
| Defined entries | 18 FR, 6 NFR, 31 AC |
| Duplicate IDs | none |
| ACs without exactly one `Verifies:` line | none |
| Entries without a valid `**Source:**` | none |
| Matrix rows (24) equal the inverse of the `Verifies:` lines | **yes**, exact match |
| Requirements without an AC / ACs that verify nothing | none / none |
| Referenced but undefined IDs | `FR-101`, `FR-105`, `AC-103`, `FR-304` (audit references for later phases) and `FR-009` (retired). These are the same exemptions as in Revision 2; no new ones. |
| Other ID families | OD-01..07, A-01..07, RK-01..10, D-01..06, WP-A..E (WP-B only as "removed"); all consistent |
| Remaining `Write-Warning` requirement | **none.** All 7 mentions say not to use it (FR-019, NFR-006, AC-031), give evidence (NFR-006), or are history (OD-07, Revision 2 and 3 lists). |

## 6. Open items

- **A-06, to confirm.** Your example `<reason>`, `ParseException`, cannot occur on this code path (F-3). The spec proposes the fixed text `no parameter metadata` for the `$null` case. It is not tested, so changing it later affects no criterion.
- **A-07, UNVERIFIED.** "A validator that fails to parse makes `specify.ps1` exit 2" is still unverified, as you requested. AC-024's one-time check against `2e85dbe` settles it in WP-C.
- **A-02, UNVERIFIED for script files.** It is confirmed in WP-D step 3a before anything depends on it.
- **Interpretation, please check.** I read "absent -Mode (no warning, silent)" as a `specify.ps1` run without `-Mode` (default `requirements`), not as "a validator that doesn't declare `-Mode`". The other reading would contradict OD-03 and AC-023, which keep the documentation-mode warning for validators that don't declare `-Mode`.
- **Stale header line, not changed.** "Applies to: `2e85dbe` (working tree: `.gitignore` modified, `specs/portfolio-*` untracked)" describes the state on 2026-11-19. Both points were settled by commit `8ef5aae`. I left the line alone to keep the edit minimal.
