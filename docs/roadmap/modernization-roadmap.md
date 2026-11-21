# AI Development Harness: modernization roadmap

**What this is.** This document reproduces the read-only architecture audit and modernization specification produced on 2026-11-19, before Phase 0. Until now it existed only in a Claude Code session transcript. It covers:

- the investigation of a failed specification run
- cross-cutting requirements
- Phases 0–6
- implementation order
- open decisions O-01 to O-18
- risks R-01 to R-12
- open questions Q-01 to Q-06

It ends with an addendum of findings measured later the same day.

**Exported:** 2026-11-19, at repository HEAD `984eaba`.

## Status 2026-11-20

**Phase 0 is DONE** (FACT): tag `phase0-done`, commit `5ffc33f`; the spec is at Revision 4 ([specs/harness-phase-0-defect-corrections.md](../../specs/harness-phase-0-defect-corrections.md)); the work-package reports and the final QA are in [docs/audits/](../audits/). Defects D-02 and D-03 are closed.

**Phase 1 is DONE** (FACT, 2026-11-21): tag `phase1-done`, commit `d73cefd`; the spec is [specs/harness-phase-1-config-registry.md](../../specs/harness-phase-1-config-registry.md) (Implemented, Revision 3) and the final QA is [docs/audits/2026-11-20-phase1-final-qa.md](../audits/2026-11-20-phase1-final-qa.md). Verified offline only; live behavior with a real model is NOT VERIFIED. Phase 2 is next, after the platform decision gate below.

**What was learned and measured after the audit:**

| Finding | Label | Evidence |
|---|---|---|
| Ollama 0.40.13 returns the reasoning of `qwen3.5` and `qwen3.6` in a separate `thinking` field, so `stripThinking` is a no-op for these models | FACT | section 9; [docs/audits/2026-11-19-model-validation.md](../audits/2026-11-19-model-validation.md), [docs/audits/2026-11-19-model-validation-2.md](../audits/2026-11-19-model-validation-2.md) |
| Models in use now: `qwen3.5:9b` for `spec`, `qwen3.6:35b` for `spec-reviewer`, `spec-reviser` and `developer` | FACT | `.ai/config.json` at `5ffc33f` |
| A script's line endings (CRLF or LF) change the bytes of the prompts built from its here-strings. Prompt golden tests must compare files with equal line endings. | FACT | [docs/audits/2026-11-20-wp-d-implementation.md](../audits/2026-11-20-wp-d-implementation.md), sections 5 and 7 |
| `test-all.ps1` has a `ModelAgent` field: a live suite's model is resolved from the configuration, not hardcoded | FACT | [docs/audits/2026-11-20-wp-e-implementation.md](../audits/2026-11-20-wp-e-implementation.md) |
| The reviewer and reviser write telemetry and check model availability before generating (D-02 and D-03 closed) | FACT | [docs/audits/2026-11-20-wp-d-implementation.md](../audits/2026-11-20-wp-d-implementation.md), [docs/audits/2026-11-20-phase0-final-qa.md](../audits/2026-11-20-phase0-final-qa.md) |

**Decisions recorded** (DECISION, 2026-11-20): O-03, O-04, O-16 (provisional), and O-08 and O-15 done; see the table in section 7. O-07 and O-11 stay open and belong to Phase 3.

**Platform decision gate** (open, before Phase 2): stay on Windows PowerShell 5.1, or move the engine to PowerShell 7 or Python. Settle it with a spike of one or two days: the streaming call with an idle timeout (Q-05, O-10). Until then, Phase 1 stays on PowerShell 5.1.

## How to read this document

