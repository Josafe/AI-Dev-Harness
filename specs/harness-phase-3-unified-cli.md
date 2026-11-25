# Specification

**Title:** Harness modernization, Phase 3: unified CLI, run manifests and safe concurrent runs
**Status:** Draft, revision 2 (2026-11-26). Applies `docs/audits/2026-11-25-phase3-spec-review.md` and the owner decisions D-301 to D-314; finding table: `docs/audits/2026-11-26-phase3-spec-rev2-notes.md`. Not approved. Choices beyond the roadmap and the decisions are Open Questions with a RECOMMENDATION. Phases 4 to 6 are not designed.
**Applies to:** AI-Dev-Harness, baseline tag `phase2-calibrated` (`ec05225`, Phase 2 spec revision 3.5).
**IDs:** `FR-3nn`, `NFR-3nn`, `AC-3nn`, `D-3nn` (owner decisions), `OQ-3nn`, `RK-3nn`, `A-3nn`. "Phase 2 FR-216" is `specs/harness-phase-2-shared-engine.md`; XR-nn, O-nn, R-nn and "roadmap FR-3nn" are `docs/roadmap/modernization-roadmap.md`; "WP-2E s5" is a section of `docs/audits/2026-11-25-phase2-wp2e-resume.md`. FR-312 and AC-318 are cut (D-301); the numbers are not reused.

## Goal

One entry point, `scripts/harness.ps1`, over the existing scripts. Every workflow run gets a run directory and a validated manifest and ends with a stable exit code. A run is a short-lived foreground process that checkpoints its manifest; background execution is Claude Code's. Concurrent runs become safe. The WP-2E findings become checkable behavior: a truncation signal that works, a load failure that is not retried, a `doctor` preflight. The deprecated wrappers go and the largest suite is split. Legacy scripts keep their interfaces. Two stages with a gate: **3A** (infrastructure independent of the CLI design) and **3B** (the CLI).

## Context

**Current behavior** (FACT, at `phase2-calibrated`; WP-2E s5, s9, s13):

- `specify.ps1` (382 lines) runs four scripts with `&` (`-RunnerScript`, `-ValidatorScript`, `-ReviewerScript`, `-ReviserScript`), writes `<harness>\specs\<Name>.md`, `.review.md`, `.revised-vN.md`, `.revised-vN.review.md`, exits 0 (PASS), 1 (FAIL after 3 revisions), 2 (error), 3 (insufficient input). It has no `-Profile`, passes no `-ContextFile`, never resets `$LASTEXITCODE`.
- `run-agent.ps1` prints its answer to the success stream; `revise-spec.ps1` **throws** on failure; `review-spec.ps1` exits 0, 1 or 2; `scan-repository.ps1` and `build-context.ps1` throw and set no exit code. The telemetry writer has no lock (`Add-Content`): overlapping processes lose records.
- Nine `AC-216` cases of `test-engine-callsites.ps1` (2,081 lines, 160 cases, about 164 s) use or assert the unused wrappers `Invoke-HarnessGenerate` and `Test-HarnessModelAvailable` (lines 1192, 1211, 1225, 1233, 1243, 1254, 1266, 1276, 2044), with a wrapper driver (about lines 335 to 375), a `Write-Host` exemption and a pinned list in `test-agent-prompts.ps1`.
- Live (WP-2E): Ollama **truncates an overlong prompt silently**, the shipped `possible_prompt_truncation` rule fires on healthy prompts and no script prints it, and CUDA model-load faults were retried by the 5 s retry with half success (FR-316, FR-317).

**Owner decisions** (2026-11-26; applied, not reopened):

- **D-301:** `-Resume` (FR-312, AC-318, WP-3H of revision 1) is cut and deferred; a killed run is started again.
- **D-302:** no `-Background`, `cancel` or `console.log`; rely on Claude Code's background execution. **Roadmap deviation:** XR-06 detached runs and cancel and roadmap Phase 3 AC-302 leave Phase 3; the XR-04 shared sensitive-pattern policy and the XR-03 derived context budget are deferred (OQ-322).
- **D-303:** `develop` exits 4 until Phase 5. Legacy `specify.ps1` writes no manifest and keeps its exit codes.
- **D-304:** two stages in one spec: 3A (telemetry lock, wrapper deletion, suite split, engine signals), a gate, 3B (the CLI).
- **D-305** names and overwrite (FR-319); **D-306** `-Include` is one comma-separated string; **D-307** a target equal to the harness root is refused and targets, `.ai-harness`, `specs` are not reparse points; **D-308** telemetry mutex plus `FileStream` append, no `Local\` fallback (FR-311); **D-309** run claim and `File.Replace` manifest (FR-304, FR-305); **D-310** no stage-script options, `$args` parser (FR-302); **D-311** stage contract and outcome table (FR-303, FR-308); **D-312** schema enums equal XR-08 (FR-305); **D-313** WP-2E findings are FR-316 to FR-318, the model-switch policy is OQ-317; **D-314** kept: telemetry join by `run_id` and `call_id` without new columns, no job daemon, wrappers deleted in 3A, suite split by script.
**Other deviations:** CLI exit 1 for a failed validation against legacy 2 (XR-01); categories `artifact_exists`, `artifact_in_use`, `stage_failed`, `model_load_failed` added; no `prompts\` or `outputs\*.raw.md`. **Hooks for Phase 4** (not designed): exit codes, `RUN_ID:` and `MANIFEST:` lines, `-Json`, a caller `-RunId`, `trust`, empty `verification[]`, `process.background`. **Deferred:** D-301 and D-302 items; telemetry columns; run pruning `[O]`; a model-switch policy; `num_ctx` in the warm-up key, a run-time `charsPerToken`, a load-failure telemetry column (WP-2E s13.6 to 13.8).

## Functional Requirements

### FR-301 - One entry point and its commands

**Source:** USER

`scripts/harness.ps1 <command> [options]`:

| Command | Does | Run and manifest |
|---|---|---|
| `specify` | the workflow of `specify.ps1` (FR-303); optional `-LoadCheck` (FR-318) | yes |
| `review`, `revise` | one `review-spec.ps1` call; one `revise-spec.ps1` call plus validation (FR-319) | yes |
| `scan`, `context` | `scan-repository.ps1`; scan plus `build-context.ps1`, into the run directory (FR-313) | yes |
| `validate` | `validate-spec.ps1 -SpecFile -Mode`; exit code passed through (0, 1, 3); a throw is 2 | no |
| `status`, `list`, `stages`, `config`, `doctor` | read-only (FR-309, FR-318) | no |
| `architecture`, `plan`, `qa`, `code-review`, `develop` | unsupported, exit 4 (FR-308) | yes |

Stages run in the CLI's process with `&`; the only other processes are read-only `git` (`--no-optional-locks`) and, for `doctor`, `nvidia-smi`. An argument error never creates a manifest.

### FR-302 - Parameters: a literal table parsed by the script

**Source:** USER

`harness.ps1` has no `param` block, `[CmdletBinding()]`, `[Parameter()]` or validation attribute, so PowerShell never rejects an input first (localized text, exit 1). It parses `$args` against this table. An option is `-Name value` (the next element, whatever it starts with); `-Json`, `-Overwrite`, `-LoadCheck` are switches. Names match case-insensitively and must be complete.

| Command | Required | Optional |
|---|---|---|
| `specify` | `-TargetPath -Name`, one of `-Task`/`-TaskFile` | `-Mode -Include -Model -Profile -RunId -Overwrite -LoadCheck` |
| `review` | `-TargetPath -Name`, one of `-Task`/`-TaskFile` | `-Revision -Mode -Model -Profile -RunId -Overwrite` |
| `revise` | `-TargetPath -Name -Revision`, one of `-Task`/`-TaskFile` | `-Mode -Model -Profile -RunId -Overwrite` |
| `scan` | `-TargetPath` | `-RunId` |
| `context` | `-TargetPath -Include` | `-RunId` |
| `validate` | `-SpecFile` | `-Mode` |
| `status` | `-RunId` | `-Json` |
| `list` | none | `-Last -Json` |
| `stages` | none | `-Json` |
| `config` | none | `-Agent -Model -Profile -Json` |
| `doctor` | none | `-Json -LoadCheck` |
| `architecture plan qa code-review develop` | none | `-TargetPath -RunId` |

Values: `-Mode` is `requirements`, `baseline` or `documentation` exactly (default `requirements`); `-Revision` digits (default 0 for `review`, at least 1 for `revise`); `-Last` a positive integer; exactly one of `-Task`/`-TaskFile` (UTF-8, read with .NET); `-Model` with `-Profile` invalid; `-Name` per FR-319, `-RunId` per FR-304, `-Include` per FR-313. `-TargetPath` must exist, be a folder, not be a reparse point and not equal or contain the harness root (OQ-314); it is resolved against the PowerShell location with `GetFullPath`, trailing separators removed, 8.3 names expanded (OQ-301: no default).

Every bad input (unknown command or option, option of another command, option without a value, duplicate, leftover positional, incomplete name, missing required option, bad value) exits **2** with the first output line `ERROR: invalid_arguments: <text>`; tests match the token only (NFR-303). The stage scripts and the hook are not options: `harness.ps1` only parses `$args` and calls `Invoke-HarnessCli -Command -Options [-StageScripts] [-Hook]` in `lib\cli.ps1`, the entry point tests use with mock stages in a child process (D-310).

### FR-303 - One shared workflow, a stage contract, an unchanged legacy front end

**Source:** USER

The loop moves to `scripts/lib/workflow.ps1` as `Invoke-SpecifyWorkflow`, used by `specify.ps1` and the CLI. It takes the four script paths, `Mode`, `Task`, `Name`, an output directory, optional `-Model` or `-Profile`, a context file, a stage hook and a `-Result` hashtable; it prints the console lines `specify.ps1` prints today, never calls `exit`, and fills `-Result` with `{ outcome, category, stage, legacyExitCode, cliExitCode }` (FR-308). `review` and `revise` call the same stage helpers under the same contract.

**Stage contract.** A stage is called as a statement and its success-stream output passes through, so the result never travels in the pipeline. `$global:LASTEXITCODE` is set to `$null` before each stage; `$null` counts as 0 except for the reviewer, where it is unexpected. A stage that **throws** is a failed stage: `stage_end` gets exit code null, and the legacy front end rethrows so the `trap` of `specify.ps1` prints and exits 2 as today. `scan-repository.ps1` and `build-context.ps1` have no exit codes: success is "no throw, and the output file exists and is not empty". The hook gets `stage_begin` (id, kind, agent, attempt) and `stage_end` (id, status, exit code, output path, verdict, reason) and uses only its parameters; a throwing hook is `internal_error`.

`specify.ps1` keeps its parameters, folder, file names, `maxRevisions` 3, exit codes and console lines, and passes no hook, run directory or context (D-303). Its only addition is an optional `-Profile`, passed to the three agent scripts only when bound.

### FR-304 - Run identity, run directory, locations

**Source:** USER

The run id is `-RunId`, else a valid `AI_HARNESS_RUN_ID`, else `<UTC yyyyMMddTHHmmssZ>-<8 lowercase hex>`. A given id matches `\A[A-Za-z0-9](?:[A-Za-z0-9_-]|\.(?!\z)){0,63}\z` and its text before the first dot is not a device name (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`, any case). An invalid environment value is ignored with the warning `invalid_run_id_env`.

