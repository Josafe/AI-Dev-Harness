# Phase 2, WP-2C: independent adversarial review

**Date:** 2026-11-23
**Branch:** `docs/phase2-wp2c-review`, from `origin/feat/phase2-wp2c` at `0db1d49` (not merged). Only this file was added; no source, test or spec file was changed.
**Target:** `scripts/lib/agent-exec.ps1` (WP-2C functions), `scripts/test-agent-exec.ps1`, the two edits of `scripts/test-agent-prompts.ps1`, against spec revision 3.1 and `docs/audits/2026-11-23-phase2-wp2c.md` ("the report").
**Host:** Windows PowerShell 5.1.26100.9818, culture and UI culture es-ES.

## 1. Verdict

**APPROVE WITH CHANGES.** 0 blockers, 10 important, 15 nits.

The design, retry arithmetic, whitelist, `think` handling and budget order hold. The key unverified assumption (A-201) holds on the real cmdlet, with one exception that the code already handles. The main defects are paths that break the "never throws, exactly one record" contract, and one hook path that fails open.

### MUST change before WP-2D

| # | Where | Evidence | Proposed change |
|---|---|---|---|
| M-1 (F-01) | `agent-exec.ps1:878-881` | Real default transport, 200 with `"prompt_eval_count":"n/a"`: `Invoke-AgentModel` THREW `InvalidCastFromStringToDecimal`, 0 telemetry lines. Also an object, and `1e300`. | Compare only when the value is `[int]`, `[long]`, `[decimal]` or `[double]`, and compare as `[double]`. |
| M-2 (F-02) | `agent-exec.ps1:892-903` | A `-ResponseCheck` whose body reaches a `break` or `continue` outside its own loop gives `status` **ok** (section 5, cases 08, 09): the format gate fails open. | Run the check inside `foreach ($once in 1) { try { ...; $checkCompleted = $true } catch { } }`, then `if (-not $checkCompleted) { $code = 'response_check_error' }`. |
| M-3 (F-03) | `agent-exec.ps1:736-745` (and `:702` for `break`) | `-Sleep` that throws: exception, 0 records. `-OnRetry` returning an object with `Attempts`: exception, 0 records. `-OnRetry` with `break`: `status` error with an EMPTY category. | `$null = & $OnRetry ...` and `$null = & $Sleep $wait`, each in `foreach ($once in 1) { try {...} catch { $null = $_ } }`. Contain `& $Transport` the same way. |
| M-4 (F-04) | `agent-exec.ps1:412` | Real 201, 204 and 206 answers were all recorded as 200. FR-216: numbers that were not measured are written as an empty string. | `httpStatus = $null` on success, and update `test-agent-exec.ps1:1063`; or an explicit owner ruling in the spec that 200 means "2xx assumed". |
| M-5 (F-08, F-09) | `test-agent-exec.ps1:119-125, 461, 840` and the retry section | Sending `stream` as the string `"False"` survives in generate and warm-up, although the test titles say "JSON false". Removing the default wait, or making it milliseconds, survives. | `Assert-True ($body.stream -is [bool])` in both; one case with backoff 1, no `-Sleep`, asserting 900 ms or more. |
| M-6 (F-05, A-201) | spec RK-203, A-201, FR-204 | `-TimeoutSec` does not bound the response body (section 4). | Text only, by the owner: see F-05 and section 4. |

The code parts of M-1 to M-3, except the `& $Transport` containment, were applied to a TEMP copy: suite 91 passed, 0 failed; cases 01 to 04, 07 to 10 then returned one record and the expected status. The `& $Transport` containment and M-4, M-5 were not tried.

## 2. Findings

