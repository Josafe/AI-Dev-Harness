# Phase 2: independent final QA

**Branch:** `docs/phase2-final-qa`, from `master` at `f378ef9` (tag `phase2-config`, an ancestor as required). Baseline `phase1-hardened` = `ba33bb4`. Only this file was added; no source, test, spec or config file was changed. Nothing was pushed.
**Host:** Windows PowerShell 5.1.26100.9818, culture es-ES, `core.autocrlf=true`. Run on 2026-11-24 (host clock); the file name uses the date the task gave.
**Network:** none, except throw-away `TcpListener` servers on 127.0.0.1 (OS-chosen port, hard time limit, stopped after use; 0 leftover processes at the end). No Ollama. The scratch is in `%TEMP%\p2fqa` and is not committed.

## 1. Verdict

**READY to tag `phase2-done`: YES WITH CONDITIONS.** 0 blockers, 7 important, 18 nits.

The engine works with the real cmdlet. In 61 real runs of the three scripts (30 scenarios) there was exactly one telemetry record per run, no wrong exit code, no output file on a failure, and no divergence in category, attempts or request body. `specify.ps1` kept its exit codes and artifacts in three of four workflows; the fourth (a 500 on the first request) now succeeds through the intended retry.

**Conditions (all text or tests; none needs an engine change):**

1. C1 (I-2): list `scripts/test-shipped-config.ps1` in "Affected Files". AC-219 fails literally until then.
2. C2 (I-1): the owner rules on the body line of the OLLAMA ERROR block. Either amend FR-202 and NFR-205 to say `detail`, or carry the body in the engine result.
3. C3 (I-3): complete the intentional-change list of NFR-205 and fix the FR-202 / FR-209 contradiction.

I-4 to I-7 are recommended before WP-2E but do not block the tag.

## 2. Findings

