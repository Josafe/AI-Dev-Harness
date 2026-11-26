# Phase 3 context pack

Read this INSTEAD of the whole spec, plus only the spec sections your package names (table in 3). Spec: `specs/harness-phase-3-unified-cli.md` (draft rev 2, not approved; line ranges below are for the tree that contains this file; if they drift, grep the heading id, e.g. `### FR-311`). Where this pack says RECOMMENDATION or Open Question, the spec does too: it is not a requirement.

## 1. Goal and stages

One entry point `scripts/harness.ps1` over the existing scripts. Every workflow run gets a run directory `runs\<id>\` and a validated manifest and ends with a stable exit code (0 ok, 1 workflow failure, 2 error, 3 needs input, 4 unsupported stage). A run is a short foreground process that checkpoints its manifest; no daemon. Concurrent runs become safe. WP-2E findings become behavior. Legacy scripts keep their interfaces.

- **3A** (DONE, merged; gate fixes applied): A1 telemetry lock; A2 wrappers `Invoke-HarnessGenerate` and `Test-HarnessModelAvailable` deleted with their nine cases and driver; A3 `test-engine-callsites.ps1` split into three suites plus `tests/lib/engine-fake-host.ps1`; A4 engine signals (truncation, `model_load_failed`, `Test-OllamaModelLoad`).
- **Gate 3A:** offline `test-all` twice, report, owner approval, tag `phase3a-done`; the spec may be revised before 3B.
- **3B:** B1-B9, the CLI. Final QA (independent session) and tag `phase3-done` are the owner's.

## 2. Owner decisions (applied, not reopened)

- D-301 `-Resume` cut; a killed run is started again (FR-312, AC-318 unused).
- D-302 no `-Background`, `cancel`, `console.log`; XR-06, XR-03 budget, XR-04 policy deferred (FR-310, OQ-322).
- D-303 `develop` and the 4 other stages exit 4; legacy `specify.ps1` writes no manifest (FR-301, FR-308, AC-312).
- D-304 two stages, 3A and 3B, with a gate (Execution Order).
- D-305 names and overwrite policy (FR-319, AC-328).
- D-306 `-Include` is ONE comma-separated string (FR-313, AC-301, AC-320).
- D-307 target not the harness root, no reparse points (FR-302, FR-319, AC-301, AC-328).
- D-308 telemetry: named mutex plus `FileStream` append, no `Local\` fallback (FR-311c, FR-307, AC-317).
- D-309 run claim by `CreateDirectory` plus `.claim`; manifest by `File.Replace` (FR-304, FR-305, AC-308, AC-329).
- D-310 no stage-script options; `$args` parser; `Invoke-HarnessCli` is the test entry (FR-302, AC-301).
- D-311 stage contract and outcome table (FR-303, FR-308, AC-303, AC-311, AC-330).
- D-312 schema enums equal XR-08 (FR-305, FR-306, AC-307, AC-309).
- D-313 WP-2E findings are FR-316 to FR-318; model-switch policy only OQ-317 (AC-331 to AC-333).
- D-314 kept: telemetry join by `run_id` and `call_id`, no new columns; wrappers deleted in 3A; suite split by script (FR-307, FR-314, FR-315).

## 3. Packages (implement S/O = Sonnet/Opus as marked; "L" = spec line range)

| Pkg | Purpose | Implements | Read (spec) | Exit check | Model |
|---|---|---|---|---|---|
| A1-A4 | DONE (3A): telemetry lock, wrappers removed, suite split, engine signals | FR-311c, FR-314 to FR-318 | see section 4 | AC-317, 322, 323, 331 to 333 | done |
| B1 | Manifest lib: ids, claim, atomic write/read, derived status, schema, validator, `.gitignore` | FR-304, 305, 306, 309 (status) | L84-125, L163-167, AC-308/309 L324-338, AC-329 L484-490 | AC-309, AC-329, writer-reader half of AC-308 | S, O |
| B2 | Workflow extraction, `-Profile`, stage contract | FR-303 | L74-82, AC-302 L276-282, AC-304 L292-298, AC-330 L492-498 | AC-304, AC-330, AC-302 minus the two ContextFile additions | O, O |
| B3 | Parser, `stages`, `config`, `doctor`, `validate`, unsupported stages | FR-301, 302, 308, 309, 318 | L32-72, L135-167, L216-222, AC-301 L268-274, AC-312 L356-362, AC-314 L372-378, AC-333 L516-522 | AC-301, AC-312, AC-314, AC-333 | S, S |
| B4 | `specify`: layout, manifest, checkpoints, correlation, names, overwrite, protocol | FR-304, 305, 307, 308, 319, NFR-305 | L84-133, L135-161, L224-230, AC-303/305/307/308/310/311/313 (L284-290, L300-330, L340-370), AC-321 L420-426, AC-327/328 L468-482 | AC-303, 305, 307, 308 (checkpoints), 310, 311, 313, 321, 327, 328 | O, O |
| B5 | `review`, `revise`, live `status`, `list` | FR-319 (2nd para), FR-309 | L163-167, L224-230, AC-315 L380-386, AC-334 L524-530 | AC-334, AC-315 | S, O |
| B6 | Artifact lock, concurrent runs | FR-310, FR-311d | L169-179, AC-316 L388-394 | AC-316 | O, O |
| B7 | `-ContextFile` and builder `RepositoryContext` of reviewer and reviser | FR-313 (builders) | L181-185, AC-319 L404-410, AC-302 | builder part of AC-319, AC-302 complete | S, O |
| B8 | `scan`, `context`, `-Include`, `.ai-harness\` exclusion | FR-313 | L181-185, AC-319/320 L404-418 | AC-319, AC-320 | S, O |
| B9 | All commands unattended, footprint, README, regression | NFR-301, 302, 304 | L234-262, AC-306 L308-314, AC-324/325/326 L444-466 | AC-306, 324, 325, 326 | S, S |

Always useful: Execution Order L573-596 (needs and order), Affected Files L562-571 (the only files that may change). Order: A1; A2; A3 after A2; A4 after A3; B1, B2 after the gate; B3 after B1; B4 after B1+B2+B3; B5, B6, B7 after B4; B8 after B7; B9 last.

## 4. Engine facts (read from the files)

- `scripts/lib/agent-exec.ps1` (find by function name, not line): `New-RunAgentPrompt`, `Test-OllamaLoadFailureText` (pure helper, used only by the classifier), `Get-AgentErrorCategory`, `Invoke-OllamaHttp`, `Test-OllamaModel`, `Test-OllamaModelLoad`, `Invoke-AgentModel`. The two wrappers are gone (AC-322).
- `Invoke-AgentModel` warnings: `budget_exceeded`, `possible_prompt_truncation` (weak rule), `prompt_truncation_detected` (strong rule, FR-316; scripts print it before the weak line).
- 12 engine categories (hints table of `Get-AgentErrorCategory`): `http_5xx`, `http_4xx`, `timeout`, `transport_unreachable`, `transport_reset`, `transport_other`, `context_budget_exceeded`, `thinking_budget_exhausted`, `empty_response`, `format_invalid`, `model_not_installed`, `model_load_failed`. Retried: `http_5xx`, `transport_reset` only; `model_load_failed` is reclassified from a 5xx whose JSON `error` string has a load marker and is not retried.
- `Test-OllamaModelLoad -Execution -Registry [-Transport]` returns `{loaded, category, hint, durationMs}`; one attempt, no telemetry; member list pinned (AC-333). It has no `httpStatus` or detail (gate finding 13: B3/B4 use fixed wording or decide to add members).
- `scripts/lib/telemetry.ps1`: telemetry is LOCKED (A1): mutex `Global\AiHarnessTelemetry-<16 hex>`, one `FileStream` per file, `Write-HarnessModelTelemetry [-LockWaitMs]` (default 10000). `Read-HarnessModelTelemetry -Root [-FromOffset] [-LengthOnly] [-LockWaitMs]` returns `{Exists, Length, Lines, LockTimedOut}`; `-Root` is the harness root (not `logs`) and must be ABSOLUTE; `LockTimedOut` is also true for a refused name. v2 = 31 columns (14 legacy then 17); JSONL `logs\model-calls.jsonl`, CSV beside it. B6 reworks the retry budget (one deadline), `AppendData` and the CSV share-deny (FR-311c).
- `scripts/lib/config.ps1`: `Get-HarnessRegistry` (390), `Get-HarnessRegistryModels` (398), `Resolve-HarnessExecution` (426).
- `.ai/config.json` `schemaVersion` 2: profiles `fast` (qwen3.5:9b, 16384, reserved 4096), `deep`, `review` (reserved 6144); agents `spec`=fast, `spec-reviewer`=review, `spec-reviser`=deep, `developer`=deep; agent files in `.ai\agents\`.
- The eight legacy scripts and `AI_HARNESS_MODEL`, `AI_HARNESS_RUN_ID` keep their behavior (NFR-304).

## 5. Working rules

- Windows PowerShell 5.1, ASCII only; change only the files of Affected Files.
- Tests offline with the engine fake host (no Ollama, no network, writes only under TEMP, tripwire clean).
- Expected `scripts\test-all.ps1` at `phase3a-done`: 22 discovered, 21 PASS, 1 skipped (`test-spec-integration.ps1`).
- Engine suites: `test-engine-callsites-run-agent.ps1`, `-review-spec.ps1`, `-revise-spec.ps1` (their case names are pinned by AC-323), `test-engine-signals.ps1` (A4: AC-331, 332, 333), helper `tests/lib/engine-fake-host.ps1` (fake host, `Invoke-Case`, `New-V2Config`, four guards; knows only `/api/tags` and `/api/generate`, B3 adds `/api/version`).
- AC-322 (in `test-engine-callsites-run-agent.ps1`): no wrapper name in files git does not ignore under `scripts\` and `tests\`. AC-323: `tests\lib\compare-engine-case-names.ps1 -RunSuites` (about 3 min, NOT run by `test-all`; run in B9).
- Existing assertions 3B may extend (FR-314): the function lists and parameter count in `test-agent-telemetry-v2.ps1`, the pinned lists in `test-agent-prompts.ps1` and `test-agent-exec.ps1`.
- Sessions never push, reset, rebase, tag, amend or delete; the owner does Git remote work. One final `test-all` per package (owner cost rule; the gate itself runs it twice), then a report and STOP for review.
- Mutation proofs only for the key rules the AC names (temporary edit, hash-checked revert).
- Assumptions never become requirements; report ambiguity instead of inventing.

## 6. Report convention

Every report, `docs/audits/<date>-phase3-<package>.md`, starts with an executive summary of at most 60 lines: what was done, files, test counts, mutations, doubts, what is not verified.
