# Phase 2 specification: independent review

**Date:** 2026-11-22
**Reviewed:** `specs/harness-phase-2-shared-engine.md` (Draft, revision 1, 654 lines, 69,603 bytes) and `docs/audits/2026-11-22-phase2-spec-notes.md`, at commit `7c5e8ed` (branch `docs/phase2-spec`).
**Reviewer:** an independent session that did not write the spec. Local commit only; nothing pushed; the spec was not modified; no Ollama call was made.
**Method:** read the spec, the notes, `scripts/lib/config.ps1`, `scripts/lib/telemetry.ps1`, the three scripts, `scripts/test-agent-telemetry.ps1`, `scripts/test-registry-callsites.ps1`, `scripts/test-all.ps1`, `scripts/specify.ps1`, `scripts/benchmark-models.ps1`, `.ai/config.json`, the roadmap, and the Phase 0 and Phase 1 specs. Facts were re-measured (table in section 3). PowerShell 5.1 mechanisms were tried on this machine (5.1.26100.9818, CLR 4.0.30319, culture es-ES) with an in-process fake `WebResponse` and with a throw-away loopback `TcpListener` in a PowerShell runspace (127.0.0.1, OS-chosen port, hard time limits; no Ollama). `scripts\test-all.ps1` was run once, offline, on the unmodified baseline. Scratch files stayed under `%TEMP%\p2rev`.

---

## 1. Verdict: APPROVE WITH CHANGES

The architecture is sound and the author was unusually honest about the budget problem. The spec is implementable once the changes in section 2 are made. **3 blockers** and **14 important** findings (plus 9 nits) (section 4); the blockers are small text changes, not redesigns. No work package should start until the three blockers and the "MUST" items marked *before WP-2A* are applied. The other MUST items are due before the package named next to each.

The three blockers:

1. **The default `budgetMode` is `enforce`, which contradicts the spec's own compatibility rules.** A v2 file without the new keys (the shipped Phase 1 `.ai/config.json`) would refuse every reviewer and reviser call (F-01).
2. **AC-218 omits a baseline assertion that FR-214 breaks** (`scripts/test-registry-callsites.ps1:718`), while AC-218 and AC-219 forbid editing any other assertion. WP-2D cannot pass as written (F-02).
3. **FR-203 "byte-identical" and its fixtures are not implementable as written under `core.autocrlf=true`.** I verified that git rewrites files with mixed line endings on commit, so mixed-ending fixtures cannot be stored as files; and the template separators' line endings change silently (F-03).

---

## 2. Changes that MUST be made before implementation

Line numbers refer to the spec file as reviewed. "Replacement" is proposed text; the owner may reword it, but the substance is needed.

### M-1 (blocker, before WP-2A). Make `warn` the default budget mode (F-01)

Locations: FR-209 line 140; line 143; FR-217 table line 247 and line 250; RK-201 line 597; OQ-201 line 626.

