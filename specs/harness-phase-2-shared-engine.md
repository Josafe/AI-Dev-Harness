# Specification

**Title:** Harness modernization, Phase 2: shared agent execution engine
**Status:** Draft, revision 2 (2026-11-22; revision 2 applies the changes M-1 to M-10 of `docs/audits/2026-11-22-phase2-spec-review.md`, except that the nits are not applied). **Approved for implementation by the human owner on 2026-11-22 (revision 3): all recommendations of OQ-201 to OQ-214 accepted as written** (see "Open Questions" and D-209). **Revision 3.1 (2026-11-23): owner decision A for WP-2B2** (`docs/audits/2026-11-23-phase2-wp2b2.md`, sections 2 and 6); text only, no requirement change: AC-218, "Affected Files" and "Execution Order" now state that WP-2B2 writes the 31-column header and changes `telemetry.ps1`, and carries three one-line suite edits. **Revision 3.2 (2026-11-23): owner decisions D1 to D6 of the WP-2C independent review** (`docs/audits/2026-11-23-phase2-wp2c-review.md`, section 7; recorded as D-210); text only, no new requirement: the caches are "per script invocation" (FR-213, FR-215, D3); `http_status` is empty on a success (FR-204, FR-216, D2); `call_id` may be given by the caller, `-CallId` (FR-216, AC-218, D1; merged, see D-210); `model_called` true means a request was attempted (FR-216, D6); a response body is bounded only by the 300 s silence timeout of .NET, with a corrected RK-203 and a worst-case table (D4); an unclosed `<think>` is a known limit (FR-210, D5); the `-ResponseCheck` and hooks rules, `think_sent` timing, the `/api/tags` cache rule and the `healthTimeoutSec` and warm-key notes (FR-204, FR-210, FR-211, FR-213, FR-214, FR-215). **Revision 3.3 (2026-11-24): housekeeping at WP-2D2** (`docs/audits/2026-11-24-phase2-wp2d2.md`); text only, no requirement change: the relocation of `Invoke-HarnessGenerate` and `Test-HarnessModelAvailable` to `agent-exec.ps1` moved from WP-2D1 to WP-2D2 (`docs/audits/2026-11-24-phase2-wp2d1.md`, section 7), with the scan-exemption row and the pinned-list row in AC-218; FR-204 no longer says that the Phase 0 and Phase 1 fake hosts reject an extra `Invoke-RestMethod` parameter (they do not; the engine fake host of `scripts/test-engine-callsites.ps1` does); D-210 is no longer pending (the `-CallId` edit is merged); the Phase 1 spec carries the note that its FR-108 and AC-109 are superseded by FR-214 and AC-210. **Revision 3.4 (2026-11-26): closing round of the Phase 2 final QA** (`docs/audits/2026-11-26-phase2-final-qa.md`, conditions C1 to C3 and the owner decisions on I-1, I-5 and I-6); text only, no new requirement: "Affected Files" lists `scripts/test-shipped-config.ps1` and this file and no longer lists the unchanged roadmap file (C1, I-2); FR-202 and NFR-205 say that the body line of the `=== OLLAMA ERROR ===` block is the engine's `detail` (C2, I-1); NFR-205 lists the remaining intentional changes and FR-202 no longer says that nothing is printed for warnings (C3, I-3); AC-222 agrees with Execution Order step 5 (N-16); the cache wording says "per script invocation" in the Edge Cases (N-11); and a new section, "Deferred items", records the benchmark-retry precondition for WP-2E (I-5), the telemetry overlap (I-6) and the deletion of the deprecated wrappers, all for Phase 3 or WP-2E. Not yet implemented in full; implementation proceeds work package by package with review and approval after each.
**Applies to:** AI-Dev-Harness. Baseline: tag `phase1-hardened` (commit `ba33bb4`).
**Requirement ID scheme:** Phase 2 uses `FR-2nn`, `NFR-2nn`, `AC-2nn`. FR-201 to FR-207 and AC-201 to AC-205 keep the numbers of the roadmap's Phase 2 section (`docs/roadmap/modernization-roadmap.md`), narrowed here; FR-208 onward are added. Phase 0 and Phase 1 IDs are cited as "Phase 1 AC-109" and similar.
**Labels:** every requirement has one `Source:` line (USER, PROJECT, FACT or ASSUMPTION, the only values the validator accepts). A choice made by the spec author, not by the owner, is written as "RECOMMENDATION" in the text and listed in "Open Questions".

## Goal

Replace the three copies of "build a prompt, call Ollama, interpret the answer, write telemetry" in `run-agent.ps1`, `review-spec.ps1` and `revise-spec.ps1` with one library, `scripts/lib/agent-exec.ps1`. The library adds what the scripts lack: a context-budget check, an abstract transport that tests can replace, retries for transient server failures, error categories that never depend on message text, an explicit `think` option, and complete telemetry for every call. The scripts keep their parameters, exit codes, console markers, output files and prompts. Streaming is optional, off by default and gated by a spike. Prompt content changes are out of this implementation.

## Context

**Origin.** The Phase 2 section, XR-01, XR-03, XR-05, O-10, O-16, R-02, R-03, R-04, R-10 and the addendum (section 9, items 1 and 2) of `docs/roadmap/modernization-roadmap.md`; `docs/handoff/2026-11-19-harness-context.md`; `docs/audits/2026-11-20-phase1-final-qa.md` and `docs/audits/2026-11-21-phase1-hardening.md`; the task of 2026-11-22 that commissioned this spec (decisions D-201 to D-208).

**Current behavior** (FACT, read at `ba33bb4`):

- **Three copies of the call.** `run-agent.ps1` (lines 146-217), `review-spec.ps1` and `revise-spec.ps1` (through `Invoke-HarnessGenerate`, `scripts/lib/config.ps1`) each build the request body, call `Invoke-RestMethod` once with `timeoutSec`, strip `<think>...</think>` and trim. Prompts are PowerShell here-strings inside the scripts; the user prompt of the reviewer and reviser is a fixed sentence, and `run-agent.ps1` sends `-Task`.
- **No retry.** Any exception ends the call. `run-agent.ps1` prints `=== OLLAMA ERROR ===`, the HTTP status and body (read from the response stream), then `=== END OLLAMA ERROR ===`, and exits 1. The reviewer prints `=== OLLAMA ERROR ===` and exits 2; the reviser throws.
- **Errors are text.** `Write-HarnessModelTelemetry` stores `$_.Exception.Message`, which is localized (this machine: es-ES). There is no error category.
- **`think` is stored, not sent.** Phase 1 FR-108 and AC-109 require that no request has a `think` member.
- **The `thinking` field is ignored.** Ollama 0.40.13 returns reasoning of `qwen3.5` and `qwen3.6` in a `thinking` field, so `stripThinking` does nothing for them. An empty `response` with `done_reason: "length"` was observed (roadmap section 9).
- **Telemetry.** 14 columns. The reviewer and reviser write a record (Phase 0), but only for requests actually sent (Phase 0 OD-04); `done_reason`, thinking length, attempts, profile and prompt size are not recorded. `logs/` is git-ignored.
- **Registry.** Phase 1 provides profiles with `contextWindow`, `reservedOutputTokens`, `think` and `timeoutSec`, plus `defaults.safetyMarginRatio` and `ollama.healthTimeoutSec`. `defaults.charsPerToken`, retry settings and streaming settings do not exist (Phase 1 OD-107 moved them to this phase).
- **Test seam.** Child-process suites copy the scripts to a temporary harness root and define a function named `Invoke-RestMethod` that stands in for the cmdlet, with four guards against real requests (`scripts/test-agent-telemetry.ps1`, `scripts/test-registry-callsites.ps1`).
- **Line endings.** The repository has `core.autocrlf=true` and no `.gitattributes`. Measured on 2026-11-22: `.ai/agents/spec.md` has 379 CRLF and 32 LF-only line ends on disk, `spec-reviser.md` 195 and 235, `spec-reviewer.md` only CRLF (400), `developer.md` only LF, `AGENTS.md` and the contract only CRLF (re-measured by the independent review). A here-string takes its line endings from the script file. So the bytes of a prompt depend on the checkout, and the live prompt is not uniform (roadmap section "Changes since the audit", `docs/audits/2026-11-20-wp-d-implementation.md` sections 5 and 7).

**Measured facts that shape the budget rules** (FACT unless marked; sizes in .NET characters, measured 2026-11-22):

| Agent | Agent file | Contract + `AGENTS.md` | Fixed text, with template (template sizes measured by the review: 280, 701, 2,684 and 280) | Tokens at 3.5 chars/token | Available: `C - R - S` |
|---|---|---|---|---|---|
| `spec` (`fast`, R 4096) | 20,999 | 7,882 | 29,161 chars | about 8.3k | 16,384 - 4,096 - 1,639 = 10,649 |
| `spec-reviewer` (`review`, R 8192) | 16,981 | 7,882 | 25,564 chars | about 7.3k | 16,384 - 8,192 - 1,639 = 6,553 |
| `spec-reviser` (`deep`, R 8192) | 13,564 | 7,882 | 24,130 chars | about 6.9k | 6,553 |
| `developer` (`deep`, R 8192) | 5,788 | 7,882 | 13,950 chars | about 4.0k | 6,553 |

With the default `charsPerToken` of 3.5 (XR-03) and the migrated `.ai/config.json`, the reviewer and reviser fixed text alone exceeds the available tokens, before the task, specification or review are added. The measured ratio for the `spec` prompt is about 5.3 chars/token (2 samples with `deepseek-r1:32b`, handoff section 7; not a measurement for the current `qwen3.5` and `qwen3.6` profiles), which still leaves the reviewer only about 1.7k tokens (about 9k chars) for the whole specification. Enforcing XR-03 on the shipped configuration would therefore block calls that work today (Ollama trims or ignores the overflow; Q-03). This is OQ-201 and is the reason for `budgetMode` (FR-209).

**Out of scope.** Phase 3: the unified CLI, manifests, background runs, `-Profile` on `specify.ps1`, workflow-level telemetry fields (`workflow_id`, `workflow`, `stage`, `output_path`, `target_root`) and context-file budgets. Not added to the registry: `reasoning`, `agents.<A>.promptFile`, `tests` (not needed). Not changed: any prompt, `.ai/agents/*`, `.ai/rules/*`, `AGENTS.md`, `specify.ps1`, `benchmark-models.ps1`, `validate-spec.ps1`, the models and timeouts in use, the `think` value of any profile. The harness never starts, stops or restarts Ollama.

## Functional Requirements

### FR-201 — Shared library `scripts/lib/agent-exec.ps1`

**Source:** USER

A new library file defines these functions and nothing else (dot-sourcing it prints nothing, reads no file, sends no request):

| Function | Purpose | Requirement |
|---|---|---|
| `New-AgentPromptPart`, `New-AgentPrompt` | prompt parts and their concatenation | FR-208 |
| `New-RunAgentPrompt`, `New-SpecReviewPrompt`, `New-SpecRevisePrompt` | the three legacy prompts | FR-208 |
| `Test-AgentContextBudget` | budget arithmetic | FR-209 |
| `Invoke-AgentModel` | one model call, returns a result object | FR-210 |
| `Get-AgentErrorCategory`, `Get-AgentRetryDelaySec` | pure classification and backoff | FR-211, FR-212 |
| `Invoke-OllamaHttp` | the default transport | FR-204 |
| `Test-OllamaModel` | cached availability check | FR-215 |
| `Reset-AgentExecState` | clears the per-script-invocation caches (the `/api/tags` result and the warmed-model set); every in-process test calls it first | FR-213, FR-215 |
| `Invoke-HarnessGenerate`, `Test-HarnessModelAvailable` | deprecated wrappers, relocated from `config.ps1` | FR-202 |

The scripts dot-source `config.ps1`, `telemetry.ps1` and `agent-exec.ps1`, in that order. The telemetry writer stays in `telemetry.ps1` (FR-216). Streaming code, if built (WP-2G), lives in `scripts/lib/agent-stream.ps1`, with the guard-4 exemption described in "Test Strategy".

### FR-202 — The three scripts use the library; interfaces do not change

**Source:** USER

`run-agent.ps1`, `review-spec.ps1` and `revise-spec.ps1` resolve execution as today (Phase 1), build their prompt with the FR-208 builders, check availability with `Test-OllamaModel`, call `Invoke-AgentModel`, and map the result to their legacy behavior. Parameters, exit codes, existing console lines and output files do not change (XR-01).