| ID | Severity | Where | Finding and evidence | Fix |
|---|---|---|---|---|
| I-1 | important | `scripts/run-agent.ps1:191-193`; spec FR-202 ("response-body line ... taken from `failure.body`") | The script prints `failure.detail`, not the body. WP-2D1 decision 1 says a JSON body line "is the same text as before": **refuted**. Fake host, legacy vs now: `{"error":"boom"}` -> `boom`; a text body -> `System.Net.WebException ProtocolError`; `{"message":...}` -> the type name; an empty body -> a type name where the legacy printed nothing. Real cmdlet: a chunked 500 printed `{"error":"chunked boom ..."}` and now prints `chunked boom ...`. With Content-Length the real legacy printed an EMPTY body line (the stream was already consumed), so there the new line is an improvement. The suite asserts the new text (`test-engine-callsites.ps1:980, 997`), so it locks the deviation in. Not in NFR-205. | Owner ruling (C2) |
| I-2 | important | spec "Affected Files"; NFR-206, AC-219 | `scripts/test-shipped-config.ps1` (new) is in the diff and not in the list. The spec file itself is not listed either (trivial). The list also says `docs/roadmap/modernization-roadmap.md` is modified; it is unchanged. | Text (C1) |
| I-3 | important | spec NFR-205 and FR-202 line "nothing is printed for warnings" | Observed changes that NFR-205 does not list: (a) telemetry `success` -> `error` for an empty response of the **reviewer and reviser** (NFR-205 names only run-agent); (b) the same for a reviewer format failure (WP-2D2 decision 5, confirmed); (c) the reviser's thrown text loses the localized message although it has no OLLAMA ERROR block; (d) the `Warning: budget_exceeded` line on success. (d) also contradicts FR-202 ("No line is added on success, and nothing is printed for warnings"), while FR-209 requires it. | Text (C3) |
| I-4 | important | `scripts/test-agent-exec.ps1:721-770`; `agent-exec.ps1:924` | No test has a `<think>` block that spans lines. Mutant Q08 (the `(?s)` removed from the strip regex) survives both engine suites. Multi-line reasoning is the normal shape, so the main job of the regex is untested. The code is correct today. | One case with newlines inside `<think>` |
| I-5 | important | `scripts/benchmark-models.ps1:192, 246`; `telemetry.ps1:65` | `benchmark-models.ps1` reads `duration_ms` and counts exit 0 as success. A retried call now exits 0 with `duration_ms` covering the failed attempt and the wait: 1218 ms with `attempts` 2 against 160 ms with `attempts` 1 (real cmdlet, backoff 1 s). With the shipped backoff the error is 5 s plus the failed attempt. The baseline recorded such a run as an error. | Before WP-2E numbers are used: ignore rows with `attempts` above 1, or benchmark with `maxAttempts` 1 |
| I-6 | important (pre-existing) | `telemetry.ps1:130-181` | Overlapping processes lose records. 40 writes each with a 5 ms pause: 1 process 40/40; 2 processes 1 to 14 of 80; 4 processes 6 to 8 of 160. The **baseline writer is equally bad** (1 to 11 of 80; 5 to 35 of 160), so this is no regression, and the loss is a warning. The stress is harsher than real use, but "exactly one record per call" (FR-216) holds only without overlap. | Phase 3 (background runs): bounded retry on a sharing violation, or a named mutex |
| I-7 | important | spec AC-215 | The clause "a reviewer-sized stub prompt against the frozen baseline is **sent, not refused**" has no assertion. `test-shipped-config.ps1` (last case) checks only the mode, against the shipped file; `test-agent-exec.ps1:1593` uses a synthetic registry. Observed true in Part C with the shipped file. | One in-process case on `config-v2-phase1-baseline.json` |
| N-1 | nit | `agent-exec.ps1:280, 284` | Hints say "on every attempt". `/api/tags` is asked once and never retried, and `maxAttempts` may be 1, so the hint is false there. Seen with `tags-500` and `tags-drop`. | Reword |
| N-2 | nit | `agent-exec.ps1:282` | The `timeout` hint names the profile's `timeoutSec`; a `/api/tags` timeout is governed by `ollama.healthTimeoutSec`. | Reword |
| N-3 | nit | `agent-exec.ps1:283` | The `transport_unreachable` hint names `ollamaUrl` (the v1 key); the shipped file uses `ollama.url`. | Reword |
| N-4 | nit | `agent-exec.ps1:289`; `review-spec.ps1:161-172` | The `format_invalid` hint says "The raw text was kept". The reviewer discards it: no output file, nothing on the console, nothing in telemetry. | Reword, or save it |
| N-5 | nit | three scripts, after the call | The `Warning: budget_exceeded` line is printed only after the call returns (up to 1,805 s later) and, on a failure, before the error block. | Accept, or print before the call |
| N-6 | nit | `agent-exec.ps1:928-930` | A 200 HTML or truncated-JSON answer is `empty_response` with an empty detail and an "empty answer" hint (real cmdlet, `200-html`, `200-badjson`). `Test-OllamaModel` names the answer type in the same situation. | Name the type |
| N-7 | nit | `config.ps1:16-24` | `Get-ConfigValue` unrolls arrays: `maxAttempts: [2]`, `warmup: [true]`, `budgetMode: ["enforce"]` and `charsPerToken: [3.5]` are accepted; `maxAttempts: []` becomes `$null` (1 attempt, retries silently off), `warmup: []` and `budgetMode: []` become `$null`. Same pattern as Phase 1. | Reject arrays |
| N-8 | nit | `config.ps1:185` | `charsPerToken: 1e30` throws a localized conversion error without the `registry_invalid:` token (FR-217). | Guard the cast |
| N-9 | nit | `agent-exec.ps1:208` | `charsPerToken` 1e-28 passes validation and `Invoke-AgentModel` then THROWS (decimal overflow), with no record (FR-210 "never throws"). Only a hostile configuration reaches it. | A sane lower bound |
| N-10 | nit | `telemetry.ps1:174-177` | Appending to a v2 CSV without a final newline joins the new row to the last one (1 row read back, 2 expected). | Check the last byte |
| N-11 | nit | `agent-exec.ps1:371, 471, 855` | Comments still say "per process"; D3 made it "per script invocation" (observed: 4 tags requests for 4 script calls in `specify.ps1`). | Comment |
| N-12 | nit | `agent-exec.ps1:386-387` | Stale comment about the old fake hosts (known, WP-2D2 finding 3). | Comment |
| N-13 | nit | `test-agent-exec.ps1`, `test-engine-callsites.ps1` | Q10 survives: no test checks that `eval_count` and the durations reach the record of an `empty_response` or `format_invalid` (Part C shows that they do). | One assertion |
| N-14 | nit | `test-engine-callsites.ps1` | Q15 survives: the `Warning: budget_exceeded` line may be printed for any warning (for example `output_truncated`) without a test noticing. | One case |
| N-15 | nit | `test-engine-callsites.ps1` | Q16 and Q17 survive: line order inside a failure block and the hint text (only "a `Hint:` line exists" is asserted; the reports admit it). | Pin per category |
| N-16 | nit | spec AC-222 vs Execution Order row 5 | AC-222 says Phase 2 acceptance depends on the spike report existing; row 5 excludes AC-222. There is no spike report. | Text |
| N-17 | nit | `test-agent-prompts.ps1:161` | Counts `Invoke-RestMethod` calls as "at most 1" (0 passes). `test-engine-callsites.ps1:738` pins exactly 1, so it is covered. | None needed |
| N-18 | nit | history | `0324aa9`, `635dc7b`, `d9cf715`, `b8d51cc`, `4f39e1f` and `9de754d` are red on their own; not bisectable (reports admit it). | Owner's choice |

## 3. Step 0 and the offline runs

Two consecutive runs of `scripts\test-all.ps1` on the unmodified tree: **19 discovered, 18 executed, 18 PASS, 0 FAIL, 1 skipped** (`test-spec-integration.ps1`), `STATUS: PASS WITH SKIPS`, exit 0, tripwire clean in all 18 suites of both runs. The two logs are identical with the times removed. `git status` was empty afterwards.

