# Phase 3A gate review (independent)

Date: 2026-11-26. Reviewer: independent session (did not implement any 3A package). Scope: `git diff phase3-spec-rev2..master -- scripts tests` (master `e412b89`), the five package reports, `docs/phase3-context.md`, the spec sections named below. Review only: no script, test, spec or config was changed.

## Executive summary

**Verdict: GO WITH FIXES.** No blocker. The locked telemetry path, the wrapper deletion, the suite split and the engine signals do what the spec asks, and no Phase 2 behavioral expectation (exit code, category, warning, output text, golden) was changed. Six small items should land before B1/B2 start: one test fix, one context-pack refresh, four spec wording edits (findings 1 to 6).

**Fix before 3B**
1. AC-322 scans git-ignored files (owner's `*.bak*` made it fail): scan `git ls-files --cached --others --exclude-standard`, fall back to the full walk without git; reword AC-322 (finding 1).
2. Context pack is stale for 3B sessions: baseline 19/18/1 (now 22/21/1), "no lock today", line numbers, "wrappers to delete" (finding 2).
3. FR-311(c) retry budget is ambiguous; A1 chose per-file budgets (worst case about 30 s per call, mutex held up to about 20 s). Record the decision (finding 3).
4. FR-314 says the wrapper edits are "the only authorized edits of existing assertions"; A1 and A4 changed four more static/pinned assertions. Reword (finding 4).
5. Affected Files / Dependencies: `tests/lib/compare-engine-case-names.ps1` is unlisted; the fake host has no `/api/version` route yet although Dependencies says it has one (finding 5).
6. AC-317 / AC-316 / RK-303 "holder killed" cannot reach the abandoned-mutex path; the wording must say another process keeps a handle open (finding 6, probe evidence).

**Answers in one line each**
- Q1 A1: correct and complete for the locked path; the AC-317 evidence is sound. `FileSystemRights.AppendData`: **at 3B (B6)**, not now and not never; probe: unlocked plain `Append` kept 771 of 1200 records, `AppendData` 1200 of 1200 (findings 7, 8). The abandoned-mutex rule IS testable (probe); the retry-budget reading needs an owner decision (finding 3).
- Q2 A4: all checks hold: rule `promptChars > 7 * n` only for a real number above 0; three ordinal markers, 5xx only, JSON `error` string only, full string before the 500 cut; not retried (also warm-up); helper is a legitimate NFR-202 exception; `Test-OllamaModelLoad` sends only `model`, `options`, `stream`, one attempt, no telemetry, no `keep_alive`; owner hint present; `http_5xx` / `transport_reset` hints byte-identical and pinned (finding 12).
- Q3 Phase 2: no behavior beyond the spec. The RK-305 fake edits are legitimate; the two "field absent" cases are arithmetically forced and mask nothing. Expected values changed: only four static/pinned assertions (function lists, parameter count 23 to 24), plus the authorized FR-314 removals and the owner-decided A3 loop (finding 16).
- Q4 tests: mutation proofs are meaningful (A1 lock-off, BOM; A2 name; A3 rename; A4 7 to 8 / 6, retryable, Ordinal). Gap: no abandoned-mutex proof (fixable). Env-dependent: AC-322 (finding 1), AC-317 timings and `Global\` availability, 8.3 alias (skips), AC-323 check not automated (findings 18, 20).
- Q5 3B interfaces: confirmed `Read-HarnessModelTelemetry -Root [-FromOffset] [-LengthOnly] [-LockWaitMs]` -> `{Exists, Length, Lines, LockTimedOut}`; `Test-OllamaModelLoad -Execution -Registry [-Transport]` -> `{loaded, category, hint, durationMs}`; 12 engine categories (hints table keys). Gaps for B3/B4: load-check stage has no `httpStatus` / detail source (finding 13); `LockTimedOut` also means "name refused" (finding 11); CLI must pass an absolute root (finding 10).
- Q6 spec debt: findings 1, 3, 4, 5, 6 (spec part) and the pack (2). Optional: findings 13, 14, 17.

**Probes run (read-only, scratchpad and TEMP only, nothing in the repo):**
(a) abandoned mutex: a child holds a `Global\` mutex and is killed; a third process waits. Without another open handle: `acquired=True abandonedCatch=False` (the object died with its only handle; this is what the A1 kill test sees). With the parent keeping a handle open: `acquired=True abandonedCatch=True` (WAIT_ABANDONED reached, the PowerShell typed `catch [System.Threading.AbandonedMutexException]` matches).
(b) 4 processes x 300 unlocked appends of 420-byte lines: `FileMode.Append` + `FileAccess.Write` -> 771 lines of 1200; `FileMode.Append` + `FileSystemRights.AppendData` -> 1200 of 1200, `Length` readable on the append-only handle.
No suite was run; `test-all` was not run (the owner ran it twice: 22 / 21 PASS / 0 FAIL / 1 skipped).

**Not verified:** behavior under a real refused `Global\` name (other account or mixed elevation); network/UNC log paths; live Ollama load failures and real truncation; the A3 move by full diff (checked by a line-multiset comparison: the only old-only lines are comments, the documented `$script:` moves and the cut script lists).

## Findings

Tags: BLOCKER / FIX-BEFORE-3B / LATER / NOTE. Line numbers are at master `e412b89`.

1. **FIX-BEFORE-3B** `scripts/test-engine-callsites-run-agent.ps1:545` - AC-322 walks every file under `scripts\` and `tests\`, so git-ignored local backups (`*.bak`, `*.bak-*`, `*.bak.*`, all in `.gitignore`) that still name the wrappers fail the case. Minimal fix: when `git` resolves and `git -C <root> rev-parse --is-inside-work-tree` is true, take the list from `git -C <root> --no-optional-locks ls-files -z --cached --others --exclude-standard -- scripts tests` (tracked plus untracked-not-ignored, so a new unignored file still counts); otherwise keep the current walk. Spec AC-322 (L432) to read "no file under `scripts\` or `tests\` that git does not ignore (every file when git is unavailable)". Belongs before 3B: every B-package gate run and the final QA run in the owner's checkout would otherwise report a false FAIL.
2. **FIX-BEFORE-3B** `docs/phase3-context.md:52-55,64` - the pack replaces the spec for 3B sessions but says: line numbers of `agent-exec.ps1` functions (all moved), "wrappers to delete" (gone), "`telemetry.ps1` ... no lock today" (locked now), baseline "19 discovered, 18 PASS, 1 skipped" (now 22 discovered, 21 PASS, 1 skipped, PASS WITH SKIPS). Add: the 3A interfaces of Q5, the 12 categories, `tests/lib/engine-fake-host.ps1` as the helper, and the AC-322 / AC-323 checks.
3. **FIX-BEFORE-3B** (spec) `specs/harness-phase-3-unified-cli.md:177`, `scripts/lib/telemetry.ps1:117,138,340,379` - "a bounded retry on IOException until -LockWaitMs is spent" is read by A1 as a fresh budget per file write, separate from the mutex wait. Worst case one call: 10 s mutex wait + 10 s JSONL retry + 10 s CSV retry, holding the mutex up to about 20 s, which pushes every concurrent writer past its own 10 s wait into the unlocked path. Decide and write down one of: (a) one deadline per call covering wait and writes, or (b) A1's reading. RECOMMENDATION: (a), plus a short in-lock retry for the CSV (finding 8).
4. **FIX-BEFORE-3B** (spec) `specs/harness-phase-3-unified-cli.md:189` - FR-314 ends "These are the only authorized edits of existing assertions." Since then A1 changed `test-agent-telemetry-v2.ps1:1092` (function list; parameter count 23 to 24) and A4 changed the pinned lists in `test-agent-prompts.ps1:129` and `test-agent-exec.ps1:2284`. All four are forced by the new functions/parameter and Affected Files names the A4 pair, but FR-314's sentence is now false. Reword to list them (and that 3B may extend those same lists).
5. **FIX-BEFORE-3B** (spec) `specs/harness-phase-3-unified-cli.md:567-571,607`, `tests/lib/engine-fake-host.ps1:242-244` - Affected Files does not list `tests/lib/compare-engine-case-names.ps1` (A3 put it there; the `tests/fixtures/` row covers only the fixture). Dependencies says the fake host was "moved by FR-315, with a `/api/version` route"; the moved host knows only `/api/tags` and `/api/generate` and throws on any other route. State that B3 adds the route (and that `engine-fake-host.ps1` is modified in 3B, not only new in A3).
6. **FIX-BEFORE-3B** (spec), **LATER** (test, B6) `scripts/test-agent-telemetry-v2.ps1:1019`, spec AC-317 (L400), AC-316, RK-303 (L615) - the "holder killed" case passes because the kernel mutex is destroyed with its only handle, so the next writer creates a fresh one; `AbandonedMutexException` (`telemetry.ps1:87-89`) is never reached, which is why A1's third mutation survived. Probe (a) shows the path is reachable when another process keeps a handle open. Spec: "a holder killed while another process keeps the mutex open". Test (B6, together with AC-316 for the artifact lock): the parent opens the same name before killing the holder; then the mutation "abandoned counts as not acquired" must fail.
7. **LATER** (B6) `scripts/lib/telemetry.ps1:124` - `FileSystemRights.AppendData`. Locked path: not needed (A1 proof 1 and the 4 x 40 case). Fallback path (lock refused or timed out): `FileMode.Append` seeks to the end once at open, so overlapping writers overwrite each other (probe b: 771/1200); with `AppendData` and no `WriteData` the OS appends each `WriteFile` at end of file (probe b: 1200/1200). Recommendation: adopt in B6 (concurrency is the B6 subject and B6 is Opus/Opus), using the .NET Framework constructor `FileStream(path, Append, FileSystemRights.AppendData, FileShare.ReadWrite, 4096, FileOptions.None)` and one `Write` per record. Then AC-317's "lock disabled loses records" proof must name another observable (e.g. CSV header decision or BOM at creation, which `AppendData` does not protect), or disable both. Not now: the spec accepts fallback loss (Edge Cases L602) and the gate should not reopen A1. Not never: findings 8 and 9 make the fallback reachable in ordinary use once concurrent runs are a feature.
8. **LATER** (B6) `scripts/lib/telemetry.ps1:320-329,346,379` - a program that opens `model-calls.csv` denying write sharing (Excel typically does) makes the CSV append retry for 10 s inside the lock, then the call's telemetry ends with "Telemetry logging failed" (JSONL row was written); concurrent writers meanwhile time out and append the JSONL unlocked (finding 7). `$readHeader` opens with `StreamReader` (share Read) and is not retried (pre-existing). Recommendation: CSV is the convenience copy; retry it briefly (for example 1 s) and skip the row with a warning, never stall the JSONL.
9. **NOTE** `scripts/lib/telemetry.ps1:78-83` - refused name path untested. Realistic triggers: two Windows accounts, or one elevated and one non-elevated harness process (the elevated creator's default DACL may refuse the other). Every write is then unlocked with a warning. Harmless for the JSONL once finding 7 is done.
10. **NOTE** `scripts/lib/telemetry.ps1:40,124,170` - `GetFullPath` and `FileStream` resolve a relative `-Root` against the process directory, not the PowerShell location. Today all callers pass `Split-Path -Parent $PSScriptRoot` (`run-agent.ps1:74`, `review-spec.ps1:13`, `revise-spec.ps1:14`): absolute. The 3B CLI must pass an absolute root too. `subst`, UNC and junction spellings of one folder give different mutex names (D-307 covers targets, not the harness root).
11. **NOTE** (B4) `scripts/lib/telemetry.ps1:165,192` - `LockTimedOut` is also true for a refused name; B4 should add `telemetry_lock_timeout` in both cases (FR-307 L131 says "lock timeout"). In the unlocked case a half-written last line is returned (unparsable, dropped by the caller) but `Length` already counts it, so the next `-FromOffset` read starts inside that record and loses it. Only on the fallback path.
12. **NOTE** A4 verified in `scripts/lib/agent-exec.ps1`: helper `:264-271` (ordinal `IndexOf`, three literal markers, pure); classifier `:371` runs it only when the status row gave `http_5xx` and `detail` is the JSON `error` string, before the 500 cut (`:379`); `retryable` follows the final name (`:383`), so the retry loop (`:899`) and the warm-up (same `sendWithRetry`) make one attempt; ByName is not retryable (`:316`); hint `:309` is the owner text; rule `:1070-1078` treats int/long/decimal/double above 0, NaN and infinity add nothing; scripts print new then weak line after the budget line (`run-agent.ps1:165-174`, same in the other two); `Test-OllamaModelLoad` `:669` builds `model` / `options` (only when non-empty) / `stream`, `Purpose warmup`, profile timeout, no loop, no telemetry.
13. **LATER** (decide before B4) `scripts/lib/agent-exec.ps1:669-750` - `Test-OllamaModelLoad` copies the transport-wrapping block of `Invoke-AgentModel` (`:851-887`); a future fix must be made twice. It returns no `httpStatus` and no detail, so the `load-check` stage's `error.httpStatus` and `error.message` (FR-305) have no source except fixed wording. Either accept null/fixed wording in FR-318/FR-305, or add members (the AC-333 test pins the member list `loaded,category,hint,durationMs`).
14. **LATER** (owner, OQ-318) `scripts/lib/agent-exec.ps1:298,302` - the unchanged `http_5xx` and `transport_reset` hints still say a CUDA initialization error is "usually" cleared by restarting the server; the new `model_load_failed` hint says a restart has not cleared it. Kept on purpose (RN-16); users may see both pieces of advice in one session.
15. **NOTE** `scripts/lib/agent-exec.ps1:264,371` - the separate helper is a legitimate NFR-202 exception: documented in FR-317 and the Phase 2 note, and better than relaxing the Phase 2 classifier scan. LATER: a static assertion that `Test-OllamaLoadFailureText` is called exactly once, inside `Get-AgentErrorCategory`, so the exception cannot spread unnoticed.
16. **NOTE** Phase 2 compatibility. Code: behavior changes are those the spec allows (new warning and lines, new category, lock wait, lock warning); one incidental improvement: the JSONL path is now literal (old `Add-Content -Path` treated `[` `]` as wildcards). Tests: RK-305 fake edits at `test-agent-exec.ps1:1028,1659,1696,1706` move the fake count to about 5 characters per token, below C - R: no behavior hidden. The two "field absent" cases (`test-agent-exec.ps1:1678-1683`; `engine-fake-host.ps1:570` used by the three warn loops) are forced: avoiding both warnings needs `n >= chars / 7` and `n < C - R`, that is about 142,858 <= n < about 10,000, and about 1,286 <= n < 900; both empty. They test the estimate and `budget_exceeded` only; both truncation rules stay covered (8 cases in `test-agent-exec.ps1`, 6 in `test-engine-signals.ps1`). Fake-host default `engine-fake-host.ps1:261-271` (floor(chars / 5), at least 5) is a shared input change, documented. No golden, fixture or behavioral expected value changed; the changed expected values are the four in finding 4.
17. **NOTE** `scripts/lib/agent-exec.ps1:1070-1078` - like the old rule, the new rule runs on any HTTP-2xx answer, also one that ends as `empty_response`; FR-316 says "after a successful response". Harmless (warning only). Residual risk for OQ-320: an Ollama version that reports only non-cached prompt tokens would make repeated prompts look truncated (the owner's probe saw no cache effect).
18. **LATER** (B9 / final QA) `tests/lib/compare-engine-case-names.ps1` - the AC-323 name check is not run by `test-all`; a 3B package that renames a call-site case is caught only if someone runs it (`-RunSuites`, about 3 min). Name it in B9's or the final QA's exit check.
19. **NOTE** `scripts/lib/agent-exec.ps1:411` still names "the engine fake host of test-engine-callsites.ps1" (now `tests/lib/engine-fake-host.ps1`). The close-out report lists the stale comment of the old `:691` as open; A3 already fixed it (`engine-fake-host.ps1:713`).
20. **NOTE** environment-dependent tests besides finding 1: AC-317 timings (`elapsedMs -ge 250`, `-lt 8000`, `test-agent-telemetry-v2.ps1:997-1031`) on a loaded machine; the AC-317 cases need `Global\` mutexes and `powershell.exe` child processes (a sandbox refusing `Global\` fails them); the 8.3 alias line skips with a printed note on machines without short names.

## Details

### Q1 - A1 telemetry lock

Correct for FR-311(c) and the FR-307 reader as written:
- Name: `Global\AiHarnessTelemetry-` + 16 hex of SHA-256 of the lower-cased long path (`telemetry.ps1:59-68`); spelling variants (trailing separator, case, dot segments, slashes, 8.3) are tested.
- Whole file section inside the lock (`:334-386`): JSONL append, CSV header decision, CSV append. Release in `finally`; `Exit-` releases only when acquired; a refused or timed-out lock warns once and writes (`:336-338`), never failing the call (outer `catch`, `:388`).
- One `FileStream` per file, one `Write`, BOM only at length 0, CRLF (`:120-130`); bytes equal `Add-Content` / `Set-Content -Encoding UTF8` (tested by SHA). The N-10 missing-final-newline fix is kept and now in the same write.
- Reader (`:150-205`): same lock, `FileShare.ReadWrite`, IOException retry, BOM dropped only at offset 0, offset clamped, `-LengthOnly`. Under the lock, offsets always fall on record boundaries, so UTF-8 decoding from an offset is safe.
- AC-317 evidence holds for the locked path (4 x 40, 2 writers + reader, BOM/bytes, `-LockWaitMs 300`, kill, name). The mutation "lock disabled" lost records three times: the evidence AC-317 asks for.

Gaps: abandonment not exercised (finding 6), budget reading (finding 3), fallback loss (findings 7 to 9), relative root (finding 10).

**AppendData decision.** At 3B, in B6. Reason: it costs a few lines, the probe shows it removes the JSONL loss of the fallback, and concurrent runs become a feature in 3B (AC-316). It does not protect the creation races (two writers both seeing length 0 write two BOMs; two writers both creating the CSV header) nor the reader's partial line; those stay lock-only. It changes how AC-317's "lock disabled loses records" proof must be done (finding 7).

**Abandoned-mutex rule.** The code is right: `WaitOne` throws `AbandonedMutexException` with ownership granted, the typed `catch` sets `Acquired`, `finally` releases it. It is testable (probe a); the existing test proves only "a dead holder does not block", which is true for a different reason.

**Retry budget.** A1's reading is defensible but not the only one, and it lets one stuck file hold the mutex long enough to push others into the unlocked path. Owner decision, then a one-line spec edit (finding 3).

### Q2 - A4 engine signals

All items in the brief check out (finding 12). Edge cases confirmed by reading: a JSON `error` that is not a string, a non-JSON body, a 4xx, a marker in another member: no reclassification. A body longer than 4096 characters is cut by `Invoke-OllamaHttp` before parsing (pre-existing), so a marker beyond that would be missed; negligible. `Test-OllamaModelLoad` omits `options` when the execution has none (no `num_ctx` then; consistent with the later generate request, which omits it too). It applies to `/api/tags` 5xx bodies as well (the classifier is shared); harmless.

### Q3 - Phase 2 compatibility

See finding 16. A3 move check: a sorted multiset of non-blank, non-`#` lines of the old suite (at `0d4a199`) against the three suites plus the helper (at `4c47e1b`): the only old-only lines are help-block prose, the shared data now assigned as `$script:` in `Initialize-EngineSuite`, and the cut script lists, as the A3 report says. A4 then changed one token per suite (`$okReply` to `$okReplyNoCount`) and the A3 follow-up one loop variable (`$allSubjects`).

### Q4 - Test quality

Mutation proofs: each targets the key rule of its AC and each was hash-reverted. Strongest: A1 lock-off (records lost), A4 constant both directions, A4 retry. Weakest: A1 abandoned (survived; finding 6 explains and fixes). The A3 proof also found a real bug in the checker (case-insensitive hashtable), fixed.

AC-322 fix (finding 1), sketch:

```powershell
$files = $null
if (Get-Command git -ErrorAction SilentlyContinue) {
    $inside = & git -C $repositoryRoot rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0 -and $inside -ceq 'true') {
        $listed = & git -C $repositoryRoot --no-optional-locks ls-files -z --cached --others --exclude-standard -- scripts tests
        $files = @(($listed -join '') -split "`0" | Where-Object { $_ } | ForEach-Object { Join-Path $repositoryRoot $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    }
}
if ($null -eq $files) { $files = @(Get-ChildItem -LiteralPath $scriptsDirectory, (Join-Path $repositoryRoot 'tests') -File -Recurse | ForEach-Object FullName) }
```

(`Test-Path` drops files deleted in the work tree but still in the index.)

### Q5 - What 3B calls

| Interface | Shape | 3B user | Note |
|---|---|---|---|
| `Read-HarnessModelTelemetry` | `-Root` (harness root, not `logs`), `-FromOffset`, `-LengthOnly`, `-LockWaitMs`; `{Exists, Length, Lines, LockTimedOut}` | B4 `stage_begin` (`-LengthOnly`) and `stage_end` (`-FromOffset`) | Lines are .NET strings (FR-305 rule ok); caller parses and filters `run_id`; findings 10, 11 |
| `Write-HarnessModelTelemetry -LockWaitMs` | optional, default 10000 | none directly | finding 3 |
| `Test-OllamaModelLoad` | `-Execution -Registry [-Transport]`; `{loaded, category, hint, durationMs}` | B3 `doctor -LoadCheck`, B4 stage `load-check` | caller groups (model, options); finding 13 |
| `Get-AgentErrorCategory` | 12 categories (hints table) | B1 schema enum `engineCategory` (D-312) | `model_load_failed` maps to itself (FR-307 L133) |
| `Invoke-OllamaHttp` | `Purpose` generate, warmup, tags | B3 `GET /api/version` | needs a fake-host route (finding 5) |

Spec text made stale by 3A: findings 2, 4, 5; Context L16-18 is labeled "at phase2-calibrated" and is correct as history.

### Q6 - Spec edits before 3B (confident)

1. AC-322 (L432): "no file ... that git does not ignore (every file when git is unavailable)".
2. FR-311(c) (L177): the chosen retry-budget reading.
3. FR-314 (L189): name the A1 and A4 static/pinned assertion edits as authorized.
4. AC-317 (L400), AC-316, RK-303 (L615): "killed while another process keeps the mutex open".
5. Affected Files (L569): add `tests/lib/compare-engine-case-names.ps1`; `tests/lib/engine-fake-host.ps1` modified in B3 (route `/api/version`); Dependencies (L607): the route is added by B3.
6. `docs/phase3-context.md` refresh (finding 2).

Optional, owner's call: FR-318 / FR-305 source of `load-check` error fields (finding 13); FR-307 "lock timeout or refused name" (finding 11); OQ-318 hint wording (finding 14); FR-316 "after an HTTP success" (finding 17).