| Label | Meaning |
|---|---|
| **FACT** | Verified by the audit on 2026-11-19 against commit `2e85dbe` (code, configuration, repository logs). The scripts, tests and agent prompts are still byte-identical to `2e85dbe` (`git diff --stat 2e85dbe HEAD -- scripts tests .ai AGENTS.md README.md` shows only `.ai/config.json` changed), so code facts still hold. **Configuration facts are historical** (see below). |
| **DECISION** | Approved by the human owner. |
| **ASSUMPTION** | Not approved, and not to be treated as a requirement. |
| **UNVERIFIED** | Derived by the audit from sources outside the repository (Ollama's own logs under `%LOCALAPPDATA%\Ollama`), and not re-checked since. |
| *(no label)* | A **proposal** of the audit. Requirements in Phases 1–6 become binding only when each phase is extracted into its own specification, reviewed and approved. |

The audit also used source tags in its requirements: `USER`, an approved decision, which here becomes DECISION; `FACT`; `PROJECT`, from `AGENTS.md` or the agent contract; and `ASSUMPTION`. These tags are kept where they help.

**Scope tags:** `[M]` mandatory initial functionality, `[O]` optional later enhancement, `[X]` explicitly out of scope.

### Changes since the audit

| What changed | Status |
|---|---|
| **The model assignment.** At the audit, `spec` and `spec-reviewer` used `deepseek-r1:32b`, and `spec-reviser`, `developer` and `defaultModel` used `qwen2.5-coder:32b`. Now (`.ai/config.json` at `984eaba`): `defaultModel` and `spec` use `qwen3.5:9b`; `spec-reviewer`, `spec-reviser` and `developer` use `qwen3.6:35b`. `timeoutSec` (900) and `num_ctx` (16384) are unchanged. | FACT |
| **Phase 0** was extracted into [specs/harness-phase-0-defect-corrections.md](../../specs/harness-phase-0-defect-corrections.md), Revision 2. That spec supersedes the audit's Phase 0 section below. | FACT |

### What could not be recovered

- **The full text of the original request** that commissioned the audit. Only its context list and its list of approved decisions are reproduced (section 1).
- **The partial model output and the task text of the failed run.** The harness never logged them (FACT, from the audit).

---

## 1. Context and approved decisions (from the commissioning request)

**Limitations identified by an earlier audit** (as stated in the request):

1. Local agents cannot directly inspect files or execute tools.
2. Model assignments are duplicated across configuration, scripts and tests.
3. Prompt construction and Ollama API calls are duplicated.
4. There is no unified CLI.
5. There are no structured JSON execution manifests.
6. Repository context is not consistently available across workflows.
7. Long-running workflows require background execution.
8. Documentation validation has a verified inconsistency.
9. Reviewer and reviser calls lack consistent telemetry and model validation.

**Decisions approved before the audit** (DECISION):

- Claude Code is the primary orchestrator.
- Ollama agents remain local, specialized, and without permission to write files or run commands.
- Claude selects relevant project context and delegates appropriate tasks to local agents.
- Local outputs are untrusted drafts, never proof of successful verification.
- Claude reviews and applies changes using its permission-controlled editing capabilities.
- Target-project artifacts belong in `<target-project>/.ai-harness/`.
- Temporary execution data and technical logs remain in the Harness repository.
- Introduce a centralized configuration registry v2 that still accepts v1.
- Introduce a shared agent execution library.
- Introduce a unified PowerShell CLI and JSON manifests.
- Integrate Claude Code through `CLAUDE.md`, a `/harness` skill and a read-only reviewer subagent.
- Do not implement MCP initially.
- Promote the skill to user level only after successful project-level validation.
- Documentation mode should allow FR and AC to be `None` when appropriate, without weakening validation of functional specifications.
- Claude Code is responsible for applying reviewed changes.
- Preserve existing functionality, and avoid unnecessary dependencies.

**Decisions added when Phase 0 was specified** (DECISION, 2026-11-19):

- Do not fix the local model timeout yet.
- No registry or profiles in Phase 0.
- Move test-model centralization that needs the registry to Phase 1.
- Keep Phase 0 small, independently testable and backward-compatible.
- Phase 0 spec decisions OD-01 to OD-06 (see that spec).

---

## 2. Why the specification run failed (audit, Part 1)

These are historical findings, from when `spec` used `deepseek-r1:32b`.

**Conclusion.** The last `specify.ps1` attempt failed at Step 1 (spec generation).

- `run-agent.ps1` gave up on its HTTP request after the configured **900 s**, while `deepseek-r1:32b` was still generating. At that moment Ollama was running, the model was installed and loaded, and the prompt fit in the context window.
- **Category:** a configuration setting that didn't match the hardware's speed.
- **Ruled out:** it was not a script defect, Ollama was available, the context did not overflow, and nothing suggests an invalid task.

**Evidence** (times in CET; harness telemetry uses UTC):

| Time | Source | Evidence | Label |
|---|---|---|---|
| 15:08:26 | Ollama `server.log` | `GET /api/tags` returned 200; the runner's pre-flight check passed ([run-agent.ps1:83-97](../../scripts/run-agent.ps1#L83-L97)) | UNVERIFIED |
| 15:08:27–15:09:04 | `server.log` | `deepseek-r1:32b` loaded with 27 of 65 layers on the GPU (12 GB VRAM); KV cache 2.4 GB on CPU and 1.6 GB on GPU; `n_ctx = 16384` | UNVERIFIED |
| 15:09 | `server.log` | the prompt was 5,980 tokens, about 36% of the window | UNVERIFIED |
| 15:09–15:23 | `server.log` | generation at about 2.22 tokens/s, reaching `n_gen = 1885` | UNVERIFIED |
| 15:23:26 | `server.log` | `POST /api/generate` returned 500 after 15m0s, then `cancel task`, `truncated = 0` | UNVERIFIED |
| 14:23:26Z | last line of `logs/model-calls.jsonl` | agent `spec`, model `deepseek-r1:32b`, status `error`, **900,030 ms**, a localized .NET timeout message | FACT |
| — | `.ai/config.json` and [run-agent.ps1:149](../../scripts/run-agent.ps1#L149), [run-agent.ps1:169](../../scripts/run-agent.ps1#L169) | `timeoutSec: 900`, sent with `stream = $false`: one wall-clock limit for the whole response | FACT |
| 15:23:56 | Ollama `app.log` | Ollama shut down | UNVERIFIED |

**What the evidence shows:**

- **Timeout reached** (FACT): the request lasted 900,030 ms against a 900 s limit. The server log shows the model still producing tokens until the request was cancelled.
- **Cause of the 500** (INFERENCE by the audit, from UNVERIFIED logs): the client disconnected. The server cancelled at exactly the client's limit.
- **Not a context problem:** 5,980 prompt tokens, `truncated = 0` (UNVERIFIED).
- **Throughput** (UNVERIFIED): 900 s, minus about 38 s of model load and about 13 s of prompt processing, leaves room for about 1,880 output tokens at 2.22 tokens/s. Earlier successful runs the same day needed 1,815 tokens in 805 s and 1,097 tokens in 452 s, so a timeout was likely sooner or later.
- **The scripts behaved as designed** (FACT): `run-agent.ps1`'s `trap` returned exit 1 and wrote the telemetry error record, and [specify.ps1:128-133](../../scripts/specify.ps1#L128-L133) printed "Specification agent failed." and exited 2. No file was written.
- **Not reconstructable:** the `-Name`, the task text, `-Mode`, whether `-Model` was passed, the console output, and the partial generation. The harness keeps none of these.

**Two earlier failures that day had another cause** (UNVERIFIED, Ollama `server-1.log`):

- At 12:15 and 12:18, two `spec` calls returned HTTP 500 after about 43 s.
- The log shows `CUDA error: shared object initialization failed`, a crash of `llama-server` (`0xc0000409`), `Load failed`, and a timeout during GPU detection. Ollama restarted at 12:18:28, and the next call succeeded.
- **Category:** an Ollama/GPU runtime failure. Ollama was 0.40.13; 0.40.16 was downloaded but not installed.

**Reviewer and reviser calls are invisible in telemetry.** An earlier full workflow (spec, review FAIL, revision v1, review PASS), run for an unrelated project, shows its reviewer and reviser calls only in Ollama's own log. This confirms limitation 9: the harness writes no telemetry for those calls (FACT about the code; UNVERIFIED about the log).

**Design weaknesses that contributed** (FACT, about the code):

1. A single wall-clock timeout on a request that isn't streamed. A slow model that is still producing text can't be told apart from a hung server.
2. One global `timeoutSec` for every agent and model.
3. No cap on output tokens. Reasoning tokens use up the time budget, and `stripThinking` only removes them afterwards.
4. Telemetry records no task hash, prompt size, workflow or stage. Reviewer and reviser calls are not logged at all, and console output is not saved.
5. Error messages are stored as localized text, so automatic classification has to use the exception's type or status, not its message.

**Mitigation options**, not applied (see O-01):

- raise the timeout for reasoning models
- switch `spec` to a non-reasoning model
- use a model that fits fully in VRAM
- streaming with an idle timeout (Phase 2)

---

## 3. Conventions of the modernization specification

- **Requirement IDs are prefixed by phase.** Phase 0 uses `FR-001…`, Phase 1 `FR-101…`, Phase 2 `FR-201…`, and so on. These match the validator's patterns (`^### FR-\d+`, `^### AC-\d+`).
- **Cross-cutting requirements** use `XR-nn`, and are copied into each phase's spec when that phase is extracted.
- **One spec per phase.** Each phase is extracted into a separate spec with the 10 required headings. The whole document is far too large for the local reviewer's 16k context (R-09).

---

## 4. Cross-cutting requirements

### XR-01 Backward compatibility [M] (USER, FACT)

These interfaces must keep their parameters, exit codes and output files until a decision is made to deprecate them:

| Interface | What must be preserved |
|---|---|
| `run-agent.ps1` | `-Agent -Task -Model -OutputFile -ContextFile`; exit 0/1; writes nothing on failure |
| `specify.ps1` | `-Task -Name -Model -Mode -RunnerScript -ValidatorScript -ReviewerScript -ReviserScript`; exit 0/1/2/3; file names `<Name>.md`, `.review.md`, `.revised-vN.md`, `.revised-vN.review.md` in `<harness>/specs/`; `maxRevisions = 3` |
| `review-spec.ps1` | exit 0 (PASS), 1 (FAIL), 2 (error); the `## Status` regex contract |
| `revise-spec.ps1` | exit 0 or non-zero; output file |
| `validate-spec.ps1` | exit 0/1/3; behavior without `-Mode` stays the same |
| `scan-repository.ps1`, `build-context.ps1` | the `schemaVersion: 1` manifest and every current guard |
| `benchmark-models.ps1` | parameters and output files |
| Environment variables | `AI_HARNESS_MODEL` (overrides the model), `AI_HARNESS_RUN_ID` (sets the telemetry `run_id`) |
| Configuration | a v1 `.ai/config.json`, with no `schemaVersion`, must still load |
| Telemetry | existing `logs/model-calls.jsonl` and `.csv` are never rewritten or misaligned |
| Tests | the `test-all.ps1` contract: no mandatory parameters, an explicit `exit`, live suites SKIPPED without `-IncludeLive`, the repository tripwire |

### XR-02 How the model and profile are chosen [M from Phase 1] (USER)

**Inputs:** the agent name `A`, an explicit `-Model M`, an explicit `-Profile P` (new), `AI_HARNESS_MODEL`, and the registry.

**Rules, in order:**

1. `-Model` together with `-Profile` is an error: `invalid_arguments` (O-04).
2. With `-Model`, use `M`; a blank value is an error, as today. The parameters come from the one registered profile whose `model == M`, if exactly one matches; otherwise from A's profile, with the warning `unregistered_model_override`. Source: `explicit-model`.
3. With `-Profile`, `P` must exist; otherwise `registry_invalid`. Source: `explicit-profile`.
4. If `AI_HARNESS_MODEL` is set and not blank, treat it like rule 2. Source: `env`. This keeps the current v1 order.
5. Otherwise use `agents.<A>.profile`. Source: `agent`.
6. Otherwise use `defaults.profile`. Source: `default`.
7. Otherwise stop with an error (the same message as today).

**Further rules:**

- **An agent exists** if `.ai/agents/<A>.md` exists. A registry entry is optional.
- **A v1 configuration is converted on load:**
  - each `agentModels[A] = m` becomes the synthetic profile `legacy:<m>`
  - the global `options` and `timeoutSec` apply to every profile
  - `defaultModel` becomes `defaults.profile`
- **The resolved record** is stored in the manifest and in telemetry. It contains: agent, profile, model, `modelSource`, `parametersFrom`, contextWindow, timeoutSec, reservedOutputTokens and options.
- **Availability check:** call `/api/tags` once per process and require an exact name match. Treating `name` and `name:latest` as the same is `[O]`.

### XR-03 Context-window budget [M from Phase 2] (USER; parts ASSUMPTION)

**Definitions:**

- `C` = `profile.contextWindow`. This is the only source for `options.num_ctx`; a different `num_ctx` in a profile makes the registry invalid.
- `R` = `profile.reservedOutputTokens`. Required when `reasoning: true`; it covers thinking plus the answer.
- `S` = the safety margin, `ceil(0.10 × C)`, configurable.
- `E` = estimated prompt tokens = `ceil(chars(system + prompt) / charsPerToken)`. The default is `charsPerToken = 3.5`, configurable. This is conservative: telemetry suggests about 5 characters per token.

**Rules:**

- **Budget check.** Call only if `E + R + S ≤ C`. Otherwise stop **before** any network call with `context_budget_exceeded`, and report the characters and tokens of each section.
- **Never truncate silently.**
- **Truncation warning.** After the call, if `prompt_eval_count ≥ C − R`, record the warning `possible_prompt_truncation`. ASSUMPTION, to verify live: Ollama trims prompts that overflow `num_ctx`.
- **Context-file budgets** come from `C − R − S − (fixed prompt size)`. The fixed `MaxTotalChars = 24000` stays the default only for the legacy `build-context.ps1`.

### XR-04 Context selection and security [M] (USER, FACT)

- **Claude selects the files and the harness enforces the rules.** Claude's choice is never trusted on its own.
- **Guards kept from today's code** ([build-context.ps1:91-177](../../scripts/build-context.ps1#L91-L177)):
  - the file is listed in the scan manifest
  - no absolute or rooted paths, no `..`, no duplicates
  - excluded name patterns and an extension allowlist
  - per-file and total size limits
  - no reparse points, no NUL bytes
- **New rules:**
  - the path resolves inside the **target** root
  - `.ai-harness/` is excluded from scans by default; specs and reviews are passed as typed inputs, never as general context
  - the sensitive-file patterns, now duplicated in [scan-repository.ps1:52-59](../../scripts/scan-repository.ps1#L52-L59) and [build-context.ps1:71-78](../../scripts/build-context.ps1#L71-L78), move into one shared policy, which may be extended but never weakened
  - each included file's SHA-256 is recorded, so Phase 6 can detect stale files
- **Untrusted content.** All context is wrapped as untrusted data. All **local model output** is untrusted when it reaches Claude, because it may repeat instructions injected through repository content.
- `[O]` Heuristic scanning of file contents for secrets before inclusion.

### XR-05 Consistent telemetry [M from Phase 2]

- **One record per agent call.** Exactly one, through the shared library, for every agent including the reviewer and reviser.
- **Calls that fail before reaching the model are logged too** (budget exceeded, model unavailable, Ollama unreachable), with `model_called: false`.
- **New fields, added at the end:**
  - `schema_version: 2`, `call_id` (always new), `workflow_id` (the CLI run ID)
  - `workflow`, `stage`, `attempt`
  - `profile`, `model_source`, `timeout_sec`, `context_window`
  - `prompt_chars`, `est_prompt_tokens`
  - `task_sha256` (the task text itself goes only into the run folder, O-14)
  - `transport`, `error_category`, `http_status`
  - `output_path`, `target_root`
- **`run_id` is kept** as it is, using `AI_HARNESS_RUN_ID` when it is set.
- **Files.** JSONL gets the new keys. For CSV: if the existing header differs from the v2 header, write `model-calls.v2.csv`. Never rewrite or append misaligned rows.
- **Errors are classified** from the exception type and `WebException.Status` or the HTTP status, **never from message text**, which is localized.

### XR-06 Background execution [M from Phase 3]

- **Detached runs.** `harness … -Background` starts a separate `powershell.exe` running the same command with `-RunId`. It records the PID and process start time in the manifest, sends output to `runs/<id>/console.log`, returns immediately, and prints `MANIFEST: <path>`.
- **Liveness instead of heartbeats.**
  - A blocking PS 5.1 HTTP call cannot emit a heartbeat (a FACT about PowerShell's single pipeline thread).
  - `status` therefore checks that the PID is alive **and** that its start time matches.
  - A `running` run whose process is gone is shown as `abandoned`.
  - A heartbeat is `[O]`, and possible only with streaming.
- **Cancel.** `harness cancel -RunId` stops the process only if the PID and start time match, then marks the run `cancelled`.
- **Foreground runs** must work unattended inside Claude Code's `run_in_background`: no prompts, no stdin, defined exit codes, and the manifest always written.
- **Concurrency.** If another `running` run uses the same Ollama URL, record the warning `concurrent_run_detected`. Queueing or locking is `[O]` (R-07).

### XR-07 Where artifacts live [M from Phase 3] (USER)

```text
<target>/.ai-harness/                  # project artifacts (DECISION)
  specs/<name>.md, <name>.review.md, <name>.revised-vN.md, <name>.revised-vN.review.md
  changes/<runId>.json                 # Phase 6 application/verification record
<harness>/runs/<runId>/                # temporary execution data (git-ignored)
  manifest.json, console.log
  inputs/task.md, inputs/context.txt, inputs/context-files.json
  prompts/<stage>-<attempt>.txt        # full prompt (O-12)
  outputs/<stage>-<attempt>.raw.md
  proposal/ (Phase 5), backup/ (Phase 6)
<harness>/logs/model-calls.jsonl|csv   # technical telemetry
```

- The legacy scripts, called without a target, keep writing to `<harness>/specs/` (XR-01).
- The CLI requires `-TargetPath` for any command that produces artifacts (O-07).
- The harness writes **only** to `<target>/.ai-harness/` inside a target.

### XR-08 Run manifest JSON [M from Phase 3]

Manifests are written atomically: write a temporary file in the same folder, then rename it.

In the example below, the request name and the context file name were made generic in this export. The original example used values from an unrelated project.

```json
{
  "schemaVersion": 1,
  "runId": "20261119T140826Z-a2ae9c42",
  "workflow": "specify",
  "status": "failed",
  "exitCode": 2,
  "createdAtUtc": "…", "startedAtUtc": "…", "endedAtUtc": "…",
  "harness": { "root": "…", "gitCommit": "2e85dbe", "gitDirty": true,
               "registrySchemaVersion": 2, "registrySha256": "…" },
  "target":  { "root": "…", "artifactDir": "…/.ai-harness" },
  "process": { "pid": 1234, "processStartUtc": "…", "background": true },
  "request": { "name": "example-spec", "mode": "requirements", "maxRevisions": 3,
               "taskSha256": "…", "taskFile": "inputs/task.md",
               "overrides": { "model": null, "profile": null } },
  "context": { "file": "inputs/context.txt", "sha256": "…", "chars": 18000,
               "files": [ { "path": "src/example.txt", "sha256": "…", "sizeBytes": 1234 } ] },
  "stages": [
    { "id": "spec-generate", "kind": "agent", "agent": "spec", "attempt": 1,
      "status": "failed",
      "resolution": { "profile": "reasoning-32b", "model": "deepseek-r1:32b",
                      "modelSource": "agent", "timeoutSec": 900 },
      "budget": { "contextWindow": 16384, "estimatedPromptTokens": 7100,
                  "reservedOutputTokens": 6000, "withinBudget": true },
      "callId": "…", "durationMs": 900030, "output": null,
      "error": { "category": "timeout", "message": "…", "retryable": true } },
    { "id": "spec-validate", "kind": "deterministic", "status": "skipped",
      "reason": "dependency failed: spec-generate" }
  ],
  "artifacts": [ { "role": "specification", "path": ".ai-harness/specs/x.md",
                   "sha256": "…", "trust": "untrusted-draft" } ],
  "verification": [],
  "warnings": [ "possible_prompt_truncation" ]
}
```

**Allowed values:**

| Field | Values |
|---|---|
| Run `status` | `queued`, `running`, `succeeded`, `failed`, `needs_input`, `cancelled`, `abandoned` |
| Stage `status` | `pending`, `running`, `succeeded`, `failed`, `skipped`, `unsupported`, `cancelled` |
| `trust` | `untrusted-draft` (local model output), `deterministic-check` (validator), `verified-by-command` (only entries for commands actually executed, with the command, working folder, exit code and executor) |

### XR-09 Claude Code permissions and responsibilities [M from Phase 4] (USER)

| Actor | May | May not |
|---|---|---|
| Local Ollama agents | receive text, return text | use tools or functions (the library never sends `tools`), access files, run anything |
| Harness CLI | read the target and the harness; write to `<harness>/runs`, `<harness>/logs`, `<target>/.ai-harness`, and the legacy `<harness>/specs` | write any other target file; commit, push or deploy; edit `.ai/config.json` |
| Claude Code (orchestrator) | select context, run the CLI, review output, apply changes with Edit/Write under the session's permission mode, run the project's verification | present local output as verification; apply changes without approval unless authorized; commit or push unless asked |
| `harness-reviewer` subagent | Read, Grep, Glob | Edit, Write, Bash, or any network or MCP tool |

### XR-10 Reporting failures and unsupported stages [M from Phase 3]

**CLI exit codes:**

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | workflow failure (validation failed, or review still FAIL after the maximum number of revisions) |
| 2 | execution error |
| 3 | human input needed |
| 4 | unsupported stage or command |

The legacy scripts keep their current codes.

**Error categories** (`error.category`): `invalid_arguments`, `registry_invalid`, `agent_not_found`, `ollama_unreachable`, `model_not_installed`, `context_budget_exceeded`, `context_invalid`, `timeout`, `http_error`, `empty_output`, `invalid_output_format`, `validation_failed`, `review_failed`, `max_revisions_reached`, `needs_human_input`, `cancelled`, `abandoned`, `unsupported_stage`, `internal_error`.

**Unsupported stages:**

- Architecture, Implementation Plan, QA and code Review have no local agents.
- Asking for one gives exit 4 and stage status `unsupported`, with the message "No local agent implements '<stage>'; perform it in Claude Code or manually."
- The harness **never simulates** a stage.
- `harness stages` lists each stage as supported or unsupported.

**Partial results:** every failure leaves a manifest and keeps any partial artifacts.

---

## 5. Phases

### Phase 0: fix verified defects

**Superseded by its own spec.** The audit's version is summarized here only for traceability. The binding version is [specs/harness-phase-0-defect-corrections.md](../../specs/harness-phase-0-defect-corrections.md) (Revision 2). That spec corrected the audit in at least one place: the audit expected `tests/fixtures/valid-spec.md` to pass the validator, but it returns 1 (FACT).

**Defects the audit identified** (FACT):

| ID | Defect |
|---|---|
| D-01 | Documentation mode can't pass validation. The prompts tell the agent to write `None` for FR and AC, but the validator turns FR = `None` into exit 3, always requires `### AC-n`, and has no `-Mode`. |
| D-02 | Reviewer and reviser calls have no telemetry and no model-availability check. |
| D-03 | The live reviewer test used a different model from the configured reviewer. |
| D-04 | No tracked test checks that `-Mode` reaches every stage. |
| D-05 | The mock validators accept only `-SpecFile`. |

The audit then proposed FR-001 to FR-008, NFR-001 and NFR-002, and AC-001 to AC-006. These were reworked in the Phase 0 spec; use that spec.

**Out of Phase 0** (per the audit): changing the timeout or model mapping (O-01); deleting tracked `.bak` files (O-15); whether specs may contain extra sections (Q-04).

### Phase 1: configuration registry v2

**Functional requirements:**

- **FR-101** (USER): define registry v2 (`schemaVersion: 2`) in `.ai/config.json` (O-03), with:
  - `ollama {url, healthTimeoutSec}`
  - `defaults {profile, options, charsPerToken, safetyMarginRatio}`
  - `profiles {<name>: {model, contextWindow, timeoutSec, reservedOutputTokens, reasoning, think: true|false|default, options, transport}}`. `think` is Ollama's `think` request option. Phase 1 only stores it; Phase 2 uses it. (Replaces the audit's `thinking: "strip"|"keep"`; DECISION, 2026-11-20.)
  - `agents {<name>: {profile, promptFile?}}`
  - `tests {liveReviewerAgent, …}`
- **FR-102** (USER): one loader, `Get-HarnessRegistry`, accepts v1 or v2 and always returns a normalized v2 object (XR-02).
- **FR-103** (USER): the registry is validated on load:
  - every referenced profile exists
  - `contextWindow` is greater than `reservedOutputTokens` plus the margin
  - `num_ctx` doesn't conflict with `contextWindow`
  - `timeoutSec` is in the range 30–14400
  - unknown keys produce a warning, not an error
- **FR-104** (USER): `Resolve-HarnessExecution` implements XR-02. `Resolve-HarnessModel` stays as a compatibility wrapper.
- **FR-105** (USER): model names appear only in the registry and in test fixtures:
  - `benchmark-models.ps1`'s default `-Models` is built from the registry's profiles
  - `test-all.ps1` `Model` entries and the live suites resolve through the registry

**NFR-101:** works on PowerShell 5.1, with no `-AsHashtable` and JSON depth of at least 10.

**Acceptance criteria:**

- **AC-101:** a golden table of 4 agents × (no override / `-Model` / env / both) resolves identically under the v1 file and its v2 translation.
- **AC-102:** invalid v2 files are rejected with `registry_invalid` before any network call.
- **AC-103:** a static test finds no model-name literals in `scripts/*.ps1` outside the loader's test fixtures.
- **AC-104:** `-Model` combined with `-Profile` is rejected.

**Depends on:** Phase 0.
**Regression tests:** all offline suites, plus `test-registry.ps1`.
**Security:** by default only a localhost Ollama URL; a URL that isn't loopback produces a warning (R-11).
**Migration and rollback:** v1 stays supported. Migrating means rewriting `config.json` as v2, with approval; rolling back means restoring the v1 file.

### Phase 2: shared agent execution library

**Functional requirements:**

- **FR-201** (USER): `scripts/lib/agent-exec.ps1`, with these functions:
  - `Get-AgentPromptParts` / `New-AgentPrompt`, which build the prompt from labelled parts (`instruction` or `data`)
  - `Test-AgentContextBudget` (XR-03)
  - `Test-OllamaModel`, a health check with a cached `/api/tags` lookup
  - `Invoke-AgentModel`, which returns `{status, text, meta, error{category,…}}` and does not throw for model or transport failures
  - an extended `Write-HarnessModelTelemetry` (XR-05)
- **FR-202** (FACT/USER): `run-agent.ps1`, `review-spec.ps1` and `revise-spec.ps1` use the library. Their parameters, exit codes, console markers and output files stay the same. `Invoke-HarnessGenerate` remains as a deprecated wrapper.
- **FR-203** (USER): the prompts sent stay **byte-identical** for the same inputs (golden tests).
- **FR-204** (USER): an abstracted transport. The default is the blocking `Invoke-RestMethod` with the profile's `timeoutSec`; offline tests inject a fake transport.
- **FR-205** `[O]` (O-10): a streaming transport (`HttpWebRequest` reading NDJSON) with `idleTimeoutSec` and `maxTotalSec`, enabled per profile.
- **FR-206** `[O]`: an optional `num_predict` per profile.
- **FR-207:** never send `tools`, `functions` or any instruction to execute anything to Ollama.

**Non-functional requirements:**

- **NFR-201:** less than 1 s of library overhead per call, not counting network time.
- **NFR-202:** errors are classified without depending on the language of the messages.

**Acceptance criteria:**

- **AC-201:** golden prompt captures for spec, reviewer, reviser and developer match byte for byte.
- **AC-202:** injected timeout, HTTP 500, empty response, and a review with no Status each give the legacy exit code, the right `error_category`, and exactly one telemetry line.
- **AC-203:** an oversized context gives `context_budget_exceeded` with a size breakdown, and makes **no** transport call.
- **AC-204:** the CSV rule holds: with an old header present, v2 rows go to `model-calls.v2.csv`, and the old file is unchanged (hash check).
- **AC-205** (live, deferred): one real call per agent returns the expected format; `prompt_eval_count` is recorded and used to calibrate `charsPerToken`.

**Depends on:** Phase 1.
**Security:** prompt sections are marked as data or instructions; context is always data.
**Migration and rollback:** the scripts keep their interfaces, so rolling back means reverting the library and the three scripts together.

The addendum (section 9) adds Phase 2 candidates measured after the audit.

### Phase 3: unified CLI and JSON manifests

**Functional requirements:**

- **FR-301** (USER): `scripts/harness.ps1 <command>`, with these commands:
  - `specify`, `review`, `revise`, `validate`, `scan`, `context`, `develop`
  - `status`, `cancel`, `list`, `stages`
  - `config` (shows how models resolve; no network)
  - `doctor` (registry check, `/api/tags`, installed models; never generates)
- **FR-302** (USER): the workflow commands take:
  - `-TargetPath`, required for artifacts (O-07)
  - `-Name`, `-Mode`, `-TaskFile` or `-Task`
  - `-Include <relative paths>`
  - `-Model` / `-Profile`, `-Background`, `-RunId`
- **FR-303** (FACT/USER): one implementation of the specify workflow, shared by the CLI and `specify.ps1`. `specify.ps1` keeps its current interface and folder.
- **FR-304** (USER): repository context is available in **every** model stage of a workflow (spec, review, revise, develop). Today `specify.ps1` does not pass `-ContextFile` at all (FACT). Every stage uses the same `context.txt` and records its hash.
- **FR-305:** manifests (XR-08), artifacts (XR-07), background runs (XR-06), failure reporting and exit codes (XR-10).
- **FR-306:** the last line of stdout is `MANIFEST: <absolute path>`.
- **FR-307:** `runs/` is added to `.gitignore`; pruning old runs is `[O]`.

**Non-functional requirements:**

- **NFR-301:** never asks for input; safe inside Claude's `run_in_background`.
- **NFR-302:** the target tree outside `.ai-harness/` is byte-identical before and after any command (tripwire).

**Acceptance criteria:**

- **AC-301:** an offline mock `specify` against a temporary target writes the 4 artifacts to `<tmp>/.ai-harness/specs/` plus a valid manifest; the target is otherwise unchanged.
- **AC-302:** with `-Background`, `status` shows `running` then `succeeded`; killing the child process externally leads to `abandoned`; `cancel` with a mismatched start time refuses to act.
- **AC-303:** `harness architecture` exits 4, and the manifest stage is `unsupported`.
- **AC-304:** injected failures each give the right exit code and `error.category`, keep the earlier stages and mark the later stages `skipped`.
- **AC-305:** an `-Include` that escapes the target, points to a sensitive file, or is not in the manifest is rejected before any model call.
- **AC-306:** the legacy `specify.ps1` mock suite passes unchanged.

**Depends on:** Phase 2.
**Security:** writes are limited to the folders in XR-07; every path is canonicalized before checks; context from different targets is never mixed.
**Migration and rollback:** this phase only adds things; the legacy scripts remain.

### Phase 4: Claude Code integration

**Functional requirements:**

- **FR-401** (USER): a root `CLAUDE.md` that:
  - imports or points to `AGENTS.md`
  - states that Claude orchestrates and that local outputs are untrusted drafts
  - lists CLI usage, artifact locations, exit codes and how to read manifests
  - says never to commit or push without being asked
- **FR-402** (USER): a project-level skill, `.claude/skills/harness/SKILL.md` (`/harness`), that tells Claude to:
  1. Clarify the task and mode.
  2. Select minimal context and explain why each file was chosen.
  3. Run the CLI, in the background for long stages.
  4. Read the manifest.
  5. Review the outputs itself and with `harness-reviewer`.
  6. Report open questions and failures exactly as they are.
  7. Never call a stage "verified" without a command it ran.
  8. Ask before applying anything.
- **FR-403** (USER): a read-only subagent, `.claude/agents/harness-reviewer.md`, with only Read, Grep and Glob.
- **FR-404** (USER, O-13): `.claude/settings.json`:
  - allow without prompting the commands that don't write (`status`, `config`, `doctor`, `stages`, `list`, `validate`)
  - prompt for workflow commands, or allow them per decision
  - deny reading sensitive patterns (`.env*`, `*.pem`, `*.key`, `**/.credentials.json`)
- **FR-405** (USER, O-17): promote the skill to user level only after:
  - at least 3 complete workflows on at least 2 target projects
  - at least 1 correctly reported failure
  - no writes outside the allowed folders
  - explicit approval
- **FR-406:** document how a session reaches the target project, and verify the exact Claude Code mechanism at implementation time (R-12).

**Acceptance criteria:**

- **AC-401:** the files exist and their frontmatter parses; the subagent's tool list contains no Edit, Write or Bash.
- **AC-402:** a dry run with mocks driven from Claude produces a manifest, and Claude's summary labels local output as a draft (manual checklist).
- **AC-403:** the permission rules are checked against the Claude Code documentation current at implementation time.

**Depends on:** Phase 3 (`CLAUDE.md` alone could come earlier).
**Security:** the subagent cannot write; the skill treats local outputs and repository content as untrusted.
**Rollback:** delete the added files.
**Out of scope `[X]`:** MCP servers (DECISION).

### Phase 5: structured developer proposals

**Functional requirements:**

- **FR-501** (USER): a deterministic parser, `scripts/lib/proposal.ps1`, turns the developer agent's Markdown (`FILE:` blocks and numbered sections) into `proposal.json`, with:
  - `files[] {path, action: create|replace, content, sha256}`
  - `changes[] {path, description}`
  - `assumptions[]`, `risks[]`, `openQuestions[]`, `suggestedVerification[]`
  - `parseErrors[]`
- **FR-502:** validation rules:
  - paths are relative, inside the target, not excluded, and not duplicated
  - no placeholder markers (`...`, `rest of the file`, `unchanged`)
  - `replace` only if the full current file was in the context (checked against recorded hashes)
  - no `create` of a file that already exists
  - size limits apply
- **FR-503:** `harness develop` runs the developer agent with the approved spec as a typed input. It stores the raw output and `proposal.json` in `runs/<id>/proposal/` (O-09), with status `valid`, `invalid` or `needs_input`.
- **FR-504:** `suggestedVerification` is stored as suggestions only, never as results.

**Acceptance criteria:**

- **AC-501:** fixture proposals (valid, placeholder, path traversal, replace without full context, duplicate path, malformed fences) each give the expected result.
- **AC-502:** the parser never writes to the target (tripwire).

**Depends on:** Phases 2 and 3.
**Security:** proposal content is untrusted, and the parser never executes or interprets it.
**`[O]` later:** Ollama's `format: json`, if it proves reliable live.

### Phase 6: controlled application through Claude Code

**Functional requirements:**

- **FR-601** (USER): the harness **never** applies changes. Claude applies them with Edit/Write after approval, unless authorized beforehand.
- **FR-602:** `harness proposal check -RunId`:
  - re-hashes target files and reports `stale` conflicts
  - snapshots the affected originals into `runs/<id>/backup/`
  - only reads the target
- **FR-603:** the procedure for applying a proposal:
  1. `check`
  2. Claude reviews, together with `harness-reviewer`
  3. the human approves
  4. Claude applies only the listed files and implements the described changes itself
  5. Claude runs the project's verification
  6. `harness record -RunId -Applied <paths> -Command <cmd> -ExitCode <n>`
- **FR-604:** `record` adds `verification[]` entries (`trust: verified-by-command`, `executor: claude-code`) and writes `<target>/.ai-harness/changes/<runId>.json`. A stage that was not verified is `not_verified`, not `passed`.
- **FR-605:** rollback guidance restores from `backup/` or git. The harness never runs git commands that write.

**Acceptance criteria:**

- **AC-601:** a stale file blocks application, with a clear message.
- **AC-602:** `record` refuses entries that have no command or exit code.
- **AC-603:** no harness command in this phase changes the target (tripwire).

**Depends on:** Phases 4 and 5.
**Security:** no automatic application, commit, push or deploy.

### Scope classification

| Mandatory `[M]` | Optional later `[O]` | Out of scope `[X]` |
|---|---|---|
| Phase 0 fixes; registry v2 with v1 compatibility; shared library; budget enforcement; telemetry v2; CLI and manifests; background runs, `status` and `cancel`; artifact layout; `CLAUDE.md`, skill and read-only subagent; proposal parser; stale check, backup and record | streaming transport and heartbeat (O-10); `num_predict`; `name:latest` normalization; secret-content scanning; run cleanup; queue or model lock; `format: json` proposals; local architect, QA or code-review agents; automatic retry with backoff; telemetry dashboard | MCP server; local agents with tools, file or exec access; harness auto-apply; commit, push or deploy automation; cloud model integration in the harness; GUI; PowerShell 7 or cross-platform port; automatic context selection by embeddings |

---

## 6. Implementation order

```text
Phase 0 ──► Phase 1 ──► Phase 2 ──► Phase 3 ──┬──► Phase 4 ──► Phase 6
                                              └──► Phase 5 ──┘
```

1. **The O-01 configuration decision.** This needs no code.
2. **Phase 0:** small, testable offline, and it unblocks documentation mode.
3. **Phase 1:** every later model reference depends on it.
4. **Phase 2:** removes duplicated code, and makes telemetry and budgeting consistent. The live AC-205 check waits until Ollama is available.
5. **Phase 3:** CLI, manifests, background runs, and context in every stage.
6. **Phases 4 and 5**, which can run in parallel. A minimal `CLAUDE.md` can come earlier.
7. **Phase 6.**
8. **After Phase 6:** promote the skill to user level, once the FR-405 criteria are met.

Each phase ends with a full offline `test-all.ps1`, a review, and human approval before the next phase starts.

---

## 7. Open decisions (audit, Part 4)

The "Status" column was added on 2026-11-19. Everything without a status is still open.

| ID | Decision | Audit's recommendation | Status |
|---|---|---|---|
| O-01 | Immediate fix for the timeout | `timeoutSec` 2400 for `deepseek-r1:32b`, or map `spec` to a model that doesn't reason; per-profile timeouts arrive in Phase 1 | **DECISION:** deferred (not in Phase 0). The models have since changed; see section 9 and the audit reports. |
| O-02 | Which model the live tests use | the agent's registry model, with an optional `tests` override | Partly decided: Phase 0 (FR-013/FR-014) makes the live reviewer test use the configured reviewer model |
| O-03 | Where the registry lives | the same `.ai/config.json`, with `schemaVersion: 2` | **DECISION (2026-11-20):** the same `.ai/config.json`, `schemaVersion: 2`; v1 is still accepted |
| O-04 | `-Model` together with `-Profile` | reject | **DECISION (2026-11-20):** reject |
| O-05 | Documentation mode with FR present but no AC | require AC | **DECISION:** require at least one AC when FR entries are present (Phase 0) |
| O-06 | Commit or ignore `<target>/.ai-harness/` | commit `specs/` and `changes/`; decide per project | open |
| O-07 | Is `-TargetPath` required? | yes, with no implicit current-folder default | open; belongs to Phase 3 |
| O-08 | Specs in the harness's `specs/` that belong to an unrelated project | move them to that project's `.ai-harness/`, or delete them; don't commit them to the harness | **DONE** (2026-11-20): they were committed in `b8cae9f`; a hygiene commit untracked them and ignores them |
| O-09 | Where proposals are stored | the run folder; only the application record goes into the target | open |
| O-10 | Is streaming required in Phase 2, or optional? | optional and off by default until it has been validated live | open |
| O-11 | Built-in `-Background`/`cancel`, or rely on Claude's `run_in_background` | build both | open; belongs to Phase 3. **Updated recommendation (not a decision):** rely on Claude Code's own background execution first, and build the harness's own `-Background`, `status` and `cancel` only if that proves insufficient. |
| O-12 | Save full prompts in run folders | yes, local and git-ignored | open |
| O-13 | Claude Code allow and deny lists | as in FR-404 | open |
| O-14 | Task text in telemetry | hash only; full text only in the run folder | open |
| O-15 | Remove the tracked `.bak` files | a separate hygiene commit | **DONE** (2026-11-20): a hygiene commit untracked them; they stay on disk and are ignored by `*.bak` |
| O-16 | `reservedOutputTokens` per profile | reasoning 32b: 6000; coder: 4096; calibrate in Phase 2 | **DECIDED provisionally (2026-11-20):** 4096 for the `fast` profile and 6144 for the `deep` profile; calibrate in Phase 2 (the models changed since the audit). **Superseded for `deep` by Phase 1 OD-112:** `deep` and `review` use 8192, `fast` stays at 4096 (still provisional) |
| O-17 | Criteria for promoting the skill to user level | as in FR-405 | open |
| O-18 | New exit code 4 for unsupported stages (CLI only) | accept | open |

---

## 8. Risks and unresolved questions (audit, Part 5)

### Risks

| ID | Risk |
|---|---|
| R-01 | **Throughput** (historical; UNVERIFIED figures). The 32b models of the time ran partly on the CPU at about 2.2–2.6 tokens/s, so a review cycle took 7–15 minutes, and a workflow with 3 revisions could exceed an hour. Timeouts and background runs are essential. The models measured after the audit are much faster (section 9). |
| R-02 | **Ollama/GPU instability:** CUDA initialization crashes (UNVERIFIED). Report them as `http_error`, with the response body. |
| R-03 | **Context limits** depend on token estimates and on how Ollama handles overflow; both are calibrated in Phase 2. |
| R-04 | **Refactoring regressions:** a prompt change could silently change model behavior. AC-201 (byte-identical prompts) guards against this. |
| R-05 | **Prompt injection** through repository content into model output, and on to Claude. Mitigated by the untrusted framing, the read-only reviewer, and human approval. |
| R-06 | **PowerShell 5.1 limits:** no threads for a heartbeat, complex `HttpWebRequest` streaming, `ConvertFrom-Json` quirks, BOM defaults. [validate-spec.ps1:12](../../scripts/validate-spec.ps1#L12) reads files without `-Encoding UTF8` (FACT). |
| R-07 | **Concurrency:** with a single GPU, concurrent runs slow each other down or fail to load. |
| R-08 | **Telemetry schema change:** handled by the CSV rule in XR-05. |
| R-09 | **Size of the spec:** the local reviewer's fixed prompt is already about 25 KB, so each phase must be validated separately. |
| R-10 | **Localized errors:** classification must never parse message text. |
| R-11 | **Ollama URL that isn't loopback:** prompts containing target code would leave the machine. Warn about it and document it. |
| R-12 | **Claude Code details:** skill and subagent formats, permission syntax, and access to an extra folder must be checked against the documentation current at Phase 4. |

### Unresolved questions

| ID | Question |
|---|---|
| Q-01 | What the failed run was generating, and why it ran past about 1,880 tokens. This can't be recovered. |
| Q-02 | The root cause of the CUDA initialization crash, and whether a newer Ollama fixes it. |
| Q-03 | The real ratio of characters to tokens, and whether Ollama truncates prompts that overflow. Both need live calibration. |
| Q-04 | Should specs be allowed sections beyond the 10 required ones? A spec generated for an unrelated project added extra sections that the `spec.md` prompt forbids; the validator doesn't check for this. |
| Q-05 | Can `HttpWebRequest` streaming on PS 5.1 reliably read Ollama's stream with an idle timeout? This needs a spike before O-10 is decided. |
| Q-06 | Should `AGENTS.md`, the harness's own development rules, keep being added to prompts for tasks on other projects? |

---

## 9. Addendum 2026-11-19: findings measured after the audit

Source: two live validation runs with the new models, [docs/audits/2026-11-19-model-validation.md](../audits/2026-11-19-model-validation.md) and [docs/audits/2026-11-19-model-validation-2.md](../audits/2026-11-19-model-validation-2.md).

### 1. Reasoning comes back in a separate `thinking` field

**Measured (FACT):**

- Ollama 0.40.13 returns the reasoning of `qwen3.5:9b` and `qwen3.6:35b` in a separate `thinking` field of the `/api/generate` response, not as `<think>` tags inside `response`.
- With `"think": false`, the `thinking` field is absent.

**Consequences for the harness:**

- **`stripThinking` does nothing** for these models (FACT: it only removes `<think>` tags).
- **The reasoning is discarded.** The harness reads only `response`, so it never sees the reasoning.
- **Hidden cost.** The reasoning still counts in `eval_count` and uses generation time: roughly 40–80% of output tokens in the measured samples.
- **Empty answers.** When the reasoning uses up the output or context budget, `response` comes back empty (FACT: observed with a capped output budget, `done_reason: length`). One `revise-spec.ps1` run returned "Reviser returned an empty response" after 177 s; the likely cause is that thinking ran until the context was full, but this is unconfirmed because the reviser writes no telemetry.

**Phase 2 candidates:**

- a per-agent `think` setting
- detecting an empty `response` with `done_reason: "length"` and reporting it as a context or thinking budget that ran out
- recording `done_reason`, `eval_count` and the thinking length for every call, including the reviewer and reviser (this extends XR-05 and Phase 0 defect D-02)

Turning thinking off reduced spec quality in the samples taken (2 of 2), so thinking should not simply be disabled.

### 2. The spec prompt labels design choices as `USER` and leaves Open Questions empty

**Observed:** on a task that has nothing to do with user registration ("a simple CLI that converts CSV to JSON"), `spec` outputs from `qwen3.5:9b` labelled unrequested design choices as `Source: USER` in 5 of 5 samples, and left Open Questions and Assumptions empty. Examples of such choices: input and output file arguments, stdout versus file output, header handling, error behavior.

- The structural validator can't detect either problem.
- The reviewer (`qwen3.6:35b`) catches only some of them.
- `qwen3.6:35b` with default thinking produced more pertinent open questions (2 of 2 samples), but the samples are small.

**Phase 2 prompt work:**

- source labelling and minimality in `spec.md`
- using Open Questions for real ambiguities
- reducing the prompts' dependence on the single registration example (see the handoff document)
