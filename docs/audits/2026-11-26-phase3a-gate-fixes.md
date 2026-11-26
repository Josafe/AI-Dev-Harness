# Phase 3A gate fixes

Date: 2026-11-26. Applies findings 1-6, 18, 19 of `docs/audits/2026-11-26-phase3a-gate-review.md`.

## Executive summary

All seven fixes applied. One test changed (AC-322 file list), one comment, spec and context pack edited. No other code or assertion changed. `scripts\test-all.ps1` once: **22 discovered, 21 PASS, 1 skipped (`test-spec-integration.ps1`), 0 FAIL, PASS WITH SKIPS**. `validate-spec.ps1` PASS. Context pack 9156 bytes (limit 9216). Nothing pushed or tagged.

## Per finding

- **1** `scripts/test-engine-callsites-run-agent.ps1` (AC-322 case, name unchanged): inside a git work tree the list is `git -C <root> --no-optional-locks ls-files -z --cached --others --exclude-standard -- scripts tests` (deleted files dropped); otherwise the old walk. AC-322 reworded: "no file ... that git does not ignore (every file when git is unavailable)".
- **2** `docs/phase3-context.md`: baseline 22/21/1; telemetry locked; wrappers gone; function names instead of line numbers; `Read-HarnessModelTelemetry` and `Test-OllamaModelLoad` interfaces; 12 categories; `tests/lib/engine-fake-host.ps1`; AC-322/AC-323; A1-A4 rows collapsed to keep size.
- **3** FR-311(c): option (a) recorded (one deadline per call, about 1 s in-lock CSV retry, then skip with warning); A1 code implements the per-file reading; B6 implements (a) plus findings 7 (`AppendData`) and 8 (CSV share-deny). B6 row in Execution Order lists all three.
- **4** FR-314: the four forced edits listed (A1 function list and parameter count; A4 pinned lists in `test-agent-prompts.ps1`, `test-agent-exec.ps1`); 3B may extend those lists.
- **5** Affected Files: `tests/lib/compare-engine-case-names.ps1` added; `engine-fake-host.ps1` marked modified in B3. Dependencies: B3 adds `/api/version`.
- **6** AC-317, AC-316, RK-303: "holder killed while another process keeps the mutex open". B6 exit check names the abandoned-mutex test and its mutation (not written now).
- **18** B9 exit check names the AC-323 name check (`-RunSuites`). The spec has no separate final-QA exit check row for it, so B9 only.
- **19** `scripts/lib/agent-exec.ps1` comment now names `tests\lib\engine-fake-host.ps1` (comment only).

## AC-322 proof (suite `test-engine-callsites-run-agent.ps1`)

1. `scripts\zz-gate.bak` (matches `.gitignore` `*.bak`) naming a wrapper (built from fragments): PASS, 60 passed, 0 failed.
2. `scripts\zz-gate-notignored.txt` (not ignored) naming a wrapper: AC-322 [FAIL], 59 passed, 1 failed, exit 1.
3. Both deleted; `git status` shows only the intended edits.

## Not verified

AC-323 `-RunSuites` not run (not needed: no case name changed). The no-git fallback branch was not exercised.