`<harness>\runs\<id>\` is claimed by `CreateDirectory` and then creating `.claim` in it with `FileMode.CreateNew`; the creator owns the id. A lost claim on `-RunId` is `invalid_arguments`. `AI_HARNESS_RUN_ID` is a correlation id (it groups calls today): when its directory exists the CLI appends `-<4 lowercase hex>`, with a new suffix until the claim succeeds (at most 69 characters),, warns `run_id_env_reused` and never fails. The CLI sets `$env:AI_HARNESS_RUN_ID` to the final id for its stages and restores it in a `finally`, so telemetry `run_id` equals the manifest `runId`.

```text
<target>\.ai-harness\specs\   <Name>.md, .review.md, .revised-vN.md, .revised-vN.review.md
<harness>\runs\<id>\          .claim, manifest.json, inputs\task.md, inputs\scan.json, inputs\context.txt, replaced\
<harness>\logs\               model-calls.jsonl, .csv (unchanged)
```

In a target the harness writes only below `<target>\.ai-harness\`. `runs/` is added to `.gitignore`. `inputs\task.md` (UTF-8, no BOM) is the only place with the task text (O-14).

### FR-305 - The run manifest (XR-08)

**Source:** USER

`runs\<id>\manifest.json`: UTF-8 without BOM, `ConvertTo-Json -Depth 10`, `schemaVersion` 1. Created before the first stage (`running`, `exitCode` null), rewritten at every stage event and at the end, before the `MANIFEST:` line: write a temp file in the same folder, then `File.Replace(temp, manifest, [NullString]::Value)` (`Move` if absent), retried 50 times 20 ms apart. A reader opens with `FileShare.ReadWrite, Delete` and retries 25 times 20 ms apart on `IOException` **and** `FileNotFoundException`. Every string in the manifest comes from .NET I/O or is cast to `[string]` (`ConvertTo-Json` of a `Get-Content` string hangs).

| Field | Content |
|---|---|
| top level | `schemaVersion`, `runId`, `workflow`, `status`, `exitCode`, `createdAtUtc`, `startedAtUtc`, `endedAtUtc`, `warnings[]` (union, no duplicates), `error` |
| `harness` | `root`, `gitCommit`, `gitDirty` (null without git; `git --no-optional-locks rev-parse HEAD`, `status --porcelain`), `registrySchemaVersion`, `registrySha256`, `ollamaUrl` |
| `target`, `process` | `root`, `artifactDir` (null with no target); `pid`, `processStartUtc`, `background` (false) |
| `request` | `name`, `mode`, `maxRevisions` (3), `taskSha256`, `taskFile`, `include[]`, `revision`, `overrides {model, profile}` |
| `context` | null, or `file`, `sha256`, `chars`, `files[] {path, sha256, sizeBytes}` |
| `stages[]` | `id`, `kind`, `agent`, `attempt`, `status`, `reason`, `startedAtUtc`, `durationMs`, `exitCode`, `resolution {profile, model, modelSource, timeoutSec}`, `budget {contextWindow, estimatedPromptTokens, withinBudget}`, `callId`, `engineAttempts`, `callDurationMs`, `warnings[]`, `contextSha256`, `verdict` (`PASS`, `FAIL`, null), `output {path, sha256}`, `error {category, engineCategory, message, hint, retryable, httpStatus}` |
| `artifacts[]` | `role`, `root` (`target` or `run`), `path` (relative to it), `sha256`, `trust` |
| `verification[]` | empty (Phase 6) |

**States.** The schema enums are the XR-08 lists: run `queued`, `running`, `succeeded`, `failed`, `needs_input`, `cancelled`, `abandoned`; stage `pending`, `running`, `succeeded`, `failed`, `skipped`, `unsupported`, `cancelled`; `trust` `untrusted-draft`, `deterministic-check`, `verified-by-command`. **The CLI writes only** run `running`, `succeeded`, `failed`, `needs_input`; stage `pending`, `running`, `succeeded`, `failed`, `skipped`, `unsupported`; `trust` `untrusted-draft` (model output), `deterministic-check` (context file). `abandoned` is derived (FR-309). `kind` is `agent`, `deterministic` or `unsupported`.

**Stages.** Ids: `load-check`, `scan`, `context`, `spec-generate`, `spec-validate`, `spec-review`, `spec-revise`, `revised-validate`. `attempt` is the loop's 1-based counter (round k for `spec-review`, revision k for `spec-revise` and `revised-validate`, else 1); `engineAttempts` is the engine's HTTP attempts. A FAIL review is a `succeeded` stage with verdict `FAIL`; next-round stages are appended only after a FAIL. At the end each planned stage not reached is `skipped` with `dependency failed: <id>` or, when none failed (`registry_invalid`, `agent_not_found`, `artifact_exists`), `not reached: <category>`. `error.retryable` is true only when `engineCategory` is `http_5xx` or `transport_reset`; `error.hint` is the engine's fixed hint for `engineCategory`.

### FR-306 - Manifest schema and validator

**Source:** USER

`scripts/lib/run-manifest.schema.json` uses a documented subset of JSON Schema: `type` (a name or an array, for nullable fields), `required`, `enum`, `properties`, `items`, `pattern`, `minimum`; unknown properties are allowed; comparisons are ordinal (`-ceq`, `-ccontains`, `-cmatch`). `lib\manifest.ps1` has `Test-HarnessManifest -Manifest <object or JSON text> [-SchemaPath]` returning `{ valid, errors[] }`, errors `<path>: <code>` with the path literal as `$.stages[0].status`; codes `missing_required`, `wrong_type`, `not_in_enum`, `pattern_mismatch`, `below_minimum`, `unsupported_schema_version`, `invariant_*`. Keys, types and enums come from the schema file only. Invariants: a terminal run has `exitCode` 0 to 4 and `endedAtUtc`; `succeeded` has `exitCode` 0 and no failed stage; `failed` and `needs_input` have an `error`; (`id`, `attempt`) is unique; `artifacts[].path` is relative, without `..` or a drive. Every manifest the CLI writes is valid, after any failure too.

### FR-307 - Telemetry correlation without a telemetry change

**Source:** ASSUMPTION

The manifest joins telemetry by `run_id` (= `runId`) and `call_id`. At `stage_begin` of an agent stage the CLI notes the byte length of `logs\model-calls.jsonl`; at `stage_end` it reads the bytes appended since. Both reads hold the telemetry mutex (FR-311), open with `FileShare.ReadWrite`, retry an `IOException` and drop a leading BOM; on a lock timeout they read unlocked and add the warning `telemetry_lock_timeout`. From the parsable lines with the run's `run_id`, the last fills the stage: `callId`, `engineAttempts` (`attempts`), `callDurationMs`, `warnings` (split on `;`), `resolution`, `budget` (`withinBudget` false when `budget_exceeded` is a warning), `error.engineCategory`, `error.httpStatus`. No record: `callId` null and `telemetry_record_missing`; several: the last wins and `telemetry_multiple_records` is added.

`error.category` maps from the engine's (Phase 2 FR-211): `transport_unreachable` to `ollama_unreachable`; `http_4xx`, `http_5xx`, `transport_reset`, `transport_other` to `http_error`; `empty_response`, `thinking_budget_exhausted` to `empty_output`; `format_invalid` to `invalid_output_format`; `timeout`, `context_budget_exceeded`, `model_not_installed`, `model_load_failed` unchanged. `error.message` is the telemetry `error` column (one line, at most 500) or fixed harness wording.

### FR-308 - Exit codes, categories, outcome table, output protocol (XR-10)

**Source:** USER

Exit codes: 0 success; 1 workflow failure; 2 execution error; 3 `needs_human_input`; 4 unsupported stage. `manifest.exitCode` equals the process exit code. `error.category` is one of `invalid_arguments`, `registry_invalid`, `agent_not_found` (checked before the first stage), `ollama_unreachable`, `model_not_installed`, `model_load_failed`, `context_budget_exceeded`, `context_invalid`, `timeout`, `http_error`, `empty_output`, `invalid_output_format`, `validation_failed`, `review_failed`, `max_revisions_reached`, `needs_human_input`, `unsupported_stage`, `artifact_exists`, `artifact_in_use`, `stage_failed`, `internal_error`; `cancelled` and `abandoned` are reserved.

**Outcome table** ("record" is the stage's telemetry record, FR-307):

| Situation | Legacy | CLI | CLI category |
|---|---|---|---|
| review exit 0 | 0 | 0 | none |
| runner or reviser throws, or exits other than 0 or `$null` | 2 | 2 | from the record, else `stage_failed` |
| runner or reviser ends well, output file missing or empty | 2 | 2 | `stage_failed` |
| first validation exit 3 | 3 | 3 | `needs_human_input` (run `needs_input`) |
| first validation exit 1 | 2 | 1 | `validation_failed` |
| first validation another code or a throw | 2 | 2 | `stage_failed` |
| revised validation exit 1 or 3 | 2 | 1 | `validation_failed` |
| revised validation another code or a throw | 2 | 2 | `stage_failed` |
| review exit 2 | 2 | 2 | from the record, else `stage_failed` |
| review exit outside 0, 1, 2, `$null`, or a throw | 2 | 2 | `stage_failed` |
| review exit 0 or 1, review file missing or empty | 2 | 2 | `stage_failed` |
| FAIL after revision 3 | 1 | 1 | `max_revisions_reached` |
| `harness review`, verdict FAIL | n/a | 1 | `review_failed` |

`stage_failed` has fixed wording naming the stage and code. The five unsupported commands exit 4 with one stage of kind `unsupported`, status `unsupported`, run `failed`, category `unsupported_stage` and the message "No local agent implements '<stage>'; perform it in Claude Code or manually." The harness never simulates a stage.

**Protocol.** After argument validation and the claim, a workflow command prints `RUN_ID: <id>` and, as its last stdout line, `MANIFEST: <absolute path>`, on success and every later failure; before a nonzero exit it prints one `ERROR: <category>: <text>` line just before `MANIFEST:`. A failure before the claim prints only `ERROR:`, exits 2, writes no manifest. Failures keep partial artifacts and earlier stage records. The CLI never prompts or reads stdin. Legacy scripts keep their codes.

### FR-309 - Read-only commands and derived status

**Source:** USER

`-Json` makes a read-only command print exactly one JSON line on success; any failure prints exactly one `ERROR: <token>: <text>` line (never JSON) and exits 2, tokens `invalid_arguments`, `manifest_invalid`, `registry_invalid`, `ollama_unreachable`. `stages` lists each command and stage with `supported`, its agent and a `reason` (`no_local_agent`, `planned_phase_5`). `config [-Agent] [-Model|-Profile]` prints per file of `.ai\agents\` the record of `Resolve-HarnessExecution` (profile, model, `modelSource`, `parametersFrom`, `contextWindow`, `timeoutSec`, `reservedOutputTokens`, `think`, warnings) plus the registry warnings; it sends no request. `list [-Last N]` shows runs newest first with the derived status; an unreadable or schema-invalid manifest is `unreadable`. `status -RunId` prints `runId`, `workflow`, `recordedStatus`, `status`, `exitCode`, each stage's `id` and `status`, `warnings`, `error` and the manifest path; an unknown run is `invalid_arguments`, an unreadable manifest `manifest_invalid`. The derived status equals the recorded one, except that a recorded `running` is `abandoned` when the `pid` does not exist or its start time differs from `processStartUtc` by more than 2 s. Neither command writes; readers use the FR-305 retries.

### FR-310 - Execution model: no job daemon (D-302)

**Source:** USER

The CLI is a short-lived foreground process built to be killed at any moment: the manifest is checkpointed at every stage event, `status` tells a live run from a dead one, a caller passes `-RunId` to know the result path, a killed run is started again (D-301). There is no `-Background`, `cancel`, heartbeat or queue. A run that starts while a recorded-`running` run with a live process has the same `harness.ollamaUrl` (the 50 newest run folders are checked) records the warning `concurrent_run_detected` (R-07); nothing is queued or refused.

### FR-311 - Safe concurrent runs (DF-202, D-308, D-309)

**Source:** USER

(a) Run ids are claimed atomically (FR-304). (b) Manifest writes are atomic, both sides retry (FR-305). (c) `Write-HarnessModelTelemetry` takes the named mutex `Global\AiHarnessTelemetry-<first 16 hex of SHA-256 of the lower-cased resolved log directory path>` around its whole file section (JSONL append, CSV header decision, CSV append) and appends **each file through one `FileStream`** (`Append`, `Write`, `FileShare.ReadWrite`) with a bounded retry on `IOException` until `-LockWaitMs` (new optional parameter, default 10000) is spent, instead of `Add-Content`; the bytes equal what `Add-Content -Encoding UTF8` wrote (BOM only when the file is created, CRLF). `AbandonedMutexException` counts as acquired; the mutex is released in a `finally`; if the `Global\` name is refused or the wait runs out it prints a `Write-Warning`, writes anyway relying on the retry, and never fails the call. No `Local\` fallback; records, columns and the CSV rule are unchanged. (d) `specify`, `review` and `revise` (not `scan` and `context`, which write only under `runs\<id>\`) hold `Global\AiHarnessArtifact-<first 16 hex of SHA-256 of the lower-cased resolved target path, `|`, the lower-cased name>` for the whole run, taken without waiting before any artifact is looked at (names never alias, FR-319, so the name is the family). Held or refused: exit 2 `artifact_in_use`, no artifact touched. The OS releases it when the holder dies (`AbandonedMutexException` counts as acquired). A mutex is recursive within a thread: one run per process.

### FR-313 - Repository context in every stage (XR-03 rest, XR-04)

**Source:** USER

`-Include` is ONE string of relative paths separated by commas (a path with a comma, or an empty entry, is `context_invalid`). With it `specify` first runs `scan` (`scan-repository.ps1` on the target, to `inputs\scan.json`) and `context` (`build-context.ps1`, to `inputs\context.txt`, default limits 24000 and 20000), then passes that file as `-ContextFile` to the spec agent, reviewer and reviser. `review-spec.ps1` and `revise-spec.ps1` gain an optional `-ContextFile`; their builders gain an optional `RepositoryContext` that adds one `data` part `repository-context` after the task part (wording of `New-RunAgentPrompt`) only when bound, so without it every prompt equals the Phase 2 goldens byte for byte. The manifest records the context hash, each file's path, SHA-256 and size (computed by the CLI) and `contextSha256` on each stage that got it. The existing guards decide acceptance (absolute or rooted paths, `..`, duplicates, files not in the scan, sensitive names, extensions, reparse points, NUL bytes, size limits); a rejection is `context_invalid` before any model call. New: `scan-repository.ps1` excludes a top-level `.ai-harness\`; a target that equals or contains the harness root is refused, so `runs\` is never scanned. Not built (D-302): the derived budget and the shared sensitive-pattern policy.

### FR-314 - Delete the deprecated wrappers (DF-203)

**Source:** USER

`Invoke-HarnessGenerate` and `Test-HarnessModelAvailable` are removed from `lib\agent-exec.ps1`, with **all nine** `AC-216` cases of Context, the wrapper driver, the `Write-Host` exemption and the two pinned-list entries in `test-agent-prompts.ps1` (its NFR-203 scan then forbids `Write-Host` in the whole library), and the scan that no script names them (replaced by AC-322). This supersedes Phase 2 FR-202, AC-216 and AC-218 for these two functions only; the Phase 2 spec gets a one-line note and DF-202, DF-203 closed. These are the only authorized edits of existing assertions.

### FR-315 - Split `test-engine-callsites.ps1` by script

**Source:** USER

It becomes `test-engine-callsites-run-agent.ps1`, `-review-spec.ps1` and `-revise-spec.ps1` over one helper `tests\lib\engine-fake-host.ps1` (fake host, `New-TempHarness`, `Invoke-Case`, the four guards, assertion helpers; not named `test-*`). No case body, assertion or expected value is edited; only file and order change, and a loop that builds cases for several scripts may have its script list cut to one (the case at line 2013, which tests two scripts, goes with its first). Case names are built at run time (85 `Test-Case` sites), so the reference is the name list printed by a run of the old suite. FR-314 comes first, as its own commit. Each suite follows the `test-all.ps1` contract and runs the four guards.

### FR-316 - A prompt-truncation signal that works, and is printed (WP-2E s5, s13.5)

**Source:** FACT

**Data.** At `num_ctx` 16,384 a 19,142-token prompt of 85,957 characters was cut by the server to 8,194 tokens with HTTP 200; `prompt_eval_count` was the **cut** count and the server's `truncated` flag stayed 0. Healthy prompts measured 3.93 to 5.43 characters per token (16 prompts); the cut one 85,957 / 8,194 = 10.49. The shipped rule also fired on healthy prompts of 8,573 and 9,237 tokens.

**Rule.** After a successful response, with `promptChars` the engine's `prompt_chars` and `n` the response's `prompt_eval_count` when it is a real number above 0, the engine adds the warning `prompt_truncation_detected` when `promptChars > 7 * n` (integers). The constant 7 lies between the healthy maximum 5.43 and twice the healthy minimum 7.86 (a cut to half the window doubles the ratio); it lives in the engine, not the registry. A missing, zero, negative, non-numeric or string `n` adds nothing and never throws. `possible_prompt_truncation` keeps its rule and is documented as weak.

**Loud.** `run-agent.ps1`, `review-spec.ps1` and `revise-spec.ps1` print, after the `budget_exceeded` line, one yellow `Warning: prompt_truncation_detected (...)` or `Warning: possible_prompt_truncation (...)` line per warning present (the second says it is weak). Telemetry records both; the manifest carries both in stage and run `warnings`; the CLI prints `WARNING: <code>: <stage id>` after a stage with `prompt_truncation_detected`. The stage outcome is unchanged (OQ-316). Not verified at other window sizes; a cut all-Catalan prompt (about 2.9 characters per token) stays under 7.

### FR-317 - A model-load failure is its own category and is not retried (WP-2E s9, s13.1-13.2)

**Source:** FACT

In `Get-AgentErrorCategory` (Phase 2 FR-211), an HTTP status 500 to 599 whose Ollama JSON `error` string contains (ordinal, case-sensitive) `Load failed`, `CUDA error` or `llama-server process has terminated` is the category `model_load_failed`, `retryable` false: one attempt, no wait, no `OnRetry`. It is the one rule where the engine reads body text to pick a category (the server's text, not PowerShell's); 4xx, a non-JSON body and other 5xx are unchanged. The fixed English hint says: the model could not be loaded by the Ollama server; retrying at once does not help; restarting the Ollama server may clear it; if it comes back after days of uptime, rebooting the machine is the remedy that worked. Telemetry `error_category` is `model_load_failed`; the scripts print `Category:` and `Hint:` as for any failure; the manifest maps it to itself. The `http_5xx` and `transport_reset` hints are unchanged (OQ-318). Phase 2 NFR-202 gets a one-line note.

### FR-318 - `doctor`: preflight, and an optional load check (WP-2E s13.3)

**Source:** USER

`doctor` is read-only and never prompts. It runs `Get-HarnessRegistry` (finding `registry_invalid`), reads the version with `GET /api/version` through `Invoke-OllamaHttp` (failure: the informational finding `ollama_version_unavailable`), checks with `Test-OllamaModel` (route `/api/tags`, no `-TelemetryRoot`) that every model of `Get-HarnessRegistryModels` is installed (`model_not_installed`; Ollama down is `ollama_unreachable`), and reports free VRAM in MiB only if `nvidia-smi` resolves with `Get-Command` and `--query-gpu=memory.free --format=csv,noheader,nounits` answers within 5 s without admin rights (first line as integer; else null, no finding). Exit 0 all well; 1 a model missing or failing the load check; 2 invalid registry or Ollama unreachable. `-Json` prints `{registry, ollama {url, reachable, version}, models[], vramFreeMiB, findings[], exitCode}`.

**Load check, off by default.** `doctor -LoadCheck`, and `specify -LoadCheck` as its first stage `load-check`, send for each distinct (model, effective options) of the agents `spec`, `spec-reviewer`, `spec-reviser` one request through the new engine function `Test-OllamaModelLoad`: a body with only `model`, `options` (with `num_ctx`, so the model is not reloaded later) and `stream` false, no prompt (loads, generates nothing), the profile's `timeoutSec`, **one attempt**, no telemetry. It returns `{ loaded, category, hint, durationMs }`, classified like any call. A failed check ends `specify` before any artifact is written. It is the one exception to "doctor never generates".

### FR-319 - Spec names, overwrite policy, path safety (D-305, D-307)

**Source:** USER

A `-Name` matches `\A[A-Za-z0-9][A-Za-z0-9._-]*\z` and is not: ending in `.review`, ending in `.revised-v<digits>`, containing `.revised-v<digits>.`, ending in a dot, or having a device name (FR-304) before its first dot; else `invalid_arguments`. Legacy `specify.ps1` keeps its rule. A name's family is `<Name>.md`, `<Name>.review.md`, `<Name>.revised-vN.md`, `<Name>.revised-vN.review.md` (exact, case-insensitive).

`specify` refuses with `artifact_exists` (exit 2, after the artifact lock and before any stage; manifest written) when a family file exists in `<target>\.ai-harness\specs\`, unless `-Overwrite`, which first moves the whole family (copy then delete across volumes) to `runs\<id>\replaced\`, listed in `artifacts[]` with role `replaced`. `review -Revision N` reads `<Name>.md` (N = 0) or `<Name>.revised-vN.md` and writes its `.review.md`; `revise -Revision N` (N >= 1) reads revision N-1 and its `.review.md`, writes `<Name>.revised-vN.md`, then validates it. A missing input is `invalid_arguments` before any run exists; an existing output is `artifact_exists`, or with `-Overwrite` that file alone is moved. No free output path. `<target>`, `<target>\.ai-harness` and `<target>\.ai-harness\specs` must not be reparse points (`invalid_arguments`, no manifest); missing levels are created.

## Non-Functional Requirements

### NFR-301 - Platform and unattended use

**Source:** PROJECT

Windows PowerShell 5.1; nothing added. `harness.ps1` never prompts or reads stdin (safe in Claude Code's `run_in_background`): no `Read-Host`, `$Host.UI.Prompt*`, `pause`, `Start-Process`, `Start-Job` or HTTP cmdlet in `harness.ps1`, `lib\cli.ps1`, `lib\workflow.ps1`, `lib\manifest.ps1` (the one HTTP route stays inside `Invoke-OllamaHttp`), JSON depth at least 10, no `ConvertFrom-Json -AsHashtable`. Tests may use `Start-Process`.

### NFR-302 - Write boundaries

**Source:** USER

During any CLI command the target outside `.ai-harness\` is byte-identical (SHA-256 tripwire, `.git\index` included) and the harness root changes only in `runs\<id>\` and `logs\`. Legacy `specify.ps1` keeps its footprint: `<harness>\specs\` and, through its agent scripts, `<harness>\logs\`. Read-only commands (without `-LoadCheck`) and `validate` change no file.

### NFR-303 - Offline, side-effect-free tests

**Source:** USER

New or changed suites follow Phase 0 NFR-002 and NFR-006 and Phase 2's pattern: no Ollama or network, writes only under `TEMP`, tripwire clean, no mandatory parameters, explicit `exit`; a test that could send a request uses the engine fake host and its four guards. Assertions match only exit codes, manifest values, record fields and harness wording (`ERROR: invalid_arguments:`, `MANIFEST:`, category names, fixed hints), never text produced by PowerShell, .NET or Ollama; no expected value is computed with the code under test (hashes from `Get-FileHash`, literal tables, baselines from `phase2-calibrated`).

### NFR-304 - Backward compatibility and footprint

**Source:** USER

XR-01 holds: parameters, exit codes, console markers and output files of the eight legacy scripts (the lines of FR-316 and the category of FR-317 are the only added output); `AI_HARNESS_MODEL`, `AI_HARNESS_RUN_ID`; a v1 configuration; the 31-column telemetry; the `test-all.ps1` contract. Prompts, `.ai\*`, `AGENTS.md` and the Phase 2 goldens do not change. Only the files under "Affected Files" change.

### NFR-305 - Privacy of task text

**Source:** USER

The task text appears only in `runs\<id>\inputs\task.md` and in files the scripts already write. The manifest holds `taskSha256`; telemetry is as Phase 2 defined it (O-14).

## Acceptance Criteria

"Mock stages" are scripts passed to `Invoke-HarnessCli` (FR-302) or `Invoke-SpecifyWorkflow` (FR-303); they record their arguments under `TEMP`, may write telemetry, and are steered by environment variables. "Fake host" is the Phase 2 engine fake host with its four guards. Commands run as `powershell.exe -NoProfile -NonInteractive -File` unless "in process" is said.

### AC-301 - Dispatch and argument validation

**Source:** USER

Verifies: FR-301, FR-302.

Each FR-302 row (a literal copy is in the test) with its required options reaches its handler; the AST of `harness.ps1` has no `param` block, `[CmdletBinding()]`, `[Parameter()]` or validation attribute. Each of these exits 2, prints `ERROR: invalid_arguments:` as first stdout line and leaves `runs\` empty: no command; an unknown command or option; `-Targ`; an option of another command, without a value, or duplicated; a leftover positional (`-Include a.md b.md`); each missing required option; `-Model` with `-Profile`; both or neither of `-Task`/`-TaskFile`; `-Mode Requirements`; `-Revision abc`; `revise` without `-Revision` or with 0; `-Last 0`; a `-TargetPath` that is missing, a file, a junction, or equals or contains the harness root; a missing input spec for `review`. With `-Json`, the same line. In process, a relative `-TargetPath` resolves against the PowerShell location (set apart from the process directory) and `C:\x`, `C:\x\` give one path.

### AC-302 - The legacy interfaces are unchanged

**Source:** USER

Verifies: FR-303, NFR-304.

Parameter names, types and mandatory flags of the eight legacy scripts, read with the parser, equal `tests\fixtures\legacy-parameters.json` (captured at `phase2-calibrated` before any change) plus exactly `Profile` on `specify.ps1` and `ContextFile` on the reviewer and reviser. `test-mode-propagation.ps1`, `test-spec.ps1` and the engine call-site suites pass; `git diff phase2-calibrated` shows no changed line in the first two and no changed assertion in the third beyond FR-314, FR-315 and the fake `prompt_eval_count` values FR-316 may force (listed in the package report; no expected value changes).

### AC-303 - One workflow for both front ends

**Source:** USER

Verifies: FR-303, FR-308.

For 13 scenarios with mock stages (PASS first review; PASS after one revision; FAIL after 3 revisions; first validation exit 3; first validation exit 1; runner exit 2; reviewer exit 2; reviser exit 2; revised validation exit 1; reviewer exit 5; runner exit 0 with no output file; reviewer throws; first validation exit 2) the recorded stage calls (order and arguments, output directory replaced by a placeholder) of `specify.ps1` and of the CLI each equal `tests\fixtures\specify-calls-<scenario>.txt`, recorded by the unmodified `specify.ps1` of `phase2-calibrated` with the same mocks (the oracle is not the new code); `specify.ps1`'s stdout (harness path replaced) equals `specify-output-<scenario>.txt` frozen the same way. Exit codes in that order: legacy 0, 0, 1, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2; CLI 0, 0, 1, 3, 1, 2, 2, 2, 1, 2, 2, 2, 2.

### AC-304 - `-Profile` on `specify.ps1`

**Source:** USER

Verifies: FR-303.

With `-Profile P` bound the three agent mocks get `-Profile P` and no `-Model`; unbound, none gets `-Profile`; `-Model` with `-Profile` exits 2 before any stage call.

### AC-305 - Run id, layout and artifact locations

**Source:** USER

Verifies: FR-304.

A generated id matches `^\d{8}T\d{6}Z-[0-9a-f]{8}$`; a valid `-RunId` is used. A mock `specify` with one revision on a temporary target leaves exactly `.ai-harness\specs\<Name>.md`, `.review.md`, `.revised-v1.md`, `.revised-v1.review.md` and, under `runs\<id>\`, `.claim`, `manifest.json`, `inputs\task.md` (bytes equal to the task). The mocks saw `AI_HARNESS_RUN_ID` equal to the id; afterwards it is restored. `.gitignore` has the line `runs/`.

### AC-306 - Write boundaries

**Source:** USER

Verifies: FR-304, NFR-302.

Around `specify` (success and failure), `review`, `revise`, `scan`, `context`, `architecture` and every read-only command, the SHA-256 listing of the target outside `.ai-harness\` (and `.git\index` of a temporary git repository target) is identical and the harness root differs only by new files in `runs\<id>\` and `logs\`. Legacy `specify.ps1` changes only `specs\` and `logs\`. Read-only commands and `validate` change no file.

### AC-307 - Manifest of a successful run

**Source:** USER

Verifies: FR-304, FR-305.

The one-revision mock `specify` manifest passes `Test-HarnessManifest`: `succeeded`, `exitCode` 0, stages `spec-generate`, `spec-validate`, `spec-review` (attempt 1, FAIL), `spec-revise`, `revised-validate`, `spec-review` (attempt 2, PASS), all `succeeded`; every `output.sha256` and artifact `sha256` equals `Get-FileHash`; model outputs are `untrusted-draft`; `verification` is empty; `process.pid` equals the pid of the child the test started and `processStartUtc` is within 2 s of its start; `taskSha256` and `registrySha256` equal the hashes of the task and config bytes. Every run, stage and `trust` value in any manifest of the suites is in the set the CLI writes.

### AC-308 - Checkpoints, atomic writes, string sources

**Source:** USER

Verifies: FR-305.

A mock stage reading `manifest.json` while it runs sees `running`, `exitCode` null, itself `running` and earlier stages finished. A writer process rewrites a manifest 200 times while a reader process reads it in a loop with the FR-305 rules: every read parses and validates, none is partial, no reader runs out of retries, the writer never fails, no temp file remains. A manifest built from a 200 KB task file is written in under 5 s (a builder that puts a `Get-Content` string in the object fails).

### AC-309 - Schema and validator

**Source:** USER

Verifies: FR-306.

A valid fixture passes. Fixtures with a missing required key (top level, stage, artifact), a wrong type, `null` in a nullable field (valid) and in another (invalid), run status `unknown`, stage status `paused`, `Failed` (case), a bad `sha256`, `schemaVersion` 2, a terminal run with null `exitCode`, a `succeeded` run with a failed stage, a failed run with no `error`, a duplicate (`id`, `attempt`) and an absolute artifact path each fail with the expected code at the expected literal path. The accepted run statuses (7), stage statuses (7) and `trust` values (3) equal the literal XR-08 lists in the test; changing one enum value in a temporary schema copy changes the verdict for the same manifest.

### AC-310 - Telemetry correlation

**Source:** ASSUMPTION

Verifies: FR-307, NFR-304.

Mock stages each write one record with set values (call id, 2 attempts, `budget_exceeded`, a category, a duration); the stage carries the same `callId`, `engineAttempts` 2, `warnings`, `callDurationMs`, `resolution`, `withinBudget` false and, on failure, `error.engineCategory` and `error.httpStatus`. `error.category` for each of the 12 engine categories (Phase 2's 11 and `model_load_failed`) equals the literal table of FR-307. No record: `callId` null and `telemetry_record_missing` in stage and run; two records: the last wins plus `telemetry_multiple_records`; a record of another `run_id` is ignored; run `warnings` has no duplicates; a JSONL with a leading BOM is read. The first line of `model-calls.csv` equals the 31-column header frozen from `phase2-calibrated`.

### AC-311 - Failure matrix of `specify`

**Source:** USER

Verifies: FR-305, FR-308.

Each injected failure gives the exit code and category below, a valid manifest, earlier stages and artifacts kept, the failing stage `failed` and each planned later stage `skipped` with `dependency failed: <id>`. Runner exit 2 with a record of `http_5xx`: 2 `http_error`; `timeout`: `timeout`; `empty_response`: `empty_output`; `model_load_failed`: `model_load_failed` with `retryable` false and `error.hint` containing "Restarting the Ollama server" and "rebooting the machine"; reviewer `format_invalid`: `invalid_output_format`; `transport_unreachable`: `ollama_unreachable`; `model_not_installed` and `context_budget_exceeded`: same name; a stage exit 2 with no record: `stage_failed`; a reviser that throws: the record's category, else `stage_failed`; every other row of the FR-308 table with its CLI exit and category. Missing `.ai\agents\spec.md` and an invalid registry: 2 `agent_not_found` and `registry_invalid`, no stage ran, planned stages `skipped` with `not reached: <category>`. `specify -LoadCheck` with a mock load check failing as `model_load_failed`: 2, no artifact written, later stages skipped.

### AC-312 - Unsupported stages

**Source:** USER

Verifies: FR-308, FR-309.

The five unsupported commands each exit 4 with one stage `unsupported`, run `failed`, `unsupported_stage` and the FR-308 message with the stage name; no stage script is called and the fake host records no request. `stages -Json` lists them with `supported` false and `specify`, `review`, `revise`, `scan`, `context`, `validate` with true.

### AC-313 - Output protocol

**Source:** USER

Verifies: FR-308.

For success and each of exit 1, 2, 3, 4 the first line after validation is `RUN_ID: <id>`, the last stdout line is `MANIFEST: <absolute path>`, a nonzero exit prints one `ERROR: <category>:` line just before it, and the manifest exists, validates and holds that exit code. A bad `-RunId` prints one `ERROR: invalid_arguments:` line, exits 2 and creates nothing under `runs\`.

### AC-314 - `config`, `stages` and `-Json`

**Source:** USER

Verifies: FR-309.

`config -Json` on `config-v2-current.json` gives per agent the profile, model, `modelSource`, `timeoutSec` and `contextWindow` of a literal table, also with `-Profile`, `-Model` and `AI_HARNESS_MODEL`; the fake host records no request. Every `-Json` output is one parsable line; a failing read-only command under `-Json` prints one `ERROR:` line.

### AC-315 - `status`, `list` and derived status

**Source:** USER

Verifies: FR-309.

A run whose mock stage sleeps (handshake by an event file) is `running` while its process lives; after the test kills it `status` shows `abandoned` with `recordedStatus` `running`. A manifest edited to the test's own live pid with a `processStartUtc` over 2 s off, or to a pid that does not exist, shows `abandoned`. A finished run shows its recorded status. `list -Last 2` returns the two newest in order; a corrupt manifest is listed `unreadable` and `status` on it exits 2 `manifest_invalid`. The run directory has the same SHA-256 listing before and after both commands.

### AC-316 - Concurrent runs

**Source:** USER

Verifies: FR-310, FR-311.

Two `specify` runs with different names on one target, each mock waiting for the other's start event file, both exit 0 with valid manifests and different ids; the telemetry file holds exactly the expected records with the right `run_id`. Two runs with the same target and name, the first held at an event file: the second exits 2 `artifact_in_use` and changes nothing under `.ai-harness\`; after the holder is killed a third succeeds. A relative and an absolute spelling, a trailing backslash and (where 8.3 names exist) a short-name alias of one target give the same lock. A live run with the same `harness.ollamaUrl` recorded `running` gives the later run `concurrent_run_detected`, and it succeeds. A `Global\` name the process may not open gives `artifact_in_use`. The test proves exclusion only for the overlap it builds.

### AC-317 - Telemetry writer under overlap

**Source:** USER

Verifies: FR-311.

Four child processes each write 40 records (5 ms pause) to one temporary root: the JSONL has exactly 160 parsable lines with 160 distinct `call_id`; the CSV has 160 rows and one header. Two writers (40 each) that read the JSONL with the FR-307 rules after every write, plus a third process reading in a loop, lose no record (80). A new JSONL starts with a BOM and later appends add none, as `Add-Content -Encoding UTF8` did at `phase2-calibrated`. A writer with `-LockWaitMs` 300 against a child holding the mutex writes after the wait, prints a warning and exits 0. A holder killed while holding it does not block the next writer. The package report records that the same stress with the lock disabled (temporary edit, hash-checked revert) loses records.

### AC-319 - Context in every stage

**Source:** USER

Verifies: FR-313.

With `-Include "a.md,b.md"`, `scan` and `context` precede `spec-generate`; the runner, reviewer and reviser mocks all get `-ContextFile` with `runs\<id>\inputs\context.txt`; `context.sha256` and each `files[].sha256` equal `Get-FileHash`; every agent stage has that `contextSha256`; without `-Include` no context stage runs and no `-ContextFile` is passed. On the fake host with the real scripts each request prompt contains the file text; without a context file the request bodies equal the Phase 2 goldens byte for byte; with one, the parts list is the no-context list plus one `data` part `repository-context` after the task part, whose text equals what `New-RunAgentPrompt` builds for the same string. `scan` and `context` alone leave `scan.json` (and `context.txt`) in the run directory and exit 0.

### AC-320 - Include rejections and the `.ai-harness\` exclusion

**Source:** USER

Verifies: FR-313, NFR-304.

Each of these `-Include` values exits 2 `context_invalid` before any model call, stage `context` failed, later stages skipped: an absolute path, a rooted path, `..`, a duplicate, a file not in the scan, `.env`, a `.pem` file, an unsupported extension, a file over 20000 bytes, a set over 24000 characters, a junction (if it can be created), a file below `.ai-harness\`, an empty entry, a path with a comma. `scan-repository.ps1` leaves `.ai-harness\` out; for a tree without it the output equals the frozen output of `phase2-calibrated` after `scannedAtUtc` and `rootPath` are replaced by a placeholder, byte for byte.

### AC-321 - Real scripts end to end

**Source:** USER

Verifies: FR-303, FR-307, FR-316, FR-317.

On the fake host with the real scripts: one `harness specify` run (spec, validation, one FAIL review, one revision, PASS) has stage `callId`, `resolution` and `engineAttempts` equal to its telemetry records (one per agent stage); `specify.ps1` in process with output captured prints the same lines as at `phase2-calibrated`; a 500 on the reviewer exits 2 `http_error` with `engineCategory` `http_5xx`; a 500 on the **reviser** (which throws) exits 2 `http_error`, stage `spec-revise` failed, not `internal_error`; a 500 with a `CUDA error` body exits 2 `model_load_failed` after one attempt; a reviewer answer with `prompt_eval_count` 1 gives stage warnings with `prompt_truncation_detected`, the printed `WARNING: prompt_truncation_detected:` line and an unchanged outcome; a real `scan` is a succeeded stage and a real `build-context` rejecting an include a failed one. The fake recorded only `http://127.0.0.1:9/` routes.

