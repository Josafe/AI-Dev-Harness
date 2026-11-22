# Phase 2 spec notes

**Date:** 2026-11-22
**Branch:** `docs/phase2-spec`, from `master` at `ba33bb4` (tag `phase1-hardened`). Local commits only; nothing was pushed.
**Deliverable:** `specs/harness-phase-2-shared-engine.md` (Draft, revision 1). `scripts\validate-spec.ps1` gives `STATUS: PASS`. A script check found 46 unique IDs, a `Verifies:` line on every AC, and a traceability matrix that matches those lines exactly.
**Not done:** no code, no test run, no Ollama call, no live test, no change to any prompt or to `.ai/config.json`. The spec is not approved.

## 1. Findings that shaped the spec (FACT, measured 2026-11-22)

1. **The shipped budget would block the reviewer and reviser.** With the migrated `.ai/config.json` (`contextWindow` 16384, `reservedOutputTokens` 8192 for `deep` and `review`, ratio 0.10, so `C - R - S` = 6,553 tokens) and the XR-03 default of 3.5 chars/token, the fixed text alone is about 7.4k tokens for the reviewer and about 7.0k for the reviser, before the task, spec or review. At the measured 5.3 chars/token (2 samples in the handoff) the reviewer has about 1.7k tokens left for the whole specification. Enforcing XR-03 as written would refuse calls that work today. The spec adds `defaults.budgetMode` and recommends shipping `warn` (OQ-201). The template sizes in that table are estimates; the file sizes are measured.
2. **The live prompt has mixed line endings.** `.ai/agents/spec.md` has 379 CRLF and 411 LF line ends on disk, `spec-reviser.md` 195 and 430, `developer.md` only LF (`git ls-files --eol` shows `i/lf w/mixed`). So the prompt sent today is not uniform, and the roadmap's EOL note is only part of the story. The golden rule in FR-203 normalizes CRLF to LF on both sides for comparison and requires the builders to pass inputs through untouched, which keeps today's live bytes.
3. **Existing tests encode decisions this phase supersedes.** `test-agent-telemetry.ps1` asserts zero telemetry for a missing model, an unreachable server and the config-deleted case (Phase 0 OD-04), and a 14-column CSV header; `test-registry-callsites.ps1` asserts the `think` member is absent even for a profile with `think: true` (Phase 1 AC-109). AC-218 lists exactly these edits.
4. **Existing fakes throw plain exceptions.** The Phase 0 and Phase 1 fake hosts throw a `RuntimeException` for a failed request, so those cases classify as `transport_other` and are not retried; the old suites keep passing without sleeping.
5. **The spec is large:** about 69 KB, twice Phase 1's size, so the local reviewer's 16k context (R-09) cannot review it. It needs a review by Claude or a human, or a split.

## 2. Deviations from the roadmap Phase 2 text, and why

| # | Roadmap | This spec | Why |
|---|---|---|---|
| 1 | XR-03 [M]: budget enforced | Enforcement implemented and tested, key `budgetMode`; shipped config recommended as `warn` | Finding 1 |
| 2 | Retry with backoff is `[O]` in the scope table | Mandatory in Phase 2 (FR-212) | The task asks for it |
| 3 | XR-05 lists 17 new fields (`workflow_id`, `workflow`, `stage`, `task_sha256`, `output_path`, `target_root`, ...) | 17 new columns, but without those six | They need Phase 3 concepts or the open O-14 (OQ-205) |
| 4 | XR-05: log failures before the model (budget, unavailable, unreachable) | Done (FR-215, FR-216) | Same as roadmap, but it supersedes Phase 0 OD-04 explicitly (OQ-202) |
| 5 | Telemetry `status` | An empty response or a format failure is `error`; the baseline `run-agent.ps1` logged `success` for an empty response | One honest status per call |
| 6 | `error` column | `<category>: <detail>`, never the localized exception message | Handoff item 6, NFR-202 (OQ-206) |
| 7 | FR-201 "labelled parts (instruction or data)", "context is always data" | Labels are metadata only; no byte of the prompt changes | FR-203 byte-identity; framing changes belong to WP-2P |
| 8 | FR-205 streaming, `transport` per profile | `stream`, `idleTimeoutSec`, `maxTotalSec` per profile, only if the spike passes; no `transport` key | O-10, D-202; smallest field set |
| 9 | FR-206 optional `num_predict` per profile | No new field: `options.num_predict` already flows through the registry | Minimal change |
| 10 | Phase 1 OD-107 moved `reasoning`, `transport`, `promptFile`, `defaults.charsPerToken`, `tests` to Phase 2 | Only `charsPerToken` is added (plus `budgetMode`, retry, warm-up keys). `reasoning` is not added: `R` is used whenever the profile has it | Not needed by any requirement; not raised as an open question, say if you want them |
| 11 | `Invoke-HarnessGenerate` "remains as a deprecated wrapper" | It stays, and is relocated from `config.ps1` to `agent-exec.ps1` with `Test-HarnessModelAvailable` | One home for the call code; no other script uses them |
| 12 | `Test-OllamaModel` with a cached `/api/tags` | As written; returns the real category, the scripts keep the legacy "not reachable" text | XR-01 |
| 13 | XR-03: context-file budgets `C - R - S - fixed` | Not implemented; only the per-section breakdown is reported | Context in every stage is Phase 3 |
| 14 | AC-201 to AC-205 | Kept with the same numbers and meaning; AC-206 to AC-222 added; FR-201 to FR-207 numbering kept, FR-208 to FR-218 added | Traceability to the roadmap |
| 15 | AC-202 "a review with no Status" | Implemented with a `-ResponseCheck` hook on `Invoke-AgentModel`, so the check stays in the reviewer and the failure still produces exactly one telemetry line | The record is written inside the call |
| 16 | The task's WP list put telemetry in WP-2D | The telemetry writer is in WP-2B | WP-2C must write the one record |
| 17 | Platform decision gate "before Phase 2" | Phase 2 assumes PowerShell 5.1; the spike report informs the gate; acceptance does not depend on it (OQ-210) | The task says the harness stays on 5.1 and acceptance is independent of the spike |
| 18 | `RECOMMENDATION` as a source label | The validator accepts only USER, PROJECT, FACT, ASSUMPTION, so RECOMMENDATION appears in the text and in Open Questions, not in `Source:` lines | `validate-spec.ps1` |