| ID | Severity | Location | Finding and evidence | Suggestion |
|---|---|---|---|---|
| F-01 | important | `agent-exec.ps1:880` | Unguarded `[decimal]` cast of a server value. Violates FR-210 and FR-216. Reproduced end to end through the real transport. | M-1 |
| F-02 | important | `agent-exec.ps1:895` | `break`/`continue` in the check leaves the `:call do` loop before `$failureName` is set. | M-2 |
| F-03 | important | `agent-exec.ps1:740, 743` | Hook output is collected into the result of `$sendWithRetry`. Plain strings work only because of member enumeration. `-Sleep` is not guarded although `-OnRetry` is. | M-3 |
| F-04 | important | `agent-exec.ps1:412` | An assumption is stored in telemetry as a measurement. | M-4 |
| F-05 | important | `agent-exec.ps1:400`, spec RK-203 | `TimeoutSec` 2: a body completed after 6.0 s and a 9.2 s trickle both succeeded; a silent body ended as `timeout` at 300.1 s (the .NET read timeout, not the profile's). See section 4 for the worst case. | M-6: state that the body is bounded only by 300 s of silence; not fixable with the five allowed parameters. |
| F-06 | important | `agent-exec.ps1:376, 500, 670` | The caches are per script scope, not "per process". In one process, a parent cached `/api/tags` and each `&` child requested it again (3 requests; also 1 for a child that inherits the functions). `specify.ps1` runs the scripts with `&`, so tags is re-queried and the warm-up repeats per script. | Amend FR-213 and FR-215 to "per script invocation", or use a `$global:` store. Owner decision. |
| F-07 | important | `agent-exec.ps1:740, 895` | A hook that is not a closure sees the engine's variables first. A caller's `$Model`, `$attempts`, `$url` and `$text` were read as the engine's values; `$warnings.Add('INJECTED')` in a check changed `meta.warnings`. | WP-2D rule and a header comment: hooks use only their parameters or uniquely named variables. Do not use `GetNewClosure()` where script functions are needed. |
| F-08 | important | `test-agent-exec.ps1:119-125` | `Assert-Equal` compares text, so types are not checked except where `-is` is used (N06, N07 survive). | M-5 |
| F-09 | important | `test-agent-exec.ps1:422-435` | The default `Start-Sleep` branch never runs (N08, N09 survive). My run measured 1012 ms for backoff 1, so the code is right; the suite does not prove it. | M-5 |
| F-10 | important | `agent-exec.ps1:673, 953` | `meta.callId` never equals the telemetry `call_id` (confirmed), so a result cannot be joined to its record. | Optional `-CallId` on the writer (decision 1). |
| F-11 | nit | `test-agent-exec.ps1:1512-1515` | Vacuous: `$bare` is never passed to anything, so "no logs folder" cannot fail. | Assert that no file appears under `$tempRoot`. |
| F-12 | nit | `test-agent-exec.ps1:1534` | The title says the request reached the server, but the fixture is `ConnectFailure`. FR-216 lists an unavailable server as `model_called` false; the code records true. | Clarify the spec: true means "a request was attempted". |
| F-13 | nit | `agent-exec.ps1:511` | `$modelCalled = $true` is never read. | Delete. |
| F-14 | nit | `agent-exec.ps1:787-792, 816` | After a failed warm-up `think_sent` is `false`/`true` although no request with `think` was sent. Disagrees with decision 5. | Set `thinkSent` when the generation is sent. |
| F-15 | nit | suite, warm-up and tags cases | N12 (`http_status`), N13, N14 (hint, detail) on warm-up failure and N27, N28, N30 on tags survive. | Assert them. |
| F-16 | nit | suite | N10 (stream fallback decoded as ASCII) survives. | A non-ASCII chunked body. |
| F-17 | nit | `agent-exec.ps1:868-869` | An unclosed `<think>` cut by `length` is `ok` and returns the reasoning as the answer. Conforms to "legacy regex, unchanged". | Spec question. |
| F-18 | nit | `agent-exec.ps1:861-876` | 200 with truncated JSON (no Content-Length), HTML or 204 is `empty_response`, no retry, empty detail. A non-tags 200 is cached as "no models". | Detail naming the type; do not cache without a `models` member. |
| F-19 | nit | `agent-exec.ps1:803` | The warm key ignores options: `num_ctx` 8192 then 16384 warmed once. Conforms to FR-213. | Note for WP-2E. |
| F-20 | nit | `agent-exec.ps1:502, 676` | N01, N02 (no `TrimEnd`) survive. | One case with a trailing slash. |
| F-21 | nit | `agent-exec.ps1:594, 937` | A non-numeric `httpStatus` from an injected transport throws after the call, 0 records. | Cast only integers. |
| F-22 | nit | `agent-exec.ps1:797` | A v1 `timeoutSec` of `"10m"` throws (v1 is not validated), 0 records. Legacy also failed. | Leave or document. |
| F-23 | nit | `agent-exec.ps1:438-439` | The fallback reads the whole error body without a bound; a stalled chunked 500 took 6.0 s with `TimeoutSec` 2. | Read at most 4096 characters. |
| F-24 | nit | spec FR-211 | Refused loopback took about 2.02 s: with `TimeoutSec` 2 it is `timeout`, with 15 it is `ConnectFailure`. `healthTimeoutSec` 1 or 2 hides "unreachable". | Document. |
| F-25 | nit | `agent-exec.ps1:896` | Only the first output of the check counts: `$null; 'code'` is accepted. N19 survives. | Any non-blank output rejects. |

## 3. Claims re-verified

| Claim of the report | Result |
|---|---|
| Baseline 17 discovered / 16 PASS / 1 skipped, tripwire clean | Confirmed, one run; `git status` empty |
| `test-agent-exec.ps1` 91 passed; NFR-201 median | Confirmed: 91 / 0; median 15.6 ms, max 56.4 ms |
| Four files changed; 12 functions | Confirmed (`git diff --numstat c008ecf 0db1d49`; AST count) |
| Mutations killed | Sampled 11 of 63 (R2, R3, R5, R8, T1, I3, B1, X3, H1, H8, O5): all killed, counts equal. The rest not re-run |
| Library hash `D60AA316...66C9` | Confirmed |
| Off-by-one of the attempts | None found: R3 killed; real 500 with `maxAttempts` 2 gave `attempts` 2 |
| "One record per call" | **Refuted** for F-01, F-03, F-21, F-22; no path wrote two |
| "never an exception" (AC-213) | **Refuted** (F-01, F-03) |
| `think` false through the file loader | Confirmed: Boolean in the record, `"think":false` in the body, `thinkSent` false |
| Budget before body and warm-up; no truncation | Confirmed by reading `:761-775`; B1 killed |
| "An `OnRetry` hook that throws does not lose the call" | Confirmed for a throw; `break` and emitted objects do lose it (F-03) |
| Cache "per process" (FR-215 case) | **Refuted** across scripts (F-06) |
| Telemetry value types | Confirmed from a JSONL line: numbers and `model_called` are JSON numbers and a boolean |
| The scan edits of `test-agent-prompts.ps1` | Read and consistent; mutation results of report section 8 item 12 not re-run |

## 4. Real-host experiment (throw-away `TcpListener` on 127.0.0.1, OS-chosen port, child process with a time limit, killed at the end)

37 behaviors, 43 rows (POST, plus GET for six), `TimeoutSec` 2. es-ES against en-US: **no difference** in the 14 compared fields (type, status, StatusCode, ErrorDetails, body, category, retryable, detail), while the messages did change language for a 500 and a timeout. A subset (ok, 500s, refused) was also run in tr-TR with the same categories.

| Server behavior | Real `Invoke-RestMethod` | `ErrorDetails` | Record from `Invoke-OllamaHttp` | Category |
|---|---|---|---|---|
| 200 JSON, `charset=utf-8`, non-ASCII | returns object, text correct | - | ok, 200 | - |
| 200 JSON without charset, non-ASCII | returns, text **mojibake** (ISO-8859-1) | - | ok, 200 | - |
| 201, 206 / 204 | returns object / empty string | - | ok, **200** | 204: `empty_response` |
| 200 HTML / invalid JSON | `XmlDocument` / `String` | - | ok, 200 | `empty_response` (end to end) |
| 500, 404, 400, 429 with JSON body | `WebException` `ProtocolError`, `HttpWebResponse`, StatusCode present | body, and the cast equals `Message` | type, `ProtocolError`, status, body | `http_5xx`, `http_4xx` |
| 500 chunked | same | **null** | body from the stream | `http_5xx` |
| 500 / 400 empty body | same | null | body null | `http_5xx` / `http_4xx` |
| 500, 10,012 characters | same | full | body cut to 4096, detail falls back to the type | `http_5xx` |
| 500, body shorter than Content-Length | `WebException` `ReceiveFailure`, no response | null | status lost | `transport_reset` |
| 304 | `ProtocolError` | null | 304 | `transport_other` |
| 302 | followed as a GET with no body | - | ok, 200 | - |
| closed, no answer / in headers | `ConnectionClosed` | null | `ConnectionClosed` | `transport_reset` |
| reset, no answer | `ReceiveFailure`, inner `IOException` | null | `ReceiveFailure` | `transport_reset` |
| **closed or reset mid-body** (Content-Length or chunked) | **`System.IO.IOException`**, not a `WebException` | null | `IOException`, no webStatus | `transport_reset` |
| closed mid-body, no Content-Length | **returns a string** | - | ok, 200 | `empty_response` |
| garbage | `ServerProtocolViolation` | null | same | `transport_other` |
| headers after 6 s | `Timeout` at 2.0 s | null | `Timeout` | `timeout` |
| body split over 6 s / 9 s trickle | **returns** after 6.0 s / 9.2 s | - | ok, 200 | - |
| body silent 340 s | `Timeout` at **300.1 s** | null | `Timeout` at 300.0 s | `timeout` |
| refused port, `TimeoutSec` 2 / 15 | `Timeout` / `ConnectFailure`, about 2.0 s | null | same | `timeout` / `transport_unreachable` |

The echo case returned the 21 bytes sent, unchanged, with `application/json; charset=utf-8`: the `byte[]` body is not re-encoded. With `ErrorDetails` filled, the response stream still opened but was empty (0 characters); without it, the body was still readable, so the fallback order is right. An error body without charset was decoded as UTF-8. The results with non-ASCII text are from a rerun: the first server file held a mis-encoded literal (fixed, then rerun in three cultures).

**A-201:** confirmed for HTTP and connection errors. **Refuted in part:** "other exception types come only from fakes or bugs" is false, because a mid-body disconnect is a real `IOException`. A-206 and FR-211 already classify it as `transport_reset`. Decision 2 (cast of `ErrorDetails`): confirmed. Decision 6: refuted.

### Worst-case wall time (arithmetic, not observed)

| Case (timeoutSec 900, maxAttempts 2, backoff 5) | Seconds |
|---|---|
| Headers phase only, no warm-up: 2 x 900 + 5 | 1,805 (RK-203 agrees) |
| With warm-up, both phases retried | 3,610 |
| Adding one silent body gap of 300 s per attempt | 2,405 (4,810 with warm-up) |
| Body that keeps trickling | no bound |
| Registry maximum: 5 x 14,400 + 4 waits of 60 | 72,240 (RK-203 says 72,075, which assumes backoff 5); 144,480 with warm-up |

`timeout` is never retried, so these need a 5xx or reset just before the limit. The `healthTimeoutSec` of `Test-OllamaModel` is extra.

## 5. In-process attacks (fakes; telemetry lines counted)

| Case | Result |
|---|---|
| 01-03 bad `prompt_eval_count` | THREW, 0 lines (F-01) |
| 04 `-Sleep` throws; 07 `-OnRetry` returns an object | THREW, 0 lines (F-03) |
| 05, 06 hooks emit strings | ok, 1 line |
| 08, 09 check with `break` / `continue` | **ok**, 1 line (F-02) |
| 10 `-OnRetry` with `break` | error, empty category, 1 line |
| 12 check returns `$false` | `format_invalid` |
| 13 unclosed `<think>`; 14 only `</think>` | ok with the reasoning in `text` (F-17) |
| 15 `response` is an object | ok, text `@{a=1}` |
| 18 `ok` is the string `"false"` | treated as success by `Invoke-AgentModel` (`-not`), but `Test-OllamaModel` uses `-eq $true` |
| 17, 25 bad `httpStatus`, v1 `timeoutSec` text | THREW, 0 lines (F-21, F-22) |
| 26 telemetry root is a file | ok, warning, 0 lines |
| 31 text read with `Get-Content -Raw` | body is a plain JSON string |
| 41 caller in StrictMode 2 | throws; the harness does not use StrictMode |

## 6. My mutations (TEMP copy, `test-agent-exec.ps1` only; hashes of all 164 files in `scripts` and `tests` equal before and after)

39 applied plus an unmutated control (passed). 14 killed: N20, N21, N22, N24, N26, N29, N31, N33, N34, N35, N36, N37, N38, N39. 25 survived:

| Class | Survivors |
|---|---|
| Real gaps | N01, N02 trailing slash; N06, N07 `stream` as a string; N08, N09 default wait; N10 fallback encoding; N11 error `httpStatus` on interpretation failure; N12-N14 warm-up failure fields; N15 constant `callId`; N16 `elapsedMs` 0; N17 record `StartedAt`; N18 `thinking_chars` 0 instead of blank; N19 check output; N27, N28, N30 tags hint and detail |
| Not meaningful or equivalent | N03 (FR-213 does not mention the URL), N04, N05 (case of the key), N23 (Ollama sends lower case), N25 (needs an unset variable: equivalent), N32 (registry already case-checked) |

## 7. The report's decisions

| # | Answer |
|---|---|
| 1 `callId` differs | **Change:** optional `-CallId` on the writer, GUID by default. "Always a new GUID" still holds if the engine generates it. Needs the owner to allow the edit of `telemetry.ps1` (F-10) |
| 2 no `failure.message` | **Accept.** The cast equals `Message` on the real cmdlet. D-209 accepted OQ-214 ("may carry"), so the owner should confirm the line is dropped |
| 3 injected `WebException` is `transport_other` | Accept (FR-204) |
| 4 `thinkingChars` counts inner text | Accept |
| 5 blank `thinkSent` on refusals | Accept, but apply it to warm-up failures too (F-14) |
| 6 `httpStatus` 200 | **Change** to not measured (M-4) |
| 7 `model_called`, `attempts` | Accept; clarify the meaning for connect failures (F-12) |
| 8 `OnRetry` arguments, swallow | Accept, and contain output and `break` (M-3) |
| 9 check semantics | **Change:** fail closed (M-2); any non-blank output rejects (F-25) |
| 10 `Test-OllamaModel` shape, no retry | Accept; do not cache a 200 without `models` (F-18) |
| 11 warm-up key | Accept; the per-process wording is wrong (F-06) |
| 12 resolution warnings not copied | Accept |
| 13 body bytes | Accept; confirmed on the wire |
| 14 11-line scan edit | Accept |

## 8. Report section 8, item by item

1: sections 2 to 4. A `WebException` wrapped in another exception was not produced by the real cmdlet in any case. 2: confirmed on the wire; the splat has no extra parameter. 3: no off-by-one; time in section 4. 4: refuted (F-01, F-03). 5: holds. 6: holds. 7: holds except F-01, F-17; `>=` with `C - R` killed by I3. 8: no shadowing bug inside the engine; hooks are exposed (F-07). 9: `ToString()`, `"$_"` and `Out-String` would bypass the scan; a read of the three functions found none, apart from the deliberate cast. 10: types are right; `http_status` 200 is F-04. 11: F-08, F-09, F-11, F-12. 12: pins names only, as the report says. 13: confirmed.

## 9. NOT VERIFIED

- Anything against Ollama, a real model, or a non-loopback network; DNS failures (no external lookup was made); proxies; TLS; redirects other than 302.
- M-4, M-5 and the `& $Transport` part of M-3 as patches.
- 52 of the report's 63 mutations; the second `test-all` run; a child-process host with the Phase 1 fake parameters.
- Infinite loop from a transport that runs `continue` (inferred from `agent-exec.ps1:730`, not run).
- Worst-case times (arithmetic only); concurrency of telemetry writers.
- The scratch server, probe, attack and mutation scripts are in `%TEMP%\wp2c-review`, not committed.