### AC-322 - The wrappers are gone

**Source:** USER

Verifies: FR-314.

The syntax tree of `lib\agent-exec.ps1` defines neither wrapper; after dot-sourcing the three libraries `Get-Command` finds neither; no file under `scripts\` or `tests\` contains either name (built from fragments in the test); the nine wrapper cases and the driver are gone; the NFR-203 scan of `test-agent-prompts.ps1` has no function exemption and finds no `Write-Host` in the library; the pinned list equals Phase 2's minus the two names; the other AC-216 criteria pass.

### AC-323 - The suite split

**Source:** USER

Verifies: FR-315.

`test-engine-callsites.ps1` is gone; the three suites and the helper exist; `test-all.ps1` discovers the three and not the helper; each parses, has no mandatory parameter, ends with `exit`, passes with the four guards and runs under 300 s. The union of their case names equals `tests\fixtures\engine-callsites-cases.txt`, the names printed by a run of the old suite at the commit before the split (minus the nine wrapper cases when FR-314 is done first), and the counts add up.

### AC-324 - Full offline regression and determinism

**Source:** PROJECT

Verifies: NFR-301, NFR-303.

`scripts\test-all.ps1` offline, run twice: every suite PASS except the live one (SKIPPED), tripwire clean, no FAIL, the two logs equal once times are removed. `test-syntax.ps1` parses every new file. A static scan finds none of the NFR-301 commands in `harness.ps1`, `lib\cli.ps1`, `lib\workflow.ps1`, `lib\manifest.ps1`, and no `.Exception.Message` in an assertion of a new suite.

### AC-325 - Footprint

**Source:** USER

Verifies: NFR-304.

`git diff --name-status phase2-calibrated` of the final tree lists only the files of "Affected Files" and `docs/audits/*phase3*`; none of `.ai\`, `AGENTS.md`, `tests\golden\` or a Phase 0 to 2 fixture; the case counts of the unchanged suites equal their Phase 2 counts.

### AC-326 - Unattended behavior

**Source:** PROJECT

Verifies: NFR-301.

Every command runs as `powershell.exe -NoProfile -NonInteractive` with stdin from an empty stream and ends within its test limit with the exit codes above.

### AC-327 - Task text stays out of the manifest and telemetry

**Source:** USER

Verifies: NFR-305.

A task with a unique marker leaves the marker in `inputs\task.md` and in no other file under `runs\<id>\` nor any line of `logs\model-calls.jsonl` and `.csv` the run wrote.

### AC-328 - Names, overwrite, path safety

**Source:** USER

Verifies: FR-319.

`-Name` values `a.review`, `a.revised-v1`, `a.revised-v12.x`, `a.`, `CON`, `nul.txt`, `.a`, `a b` and `a` plus a newline exit 2 `invalid_arguments:` before any run; `a.revised-vx`, `a.b-c_d`, `review` are accepted. With each of `<Name>.md`, `.review.md`, `.revised-v1.md`, `.revised-v2.review.md` present, `specify` exits 2 `artifact_exists`, no stage runs, the files keep their SHA-256, the manifest is valid; another name's files do not count. With `-Overwrite` the family moves to `runs\<id>\replaced\` with the same bytes, `artifacts[]` lists it with role `replaced`, and the run writes the four files. A junction as `.ai-harness` or `specs` exits 2 `invalid_arguments:`, nothing written through it.

### AC-329 - Run id grammar and claim

**Source:** USER

Verifies: FR-304.

`-RunId` values `abc` plus a newline, `CON`, `con.x`, `abc.`, `-a`, `a/b`, `..`, a 65-character id and an existing id exit 2 `invalid_arguments:` and add nothing under `runs\`; a 64-character id, `a.b` and `A_b-1` are accepted. Four processes claiming the same 200 ids give exactly 200 winners. An invalid `AI_HARNESS_RUN_ID` is ignored with `invalid_run_id_env`; one whose directory exists gives `<env>-<4 hex>` with `run_id_env_reused`, exit 0, and telemetry `run_id` equal to the manifest `runId`.

### AC-330 - The stage contract

**Source:** USER

Verifies: FR-303.

In process, through the library entry point with mock stages: a stage that writes its answer to the success stream and exits 0 leaves that text, and nothing else, in the captured output, and `-Result.outcome` is `passed`; with `$global:LASTEXITCODE` preset to 7 a mock validator that sets no code succeeds, and each stage has one `stage_end`; a stage that throws gives one `stage_end` (status `failed`, exit code null) and, through `specify.ps1`, exit 2 with the same two failure lines as at `phase2-calibrated`, through the CLI exit 2 `stage_failed`; real `scan-repository.ps1` and `build-context.ps1` succeed with no exit code and a stale `$LASTEXITCODE`, and fail when they throw or the output file is missing; a throwing hook gives `internal_error` and a finalized manifest.

### AC-331 - Prompt-truncation signal

**Source:** FACT

Verifies: FR-316.

Through `Invoke-AgentModel` on the fake host with C 16,384, R 8,192, a system plus prompt of exactly `promptChars` characters and a response with `prompt_eval_count` `n`, the warnings are (literal; `old` = `possible_prompt_truncation`, `new` = `prompt_truncation_detected`): 85,957 / 8,194: old and new (the live truncation); 41,770 / 8,573 and 44,784 / 9,237: old only (the live false positives); 26,431 / 4,986, 29,247 / 5,384, 14,776 / 3,116 and 22,123 / 5,627 (Catalan): none; 7,000 / 1,000: none; 7,001 / 1,000: new; `n` absent, 0, -1, `"8194"` or NaN: no new warning, no throw. The telemetry `warnings` column holds the same codes. On the fake host `run-agent.ps1`, `review-spec.ps1` and `revise-spec.ps1` each print a line starting `Warning: prompt_truncation_detected` when answered with `n` 1, and none when answered with `n` = `prompt_chars` / 5 (integer division, `prompt_chars` read from the telemetry record of the first call).

### AC-332 - Model-load failure

**Source:** FACT

Verifies: FR-317.

On the fake host, one attempt and no sleep for: 500 `{"error":"llama-server process has terminated: exit status 0xc0000409"}`; 500 `{"error":"... Load failed ..."}`; 503 `{"error":"CUDA error: out of memory"}`; each gives `model_load_failed`, `retryable` false, `attempts` 1, telemetry `error_category` `model_load_failed`, the FR-317 hint (asserted by "Restarting the Ollama server" and "rebooting the machine"), and script exit 2 with `Category:` and `Hint:` lines. 500 `{"error":"internal server error"}` is `http_5xx` with `maxAttempts` attempts and one wait; 400 `{"error":"Load failed"}` is `http_4xx`; 500 `{"error":"load failed"}` and 500 with the plain body `Load failed` are `http_5xx`. The same rule holds for a warm-up request.

### AC-333 - `doctor` and the load check

**Source:** USER

Verifies: FR-318.

`doctor` on the fake host: all models listed and a version answered gives 0 and the version; one missing gives 1 `model_not_installed`; connection refused gives 2 `ollama_unreachable`; an invalid registry gives 2 `registry_invalid`; no `/api/version` gives 0 and `ollama_version_unavailable`; only the routes `/api/tags` and `/api/version` are seen; no telemetry record, no file written. The `nvidia-smi` parser gives 11924 for `11924` and null for `N/A`, empty and `11924 MiB`; `vramFreeMiB` is null when the executable is absent. `doctor -LoadCheck` and `Test-OllamaModelLoad` send one request per distinct (model, options) pair of the three agents, whose decoded body has only `model`, `options` (`num_ctx` = the profile's `contextWindow`) and `stream`; success gives `loaded` true; a 500 `CUDA error` body gives exit 1, `model_load_failed` and one attempt; without `-LoadCheck` no `/api/generate` is sent.

### AC-334 - `review` and `revise`

**Source:** USER

Verifies: FR-301, FR-319.

On the fake host with the real scripts: `harness review -Name n -Revision 0` on an existing `n.md` writes `n.review.md` and exits 0 for PASS, 1 `review_failed` for FAIL; `revise -Revision 1` reads `n.md` and `n.review.md`, writes `n.revised-v1.md`, validates it (1 `validation_failed` when it fails) and exits 0; `review -Revision 1` and `revise -Revision 2` read and write only the files of FR-319, refuse an existing output with `artifact_exists` and move it with `-Overwrite`; each manifest has one stage of the matching id (`revise` also `revised-validate`) with the attempt of FR-305, and `request.revision` equals the option.

## Traceability Matrix

Inverse of the `Verifies:` lines above; the two must stay identical (the final QA re-derives it).

| Requirement | Acceptance criteria |
|---|---|
| FR-301 | AC-301, AC-334 |
| FR-302 | AC-301 |
| FR-303 | AC-302, AC-303, AC-304, AC-321, AC-330 |
| FR-304 | AC-305, AC-306, AC-307, AC-329 |
| FR-305 | AC-307, AC-308, AC-311 |
| FR-306 | AC-309 |
| FR-307 | AC-310, AC-321 |
| FR-308 | AC-303, AC-311, AC-312, AC-313 |
| FR-309 | AC-312, AC-314, AC-315 |
| FR-310 | AC-316 |
| FR-311 | AC-316, AC-317 |
| FR-313 | AC-319, AC-320 |
| FR-314 | AC-322 |
| FR-315 | AC-323 |
| FR-316 | AC-321, AC-331 |
| FR-317 | AC-321, AC-332 |
| FR-318 | AC-333 |
| FR-319 | AC-328, AC-334 |
| NFR-301 | AC-324, AC-326 |
| NFR-302 | AC-306 |
| NFR-303 | AC-324 |
| NFR-304 | AC-302, AC-310, AC-320, AC-325 |
| NFR-305 | AC-327 |

## Affected Files

| File | Change | Requirements |
|---|---|---|
| `scripts/harness.ps1`, `lib/cli.ps1`, `lib/workflow.ps1`, `lib/manifest.ps1`, `lib/run-manifest.schema.json` (new) | Parser; command handlers; workflow; ids, claim, manifest, status, validator; schema | FR-301 to FR-311, FR-313, FR-318, FR-319 |
| `scripts/specify.ps1`, `review-spec.ps1`, `revise-spec.ps1`, `run-agent.ps1`, `scan-repository.ps1`, `lib/agent-exec.ps1`, `lib/telemetry.ps1` (modified) | Thin front end, `-Profile`, `-ContextFile`, warning lines, exclusion; wrappers removed, truncation warning, `model_load_failed`, `Test-OllamaModelLoad`, builder context part; mutex, `FileStream`, `-LockWaitMs`, locked read | FR-303, FR-307, FR-311, FR-313 to FR-318 |
| `scripts/test-agent-prompts.ps1`, `test-agent-telemetry-v2.ps1`, `test-scan-repository.ps1` (modified); `test-engine-callsites.ps1` (deleted); three `test-engine-callsites-*` suites, `tests/lib/engine-fake-host.ps1`, `test-harness-{cli,workflow,manifest,concurrency,context,e2e}.ps1` (new); `test-all.ps1` (only if needed) | FR-314 edits; new cases; the split; Phase 3 suites | FR-311 to FR-319 |
| `tests/fixtures/`, `tests/mocks/` (new files); `.gitignore`, `README.md`, `specs/harness-phase-2-shared-engine.md` (modified); this spec, its notes, one report per package | Frozen baselines and mock stages; `runs/`, commands, exit codes; Phase 2 notes (FR-314, FR-317, DF-202, DF-203); traceability | FR-304, FR-308, FR-314, FR-317 |

Not modified: `validate-spec.ps1`, `build-context.ps1`, `benchmark-models.ps1`, `.ai/*`, `AGENTS.md`, `tests/golden/*`, Phase 0 to 2 fixtures, the roadmap (OQ-322), every other suite.

## Execution Order

One work package per unattended session. After each: `scripts/test-all.ps1` offline twice with counts, the mutation proofs its criteria name (temporary edit, hash-checked revert), a report `docs/audits/<date>-phase3-<wp>.md`, then **stop for review and approval**. Nothing is pushed; local model output is never verification. Each exit check names only criteria that can pass at that step. S = Sonnet, O = Opus (implement / review).

| Step | Package | Needs | S/O | Exit check |
|---|---|---|---|---|
| 0 | Baseline at `phase2-calibrated`: offline `test-all`; freeze `legacy-parameters.json`, `specify-calls-*`, `specify-output-*`, the telemetry header, the scan output, the old case-name list; owner decides the Open Questions | spec approved | owner | recorded |
| 1 | **A1** Telemetry mutex, `FileStream` append, locked reader | 0 | S / O | AC-317 |
| 2 | **A2** Wrapper deletion: 9 cases, driver, exemption, list (one commit) | 0 | S / S | AC-322 |
| 3 | **A3** Suite split, move only, a script compares case names | 2 | S / S | AC-323 |
| 4 | **A4** FR-316, FR-317, `Test-OllamaModelLoad`, warning lines | 3 | S / O | AC-331, AC-332, library half of AC-333 |
| gate | **Gate 3A**: offline `test-all` twice, report, owner approval, tag `phase3a-done`; the spec may be revised before 3B | 1 to 4 | owner | AC-324 as far as it applies |
| 5 | **B1** Manifest library: ids, claim, atomic write and read, derived status, schema, validator, `.gitignore` | gate | S / O | AC-309, AC-329, writer-reader half of AC-308 |
| 6 | **B2** Workflow extraction, `-Profile`, stage contract | gate | O / O | AC-304, AC-330, AC-302 without the two `ContextFile` additions |
| 7 | **B3** Parser, `stages`, `config`, `doctor`, `validate`, unsupported stages | 5 | S / S | AC-301, AC-312, AC-314, AC-333 |
| 8 | **B4** `specify`: layout, manifest, checkpoints, correlation, names, overwrite, protocol | 5, 6, 7 | O / O | AC-303, AC-305, AC-307, AC-308 (checkpoints), AC-310, AC-311, AC-313, AC-321, AC-327, AC-328 |
| 9 | **B5** `review`, `revise`, live `status` and `list` | 8 | S / O | AC-334, AC-315 |
| 10 | **B6** Artifact lock, concurrent runs | 8 | O / O | AC-316 |
| 11 | **B7** `-ContextFile` and builders of reviewer and reviser | 8 | S / O | builder part of AC-319, AC-302 complete |
| 12 | **B8** `scan`, `context`, `-Include`, exclusion | 11 | S / O | AC-319, AC-320 |
| 13 | **B9** Every command unattended, footprint, README, regression | 1 to 12 | S / S | AC-306, AC-324, AC-325, AC-326 |
| 14 | Final QA by an independent session; approval; tag `phase3-done` | all | O | AC-301 to AC-334 |

WP-2E is done (Phase 2 rev 3.5); no criterion needs a live model.

## Edge Cases

- **Start time unreadable** (another user's process): `status` shows `abandoned` only when the pid does not exist, else `running` with `liveness_unverified` in its output.
- **Same name, different targets** never block each other (the lock includes the target). **A stage killed after writing its output and before the checkpoint:** the run is `abandoned`; start it again (`-Overwrite` if its family exists; after a failure that follows `-Overwrite` the old family stays in `replaced\`).
- **No telemetry file at `stage_begin`:** offset 0. **Telemetry lock refused or timed out:** warning and an unlocked write; a record may be lost (AC-317 proves only the locked case).

## Dependencies

- Phase 2 complete and calibrated (tag `phase2-calibrated`); Phase 5 adds `develop`. Windows PowerShell 5.1; read-only `git` and `nvidia-smi` optional. No Ollama, network or new tool for any criterion.
- The `test-all.ps1` contract, sandbox and tripwire; the engine fake host (moved by FR-315, with a `/api/version` route).

## Risks and Rollback

| ID | Risk | Mitigation |
|---|---|---|
| RK-301 | The extraction changes `specify.ps1` behavior. | AC-303, AC-330; Opus on B2. |
| RK-302 | Offset correlation misattributes or misses a record. | `run_id` filter, locked read, a warning (AC-310). |
| RK-303 | Mutex semantics (abandonment, refused `Global\`) are wrong. | AC-316, AC-317 with killed holders; Opus on A1, B6. |
| RK-304 | The context part changes reviewer behavior; the schema reader drifts. | Only with `-ContextFile` (AC-319); the validator reads the file (AC-309). |
| RK-305 | The new engine rules break Phase 2 cases (a fake `prompt_eval_count` far below the prompt size); the constant 7 misfires on unusual text. | A4 lists every edited fake value, no expected value changes (AC-302); warning only (OQ-316, OQ-320). |

**Rollback.** One or two commits per package, reverted in reverse order; legacy scripts and telemetry formats keep their shape; 3A is useful alone; `runs\` can be deleted at any time.

## Open Questions

Each has a RECOMMENDATION; none is decided. Revision 2 applies them so the spec is implementable; the owner may change any.

- **OQ-301 (O-07):** is `-TargetPath` required? RECOMMENDATION: yes for commands that write artifacts, no default.
- **OQ-305:** manifest category names. RECOMMENDATION: roadmap names mapped from the engine's, engine name in `error.engineCategory`, four added names (FR-308). **OQ-308:** unknown command is exit 2 `invalid_arguments` (4 is for unsupported stages, O-18). **OQ-310:** failed validation is CLI 1 (XR-10), legacy 2 (XR-01).
- **OQ-314:** a target that CONTAINS the harness root. RECOMMENDATION: refuse it like the equal case, so `runs\` is never scanned. **OQ-315:** length limit for `-Name`. RECOMMENDATION: 64 characters (not yet in FR-319).
- **OQ-316:** effect of `prompt_truncation_detected`. RECOMMENDATION: a loud warning now; after one more live observation fail a `review` stage that has it (a PASS from a cut prompt is untrustworthy). **OQ-320:** the constant 7. RECOMMENDATION: keep it in the engine, re-check at the next calibration.
- **OQ-317:** model-switch policy. Live data (WP-2E s9, s13.4): 8 of 8 first loads succeeded with an explicit `ollama stop` and a 3 s wait between models, and 6 loads of the 35b with the 9b resident succeeded after the reboot; before it 11 of 18 such loads failed with a CUDA fault; the 35b runs at 58 % CPU / 42 % GPU, so the two models do not fit together. An explicit unload needs `keep_alive: 0`, which the Phase 2 request whitelist (FR-207) excludes: an engine change. RECOMMENDATION: not designed here; decide with more uptime data.- **OQ-318:** reword the `http_5xx` and `transport_reset` hints like the load-failure hint. RECOMMENDATION: yes, in a Phase 2 text edit (Phase 2 tests pin them).
- **OQ-319:** retention of `runs\` (task texts, absolute paths; nothing deletes them). RECOMMENDATION: document in the README; pruning stays `[O]`.
- **OQ-320:** the constant 7. RECOMMENDATION: keep it in the engine; re-check at the next calibration.
- **OQ-321:** `-LoadCheck` default. RECOMMENDATION: off; revisit if the fault returns.
- **OQ-322:** roadmap text for D-302 and D-303. RECOMMENDATION: the owner edits XR-06, XR-03, XR-04 and Phase 3 AC-302 in a separate commit.

## Assumptions

- **A-301:** manifest `schemaVersion` 1 is independent of the registry's version.
- **A-302:** the stages of a run run one after another in one process, so a stage's records are the new lines with the run's `run_id`.
- **A-303:** `Get-Process` gives the id and start time of a same-user process.
- **A-304:** an ordinary user can create a `Global\` mutex in the same logon session; if not, FR-311 reports it (no fallback).
- **A-305:** Claude Code's `run_in_background` keeps the process attached and returns stdout and the exit code.
- **A-306:** `build-context.ps1` keeps its defaults (24000, 20000).
- **A-307:** Ollama's request with a model and no prompt loads the model and generates nothing.

## Not Verified

- Anything against a real Ollama: durations, `abandoned` in a real long call, the constant 7 at other windows, other load-fault texts.
- A mutex or file owned by another Windows user or an elevated process; other cultures than es-ES; a slower disk; antivirus effects on `File.Replace`; the `File.Replace`, mutex and claim numbers are the review's experiments outside the repository; nothing here was implemented.
- `Process.StartTime` precision against 2 s; Claude Code's background behavior (A-305); `nvidia-smi` output on other drivers.