Counts: budget 41, errors 39, exec 109, prompts 23, telemetry-v2 34, telemetry 23, build-context 15, engine-callsites 133, mode-propagation 11, registry-callsites 55, registry-engine 61, registry 86, run-agent 5, scan-repository 26, shipped-config 7, spec 17, validate-spec 54; `test-syntax` PASS.

I also ran `test-all.ps1` from a TEMP export of `phase1-hardened`: 11 discovered, 10 PASS, and the same counts for every baseline suite (telemetry 23, build-context 15, mode-propagation 11, registry-callsites 55, registry 86, run-agent 5, scan-repository 26, spec 17, validate-spec 54).

## 4. Part A: acceptance

`Verifies:` lines and the matrix, checked with my own awk script: 56 pairs in the `Verifies:` lines and 56 in the matrix, identical; 24 requirements and 22 criteria, none missing; every requirement and criterion has exactly one `Source:` line.

"Ind" = expected values independent of the code under test (literals, goldens, raw JSON). "Part" = partly recomputed with the same formula.

| AC | Verifying assertions | Ind? | Verdict |
|---|---|---|---|
| AC-201 | `test-agent-prompts.ps1:204, 235, 242, 256, 278, 355`; script part `test-engine-callsites.ps1:757-784, 786, 1297, 1330` | Ind (goldens) | PASS |
| AC-202 | `test-engine-callsites.ps1:957-1058` (run-agent), `1624-1719, 1735` (reviewer, reviser) | Ind | **PASS-with-gap**: the body line asserted is the deviation of I-1 |
| AC-203 | `test-engine-callsites.ps1:1072-1128, 1760-1801`; `test-agent-exec.ps1:1534-1602` | Part (estimate recomputed; also the literals 1143 and 8001) | **PASS-with-gap** (N-14) |
| AC-204 | `test-agent-telemetry-v2.ps1:553-713` | Ind | PASS (edge N-10) |
| AC-206 | `test-agent-budget.ps1:150-286` | Ind | PASS |
| AC-207 | `test-agent-errors.ps1:220-330, 610, 624`; `test-agent-exec.ps1:1271-1353, 2107` | Ind | PASS |
| AC-208 | `test-agent-exec.ps1:268-445, 1808` | Ind | PASS |
| AC-209 | `test-agent-exec.ps1:517-608, 1834` | Ind | PASS |
| AC-210 | `test-agent-exec.ps1:622-707, 1954`; `test-engine-callsites.ps1:800-861, 1426, 1440` | Ind | PASS (also on the real wire) |
| AC-211 | `test-agent-exec.ps1:721-944, 1905, 1927` | Ind | **PASS-with-gap** (I-4) |
| AC-212 | `test-agent-exec.ps1:970-1059` | Ind | PASS |
| AC-213 | `test-agent-exec.ps1:1084-1376, 2046`; `test-engine-callsites.ps1:1053` | Ind | PASS |
| AC-214 | `test-agent-exec.ps1:1623-1786, 1935`; `test-agent-telemetry-v2.ps1:742-790`; `test-engine-callsites.ps1:1719, 1815, 1842` | Part | **PASS-with-gap**: N-13, and the child-process success record does not assert `model_source` (`test-agent-exec.ps1:1638` does) |
| AC-215 | `test-registry-engine.ps1:142-380`; `test-shipped-config.ps1:137-202` | Ind (raw leaves); the execution-record case compares the code with itself, backed by the leaf case | **PASS-with-gap** (I-7) |
| AC-216 | `test-engine-callsites.ps1:1152-1276, 1856-1910` | Ind | PASS; `test-all.ps1` unchanged in git |
| AC-217 | section 3; NFR-201 `test-agent-exec.ps1:2063` | Ind | PASS |
| AC-218 | section 4.1 | Ind | PASS |
| AC-219 | section 4.2 | Ind | **FAIL (text only)**: I-2 |

18 criteria checked: 12 PASS, 5 PASS-with-gap, 1 FAIL (documentation). AC-205 and AC-220 to AC-222 are deferred and were not checked.

### 4.1 Changed lines in the baseline suites (`git diff phase1-hardened`)

Only two baseline suites changed, and no test, mock or fixture of Phase 0 or 1 under `tests/`.

| Suite | Line (new file) | Change | AC-218 row |
|---|---|---|---|
| `test-agent-telemetry.ps1` | 505 | `-ne 14` -> `-ne 31` (and its message) | 5 |
| `test-agent-telemetry.ps1` | 543-548 | AC-014: zero lines -> one line, `model_called` false, `model_not_installed` | 4 |
| `test-agent-telemetry.ps1` | 568-573 | AC-015: the same with `transport_other` | 4 |
| `test-agent-telemetry.ps1` | 611-616 | AC-030: the same with `transport_other` | 4 |
| `test-registry-callsites.ps1` | 219-220 | fake host records `thinkValue` (infrastructure) | 3 |
| `test-registry-callsites.ps1` | 664, 672-674 | case renamed; `think member` False -> True; two assertions added | 1 |
| `test-registry-callsites.ps1` | 722-724 | `think member` False -> True; two assertions added | 2 |

