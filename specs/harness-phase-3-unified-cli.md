# Specification

**Title:** Harness modernization, Phase 3: unified CLI, run manifests and safe concurrent runs
**Status:** Draft, revision 1 (2026-11-25). Written unattended; nothing is approved. Every choice beyond the roadmap is an Open Question with a RECOMMENDATION. Phases 4 to 6 are not designed here.
**Applies to:** AI-Dev-Harness. Baseline: tag `phase2-done` (Phase 2 spec Revision 3.4).
**Requirement ID scheme:** `FR-3nn`, `NFR-3nn`, `AC-3nn`. Earlier IDs are cited as "Phase 2 FR-216" (`specs/harness-phase-2-shared-engine.md`); XR-nn, O-nn, R-nn are the roadmap's (`docs/roadmap/modernization-roadmap.md`); DF-2nn are Phase 2 deferrals; I-n and N-n are findings of `docs/audits/2026-11-26-phase2-final-qa.md`.

## Goal

Add one entry point, `scripts/harness.ps1`, over the existing scripts. Every workflow run gets a run directory and a versioned manifest (with a schema and a validator) carrying what Phase 2 now records: profile, model, attempts, warnings, categories, durations, call ids, artifact paths. Failures and unsupported stages end with a stable exit code and a machine-readable status. A run is a short-lived foreground process that checkpoints its manifest, is inspected with `status` and continued with `-Resume`; background execution is left to Claude Code. Concurrent runs become safe (telemetry lock, artifact lock). The deprecated wrappers are deleted and the largest suite is split. The legacy scripts keep their interfaces.

## Context

**Origin.** The roadmap's Phase 3 section, XR-03 (remainder), XR-06 to XR-08, XR-10, O-07, O-11, O-12, O-14, O-18, R-07; Phase 2 DF-202, DF-203 and "Out of scope"; sections 2, 9 and 10 of the Phase 2 final QA; the owner's task of 2026-11-25.

**Current behavior** (FACT, at `phase2-done`, `8c26f72`):

- `specify.ps1` (382 lines) is the only workflow driver. It calls four scripts with `&` in its own process (`-RunnerScript`, `-ValidatorScript`, `-ReviewerScript`, `-ReviserScript`, each defaulting to its sibling): `run-agent.ps1 -Agent spec`, `validate-spec.ps1`, then up to 3 rounds of `review-spec.ps1`, `revise-spec.ps1` and validation. It writes `<harness>/specs/<Name>.md`, `.review.md`, `.revised-vN.md`, `.revised-vN.review.md`. Exit 0 (PASS), 1 (FAIL after 3 revisions), 2 (any error, including a failed validation), 3 (insufficient input). It passes no `-ContextFile` and has no `-Profile`. `review-spec.ps1` exits 0, 1 or 2.
- The three agent scripts use the engine and write one telemetry record per call (`run_id` from `AI_HARNESS_RUN_ID`, else a GUID; `call_id`, `profile`, `model`, `model_source`, `attempts`, `error_category`, `http_status`, `warnings`, `timeout_sec`, `context_window`, `est_prompt_tokens`, `duration_ms`; 31 columns). Telemetry has no workflow, stage or artifact field (Phase 2 OQ-205).
- Only `run-agent.ps1` accepts `-ContextFile`; the reviewer and reviser builders have no context part.
- The telemetry writer has no lock: 2 overlapping processes kept 1 to 14 of 80 records, 4 kept 6 to 8 of 160 (DF-202, I-6).
- `Invoke-HarnessGenerate` and `Test-HarnessModelAvailable` are unused (DF-203); 8 `AC-216` cases of `test-engine-callsites.ps1` (2,081 lines, 160 cases, about 164 s), a `Write-Host` exemption and a pinned list in `test-agent-prompts.ps1` cover them.
- `scan-repository.ps1` does not exclude `.ai-harness/`. There is no `runs/`, manifest, CLI or JSON status, and `.gitignore` has no `runs/`.

**Hooks left for Phase 4** (its design is out of scope): the exit-code table and the `RUN_ID:` and `MANIFEST:` lines; `-Json` on the read-only commands (so a permission rule can allow them); a caller-chosen `-RunId`; `trust` on every artifact and an empty `verification[]` (Phase 6); `process.background` (false) with the process id and start time (a later `cancel`).

**Out of scope.** Phases 4 to 6. A detached `-Background`, `cancel`, heartbeats, a queue (OQ-302). Saved prompts, raw outputs and `console.log` (OQ-309). New telemetry columns (OQ-304). Run pruning `[O]`. The live validation WP-2E.

## Functional Requirements

### FR-301 — One entry point and its commands

**Source:** USER

`scripts/harness.ps1 <command> [options]` is the single entry point.

| Command | Does | Manifest |
|---|---|---|
| `specify` | the workflow of `specify.ps1` (FR-303) | yes |
| `review`, `revise` | one `review-spec.ps1` or `revise-spec.ps1` call on a spec in the target | yes |
| `scan`, `context` | `scan-repository.ps1`; scan plus `build-context.ps1`, into the run directory (FR-313) | yes |
| `validate` | `validate-spec.ps1 -SpecFile -Mode`, exit code passed through (0, 1, 3) | no |
| `status`, `list`, `stages`, `config`, `doctor` | read-only (FR-309) | no |
| `architecture`, `plan`, `qa`, `code-review`, `develop` | unsupported stages (FR-308) | yes |

A command that writes a file creates a run and a manifest; one that only reads never does. An unknown command is `invalid_arguments` (exit 2, no manifest; OQ-308). `develop` stays unsupported until Phase 5 (OQ-306). Stages run in the CLI's own process with `&`; the only other process it starts is read-only `git` (FR-305).

### FR-302 — Parameters and validation

**Source:** USER