- **Line 140.** Replace `defaults.budgetMode` is `enforce` or `warn` (default `enforce`, as XR-03). With `enforce`, ...` with:
  > `defaults.budgetMode` is `enforce` or `warn` (default `warn`). `enforce` implements XR-03 literally; it is selected only by a configuration that sets it. With `enforce`, `Invoke-AgentModel` stops before any request with category `context_budget_exceeded`. With `warn` (the default), it proceeds, adds the warning code `budget_exceeded` to the result and the telemetry, and the script prints one added line `Warning: budget_exceeded (estimated N tokens, available M).` (F-10). Never truncates the prompt (XR-03).
- **Line 143.** Replace the RECOMMENDATION with: `RECOMMENDATION (OQ-201): the code default is warn; the shipped .ai/config.json adds no budgetMode key until WP-2E has calibrated charsPerToken; flipping to "enforce" is a configuration change made with the measurements.`
- **Line 247.** Default of `defaults.budgetMode`: `"warn"`.
- **Line 250.** Delete `and budgetMode "warn" (OQ-201)` from the list of keys added to `.ai/config.json` (the key is then absent, which means `warn`). Keep `charsPerToken` 3.5 only if the owner wants it written down.
- **Line 597 (RK-201).** `...Mitigation: the default is warn; enforcement is tested with fixtures that set it explicitly; the shipped configuration never sets enforce before WP-2E.`
- **Line 626 (OQ-201).** Replace `implement enforcement with default enforce when the key is absent (as XR-03), but ship "budgetMode": "warn"` with `implement enforcement, default warn when the key is absent, shipped config without the key`. Keep the rest.
- **AC-215.** Add: `a v2 file without defaults.budgetMode resolves to warn; the shipped .ai/config.json at phase1-hardened (frozen copy) resolves to warn and a reviewer-sized stub prompt is sent, not refused.`

Why: see F-01. With the proposed text, Phase 1 NFR-103 ("v2 files without them keep working"), FR-217, the rollback paragraph (reverting only the `.ai/config.json` commit "returns the registry to its Phase 1 state") and RK-201 all become true.

### M-2 (blocker, before WP-2D). Complete the AC-218 table (F-02)

Location: AC-218, table row 1 (line 446) and the sentence that says "the four other `think member` checks".

Replace row 1 with two rows:

> | `scripts/test-registry-callsites.ps1`, the case "review-spec -Profile alpha: profile parameters, num_ctx from contextWindow, think never sent" (line 662; renamed) | expects the `think` member present and true | Phase 1 AC-109 superseded by FR-214 / AC-210 |
> | `scripts/test-registry-callsites.ps1`, the case "run-agent with a v2 config: agent profile, server line, health timeout and body" (line 707; the `spec` agent resolves to profile `alpha`, which has `think` true), assertion `think member` at line 718 | expects the `think` member present and true | same |

and replace "the four other `think member` checks (default, absent, v1) still expect it absent" with "the three other `think member` checks (lines 658, 700 and 737: profile `beta` and v1 configurations) still expect it absent".

Also add to AC-218 a closing check: *"WP-2D runs the two suites before and after the edit and lists every assertion whose result changed; the list equals this table."* That is how an omission like line 718 gets caught mechanically.

### M-3 (blocker, before WP-2A). Make FR-203 testable and honest about line endings (F-03)

Locations: FR-203 title and rules 2 to 4 (lines 83 to 93); AC-201 (line 306); Affected Files row for `tests/golden/*` (line 537); OQ-208 (line 633).

- **Title.** `FR-203 — Prompts are identical to the legacy prompts, apart from line endings of the builders' own template text`.
- **Rule 3, add:** `The pass-through test builds its CRLF, LF and mixed inputs in memory (for example "a`r`nb`nc"); it does not read them from fixture files, because git with core.autocrlf=true rewrites a committed file with mixed endings to LF.`
- **Rule 1, add:** `Golden files and fixture inputs under tests/golden/ are protected by a new tests/golden/.gitattributes containing "* -text" (added in WP-2A, listed in Affected Files), so that a checkout does not change their bytes. The suite also asserts that the golden files contain no CR when they are meant to be LF-only (a guard against a missing attribute).`
- **New rule 6:** `Template separators. The legacy templates take their line endings from the script file (verified: a CRLF script gives CRLF in the here-string; an LF script gives LF). The builders' templates take theirs from agent-exec.ps1. FR-203 does not claim to preserve the template bytes; the owner decides in OQ-211 whether the builders emit CRLF (as the legacy scripts do on a standard checkout), LF, or follow the file.`
- **OQ-211 (new).** *Template line endings.* `RECOMMENDATION: the builders build their template lines with an explicit constant separator and use CRLF, which is what the three legacy scripts produce on this repository's standard checkout; then the live prompt differs from today's only where an input segment's own endings differ. Record it as a deviation from the roadmap's "byte-identical" (FR-203, AC-201).`

### M-4 (important, before WP-2B). Fix the telemetry writer contract (F-04)

Locations: FR-216 (lines 227 to 233); AC-214 (line 410).

Add to FR-216:

> The new parameters of `Write-HarnessModelTelemetry` are all optional, so the existing call with `-Root -Agent -Model -StartedAt -Status` (used by `test-agent-telemetry.ps1:491`) still works and produces a v2 record with the defaults below. `prompt_chars` is `len(system) + len(prompt)` (the `E` numerator of FR-209). Not-applicable values: integers that were not measured (`http_status`, `thinking_chars`, `attempts` before any attempt) are written as an empty string, booleans as `true`/`false`, `warnings` empty when none; `context_window`, `est_prompt_tokens` are empty when the budget is `skipped` and `prompt_chars` is still written. A call starts at the model-availability check: errors found before it (blank model, missing or empty input file, missing context file) write no record, as today (this keeps Phase 0 AC-106 and the Phase 1 `Assert-NoRequest` cases unchanged). The `error` text has CR and LF replaced by a space and is cut at 500 characters.

Add to AC-214 literal expectations (for example: stub system `"AB"` and prompt `"CDE"` give `prompt_chars` 5 and, at `charsPerToken` 2.5, `est_prompt_tokens` 2) so the expected values are not derived from the code under test.

### M-5 (important, before WP-2B). Transport and fake contract details (F-05)

Locations: FR-204 (line 102); FR-215 (line 225); AC-209 and AC-213.

- **FR-204, add:** `Invoke-OllamaHttp calls Invoke-RestMethod with exactly -Uri, -Method, -Body, -ContentType (generate and warm-up only) and -TimeoutSec, and no other parameter. The Phase 0 and Phase 1 fake hosts declare exactly these parameters; an extra one (for example -ErrorAction or -Headers) makes every child-process suite fail.`
- **FR-215 and FR-213, add:** `The per-process caches (the /api/tags result and the warmed-model set) are held in a script variable that Reset-AgentExecState clears; every in-process test calls it first. Without it a cached success hides the next test's "model missing" scenario.` Add `Reset-AgentExecState` to the FR-201 function table.
- **AC-202:** state that the child-process fake host used for the failure matrix is a new fake host (call it `fake-host-engine`, in `scripts/test-engine-callsites.ps1`) that throws a typed `System.Net.WebException` through `Add-Type`d `FakeWebResponse`; the Phase 0 and Phase 1 fake hosts throw plain `RuntimeException` and cannot produce `http_5xx`, `http_4xx`, `timeout` or `transport_reset` (verified: they classify as `transport_other`).

### M-6 (important, before WP-2D). Resolve the vocabulary, console, and scope statements (F-08, F-09, F-10, F-11, F-12, F-13)

- **FR-202, add** (after "Added output, only on failure"): `run-agent.ps1 keeps its existing "Status: <code>" line and the response body line inside the === OLLAMA ERROR === block (read from failure.httpStatus and failure.body). One line "Retrying (attempt 2 of N) after <category>, waiting S s." is printed before each wait of a retry (F-08).`
- **FR-214, add:** `think is sent only when Execution.profile is non-empty (the profile named in the resolution). When the model comes from -Model or AI_HARNESS_MODEL and matches no profile, the parameters are borrowed from another profile (Phase 1 FR-104) and think is omitted: a borrowed think:true makes Ollama answer 400 for a model that does not support it (F-09).` Add the matching case to AC-210.
- **NFR-205, add to the list of intentional changes:** `the console no longer prints the localized exception message in the === OLLAMA ERROR === blocks (replaced by Category and Hint, plus the existing Status and body lines); the telemetry status of an empty run-agent response changes from success to error; two extra console lines on retry and on budget warning.` (F-13)
- **FR-211, decide the vocabulary now (OQ-212, new).** The roadmap's Phase 3 manifest lists `ollama_unreachable`, `http_error`, `empty_output`, `invalid_output_format`; the spec uses `transport_unreachable`, `http_4xx`/`http_5xx`, `empty_response`, `format_invalid`. RECOMMENDATION: keep the spec's finer names in telemetry, add a one-line mapping table to the spec ("telemetry category -> manifest category") so Phase 3 cannot drift. (F-11)
- **Labels (F-12).** Change `Source: USER` to `Source: ASSUMPTION` for the author-chosen specifics, or move them to Open Questions: the retryable set (FR-211, FR-212), the 60 s cap and exponential growth (FR-212), the category names, the `charsPerToken` range 0 to 10, the 17 telemetry column names and order, the `idleTimeoutSec` default 120, the S1/S2/S4/S6 spike rule. At least add OQ-213 *"choices not made by the owner"* that lists them. The notes' claim that all of them "are listed as open decisions" (notes section 3, last bullet) is false; fix the notes or the OQ list.

### M-7 (important, before WP-2B and WP-2D). Split the two overloaded work packages (F-14)

See section 5. Proposed table for "Execution Order" (replace steps 2 and 4):

| Step | Package | Content |
|---|---|---|
| 2a | WP-2B1 | Registry fields and fixtures, `Test-AgentContextBudget`, `Get-AgentRetryDelaySec`; suites `test-agent-budget.ps1`, `test-registry-engine.ps1` |
| 2b | WP-2B2 | `Get-AgentErrorCategory` with hints, `tests/mocks/fake-web-response.ps1` (compile proof first), telemetry v2 writer and CSV rule; suites `test-agent-errors.ps1`, `test-agent-telemetry-v2.ps1` |
| 4a | WP-2D1 | Migrate `run-agent.ps1` and the relocated wrappers; the engine fake host and the run-agent part of `test-engine-callsites.ps1`; the AC-218 edits for `test-registry-callsites.ps1` that concern `run-agent` |
| 4b | WP-2D2 | Migrate `review-spec.ps1` and `revise-spec.ps1`; the rest of the callsite suite; the other AC-218 edits; the Phase 1 spec note; then, last and after approval, `.ai/config.json` |

### M-8 (important, before WP-2S). Keep the loopback suite out of the default run until it is stable (F-07)

`scripts/test-all.ps1` discovers every `scripts\test-*.ps1` (verified, lines 808 to 834). `test-streaming-spike.ps1` would run, and open a listener, in the default offline run from its first commit, contradicting OQ-210's "only if stable in three runs". Replace the file name in Affected Files and Test Strategy by `scripts/spike-streaming-check.ps1` (not discovered), and move it to `test-streaming-spike.ps1` only in the commit that records three stable runs. Keep `test-all.ps1` unmodified.

### M-9 (important, before WP-2G). Streaming code versus guard 4 (F-06)

Replace the sentence in "Test Strategy" (line 547) "the streaming code of WP-2G is the only allowed `HttpWebRequest` and lives outside the copied scripts of these suites" with:

> The baseline suites copy every `scripts\lib\*.ps1` and stop at startup if the text `HttpWebRequest` appears in a copied script (`test-registry-callsites.ps1:277-291`, `test-agent-telemetry.ps1:275`). WP-2G therefore adds `scripts/lib/agent-stream.ps1` and, in the same commit, a listed AC-218 row that exempts exactly that file name from the `HttpWebRequest` literal in guard 4 of both suites while still scanning it for every other route. No other change to the guards.

### M-10 (important, before WP-2A). Correct the Context facts

- Line 27: `.ai/agents/spec.md` has **379 CRLF and 32 LF-only** line ends (411 is the total), `spec-reviser.md` **195 and 235** (430 is the total). `spec-reviewer.md` is pure CRLF (400), omitted today.
- Line 38: say the 5.3 characters per token figure comes from `deepseek-r1:32b`, n = 2, with a model that is no longer in the registry; it is not a calibration for `qwen3.5` or `qwen3.6`.
- Replace the estimated "fixed text" column with the measured one (section 3, F2): 29,161, 25,564, 24,130, 13,950 characters.

---

## 3. Re-verified facts

| # | Claim (spec or notes) | Result | Evidence |
|---|---|---|---|
| F1 | Agent file sizes 20,999 / 16,981 / 13,564 / 5,788 chars; contract + `AGENTS.md` 7,882 | **Confirmed** | `Get-Content -Raw -Encoding UTF8` lengths: contract 3,435, `AGENTS.md` 4,447, agent files as stated |
| F2 | Template sizes are ESTIMATE, 0.3 to 3 KB | **Confirmed, measured** | parser: `run-agent` 280 (+56 for the context wrapper), reviewer 701, reviser 2,684 chars. Fixed text: spec 29,161; reviewer 25,564; reviser 24,130; developer 13,950 (spec estimates 29.1k, 25.8k, 24.4k, 13.9k: within 1 %, conservative) |
| F3 | Budget arithmetic with the real `.ai/config.json` | **Confirmed** | `S = ceil(0.10 x 16384) = 1639`; available 10,649 (`fast`, R 4096) and 6,553 (`deep`, `review`, R 8192). Reviewer fixed text 25,564 / 3.5 = 7,304 tokens > 6,553; reviser 24,130 / 3.5 = 6,894 > 6,553; `developer` 3,986 fits (2,567 tokens, about 9.0k chars, left for `-Task`); `spec` 8,332 fits (2,317 tokens, about 8.1k chars, left for task and context). At 5.3 chars/token the reviewer keeps 6,553 - 4,823 = 1,730 tokens (about 9.2k chars): the notes' "about 1.7k tokens" is right. **Added fact:** the Phase 2 spec itself (69,603 chars) as reviewer input is (25,564 + 69,603 + about 55) / 5.3 = 17,964 tokens, above the whole 16,384 window even with R = 0 |
| F4 | The 5.3 chars/token figure is a measurement for the current profiles | **Refuted in scope** | `docs/handoff/2026-11-19-harness-context.md:286`: `deepseek-r1:32b`, n = 2, older prompt (20,620 chars vs 20,999 now). Different tokenizer from `qwen3.5/3.6` (F-16) |
| F5 | Mixed line endings, counts "379 CRLF and 411 LF" / "195 and 430" | **Partly refuted** | byte count: `spec.md` CRLF 379, LF-only **32**; `spec-reviser.md` CRLF 195, LF-only **235**; the spec's 411 and 430 are the totals. `developer.md` LF only (130), `AGENTS.md` CRLF only (183), contract CRLF only (161), `spec-reviewer.md` CRLF only (400, not mentioned). `git ls-files --eol`: all `i/lf`; `w/mixed` for `spec.md`, `spec-reviser.md`; `w/crlf` for the three scripts and `.ai/config.json` |
| F6 | A here-string takes its line endings from the script file | **Confirmed** | CRLF script: output holds 2 CR; LF script: 0 CR (PowerShell 5.1) |
| F7 | `autocrlf=true`, no `.gitattributes`: committed mixed-ending files lose their CRs (implied by FR-203) | **Confirmed, with consequence** | throw-away repo: `mixed.txt` (CRLF, LF, CRLF) staged as `i/lf`; with `* -text` it stays `i/mixed`. So fixture files cannot carry mixed endings (F-03) |
| F8 | Existing fakes throw a plain `RuntimeException` | **Confirmed** | `test-agent-telemetry.ps1:218,222`, `test-registry-callsites.ps1:229`: `throw "..."`; tried: type `System.Management.Automation.RuntimeException`, `Response` null |
| F9 | `Invoke-HarnessGenerate` and `Test-HarnessModelAvailable` have no other callers | **Confirmed** | only `review-spec.ps1:112,121`, `revise-spec.ps1:148,156`; no suite calls them. AC-216's "wrapper tests of the baseline behaviors" do not exist (F-17) |
| F10 | CSV header 14 -> 31 | **Confirmed** | `telemetry.ps1:31-46` has 14 fields; spec FR-216 adds 17 names (`schema_version` ... `warnings`) = 31; `test-agent-telemetry.ps1:505` asserts 14 |
| F11 | AC-218 lists exactly the baseline assertions that change | **Refuted** | `test-registry-callsites.ps1:718` (run-agent, agent `spec` -> profile `alpha`, `think` true) asserts the `think` member absent and is not listed; the "four other" `think` checks are three (658, 700, 737) (F-02) |
| F12 | Zero-telemetry assertions to change | **Confirmed** | `test-agent-telemetry.ps1:543` (missing model), `:563` (unreachable), `:601` (config deleted). The `Assert-NoRequest` cases (`test-registry-callsites.ps1:594-638`) are configuration errors and stay valid |
| F13 | Legacy `run-agent.ps1` logged `success` for an empty response | **Confirmed** | `run-agent.ps1:202-221`: telemetry `success` is written before the empty check |
| F14 | `validate-spec.ps1` passes | **Confirmed** | `STATUS: PASS`, exit 0 |
| F15 | 46 unique IDs; one `Verifies:` per AC; matrix is the inverse | **Confirmed (own script)** | `%TEMP%\p2rev\check.ps1`: 18 FR, 6 NFR, 22 AC; no duplicate heading; exactly one `Source:` per heading; exactly one `Verifies:` per AC; no unknown reference; 24 matrix rows equal the inverse of the `Verifies:` lines; every FR and NFR has at least one AC (FR-205 and FR-218 only through the optional AC-220 to AC-222); no `-2nn` ID exists in Phase 0 or Phase 1 |
| F16 | "XR-05 lists 17 new fields" (notes, deviation 3) | **Refuted (minor)** | roadmap `XR-05` lists 18 (`schema_version`, `call_id`, `workflow_id`, `workflow`, `stage`, `attempt`, `profile`, `model_source`, `timeout_sec`, `context_window`, `prompt_chars`, `est_prompt_tokens`, `task_sha256`, `transport`, `error_category`, `http_status`, `output_path`, `target_root`). The spec's 17 are 12 of these (with `attempt` renamed `attempts`, not noted) plus `model_called`, `done_reason`, `thinking_chars`, `think_sent`, `warnings` |
| F17 | Spec is about twice Phase 1 | **Confirmed** | 69,603 bytes vs 35,646 |
| F18 | `Invoke-RestMethod` on PS 5.1 reports a `WebException` with `Status`, and `Response.StatusCode` for HTTP errors (A-201) | **Confirmed** | loopback: closed port `ConnectFailure`; `.invalid` host `NameResolutionFailure`; server hang with `-TimeoutSec 3` `Timeout` at 3,008 ms; HTTP 500 and 400 `ProtocolError` with `Response.StatusCode` 500/400 and `ErrorDetails.Message` = the JSON body; RST and FIN before the response `ConnectionClosed` |
| F19 | A body cut off after the headers | **New fact** | raw `System.IO.IOException` (no `Status`): the spec maps it to `transport_reset`, retryable (consistent) |
| F20 | A 200 whose body is not JSON | **New fact** | `Invoke-RestMethod` returns the string without an error; `.response` is then null, so `empty_response` (consistent with "a body without `response`") |
| F21 | `-TimeoutSec` bounds the call | **Partly refuted** | it bounds the wait for the response headers only: a server that sent headers and stalled the body was read for 8.3 s with `-TimeoutSec 3` (the cmdlet's default read timeout applies to the body). For non-streaming Ollama, headers come last, so it is equivalent in practice (F-21) |
| F22 | A `WebResponse` subclass compiled with `Add-Type` can be given to a `WebException` and read like a real one (A-202) | **Confirmed** | `FakeWebResponse` with `StatusCode` and a stream: `Status`, `Response.StatusCode`, stream body all read; thrown from a function named `Invoke-RestMethod` the `ErrorDetails` is null, so the stream fallback in FR-204 is the path the fakes take |
| F23 | Classification by status/type is independent of the Windows language | **Confirmed on es-ES** | same `Status` values with `CurrentUICulture` es-ES; messages are localized, enum names are not. Only one language was available (NOT VERIFIED for others, but enum names are language-neutral by design) |
| F24 | Baseline `test-all.ps1` ends `PASS WITH SKIPS` | **Confirmed** | 11 discovered, 10 passed, 1 skipped (`test-spec-integration.ps1`); counts: telemetry 23, callsites 55, registry 86, validate-spec 54, scan 26, spec 17, build-context 15, mode 11, run-agent 5, syntax 1; repository clean afterwards |
| F25 | `test-all.ps1` discovers new suites by name | **Confirmed** | `Get-ChildItem ... -like "test-*.ps1"`; a table entry is only needed for `Requires`, `Isolation`, `Skip`. Consequence in F-07 |
| F26 | The four-guard child suites would accept the new library | **Partly refuted** | they copy every `scripts\lib\*.ps1` and refuse to start on `HttpWebRequest` (`test-registry-callsites.ps1:277-291`); the new `agent-exec.ps1` with its single `Invoke-RestMethod` is fine (the scan list does not include the bare cmdlet name), a streaming file in `lib\` is not (F-06) |

### Worst-case wall time (the safe-by-default question)

Defaults proposed by the spec: `maxAttempts` 2, `retryBackoffSec` 5 (so one wait of 5 s), shipped `timeoutSec` 900, `healthTimeoutSec` 15. `timeout` is never retried, so a pure timeout is unchanged (900 s). The extra time appears only when an attempt fails with a retryable category late.

| Case | Legacy ceiling | New ceiling | Factor |
|---|---|---|---|
| One generation call: first attempt dies at about 900 s (reset or 5xx), second runs to the timeout | 900 s | 2 x 900 + 5 = **1,805 s** (30 min 5 s) | 2.0 |
| A persistent fast fault (GPU initialization error, immediate 500) | seconds | seconds + 5 s | about 1 |
| One call with `ollama.warmup` true: warm-up (same timeout and retry) plus generation | 900 s | 2 x 1,805 = **3,610 s** (1 h 10 s) + 15 s health check | 4.0 |
| `specify.ps1`: 1 spec + 4 reviews + 3 revisions = 8 model calls (`$maxRevisions = 3`, `specify.ps1:71,217`) | 7,200 s (2 h) | 8 x 1,805 = **14,440 s** (4 h 41 s); with warm-up per process 28,880 s (8 h 1 m) | 2.0 / 4.0 |
| Maximum the registry allows: `maxAttempts` 5, `timeoutSec` 14,400, waits 5+10+20+40 | 14,400 s | 5 x 14,400 + 75 = **72,075 s** (20 h 1 m 15 s); with warm-up 144,150 s (40 h) | 5.0 / 10.0 |

Reaching the ceilings needs every first attempt to fail just before its timeout, which is unlikely, but nothing in the spec stops it and the user would see an unexplained silence (nothing is printed during a retry: F-08). The budget part of the question: with the spec's default `enforce` and the shipped `.ai/config.json`, calls that work today fail 100 % of the time for the reviewer and reviser, and for `spec` once task plus context exceed about 8.1k characters, and for `developer` once the task exceeds about 9.0k characters (F3). With `warn` (M-1) no call that works today fails.

---

## 4. Findings

Severity: **blocker** (the spec cannot be implemented or is self-contradictory), **important** (a gap that causes rework or a wrong result if not fixed), **nit**.

| ID | Sev | Evidence | Finding and suggestion |
|---|---|---|---|
| F-01 | blocker | spec 140, 247, 250, 597, 626; `.ai/config.json:12-33`; Phase 1 NFR-103; spec rollback 607 | Default `budgetMode` is `enforce`. FR-217 says v2 files without the new fields "keep working", but the shipped Phase 1 config has `contextWindow` 16384 and R 8192 and no `budgetMode`, so the reviewer and reviser are refused from the first WP-2D commit; reverting only the `.ai/config.json` commit (the spec's rollback) re-creates the refusal. Also an XR-03 miscalibration at 3.5 vs the true ratio. Fix: M-1. |
| F-02 | blocker | `test-registry-callsites.ps1:707-718`, spec AC-218 446-451, AC-219 | AC-218 omits the run-agent `think member` assertion (line 718) and miscounts the unchanged ones; with "no other assertion is edited" WP-2D cannot be accepted. Fix: M-2. |
| F-03 | blocker | spec 90-93, 306, 27; verified F6, F7 | Golden inputs with CRLF/LF/mixed endings cannot be stored as files under `autocrlf=true` (git normalizes them), and the template separators' endings silently change from the legacy script's to the new file's; "byte-identical" (FR-203, roadmap AC-201) is not what is tested. The EOL deviation is also missing from the notes' deviation table. Fix: M-3. |
| F-04 | important | `telemetry.ps1:1-10`, `test-agent-telemetry.ps1:491`; spec 231-233, 410 | The v2 writer's parameter list, the value of not-applicable columns, the definition of `prompt_chars`, and what counts as "a call" are unspecified, so AC-214 cannot be checked precisely, and a mandatory new parameter would break the unchanged baseline reference-header call. Newlines in `error` break line-based CSV readers (verified: `ConvertTo-Csv` keeps a newline inside a quoted field, one record over two physical lines). Fix: M-4. |
| F-05 | important | `test-registry-callsites.ps1:198-243`, `test-agent-telemetry.ps1:188-233`; spec 102, 225, 213 | The fake `Invoke-RestMethod` of the baseline suites declares only `-Uri -Method -Body -ContentType -TimeoutSec`. The default transport must use exactly those. The `/api/tags` cache and the warm-up set persist across test cases in one process: no reset exists. The failure matrix of AC-202 needs a new typed-exception fake host (the baseline fakes give only `transport_other`). Fix: M-5. |
| F-06 | important | `test-registry-callsites.ps1:164-168,277-291`; spec 61, 547 | Streaming code in `scripts\lib\` is copied by both baseline suites and trips their guard 4 (`HttpWebRequest`) at startup; the spec says it "lives outside the copied scripts", which is impossible for `lib\`. Fix: M-9. Conditional on WP-2G. |
| F-07 | important | `test-all.ps1:808-834`; spec 533, 276, 635 | `test-streaming-spike.ps1` is auto-discovered and would open a listener in every default run, contrary to OQ-210. Fix: M-8. |
| F-08 | important | spec 79, 205-207, 599; section 3 table | Retries print nothing; worst case doubles (4x with warm-up) and is only given as a formula (RK-203). Fix: print one line per retry (M-6), put the table in RK-203. |
| F-09 | important | `config.ps1:437-443,472-473`; `benchmark-models.ps1:149-156`; spec 219 | For `-Model` / `AI_HARNESS_MODEL` with an unregistered model, `Resolve-HarnessExecution` borrows the agent profile's parameters, `think` included. FR-214 would then send `think` to any model (the benchmark does exactly this with several models) and an unsupporting model answers 400, with no fallback by design. Harmless while every profile says `"default"`, but OQ-209 plans `false` for the reviser. Fix: M-6 (omit `think` when no profile matched the model). |
| F-10 | important | spec 79, 140, 38; roadmap XR-03 "Never truncate silently" | In `warn` mode nothing is printed ("nothing is printed for warnings"), so the shipped configuration makes the XR-03 protection invisible: an overflowing prompt is still truncated by Ollama and only a telemetry column says so. Fix: one added console line (M-1). |
| F-11 | important | roadmap line 370 vs spec FR-211 | Category names differ from the roadmap's Phase 3 manifest list (`ollama_unreachable`, `http_error`, `empty_output`, `invalid_output_format`); R-02 says `http_error`. Not recorded as a deviation. Fix: OQ-212 and mapping table (M-6). |
| F-12 | important | spec 7, 44-256 (almost every `Source: USER`); notes line 49 | AGENTS.md principle 6: author choices are labelled `USER`. Examples: the retryable set, the 60 s cap, the `charsPerToken` range 0 to 10, the 17 names and their order, the idle default. The notes say they are "all listed as open decisions"; OQ-201 to OQ-210 do not list them. Fix: M-6 (label or OQ-213). |
| F-13 | important | `run-agent.ps1:183-199`, `review-spec.ps1:131-133`; spec 99-101, 288 | The legacy error blocks print `Exception.Message` (reviewer, and run-agent for non-HTTP failures) and, in run-agent, `Status:` and the body. FR-204 forbids the transport to return the message, FR-202 does not say `Status:`/body stay, and NFR-205's list of intentional changes omits the lost message line and the `success` -> `error` status change for empty run-agent responses. Fix: M-6. If the owner wants the message kept, carry it in a `failure.message` used for display only, never for a decision or telemetry. |
| F-14 | important | spec 561-563 | WP-2B (registry with about 12 fixtures, budget, error table with hints, retry delay, telemetry writer and CSV rule, two fakes, four suites, mutation proofs, report) and WP-2D (three scripts, relocated wrappers, failure matrix of 3 scripts x 7 cases on a new fake host, test edits, Phase 1 note, config update) each exceed one unattended session; WP-2B's "step 1" (fake `WebResponse`) is referenced by RK-205 but not defined. Fix: M-7. The fake `WebResponse` compile proof is already done here (F22): quote it as evidence. |
| F-15 | important | spec 109, 213, 252-256, 565-568 | Scope: FR-213 (warm-up, ASSUMPTION, default off, unverified behaviour A-203), FR-218 / WP-2P (a procedure with no deliverable), FR-205 / WP-2S / WP-2G (the roadmap marks streaming and `num_predict` `[O]`) bring the spec to 69.6 KB. Nothing is Phase 3 creep (the six Phase 3 telemetry fields are correctly deferred), but the roadmap's R-09 says each phase must be reviewable. Suggest: keep FR-213, FR-218, FR-205 as one-paragraph "Deferred" notes without ACs, or split a Phase 2b spec. The core (FR-201 to FR-204, 207 to 212, 214 to 217) is complete without them. |
| F-16 | important | handoff `:286`; spec 38; notes 10 | The only measured chars/token (5.3) is for `deepseek-r1:32b`, n = 2; nothing measured for the qwen models in the registry. OQ-201's calibration is therefore not "confirm 5.3" but "measure". Also see M-10 (wrong LF counts, estimated template column). |
| F-17 | important | spec 426; grep | AC-216 says "the wrapper tests of the baseline behaviors pass (text returned trimmed; a throw starting with `Ollama request failed:`; the legacy lines and problem string)". No baseline suite tests the wrappers (`Ollama request failed` appears only in `config.ps1:559`). They must be written; say so and put them in WP-2D's suite, with literals. |
| F-18 | nit | spec 141; Ollama behaviour | `prompt_eval_count` can be lower than the prompt length when Ollama reuses a cached prefix, so `possible_prompt_truncation` can miss a truncation. Say "heuristic" (the spec already calls it ASSUMPTION). |
| F-19 | nit | spec 354 | "The test runs under two UI cultures": with a fake exception the messages are not localized, so the test proves nothing about language. The meaningful check is a static one: no `.Message` read in `Invoke-OllamaHttp`, `Get-AgentErrorCategory` or `Invoke-AgentModel` except the display-only field. Add that scan to AC-207. |
| F-20 | nit | spec 99, 100 | `detail` "at most 500 characters" and `body` "at most 4096": say whether they are cut before or after control characters are stripped (M-4). |
| F-21 | nit | spec 207, 599; F21 | RK-203's "worst case maxAttempts x timeoutSec" holds for the header wait; the body read after headers has its own default timeout (measured). Immaterial for non-streaming Ollama, but the sentence should say "per attempt, until the response headers". |
| F-22 | nit | spec 354 | `Add-Type` of `FakeWebResponse` twice in one session fails ("type already exists") and needs `csc.exe`; the mock file must guard with `if (-not ('FakeWebResponse' -as [type]))`. Compile takes about a second per process. |
| F-23 | nit | `run-agent.ps1:84-125`; spec 67 | FR-202 lists "build their prompt, check availability, call". `run-agent.ps1` checks availability before it reads the files and the context file; keep that order or an unreachable server plus a missing context file reports a different error. |
| F-24 | nit | spec 434 | NFR-201 is a timing assertion (median under 1,000 ms); fine on a quiet machine, flaky on a loaded one. State that a failure prints the measurement and is rerun once, or relax to 3,000 ms. |
| F-25 | nit | spec 346 | AC-206 gives parenthesised cases "(0.5, window 1000)" and "(2.5, 4)" without expected values; every case needs its literal result, as the first ones have. |
| F-26 | nit | spec 282, 434 | NFR-204 (no `-AsHashtable`, no ternary) is verified only by `test-syntax` and two runs; add a text scan for `-AsHashtable` in the new files. |

**Counts: 3 blockers, 14 important, 9 nits** (26 findings; counted from the table rows by script).

### Specific checks requested

1. **Ambiguity, circularity, localized text, `Verifies:`, matrix, IDs.** Matrix and `Verifies:` agree exactly (F15). No AC asserts localized PowerShell, .NET or Ollama text (the harness's own wording is asserted). Circular or underspecified expected values: AC-214 (derived `est_prompt_tokens`, F-04), AC-206 parenthesised cases (F-25), AC-216 "baseline wrapper tests" that do not exist (F-17). The two-culture test in AC-207 is vacuous with fakes (F-19). No ID collisions: Phase 0 and Phase 1 define no `-2nn` identifier; the identifiers shared with them in the text are citations.
2. **Contradictions.** Default `enforce` versus FR-217/NFR-205/rollback (F-01). "Byte-identical" versus the normalized comparison and line endings (F-03). FR-202 "existing lines unchanged" versus FR-204's no-message rule (F-13). Retry rules, categories, exit codes and "exactly one record" agree with each other: retries live inside one `Invoke-AgentModel` call that writes one record, and `maxAttempts` 1 is the legacy path. `think` semantics agree with Phase 1 AC-109 (the record part stays; the request part is superseded explicitly), except for borrowed profiles (F-09).
3. **PS 5.1 feasibility.** `WebException.Status` and `Response.StatusCode`, the body from `ErrorDetails.Message`, a fake `WebResponse` via `Add-Type`, a loopback `TcpListener` without administrator rights, and `-Sleep` injection all work (section 3). Timeout, closed port, name failure, reset and truncated body map as FR-211 expects. Not feasible as written: streaming code in `lib\` (F-06). Not testable by fakes alone: the real language independence (F-19).
4. **Backward compatibility.** v1 files: budget `skipped`, retries apply, `think` omitted: consistent. v2 shipped config: broken by F-01. Existing suites: broken only by F-02 once FR-214 lands, and by F-06 if streaming is built. Legacy exit codes and markers: preserved apart from F-13. CSV rule: correct, including the BOM that `Export-Csv -Encoding UTF8` writes (verified: EF BB BF); the header comparison must be made on the quoted `ConvertTo-Csv` form.
5. **Safety.** FR-207 (the whitelist) is sound: `Invoke-HarnessGenerate` today builds `model`, `system`, `prompt`, `stream`, `options` only; nothing in the code sends tools. The four guards survive for `agent-exec.ps1` (single `Invoke-RestMethod`, not the namespaced form the scan looks for). Tripwire and sandbox: no new suite writes outside `TEMP`; none needs `Isolation = "sandbox"` unless it writes into the repository. No real sleeping in tests, provided `retryBackoffSec` 0 or `-Sleep` is injected everywhere (AC-202, AC-208); add a guard that fails a suite whose total real wait exceeds 2 s.
6. **Work packages.** See M-7 and F-14, F-15. Ordering is right (goldens before code, pure before impure, scripts last, config commit last); gates after every package are right.
7. **Open questions.** Section 6.
8. **Safe-by-default.** Section 3, "Worst-case wall time", and F-01, F-08, F-10.

---

## 5. Work-package sizing

| Package | Spec | Review | Notes |
|---|---|---|---|
| WP-2A goldens and builders | one session | fits | Needs OQ-208 and OQ-211 decided; the parser capture works (templates measured with `Parser.ParseFile`; expansion of the here-strings was not executed here). Add `tests/golden/.gitattributes` |
| WP-2B | one session | **overloaded** | 12+ registry fixtures, budget, 11-row error table with hints, retry delay, writer and CSV rule (six sub-cases), two fakes, four suites, mutation proofs for six rules, report. Split (M-7) |
| WP-2C | one session | fits | `Invoke-OllamaHttp`, `Test-OllamaModel`, `Invoke-AgentModel`; the largest logic, but self-contained with the fake |
| WP-2D | one session | **overloaded** | three scripts, wrappers, new fake host, 3 x 7 failure matrix, AC-218 edits, Phase 1 note, config commit. Split (M-7) |
| WP-2S | one time box | fits | independent; keep the suite undiscovered until stable (M-8) |
| WP-2G | one session | conditional | file placement and guard exemption first (M-9) |
| WP-2E | live | depends on hardware | the only package that decides `enforce` |
| WP-2P | deferred | n/a | a procedure, not code |

---

## 6. Answers to the open questions

| OQ | Agree? | Answer |
|---|---|---|
| OQ-201 budget default and shipped mode | **Partly** | Agree with shipping `warn`, disagree that the code default is `enforce`: make the code default `warn` too (M-1), print one line in `warn` (F-10), and calibrate with the qwen tokenizers (the 5.3 figure is from `deepseek-r1`, F-16). Decide the larger window only after WP-2E: even at 5.3 the 69 KB spec cannot be reviewed in a 16,384 window (F3), so the reviewer's real constraint is the window, not the ratio |
| OQ-202 log failures before the model | Agree | Add the definition of "a call" (M-4) so input errors still write nothing |
| OQ-203 retry defaults, applied to v1 | **Agree with 2 attempts and 5 s; add a visible retry line** | Worst cases in section 3. Keep `timeout` non-retryable (the doubling risk is the whole reason). Consider a lower default `timeoutSec` cap warning only in a later phase |
| OQ-204 warm-up default | Agree: off | And defer FR-213 itself to WP-2E, since A-203 is unverified (F-15) |
| OQ-205 deferred telemetry fields | Agree | Record `attempt` -> `attempts` as a rename (fact F16) |
| OQ-206 `error` column | Agree | Strip CR/LF and cut at 500 (M-4) |
| OQ-207 `Category:` and `Hint:` lines | Agree | Additive; also allow the retry and budget-warning lines (M-6) |
| OQ-208 line endings of inputs | Agree: pass through | The live prompt is not uniform; canonicalize only in WP-2P. Separate question for the template separators: OQ-211 (M-3) |
| OQ-209 `think` values | Agree: change none | Add the borrowed-profile rule (F-09) before any profile sets `false` |
| OQ-210 platform gate and spike scheduling | Agree with 5.1 and a parallel spike | The roadmap says the gate is "open, before Phase 2": record the owner's decision that Phase 2 core proceeds on 5.1 and that only the streaming transport depends on the gate. Keep the spike suite out of `test-all` until stable (M-8) |

**Missing owner decisions** (add as OQ-211 to OQ-214):

- **OQ-211** line endings of the builders' template text (M-3).
- **OQ-212** category vocabulary versus the roadmap's manifest list (M-6). RECOMMENDATION: keep the finer names and publish the mapping.
- **OQ-213** the author-chosen specifics listed under M-6 (F-12): retryable set, 60 s cap, `charsPerToken` range, column names and order, idle default, spike rule. RECOMMENDATION: accept as written, after the owner has seen them in one place.
- **OQ-214** whether the console may show the localized exception message for display only (F-13). RECOMMENDATION: yes, a `failure.message` used only for printing.
- Smaller: whether the one-line retry and budget-warning outputs are acceptable as additions to the console (covered by OQ-207's logic); whether `.gitattributes` under `tests/golden/` is allowed as a new file (M-3).

---

## 7. NOT VERIFIED

- Everything that needs Ollama: real `prompt_eval_count`, whether Ollama trims an overflowing prompt, whether `think: false` is accepted by a model without thinking support (relevant to F-09), whether a request without `prompt` only loads the model, the real HTTP 5xx behaviour and its timing, the GPU initialization fault, streaming first-byte timing (S8).
- That the ratio for the qwen models is near 3.5 or near 5.3; the reviewer and reviser figures in section 3 use both.
- Spike questions S1 to S7 for `HttpWebRequest` streaming: not tried. Only the blocking `Invoke-RestMethod` was exercised against a loopback server; chunked streaming, `ReadWriteTimeout` on a response stream and `Abort()` were not.
- Evaluation of the legacy here-strings into goldens (the parser located them and their size was measured; the expansion was not performed, and `ExpandableStringExpressionAst.Value` semantics for escapes were not exercised; the templates contain no backtick or `$(`).
- Windows languages other than es-ES, other PowerShell 5.1 builds, `Add-Type` under constrained language or a locked-down antivirus.
- That the new suites pass `test-all.ps1` in a sandbox, that two runs give identical results, and every mutation proof: nothing was implemented.
- The 1,000 ms library-overhead target (NFR-201): nothing to measure yet.
- Worst-case times are arithmetic from the proposed defaults, not observed.