Nothing else changed. Phase 2 suites, diffed line by line from tag `phase2-wp2b2` only: the pinned list and the scan of `test-agent-prompts.ps1`, and `22 -> 23` of `test-agent-telemetry-v2.ps1` (plus one added case), as in AC-218. I did not diff `test-agent-exec.ps1` across its own WP-2C fix round.

### 4.2 Footprint (AC-219, NFR-206)

83 files changed. None of `.ai/agents/*`, `.ai/rules/*`, `AGENTS.md`, `README.md`, `specify.ps1`, `benchmark-models.ps1`, `validate-spec.ps1`, `scan-repository.ps1`, `build-context.ps1` or `test-all.ps1`. Not listed in "Affected Files": `scripts/test-shipped-config.ps1` and the spec file itself (I-2).

## 5. Part B: attacks

**Old vs new console.** 28 failure and success cases, up to three scripts each, through the fake host text extracted verbatim from the suite, with the old scripts from `phase1-hardened`. Exit codes were equal in every case; no case had an undeclared `Invoke-RestMethod` parameter or an allowlist violation; the output-file state was equal. The only added lines are `Category:`, `Hint:` and `Retrying`; the only changed lines are the failure detail lines of I-1 and the localized messages (OQ-214). Every telemetry status change is in I-3. Input errors (blank model, `-Model` with `-Profile`, missing or empty specification, review or context file) give the same output, with no record.

| Item | Result |
|---|---|
| WP-2D1 10.1, 10.2 (detail line, warning after the call) | I-1, N-5 |
| WP-2D1 10.3 (`$execution.model = $Model`) | `model_source` and `profile` come from fields that do not depend on the trimmed text; `think_sent` is right for a resolved profile. Real runs: `prof=fast src=agent`. Holds |
| WP-2D1 10.4, 10.5 (availability before files; context-file errors) | Holds; `ctx-missing` and `ctx-empty` write no record, as the legacy did, because the engine call was not made |
| WP-2D1 10.6, WP-2D2 10.5 (hooks, F-07) | The three `-OnRetry` blocks and the reviewer's `-ResponseCheck` read only their parameters. A hook with a parameter named like `$maxAttempts` saw 2/2/http_5xx/0: the parameter wins, so the case-insensitive shadowing is harmless |
| WP-2D1 10.7 (strict host) | Read only: undeclared named arguments are caught by `$args.Count`; the engine splats a hashtable without `$null` members (`agent-exec.ps1:398-406`) |
| WP-2D1 10.8 (golden coverage) | Still open: a task of whitespace or with a lone CR is not covered at script level (the builders are covered) |
| WP-2D1 10.9, WP-2D2 10.11 (mutants not written) | Written as Q15 to Q17 and Q23, Q24: Q23 and Q24 killed, the rest N-14, N-15 |
| WP-2D1 10.10 (relocation) | Done in WP-2D2; the pinned list and scan hold |
| WP-2D2 10.1 (NFR-205 complete?) | **No**: I-3 |
| WP-2D2 10.2 (failure wording) | I-1. Read only, not run: a `detail` with a newline would print over two lines on the console (telemetry normalizes it, `telemetry.ps1:81`) |
| WP-2D2 10.3 (consumers of reviewer text) | None. `specify.ps1:251-298` uses the exit code and the review file; `test-all.ps1`, `validate-spec.ps1` and the harness suites read no reviewer text. `benchmark-models.ps1` reads telemetry (I-5) |
| WP-2D2 10.4 (Status regex twice) | The two patterns are identical and case-insensitive. `## Status` twice: the first wins in both, old and new equal. Read only: the check body has nothing else that could throw |
| WP-2D2 10.6 (wrappers) | See section 9 |
| WP-2D2 10.7 (guard 4) | Passes; the Phase 0 and 1 suites pass with their own scans |
| WP-2D2 10.8 (AC-215 on the shipped file) | Closed by `test-shipped-config.ps1`; gap I-7 |
| WP-2D2 10.9 (warning on every run) | Confirmed with the real cmdlet: reviewer 7,350 of 6,553, reviser 6,965 of 6,553, printed and in telemetry. Owner-accepted |
| WP-2D2 10.10 (cases not written) | Double status, output path is a directory: old and new equal (exit 2 reviewer, 1 for the others, record `success`). `-Mode` case variant, a missing agent file and a very long task: not run |
| WP-2D2 10.12 (history) | N-18 |
| CSV rule, old file present | AC-204 suites; a v2 CSV re-saved as UTF-16 was appended to (466 bytes) and no v2 file appeared; N-10 |
| Line endings (LF checkout) | TEMP export with `core.autocrlf=false` (library and scripts LF, goldens still mixed): 10 engine and registry suites pass with equal counts. The live prompt then differs from the legacy only in separator line ends (OQ-211, accepted) |
| PowerShell 5.1 traps | N-7, N-8, N-9. `-Profile` hides the automatic variable inside the script only; `List` values are returned with `.ToArray()`; BOM and tr-TR cases are covered by the suites |
| Response shapes (array, null, number, object `done_reason`, hashtable record, failure as text) | One record each, no throw |
| Worst-case wall time, shipped config | Headers phase 2 x 900 + 5 = 1,805 s per call plus the `/api/tags` time (up to 15 s); `specify.ps1` 1 + 4 + 3 = 8 calls (`$maxRevisions` 3, `specify.ps1:71`) = 14,440 s. Arithmetic; a body has no bound (FR-204) |
| `test-engine-callsites` runtime | 131.5 s and 130.8 s here, against a 600 s limit (4.5x margin) |