Workflow commands take `-TargetPath`, `-Name`, `-Mode` (`requirements`, `baseline`, `documentation`; default `requirements`), `-Task` or `-TaskFile` (exactly one, UTF-8), `-Include <relative paths>` (FR-313), `-Model` or `-Profile` (both is `invalid_arguments:`, as Phase 1 FR-104), `-RunId`, `-Resume`, and the four test seams `-RunnerScript`, `-ValidatorScript`, `-ReviewerScript`, `-ReviserScript` (as in `specify.ps1`). `review` and `revise` also take `-Revision N` (0 by default for `review`; at least 1 and required for `revise`) and read and write only `<Name>`, `<Name>.revised-vN` and their `.review.md` files in `<TargetPath>\.ai-harness\specs\`; there is no free output path. Read-only commands take `-Json`, `-RunId`, `-Last`, `-Agent` where meaningful. `-TargetPath` is required by every command that writes an artifact (O-07, OQ-301), must be an existing folder, and is canonicalized with `GetFullPath`; there is no current-folder default. An option of another command, a stray positional argument, a bad `-Name` (the `specify.ps1` pattern) or `-RunId` (FR-304) and a missing required option are `invalid_arguments` (exit 2). The harness's own error lines start with a fixed token (`invalid_arguments:`, `registry_invalid:`); tests match only those (NFR-303).

### FR-303 — One shared specify workflow; legacy scripts keep their interfaces

**Source:** USER

The review and revision loop moves to `scripts/lib/workflow.ps1` as `Invoke-SpecifyWorkflow`, called by `specify.ps1` and by `harness.ps1 specify`. It takes the four script paths, `Mode`, `Task`, `Name`, an output directory, optional `-Model` or `-Profile`, an optional context file and an optional stage hook. It prints the console lines `specify.ps1` prints today, never calls `exit`, and returns `{ outcome, category, stage, legacyExitCode, cliExitCode }`. The hook gets `stage_begin` (id, kind, agent, attempt) and `stage_end` (id, status, exit code, output path, verdict, reason) and uses only its parameters (the engine's hook rule). `specify.ps1` keeps its parameters, folder (`<harness>\specs\`), file names, `maxRevisions = 3` and exit codes 0 to 3, and passes no hook, run directory or context (OQ-307). Its only addition is an optional `-Profile`, passed to the three agent scripts only when bound (Phase 2 "Out of scope", OD-108). The two front ends map one outcome to different codes: a failed structural validation is 2 for the legacy script and 1 for the CLI (FR-308, OQ-310).

### FR-304 — Run identity, run directory, artifact locations

**Source:** USER

The run id is `-RunId`, else a valid `AI_HARNESS_RUN_ID`, else `<UTC yyyyMMddTHHmmssZ>-<8 lowercase hex>`. A given id matches `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`; an invalid environment value is ignored with the warning `invalid_run_id_env`. `<harness>\runs\<runId>\` is created with an existence check; an existing id is `invalid_arguments` unless `-Resume` (FR-312). The CLI sets `$env:AI_HARNESS_RUN_ID` to the id for its stages and restores the old value in a `finally`, so telemetry `run_id` equals the manifest `runId` (XR-01).

```text
<target>\.ai-harness\specs\   <Name>.md, .review.md, .revised-vN.md, .revised-vN.review.md
<harness>\runs\<runId>\       manifest.json, inputs\task.md, inputs\scan.json, inputs\context.txt
<harness>\logs\               model-calls.jsonl, .csv (unchanged)
```

Inside a target the harness writes only below `<target>\.ai-harness\`. `runs/` is added to `.gitignore`. `inputs\task.md` is the only place with the task text (O-14). `console.log`, `prompts\` and `outputs\*.raw.md` of XR-07 are not created (OQ-309).

### FR-305 — The run manifest (XR-08)

**Source:** USER

`runs\<runId>\manifest.json`: UTF-8 without BOM, `ConvertTo-Json -Depth 10`, `schemaVersion` 1. It is created before the first stage (`running`, `exitCode` null), rewritten at every stage event (a checkpoint) and at the end, each time by writing a temp file in the same folder and then `File.Replace` (`Move` when the target does not exist). Readers retry up to 5 times, 20 ms apart. The final write precedes the `MANIFEST:` line (FR-308).

| Field | Content |
|---|---|
| top level | `schemaVersion`, `runId`, `workflow`, `status` (`running`, `succeeded`, `failed`, `needs_input`), `exitCode`, `createdAtUtc`, `startedAtUtc`, `endedAtUtc`, `resumeCount`, `warnings[]` (union, no duplicates), `error` (null, or as a stage `error`) |
| `harness` | `root`, `gitCommit`, `gitDirty` (null without `git` or a repository; read-only `rev-parse` and `status --porcelain`), `registrySchemaVersion`, `registrySha256` (of `.ai\config.json`), `ollamaUrl` |
| `target` | `root`, `artifactDir`; null with no target |
| `process` | `pid`, `processStartUtc`, `background` (false) |
| `request` | `name`, `mode`, `maxRevisions` (3), `taskSha256`, `taskFile`, `include[]`, `revision`, `overrides {model, profile}` |
| `context` | null, or `file`, `sha256`, `chars`, `files[] {path, sha256, sizeBytes}` |
| `stages[]` | `id`, `kind` (`agent`, `deterministic`, `unsupported`), `agent`, `attempt`, `status` (`pending`, `running`, `succeeded`, `failed`, `skipped`, `unsupported`), `reason`, `startedAtUtc`, `durationMs` (wall time), `exitCode`, `resolution {profile, model, modelSource, timeoutSec}`, `budget {contextWindow, estimatedPromptTokens, withinBudget}`, `callId`, `engineAttempts`, `callDurationMs`, `warnings[]`, `contextSha256`, `verdict` (`PASS`, `FAIL`, null), `output {path, sha256}`, `reused`, `error {category, engineCategory, message, retryable, httpStatus}` |
| `artifacts[]` | `role`, `path` (relative), `sha256`, `trust` (`untrusted-draft` for model output, `deterministic-check` for the context file; `verified-by-command` is not produced) |
| `verification[]` | empty in Phase 3 (Phase 6) |

`attempt` is the position in the review loop (1-based); `engineAttempts` is the engine's HTTP attempts (telemetry `attempts`), so a retried call is visible (final QA section 10). Stage ids: `scan`, `context`, `spec-generate`, `spec-validate`, `spec-review`, `spec-revise`, `revised-validate`. The run states `queued`, `cancelled` and `abandoned` are never written (`abandoned` is derived, FR-309). A review that returns FAIL is a `succeeded` stage with verdict `FAIL`. A planned stage not reached when the run ends is `skipped` with the reason `dependency failed: <id>`; the next loop round's stages are appended only after a FAIL verdict. `budget.reservedOutputTokens` of the roadmap example is not carried (OQ-304).

### FR-306 — Manifest schema and validator

**Source:** USER

`scripts/lib/run-manifest.schema.json` is the schema of FR-305, in a documented subset of JSON Schema (`type`, `required`, `enum`, `properties`, `items`, `pattern`, `minimum`). `lib\manifest.ps1` has `Test-HarnessManifest -Manifest <object or JSON text> [-SchemaPath]`, returning `{ valid, errors[] }` with errors `<JSON path>: <code>`; codes `missing_required`, `wrong_type`, `not_in_enum`, `pattern_mismatch`, `below_minimum`, `unsupported_schema_version`, `invariant_*`. Required keys, types and enums come from the schema file only. Invariants: a terminal run has `exitCode` 0 to 4 and `endedAtUtc`; `succeeded` has `exitCode` 0 and no failed stage; `failed` and `needs_input` have an `error`; (`id`, `attempt`) is unique; `artifacts[].path` is relative without `..`. Every manifest the CLI writes is valid, after any failure too.

### FR-307 — Telemetry correlation without a telemetry change

**Source:** ASSUMPTION

The manifest is joined to telemetry by `run_id` (= `runId`) and `call_id`; no column is added (OQ-304). At `stage_begin` of an agent stage the CLI notes the byte length of `logs\model-calls.jsonl`; at `stage_end` it reads the bytes appended since (share mode ReadWrite), keeps the parsable lines whose `run_id` is the run id, and fills the stage from the last: `callId`, `engineAttempts`, `callDurationMs`, `warnings` (split on `;`), `resolution` (`profile`, `model`, `model_source`, `timeout_sec`), `budget` (`context_window`, `est_prompt_tokens`; `withinBudget` false when `budget_exceeded` is a warning), `error.engineCategory`, `error.httpStatus`. No record: `callId` null and the warning `telemetry_record_missing`. Several: the last wins and `telemetry_multiple_records` is added. `error.category` is the roadmap name from this table, which is Phase 2 FR-211's mapping (OQ-305): `transport_unreachable` to `ollama_unreachable`; `http_4xx`, `http_5xx`, `transport_reset`, `transport_other` to `http_error`; `empty_response`, `thinking_budget_exhausted` to `empty_output`; `format_invalid` to `invalid_output_format`; `timeout`, `context_budget_exceeded`, `model_not_installed` unchanged. Detail text comes only from the telemetry `error` column (single-line, cut at 500) or from fixed harness wording, never from an exception message.

### FR-308 — Exit codes, categories, unsupported stages, output protocol (XR-10)

**Source:** USER

Exit codes: 0 success; 1 workflow failure (`validation_failed`, `review_failed` for `harness review` with a FAIL verdict, `max_revisions_reached`); 2 execution error; 3 `needs_human_input`; 4 unsupported stage. `manifest.exitCode` equals the process exit code. `error.category` is one of: `invalid_arguments`, `registry_invalid`, `agent_not_found` (an `.ai\agents\<agent>.md` is missing; checked before the first stage), `ollama_unreachable`, `model_not_installed`, `context_budget_exceeded`, `context_invalid`, `timeout`, `http_error`, `empty_output`, `invalid_output_format`, `validation_failed`, `review_failed`, `max_revisions_reached`, `needs_human_input`, `unsupported_stage`, `artifact_in_use` (FR-311), `stage_failed` (a stage exited non-zero and wrote no record; fixed wording naming the stage and code), `internal_error`; `cancelled` and `abandoned` are reserved. `architecture`, `plan`, `qa`, `code-review` and `develop` exit 4 with one stage of kind `unsupported`, status `unsupported`, run status `failed`, and the message "No local agent implements '<stage>'; perform it in Claude Code or manually." The harness never simulates a stage.

Workflow commands print `RUN_ID: <runId>` as the first line after argument validation and `MANIFEST: <absolute manifest path>` as the last stdout line, on success and on every failure once a run directory exists. A failure before that (unknown command, bad `-RunId`, `runs\` not writable) prints one `ERROR: <token>: <text>` line, exits 2 and writes no manifest. Failures keep partial artifacts and earlier stage records. The CLI never prompts or reads stdin (NFR-301). Legacy scripts keep their codes.

### FR-309 — Read-only commands and derived status

**Source:** USER

`-Json` makes a read-only command print exactly one JSON line and nothing else. `stages` lists each command and stage with `supported`, its agent and a `reason` (`no_local_agent`, `planned_phase_5`). `config [-Agent] [-Model|-Profile]` prints, for each file in `.ai\agents\`, the record of `Resolve-HarnessExecution` (profile, model, `modelSource`, `parametersFrom`, `contextWindow`, `timeoutSec`, `reservedOutputTokens`, `think`, warnings) and the registry warnings; it sends no request. `doctor` runs `Get-HarnessRegistry`, then `Test-OllamaModel` per distinct model (one `/api/tags` call), with no `-TelemetryRoot`, never calls `/api/generate`, and reports each finding with a category: exit 0 all well, 1 a configured model is not installed, 2 invalid registry or Ollama unreachable. `list [-Last N]` shows runs newest first with the derived status. `status -RunId` prints `runId`, `workflow`, `recordedStatus`, `status`, `exitCode`, each stage's `id` and `status`, `warnings`, `error` and the manifest path. The derived status equals the recorded one, except that a recorded `running` is `abandoned` when the `pid` does not exist or its start time differs from `processStartUtc` by more than 2 s. `status` and `list` never write.

### FR-310 — Execution model: no job daemon (XR-06, O-07, O-11)

**Source:** ASSUMPTION

Phase 3 relies on Claude Code's own background execution (`run_in_background`) and builds no detached process, `-Background`, `cancel`, heartbeat or queue (OQ-302). The CLI is a short-lived foreground process built to be killed at any moment: the manifest is checkpointed at every stage event, `status` tells a live run from a dead one without its help, `-Resume` (FR-312) continues a dead run, and a caller passes `-RunId` to know the result path in advance. A run that starts while another recorded-`running` run with a live process has the same `harness.ollamaUrl` records the warning `concurrent_run_detected` (R-07); nothing is queued or refused for that.

### FR-311 — Safe concurrent runs (DF-202, I-6)

**Source:** USER

(a) Run ids and directories are unique (FR-304). (b) Manifest writes are atomic and readers retry (FR-305). (c) `Write-HarnessModelTelemetry` takes a named mutex around its whole file section (JSONL append, CSV header decision, CSV append): `Global\AiHarnessTelemetry-<first 16 hex of SHA-256 of the lower-cased full log directory path>`, with the `Local\` name as fallback when the `Global\` one is refused. It waits at most `-LockWaitMs` (new optional parameter, default 10000); `AbandonedMutexException` counts as acquired; the mutex is released in a `finally`; on a timeout it writes unlocked and prints a `Write-Warning`; it never fails the call. Records, columns, files and the CSV rule are unchanged. (d) A workflow command holds the mutex `Global\AiHarnessArtifact-<first 16 hex of the SHA-256 of the lower-cased target path, a vertical bar and the lower-cased name>` for the whole run, taken without waiting; if it is held, the command exits 2 with `artifact_in_use` before any stage, touching no artifact. The operating system releases it when the holder dies, so a killed run never blocks a new one (OQ-311). With (c), "exactly one record per call" (Phase 2 FR-216) holds under overlap.

### FR-312 — Resume

**Source:** ASSUMPTION

`harness specify -Resume -RunId <id>` (also `review`, `revise`) continues a run that is derived `abandoned` or recorded `failed`. It exits 2 with `invalid_arguments`, running no stage and leaving the manifest untouched, for a run that is `succeeded`, `needs_input` or alive, for a missing manifest, and for a recomputed `taskSha256`, `name`, `mode`, target, overrides or `-Include` that differs from the manifest. The workflow is replayed: an agent stage that is `succeeded` in the old manifest and whose output file still has the recorded SHA-256 is not run again (`reused: true`, verdict taken from the manifest); every other stage, deterministic ones included, runs. `resumeCount` increases, earlier stage records are kept, id and directory stay, and the lock of FR-311(d) is taken again.

### FR-313 — Repository context in every stage (XR-03 remainder, XR-04)

**Source:** USER

With `-Include`, `specify` first runs the stages `scan` (`scan-repository.ps1` on the target, to `inputs\scan.json`) and `context` (`build-context.ps1` with the includes, to `inputs\context.txt`, default limits 24000 and 20000), then passes the same file as `-ContextFile` to the spec agent, the reviewer and the reviser. `review-spec.ps1` and `revise-spec.ps1` gain an optional `-ContextFile`; their builders gain an optional `RepositoryContext` that adds one `data` part named `repository-context`, with the wording of `New-RunAgentPrompt`, after the task part. Without a context file every prompt is byte-identical to today's (Phase 2 goldens). The manifest records the context hash, each file's path, SHA-256 and size (computed by the CLI after `build-context.ps1` succeeded) and `contextSha256` on each stage that received it. The existing guards decide what is accepted (absolute or rooted paths, `..`, duplicates, files not in the scan, sensitive names, extensions, reparse points, NUL bytes, size limits); a rejection is `context_invalid` before any model call. New: `scan-repository.ps1` excludes `.ai-harness\`, so specs and reviews are never general context (XR-04). Not built: the derived budget `C - R - S - fixed size`, because the reviewer's fixed text already exceeds it under the shipped configuration (Phase 2 Context) and the ratio is uncalibrated until WP-2E; the engine's own check (`budget_exceeded` in `warn`, `context_budget_exceeded` in `enforce`) covers the prompt with context and reaches the manifest (OQ-312). The shared sensitive-pattern policy is not built (OQ-313).

### FR-314 — Delete the deprecated wrappers (DF-203)

**Source:** USER

`Invoke-HarnessGenerate` and `Test-HarnessModelAvailable` are removed from `lib\agent-exec.ps1`, with the 8 `AC-216` cases that exercise them, the `Write-Host` exemption and the two pinned-list entries in `test-agent-prompts.ps1` (the NFR-203 scan then forbids `Write-Host` in the whole library), and the scan in `test-engine-callsites.ps1` that no script names them (replaced by AC-322). This supersedes Phase 2 FR-202, AC-216 and AC-218 for these two functions only; the Phase 2 spec gets a one-line note. The authorized edits of existing assertions are exactly these.

### FR-315 — Split `test-engine-callsites.ps1` by script

**Source:** USER

The suite becomes `test-engine-callsites-run-agent.ps1`, `-review-spec.ps1` and `-revise-spec.ps1` over one helper, `tests\lib\engine-fake-host.ps1` (fake host, `New-TempHarness`, `Invoke-Case`, the four guards, assertion helpers; not named `test-*`, so `test-all.ps1` never runs it). Only the file and order of cases change; no case body, assertion or expected value is edited. FR-314 is done first, as its own commit. Each suite follows the `test-all.ps1` contract and runs the four guards.

## Non-Functional Requirements

### NFR-301 — Platform and unattended use

**Source:** PROJECT

Windows PowerShell 5.1; no module, package or executable is added. `harness.ps1` never prompts and never reads stdin, so it is safe inside Claude Code's `run_in_background`: no `Read-Host`, `$Host.UI.Prompt*`, `pause`, `Start-Process`, `Start-Job` or HTTP cmdlet in `harness.ps1`, `lib\workflow.ps1` and `lib\manifest.ps1` (the only HTTP route stays inside `Invoke-OllamaHttp`), JSON written with depth at least 10, no `ConvertFrom-Json -AsHashtable`.

### NFR-302 — Write boundaries

**Source:** USER

During any command, the target tree outside `.ai-harness\` is byte-identical before and after (SHA-256 tripwire); the harness root changes only in `runs\<runId>\` and `logs\`; for the legacy `specify.ps1`, only `specs\` as today.

### NFR-303 — Offline, side-effect-free tests

**Source:** USER

Every new or changed suite follows Phase 0 NFR-002 and NFR-006 and Phase 2's pattern: no Ollama or network, writes only under `TEMP`, tripwire clean, no mandatory parameters, explicit `exit`. A test that runs a script that could send a request uses the engine fake host and its four guards (the URL must be `http://127.0.0.1:9`; the fake exits 97 unless it is in effect; any other URI is refused and recorded; a static scan of the copied scripts). Assertions match only exit codes, manifest values, record fields, and harness wording (`invalid_arguments:`, `MANIFEST:`, category names); never text produced by PowerShell, .NET or Ollama, and no expected value is computed with the code under test (hashes come from `Get-FileHash`, golden tables are literal, baselines come from `phase2-done`).