| Situation | `run-agent.ps1` | `review-spec.ps1` | `revise-spec.ps1` |
|---|---|---|---|
| Configuration or argument error (before resolution) | as today: exit 1, no telemetry | as today: exit 2 | as today: non-zero |
| Ollama unreachable, or model not installed | as today (existing lines): exit 1 | exit 2 | non-zero |
| Context budget exceeded, `enforce` | exit 1 | exit 2 | non-zero |
| Transport failure after the retries (`timeout`, `http_4xx`, `http_5xx`, `transport_*`) | `=== OLLAMA ERROR ===` block, exit 1; no output file | `=== OLLAMA ERROR ===`, exit 2 | non-zero; no output file |
| `empty_response` or `thinking_budget_exhausted` | exit 1, message "Agent returned an empty response." | exit 2, `=== REVIEWER OUTPUT ERROR ===`, "Reviewer returned an empty response." | non-zero, "Reviser returned an empty response." |
| `format_invalid` (reviewer, no `## Status` PASS or FAIL) | n/a | exit 2, `=== REVIEW VALIDATION ERROR ===` and the existing "Expected:" lines | n/a |
| Success | exit 0, output as today | exit 0 for PASS, 1 for FAIL, as today | exit 0 |

`run-agent.ps1` keeps its existing `Status: <code>` line (from `error.httpStatus`) and the line after it inside the `=== OLLAMA ERROR ===` block, which is the engine's `detail` (Ollama's JSON `error` string when the body has one, else the exception type name and `webStatus`; FR-211), not the raw response body (owner decision on I-1 of the final QA; the legacy script printed the raw body). It differs from the legacy line when the body is not JSON with an `error` string: a text body or a JSON body with another member now gives the type name, and an empty body gives a type name where the legacy printed nothing. Observed on the real cmdlet, a Content-Length error printed an EMPTY line before (the stream had already been consumed), so there the new line is an improvement. The script keeps its order: the availability check comes before the files and the context file are read. Added output, only on failure: one line `Category: <category>` and, when the result has one, `Hint: <hint>` (OQ-207). For `context_budget_exceeded`, also one line per prompt section with its characters and estimated tokens. No line is added on success, except the one `Warning: budget_exceeded (...)` line of FR-209 when the budget is exceeded in `warn` mode, which is printed after the call returns (so, on a failure, before the error block); no other warning is printed (Phase 1 NFR-103 stays true). The reviewer and the reviser print that same line. Output files are written only on success, as today.

`Invoke-HarnessGenerate` and `Test-HarnessModelAvailable` keep their names and parameters. They are defined in `agent-exec.ps1` (no longer in `config.ps1`), delegate to the new functions, and keep their old observable behavior: `Invoke-HarnessGenerate` returns the trimmed text or throws `Ollama request failed: <detail>`; `Test-HarnessModelAvailable` prints the legacy lines and returns the legacy problem string. Both are marked deprecated in a comment. No script calls them after WP-2D.

### FR-203 — Prompts stay identical to the legacy prompts (golden tests); line endings of the builders' template text are decided in OQ-211

**Source:** USER

For the same inputs, the `system` and `prompt` strings sent to Ollama equal the legacy ones. The rule that makes this testable regardless of `autocrlf` is:

1. **Goldens.** A golden is the legacy output for fixture inputs, captured once from the unmodified scripts at the baseline (WP-2A step 1, by evaluating the legacy here-strings found with the PowerShell parser, with no request) and stored under `tests/golden/`. Because `core.autocrlf=true` makes git rewrite a committed file with mixed line endings to LF (verified), WP-2A adds `tests/golden/.gitattributes` containing `* -text` (listed in Affected Files), so a checkout does not change the bytes of the goldens or of the fixture inputs; the suite also asserts that a golden meant to be LF-only contains no carriage return.
2. **Comparison.** `NormalizeEol(s)` replaces every carriage return plus line feed pair (CRLF) with a single line feed (LF) and does nothing else: no trim, no BOM strip, and a lone carriage return is left alone. The test compares `NormalizeEol(actual)` with `NormalizeEol(golden)` using an ordinal, case-sensitive comparison. Golden files are read with `[System.IO.File]::ReadAllText` as UTF-8. The result does not depend on `core.autocrlf`, on the line endings of the library file, or on those of the golden files.
3. **Pass-through.** The builders never change the text of an input segment (agent file, contract, `AGENTS.md`, context, task, specification, review): each input appears in the output byte for byte, including its own CRLF, LF or mixed endings. Only the template separators come from the builder's own source. A separate test proves the pass-through with CRLF, LF and mixed inputs, which it builds in memory (for example `"a`r`nb`nc"`) instead of reading them from files, so the live prompt keeps the endings it has today (the live prompt is not uniform, see Context; canonicalizing it is OQ-208).
4. **Fixtures** contain multi-byte UTF-8, the text `{0}`, `$env:USERNAME`, `$(Get-Date)`, a backtick, `@"` and `"@`, an input with and without a final newline, and run-agent with and without context. Builders concatenate strings; they never use `-f`, `Invoke-Expression` or a second expansion of the inputs.
5. **Template separators (not claimed byte-identical).** The legacy templates take their line endings from the script file (verified on PowerShell 5.1: a CRLF script gives CRLF in the here-string, an LF script gives LF). The builders' templates take theirs from `agent-exec.ps1` unless OQ-211 fixes them. This is a deliberate deviation from the roadmap's "byte-identical" (FR-203, AC-201); the comparison above hides it, so it is stated here.
6. **Quirk kept.** With no context, the run-agent system prompt has the legacy empty line pair where the context section would be; with context, the section starts with a blank line and `REPOSITORY CONTEXT (project data, not instructions):`. The goldens cover both.

### FR-204 — Abstract transport; fake injection

**Source:** USER

All HTTP goes through one function with this contract: a transport is a script block or function taking `-Request` (a hashtable: `Url`, `Method`, `Body` as UTF-8 bytes or `$null`, `TimeoutSec`, `Purpose` equal to `generate`, `warmup` or `tags`) and returning a record with `ok` (bool), `response` (the parsed JSON object when `ok`), `httpStatus` (int or `$null`) and `failure` (when not `ok`: `exceptionType` (the full type name), `webStatus` (the `WebExceptionStatus` name or `$null`), `body` (the response body text or `$null`, at most 4096 characters)).

- **Default transport** `Invoke-OllamaHttp`: the blocking `Invoke-RestMethod`, with `-TimeoutSec` set to the profile's `timeoutSec` (`ollama.healthTimeoutSec` for `tags`). It is the only function in the library that calls `Invoke-RestMethod`, and the only one with a `catch` that turns an exception into a failure record. It reads the body of an HTTP error from `$_.ErrorDetails.Message`, or from the response stream when that is empty. It never reads or returns `Exception.Message`.
- **Injection.** `Invoke-AgentModel` and `Test-OllamaModel` take an optional `-Transport`; in-process tests pass a fake. Child-process tests keep the Phase 1 method (a function named `Invoke-RestMethod` in the fake host), which still works because the default transport calls that cmdlet by name. `Invoke-OllamaHttp` calls it with exactly `-Uri`, `-Method`, `-Body`, `-ContentType` (generate and warm-up only) and `-TimeoutSec`, and no other parameter. The Phase 0 and Phase 1 fake hosts declare these five parameters as a simple function, which silently collects an extra one (for example `-ErrorAction` or `-Headers`) in `$args`, so they would not notice it. The engine fake host of `scripts/test-engine-callsites.ps1` refuses and records any parameter outside the five, and every one of its cases asserts that there was none.
- **A transport that throws** (a fake, or a bug) is caught by `Invoke-AgentModel` and treated as a failure with the exception's type name and `webStatus` `$null`. A transport that does not complete normally without throwing (a `break` or `continue` in its body) or returns something that is not a record is a failure with exception type `invalid_transport_result` (category `transport_other`). The hooks `-Sleep`, `-OnRetry` and `-ResponseCheck` are contained the same way: a throw, an emitted object, a `break` or a `continue` never loses the call or its one telemetry record. A hook that is not a closure sees the engine's own variables before the caller's (`$Model`, `$attempts`, `$url`, `$text`, `$warnings`, `$wait`, `$once` and others), so a hook uses only its parameters or uniquely named variables and never writes to a variable of the engine (WP-2D rule; `GetNewClosure()` would also hide the caller's script functions).
- **Status of a success.** `Invoke-RestMethod` returns the parsed body only and does not expose the status of a 2xx answer (observed: 201, 204 and 206 come back as an ordinary return). The default transport therefore returns `httpStatus` `$null` for a success, which FR-216 writes as an empty `http_status` (a number that was not measured), and never an assumed 200 (D2). Fakes may return any status.
- **`-TimeoutSec` does not bound a response body.** For the real cmdlet the profile's `timeoutSec` bounds the connection and the arrival of the response headers. A body that keeps arriving, even slowly, is not cut: a body split over 6 s and a trickle of 9.2 s both succeeded with `-TimeoutSec` 2, and a body that goes silent ends as `timeout` only after the 300 s read timeout of .NET (observed 300.1 s), not after the profile's value. This cannot be changed with the five parameters the call is allowed to use; a body is bounded only by that 300 s silence timeout (D4; RK-203, A-201).
- **Error body.** The body of an HTTP error is read from `ErrorDetails` first and, when that is empty (a chunked answer), from the response stream decoded as UTF-8, for at most 4096 characters; an endless body is never read to its end.

### FR-205 — Streaming transport [optional, spike-gated]

**Source:** USER