## 6. Part C: real cmdlet end to end

**Setup.** TEMP root with `scripts`, `.ai`, `AGENTS.md` from the working tree; `.ai/config.json` is the shipped file with `ollama.url` pointing at the loopback server and `retryBackoffSec` 1; each run is a real script in a fresh `powershell.exe`, with `Invoke-RestMethod` and no fake host. The old root is a `phase1-hardened` export with its own shipped file. 61 new and 57 old runs. The server recorded every request: JSON bodies decoded correctly, `Content-Type: application/json; charset=utf-8`, and the non-ASCII task and specification arrived intact.

| Scenario | Scripts | Exit new / old | Requests (gen) | Telemetry (new) |
|---|---|---|---|---|
| success | run, review, revise | 0 / 0 | 1 | success, `attempts` 1, empty `http_status`, `think` omitted |
| success with a `thinking` field of 123 characters | all | 0 / 0 | 1 | `thinking_chars` 123 |
| review FAIL | review | 1 / 1 | 1 | success |
| review without Status | review | 2 / 2 | 1 | `format_invalid: status_missing`, `error` |
| 500 once then ok | all | 0 / 1, 2, 1 | 2 (gap about 1.1 s) | success, `attempts` 2 |
| 500 always | all | 1, 2, 1 / same | 2 | `http_5xx`, `http_status` 500, the server text as detail |
| 500 chunked | run, review | 1, 2 / same | 2 | `http_5xx`, UTF-8 detail correct |
| 500 empty body | run | 1 / 1 | 2 | `http_5xx`, detail is the type name |
| 400 JSON ("does not support thinking") | all | 1, 2, 1 / same | 1 (not retried) | `http_4xx`, 400 |
| 400 plain text | all | 1, 2, 1 / same | 1 | `http_4xx`, detail is the type name |
| 404 on generate | run | 1 / 1 | 1 | `http_4xx`, 404 |
| model missing in tags | all | 1, 2, 1 / same | 0 | one record, `model_called` false (old: none) |
| tags 500 | all | 1, 2, 1 / same | 0 | `http_5xx`, `model_called` false |
| tags `{}` | run | 1 / 1 | 0 | `model_not_installed`, type named in the detail |
| tags dropped | run | 1 / 1 | 0 (**2 tags requests**) | `transport_reset` |
| closed mid-body once, then ok | all | 0 / 1, 2, 1 | 2 | success, `attempts` 2 |
| closed mid-body always | all | 1, 2, 1 / same | 2 | `transport_reset: System.IO.IOException` |
| chunked closed mid-chunk always | run | 1 / 1 | 2 | `transport_reset ... ConnectionClosed` |
| connection dropped always | run | 1 / 1 | 2 | `transport_reset` |
| empty response | all | 1, 2, 1 / same | 1 | `empty_response`, counts kept (old: `success`) |
| `length` with an empty response | all | 1, 2, 1 / same | 1 | `thinking_budget_exhausted`, `thinking_chars` 50 |
| `length` with text | run | 0 / 0 | 1 | `output_truncated` |
| 200 HTML; 200 truncated JSON | run | 1 / 1 | 1 | `empty_response`, empty detail (N-6) |
| `think` true | all | 0 / 0 | 1 | body `"think"` Boolean true; `think_sent` true |
| `think` false | run | 0 / 0 | 1 | body `"think"` Boolean false; `think_sent` false |
| warm-up | run | 0 | 2 (47 ms apart) | first body is `model, options, stream` only |
| oversized task (warn) | run | 0 / 0 | 1, full prompt | `budget_exceeded` (14,046 of 10,649) |
| `enforce`, oversized | all | 1, 2, 1 | 0 | `context_budget_exceeded`, `model_called` false |
| slow past `timeoutSec` 30 | all | 1, 2, 1 / same | 1 (not retried) | `timeout`; run-agent 31.1 s |

For the one `success` pair, old and new console output are identical except for the two Warning lines of the reviewer and reviser. The `specify.ps1` driver (four workflows: fail-revise-pass, 500 on the spec then retry, reviewer without Status, reviser 400) gave the old exit codes and artifacts except for the intended retry (old exit 2, new exit 0); the added lines are the Warning, Retrying, Category and Hint lines, and the reviser failure text changes (OQ-214). 4 tags requests for a 4-call workflow, old and new.

**Divergences between the real host and the fake-host expectations** (the key output):