### NFR-304 — Backward compatibility and change footprint

**Source:** USER

XR-01 holds: the parameters, exit codes, console markers and output files of `run-agent.ps1`, `specify.ps1`, `review-spec.ps1`, `revise-spec.ps1`, `validate-spec.ps1`, `scan-repository.ps1`, `build-context.ps1` and `benchmark-models.ps1`; `AI_HARNESS_MODEL` and `AI_HARNESS_RUN_ID`; a v1 configuration; the 31-column telemetry; the `test-all.ps1` contract. Prompts, `.ai\agents\*`, `.ai\rules\*`, `.ai\config.json`, `AGENTS.md` and the Phase 2 goldens do not change. Only the files under "Affected Files" change.

### NFR-305 — Privacy of task text

**Source:** USER

The task text appears only in `runs\<runId>\inputs\task.md` and in the files the scripts already write. The manifest holds `taskSha256`, and telemetry stays as Phase 2 defined it (O-14).

## Acceptance Criteria

"Mock stage scripts" are passed through the four seams; they record their arguments under `TEMP`, may write telemetry with `Write-HarnessModelTelemetry` (inheriting `AI_HARNESS_RUN_ID`), and are steered by environment variables. "End-to-end" cases run the real scripts on the engine fake host.

### AC-301 — Dispatch and argument validation