## 3. Assumptions in the spec (also in its Assumptions section)

- **A-201** `Invoke-RestMethod` in PS 5.1 raises `WebException` with `Status` and `Response.StatusCode`.
- **A-202** A `WebResponse` subclass compiled with `Add-Type` can serve as a fake HTTP response. If not, the fallback is testing only the normalized failure records (RK-205).
- **A-203** A request without `prompt` loads the model without generating (documented Ollama behavior; not verified on 0.40.13).
- **A-204** Ollama trims an overflowing prompt instead of failing.
- **A-205** `think: true|false` is accepted, and an unsupporting model gives an HTTP 4xx. The engine does not depend on it.
- **A-206** `IOException` or `SocketException` reaching the engine means a dropped connection.
- **A-207** The here-string template sizes are about 0.3 to 3 KB.
- **A-208** A loopback `TcpListener` in a child `powershell.exe` can serve a chunked response without administrator rights (spike).
- **Choices I made that are not in your text** (all listed as open decisions): the category names `transport_reset` and `model_not_installed`; retry defaults 2 attempts and 5 s base with a fixed cap of 60 s and exponential growth; no retry for `timeout`, `transport_unreachable`, `http_4xx`, `empty_response` and `format_invalid`; `charsPerToken` range 0 to 10; the 31-column header order; the idle default of 120 s; the spike decision rule (S1, S2, S4, S6 in three stable runs, otherwise defer).

## 4. Open decisions for the owner

Full text and recommendations are in the spec's "Open Questions".

| ID | Question | Recommendation | Blocks |
|---|---|---|---|
| OQ-201 | Budget default and shipped mode; contextWindow of `deep` and `review` | Ship `warn`, calibrate in WP-2E, then choose between `enforce` with a measured ratio and a larger window (hardware decision) | WP-2B, WP-2D |
| OQ-202 | Log failures before the model (supersedes Phase 0 OD-04) | Yes | WP-2D |
| OQ-203 | Retry defaults, applied to v1 too | 2 attempts, 5 s; yes | WP-2B |
| OQ-204 | Warm-up default | Off | WP-2B |
| OQ-205 | Telemetry fields deferred to Phase 3 | Defer | none |
| OQ-206 | `error` column content | Category plus detail | WP-2B |
| OQ-207 | New `Category:` and `Hint:` lines on failure | Accept | WP-2D |
| OQ-208 | Line endings of the live prompt | Pass through now; consider LF in WP-2P | WP-2A |
| OQ-209 | Any profile `think` value change | None until live evidence | none |
| OQ-210 | Platform gate, spike scheduling, loopback suite in default `test-all` | Stay on 5.1, run the spike in parallel, allow the suite only if stable | WP-2S |

## 5. Self-review

Checked: every FR and NFR has at least one AC; every AC has one `Verifies:` line; the matrix equals the inverse; AC-206 uses hand-computed literals; no AC asserts localized text; AC-203 and AC-202 name a number of calls and lines, not wording. Known weaknesses: the spec is long (finding 5); the Context table's template sizes are estimates; WP-2B holds four small suites and may need splitting if a session runs short; the AC-218 supersession table cites test names and assertions as read at `phase1-hardened`, so a line may have moved by the time WP-2D runs; the retry timing tests rely on an injected `-Sleep` and `retryBackoffSec` 0, so real sleeping is not exercised.

## 6. NOT VERIFIED

Everything live; the budget figures against real `prompt_eval_count`; the assumptions A-201 to A-208; that the spec's size fits any local reviewer; that all existing suites still pass after the supersessions (nothing was implemented or run, apart from `validate-spec.ps1` on the new spec).