| # | Divergence | Effect |
|---|---|---|
| V-1 | A dropped `/api/tags` GET is resent once by .NET: the server saw 2 requests (old and new). The fake sees 1. | Tests that count tags requests are right only for the fake. Harmless |
| V-2 | Legacy real body line: for a Content-Length error the real legacy printed an EMPTY line; the fake prints the body, because its stream is readable. | The fake overstates the legacy output; see I-1 |
| V-3 | Real errors carry the body in `ErrorDetails`; the child-process fake never fills it (only `test-agent-exec.ps1:1287` does). | Same result through both paths; the child-process suites cover only the stream fallback |
| V-4 | A real mid-body close is `System.IO.IOException` without `webStatus`; the fake uses `ReceiveFailure`. | Same category; the detail text differs |
| V-5 | `slow-30s` took 40 s for the second and third script. | Artefact of my single-threaded server still sleeping for the previous case (first case 31.1 s); inferred, not instrumented |

No divergence in exit code, category, attempts, record count, request members or `think`.

## 7. Part D: own mutations

30 mutants (TEMP copies of `scripts`, `tests`, `.ai`; SHA-256 of every repository file in those folders equal before and after), plus an unmutated control (all 7 suites pass). **24 killed, 6 survived.** First run lost: my runner used `@($list)` on a `List[object]` (a PowerShell 5.1 trap), fixed and rerun from scratch; the numbers are from the second run.

| Survivor | Mutation | Assessment |
|---|---|---|
| Q08 | `(?s)` removed from the think-strip regex | real gap, I-4 |
| Q10 | response counts dropped from the record of a failed interpretation | real gap, N-13 |
| Q15 | the Warning line printed for any warning | real gap, N-14 |
| Q16 | `Category:` before `PASS or FAIL` in the review block | order, N-15 |
| Q17 | wrong hint on the unreachable path | text, N-15 |
| Q18 | the warm key ignores the URL | not meaningful: FR-213 does not require it (same as WP-2C N03) |

Killed: Q01 to Q07, Q09, Q11 to Q14, Q19 to Q30 (budget comparison and overflow, backoff cap, retryable set, tags cache and detail, `model_called`, `output_truncated`, telemetry cut and CSV rule, registry bounds and default, `think` without a profile, error body source, 4xx and reset boundaries, attempts and `http_status` in the record, prompt template and label, detail cut, retry line, hint, duration unit). Q19 and Q30 are each killed by one suite and survive the other.

## 8. Re-verified claims

| Claim | Result |
|---|---|
| 19 discovered / 18 PASS / 1 skipped, tripwire clean, identical runs | Confirmed |
| Baseline suites keep their counts | Confirmed against a run of `phase1-hardened` |
| Only AC-218 assertions changed in baseline suites | Confirmed |
| "the line is the same text as before" for a JSON error body (WP-2D1, decision 1) | **Refuted** (I-1) |
| One record per call | Confirmed for 61 sequential real runs; **not** for overlapping processes (I-6, pre-existing) |
| `think` absent by default, sent when set | Confirmed on the wire |
| 400 does not retry; 500, reset retry once | Confirmed on the wire |
| `timeout` is not retried | Confirmed (1 request) |
| TimeoutSec bounds the headers phase (31.1 s at 30) | Confirmed |
| Caches are per script invocation (D3) | Confirmed (4 tags for 4 script calls) |
| `http_status` empty on success (D2) | Confirmed |
| `budget_exceeded` on every reviewer and reviser run | Confirmed (7,350 and 6,965 tokens) |
| Wrappers unused | Confirmed: no script names them (`test-engine-callsites.ps1:1910`) |
| Goldens independent of line endings | Confirmed on an LF export |
| Worst case 14,440 s for `specify.ps1` | Confirmed arithmetically (8 calls) |
| `test-engine-callsites` about 125 s | 131.5 s and 130.8 s here |

## 9. The deprecated wrappers

Recommendation: **keep them through WP-2E, delete them in Phase 3** together with their 8 suite cases and the scan exemption. Nothing calls them, but FR-202 and D-208 keep them, so removing them now needs an owner decision. The exemption in `test-agent-prompts.ps1:148-152` names one function and one command only (read; the WP-2D2 mutants M115 to M117 that prove it were not re-run).

## 10. Recommendations

**WP-2E (live).**
1. Calibrate `charsPerToken` from `prompt_chars` and `prompt_eval_count`; keep `warn` until then.
2. Compare the server's real truncation with `possible_prompt_truncation`.
3. Check the 400 for `think` on a model that does not support it (the fake text was the scenario here).
4. Read `error_category` against the real Ollama bodies (Content-Type with charset, non-JSON proxy errors).
5. Do not use benchmark numbers that include retries (I-5).

**Phase 3.**
1. Telemetry writer: a lock or bounded retry before background runs exist (I-6).
2. Give the manifest the warning and `attempts`, so a retried run can be told apart.
3. A hint per source of the failure (tags vs generate, N-1, N-2).
4. Split `test-engine-callsites.ps1` by script (runtime).
5. Remove the wrappers.

## 11. NOT VERIFIED