**Source:** USER

Verifies: FR-301, FR-302.

Each command of FR-301 reaches its handler. Exit 2 with a first error line starting `invalid_arguments:` (no manifest for an unknown command, a failed manifest otherwise) for: an unknown command; `-Model` with `-Profile`; `-Task` with `-TaskFile`, or neither; a stray positional argument; an option of another command; a bad `-Name`; a missing `-TargetPath` for `specify`, `review`, `revise`, `scan`, `context`; a `-TargetPath` that is no folder; `revise` without `-Revision`. A relative `-TargetPath` is stored in full in the manifest.

### AC-302 — The legacy interfaces are unchanged

**Source:** USER

Verifies: FR-303, NFR-304.

The parameter names of `run-agent.ps1`, `specify.ps1`, `review-spec.ps1`, `revise-spec.ps1`, `validate-spec.ps1`, `scan-repository.ps1`, `build-context.ps1` and `benchmark-models.ps1`, read with the PowerShell parser, equal `tests\fixtures\legacy-parameters.json`, captured at `phase2-done` before any change, plus exactly `Profile` on `specify.ps1` and `ContextFile` on the reviewer and reviser. `test-mode-propagation.ps1`, `test-spec.ps1` and the engine call-site suites pass, and `git diff phase2-done` shows no changed line in the first two and no changed assertion in the third beyond FR-314 and FR-315.