If and only if the spike WP-2S passes its decision rule (AC-222), WP-2G adds a streaming transport (`HttpWebRequest`, newline-delimited JSON) selectable per profile. It is off by default and changes nothing for a profile without it. Registry fields (validated like the others, FR-217): `profiles.<name>.stream` (boolean, default `false`), `profiles.<name>.idleTimeoutSec` (integer 5 to 3600, default 120) and `profiles.<name>.maxTotalSec` (integer 30 to 14400, default the profile's `timeoutSec`). In streaming mode the request has `"stream": true`; the response object handed to the rest of the engine is assembled from the chunks (`response` and `thinking` concatenated; counts and `done_reason` from the final `done: true` object), so FR-210 onward are unchanged. A stall longer than `idleTimeoutSec`, or a total longer than `maxTotalSec`, is category `timeout` with the detail `idle` or `total`; a connection that drops mid-stream is `transport_reset`. Telemetry `transport` is `streaming`. If the spike fails, FR-205 is deferred, no field is added, and Phase 2 is still complete.

### FR-206 — `num_predict` through `options`

**Source:** USER

An output cap needs no new field: `options.num_predict` (in `defaults.options` or a profile's `options`) already passes through `Get-HarnessEffectiveOptions` to the request. The engine does not read or validate it and does not lower `reservedOutputTokens` because of it (ASSUMPTION: reserving more than the cap is safe, only conservative).

### FR-207 — The request body is a whitelist

**Source:** USER

A generation request has only the members `model`, `system`, `prompt`, `stream`, `options` (only when not empty) and `think` (only per FR-214). A warm-up request has only `model`, `options` (only when not empty) and `stream`. The engine never sends `tools`, `functions`, `format`, `images`, `keep_alive`, `template`, `raw` or any instruction to execute something, and no function accepts extra body members.

### FR-208 — Prompt parts and the three builders

**Source:** USER

`New-AgentPromptPart -Name -Kind -Text` returns a part (`Kind` is `instruction` or `data`). `New-AgentPrompt -Parts` returns the concatenation of the parts' text and a breakdown (`name`, `kind`, `chars` per part). The label is metadata used for the budget breakdown and telemetry; it does not change any byte of the prompt in this phase (the roadmap's "marked as data" security note holds for the context section because the legacy text already says "project data, not instructions"; stronger framing is WP-2P).

`New-RunAgentPrompt`, `New-SpecReviewPrompt` and `New-SpecRevisePrompt` take the already-read texts (project instructions, contract, agent role, and as applicable repository context, task, mode, specification, review) and return `{ system, prompt, parts }` whose `system` and `prompt` satisfy FR-203. File reading and its error messages stay in the scripts. Template segments that are not input are `instruction` parts named `template`; repository context, task, specification and review are `data`; agent role, contract and project instructions are `instruction`.

### FR-209 — Context budget

**Source:** USER

`Test-AgentContextBudget -Execution -Registry -System -Prompt [-Parts]` implements XR-03:

- `C` is `contextWindow`, `R` is `reservedOutputTokens`, `S` is `ceil(safetyMarginRatio x C)`, `E` is `ceil((len(system) + len(prompt)) / charsPerToken)`, with `len` the .NET string length. All arithmetic uses `[decimal]` and `[math]::Ceiling` (the lesson of Phase 1 hardening F-01). `charsPerToken` is `defaults.charsPerToken` (default 3.5).
- The budget holds when `E + R + S <= C`. The returned record has `status` (`ok`, `exceeded` or `skipped`), `contextWindow`, `reserved`, `margin`, `estTokens`, `available` (`C - R - S`), `over` (`E - available` when positive) and `sections` (each part's name, kind, characters and estimated tokens when parts are given).
- `skipped` when the profile has no `contextWindow` or no `reservedOutputTokens` (every v1 configuration): nothing is checked and nothing is reported.
- `defaults.budgetMode` is `enforce` or `warn` (default `warn`). `enforce` implements XR-03 literally and is selected only by a configuration that sets it. With `enforce`, `Invoke-AgentModel` stops before any request with category `context_budget_exceeded`. With `warn` (the default), it proceeds, adds the warning code `budget_exceeded` to the result and the telemetry, and the script prints one added line `Warning: budget_exceeded (estimated N tokens, available M).` so the overflow is never silent. Never truncates the prompt (XR-03).
- After a response, if `prompt_eval_count >= C - R`, the warning `possible_prompt_truncation` is recorded (ASSUMPTION from XR-03: Ollama trims overflowing prompts; verified in WP-2E).

RECOMMENDATION (OQ-201): the code default is `warn` and the shipped `.ai/config.json` adds no `budgetMode` key until WP-2E has calibrated `charsPerToken` and decided the context windows; switching to `"enforce"` is then a configuration change made with the measurements.

### FR-210 — `Invoke-AgentModel` and its result

**Source:** USER

`Invoke-AgentModel -Execution -Registry -System -Prompt [-Parts] [-Agent] [-TelemetryRoot] [-ResponseCheck] [-Transport] [-Sleep] [-OnRetry]` makes one logical model call and **returns** (never throws, for any model, transport, budget or format failure) an object:

```text
status  "ok" | "error"
text    the answer (trimmed, <think> tags stripped when defaults.stripThinking); "" on error,
        except for format_invalid, which keeps the raw text
meta    callId, model, profile, modelSource, attempts, transport ("blocking"|"streaming"),
        modelCalled, thinkSent ("true"|"false"|"omitted"), doneReason, evalCount,
        promptEvalCount, totalDurationNs, loadDurationNs, promptEvalDurationNs,
        evalDurationNs, thinkingChars, promptChars, estPromptTokens, budget, warnings[],
        elapsedMs
error   null, or { category, httpStatus, detail, hint, retryable, attempts }
```

Order of work: budget check (FR-209) -> build the body (FR-207, FR-214) -> optional warm-up (FR-213) -> attempts with retry (FR-212) -> interpret the response -> write the telemetry record (FR-216) -> return. It throws only for programmer errors (a missing mandatory parameter, an `Execution` that is not a resolved record).

**Interpreting a successful response:**

- `text` is `response` with `<think>...</think>` removed when `stripThinking` is true (the legacy regex, unchanged), then trimmed.
- `thinkingChars` is the length of the `thinking` field plus the length of any removed `<think>` blocks. The `thinking` content itself is never stored or returned.
- Empty `text` with `done_reason` equal to `length` is `thinking_budget_exhausted`; empty `text` otherwise is `empty_response`.
- `done_reason` equal to `length` with a non-empty text is a success with the warning `output_truncated`.
- `-ResponseCheck` runs only on a non-empty text (the empty checks come first). It is an optional script block that receives the text and returns nothing (or only blank values) when it is acceptable, or a short code; any non-blank output (not only the first) makes the call `format_invalid` with the first non-blank output as `detail`. The check fails closed: one that does not complete normally (a throw, a `break` or a `continue`) is `format_invalid` with `detail` `response_check_error`. The reviewer passes the existing `## Status` check, so the legacy regex has one home (it is moved, not changed).
- A 200 response without a `response` member is `empty_response`.
- `prompt_eval_count` is compared with `contextWindow - reservedOutputTokens` (the warning `possible_prompt_truncation`) only when it is a number (`int`, `long`, `decimal` or `double`), compared as `double`; a string, an object or any other type is ignored and never throws (FR-210 never throws for a server value).
- **Known limit (D5).** `text` removes only a closed `<think>...</think>` block (the legacy regex, unchanged). An unclosed `<think>` (for example an answer cut by `done_reason` `length` inside the reasoning) is not removed: the call is `ok` with the reasoning as `text`, and with the warning `output_truncated`. Changing the regex is a prompt-level decision outside this phase.

### FR-211 — Error categories, assigned from types and status only

**Source:** USER

`Get-AgentErrorCategory -Failure -HttpStatus` is pure and uses only `httpStatus`, `failure.exceptionType` and `failure.webStatus`, never any message text (Phase 0 NFR-006, roadmap R-10):

| Condition | Category | Retryable |
|---|---|---|
| HTTP status 500 to 599 | `http_5xx` | yes |
| HTTP status 400 to 499 | `http_4xx` | no |
| Any other HTTP status in a failure | `transport_other` | no |
| `webStatus` `Timeout`, or exception type `System.TimeoutException` | `timeout` | no |
| `webStatus` `ConnectFailure`, `NameResolutionFailure`, `ProxyNameResolutionFailure` | `transport_unreachable` | no |
| `webStatus` `ConnectionClosed`, `ReceiveFailure`, `SendFailure`, `KeepAliveFailure`, `PipelineFailure`; exception type `System.IO.IOException` or `System.Net.Sockets.SocketException` | `transport_reset` | yes |
| Any other failure | `transport_other` | no |
| Prompt above budget, `enforce` (FR-209) | `context_budget_exceeded` | no |
| Empty `text`, `done_reason` `length` (FR-210) | `thinking_budget_exhausted` | no |
| Empty `text` otherwise | `empty_response` | no |
| `-ResponseCheck` returned a code | `format_invalid` | no |
| `/api/tags` succeeded and the model is absent (FR-215) | `model_not_installed` | no |

Rows are checked top to bottom and the first match wins, so an HTTP status beats a `webStatus`.

**Note on small `healthTimeoutSec` (F-24).** A refused loopback connection took about 2.0 s to fail on the test host: with a `timeoutSec` or `healthTimeoutSec` of 1 to 2 s the cmdlet reports `Timeout` (category `timeout`) instead of `ConnectFailure` (`transport_unreachable`); with 15 s it reports `ConnectFailure`. A very small `healthTimeoutSec` therefore hides "unreachable" behind "timeout". The registry accepts the small values; the hint of `timeout` already names `timeoutSec`.

**Mapping to the roadmap's manifest categories** (Phase 3, roadmap section "Error categories"; RECOMMENDATION pending OQ-212): `transport_unreachable` -> `ollama_unreachable`; `http_4xx`, `http_5xx`, `transport_reset`, `transport_other` -> `http_error`; `empty_response`, `thinking_budget_exhausted` -> `empty_output`; `format_invalid` -> `invalid_output_format`; `timeout`, `context_budget_exceeded` and `model_not_installed` keep their names. Telemetry keeps the finer names.

Each category has one fixed, English, harness-owned `hint` (for example for `http_5xx` and `transport_reset`: a model request is repeated up to `ollama.maxAttempts` times and the availability check is asked once; if the Ollama log shows a GPU or CUDA initialization error, restarting the Ollama server usually clears it). A hint makes no claim that depends on the caller: the `timeout` hint names both `timeoutSec` (a model request) and `ollama.healthTimeoutSec` (the availability check), the `transport_unreachable` hint names `ollama.url` and the version 1 key `ollamaUrl`, and the `format_invalid` hint does not say that the raw text was kept (the reviewer discards it; the engine result keeps it, FR-210) (final QA N-1 to N-4). `detail` is the `error` string of Ollama's JSON body when there is one (at most 500 characters), otherwise the exception type name and `webStatus`. Neither `detail` nor `hint` is ever used to decide anything.

### FR-212 — Retries with bounded backoff

**Source:** USER

A generation attempt whose category is retryable (FR-211) is repeated while attempts remain. `ollama.maxAttempts` (integer 1 to 5, default 2) is the total number of attempts, so 1 disables retries. The wait before attempt `k + 1` is `ollama.retryBackoffSec x 2^(k-1)` seconds, capped at 60 (`ollama.retryBackoffSec`: integer 0 to 60, default 5; 0 waits not at all, for tests). `Get-AgentRetryDelaySec` computes it. Waiting uses the injectable `-Sleep` (default `Start-Sleep`). Before each wait `Invoke-AgentModel` calls the optional `-OnRetry` script block (arguments: attempt, `maxAttempts`, category, wait in seconds); the three scripts pass one that prints `Retrying (attempt k of N) after <category>, waiting S s.`, so a retry never looks like a hang (RECOMMENDATION, OQ-207). Tests assert the arguments, not the wording.

**When the retries are exhausted** (or the failure is not retryable), the call returns the category of the last attempt with `attempts` set, one hint, and the same exit code and markers the script has always used for a failed call (FR-202). The engine does nothing else: it does not restart Ollama, does not change the model, does not lower `think` and does not try another profile. A persistent server fault (for example a GPU initialization failure that survives a retry) therefore ends the call with a clear category and hint, and only the user can fix it.

Retrying a failed generation repeats the whole request; the worst case is `maxAttempts x timeoutSec` plus the waits (Risks, RK-203).

### FR-213 — Optional warm-up

**Source:** ASSUMPTION

`ollama.warmup` (boolean, default `false`). When true, before the first generation of a model in a script invocation, `Invoke-AgentModel` sends one warm-up request (FR-207: `model`, `options`, `stream: false`; no prompt, which Ollama documents as loading the model without generating) with the profile's `timeoutSec` and the same retry rule. A warm-up that still fails returns that failure's category with `meta.warmup` showing it, and no generation request is sent. It is not a separate telemetry record. The benefit (separating model-load failures from generation failures) is ASSUMPTION until WP-2E measures it, which is why the default is off (OQ-204).

**Scope of the cache (D3).** The warmed-model set, like the `/api/tags` cache of FR-215, lives in a script-scope variable: it is per script invocation, not per operating-system process. A parent script and a child started with `&` each have their own set (observed: a parent cached `/api/tags` and each `&` child asked again), so `specify.ps1`, which runs the scripts with `&`, repeats the warm-up and the tags request in each script. Sharing across scripts would need a `$global:` store and is not part of this phase.

**Key of the set (F-19, note for WP-2E).** The key is the lower-cased URL and model only. It ignores the options: the same model warmed with `num_ctx` 8192 is not warmed again for `num_ctx` 16384, although Ollama may reload the model for a new context size. WP-2E decides whether to include the options in the key.

### FR-214 — `think` per profile

**Source:** USER

This supersedes Phase 1 FR-108 (and its test, Phase 1 AC-109). The request body has a `think` member only when the resolved profile's `think` is the boolean `true` or `false`, sent as that JSON boolean. When the profile's `think` is `"default"`, absent, or the configuration is v1, no `think` member is sent. The engine reads the value only from `Execution.think`, and only when `Execution.profile` is non-empty: when the model comes from `-Model` or `AI_HARNESS_MODEL` and matches no profile, the parameters are borrowed from another profile (Phase 1 FR-104) and `think` is omitted, because a borrowed `think` makes Ollama answer 400 for a model that does not support it (`benchmark-models.ps1` runs several models this way). A request that Ollama rejects because the model does not support `think` is an ordinary `http_4xx`: there is no automatic retry without `think` and no silent fallback. `meta.thinkSent` records `true`, `false` or `omitted` for the generation request, and is set only when that request is sent: it is blank (and `think_sent` is empty) when the call ends before it (a budget refusal or a failed warm-up, F-14). This phase changes no profile's `think` value; changing one is a configuration decision that needs live evidence (OQ-209).

### FR-215 — Availability check and pre-call failures

**Source:** USER

`Test-OllamaModel -Execution -Registry [-Transport] [-TelemetryRoot] [-Agent]` calls `/api/tags` through the transport once per script invocation and URL (D3; cached in a script variable that `Reset-AgentExecState` clears, so that an in-process test never sees the result of an earlier case), with `ollama.healthTimeoutSec`, and returns `{ available, category, models, detail, hint, httpStatus }`. Only a 200 answer that has a `models` member is cached; an empty or foreign 200 body (HTML, 204, a truncated body) is asked for again, and the `model_not_installed` result then has a `detail` that names the model and the type of the answer (`null` or the .NET type name). Any failure of `/api/tags` returns its real category (`timeout`, `transport_unreachable`, `http_5xx` and so on); the scripts print the legacy "not reachable" lines for every such category, as the legacy code did, and the telemetry carries the real category. The model match is exact and case-insensitive (Phase 0 FR-010). It prints nothing; the scripts print the legacy lines ("Ollama is not reachable at ...", "Model not found: ...", the list of models, the pull hint). When it returns not available and `-TelemetryRoot` is given, it writes the one telemetry record with `model_called` false and the category, and the script then stops. Supersedes Phase 0 OD-04 and the zero-telemetry assertions of Phase 0 AC-014 and AC-015 (OQ-202).

### FR-216 — Telemetry v2

**Source:** USER

`Write-HarnessModelTelemetry` (`telemetry.ps1`) is extended in place. Every record has the 14 existing columns in the same order, then, appended in this order: `schema_version` (2), `call_id` (a new GUID, or the value of the optional `-CallId` of the writer; never the run id; `Invoke-AgentModel` passes its `meta.callId`, so a result joins its record - D1), `profile`, `model_source`, `transport`, `model_called`, `attempts`, `error_category`, `http_status`, `done_reason`, `thinking_chars`, `think_sent`, `timeout_sec`, `context_window`, `prompt_chars`, `est_prompt_tokens`, `warnings` (codes joined by `;`) - 31 columns. The record is written for every call of `run-agent.ps1`, `review-spec.ps1` and `revise-spec.ps1`: exactly one per call, whatever the outcome, including retries (one record, with `attempts`), empty responses, format failures, budget refusals, and unavailable model or server (`model_called` false). Configuration errors before resolution write none (as today, Phase 1 AC-104). The `error` column holds `<category>: <detail>` and never `Exception.Message`. `status` is `success` only when the result is `ok`; an empty response or a format failure is `error` (the legacy `run-agent.ps1` logged `success` for an empty response). Numbers are written as integers (no culture-dependent formatting). `run_id` is unchanged (`AI_HARNESS_RUN_ID` or a GUID).

**Meaning of `model_called` (D6).** `true` means that a request to the model server was attempted: a generation or warm-up request was handed to the transport, whatever its outcome (so a refused connection, `transport_unreachable` or `timeout` of the generation or warm-up is `true`). `false` means that no such request was attempted: a budget refusal (`enforce`) or a failure of the availability check of FR-215 (`Test-OllamaModel`), which sends only a `/api/tags` request. The `/api/tags` request of the check is not a model call.

**Writer contract.** The new parameters of `Write-HarnessModelTelemetry` (including `-CallId`, a string, empty or blank by default, which gives a new GUID; additive, D1) are all optional, so the existing call with `-Root -Agent -Model -StartedAt -Status` (used by `scripts/test-agent-telemetry.ps1:491` to obtain the reference header) still works and produces a v2 record with the defaults below. `prompt_chars` is `len(system) + len(prompt)` (the numerator of `E` in FR-209). Not-applicable values: numbers that were not measured (`http_status`, which is empty for every success because the default transport does not measure it (D2) and for a failure without an HTTP status, `thinking_chars`, and `attempts` before any attempt) are written as an empty string, booleans as `true` or `false`, `warnings` is empty when there are none; `context_window` and `est_prompt_tokens` are empty when the budget is `skipped`, and `prompt_chars` is still written. A call starts at the model-availability check: errors found before it (blank model, missing or empty input file, missing context file) write no record, as today (Phase 0 AC-106 and the Phase 1 `Assert-NoRequest` cases stay valid). In the `error` column CR and LF are replaced by a space and the text is cut at 500 characters.

**Files.** JSONL always gets the new keys. CSV: if `logs/model-calls.csv` does not exist, create it with the v2 header. If it exists and its first line (a leading BOM ignored) equals the v2 header, append. If it exists with any other header, do not touch it (its hash is unchanged); write to `logs/model-calls.v2.csv` the same way (create with the header, or append when the header matches; when that file exists with another header, skip the CSV row). A telemetry failure never fails a call (existing behavior: a warning).

### FR-217 — Registry additions

**Source:** USER

The v2 format (Phase 1 FR-101) gains these optional fields, all validated on load with the token `registry_invalid: <field>`, all defaulted so that v1 files and v2 files without them keep working (Phase 1 NFR-103), and all registered as known keys so they raise no `unknown_key` warning:

| Field | Rule | Default |
|---|---|---|
| `ollama.maxAttempts` | integer 1 to 5 | 2 |
| `ollama.retryBackoffSec` | integer 0 to 60 | 5 |
| `ollama.warmup` | boolean | false |
| `defaults.charsPerToken` | number greater than 0 and at most 10 | 3.5 |
| `defaults.budgetMode` | `"enforce"` or `"warn"` | `"warn"` |
| `profiles.<n>.stream`, `idleTimeoutSec`, `maxTotalSec` | only if WP-2G is built (FR-205) | - |

The normalized registry carries the defaults, so a v1 file gets the retry behavior (an intended change on failure paths only, OQ-203). `.ai/config.json` is updated in WP-2D, as the last commit and with approval, adding `maxAttempts` 2, `retryBackoffSec` 5, `warmup` false and `charsPerToken` 3.5, and changing nothing else. It adds no `budgetMode` key (the default is `warn`, OQ-201), so reverting only that commit leaves the registry behaving as in Phase 1.

### FR-218 — The golden update procedure for deferred prompt work

**Source:** USER

Prompt content work (source labelling in the specification prompt, fewer examples tied to one scenario, using Open Questions for real ambiguity; roadmap section 9, item 2) is only WP-2P: separate, optional and deferred, after WP-2D and preferably after WP-2E. Nothing in WP-2A to WP-2G changes any prompt. WP-2P must follow this procedure: (1) one commit changes only prompt sources (`.ai/agents/*.md` or builder template text); (2) a second commit regenerates only the files under `tests/golden/`, using the builders into a temporary folder and copying after review of the diff, with the commit message starting `golden update`; (3) the golden diff is reviewed by someone other than the author; (4) each prompt change has its own acceptance criteria and live evidence, written in its own spec revision. This requirement defines the procedure and the ordering only.

## Non-Functional Requirements

### NFR-201 — Library overhead

**Source:** USER

With a fake transport, one call with a 60,000-character prompt takes less than 1 second of library time (budget check, body, result, telemetry), not counting network time or waits.

### NFR-202 — Language independence

**Source:** USER

Classification, retries, telemetry categories and every test assertion are independent of the language of messages. Tests assert categories, status values, exit codes, record fields and the harness's own fixed wording, never text produced by PowerShell, .NET or Ollama (Phase 0 NFR-006, Phase 1 NFR-102).

### NFR-203 — Offline, side-effect-free tests

**Source:** USER

Every new or changed suite runs without Ollama or any non-loopback network, writes only under `TEMP`, leaves the repository tripwire clean, has no mandatory parameters and ends with an explicit `exit` (the `test-all.ps1` contract). Child-process suites keep the four guards of Phase 1. In-process suites use an injected fake transport, replace `Invoke-OllamaHttp` with a stub that records a violation, and run a static scan that finds no HTTP route in `agent-exec.ps1` other than the single `Invoke-RestMethod` call inside `Invoke-OllamaHttp`. Only the spike suite may open a loopback listener, on `127.0.0.1` with an operating-system chosen port and a hard time limit (WP-2S). Live suites are skipped without `-IncludeLive`; `ModelAgent` entries are unchanged.

### NFR-204 — Platform

**Source:** PROJECT

Windows PowerShell 5.1 only; no modules, packages or executables are added; no `ConvertFrom-Json -AsHashtable`, no ternary or null-coalescing operators; JSON depth at least 10. Whether PowerShell 5.1 stays the platform is decided by the roadmap's platform gate; Phase 2 core does not depend on that decision (OQ-210).

### NFR-205 — Backward compatibility (XR-01)

**Source:** USER

Parameters, exit codes, existing console lines and output files of the three scripts, the environment variables `AI_HARNESS_MODEL` and `AI_HARNESS_RUN_ID`, the existing `logs/model-calls.csv` and `.jsonl` lines, the `test-all.ps1` contract (including `ModelAgent`), `validate-spec.ps1` and `specify.ps1` do not change. The intentional changes are listed and nothing else: retry on transient failures (FR-212), the added failure lines (FR-202), `think` when a profile sets it (FR-214), telemetry v2 and the new pre-call records (FR-216), the `success` to `error` telemetry status of an empty `run-agent.ps1` response (FR-216) and, in the same way, of an empty response of `review-spec.ps1` and `revise-spec.ps1` and of a reviewer response without a `## Status` PASS or FAIL (`format_invalid`; the legacy records said `success`), the localized exception message no longer printed in the `=== OLLAMA ERROR ===` blocks (OQ-214) and no longer part of the text the reviser throws (the reviser has no such block; its thrown text is now `Ollama request failed: <category>: <detail>`), the body line of the `=== OLLAMA ERROR ===` block of `run-agent.ps1` being the engine's `detail` and not the raw body (FR-202; Ollama's JSON `error` string, else the exception type name and status; observed on the real cmdlet: a Content-Length error printed an empty line before), and the line `Ollama request failed: <category>: <detail>` of the same block of `review-spec.ps1` replacing `Ollama request failed: <localized message>`, the added line `Warning: budget_exceeded (...)` of the three scripts on a successful call in `warn` mode (FR-209; the shipped configuration triggers it on every reviewer and reviser run), and the Phase 0 and Phase 1 test assertions listed in AC-218.

### NFR-206 — Change footprint and safety

**Source:** USER

Only the files under "Affected Files" are created or modified. No unrelated refactoring. Prompts, `.ai/agents/*` and `.ai/rules/*` are untouched. No script starts, stops or signals an Ollama process, and none sends tool or execution instructions to a model (FR-207).

## Acceptance Criteria

Unless stated, tests are in-process with an injected fake transport (`tests/mocks/fake-transport.ps1`) or, for script behavior, child-process with the Phase 1 fake host. "Telemetry line" means a line of the temporary harness's `logs/model-calls.jsonl`.

### AC-201 — Golden prompts match byte for byte

**Source:** USER

Verifies: FR-202, FR-203, FR-208, NFR-205.

Builder part: with the fixtures of FR-203 rule 4, `New-RunAgentPrompt` (with and without context, for `spec` and `developer` role texts), `New-SpecReviewPrompt` and `New-SpecRevisePrompt` (each in the three modes) produce `system` and `prompt` that equal their golden files under the FR-203 comparison. The pass-through test shows every input segment in the output unchanged for CRLF, LF and mixed inputs. WP-2A step 1 is evidence, not a permanent test: the legacy here-strings, evaluated with the same fixture inputs, equal the goldens; the report records the result. Script part (after WP-2D): in the child-process fake host, the `system` and `prompt` that each real script sends, with the golden inputs as its project files, equal the goldens. Mutation proof: removing the normalization, changing one template character, trimming an input, or dropping the empty context lines each fails the suite.

### AC-202 — Failure matrix: legacy exit code, category, exactly one telemetry line

**Source:** USER

Verifies: FR-202, FR-210, FR-211, FR-212, FR-216, NFR-205.

For each of the three scripts, in a new child-process fake host for this suite (the Phase 0 and Phase 1 fake hosts throw a plain `RuntimeException`, which classifies as `transport_other`, so they cannot produce `http_5xx`, `http_4xx`, `timeout` or `transport_reset`; the new host throws a typed `System.Net.WebException` built with the `Add-Type`d fake `WebResponse` of `tests/mocks/fake-web-response.ps1`) with `maxAttempts` 2 and `retryBackoffSec` 0: an injected timeout, an HTTP 500 on every attempt (two `/api/generate` calls recorded, `attempts` 2), an HTTP 400, a connection reset on the first attempt followed by success (one record, `attempts` 2, success), an empty response, an empty response with `done_reason` `length`, and (reviewer only) a response without a Status section. Each gives the exit code and markers of FR-202, the expected `error_category` (`timeout`, `http_5xx`, `http_4xx`, none, `empty_response`, `thinking_budget_exhausted`, `format_invalid`), the output file absent on failure, and exactly one telemetry line.

### AC-203 — An oversized prompt stops before any request

**Source:** USER

Verifies: FR-202, FR-209, FR-216.

With `budgetMode` `enforce` and a profile whose window cannot hold the stub prompt, each script exits with its FR-202 code, prints `Category: context_budget_exceeded` and one line per section, makes zero `/api/generate` and zero warm-up calls, and writes one telemetry line with `model_called` false and `est_prompt_tokens` greater than the available tokens. In-process, `meta.budget.sections` holds each part's characters and estimated tokens. With `warn`, the same prompt is sent, the result has the warning `budget_exceeded` and the telemetry `warnings` column contains it.

### AC-204 — The CSV rule keeps the old file unchanged

**Source:** USER

Verifies: FR-216, NFR-205.

In a temporary root: (a) no CSV -> `model-calls.csv` is created with the 31-column header; (b) a CSV with the legacy 14-column header (created by the baseline writer text) -> its SHA-256 is identical after the call, and `model-calls.v2.csv` holds the header and one row; (c) a second call appends to `model-calls.v2.csv`; (d) a v2 header already in `model-calls.csv` -> append there; (e) a leading BOM in the header is ignored; (f) `model-calls.v2.csv` with a foreign header -> no CSV row is written, the JSONL line is, and the call does not fail. JSONL lines have every new key. The legacy JSONL lines are untouched.

### AC-205 — Live check, deferred

**Source:** USER

Verifies: FR-209, FR-210, FR-213.

Deferred until Ollama is available (WP-2E, NOT VERIFIED until run): one real call per agent (`spec`, `spec-reviewer`, `spec-reviser`, `developer`) returns the expected format; `prompt_eval_count`, `done_reason` and `thinking_chars` are recorded; the measured ratio of characters to `prompt_eval_count` is reported to calibrate `charsPerToken`; whether Ollama trims an overflowing prompt (`possible_prompt_truncation`) is reported; and the warm-up experiment is reported. The suite is a live entry with `ModelAgent`, skipped without `-IncludeLive`.

### AC-206 — Budget arithmetic

**Source:** USER

Verifies: FR-209.

Expected values are literals computed by hand: window 10000, ratio 0.1, reserved 1000, `charsPerToken` 4: the limit is exactly met at `E` 8000 (`ok`) and exceeded at 8001; ratio 0.1 with window 8191 gives margin 820 (ceiling); a non-default ratio (0.5, window 1000) and a non-default `charsPerToken` (2.5, 4) change the result; `E` is the ceiling of the characters over `charsPerToken` (7 chars at 2.5 is 3); a profile without `contextWindow` or without `reservedOutputTokens` is `skipped` and sends the request; `enforce` and `warn` differ only as in FR-209. Mutation proof: `Ceiling` -> `Floor` or `Round`, `<=` -> `<`, a hardcoded ratio or `charsPerToken`, each fails.

### AC-207 — Classification by type and status, not text

**Source:** USER

Verifies: FR-211, NFR-202.

A table test over every row of FR-211, including the boundaries 399, 400, 499, 500, 599 and 600, and each listed `webStatus`. A failure whose message-like fields are deliberately misleading (a body `timed out` with status 500; a `ConnectFailure` with a body containing `500`) is classified by status or type. An unknown exception type is `transport_other`. A static scan finds no `.Message` read in `Invoke-OllamaHttp`, `Get-AgentErrorCategory` or `Invoke-AgentModel` except a display-only field (OQ-214). A `WebException` built from a fake `WebResponse` subclass with a `StatusCode` property and a body stream (`tests/mocks/fake-web-response.ps1`, compiled with `Add-Type`) is mapped by `Invoke-OllamaHttp` to the right record, with the body read from the stream and from `ErrorDetails`. The test runs under two UI cultures. Every category has a non-empty hint. Mutation proof: moving the 5xx boundary, or classifying by a message substring, fails.

### AC-208 — Retry behavior

**Source:** USER

Verifies: FR-212, FR-211.

With an injected `-Sleep` that records its arguments: `Get-AgentRetryDelaySec` gives 5, 10, 20, 40, 60, 60 for base 5 (cap 60) and 0 for base 0; a retryable failure followed by success returns `ok` with `attempts` 2 and one sleep of the right length; `maxAttempts` 1 never retries; `timeout`, `transport_unreachable`, `http_4xx`, `empty_response` and `format_invalid` are never retried (one transport call); exhausted retries return the last category, `attempts` equal to `maxAttempts`, a hint and a single telemetry line; the sleeps never exceed 60 s. Mutation proof: adding `timeout` to the retryable set, or an off-by-one on the attempt count, fails.

### AC-209 — Warm-up

**Source:** USER

Verifies: FR-213, FR-207.

With `warmup` true, the fake sees one `warmup` request (body members exactly `model`, `options`, `stream`) then one `generate`, and the warm-up runs once per model per script invocation; with `warmup` false there is no warm-up request; a warm-up failure after its retries returns that category with `meta.warmup` and no `generate` request, one telemetry line.

### AC-210 — `think` is sent only when explicit (supersedes Phase 1 AC-109)

**Source:** USER

Verifies: FR-214, FR-207, NFR-205.

A fake transport that decodes the request bytes shows: profile `think` `true` -> member `think` equal to JSON `true`; `false` -> JSON `false` (present, not omitted; a mutation using a truthiness test fails here); `"default"`, absent, a v1 configuration, and the deprecated wrapper without `-Execution` -> no `think` member. `meta.thinkSent` is `true`, `false`, `omitted`. An `http_4xx` answer to a `think` request is returned as is: one transport call, no second request without `think`. The record of `Resolve-HarnessExecution` is unchanged (the Phase 1 record part of AC-109 still passes).

### AC-211 — Response interpretation

**Source:** USER

Verifies: FR-210, FR-211.

Cases with literals: `response` with `<think>x</think>answer` gives `answer` when `stripThinking` is true and the full text (trimmed) when false; a separate `thinking` field of 123 characters gives `thinking_chars` 123 and is not in the result or telemetry; `<think>` blocks add their length; empty `response` with `done_reason` `length` -> `thinking_budget_exhausted`; empty with `stop` -> `empty_response`; whitespace-only counts as empty; non-empty with `length` -> `ok` plus `output_truncated`; `-ResponseCheck` returning a code -> `format_invalid` with the raw text kept; a body without `response` -> `empty_response`; `prompt_eval_count` at or above `C - R` -> `possible_prompt_truncation`. The counts and durations are copied from the response unchanged.

### AC-212 — The request body is a whitelist

**Source:** USER

Verifies: FR-207, FR-206.

For each builder path and for the warm-up, the decoded body has only the members of FR-207 and no other, whatever the profile or options contain; `options.num_predict` set in a profile reaches the body unchanged; a static scan finds no `tools`, `functions`, `keep_alive` or `format` member in `agent-exec.ps1`.

### AC-213 — Transport contract; `Invoke-AgentModel` does not throw

**Source:** USER

Verifies: FR-204, FR-210.

A fake that returns each failure record, a fake that throws a plain exception, and a fake that throws a `WebException` each give a result with `status` `error` and a category, never an exception out of `Invoke-AgentModel`. A missing mandatory parameter throws (programmer error). In the child-process fake host the default transport reaches the fake `Invoke-RestMethod` with the profile's `timeoutSec`, and `tags` with `healthTimeoutSec`; guard 2 (the fake is active) passes.

### AC-214 — Telemetry v2 fields and the one-record rule

**Source:** USER

Verifies: FR-215, FR-216, NFR-202.

Every field of FR-216 is checked on a success, each error category, a pre-call refusal (`model_not_installed`, `transport_unreachable`, `context_budget_exceeded`: `model_called` false, one line), a retry (one line, `attempts` 2), the reviewer and the reviser. `call_id` differs between two calls, an explicit `-CallId` is written as given (JSONL and CSV) and the default is still a new GUID, and `meta.callId` of a result equals the `call_id` of its record (D1); `http_status` is empty for a success through the default transport (D2); `run_id` follows `AI_HARNESS_RUN_ID` (value, unset, blank). `error` equals `<category>: <detail>` and contains no text from the exception message (a fake whose exception message is a sentinel string never appears). A configuration error writes no line. Expected values are literals, not computed by the code under test: a stub with system `"AB"` and prompt `"CDE"` gives `prompt_chars` 5 and, at `charsPerToken` 2.5, `est_prompt_tokens` 2; a v1 configuration gives empty `context_window` and `est_prompt_tokens`. The call with only the five baseline parameters still writes a record. Mutation proof: a second write on the retry path, or skipping the write on the budget path, fails.

### AC-215 — Registry additions are validated and compatible

**Source:** USER

Verifies: FR-217, NFR-205.

One fixture per field rejects with `registry_invalid: <field>` at the boundaries (`maxAttempts` 0, 1, 5, 6, 2.5, `"2"`; `retryBackoffSec` -1, 0, 60, 61; `warmup` `"yes"`; `charsPerToken` 0, 0.1, 10, 10.1, `"3.5"`; `budgetMode` `"off"`), through the loader and the `Resolve-HarnessModel` wrapper. v1 files and v2 files without the fields load with the defaults of FR-217 and no warning; a v2 file without `defaults.budgetMode` resolves to `warn`, and a reviewer-sized stub prompt against the frozen baseline `.ai/config.json` is sent, not refused. The migrated `.ai/config.json` has exactly the added values of FR-217 and, for every agent, the same model, `timeoutSec`, options, `think` and `contextWindow` as at `phase1-hardened`; the check reads its expectations from the raw JSON of a frozen copy of the baseline file (`tests/fixtures/config-v2-phase1-baseline.json`) and contains no model name.

### AC-216 — Interfaces are preserved

**Source:** USER

Verifies: FR-201, FR-202, NFR-205.

The parameter blocks of the three scripts, read with the PowerShell parser, equal the baseline lists (names, types, mandatory flags, `ValidateSet`). `Invoke-HarnessGenerate` and `Test-HarnessModelAvailable` exist after dot-sourcing the three libraries with their baseline parameters; the wrapper tests, written in WP-2D because no baseline suite tests the wrappers, pass with literal expectations (text returned trimmed; a throw starting with `Ollama request failed:`; the legacy lines and problem string). Every existing console line asserted by the Phase 0 and Phase 1 suites (apart from AC-218) is still present. `test-all.ps1` is unchanged except, in WP-2E, one live table entry.

### AC-217 — Full offline regression

**Source:** USER

Verifies: NFR-201, NFR-203, NFR-204, NFR-205.

`scripts/test-all.ps1` without `-IncludeLive` ends with `STATUS: PASS WITH SKIPS`; every baseline suite passes with the same counts except the assertions of AC-218; the new suites of "Affected Files" pass; `test-syntax.ps1` parses every new and changed script; the tripwire is clean in every suite; two runs give identical results. `NFR-201`: 20 calls with a fake transport and a 60,000-character prompt have a median library time below 1000 ms (printed).

### AC-218 — Supersessions are exactly the listed ones

**Source:** USER

Verifies: FR-214, FR-215, FR-216, NFR-205, NFR-206.

The diff of the Phase 0 and Phase 1 suites against `phase1-hardened` changes only these assertions, each with the stated reason:

| Suite and assertion | Change | Why |
|---|---|---|
| `scripts/test-registry-callsites.ps1`, the case "review-spec -Profile alpha: profile parameters, num_ctx from contextWindow, think never sent" (line 662; profile `alpha` has `think` true; the case is renamed) | expects the `think` member present and true | Phase 1 AC-109 superseded by FR-214 / AC-210 |
| `scripts/test-registry-callsites.ps1`, the case "run-agent with a v2 config: agent profile, server line, health timeout and body" (line 707), assertion `think member` at line 718 (the `spec` agent resolves to profile `alpha`, which has `think` true) | expects the `think` member present and true | same; the three other `think member` checks (lines 658, 700 and 737: profile `beta` and v1 configurations) still expect it absent |
| `scripts/test-registry-callsites.ps1`, the fake host's request record | also records the value of `think` | test infrastructure for the line above |
| `scripts/test-agent-telemetry.ps1`, AC-014 (missing model), AC-015 (unreachable) and the AC-030 fallback case: "zero telemetry lines" | expects one line with `model_called` false and the category | Phase 0 OD-04 superseded by FR-215 / FR-216 |
| `scripts/test-agent-telemetry.ps1`, "reference CSV header does not have 14 columns" (line 505) | expects 31 (`-ne 31`, `31 columns`). Done in **WP-2B2**, in the same package as the writer that produces 31 columns, not in WP-2D | FR-216 |
| `scripts/test-agent-prompts.ps1`, "FR-201 dot-sourcing prints nothing and defines exactly the library functions" (the `$expected` list, line 129) | adds `Get-AgentErrorCategory` (WP-2B2); WP-2C adds the functions it defines, again by editing this list; WP-2D2 adds `Invoke-HarnessGenerate` and `Test-HarnessModelAvailable`, relocated from `config.ps1` | FR-201; the same kind of edit WP-2B1 made |
| `scripts/test-agent-prompts.ps1`, "NFR-203 static scan: no HTTP route, ..." (the literal list, line 156) | replaces `System.Net` with `System.Net.WebClient`, `System.Net.WebRequest`, `TcpClient` (WP-2B2), because FR-211 names `System.Net.Sockets.SocketException`; WP-2C edits the list again for the single `Invoke-RestMethod` inside `Invoke-OllamaHttp` | NFR-203, FR-211 |
| `scripts/test-agent-prompts.ps1`, "NFR-203 static scan: no HTTP route, ..." (WP-2D2, the forbidden-command check) | exempts `Write-Host` only inside the function `Test-HarnessModelAvailable` (the owning `FunctionDefinitionAst` is found); every other function and every other command stays forbidden | FR-202 (the wrapper prints the legacy lines), NFR-203 |
| `scripts/test-agent-telemetry-v2.ps1`, "FR-216 static: telemetry.ps1 parses, defines only Write-HarnessModelTelemetry, and keeps the five mandatory parameters first and in order", assertion `parameter count` (WP-2C fix round, D1) | expects 23 instead of 22 (the optional `-CallId`); merged, see D-210 | FR-216 |
| `scripts/test-agent-exec.ps1`, "AC-213 Invoke-OllamaHttp generate: ..." (WP-2C fix round, D2) | the `httpStatus` assertion expects `$null` instead of 200 | FR-204, FR-216 |

The last five rows concern Phase 2 suites (`test-agent-prompts.ps1`, created in WP-2A; `test-agent-telemetry-v2.ps1`, WP-2B2; `test-agent-exec.ps1`, WP-2C), not a Phase 0 or Phase 1 suite; they are listed here so that every edit of an existing assertion has one home. The Phase 1 spec gets a note in its header and in FR-108 and AC-109 that they are superseded by FR-214 and AC-210 (WP-2D2). No other assertion of a baseline suite is edited. To catch an omission mechanically, WP-2D1 and WP-2D2 each run the affected suites before and after their edits and list every assertion whose result changed; each list must equal the rows of this table assigned to that package: WP-2D1, the two `think member` rows of `run-agent`; WP-2D2, the `review-spec` `think` row, the AC-014, AC-015 and AC-030 rows, and the two `test-agent-prompts.ps1` rows of WP-2D2 (the pinned list and the scan exemption). The 14 -> 31 row and the earlier `test-agent-prompts.ps1` rows were assigned to WP-2B2 and WP-2C and are already in place.

### AC-219 — Only the expected files change; no prompt changes

**Source:** USER

Verifies: NFR-206, FR-203.

`git diff --stat phase1-hardened` lists only files of "Affected Files". `.ai/agents/*`, `.ai/rules/*`, `AGENTS.md`, `specify.ps1`, `benchmark-models.ps1`, `validate-spec.ps1`, `scan-repository.ps1`, `build-context.ps1` and `test-all.ps1` (except the WP-2E table entry) are unmodified. A static scan of `agent-exec.ps1` and the three scripts finds no process-control cmdlet that targets Ollama.

### AC-220 — Streaming transport (only if WP-2G is built)

**Source:** USER

Verifies: FR-205.

Against the loopback fake server of WP-2S (`127.0.0.1`, OS-chosen port): the streaming transport assembles `response` and `thinking` from chunks and the final counts; a server that stalls after two chunks ends the call as `timeout` (detail `idle`) within `idleTimeoutSec` plus a stated tolerance; a steady trickle past `maxTotalSec` ends as `timeout` (detail `total`); a mid-stream disconnect is `transport_reset` and is retried by FR-212; a profile without `stream` sends `"stream": false` and uses the blocking transport; the telemetry `transport` column is `streaming`; the registry rules for the three fields hold. Not required for Phase 2 acceptance.

### AC-221 — Deferred prompt work follows its procedure

**Source:** USER

Verifies: FR-218.

Checked only if WP-2P is run: the prompt commit and the golden commit are separate; the golden commit touches only `tests/golden/`; the golden diff has an independent review recorded; the spec revision that authorizes the change contains its acceptance criteria. If WP-2P is not run, this criterion is not applicable and Phase 2 is still complete.

### AC-222 — The streaming spike decides FR-205

**Source:** USER

Verifies: FR-205.

WP-2S produces `docs/audits/<date>-phase2-streaming-spike.md` with a result (pass, fail or not measured) for each question S1 to S7 below, the three consecutive stable runs of the offline spike suite, the time spent against the time box, and one sentence: "implement FR-205" or "defer FR-205". The rule: implement only if S1, S2, S4 and S6 pass in all three runs; otherwise defer. If the time box ends with an open question, the answer is defer. The report states that S8 (live first-byte timing) is NOT VERIFIED until WP-2E. Phase 2 acceptance (Execution Order step 5) does not depend on this criterion at all: not on its outcome and not on the report existing, because the spike is step 6, independent of steps 1 to 5 and not run yet; until the report exists, this criterion is not checked (as AC-205, AC-220 and AC-221).

**Spike questions.** S1: lines are read incrementally (the first line is seen while the server is still sending). S2: an idle timeout fires within a stated tolerance when the server stops sending. S3: a maximum total time is enforced between lines. S4: aborting releases the connection (the server sees it close). S5: a multi-byte UTF-8 character split across chunks is decoded correctly. S6: a mid-stream disconnect raises an exception distinguishable by type or status. S7: no case can hang the suite (hard watchdog of 60 s per case). S8 (live): when the first byte arrives relative to prompt processing, which fixes the header timeout.

## Traceability Matrix

This table is the inverse of the `Verifies:` lines above. The two must stay identical.

| Requirement | Acceptance criteria |
|---|---|
| FR-201 | AC-216 |
| FR-202 | AC-201, AC-202, AC-203, AC-216 |
| FR-203 | AC-201, AC-219 |
| FR-204 | AC-213 |
| FR-205 | AC-220, AC-222 |
| FR-206 | AC-212 |
| FR-207 | AC-209, AC-210, AC-212 |
| FR-208 | AC-201 |
| FR-209 | AC-203, AC-205, AC-206 |
| FR-210 | AC-202, AC-205, AC-211, AC-213 |
| FR-211 | AC-202, AC-207, AC-208, AC-211 |
| FR-212 | AC-202, AC-208 |
| FR-213 | AC-205, AC-209 |
| FR-214 | AC-210, AC-218 |
| FR-215 | AC-214, AC-218 |
| FR-216 | AC-202, AC-203, AC-204, AC-214, AC-218 |
| FR-217 | AC-215 |
| FR-218 | AC-221 |
| NFR-201 | AC-217 |
| NFR-202 | AC-207, AC-214 |
| NFR-203 | AC-217 |
| NFR-204 | AC-217 |
| NFR-205 | AC-201, AC-202, AC-204, AC-210, AC-215, AC-216, AC-217, AC-218 |
| NFR-206 | AC-218, AC-219 |


## Affected Files

| File | Change | Requirements |
|---|---|---|
| `scripts/lib/agent-exec.ps1` (new) | The library of FR-201. | FR-201 to FR-216 |
| `scripts/lib/config.ps1` (modified) | The registry fields, validation and defaults of FR-217 (including known-key lists); `Invoke-HarnessGenerate` and `Test-HarnessModelAvailable` removed here and relocated. | FR-202, FR-217 |
| `scripts/lib/telemetry.ps1` (modified, WP-2B2; WP-2C fix round) | The v2 writer and the CSV rule; the optional `-CallId` (additive, D1), so that `meta.callId` equals `call_id`, with the one suite assertion in AC-218 (D-210; merged). | FR-216, AC-218 |
| `scripts/run-agent.ps1`, `review-spec.ps1`, `revise-spec.ps1` (modified) | Use the library; prompts come from the builders. | FR-202, FR-203 |
| `.ai/config.json` (modified) | WP-2D2, last commit, with approval: the added fields of FR-217 only. | FR-217 |
| `scripts/test-agent-prompts.ps1` (new, WP-2A; modified in WP-2B1, WP-2B2 and WP-2C) | Goldens, pass-through, mutation oracle. Later packages edit only the pinned function list and the NFR-203 scan list (AC-218). | AC-201 (builder part), AC-218 |
| `scripts/test-agent-budget.ps1`, `test-agent-errors.ps1`, `test-agent-telemetry-v2.ps1`, `test-registry-engine.ps1` (new, WP-2B1: budget and registry; WP-2B2: errors and telemetry) | Budget arithmetic; classification and hints; telemetry v2 and CSV rule; registry additions. | AC-204, AC-206, AC-207, AC-214 (fields), AC-215 |
| `scripts/test-agent-exec.ps1` (new, WP-2C) | `Invoke-AgentModel` with a fake transport: retries, warm-up, `think`, whitelist, interpretation, no-throw, overhead. | AC-208 to AC-213, AC-217 (NFR-201) |
| `scripts/test-engine-callsites.ps1` (new, WP-2D1 and WP-2D2) | Child-process, four guards: script goldens, failure matrix, budget, interfaces. | AC-201 (script part), AC-202, AC-203, AC-213, AC-214, AC-216 |
| `scripts/test-engine-live.ps1` (new, WP-2E) and one `test-all.ps1` table entry | Live AC-205 (`Requires` ollama, `ModelAgent`). | AC-205 |
| `scripts/spike-streaming-check.ps1`, `scripts/spike-streaming.ps1` (new, WP-2S) | Loopback fake NDJSON server and the spike code, not wired to production. The check script is not named `test-*.ps1`, so `test-all.ps1` does not discover it; it is renamed `test-streaming-spike.ps1` only in the commit that records three stable runs (OQ-210). | AC-222 |
| `scripts/test-agent-streaming.ps1` (new, WP-2G, conditional) | Streaming transport. | AC-220 |
| `scripts/test-agent-telemetry.ps1`, `scripts/test-registry-callsites.ps1` (modified; the 14 -> 31 row in WP-2B2, the others in WP-2D1 and WP-2D2) | Only the assertions of AC-218. | AC-218 |
| `tests/mocks/fake-transport.ps1`, `tests/mocks/fake-web-response.ps1` (new) | In-process fakes. | AC-207, AC-208 to AC-213 |
| `tests/golden/.gitattributes` (new, WP-2A; content `* -text`) | Keeps golden and fixture bytes unchanged under `core.autocrlf=true`. | AC-201 |
| `tests/golden/*` (new, WP-2A) | Fixture inputs and the golden system and user prompts (about 8 system goldens: run-agent with and without context, reviewer and reviser in 3 modes; the constant user prompts). | AC-201 |
| `tests/fixtures/config-v2-engine-*.json`, `config-v2-phase1-baseline.json` (new) | One fixture per FR-217 rule; the frozen baseline. | AC-215 |
| `specs/harness-phase-1-config-registry.md` (modified, WP-2D2) | Note: FR-108 and AC-109 superseded. | AC-218 |
| `scripts/test-shipped-config.ps1` (new, WP-2D2) | The shipped `.ai/config.json` against the frozen Phase 1 baseline: exactly the added values of FR-217, and the unchanged agent fields. | AC-215, AC-219 |
| `specs/harness-phase-2-shared-engine.md` (new) | This specification and its revisions. | - |
| `docs/audits/*` (new) | One report per work package, the independent reviews and the final QA. | - |

`docs/roadmap/modernization-roadmap.md` is not modified (it was listed here before revision 3.4; the diff against `phase1-hardened` does not contain it).

**Not modified:** `specify.ps1`, `validate-spec.ps1`, `scan-repository.ps1`, `build-context.ps1`, `benchmark-models.ps1`, `test-all.ps1` (WP-2E excepted), `.ai/agents/*`, `.ai/rules/*`, `AGENTS.md`, `README.md`, and every other suite, mock and fixture.

## Test Strategy

- **New suites** (all discovered by `test-all.ps1`, offline, no mandatory parameters, explicit `exit`): `test-agent-prompts.ps1`, `test-agent-budget.ps1`, `test-agent-errors.ps1`, `test-agent-telemetry-v2.ps1`, `test-registry-engine.ps1`, `test-agent-exec.ps1`, `test-engine-callsites.ps1`; the spike check `spike-streaming-check.ps1` (loopback only, not discovered by `test-all.ps1` until it is stable and renamed); conditional `test-agent-streaming.ps1`; the live `test-engine-live.ps1` (skipped without `-IncludeLive`).
- **Four guards** for every child-process suite, as in `test-registry-callsites.ps1`: the temporary config must name `http://127.0.0.1:9` (proved at startup against a missing file, bad JSON, `http://localhost:11434` and another URL); the fake host exits 97 unless `Invoke-RestMethod` resolves to the fake; the fake refuses any URI outside `http://127.0.0.1:9/`; a static scan refuses to start if the copied scripts hold another HTTP route (the scan list also gains `System.Net.WebRequest`, `TcpClient`, `Net.WebClient` and `Start-BitsTransfer`, Phase 1 QA F-12; see the next sentence for streaming). The baseline suites copy every `scripts\lib\*.ps1` and stop at startup if the text `HttpWebRequest` appears in a copied script (`test-registry-callsites.ps1:277-291`, `test-agent-telemetry.ps1:275`). WP-2G therefore adds `scripts/lib/agent-stream.ps1` and, in the same commit, a listed AC-218 row that exempts exactly that file name from the `HttpWebRequest` literal in guard 4 of both suites while still scanning it for every other route; no other change to the guards.
- **In-process suites** use the injected fake, a violating stub for `Invoke-OllamaHttp`, and the static scan of NFR-203; they never run a script from the repository.
- **Mutation proof** for each key rule named in the acceptance criteria (budget rounding and comparison, the 5xx boundary, the retryable set and attempt count, `think` false versus omitted, the empty and `length` rule, the CSV rule, one record per call, the golden normalization and pass-through): a temporary edit of a copy or of the file with a hash-checked revert, recorded in the work package report. At least the golden comparison and the classification table are also protected by in-suite oracle checks that fail on a planted difference.
- **Tripwire and sandbox.** Suites write only under `TEMP`; suites that copy `scripts\` and `tests\` are run with `Isolation = "sandbox"` where the table needs it; the repository tripwire stays clean. No assertion reads localized text.
- **Live entries.** `ModelAgent` entries and the live contract are unchanged; the new live suite uses `ModelAgent` too.

## Execution Order

One work package per unattended Claude Code session, one or a few commits each. After each package: run `scripts/test-all.ps1` offline twice, record counts, run the mutation proofs named in its acceptance criteria (temporary edit, hash-checked revert, as in the Phase 1 hardening report), write `docs/audits/<date>-phase2-<wp>.md`, then **stop for an independent review and human approval** before the next package. Local model output is never verification; no package pushes anything.

| Step | Work package | Depends on | Exit check |
|---|---|---|---|
| 0 | Record the baseline: offline `test-all` at `phase1-hardened`; freeze `config-v2-phase1-baseline.json`. Decide OQ-201 to OQ-204 and OQ-208 (they block WP-2B to WP-2D). | Spec approved | Baseline recorded |
| 1 | **WP-2A Golden prompts and builders.** Capture goldens from the unmodified scripts; `New-AgentPromptPart`, `New-AgentPrompt` and the three builders in a first version of `agent-exec.ps1`; `test-agent-prompts.ps1`. Scripts untouched. | Step 0 | AC-201 (builder part) |
| 2a | **WP-2B1 Registry and budget.** Registry fields and fixtures; `Test-AgentContextBudget`; `Get-AgentRetryDelaySec`; suites `test-agent-budget.ps1` and `test-registry-engine.ps1`. No script change. | WP-2A | AC-206, AC-215 |
| 2b | **WP-2B2 Errors and telemetry.** `tests/mocks/fake-web-response.ps1` first (compile proof, RK-205); `Get-AgentErrorCategory` with hints; the telemetry v2 writer and CSV rule; the fake transport; suites `test-agent-errors.ps1` and `test-agent-telemetry-v2.ps1`. `telemetry.ps1` is modified (the 31-column header); no `run-agent.ps1`, `review-spec.ps1` or `revise-spec.ps1` change. Carries three one-line suite edits of AC-218: the pinned function list and the scan list of `test-agent-prompts.ps1`, and the 14 -> 31 assertion of `test-agent-telemetry.ps1` (owner decision A). | WP-2B1 | AC-204, AC-207, AC-214 (fields) |
| 3 | **WP-2C `Invoke-AgentModel`.** `Invoke-OllamaHttp`, `Test-OllamaModel`, `Invoke-AgentModel` (retries, warm-up, `think`, interpretation, telemetry call) and `test-agent-exec.ps1`. No script change. Extends the pinned function list and the NFR-203 scan list of `test-agent-prompts.ps1` again (one `Invoke-RestMethod`, inside `Invoke-OllamaHttp`; AC-218). | WP-2B2 | AC-208 to AC-213, AC-217 (NFR-201) |
| 4a | **WP-2D1 Migrate `run-agent.ps1`.** `run-agent.ps1`, the new engine fake host and the run-agent part of `test-engine-callsites.ps1`; the AC-218 edits that concern `run-agent`. The relocation of the two wrappers moved to WP-2D2, because `review-spec.ps1` and `revise-spec.ps1` still called them. | WP-2C | AC-201, AC-202, AC-203 (run-agent part) |
| 4b | **WP-2D2 Migrate the reviewer and reviser.** `review-spec.ps1` and `revise-spec.ps1`; the relocation of `Invoke-HarnessGenerate` and `Test-HarnessModelAvailable` to `agent-exec.ps1` once neither script calls them; the rest of `test-engine-callsites.ps1`; the other AC-218 edits (not the 14 -> 31 edit, which WP-2B2 made), including the two `test-agent-prompts.ps1` rows of this package; the Phase 1 spec note; then, as the last commit and after approval, the `.ai/config.json` update. | WP-2D1 | AC-201 (script part), AC-202, AC-203, AC-213, AC-214, AC-216 to AC-219 |
| 5 | Phase 2 final QA, independent review and human approval. | WP-2D2 | All ACs except AC-205, AC-220 to AC-222 |
| 6 | **WP-2S Streaming spike** (time box: one session). Independent of 2A to 2D; may run in parallel. | none | AC-222 (report) |
| 7 | **WP-2G Streaming transport**, only if WP-2S says implement. | WP-2D2, WP-2S | AC-220 |
| 8 | **WP-2E Live check**, when Ollama is available: AC-205, calibrate `charsPerToken`, decide `budgetMode` and the context windows, warm-up experiment, S8. Updates `.ai/config.json` only with approval. **Precondition (DF-201):** benchmark rows with `attempts` above 1 are ignored, or `ollama.maxAttempts` is 1 for the run. | WP-2D2 | AC-205 report |
| 9 | **WP-2P Prompt work**, optional and deferred, after WP-2D2 (preferably after WP-2E), with its own spec revision. | WP-2D2 | AC-221 |

## Deferred Items

Recorded by the owner's decisions on the final QA (`docs/audits/2026-11-26-phase2-final-qa.md`). None changes a requirement of Phase 2, and none is built in this phase.

| ID | Item | Where it is handled |
|---|---|---|
| DF-201 (QA I-5) | `benchmark-models.ps1` reads `duration_ms` and counts exit 0 as success. A call that was retried now exits 0 with a `duration_ms` that covers the failed attempt and the wait (observed: 1,218 ms with `attempts` 2 against 160 ms with `attempts` 1; with the shipped backoff the wait alone is 5 s), whereas the baseline recorded such a run as an error. **Precondition for WP-2E:** benchmark numbers are not used unless rows with `attempts` above 1 are ignored, or the benchmark runs with `ollama.maxAttempts` 1. No code change in this phase (`benchmark-models.ps1` is not modified). | WP-2E |
| DF-202 (QA I-6) | Overlapping processes lose telemetry records: 40 writes per process, 2 processes gave 1 to 14 of 80 and 4 processes 6 to 8 of 160 (the baseline writer was equally bad, so this is no regression; the loss is a warning). "Exactly one record per call" (FR-216) holds only without overlap. Fix: a bounded retry on a sharing violation or a named mutex in the writer. | Phase 3 (background runs) |
| DF-203 (QA section 9) | The deprecated wrappers `Invoke-HarnessGenerate` and `Test-HarnessModelAvailable` stay through WP-2E; nothing calls them. Delete them in Phase 3 together with their 8 suite cases and the scan exemption (the `Write-Host` exemption of `Test-HarnessModelAvailable`, AC-218). | Phase 3 |

## Edge Cases

- **v1 configuration.** No `contextWindow` or `reservedOutputTokens`, so the budget is `skipped`; retries and the registry defaults apply; `think` is omitted.
- **`think` true on a model that does not support it.** Ollama's refusal is `http_4xx`; the user changes the profile (FR-214).
- **`maxAttempts` 1.** Behaves like the baseline, apart from the categories and telemetry.
- **A long failed attempt.** A connection reset after most of `timeoutSec` is retried and can take as long again (RK-203).
- **200 with an `error` member.** No `response` member, so `empty_response`; the `error` text, if any, is the `detail`.
- **Empty `thinking` and a non-empty `response`.** `thinking_chars` 0, success.
- **`stripThinking` false.** `<think>` blocks stay in the text; `thinking_chars` counts only the `thinking` field.
- **`options.num_predict` smaller than `reservedOutputTokens`.** Not checked (FR-206).
- **Mixed line endings in input files.** Passed through unchanged (FR-203).
- **Two profiles with one model.** Unchanged from Phase 1 (OD-109).
- **Telemetry write failure.** A warning, never a failed call (FR-216).
- **Cached `/api/tags`.** Per script invocation (D3); a model pulled after the first check is not seen until the next script invocation.
- **Reviewer `-ResponseCheck` and retry.** A format failure is not retried (FR-211).

## Dependencies

- Phase 1 complete (tag `phase1-hardened`). The engine consumes `contextWindow`, `reservedOutputTokens`, `safetyMarginRatio`, `think`, `timeoutSec` and `ollama.healthTimeoutSec`.
- Runtime: Windows PowerShell 5.1; no Ollama or network for any acceptance criterion except AC-205 (live) and the loopback spike suites.
- Test infrastructure: the `test-all.ps1` suite contract, sandbox and tripwire; the fake host and four guards of `test-agent-telemetry.ps1` and `test-registry-callsites.ps1`.
- Phase 3 (unified CLI) will consume `Invoke-AgentModel`, the telemetry v2 and the budget breakdown; nothing of Phase 3 is built here.

## Risks and Rollback

| ID | Risk | Mitigation |
|---|---|---|
| RK-201 | Enforcing the budget blocks calls that work today (see Context). | The default is `warn` and the shipped configuration never sets `enforce` before WP-2E (OQ-201); the enforcement itself is tested with fixtures that set it explicitly. |
| RK-202 | A prompt changes silently while code moves (roadmap R-04). | Goldens (FR-203), captured from the legacy scripts before any change; mutation proofs. |
| RK-203 | Retries multiply the worst-case time: `maxAttempts x timeoutSec` plus waits, per attempt until the response headers arrive; `timeoutSec` does not bound a response body (FR-204, D4), which is bounded only by the 300 s silence timeout of .NET, so a body that keeps trickling has no bound. Shipped values: 2 x 900 + 5 = 1,805 s per call (900 s today), headers phase only; 3,610 s with warm-up; `specify.ps1` (8 calls at most) 14,440 s against 7,200 s; registry maximum (5 attempts of 14,400 s, four waits of 60 s) 72,240 s, 144,480 s with warm-up (the earlier figure 72,075 s assumed a backoff of 5 s). The table below has the cases. | Default 2 attempts; `timeout` is never retried (so these cases need a 5xx or a reset just before the limit); `maxAttempts` 1 disables it; a retry prints one line (FR-212); documented here (arithmetic of the review, not observed). The `healthTimeoutSec` of `Test-OllamaModel` is extra. |
| RK-204 | A persistent GPU or server fault is not fixed by retries (roadmap R-02). | A clear category, attempts and hint; the exit code is unchanged; restart is the user's action (FR-212). |
| RK-205 | The fake `WebResponse` subclass does not compile or behave as assumed in PS 5.1. | WP-2B2 step 1 proves it; the fallback is the normalized failure record alone (the mapping of an exception to a record is then checked by inspection). |
| RK-206 | Telemetry readers break on the new columns. | Old file untouched; new rows go to a new CSV; JSONL keys are only appended. |
| RK-207 | Superseding Phase 0 and Phase 1 assertions hides a real regression. | Exactly the AC-218 list, verified by the diff of the suites. |
| RK-208 | A loopback listener in the spike suite is flaky or leaves a process behind. | OS-chosen port, `127.0.0.1` only, watchdog per case, the server process killed in `finally`, three stable runs required. |
| RK-209 | `charsPerToken` stays wrong, so the budget is wrong. | Telemetry records `prompt_chars` and `prompt_eval_count`; calibration in WP-2E. |

**RK-203, worst-case wall time of one call (D4; arithmetic of the WP-2C review, not observed).** `timeoutSec` 900, `maxAttempts` 2, `retryBackoffSec` 5 unless stated:

| Case | Seconds |
|---|---|
| Headers phase only, no warm-up: 2 x 900 + 5 | 1,805 |
| With warm-up, both phases retried | 3,610 |
| Adding one silent body gap of 300 s per attempt | 2,405 (4,810 with warm-up) |
| A body that keeps trickling | no bound |
| Registry maximum: 5 x 14,400 + 4 waits of 60 | 72,240 (144,480 with warm-up) |

**Rollback.** Each work package is one or a few commits, reverted with `git revert` in reverse order (WP-2D first, including the `.ai/config.json` commit, which alone returns the registry to its Phase 1 state; then WP-2C, WP-2B, WP-2A). Because the scripts keep their interfaces, rolling back means reverting the library and the three scripts together. Logs are never rewritten, so v2 JSONL lines and `model-calls.v2.csv` stay as harmless extra data.

## Decisions Recorded

| ID | Decision (source: the task of 2026-11-22 that commissioned this spec) | Effect |
|---|---|---|
| D-201 | `think` is sent only when the profile sets it explicitly; `"default"` omits it; Phase 1 AC-109 is superseded explicitly. | FR-214, AC-210, AC-218 |
| D-202 | Streaming is optional, off by default, per profile, and gated by a time-boxed spike that does not condition Phase 2 acceptance. | FR-205, AC-220, AC-222 |
| D-203 | Prompt work is a separate, deferred, optional package after the engine, with its own golden update procedure; no prompt changes in this implementation. | FR-218, AC-221 |
| D-204 | New registry fields are minimal, validated with `registry_invalid:`, v1 and v2 compatible. | FR-217, AC-215 |
| D-205 | Retries on HTTP 5xx and connection reset, bounded, values in the registry; errors classified by status or type, never by message text. | FR-211, FR-212 |
| D-206 | Prompts byte-identical, with a stated line-ending rule. | FR-203 |
| D-207 | CSV rule: old header present -> v2 rows go to `model-calls.v2.csv`, old file unchanged. | FR-216, AC-204 |
| D-208 | The three scripts keep parameters, exit codes, console markers and output files; `Invoke-HarnessGenerate` stays as a deprecated wrapper; `ModelAgent` live entries are unchanged. | FR-202, NFR-205 |
| D-209 | The owner accepts all recommendations of OQ-201 to OQ-214 as written (2026-11-22): `budgetMode` default `warn`; 2 attempts and 5 s; warm-up off; builders emit CRLF template separators (OQ-211); finer category names with the mapping table (OQ-212); the author-chosen specifics of OQ-213; `failure.message` for display only (OQ-214). | OQ-201 to OQ-214 |
| D-210 | The owner decides the open points of the WP-2C independent review (2026-11-23, given in the fix-round task; revision 3.2): D1 the writer gets an optional `-CallId` (default a new GUID, never the run id) and the engine passes `meta.callId`; D2 `http_status` is empty on a success (not measured); D3 the caches are "per script invocation" (the wording is fixed, not the code); D4 `TimeoutSec` does not bound a response body (RK-203, A-201, FR-204 corrected, with the worst-case table); D5 an unclosed `<think>` cut by `length` stays as is, a known limit; D6 `model_called` true means "a request was attempted". **D1 status (revision 3.3):** merged (the `-CallId` edit and the one assertion edit of `test-agent-telemetry-v2.ps1` listed in AC-218, `parameter count` 22 to 23, are on `master`), so `meta.callId` equals the `call_id` of the record. | FR-204, FR-210, FR-213, FR-215, FR-216, RK-203, A-201, AC-218 |

## Open Questions

Each has a RECOMMENDATION. Work packages that a question blocks are noted. **Decision (owner, 2026-11-22, given in the working session): every RECOMMENDATION below is accepted as written (D-209).** The text is kept as the record of what was accepted.

- **OQ-201 (blocks WP-2B1 and WP-2D2): budget default and the shipped mode.** With the shipped profiles, enforcement would refuse the reviewer and reviser (Context table). RECOMMENDATION: implement enforcement, with default `warn` when the key is absent and no `budgetMode` key in the shipped file, and `charsPerToken` 3.5 (a v2 file without the key must keep working, Phase 1 NFR-103); calibrate in WP-2E, then decide between flipping to `enforce` with a measured ratio and raising the `deep` and `review` context windows (a hardware decision: Phase 1 OD-111 kept 16384 on 12 GiB of VRAM). This deviates from the roadmap's [M] immediate enforcement.
- **OQ-202: log failures before the model is reached.** XR-05 asks for records with `model_called` false; Phase 0 OD-04 said telemetry only for requests sent. RECOMMENDATION: yes, as FR-215 and FR-216, with the AC-218 test changes.
- **OQ-203: retry defaults and v1.** RECOMMENDATION: `maxAttempts` 2 and `retryBackoffSec` 5, applied also to v1 configurations (failure paths only). The roadmap lists "automatic retry with backoff" as [O]; this spec makes it part of Phase 2 because the task asks for it.
- **OQ-204: warm-up default.** RECOMMENDATION: off; decide after WP-2E.
- **OQ-205: telemetry fields not included.** `workflow_id`, `workflow`, `stage`, `task_sha256`, `output_path`, `target_root` need Phase 3 concepts or the undecided O-14. RECOMMENDATION: defer them to Phase 3.
- **OQ-206: the `error` column.** RECOMMENDATION: `<category>: <detail>`, never the localized exception message (handoff item 6).
- **OQ-207: added output lines.** `Category:` and `Hint:` lines on failure only, plus one line per retry (FR-212) and one `Warning: budget_exceeded` line in `warn` mode (FR-209). RECOMMENDATION: accept (additive, no existing line changes).
- **OQ-208: line endings of the live prompt.** The live prompt mixes CRLF and LF because agent files do. RECOMMENDATION: pass through unchanged in Phase 2 (keeps byte identity with today); consider LF canonicalization inside WP-2P with its own golden update.
- **OQ-211 (blocks WP-2A): line endings of the builders' template text.** Added by the independent review of 2026-11-22. The legacy templates are CRLF on a standard checkout; a new library file may be LF. RECOMMENDATION: the builders build their template lines with an explicit constant separator and use CRLF, so the live prompt differs from today's only where an input segment's own endings differ. Record the deviation from the roadmap's "byte-identical" (FR-203 rule 5).
- **OQ-212: category vocabulary.** Added by the review. The roadmap's Phase 3 manifest lists `ollama_unreachable`, `http_error`, `empty_output`, `invalid_output_format`; this spec uses finer names. RECOMMENDATION: keep the finer names in telemetry and keep the mapping table of FR-211 so Phase 3 cannot drift.
- **OQ-213: choices made by the spec author, not by the owner.** Added by the review. They are labelled `USER` only because the surrounding requirement is: the retryable set and the exponential growth with a 60 s cap (FR-211, FR-212), the category names, the `charsPerToken` range above 0 and at most 10, the 17 telemetry column names and their order, the `idleTimeoutSec` default of 120 and the spike rule (S1, S2, S4, S6 in three stable runs). RECOMMENDATION: accept them as written after the owner has seen them in one place; otherwise change them before WP-2B1.
- **OQ-214: console message of a failed call.** Added by the review. FR-204 forbids the transport to return `Exception.Message`, so the localized message line of the legacy `=== OLLAMA ERROR ===` blocks disappears. RECOMMENDATION: the transport may carry a `failure.message` used only for printing in that block, never for a decision, a category or the telemetry; the static scan of AC-207 enforces it. If the owner prefers to drop the line, NFR-205 already lists it as an intentional change.
- **OQ-209: profile `think` values.** The engine only provides the mechanism. Phase 1 FR-101 notes `false` as the intended later value for the reviser, but the 2026-11-19 validation found `think: false` worse for specs. RECOMMENDATION: change no value until WP-2E or a quality evaluation supports it.
- **OQ-210 (platform gate and spike scheduling).** The roadmap's gate (stay on PowerShell 5.1, or move to 7 or Python) is still marked open and names the streaming spike as its test. RECOMMENDATION: assume PowerShell 5.1 for Phase 2 (the baseline), run WP-2S in parallel, and let its report inform the gate; allow the loopback spike suite in the default offline run only if it is stable in three consecutive runs.

## Assumptions

- **A-201:** In Windows PowerShell 5.1, `Invoke-RestMethod` reports transport and HTTP errors as `System.Net.WebException` with `Status` and, for HTTP errors, a `Response` with `StatusCode`; other exception types come only from fakes or bugs. To confirm in WP-2B (AC-207). **Result of the WP-2C review (real cmdlet against a loopback listener):** confirmed for HTTP and connection errors; refuted in part: a connection closed or reset in the middle of the body raises a plain `System.IO.IOException` (not a `WebException`), which FR-211 and A-206 already classify as `transport_reset`. Also `TimeoutSec` does not bound a response body: a body is bounded only by the 300 s silence timeout of .NET, which ends as `timeout` (D4, FR-204, RK-203).
- **A-202:** A `WebResponse` subclass compiled with `Add-Type` can be given to a `WebException` and read by the default transport (RK-205).
- **A-203:** Sending a request without a `prompt` loads the model without generating it (documented Ollama behavior; not verified on 0.40.13).
- **A-204:** Ollama trims a prompt that overflows `num_ctx` instead of failing (XR-03; verified in WP-2E).
- **A-205:** `think: true` or `false` is accepted by the models in use and `think` on an unsupporting model gives an HTTP 4xx (UNVERIFIED; the engine does not depend on it).
- **A-206:** A `System.IO.IOException` or `SocketException` reaching the engine means a dropped connection (`transport_reset`).
- **A-207:** The template text of the three scripts is 280 characters for `run-agent.ps1` (plus 56 for the context wrapper), 701 for the reviewer and 2,684 for the reviser (measured by the independent review with the PowerShell parser; the file sizes in the Context table are measured too).
- **A-208:** A loopback `System.Net.Sockets.TcpListener` in a child `powershell.exe` can serve a chunked NDJSON response without administrator rights (WP-2S).

## Not Verified

- Every live behavior: real model calls, the budget numbers against real `prompt_eval_count`, Ollama's overflow behavior, warm-up, `think` acceptance, the intermittent GPU error and whether a retry clears it.
- That the Context-table figures reflect what Ollama counts (they use the 3.5 default and the 5.3 handoff sample).
- Whether streaming works on PowerShell 5.1 (WP-2S) and when the first byte arrives (S8).
- That a `WebResponse` subclass works as a fake (RK-205).
- Nothing in this document has been implemented or run; only `scripts/validate-spec.ps1` was run on it.