- Anything against Ollama: real answers, real truncation, real reasoning, the GPU fault, whether a retry clears it.
- Non-loopback network, DNS, proxies, TLS; redirects (302 only through the fake).
- `test-spec-integration.ps1` (skipped).
- The shipped 5 s backoff and the 900 s timeouts as real waits (backoff 1 s and timeout 30 s were used).
- A host with a culture other than es-ES (suites cover es-ES, en-US and tr-TR cases in process).
- The whole mutant set of the earlier reports: not re-run. AC-218 history edits inside `test-agent-exec.ps1`.
- Part C covered the failures the server emulates. The fake-host comparison is per category, attempts and exit code; it is not a byte comparison of every console line for every scenario.
- A slower machine or a parallel `test-all` (runtime margin 4.5x observed on this one).
- The deferred criteria AC-205, AC-220 to AC-222.

## Closing round

**Branch:** `fix/phase2-closing`, from `docs/phase2-final-qa` (`77f4aee`). Six local commits before this section, nothing pushed. Same host (Windows PowerShell 5.1, es-ES, `core.autocrlf=true`), no Ollama, no network. Owner decisions applied as given: I-1 amend the spec and keep the code, I-6 and the deletion of the wrappers to Phase 3 (text only), I-5 a precondition of WP-2E (text only).

### Findings and what happened

| Finding | Result | Commit |
|---|---|---|
| C1 / I-2 | Fixed (text): "Affected Files" lists `scripts/test-shipped-config.ps1`, the spec file and the audit reports; the unchanged roadmap row is gone (the diff against `phase1-hardened` does not contain it). | `be31671` |
| C2 / I-1 | Fixed (text): FR-202 and NFR-205 say that the body line of the `run-agent.ps1` block is `detail`, with the real-host observation (a Content-Length error printed an empty line before). The code is unchanged. | `be31671` |
| C3 / I-3 | Fixed (text): NFR-205 lists reviewer and reviser `success` -> `error` on an empty response and on `format_invalid`, the reviser's lost localized text, the reviewer's line `Ollama request failed: <category>: <detail>`, and the `Warning: budget_exceeded` line on success; FR-202 no longer says that nothing is printed for warnings. | `be31671` |
| N-16 | Fixed (text): AC-222 agrees with Execution Order step 5 (acceptance does not depend on the spike or its report). | `be31671` |
| N-11 (spec) | Fixed (text): the Edge Cases say "per script invocation". | `be31671` |
| I-5 | Deferred as text: DF-201 in the new "Deferred Items" section and a precondition in the WP-2E row. No code change. | `be31671` |
| I-6 | Deferred as text: DF-202 (Phase 3). | `be31671` |
| Wrappers | Deferred as text: DF-203 (delete in Phase 3 with their 8 suite cases and the scan exemption). | `be31671` |
| I-4 | Test added: a `<think>` block over several lines (LF and CRLF, two blocks) is stripped and counted. Kills Q08. | `31cadd4` |
| I-7 | Test added in `test-agent-exec.ps1` (not in `test-shipped-config.ps1`, which only loads `config.ps1`): the baseline file, `spec-reviewer`, 26,000 characters (7,429 tokens against 6,553 available) is sent, `warn`, one request, warning in the result and the record. | `31cadd4` |
| N-13 | Test added: `eval_count`, `prompt_eval_count` and the four durations reach the record of an `empty_response` and of a `format_invalid`. Kills Q10. | `31cadd4` |
| N-14 | Test added for the three scripts: an `output_truncated` success prints no `Warning:` line and the record carries the code. Kills Q15. | `31cadd4` |
| N-15 | Tests added: consecutive line order of the failure blocks of `run-agent.ps1` and `review-spec.ps1` (500, timeout, budget, empty, validation), and the hint of every category on the line right after its `Category:` line, pinned by one phrase of the fixed wording; the unreachable, tags-timeout and not-installed hints for all three scripts. Kills Q16 and Q17. | `31cadd4` |
| N-1 to N-4 | Fixed: the four hints reworded (no "every attempt", the timeout hint names `timeoutSec` and `ollama.healthTimeoutSec`, the unreachable hint names `ollama.url` and the v1 `ollamaUrl`, `format_invalid` no longer says the raw text was kept). Four cases in `test-agent-errors.ps1`; FR-211 says the same. | `b22e433` |
| N-8, N-9 | Fixed: `charsPerToken` is compared as `[double]` (NaN rejected), valid range 0.01 to 10, every bad value gives `registry_invalid: defaults.charsPerToken`. FR-217, AC-215 and OQ-213 updated. Two cases in `test-registry-engine.ps1` and one in `test-agent-exec.ps1` (0.01 and 10 with a 1,000,001-character prompt never throw). | `3bb41cb` |
| N-10 | Fixed: the CSV append reads the last byte and adds a line end when it is not LF (CR LF, or LF after a lone CR; a last byte of 0 is left alone). Two cases in `test-agent-telemetry-v2.ps1`. FR-216 says so. | `842f423` |
| N-11, N-12 (code) | Fixed: three "per process" comments and the fake-host comment in `agent-exec.ps1`. Comments only, so no assertion applies. | `003ca6e` |