### AC-303 — One workflow for both front ends

**Source:** USER

Verifies: FR-303, FR-308.

For the scenarios PASS at the first review, PASS after one revision, FAIL after 3 revisions, validator exit 3, validator exit 1 on the first spec, runner exit 2, reviewer exit 2, reviser exit 2, the recorded stage calls of `specify.ps1` and of `harness.ps1 specify` (order and arguments, the output directory replaced by a placeholder) each equal a frozen file `tests\fixtures\specify-calls-<scenario>.txt`, recorded by running the unmodified `specify.ps1` of `phase2-done` with the same mocks (so the oracle is not the new code). Exit codes in that order: legacy 0, 0, 1, 3, 2, 2, 2, 2; CLI 0, 0, 1, 3, 1, 2, 2, 2.

### AC-304 — `-Profile` on `specify.ps1`

**Source:** USER

Verifies: FR-303.

With `-Profile P` bound, the three agent mocks receive `-Profile P` and no `-Model`; unbound, none receives `-Profile`; `-Model` with `-Profile` exits 2 with `invalid_arguments:` before any stage call.

### AC-305 — Run id, layout and artifact locations

**Source:** USER

Verifies: FR-304.

A generated id matches `^\d{8}T\d{6}Z-[0-9a-f]{8}$`; a valid `-RunId` or `AI_HARNESS_RUN_ID` is used; an invalid environment value is ignored with `invalid_run_id_env` in the warnings; an invalid or existing `-RunId` exits 2 with `invalid_arguments:`. A mock `specify` with one revision against a temporary target leaves exactly `.ai-harness\specs\<Name>.md`, `.review.md`, `.revised-v1.md`, `.revised-v1.review.md` and, under `runs\<id>\`, `manifest.json` and `inputs\task.md` (bytes equal to the task). The mocks saw `AI_HARNESS_RUN_ID` equal to the id; the variable is restored afterwards. `.gitignore` has the line `runs/`.

### AC-306 — The target is not touched outside `.ai-harness\`

**Source:** USER

Verifies: FR-304, NFR-302.

Around each of `specify` (success and failure), `review`, `revise`, `scan`, `context`, `architecture` and every read-only command, the SHA-256 listing of the target outside `.ai-harness\` is identical and the harness root differs only by new files in `runs\<id>\` and `logs\`. `status`, `list`, `stages`, `config`, `doctor` and `validate` change no file anywhere.

### AC-307 — Manifest of a successful run

**Source:** USER

Verifies: FR-304, FR-305.

The manifest of the one-revision mock `specify` passes `Test-HarnessManifest`: `status` `succeeded`, `exitCode` 0, stage ids `spec-generate`, `spec-validate`, `spec-review` (attempt 1, FAIL), `spec-revise`, `revised-validate`, `spec-review` (attempt 2, PASS), all `succeeded`; every `output.sha256` and artifact `sha256` equals `Get-FileHash`; model outputs are `untrusted-draft`; `verification` is empty; `process.pid` equals the id of the child process the test started and `processStartUtc` is within 2 s of its start; `taskSha256` and `registrySha256` equal the hashes of the task and config bytes.

### AC-308 — Checkpoints and atomic writes

**Source:** USER

Verifies: FR-305.

A mock stage that reads `manifest.json` while it runs sees `running`, `exitCode` null, itself `running` and the earlier stages finished. A writer process rewrites a manifest 200 times while a reader process reads it in a loop: every read parses and validates (retries allowed, at most 5 per read), none returns partial JSON, and no temp file remains.

### AC-309 — Schema and validator

**Source:** USER

Verifies: FR-306.

A valid fixture passes. Fixtures with a missing required key (top level, stage, artifact), a wrong type, run status `unknown`, stage status `paused`, a bad `sha256`, `schemaVersion` 2, a terminal run with null `exitCode`, a `succeeded` run with a failed stage, a failed run with no `error`, a duplicate (`id`, `attempt`) and an absolute artifact path each fail with the expected code at the expected JSON path. The accepted run status, stage status and `trust` values equal the literal lists of roadmap XR-08 written in the test. Changing one enum value in a temporary copy of the schema changes the verdict for the same manifest.

### AC-310 — Telemetry correlation

**Source:** ASSUMPTION

Verifies: FR-307, NFR-304.

Mock stages each write one record with set values (call id, 2 attempts, `budget_exceeded`, a category, a duration). The stage carries the same `callId`, `engineAttempts` 2, `warnings`, `callDurationMs`, `resolution`, `withinBudget` false and, on failure, `error.engineCategory` and `error.httpStatus`. `error.category` for each of the 11 engine categories equals the literal table of FR-307 in the test. A stage with no record has `callId` null and `telemetry_record_missing` in the stage and the run; with two records the last is used and `telemetry_multiple_records` is added; a record of another `run_id` written during the stage is ignored; run `warnings` has no duplicates. The first line of `model-calls.csv` still equals the 31-column header frozen from `phase2-done`.

### AC-311 — Failure matrix

**Source:** USER

Verifies: FR-305, FR-308.

Each injected failure gives the exit code and `error.category` below, a valid manifest, earlier stages and artifacts kept, the failing stage `failed` and every planned later stage `skipped` with `dependency failed: <id>` (for `max_revisions_reached` and `review_failed` the last review is `succeeded` with verdict `FAIL`). Runner exit 2 with a record of `http_5xx`: 2, `http_error`; `timeout`: 2, `timeout`; `empty_response`: 2, `empty_output`; reviewer `format_invalid`: 2, `invalid_output_format`; `transport_unreachable`: 2, `ollama_unreachable`; `model_not_installed`: 2, same; `context_budget_exceeded`: 2, same; a stage exit 2 with no record: 2, `stage_failed`; validator exit 1 on the first spec: 1, `validation_failed`; validator exit 3: 3, `needs_human_input`, run `needs_input`; FAIL four times: 1, `max_revisions_reached`; missing `.ai\agents\spec.md`: 2, `agent_not_found`; invalid registry: 2, `registry_invalid` (for these two no stage ran and every planned stage is `skipped`). `harness review`: FAIL gives 1, `review_failed`; PASS gives 0.

### AC-312 — Unsupported stages

**Source:** USER

Verifies: FR-308, FR-309.

`architecture`, `plan`, `qa`, `code-review` and `develop` each exit 4 with one stage `unsupported`, run status `failed`, `unsupported_stage` and the FR-308 message with the stage name; no stage script is called and the fake host records no request. `stages -Json` lists those five with `supported` false and `specify`, `review`, `revise`, `scan`, `context`, `validate` with true.

### AC-313 — Output protocol

**Source:** USER

Verifies: FR-308.

For success and for each of exit 1, 2, 3 and 4, the first line after validation is `RUN_ID: <id>`, the last stdout line is `MANIFEST: <absolute path>`, the file exists, validates and holds that exit code. A bad `-RunId` prints one `ERROR: invalid_arguments:` line, exits 2 and creates nothing under `runs\`.

### AC-314 — `config`, `doctor`, `stages`, `-Json`

**Source:** USER

Verifies: FR-309.

`config -Json` on `config-v2-current.json` gives, per agent, the profile, model, `modelSource`, `timeoutSec` and `contextWindow` of a literal table, also with `-Profile`, `-Model` and `AI_HARNESS_MODEL`; the fake host records no request. `doctor` on the fake host: all models listed gives 0; one missing gives 1 with `model_not_installed`; connection refused gives 2; an invalid registry gives 2; always at most one `/api/tags` route, no `/api/generate`, no telemetry record. Every `-Json` output is one parsable line and nothing else.

### AC-315 — `status`, `list` and derived status

**Source:** USER

Verifies: FR-309.

A run whose mock stage sleeps is `running` while its process lives; after the test kills it, `status` shows `abandoned` with `recordedStatus` `running`. A manifest edited to the test's own live pid with another `processStartUtc` (over 2 s) shows `abandoned`. A finished run shows its recorded status. `list -Last 2` returns the two newest runs in order. The run directory has the same SHA-256 listing before and after `status` and `list`.

### AC-316 — Concurrent runs

**Source:** USER

Verifies: FR-310, FR-311.

Two `specify` runs with different names on one target, started together, both exit 0 with valid manifests and different ids; the telemetry file holds exactly the expected records, each with the right `run_id`. Two runs with the same target and name started together: one exits 0, the other 2 with `artifact_in_use` and changes nothing under `.ai-harness\`; after the holder is killed a third succeeds. A run started while another live run with the same `harness.ollamaUrl` is recorded `running` has `concurrent_run_detected` and still succeeds.

### AC-317 — Telemetry writer under overlap

**Source:** USER

Verifies: FR-311.

Four child processes each write 40 records (5 ms pause) to one temporary root: the JSONL has exactly 160 parsable lines with 160 distinct `call_id`; the CSV has 160 rows and one header. A second writer with `-LockWaitMs` 300 against a child holding the mutex writes its record after the wait, prints a warning and exits 0. A holder killed while holding the mutex does not block the next writer. The work package report records that the same stress with the lock disabled (temporary edit, hash-checked revert) loses records.

### AC-318 — Resume

**Source:** ASSUMPTION

Verifies: FR-312.

A run killed during `spec-review` (derived `abandoned`) is resumed with `-Resume -RunId`: exit 0; the runner mock ran once in total; `resumeCount` 1; `spec-generate` has `reused` true and the old `callId`; id and directory are unchanged. A changed task, name, mode, include list or model override, a `succeeded` run, a live run and an unknown id exit 2 with `invalid_arguments:` and run no stage. If the `spec-generate` output was edited, the stage runs again with `reused` false. A second resume while the first runs is refused with `artifact_in_use`.

### AC-319 — Context in every stage

**Source:** USER

Verifies: FR-313.

With `-Include` of two files, `scan` and `context` precede `spec-generate`; the runner, reviewer and reviser mocks all receive `-ContextFile` with `runs\<id>\inputs\context.txt`; `context.sha256` and each `files[].sha256` equal `Get-FileHash`; every agent stage has that `contextSha256`; without `-Include` no context stage runs and no `-ContextFile` is passed. End-to-end, each script's request prompt contains the file text. Without a context file the request bodies equal the Phase 2 goldens byte for byte (AC-201 cases unchanged); with one, the parts list equals the no-context list plus one `data` part `repository-context` after the task part, whose text equals what `New-RunAgentPrompt` builds for the same string.

### AC-320 — Include rejections and the `.ai-harness\` exclusion

**Source:** USER

Verifies: FR-313, NFR-304.

Each of these `-Include` values exits 2 with `context_invalid` before any model call, stage `context` failed and later stages skipped: an absolute path, a rooted path, `..`, a duplicate, a file not in the scan, `.env`, a `.pem` file, an unsupported extension, a file over 20000 bytes, a set over 24000 characters, a junction (if it can be created; else reported skipped), a file below `.ai-harness\`. `scan-repository.ps1` leaves `.ai-harness\` out of its manifest, and for a tree without it the output is byte-identical to the frozen output at `phase2-done`.

### AC-321 — Real scripts end to end

**Source:** USER

Verifies: FR-303, FR-307.

On the engine fake host with the real scripts: one `harness specify` run (spec, validation, one FAIL review, one revision, PASS) has stage `callId`, `resolution` and `engineAttempts` equal to the run's telemetry records (one per agent stage); a run with a 500 on the reviewer exits 2 with `http_error` and `error.engineCategory` `http_5xx`; the fake recorded only `http://127.0.0.1:9/` routes.