No existing assertion was edited, so no item was stopped and no `wip/phase2-closing-*` branch exists.

**Decision to confirm (N-9).** The task suggested a lower bound of 0.1 "for example". The existing boundary table of `test-registry-engine.ps1` (line 247) expects `0.01` to be accepted, so a bound of 0.1 would have needed an edit of that assertion, which the task forbids. I used 0.01. It is enough: at 0.01 a 2 GiB-character prompt is about 2e11, far from the decimal range. If the owner wants 0.1, the exact edit is in `scripts/test-registry-engine.ps1` line 247, `"0.01" = $true` -> `"0.01" = $false` (plus the same bound in `config.ps1` and FR-217).

### Counts

Offline `scripts\test-all.ps1`, run twice at the end: 19 discovered, 18 executed, 18 PASS, 0 FAIL, 1 skipped (`test-spec-integration.ps1`), `STATUS: PASS WITH SKIPS`, tripwire clean in every suite of both runs, the two logs identical with the times removed, `git status` empty afterwards. The baseline run at the start of the round was the same (19 / 18 / 1).

| Suite | Before | After |
|---|---|---|
| test-agent-exec | 109 | 113 |
| test-agent-errors | 39 | 43 |
| test-agent-telemetry-v2 | 34 | 36 |
| test-engine-callsites | 133 | 160 |
| test-registry-engine | 61 | 63 |
| every other suite | as in section 3 | unchanged (budget 41, prompts 23, telemetry 23, build-context 15, mode-propagation 11, registry-callsites 55, registry 86, run-agent 5, scan-repository 26, shipped-config 7, spec 17, validate-spec 54) |

`test-engine-callsites.ps1` takes about 164 s (limit 600 s). `scripts\validate-spec.ps1` passes on the spec after each commit; the `Verifies:` lines and the matrix were not touched.

### Mutation re-run

TEMP copies of `scripts`, `tests`, `.ai`, `specs`, `docs`; SHA-256 of the 193 tracked repository files equal before and after. An unmutated control passes (exec 113, errors 43, registry-engine 63, telemetry-v2 36). The QA does not give the exact edit of Q15 to Q17, so those are rebuilt from the descriptions in section 7; each is run in every place it can apply.

| Mutant | Mutation | Result |
|---|---|---|
| Q08 | `(?s)` removed from the think-strip regexes | killed by `test-agent-exec` (1 case) |
| Q10 | response counts dropped from the record of a failed interpretation | killed by `test-agent-exec` (1 case) |
| Q15a, b, c | the Warning line printed for any warning, in `run-agent`, `review-spec`, `revise-spec` | each killed by `test-engine-callsites` (1 case) |
| Q16 | `Category:` before `PASS or FAIL` in the review validation block | killed by `test-engine-callsites` (1 case) |
| Q17a | wrong hint text for `transport_unreachable` | killed by `test-agent-errors` |
| Q17b | `Test-OllamaModel` returns the `transport_other` hint on a failed `/api/tags` | killed by `test-agent-exec` (1 case) |
| M1 | `charsPerToken` lower bound back to "greater than 0" | killed by `test-registry-engine` (2 cases) |
| M2 | `charsPerToken` compared as `[decimal]` again | killed by `test-registry-engine` (2 cases) |
| M3 | NaN accepted | killed by `test-registry-engine` (1 case) |
| M4 | no line end before the CSV append | killed by `test-agent-telemetry-v2` (1 case) |
| M5 | a line end added also when the file ends with LF | killed by `test-agent-telemetry-v2` (3 cases) |
| M6 | `http_5xx` hint says "every attempt" again | killed by `test-agent-errors` |
| M7 | `timeout` hint loses `ollama.healthTimeoutSec` | killed by `test-agent-errors` |
| M8 | `format_invalid` hint says the raw text was kept | killed by `test-agent-errors` |
| M9 | unreachable hint names only `ollamaUrl` | killed by `test-agent-errors` |

5 QA survivors (as 8 mutants) and 9 mutants of my own changes: 17 of 17 killed. Q18 was not rerun (the QA judged it not meaningful).

### Not fixed, and why

- **N-5** (the Warning line is printed after the call): accepted as in the report; no change.
- **N-6** (a 200 HTML or truncated JSON names no type), **N-7** (arrays accepted by `Get-ConfigValue`): not in the list of this round; open, low risk.
- **N-17**: none needed. **N-18** (red intermediate commits): the owner's choice; this round added no commit that was red in the suites it touches (the touched suites were run at each commit, the whole of `test-all.ps1` only at the tip).
- **WP-2D1 10.8** (a whitespace-only or lone-CR task at script level) and **V-1 to V-5** (real-host divergences of the fake): unchanged.
- **I-5, I-6, wrappers**: recorded, not built (above).
- Still NOT VERIFIED: everything against a real Ollama, as in section 11. The new hint wording and the `Warning` line were checked only through the fake host.