### AC-322 — The wrappers are gone

**Source:** USER

Verifies: FR-314.

The syntax tree of `lib\agent-exec.ps1` defines neither wrapper; after dot-sourcing the three libraries `Get-Command` finds neither; no file under `scripts\` or `tests\` contains either name (the test builds the names from fragments); the 8 AC-216 wrapper cases are gone; the NFR-203 scan of `test-agent-prompts.ps1` has no function exemption and finds no `Write-Host` in the library; the pinned list equals the Phase 2 list minus the two names; the other AC-216 criteria still pass.

### AC-323 — The suite split

**Source:** USER

Verifies: FR-315.

`test-engine-callsites.ps1` is gone; the three suites and the helper exist; `test-all.ps1` discovers the three and not the helper; each parses, has no mandatory parameter, ends with `exit`, passes with the four guards and runs under 300 s. The union of their case names equals `tests\fixtures\engine-callsites-cases.txt` (the old file's case names at the commit before the split, written by the work package from the old file) and the counts add up to its line count; the report repeats the comparison against `git show` of the old file.

### AC-324 — Full offline regression and determinism

**Source:** PROJECT

Verifies: NFR-301, NFR-303.

`scripts\test-all.ps1` offline, run twice: every suite PASS except the live one (SKIPPED), tripwire clean everywhere, no FAIL, and the two logs equal once times are removed. `test-syntax.ps1` parses every new file. A static scan finds none of the commands forbidden by NFR-301 in the three files named there, and no `.Exception.Message` in an assertion of a new suite.

### AC-325 — Footprint

**Source:** USER

Verifies: NFR-304.

`git diff --name-status phase2-done` of the final tree lists only the files of "Affected Files"; none of `.ai\`, `AGENTS.md`, `tests\golden\` or a Phase 0 to 2 fixture is in it; the case counts of the unchanged suites equal their Phase 2 counts (listed in the final QA).

### AC-326 — Unattended behavior

**Source:** PROJECT

Verifies: NFR-301.

Every command runs as `powershell.exe -NoProfile -NonInteractive` with stdin from an empty stream and ends within its test limit with the exit codes above. The static scan of AC-324 covers `harness.ps1`, `lib\workflow.ps1` and `lib\manifest.ps1`.

### AC-327 — Task text stays out of the manifest and telemetry

**Source:** USER

Verifies: NFR-305.

A task with a unique marker leaves the marker in `inputs\task.md` and in no other file under `runs\<id>\` nor any line of `logs\model-calls.jsonl` and `.csv` the run wrote.

## Traceability Matrix

This table is the inverse of the `Verifies:` lines above. The two must stay identical (the final QA re-derives it).

| Requirement | Acceptance criteria |
|---|---|
| FR-301 | AC-301 |
| FR-302 | AC-301 |
| FR-303 | AC-302, AC-303, AC-304, AC-321 |
| FR-304 | AC-305, AC-306, AC-307 |
| FR-305 | AC-307, AC-308, AC-311 |
| FR-306 | AC-309 |
| FR-307 | AC-310, AC-321 |
| FR-308 | AC-303, AC-311, AC-312, AC-313 |
| FR-309 | AC-312, AC-314, AC-315 |
| FR-310 | AC-316 |
| FR-311 | AC-316, AC-317 |
| FR-312 | AC-318 |
| FR-313 | AC-319, AC-320 |
| FR-314 | AC-322 |
| FR-315 | AC-323 |
| NFR-301 | AC-324, AC-326 |
| NFR-302 | AC-306 |
| NFR-303 | AC-324 |
| NFR-304 | AC-302, AC-310, AC-320, AC-325 |
| NFR-305 | AC-327 |

## Affected Files

| File | Change | Requirements |
|---|---|---|
| `scripts/harness.ps1`, `lib/workflow.ps1`, `lib/manifest.ps1`, `lib/run-manifest.schema.json` (new) | Entry point; `Invoke-SpecifyWorkflow`; run ids, directory, atomic write and read, checkpoints, correlation, derived status, `Test-HarnessManifest`; the schema | FR-301 to FR-313 |
| `scripts/specify.ps1` (modified) | Thin wrapper of the workflow; `-Profile` | FR-303 |
| `scripts/review-spec.ps1`, `revise-spec.ps1`, `lib/agent-exec.ps1` (modified) | Optional `-ContextFile` and builder part; the two wrappers removed | FR-313, FR-314 |
| `scripts/lib/telemetry.ps1` (modified) | Mutex, `-LockWaitMs` | FR-311 |
| `scripts/scan-repository.ps1` (modified) | Exclude `.ai-harness\` | FR-313 |
| `scripts/test-agent-prompts.ps1`, `test-agent-telemetry-v2.ps1`, `test-scan-repository.ps1` (modified) | FR-314 edits only; writer lock cases; the exclusion case | FR-311, FR-313, FR-314 |
| `scripts/test-engine-callsites.ps1` (deleted); `-run-agent`, `-review-spec`, `-revise-spec` suites, `tests/lib/engine-fake-host.ps1` (new) | The split | FR-315 |
| `scripts/test-harness-{cli,workflow,manifest,concurrency,context,e2e}.ps1` (new); `test-all.ps1` (only if sandbox entries are needed) | Phase 3 suites | AC-301 to AC-321, AC-326, AC-327 |
| `tests/fixtures/`, `tests/mocks/` (new files) | `legacy-parameters.json`, `specify-calls-*.txt`, `engine-callsites-cases.txt`, manifest fixtures, header and scan baselines; recording mock stage scripts | AC-302 to AC-323 |
| `.gitignore`, `README.md` (modified) | `runs/`; commands, exit codes, `MANIFEST:` | FR-304, FR-308 |
| `specs/harness-phase-2-shared-engine.md` (modified) | One-line note on FR-314; DF-202, DF-203 closed | FR-314 |
| this spec, `docs/audits/2026-11-25-phase3-spec-notes.md`, one report per work package (new) | Traceability | none |

**Not modified:** `run-agent.ps1`, `validate-spec.ps1`, `build-context.ps1`, `benchmark-models.ps1`, `.ai/*`, `AGENTS.md`, `tests/golden/*`, the Phase 0 to 2 fixtures and every other suite.

## Execution Order

One work package per unattended session. After each: `scripts/test-all.ps1` offline twice with counts recorded, the mutation proofs its acceptance criteria name (temporary edit, hash-checked revert), a report `docs/audits/<date>-phase3-<wp>.md`, then **stop for review and human approval**. Local model output is never verification; nothing is pushed. "Opus review" marks packages whose risk is behavioral or concurrent; the rest suit a Sonnet review.

| Step | Work package | Depends on | Implement / review | Exit check |
|---|---|---|---|---|
| 0 | Baseline: offline `test-all` at `phase2-done`; freeze `legacy-parameters.json`, `specify-calls-*.txt` (unmodified `specify.ps1` with the AC-303 mocks), the telemetry header and the scan output; owner decides OQ-301 to OQ-313 | Spec approved | owner | recorded |
| 1 | **WP-3A Telemetry lock** (FR-311c), writer cases, child-process stress, mutation proof | 0 | Sonnet / **Opus** (mutex semantics) | AC-317 |
| 2 | **WP-3B Cleanup**: FR-314 (one commit), then FR-315 (one commit, move only, a script compares case names) | 0 | Sonnet / Sonnet | AC-322, AC-323 |
| 3 | **WP-3C Manifest library**: ids, run directory, atomic write and read, derived status, schema, validator, fixtures, `.gitignore`; no workflow script changes | 0 | Sonnet / **Opus** (schema, invariants) | AC-308, AC-309 |
| 4 | **WP-3D Workflow extraction**: `workflow.ps1`, `specify.ps1` as a wrapper, `-Profile` | 2 | Sonnet / **Opus** (behavior preserved) | AC-302, AC-304 |
| 5 | **WP-3E CLI skeleton and read-only commands**, unsupported stages, exit codes, `-Json` | 3 | Sonnet / Sonnet | AC-301, AC-312, AC-314, AC-315, AC-326 |
| 6 | **WP-3F Workflow commands**: target layout, checkpoints, correlation, failure matrix, artifact lock, `concurrent_run_detected`, README | 1, 3, 4, 5 | Sonnet / **Opus** (core of the phase) | AC-303 to AC-307, AC-310 to AC-313, AC-316, AC-321, AC-327 |
| 7 | **WP-3G Context in every stage**: reviewer and reviser `-ContextFile`, builders, `scan` and `context`, `.ai-harness\` exclusion, include rejections | 2, 6 | Sonnet / **Opus** (prompts, goldens) | AC-319, AC-320 |
| 8 | **WP-3H Resume** (FR-312); can be cut with no effect on the rest | 6 | Sonnet / Sonnet | AC-318 |
| 9 | Final QA by an independent session, human approval, tag `phase3-done` | 1 to 8 | **Opus** | AC-301 to AC-327 |

**The live validation WP-2E is a separate activity, run by the owner when Ollama is available (Phase 2 Execution Order, step 8). No package above depends on it, and no criterion of this phase needs a live model.** What waits for it is only recorded here: `charsPerToken` calibration, `budgetMode` and context windows (so the derived context budget, OQ-312), real durations and retries, `possible_prompt_truncation` against a real server, and `abandoned` detection during a real long call. Its benchmark precondition (DF-201) is unchanged.

## Edge Cases

- **Start time unreadable** (another user's process): `status` shows `abandoned` only when the pid does not exist; otherwise `running` with `liveness_unverified` in its output (not in the manifest). A reused pid is caught by the start-time comparison.
- **Same name, different targets:** the artifact lock includes the target path, so they never block each other. **`-TargetPath` equal to the harness root:** allowed; artifacts go to `<harness>\.ai-harness\specs\`, never to `<harness>\specs\`.
- **No telemetry file at `stage_begin`:** the offset is 0. **A stage killed after writing its output and before the checkpoint:** `-Resume` runs it again.
- **Line endings:** hashes are over bytes; `inputs\task.md` is the task as UTF-8 without BOM.
- **A throwing stage hook:** `internal_error`, the run stops and the manifest is still finalized.

## Dependencies

- Phase 2 complete (tag `phase2-done`). Phase 4 and Phase 5 depend on this phase; Phase 5 adds `develop`.
- Runtime: Windows PowerShell 5.1; read-only `git` is optional. No Ollama, network or new tools for any acceptance criterion of this phase.
- Test infrastructure: the `test-all.ps1` contract, sandbox and tripwire; the engine fake host and four guards (moved to `tests\lib\engine-fake-host.ps1` by FR-315).

## Risks and Rollback

| ID | Risk | Mitigation |
|---|---|---|
| RK-301 | The extraction changes `specify.ps1` behavior. | AC-302, AC-303 (same recorded calls, legacy suites unchanged); WP-3D has an Opus review. |
| RK-302 | Byte-offset correlation misattributes or misses a record. | Filter by `run_id`; the lock keeps lines whole; a missing record is a warning, never a guess (AC-310). |
| RK-303 | Mutex semantics (abandonment, `Global\` refused) are wrong. | AC-316, AC-317 with killed holders; Opus review of WP-3A. |
| RK-304 | The schema interpreter drifts from the schema file. | One source: the validator reads the file (AC-309). |
| RK-305 | A resume reuses a stale output. | Reuse only with an equal request and a matching SHA-256 (AC-318). |
| RK-306 | The context part changes reviewer behavior. | It exists only with `-ContextFile`; the no-context path keeps the goldens (AC-319). |

**Rollback.** One or two commits per package; revert in reverse order. Legacy scripts and telemetry formats never change shape. WP-3B's commits are independent. `runs\` can be deleted at any time.

## Open Questions

Each has a RECOMMENDATION; none is decided. Alternatives are in `docs/audits/2026-11-25-phase3-spec-notes.md`.

- **OQ-301 (O-07):** is `-TargetPath` required? RECOMMENDATION: yes for every command that writes an artifact, no current-folder default.
- **OQ-302 (O-11):** built-in `-Background` and `cancel`? RECOMMENDATION: no. Rely on Claude Code's background execution; the CLI is short-lived, checkpoints, reports `status` and can `-Resume`. Build a detached mode only if that proves insufficient (pid and start time are already recorded).
- **OQ-303:** include `-Resume`? RECOMMENDATION: yes, as the last package (WP-3H); it can be cut alone.
- **OQ-304:** telemetry columns (`workflow_id`, `stage`, `task_sha256`, `output_path`, `target_root`; Phase 2 OQ-205) and `budget.reservedOutputTokens`? RECOMMENDATION: add none; join by `run_id` and `call_id`. Another CSV header would force another file split and an engine change.
- **OQ-305:** manifest category names. RECOMMENDATION: the roadmap names, mapped from the engine's (Phase 2 OQ-212), engine name kept in `error.engineCategory`.
- **OQ-306:** `develop` now? RECOMMENDATION: exit 4 `planned_phase_5`; Phase 5 FR-503 defines it.
- **OQ-307:** should legacy `specify.ps1` write a run directory and manifest? RECOMMENDATION: no (unchanged behavior); an opt-in switch later.
- **OQ-308:** an unknown command. RECOMMENDATION: exit 2 `invalid_arguments`; exit 4 is for unsupported stages (O-18).
- **OQ-309:** `console.log`, `prompts\`, `outputs\*.raw.md` (O-12). RECOMMENDATION: defer; they need a capture hook in the scripts or the engine.
- **OQ-310:** exit code of a failed structural validation. RECOMMENDATION: CLI 1 (XR-10), legacy 2.
- **OQ-311:** concurrency policy. RECOMMENDATION: same target and name is refused (`artifact_in_use`); a shared Ollama URL only warns (R-07); `Global\` mutexes with a `Local\` fallback.
- **OQ-312:** derived context-file budget (XR-03). RECOMMENDATION: defer until after WP-2E; the engine's check already covers the prompt with context.
- **OQ-313:** the shared sensitive-file policy (XR-04). RECOMMENDATION: defer; no Phase 3 criterion needs it, and merging two scripts' lists is outside the smallest change.

## Assumptions

- **A-301:** the manifest `schemaVersion` 1 is its own version, independent of the registry's.
- **A-302:** stages of one run run one after another in one process, so a stage's records are the new lines with the run's `run_id`.
- **A-303:** a process of the same user can be queried with `Get-Process` for its id and start time.
- **A-304:** an ordinary user can create a `Global\` mutex in the same logon session; otherwise the `Local\` fallback applies.
- **A-305:** Claude Code's `run_in_background` keeps the process attached and returns its stdout and exit code; a killed session is handled by `status` and `-Resume`.
- **A-306:** `build-context.ps1` keeps its defaults (`MaxTotalChars` 24000, `MaxFileBytes` 20000).

## Not Verified

- Anything against a real Ollama: real durations, retries, `abandoned` detection during a real long call, real context sizes (WP-2E).
- Behavior with a process or a mutex owned by another Windows user or session.
- Antivirus or indexer interference with `File.Replace` on `manifest.json`.
- `-Resume` after a power loss in the middle of a write (only a killed process is tested).
- Windows PowerShell 5.1 builds and cultures other than the ones used in Phase 2.
- That Claude Code's current background mechanism behaves as A-305 states; Phase 4 checks it (R-12).
