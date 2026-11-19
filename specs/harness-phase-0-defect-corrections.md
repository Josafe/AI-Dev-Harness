# Specification

**Title:** Harness modernization, Phase 0: corrections to verified defects
**Status:** Revision 2 (2026-11-19). All design decisions are resolved and the spec is ready for implementation. See "Resolved Decisions" and "Revision History".
**Applies to:** AI-Dev-Harness at commit `2e85dbe` (working tree: `.gitignore` modified, `specs/portfolio-*` untracked)
**Requirement ID scheme:** Phase 0 uses `FR-0nn`, `NFR-0nn`, `AC-0nn`. Phase 1 starts at `FR-101`. Retired IDs are never reused: FR-009 and WP-B were removed in Revision 1.

## Goal

Fix six verified defects in the existing harness. Every fix must be small, backward-compatible and testable offline, and Phase 0 must not introduce any Phase 1+ architecture.

**In scope:**

1. Documentation-mode validation (D-01).
2. Telemetry for reviewer and reviser calls (D-02).
3. Model-availability checks for reviewer and reviser calls (D-03).
4. Hardcoded model names in test scripts (D-04). Model names in the benchmark script are deferred to Phase 1 (OD-02).
5. Regression tests for passing `-Mode` through every stage (D-05).
6. The live reviewer test using a model different from the configured reviewer model (D-06).

When Phase 0 is done:

- A `documentation`-mode workflow that correctly writes `None` for FR, NFR and AC can pass validation.
- Validators that do not support `-Mode` keep working exactly as before.
- Every model request sent by the reviewer and reviser is logged and preceded by an availability check.
- The test scripts no longer name models.
- Passing `-Mode` through the workflow is covered by offline regression tests.

## Context

### Where these requirements come from

- The previous read-only architecture audit and modernization specification were produced in an earlier Claude Code session on 2026-11-19. **They are not stored in the repository.** They were recovered from that session's local transcript. This document extracts only that specification's "Phase 0" section (defects D-01 to D-05, FR-001 to FR-008, AC-001 to AC-006). It re-checks every item against the current code and applies the decisions in the Phase 0 request.
- The decisions from the Phase 0 request (2026-11-19) override the audit where they differ:
  - Documentation mode may PASS without FR, NFR or AC when there is enough documentation context.
  - If FR entries are present, at least one AC entry is required.
  - Purely descriptive documentation does not need functional AC.
  - The timeout is not fixed in Phase 0.
  - No registry or profiles are introduced in Phase 0.
  - Test-model centralization that needs the registry is deferred to Phase 1.
- Revision 1 applies the findings of a read-only review of this spec and the decisions confirmed on 2026-11-19 (OD-01 to OD-05).
- Revision 2 applies the findings of a final read-only audit and the decision confirmed as OD-06.

### Verified defects

All six were verified by reading the code on 2026-11-19.

| ID | Defect | Evidence |
|---|---|---|
| D-01 | Documentation mode cannot pass validation when the agents follow their own instructions. | [spec.md:177](.ai/agents/spec.md#L177), [spec-reviser.md:368-372](.ai/agents/spec-reviser.md#L368-L372) and [revise-spec.ps1:111-113](scripts/revise-spec.ps1#L111-L113) tell the agents to write `None` for FR, NFR and AC in documentation mode. But [validate-spec.ps1:61-65](scripts/validate-spec.ps1#L61-L65) exits 3 when FR is `None`, and [validate-spec.ps1:70-75](scripts/validate-spec.ps1#L70-L75) always requires `### FR-n` and `### AC-n`. The validator has no `-Mode` parameter ([validate-spec.ps1:1-4](scripts/validate-spec.ps1#L1-L4)). [specify.ps1:155](scripts/specify.ps1#L155) and [specify.ps1:330-331](scripts/specify.ps1#L330-L331) never pass the mode to it. |
| D-02 | Reviewer and reviser model calls write no telemetry. | [review-spec.ps1:114-118](scripts/review-spec.ps1#L114-L118) and [revise-spec.ps1:149-153](scripts/revise-spec.ps1#L149-L153) call `Invoke-HarnessGenerate` ([config.ps1:54-90](scripts/lib/config.ps1#L54-L90)), which never calls `Write-HarnessModelTelemetry`. The only telemetry calls are in [run-agent.ps1:174](scripts/run-agent.ps1#L174) and [run-agent.ps1:201](scripts/run-agent.ps1#L201). The audit also matched this against the Ollama server log: reviewer and reviser calls appear there but not in `logs/`. |
| D-03 | The reviewer and reviser do not check that Ollama is reachable or that the model is installed. | [run-agent.ps1:83-97](scripts/run-agent.ps1#L83-L97) checks `/api/tags`. [review-spec.ps1](scripts/review-spec.ps1) and [revise-spec.ps1](scripts/revise-spec.ps1) do not. |
| D-04 | Test and benchmark scripts contain hardcoded model names. | [test-spec.ps1:3](scripts/test-spec.ps1#L3) has a default for `$Model`, but the parameter is never used. Other occurrences: [test-spec-integration.ps1:2](scripts/test-spec-integration.ps1#L2), [test-all.ps1:111](scripts/test-all.ps1#L111), [benchmark-models.ps1:8-12](scripts/benchmark-models.ps1#L8-L12). |
| D-05 | No test checks that `-Mode` reaches every stage. | [test-spec.ps1](scripts/test-spec.ps1) contains no `-Mode` cases, and no mock records the arguments it receives. |
| D-06 | The live reviewer test uses `qwen2.5-coder:32b`, but the configured reviewer is `deepseek-r1:32b`. | [test-spec-integration.ps1:2](scripts/test-spec-integration.ps1#L2) and [test-all.ps1:111](scripts/test-all.ps1#L111), against [config.json:6](.ai/config.json#L6). |

### Corrections to the audit (FACT, verified 2026-11-19)

- **`valid-spec.md`:** audit AC-001 expected [valid-spec.md](tests/fixtures/valid-spec.md) to return 0. It returns **1** today ("No requirement source annotations found"), because it has no `**Source:**` lines. The current exit codes are:

  | Fixture | Exit code |
  |---|---|
  | `invalid-spec.md` | 1 |
  | `minimal-valid-spec.md` | 0 |
  | `semantic-invalid-spec.md` | 0 |
  | `valid-spec.md` | 1 |

  AC-001 preserves these values.
- **D-01 is a contradiction in the code; no run has shown it yet.** The ignored artifact `specs/mode-probe-documentation.md` contains placeholder `FR-001`/`AC-001` entries, so it never reached the `None` path. It returns 0 today.
- **The runner gets the mode as text.** It receives the mode only inside the task text (`SPECIFICATION MODE (AUTHORITATIVE):` followed by the mode, [specify.ps1:105-111](scripts/specify.ps1#L105-L111)), not as a parameter.

### How PowerShell passes `-Mode` to a custom validator (FACT, verified 2026-11-19)

- **Advanced scripts reject it.** `validator-success.ps1`, `validator-error.ps1` and the current `validate-spec.ps1` each declare their parameters with `[Parameter]`, which makes them advanced scripts. An advanced script rejects an unknown `-Mode` with a parameter-binding error. Inside `specify.ps1` that error becomes exit 2.
- **Simple scripts swallow it.** A simple script (no `[Parameter]` or `[CmdletBinding]`) silently puts an unknown `-Mode documentation` into `$args`.
- **The parameter can be detected without running the script.** `Get-Command <script path>` parses the script and reports its declared parameters: `validator-success.ps1` reports `SpecFile`; `reviewer-pass.ps1` reports `Task, SpecFile, Mode, Model, OutputFile`.
- **Inspection can fail in two places.**
  - For a script that fails to parse, `Get-Command` succeeds, but reading `.Parameters` throws.
  - For a `.cmd` file, a missing file, or a relative path without `.\`, `Get-Command -CommandType ExternalScript` itself throws. For the relative path, `&` fails the same way.
- **Binding errors give exit 1.** A parameter-binding error under `powershell.exe -File` exits 1.
- **A function shadows a cmdlet.** A function named `Invoke-RestMethod` defined in a session takes precedence over the cmdlet, including when the call comes from a nested scope. This was verified with script blocks. Calls from a script file run with `&` are confirmed in WP-D, step 4a.

### Current behavior that Phase 0 builds on

- **Validator exit codes:** 0 = PASS, 1 = FAIL (and also a missing file or invalid arguments), 3 = insufficient input.
- **How `specify.ps1` handles validator results:**
  - On the initial validation, exit 3 becomes workflow exit 3 and any other non-zero code becomes 2.
  - On revision validation, every non-zero code becomes 2.
- **The FR check today.** The FR section's content has code fences removed, is trimmed, and is compared with `None` using PowerShell's case-insensitive `-eq`. With the current validator, verified 2026-11-19 on temporary copies:

  | FR section content | Exit code | Output |
  |---|---|---|
  | `None`, `none`, or fenced `None` | 3 | `STATUS: INSUFFICIENT INPUT` |
  | `None.` | 1 | "No functional requirements found.", "No acceptance criteria found.", "No requirement source annotations found." |
- **Telemetry:**
  - Written by `Write-HarnessModelTelemetry` ([telemetry.ps1](scripts/lib/telemetry.ps1)) to `<root>/logs/model-calls.jsonl` and `.csv`, with 14 fixed columns.
  - `run_id` is `AI_HARNESS_RUN_ID` if set, otherwise a new GUID.
  - `run-agent.ps1` writes exactly one record per generation request (`success` or `error`). Failures before the request is sent are not logged.
- **How model names are matched:**
  - `run-agent.ps1:92` uses `-notcontains`, which is case-insensitive.
  - `test-all.ps1:602` uses `-cnotcontains`, which is case-sensitive. This inconsistency is resolved by FR-014.
- **Offline baseline (2026-11-19):** `scripts/test-all.ps1` without `-IncludeLive` gives `STATUS: PASS WITH SKIPS`:
  - PASS: `test-syntax`, `test-build-context`, `test-run-agent`, `test-scan-repository`, `test-spec` (`Passed: 17`, `Failed: 0`)
  - SKIPPED: `test-spec-integration`
  - The repository tripwire was clean.

### Ollama and model configuration at review time (FACT, 2026-11-19)

- **Server:** Ollama is not running. Nothing answers on `localhost:11434`. The app log shows it shut down at 15:23:56.
- **Installed models**, from the on-disk manifests: `deepseek-r1:32b`, `qwen2.5-coder:32b`, `qwen2.5-coder:7b`.
- **`.ai/config.json`:**
  - `defaultModel`: `qwen2.5-coder:32b`
  - `agentModels.spec-reviewer`: `deepseek-r1:32b`
  - `timeoutSec`: 900
  - `num_ctx`: 16384
- **Environment:** `AI_HARNESS_MODEL` is not set.
- **Impact:** Phase 0 needs none of this. No exit criterion requires Ollama.

## Exclusions

These items are explicitly out of Phase 0:

| Item | Where it goes |
|---|---|
| Local model timeout (`timeoutSec`, per-agent timeouts, streaming, `num_predict`) | Revisit when local Ollama runs resume (audit O-01, O-10) |
| Configuration registry v2, profiles, `-Profile`, `Resolve-HarnessExecution`, `tests` registry section | Phase 1 (audit FR-101 to FR-105) |
| Default `-Models` list in `benchmark-models.ps1` | Phase 1, FR-105 (OD-02) |
| A single model-name source for all tests, and a static "no model literals in scripts/" check | Phase 1 (audit FR-105, AC-103) |
| Shared agent execution library, transport injection, refactoring prompt construction | Phase 2 |
| Telemetry schema v2, telemetry for failures before the request, error categories, `call_id`/`workflow_id` correlation | Phase 2 (audit XR-05, OD-04) |
| Any change to `run-agent.ps1` | Not needed for Phase 0 |
| Any change to prompt text sent to models, or to `.ai/agents/*.md` | Separate approved change only |
| Changes to the existing validator mocks (`validator-success.ps1`, `validator-error.ps1`) | Kept unchanged on purpose: they are the test cases for older validators that don't declare `-Mode` (FR-019) |
| Passing `-ContextFile` or repository context to the reviewer and reviser | Phase 3 (audit FR-304) |
| Mapping revision-validation exit 3 to workflow exit 3 (today it maps to 2) | Not in Phase 0; recorded as an edge case |
| Reading the spec file in the validator without `-Encoding UTF8` (audit R-06) | Not in Phase 0 |
| Whether specs may contain extra sections (audit Q-04) | Not in Phase 0 |
| Removing tracked `.bak` files (O-15), handling the untracked `specs/portfolio-*` files (O-08), the `.gitignore` working-tree change | Separate decisions |
| Treating `name` and `name:latest` as the same model name | Optional, later |
| CLI, manifests, background runs, Claude Code integration, proposals | Phases 3 to 6 |

## Functional Requirements

**Definition — None marker.** A section "is the None marker" when its content, after removing the strings `` ```text `` and `` ``` `` and trimming whitespace, equals `None` under PowerShell's case-insensitive `-eq`. This is exactly how the current FR check normalizes content (OD-05).

- `None`, `none`, `NONE` and a fenced `None` are the None marker.
- `None.` and any other text are not; they are ordinary text.
- A section that is empty after the same normalization is "empty".

### FR-001 — Validator accepts an optional mode

**Source:** USER

`scripts/validate-spec.ps1` accepts an optional parameter `-Mode`:

- Allowed values are `requirements`, `baseline` and `documentation`, enforced by `ValidateSet` with the same values as `specify.ps1`.
- The default is `requirements`.
- `-SpecFile` stays mandatory and keeps its current meaning.

### FR-002 — Requirements and baseline modes are unchanged

**Source:** USER

Without `-Mode`, or with `-Mode requirements` or `-Mode baseline`, the validator behaves exactly as before Phase 0:

- the same checks, in the same order
- the same exit codes
- the same `STATUS:` lines
- the same error headings ("Missing required sections:", "Validation errors:")
- the same error bullet lines and the same insufficient-input message, all in the same order

The only allowed difference is one added informational line that states the active mode. Removing, reordering or rewording any existing line is not allowed.

### FR-003 — Documentation mode may pass without FR, NFR or AC

**Source:** USER

With `-Mode documentation`, Functional Requirements, Non-Functional Requirements and Acceptance Criteria may each be the None marker, and the spec may contain no `### FR-n`, `### NFR-n` or `### AC-n` entries at all. Such a spec passes (exit 0) if:

- all 10 required sections are present (the check is unchanged)
- the documentation context is sufficient (FR-004)
- no other documentation-mode rule fails

In documentation mode, an FR section that is the None marker must **not** produce exit 3.

### FR-004 — Documentation mode requires documentation context

**Source:** USER

With `-Mode documentation`, the validator exits 3 (`STATUS: INSUFFICIENT INPUT`) when the `## Context` section is empty or is the None marker.

- The required-sections check (exit 1) still runs first.
- If the Context section cannot be captured, it counts as empty.
- `None.` in Context is ordinary text, so it counts as context (OD-05).

This check is the deterministic stand-in for "sufficient documentation context". Whether the context is adequate in substance is left to the semantic reviewer.

### FR-005 — Documentation mode: FR entries require AC entries

**Source:** USER

With `-Mode documentation`, if the spec contains at least one line matching `^### FR-\d+`, it must also contain at least one line matching `^### AC-\d+`. Otherwise the validator exits 1 with the existing message "No acceptance criteria found."

AC entries without FR entries are allowed.

### FR-006 — Documentation mode: Source annotation rules

**Source:** USER

With `-Mode documentation`:

- **Every value must be valid.** Every `**Source:**` line must contain one of `USER`, `PROJECT`, `FACT` or `ASSUMPTION`. This is the existing rule and it applies in every mode.
- **Conditional check.** The check "No requirement source annotations found." applies only when the spec has at least one numbered entry (`### FR-n`, `### NFR-n` or `### AC-n`).
- **Descriptive specs.** A purely descriptive spec with no numbered entries passes without any `**Source:**` line.

### FR-007 — Documentation mode: FR and AC sections must be the None marker or contain entries

**Source:** USER

With `-Mode documentation`, the Functional Requirements section and the Acceptance Criteria section must each either:

- be the None marker, or
- contain at least one numbered entry of the matching kind (`### FR-n` or `### AC-n`).

Any other content, including `None.` and free text without IDs, makes the validator exit 1 with a message that names the section. This was approved as OD-01.

### FR-008 — The workflow passes the mode to validators that declare it

**Source:** USER

`scripts/specify.ps1` checks, once per run, whether the validator script declares a `Mode` parameter.

**When the check happens:**

- after the existing `Test-Path` checks and before Step 1

**How it is done:**

- Resolve the validator path the same way `&` resolves it.
- Read `.Parameters` from `Get-Command` on that path with `-CommandType ExternalScript`.
- This only parses the script and never runs it.

**Using the result:**

- Both validator invocation points use it: the initial validation ([specify.ps1:155](scripts/specify.ps1#L155)) and every revision validation ([specify.ps1:330-331](scripts/specify.ps1#L330-L331)).
- Both points build their arguments the same way, for example through one shared splat or helper.
- If the validator declares `Mode`, both points pass `-SpecFile <file>` and `-Mode $Mode`.
- Otherwise, FR-019 applies.

Nothing else in the workflow changes, including how exit codes are mapped.

### FR-010 — Reviewer and reviser check that the model is available

**Source:** USER

Before sending a generation request, `scripts/review-spec.ps1` and `scripts/revise-spec.ps1` check that Ollama is reachable and that the resolved model is installed, the same way `run-agent.ps1` does.

- **How the check runs:**
  - `GET <ollamaUrl>/api/tags` with a 15 s timeout.
  - The `ollamaUrl` comes from the config, defaulting to `http://localhost:11434`.
- **How names are matched:**
  - Exact name match, **case-insensitive** (`-contains`/`-notcontains`), the same as `run-agent.ps1`.
  - `name` and `name:latest` are not treated as the same.
- **If Ollama is unreachable:** report "Ollama is not reachable at `<url>`. Make sure Ollama is running."
- **If the model is missing:** report "Model not found: `<model>`" and list the available models.
- **When either check fails:**
  - no generation request is sent
  - `review-spec.ps1` exits **2**
  - `revise-spec.ps1` exits with a **non-zero** code, as it does today on any error

The check may be a new helper function in `scripts/lib/config.ps1`. `run-agent.ps1` is not changed.

### FR-011 — Reviewer and reviser write telemetry

**Source:** USER

Each generation request actually sent by `review-spec.ps1` or `revise-spec.ps1` writes **exactly one** telemetry record through the existing `Write-HarnessModelTelemetry`, with the current 14-field schema (OD-04). The record contains:

- `agent`: `spec-reviewer` or `spec-reviser`
- `model`: the resolved model
- `status`: `success` with the response metrics, or `error` with the exception message
- `run_id`: the value of `AI_HARNESS_RUN_ID` when it is set and not blank, otherwise a new GUID (current function behavior)

Rules:

- Requests that are never sent write no record. This covers FR-010 failures and missing input files, and matches run-agent.
- If writing telemetry fails, a warning is printed and the exit code does not change (current function behavior).
- Recommended design: add optional parameters to `Invoke-HarnessGenerate`, for example `-TelemetryAgent` and `-TelemetryRoot`. When both are given, the function writes the record on success and on failure, before rethrowing. Calls without them behave exactly as today.

### FR-012 — External behavior of the reviewer and reviser is unchanged

**Source:** USER

Apart from FR-010 and FR-011, these stay exactly as they are for `review-spec.ps1` and `revise-spec.ps1`:

- parameters
- exit codes
- console markers (`=== OLLAMA ERROR ===`, `Review Status:`, `=== Revised Specification ===`)
- output files
- the `## Status` contract
- the system prompt and user prompt sent to the model, which must be byte-identical

### FR-013 — The live reviewer test uses the configured reviewer model

**Source:** USER

`scripts/test-spec-integration.ps1`:

- **No default model.** `-Model` keeps working as an optional override but has no hardcoded default.
- **Without `-Model`:** the suite does not pass `-Model` to `review-spec.ps1`, so the reviewer resolves its model the way production does (`AI_HARNESS_MODEL`, then `agentModels.spec-reviewer`, then `defaultModel`).
- **Output:** the suite prints the model in use, resolved with the existing `Resolve-HarnessModel` from `scripts/lib/config.ps1` for agent `spec-reviewer`.
- **With `-Model <m>`:** the suite passes `<m>` to the reviewer, as today.

### FR-014 — The live-suite precondition resolves its model from configuration

**Source:** USER

`scripts/test-all.ps1` no longer contains a model name.

**Table entry:**

- The `test-spec-integration.ps1` entry names the agent whose model must be installed, with a new allowed field `ModelAgent = "spec-reviewer"`.
- A literal `Model` stays allowed for compatibility.
- A `Requires = 'ollama'` entry must have exactly one of the two fields (see "Table validation" below).

**Table validation (both modes, unchanged in kind):**

- A `Requires = 'ollama'` entry must have exactly one of `Model` or `ModelAgent`, as a non-blank string.
- Any other shape is a `test-all configuration` FAIL, as table problems are today.
- A live entry that fails this check is never executed, and its precondition never runs. With `-IncludeLive` it is reported FAIL (NOT executed), and no request is sent to Ollama.
- This check uses only test-all's own table, never `.ai/config.json`.

**Model resolution (best effort, both modes):**

- **When:** when test-all reaches the live suite's entry. With `-IncludeLive`, resolution happens before any request to Ollama.
- **How:**
  - Load `scripts/lib/config.ps1` from test-all's own scripts folder.
  - Read `.ai/config.json` with `Get-HarnessConfig`.
  - Call `Resolve-HarnessModel -Agent <ModelAgent> -ModelWasProvided $false`.
  - This is the same chain the reviewer uses, including `AI_HARNESS_MODEL`.
- **It fails if any of these happen:**
  - `lib/config.ps1` is missing or fails to load
  - `.ai/config.json` is not valid JSON
  - `Resolve-HarnessModel` throws, for example when no model is configured and `AI_HARNESS_MODEL` is not set
  - the resolved model is empty or only whitespace
- **Errors never escape.** Every step runs inside `try/catch`, and a failure becomes a reason string. A resolution failure never surfaces as an unhandled exception or as `test-all internal error`.

**Without `-IncludeLive`:**

- The live suite is reported SKIPPED (NOT VERIFIED), as today.
- If resolution succeeded, the detail names the model and the agent. For example: "requires Ollama and model 'deepseek-r1:32b' (agent 'spec-reviewer'); use -IncludeLive."
- If it failed, the detail reads "model could not be resolved (agent 'spec-reviewer'): `<reason>`".
- A resolution failure is **never** a FAIL and never adds a `test-all configuration` result.
- `STATUS` and the exit code depend only on the offline suites and on test-all's own table validation. The existing rule is unchanged: exit 0 only if there is no FAIL and at least one suite passed.

**With `-IncludeLive`:**

- **If resolution fails:**
  - the live suite is reported FAIL with "precondition not met, NOT executed: model could not be resolved (agent 'spec-reviewer'): `<reason>`"
  - **no request is sent**, neither `/api/tags` nor any generation endpoint
  - the run ends with `STATUS: FAIL` and exit 1
- **If resolution succeeds:** the existing precondition runs with the resolved model (`/api/tags` and the matching rule below). Its messages name the resolved model.

**Offline independence:**

- No offline suite depends on Ollama being reachable or on any model being installed.
- test-all contacts Ollama only with `-IncludeLive`, and only after resolution has succeeded.

Before Phase 0, offline runs never read `.ai/config.json`. Now they read it on a best-effort basis, only to name the model in the SKIPPED message. The result can't change the outcome of an offline run.

**Matching:** `Test-OllamaPrecondition` compares model names case-insensitively with `-notcontains`, replacing `-cnotcontains`, so it matches `run-agent.ps1` and FR-010.

**Comment:** the table comment "must match the suite's own -Model default" is removed or corrected.

### FR-015 — No model name in the offline spec suite

**Source:** FACT

`scripts/test-spec.ps1` no longer contains the unused `-Model` parameter or its hardcoded default.

### FR-016 — Regression suite: validator modes

**Source:** USER

A new offline suite `scripts/test-validate-spec.ps1` checks the real validator against fixtures across all modes. It checks exit codes and the FR-002 output lines (AC-001 to AC-008, AC-025, AC-026).

- New fixtures go in `tests/fixtures/`.
- The suite only reads files and needs no sandbox.

### FR-017 — Regression suite: passing the mode through the workflow

**Source:** USER

A new offline suite `scripts/test-mode-propagation.ps1` runs `specify.ps1` with recording mocks. The mocks write what each stage received to a file named by the environment variable `AI_HARNESS_TEST_RECORD_FILE`, under `TEMP`.

**What is covered:**

- every mode, plus the case with no `-Mode`, using a validator that declares `-Mode` (AC-010)
- one revision cycle, so that both validator invocation points run
- an end-to-end documentation run that uses the real validator (AC-011)
- validators without `-Mode` (AC-023, AC-024): the unchanged `validator-success.ps1`, a simple recording validator, and a validator that fails to parse

**Test settings:**

- **Every scenario injects all four scripts.** Each `specify.ps1` run in this suite passes `-RunnerScript`, `-ValidatorScript`, `-ReviewerScript` and `-ReviserScript` explicitly. The only exception is the real `validate-spec.ps1`, which AC-011 names explicitly. No scenario relies on a default, so the real `run-agent.ps1`, `review-spec.ps1` and `revise-spec.ps1` are never invoked and no model request is possible.
- **Second line of defense.** The `test-all` sandbox contains only `scripts/` and `tests/`, not `.ai/`. If a real agent script were ever invoked by mistake, it would stop at "Agent not found" (or the reviewer and reviser equivalent) before reading the config or contacting Ollama.
- The validator that fails to parse is generated under `TEMP` by the suite. It is never committed, because `test-syntax.ps1` parses every `.ps1` under `tests/`.
- The suite runs in `test-all.ps1` with `Isolation = "sandbox"`, because `specify.ps1` writes into `<root>/specs`.
- Spec names start with `test-mock-mode-`.

### FR-018 — Regression suite: reviewer and reviser telemetry and availability

**Source:** USER

A new offline suite `scripts/test-agent-telemetry.ps1` runs the real `review-spec.ps1` and `revise-spec.ps1` without Ollama and without network access (AC-012 to AC-016, AC-027, AC-030).

**Temporary harness root.** The suite builds a new folder under `TEMP` that contains:

- copies of `review-spec.ps1`, `revise-spec.ps1` and `scripts/lib/*.ps1`
- small stub `AGENTS.md`, contract and agent files
- a stub `.ai/config.json` with `ollamaUrl` = `http://127.0.0.1:9`, a loopback port that is not Ollama's

Telemetry goes only to the temporary root's `logs/`, never to the repository's `logs/`. The suite deletes the temporary root when it finishes.

**Fake responses.** Each script under test runs in a child `powershell.exe` in which a function named `Invoke-RestMethod` is defined. The function returns the `/api/tags` and `/api/generate` responses set by each test case, and records every call and its request body.

**Guards against a real request.** These are mandatory:

1. **Configuration check before any case.** A suite function, for example `Test-TempHarnessConfig`, confirms that:
   - the temporary `.ai/config.json` exists
   - it parses as JSON
   - its `ollamaUrl` is exactly `http://127.0.0.1:9`

   If any of these fails, the suite reports FAIL and exits 1 without starting any script under test. At startup the suite also proves that this function rejects:
   - a missing file
   - invalid JSON
   - `http://localhost:11434`
   - any other URL
2. **Fake active check.** In each child process, after defining the fake, the child confirms that `(Get-Command Invoke-RestMethod).CommandType` is `Function` before it runs the script under test. Otherwise it exits with a dedicated code (for example 97), which the suite reports as FAIL.
3. **URL allowlist.** The fake accepts only URIs that start with `http://127.0.0.1:9/`. For any other URI, for example the default `http://localhost:11434` that `Get-HarnessConfig` falls back to when the config is missing, it records a violation and throws, without making a request. Any recorded violation fails the suite.
4. **No other HTTP routes (static check).** The copied scripts contain none of:
   - module-qualified `Microsoft.PowerShell.Utility\Invoke-RestMethod`
   - `Invoke-WebRequest`
   - `System.Net.WebClient`
   - `HttpWebRequest`
   - `HttpClient`

   These would bypass the fake.

Guards 1 and 3 together ensure that a missing or invalid temporary config cannot cause a real Ollama request: the suite refuses to start, and any fallback URL is rejected by the fake. Guards 2 and 4 ensure the fake cannot be bypassed.

### FR-019 — Validators without `-Mode` keep their current invocation

**Source:** USER

This covers every validator for which FR-008 does not confirm a `Mode` parameter. There are two cases, and they are reported differently:

- **Not declared.** Inspection succeeded, and the validator does not declare `Mode`.
- **Not confirmed.** Inspection failed: `Get-Command` threw, or reading `.Parameters` threw. Examples are a script that fails to parse, a `.cmd` file, or a path `Get-Command` cannot resolve. Support for `-Mode` is then unknown, and must not be described as absent.

Both cases are handled as follows:

- **Invocation.** At both invocation points, the validator is called exactly as today, with `-SpecFile <file>` and nothing else. It never receives `-Mode`, either as a parameter or in `$args`.
- **Errors are not raised early.** If the parameter check itself fails, `specify.ps1` does not stop early. The run continues, and the later invocation fails or succeeds exactly as it does today.
- **`requirements` and `baseline` modes.** No warning, and the console output is unchanged. In baseline mode, the harness's own validator applies the same rules as in requirements mode (FR-002), so leaving the mode out does not change the intended rules.
- **`documentation` mode.** `specify.ps1` emits exactly one warning, before Step 1, with `Write-Warning`.
  - `Write-Warning` adds the `WARNING: ` prefix itself, so the message text below does **not** include it, and the implementation must not add it either. The console line therefore starts with exactly one `WARNING: `.
  - **Not declared:**

    `Validator '<path>' does not declare a -Mode parameter. It is called without -Mode, so documentation-mode validation rules are NOT applied; the validator's own default rules are used instead.`

  - **Not confirmed:**

    `Could not read the parameters of validator '<path>' (<reason>), so support for -Mode could not be confirmed. It is called without -Mode, so documentation-mode validation rules are NOT applied; the validator's own default rules are used instead.`

  - The "not confirmed" text must not contain "does not declare".

  In addition:
  - **Summary line.** On successful completion, in either case, the summary line reads `Validation   : PASS (validator called without -Mode; documentation-mode rules NOT applied)` instead of `Validation   : PASS`.
  - **Nothing claims support.** No output, artifact or exit code may state or imply that documentation-mode validation was applied.
  - **Other outcomes are unchanged.** All other results (exit 1, 2 or 3, and their messages) are the same as today. The warning is printed before them.

## Non-Functional Requirements

### NFR-001 — Platform and dependencies

**Source:** PROJECT

All changes run on Windows PowerShell 5.1 and add no modules, packages, executables or network services.

### NFR-002 — Offline, side-effect-free tests

**Source:** USER

Every new or changed offline suite:

- runs without Ollama and opens no connection to it
- writes only under `TEMP` (or inside its `test-all` sandbox)
- leaves the repository tripwire clean
- has no mandatory parameters and ends with an explicit `exit`, as the `test-all` suite contract requires

### NFR-003 — Backward compatibility

**Source:** USER

These keep their parameters, exit codes and output files:

- `run-agent.ps1`, `specify.ps1`, `review-spec.ps1`, `revise-spec.ps1`
- `validate-spec.ps1` when called without `-Mode`
- `benchmark-models.ps1`
- custom `-ValidatorScript` validators that do not declare `-Mode`
- the `AI_HARNESS_MODEL` and `AI_HARNESS_RUN_ID` environment variables

The only intentional changes are:

- the new optional `-Mode` parameter on the validator
- removing the unused `-Model` parameter from `test-spec.ps1`
- the documentation-mode warning and summary note for validators without `-Mode` (FR-019)
- the reviewer and reviser availability check, which makes a missing model fail earlier with the same exit code (FR-010)
- the new telemetry records (FR-011)
- offline `test-all.ps1` reads `.ai/config.json` on a best-effort basis to name the live-suite model in its SKIPPED message. A resolution failure is reported there and never changes the offline result (FR-014)
- with `-IncludeLive`, an unresolvable live-suite model makes the live suite FAIL, without any request to Ollama (FR-014)
- a `Requires = 'ollama'` table entry must have exactly one of `Model` or `ModelAgent` (FR-014)
- the `test-all` live precondition now matches model names case-insensitively (FR-014)

### NFR-004 — Change footprint

**Source:** USER

Only the files listed under "Affected Files" are created or modified. Nothing unrelated is refactored, reformatted or cleaned up.

### NFR-005 — Telemetry compatibility

**Source:** USER

New records use the existing 14-field schema in the existing column order. Existing `logs/model-calls.jsonl` and `logs/model-calls.csv` are only appended to, never rewritten.

## Acceptance Criteria

In every validator case below, "exit N" means running `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\validate-spec.ps1 -SpecFile <fixture> [-Mode <m>]` returns N.

"Non-documentation modes" means three runs: no `-Mode`, `-Mode requirements` and `-Mode baseline`.

### AC-001 — Exit codes without documentation mode are unchanged

**Source:** USER

Verifies: FR-001, FR-002, FR-016, NFR-003.

In each non-documentation mode:

| Fixture | Exit code |
|---|---|
| `invalid-spec.md` | 1 |
| `minimal-valid-spec.md` | 0 |
| `semantic-invalid-spec.md` | 0 |
| `valid-spec.md` | 1 |
| `documentation-none-spec.md` | 3 |
| `documentation-lowercase-none-spec.md` | 3 |
| `documentation-fenced-none-spec.md` | 3 |
| `documentation-none-period-spec.md` | 1 |

These match the pre-Phase-0 behavior recorded in Context. An invalid mode value (for example `-Mode foo`) gives a non-zero exit and no `STATUS: PASS`.

### AC-002 — Descriptive documentation spec passes

**Source:** USER

Verifies: FR-001, FR-003, FR-006, FR-016.

`documentation-none-spec.md` exits 0 with `-Mode documentation`. The fixture has:

- descriptive Context text
- exactly `None` for FR, NFR, AC and the other optional sections
- no `**Source:**` lines

### AC-003 — Missing documentation context is insufficient input

**Source:** USER

Verifies: FR-004, FR-016.

These exit 3 with `-Mode documentation` and print `STATUS: INSUFFICIENT INPUT`:

- `documentation-no-context-spec.md` (Context `None`; FR, NFR and AC `None`)
- `documentation-empty-context-spec.md` (empty Context section; FR, NFR and AC `None`)

### AC-004 — FR without AC is rejected in documentation mode

**Source:** USER

Verifies: FR-005, FR-016.

`documentation-fr-without-ac-spec.md` exits 1 with `-Mode documentation` and prints "No acceptance criteria found." The fixture has:

- Context text
- one `### FR-001` with `**Source:** USER`
- AC `None`

### AC-005 — FR with AC passes in documentation mode

**Source:** USER

Verifies: FR-005, FR-016.

These exit 0 with `-Mode documentation`:

- `documentation-fr-with-ac-spec.md` (Context text; FR-001 and AC-001, each with a valid Source)
- `minimal-valid-spec.md`
- `semantic-invalid-spec.md`

### AC-006 — Invalid Source values are rejected in documentation mode

**Source:** USER

Verifies: FR-006, FR-016.

`documentation-invalid-source-spec.md` exits 1 with `-Mode documentation` and prints "Invalid requirement source". The fixture has:

- Context text
- FR and AC `None`
- one `### NFR-001` with `**Source:** GUESS`

### AC-007 — Entries without Source are rejected in documentation mode

**Source:** USER

Verifies: FR-006, FR-016.

`documentation-entry-without-source-spec.md` exits 1 with `-Mode documentation` and prints "No requirement source annotations found." The fixture has:

- Context text
- FR-001 and AC-001
- no `**Source:**` lines

### AC-008 — Unstructured FR or AC sections are rejected in documentation mode

**Source:** USER

Verifies: FR-007, FR-016.

These exit 1 with `-Mode documentation`:

- `documentation-prose-fr-spec.md` (Context text; prose with no IDs in the FR section; AC `None`). The message names "Functional Requirements".
- `documentation-prose-ac-spec.md` (Context text; FR `None`; prose with no IDs in the AC section). The message names "Acceptance Criteria".

### AC-009 — The existing offline spec suite still passes

**Source:** FACT

Verifies: FR-015, FR-019, NFR-003.

After the changes, `scripts/test-spec.ps1` reports `Passed: 17`, `Failed: 0` and `STATUS: PASS`. This is the verified baseline count: 13 exit-code cases and 4 artifact checks. The only change to the suite is removing its parameter (FR-015).

The suite injects the unchanged `validator-success.ps1` and `validator-error.ps1`, which don't declare `-Mode`. Passing therefore also shows that FR-019 keeps validators without `-Mode` working in requirements mode.

### AC-010 — The mode reaches every stage

**Source:** USER

Verifies: FR-008, FR-017.

For each mode M in `requirements`, `baseline` and `documentation`:

1. `specify.ps1 -Mode M` is run with:
   - `-RunnerScript recording-runner.ps1`
   - `-ValidatorScript recording-validator.ps1` (declares `-Mode`)
   - `-ReviewerScript recording-reviewer.ps1`, which returns FAIL on its first call and PASS after that
   - `-ReviserScript recording-reviser.ps1`
2. It exits 0.
3. The record file contains exactly these six entries, in this order:
   - `runner|M` (read from the task's `SPECIFICATION MODE (AUTHORITATIVE):` line)
   - `validator|M`
   - `reviewer|M`
   - `reviser|M`
   - `validator|M`
   - `reviewer|M`

The same run without `-Mode` records `requirements` in all six entries.

### AC-011 — End-to-end documentation workflow with the real validator

**Source:** USER

Verifies: FR-003, FR-008, FR-017.

`specify.ps1 -Mode documentation` with these scripts exits 0:

- `-RunnerScript runner-documentation.ps1`, which writes a spec equivalent to `documentation-none-spec.md`
- `-ValidatorScript` set to the **real** `validate-spec.ps1`, which declares `-Mode`
- `-ReviewerScript reviewer-pass.ps1`
- `-ReviserScript reviser-success.ps1` (injected so no default is used, even though it is not reached)

The output contains no FR-019 warning. The same run without `-Mode` exits 3 and prints "Specification Needs Human Input".

### AC-012 — A successful reviewer call is logged

**Source:** USER

Verifies: FR-011, FR-012, FR-018, NFR-005.

In `test-agent-telemetry.ps1`:

1. The fake `/api/tags` lists `phase0-fake:1b`.
2. The fake `/api/generate` returns a review that contains `## Status` followed by `PASS`, with `eval_count = 10`.
3. `review-spec.ps1 -Model phase0-fake:1b -OutputFile <tmp>` then:
   - exits 0
   - prints `Review Status: PASS`
   - writes the output file
4. The temporary `logs/model-calls.jsonl` gains exactly one line, with:
   - `agent = spec-reviewer`
   - `model = phase0-fake:1b`
   - `status = success`
   - `eval_count = 10`
5. The temporary `logs/model-calls.csv` header has the same 14 columns, in the same order, as the header written by the current `Write-HarnessModelTelemetry`.

### AC-013 — Failed reviewer and reviser calls are logged

**Source:** USER

Verifies: FR-011, FR-012, FR-018.

The fake `/api/tags` lists the model, and the fake `/api/generate` throws. Then:

- **Reviewer:** `review-spec.ps1` exits 2 and prints `=== OLLAMA ERROR ===`.
- **Reviser:** `revise-spec.ps1` exits with a non-zero code.
- **Telemetry:** each run adds exactly one line, with `status = error`, a non-empty `error`, and `agent` set to `spec-reviewer` or `spec-reviser` as appropriate.

### AC-014 — A missing model stops the call before generation

**Source:** USER

Verifies: FR-010, FR-018.

When the fake `/api/tags` does not list the requested model:

- `review-spec.ps1` exits 2 and `revise-spec.ps1` exits with a non-zero code
- the output contains "Model not found" followed by the model name
- the fake records **zero** `/api/generate` calls
- **zero** telemetry lines are written

A further case: the fake lists `PHASE0-FAKE:1B` and the script requests `phase0-fake:1b`. The model is then treated as installed and generation proceeds (case-insensitive, FR-010).

### AC-015 — Unreachable Ollama stops the call before generation

**Source:** USER

Verifies: FR-010, FR-018.

When the fake `/api/tags` throws:

- `review-spec.ps1` exits 2 and `revise-spec.ps1` exits with a non-zero code
- the output contains "Ollama is not reachable at"
- zero `/api/generate` calls are recorded
- zero telemetry lines are written

### AC-016 — A successful reviser call is logged

**Source:** USER

Verifies: FR-011, FR-012, FR-018.

With a fake `/api/generate` that returns a spec, `revise-spec.ps1 -Model phase0-fake:1b -OutputFile <tmp>`:

- exits 0
- writes the output file with the returned text
- adds exactly one telemetry line with `agent = spec-reviser` and `status = success`

### AC-017 — Prompts are byte-identical (one-time check)

**Source:** USER

Verifies: FR-012.

1. **Get the "before" versions.** Extract the pre-change `review-spec.ps1`, `revise-spec.ps1` and `lib/config.ps1` from commit `2e85dbe` into a temporary harness root under `TEMP`, using `git show`.
2. **Capture.** Run the FR-018 harness, with the same stub inputs, against the "before" versions and against the changed versions, and capture the `system` and `prompt` fields that each sends.
3. **Compare.** The SHA-256 hashes must be identical for both the reviewer and the reviser.
4. **Record.** Put the hashes in the implementation report.

### AC-018 — No model names in the changed test scripts

**Source:** USER

Verifies: FR-013, FR-014, FR-015.

None of these model names appears in `scripts/test-spec.ps1`, `scripts/test-spec-integration.ps1` or `scripts/test-all.ps1`:

- `qwen2.5-coder:32b`
- `qwen2.5-coder:7b`
- `deepseek-r1:32b`

Check with `Select-String -SimpleMatch`. A match is allowed only in a comment that explains the deferral.

### AC-019 — test-all reports the configured reviewer model

**Source:** USER

Verifies: FR-014.

Run `scripts/test-all.ps1` without `-IncludeLive`, with the current `.ai/config.json` and `AI_HARNESS_MODEL` not set. Then:

- `test-spec-integration.ps1` is reported `SKIPPED`
- its detail line names `deepseek-r1:32b`, the configured `spec-reviewer` model
- no `test-all configuration` FAIL is reported

### AC-020 — The live reviewer test resolves its model like production (inspection)

**Source:** USER

Verifies: FR-013.

Checked by reading the code, with no execution:

- `test-spec-integration.ps1` passes `-Model` to `review-spec.ps1` only when its own `-Model` was given (`$PSBoundParameters`)
- it prints the model resolved through `Resolve-HarnessModel -Agent spec-reviewer`

**Deferred, not a Phase 0 exit criterion:** a live run with `-IncludeLive` once Ollama is running with `deepseek-r1:32b` installed. It is reported as NOT VERIFIED until that run happens.

### AC-021 — Full offline regression run

**Source:** USER

Verifies: FR-016, FR-017, FR-018, NFR-001, NFR-002.

`scripts/test-all.ps1` without `-IncludeLive`:

- exits 0 with `STATUS: PASS WITH SKIPS`
- discovers the three new suites (`test-validate-spec.ps1`, `test-mode-propagation.ps1`, `test-agent-telemetry.ps1`)
- reports every suite except `test-spec-integration.ps1` as PASS
- reports `test-spec-integration.ps1` as SKIPPED
- has every tripwire `clean`

`test-syntax.ps1` passes, which means all new and changed `.ps1` files parse.

### AC-022 — Only the expected files change

**Source:** USER

Verifies: NFR-001, NFR-004.

`git status --porcelain` lists only:

- the files under "Affected Files"
- this spec
- the files that were already untracked or modified before Phase 0 started

`tests/mocks/validator-success.ps1` and `tests/mocks/validator-error.ps1` are unchanged. No new module manifests, packages or binaries are added.

### AC-023 — Validators without `-Mode` keep working, with an honest warning

**Source:** USER

Verifies: FR-017, FR-019.

Run with:

- `-RunnerScript runner-success.ps1`
- `-ValidatorScript validator-success.ps1`, unchanged: an advanced script without `-Mode`, so this is the "not declared" case
- `-ReviewerScript reviewer-pass.ps1`
- `-ReviserScript reviser-success.ps1`

**In documentation mode,** `specify.ps1 -Mode documentation`:

- exits 0. Because that script would reject `-Mode` with a binding error, exit 0 proves `-Mode` was not passed.
- prints exactly one line that starts with `WARNING: ` and contains:
  - "does not declare a -Mode parameter"
  - "documentation-mode validation rules are NOT applied"
- does not contain `WARNING: WARNING:` anywhere in its output
- prints the summary line `Validation   : PASS (validator called without -Mode; documentation-mode rules NOT applied)`

**In baseline mode,** `specify.ps1 -Mode baseline`:

- exits 0
- prints no FR-019 warning
- prints the plain summary line `Validation   : PASS`

### AC-024 — Both invocation points treat validators without `-Mode` the same way

**Source:** USER

Verifies: FR-008, FR-017, FR-019.

**Simple validator ("not declared" case).** Run `specify.ps1 -Mode documentation` with:

- `-RunnerScript recording-runner.ps1`
- `-ValidatorScript recording-validator-legacy.ps1`, a simple script without `-Mode` that records `validator-legacy|args=<count of $args>`
- `-ReviewerScript recording-reviewer.ps1` (FAIL, then PASS)
- `-ReviserScript recording-reviser.ps1`

Then:

- The run exits 0.
- The record shows two validator entries, both `args=0`. Neither invocation point passed `-Mode`, either bound or in `$args`.

**Validator that fails to parse ("not confirmed" case).** The suite generates, under `TEMP`, a validator that fails to parse. It runs `specify.ps1` with:

- `-RunnerScript recording-runner.ps1`
- `-ValidatorScript <the generated validator>`
- `-ReviewerScript recording-reviewer.ps1`
- `-ReviserScript recording-reviser.ps1`

It runs this twice: once with `-Mode requirements` and once with `-Mode documentation`. In both runs:

- The record file contains exactly one entry, the runner's (`runner|requirements` or `runner|documentation`). This proves the parameter check did not stop the run before Step 1, and that no later stage ran.
- The run exits 2. This is a fixed expected value in the suite. The suite does not need Git.

In the requirements run, no FR-019 warning is printed.

In the documentation run, exactly one line starting with `WARNING: ` is printed. It:

- contains "support for -Mode could not be confirmed"
- does not contain "does not declare"

**One-time check:** in the implementation, confirm that the unchanged `specify.ps1` from commit `2e85dbe`, extracted into `TEMP` with `git show`, also exits 2 for the same generated validator and the same injected mocks with `-Mode requirements`. Record the result in the implementation report.

### AC-025 — The None marker follows the agreed semantics

**Source:** USER

Verifies: FR-002, FR-004, FR-007, FR-016.

| Fixture | Content | Non-documentation modes | `-Mode documentation` |
|---|---|---|---|
| `documentation-lowercase-none-spec.md` | Context text; FR `none`; NFR `None`; AC `NONE` | exit 3 | exit 0 |
| `documentation-fenced-none-spec.md` | Context text; FR and AC each a fenced `None` | exit 3 | exit 0 |
| `documentation-none-period-spec.md` | Context `None.`; FR `None.`; AC `None` | exit 1, with the three errors listed in Context | exit 1 |

For `documentation-none-period-spec.md` in documentation mode:

- the error names "Functional Requirements" (FR-007)
- `INSUFFICIENT INPUT` does not appear, which proves that `None.` in Context counts as text

### AC-026 — Output lines in non-documentation modes are unchanged

**Source:** USER

Verifies: FR-002, FR-016, NFR-003.

**In `test-validate-spec.ps1`:** in each non-documentation mode, take the validator's output and remove three kinds of lines:

- blank lines
- the `File:` line
- the one optional mode line

What remains must be exactly this sequence: the header line `=== Specification Validator ===`, followed by the lines for the fixture below, in this order.

| Fixture | Lines after the header |
|---|---|
| `invalid-spec.md` | `STATUS: FAIL`, `Missing required sections:`, then `- ## Context`, `- ## Functional Requirements`, `- ## Non-Functional Requirements`, `- ## Acceptance Criteria`, `- ## Edge Cases`, `- ## Dependencies`, `- ## Open Questions`, `- ## Assumptions` |
| `valid-spec.md` | `STATUS: FAIL`, `Validation errors:`, `- No requirement source annotations found.` |
| `minimal-valid-spec.md` | `STATUS: PASS`, `All required specification checks passed.` |
| `documentation-none-spec.md` | `STATUS: INSUFFICIENT INPUT`, `The task did not contain enough information. See Open Questions.` |
| `documentation-none-period-spec.md` | `STATUS: FAIL`, `Validation errors:`, `- No functional requirements found.`, `- No acceptance criteria found.`, `- No requirement source annotations found.` |

**One-time check:** run the validator extracted from commit `2e85dbe` into `TEMP` and the changed validator on every fixture in `tests/fixtures/`, without `-Mode`. Their complete outputs must be identical, apart from the optional mode line. Record the result in the implementation report.

### AC-027 — Telemetry uses `AI_HARNESS_RUN_ID` when it is set

**Source:** USER

Verifies: FR-011, FR-018.

**With the variable set.** In `test-agent-telemetry.ps1`, set `AI_HARNESS_RUN_ID=phase0-run-id-test` in the child process. A successful reviewer call and a successful reviser call each write a record with `run_id = phase0-run-id-test`.

**With the variable unset or blank.** Leave the variable unset, or set it to only spaces. The `run_id` then parses as a `[guid]`.

### AC-028 — test-all resolves the live-suite model on a best-effort basis (one-time check)

**Source:** USER

Verifies: FR-014, NFR-002.

**Setup.** Build a temporary root under `TEMP` containing:

- a copy of the changed `scripts/test-all.ps1`
- a copy of `scripts/lib/config.ps1`
- one stub suite (`exit 0`) for each name in test-all's table: `test-syntax.ps1`, `test-spec.ps1`, `test-spec-integration.ps1`, `test-mode-propagation.ps1`

The stubs never call a model. `AI_HARNESS_MODEL` is unset.

**Fake for `Invoke-RestMethod`.** Every run of the copied test-all starts in a child `powershell.exe` that first defines a function named `Invoke-RestMethod`. The function records each call and throws, and the child confirms the function is active before it starts test-all. Any configuration that contains a URL uses `ollamaUrl` = `http://127.0.0.1:9`.

**Resolution cases:**

- (a) `.ai/config.json` is missing
- (b) it is invalid JSON
- (c) it is valid JSON with neither `agentModels.spec-reviewer` nor `defaultModel`
- (d) `agentModels.spec-reviewer` is `"  "`

**Each of (a) to (d) without `-IncludeLive`:**

- exits 0 with `STATUS: PASS WITH SKIPS`
- reports `test-spec-integration.ps1` as SKIPPED, with a detail containing "model could not be resolved", `spec-reviewer` and the reason
- shows no FAIL line, no `test-all configuration` result, no `test-all internal error` and no unhandled exception text

**Each of (a) to (d) with `-IncludeLive`:**

- exits 1 with `STATUS: FAIL`
- reports `test-spec-integration.ps1` as FAIL with "precondition not met, NOT executed: model could not be resolved" plus the reason
- records **zero** calls to the fake: no `/api/tags` and no generation request
- does not execute the stub `test-spec-integration.ps1`

**Other cases:**

- **(e) Valid config, without `-IncludeLive`:** `agentModels.spec-reviewer` is `phase0-fake:1b`. The run exits 0, and the SKIPPED detail names `phase0-fake:1b`.
- **(f) Bad table entry:** in the copied test-all, the `test-spec-integration.ps1` entry has neither `Model` nor `ModelAgent`. With a valid config, the run reports a `test-all configuration` FAIL and exits 1, both without and with `-IncludeLive`. With `-IncludeLive`, it records zero calls to the fake.

**Recording.** Put the results in the implementation report.

This check is one-time for two reasons. A permanent suite would have to run test-all from inside test-all. And these runs use a TEMP copy with stub suites and a fake `Invoke-RestMethod`, so they are not live runs of the repository's test-all.

### AC-029 — Model names are matched without regard to case (inspection)

**Source:** USER

Verifies: FR-010, FR-014.

Check by reading the code:

- The FR-010 availability helper compares model names with `-contains` or `-notcontains`.
- `Test-OllamaPrecondition` in `test-all.ps1` does the same.
- Neither uses `-ccontains` or `-cnotcontains`.

The case-insensitive behavior of the helper is also exercised by AC-014.

### AC-030 — The telemetry suite cannot reach a real server

**Source:** USER

Verifies: FR-018, NFR-002.

**At startup,** `test-agent-telemetry.ps1`:

- shows that its configuration check rejects:
  - a missing `.ai/config.json`
  - invalid JSON
  - `ollamaUrl` = `http://localhost:11434`
  - `ollamaUrl` = `http://127.0.0.1:10`
- shows that the configuration check accepts the real temporary config
- passes the static check of guard 4: no forbidden HTTP route in the copied scripts

**In every case it runs:**

- the child process reports that the fake was active (guard 2)
- the fake records zero URL-allowlist violations (guard 3)

The suite also includes one case in which the temporary `.ai/config.json` is deleted before `review-spec.ps1` runs, which bypasses guard 1. This shows the result is a recorded violation and a failed request, never a network call:

- the fake records a violation for `http://localhost:11434/api/tags`
- `review-spec.ps1` exits 2
- the suite counts this as the expected outcome of that negative case

## Traceability Matrix

This table is the inverse of the `Verifies:` lines above. The two must stay identical.

| Requirement | Acceptance criteria |
|---|---|
| FR-001 | AC-001, AC-002 |
| FR-002 | AC-001, AC-025, AC-026 |
| FR-003 | AC-002, AC-011 |
| FR-004 | AC-003, AC-025 |
| FR-005 | AC-004, AC-005 |
| FR-006 | AC-002, AC-006, AC-007 |
| FR-007 | AC-008, AC-025 |
| FR-008 | AC-010, AC-011, AC-024 |
| FR-010 | AC-014, AC-015, AC-029 |
| FR-011 | AC-012, AC-013, AC-016, AC-027 |
| FR-012 | AC-012, AC-013, AC-016, AC-017 |
| FR-013 | AC-018, AC-020 |
| FR-014 | AC-018, AC-019, AC-028, AC-029 |
| FR-015 | AC-009, AC-018 |
| FR-016 | AC-001, AC-002, AC-003, AC-004, AC-005, AC-006, AC-007, AC-008, AC-021, AC-025, AC-026 |
| FR-017 | AC-010, AC-011, AC-021, AC-023, AC-024 |
| FR-018 | AC-012, AC-013, AC-014, AC-015, AC-016, AC-021, AC-027, AC-030 |
| FR-019 | AC-009, AC-023, AC-024 |
| NFR-001 | AC-021, AC-022 |
| NFR-002 | AC-021, AC-028, AC-030 |
| NFR-003 | AC-001, AC-009, AC-026 |
| NFR-004 | AC-022 |
| NFR-005 | AC-012 |

| Defect | Covered by |
|---|---|
| D-01 | FR-001 to FR-008, FR-016, FR-017, FR-019 |
| D-02 | FR-011, FR-012, FR-018 |
| D-03 | FR-010, FR-018 |
| D-04 | FR-013 to FR-015 (benchmark deferred, OD-02) |
| D-05 | FR-008, FR-017, FR-019 |
| D-06 | FR-013, FR-014 |

## Affected Files

These are based on inspecting the repository on 2026-11-19. Line references are to `2e85dbe`.

**Modified:**

| File | Change | Requirements |
|---|---|---|
| `scripts/validate-spec.ps1` | Add the `-Mode` parameter and the documentation-mode rules. The requirements and baseline paths stay unchanged. | FR-001 to FR-007 |
| `scripts/specify.ps1` | Check once whether the validator declares `Mode`. Build the arguments for both validator calls (lines 155 and 330-331) the same way. Add the documentation-mode warning and the summary note for validators without `-Mode`. | FR-008, FR-019 |
| `scripts/lib/config.ps1` | Add the availability-check helper (case-insensitive). Add optional telemetry parameters to `Invoke-HarnessGenerate` (calls without them are unchanged). | FR-010, FR-011 |
| `scripts/review-spec.ps1` | Dot-source `lib/telemetry.ps1`, run the availability check before generation, and pass the telemetry agent and root. Prompt text unchanged. | FR-010 to FR-012 |
| `scripts/revise-spec.ps1` | Same as `review-spec.ps1`. | FR-010 to FR-012 |
| `scripts/test-spec-integration.ps1` | Remove the default model; resolve the model through config; pass `-Model` only when given. | FR-013 |
| `scripts/test-all.ps1` | Add the `ModelAgent` field and the rule that a live entry has exactly one of `Model` or `ModelAgent`. Resolve the model through `lib/config.ps1` on a best-effort basis: offline, a failure only appears in the SKIPPED detail; with `-IncludeLive`, it is a FAIL and no request is sent. Name the resolved model in messages. Change `-cnotcontains` to `-notcontains`. Fix the table comment. Add a sandbox entry for `test-mode-propagation.ps1`. | FR-014, FR-017 |
| `scripts/test-spec.ps1` | Remove the unused `param([string]$Model = …)`. | FR-015 |

**New:**

| File | Purpose | Requirements |
|---|---|---|
| `scripts/test-validate-spec.ps1` | Validator mode × fixture matrix, with exit codes and output lines | FR-016 |
| `scripts/test-mode-propagation.ps1` | Passing the mode through the workflow, the documentation end-to-end run, and validators without `-Mode` | FR-017 |
| `scripts/test-agent-telemetry.ps1` | Reviewer and reviser availability and telemetry, offline, with all FR-018 guards | FR-018 |
| `tests/fixtures/documentation-none-spec.md` | Descriptive documentation; FR, NFR and AC `None` | AC-001, AC-002, AC-026 |
| `tests/fixtures/documentation-no-context-spec.md` | Context `None` | AC-003 |
| `tests/fixtures/documentation-empty-context-spec.md` | Empty Context section | AC-003 |
| `tests/fixtures/documentation-fr-without-ac-spec.md` | FR present, AC `None` | AC-004 |
| `tests/fixtures/documentation-fr-with-ac-spec.md` | FR and AC present | AC-005 |
| `tests/fixtures/documentation-invalid-source-spec.md` | NFR with an invalid Source | AC-006 |
| `tests/fixtures/documentation-entry-without-source-spec.md` | Entries with no Source lines | AC-007 |
| `tests/fixtures/documentation-prose-fr-spec.md` | Unstructured FR section | AC-008 |
| `tests/fixtures/documentation-prose-ac-spec.md` | Unstructured AC section | AC-008 |
| `tests/fixtures/documentation-lowercase-none-spec.md` | `none` / `NONE` markers | AC-001, AC-025 |
| `tests/fixtures/documentation-fenced-none-spec.md` | Fenced `None` markers | AC-001, AC-025 |
| `tests/fixtures/documentation-none-period-spec.md` | `None.` as ordinary text | AC-001, AC-025, AC-026 |
| `tests/mocks/recording-runner.ps1` | Writes a valid spec and records the mode from the task text | FR-017 |
| `tests/mocks/recording-validator.ps1` | Declares `-Mode`, records it, exits 0 | FR-017 |
| `tests/mocks/recording-validator-legacy.ps1` | Simple script without `-Mode` that records the number of `$args` and exits 0 | FR-017, FR-019 |
| `tests/mocks/recording-reviewer.ps1` | Records `-Mode`; FAIL on its first call per record file, then PASS | FR-017 |
| `tests/mocks/recording-reviser.ps1` | Records `-Mode` and writes a valid spec | FR-017 |
| `tests/mocks/runner-documentation.ps1` | Writes a documentation-mode spec (FR, NFR and AC `None`) | AC-011 |

**Generated at test time under `TEMP`, never committed:**

- the validator that fails to parse (AC-024)
- the temporary harness roots (FR-018, AC-017, AC-024, AC-026, AC-028)
- the copies extracted from commit `2e85dbe`

**Not modified:**

- `scripts/run-agent.ps1`
- `scripts/lib/telemetry.ps1`
- `scripts/benchmark-models.ps1`
- `scripts/scan-repository.ps1`, `scripts/build-context.ps1` and their suites
- `scripts/test-run-agent.ps1`, `scripts/test-syntax.ps1`
- all existing mocks, including `validator-success.ps1` and `validator-error.ps1`
- all existing fixtures
- `.ai/config.json`, `.ai/agents/*`, `.ai/rules/*`
- `AGENTS.md`, `README.md`

## Execution Order

There are four work packages (WP), and each one is a separate commit. Run `scripts/test-all.ps1` offline after each one. WP-B was removed in Revision 1 because the existing validator mocks no longer need to change.

| Step | Work package | Depends on | Exit check |
|---|---|---|---|
| 0 | Record the baseline: offline `test-all` (done: PASS WITH SKIPS; `test-spec` at 17/0) and the current validator results (recorded in Context). | — | Baseline recorded |
| 1 | **WP-A Validator.** FR-001 to FR-007, the new fixtures and `test-validate-spec.ps1` (FR-016), including the AC-026 one-time comparison. | Step 0 | AC-001 to AC-008, AC-025, AC-026 |
| 2 | **WP-C Workflow.** FR-008 and FR-019, the recording mocks, `runner-documentation.ps1`, `test-mode-propagation.ps1`, and the `test-all` sandbox entry (FR-017). | WP-A | AC-009, AC-010, AC-011, AC-023, AC-024 |
| 3a | **WP-D Harness first.** Build the FR-018 harness and its guards, and confirm that a function can stand in for `Invoke-RestMethod` when a script file is run with `&` (A-02). | — | AC-030 startup checks |
| 3b | **WP-D Changes.** FR-010 and FR-011 in `lib/config.ps1`, `review-spec.ps1` and `revise-spec.ps1`, plus the full `test-agent-telemetry.ps1` and the AC-017 prompt comparison. | 3a | AC-012 to AC-017, AC-027, AC-030 |
| 4 | **WP-E Test models and test-all.** FR-013, FR-014, FR-015. | WP-C, because both edit the `test-all` table | AC-018, AC-019, AC-020 (inspection), AC-028 |
| 5 | Final QA, independent review and human approval. | All (WP-A, WP-C, WP-D, WP-E complete) | AC-021, AC-022, AC-029 |

Why WP-C depends on WP-A: at run time it doesn't. The parameter check makes `specify.ps1` safe with either validator; the old one is simply called as before. But AC-011 needs the new validator's documentation-mode rules.

WP-D can be done in parallel with WP-A, WP-C and WP-E. WP-E must come after WP-C.

AC-029 is checked in step 5, because it inspects code from both WP-D (the availability helper) and WP-E (the `test-all` precondition), and WP-D may finish after WP-E.

## Offline Verification Strategy

- **Who verifies.** Only commands actually run during implementation count as verification. Local model output is never verification.
- **Static checks.**
  - `test-syntax.ps1` must parse all new and changed `.ps1` files.
  - Run the AC-018 `Select-String` check.
  - Do the AC-029 inspection.
  - Run the guard 4 check of FR-018.
- **Validator (AC-001 to AC-008, AC-025, AC-026).**
  - Run the real `validate-spec.ps1` as a child `powershell.exe`, once per fixture and mode.
  - Check the exit code and the expected output lines.
  - This only reads files and needs no isolation.
- **Workflow (AC-009 to AC-011, AC-023, AC-024).**
  - Run `specify.ps1` with all four scripts injected in every scenario (FR-017). Only AC-011 injects the real validator; no scenario uses a default script.
  - Run inside the `test-all` sandbox (a byte-identical copy of `scripts/` and `tests/`, with `TEMP` redirected).
  - Use a record file under the sandbox `TEMP`.
  - Use spec names that match `specs/test-*`.
- **Reviewer and reviser (AC-012 to AC-017, AC-027, AC-030).**
  - Run against a temporary harness root under `TEMP`, never the repository `logs/`.
  - Fake `Invoke-RestMethod` with a function in the child process.
  - All four FR-018 guards apply.
- **One-time comparisons (AC-017, AC-024 parse case, AC-026, AC-028).**
  - Extract the pre-change scripts from commit `2e85dbe` into `TEMP` with `git show`.
  - Record the results in the implementation report.
- **Repository safety.** Every suite runs under the `test-all` tripwire (SHA-256 snapshot before and after each suite).
- **Final gate.** AC-021 and AC-022.
- **Not verified in Phase 0** (report these as NOT VERIFIED, never as passed):
  - the live suite (`test-spec-integration.ps1`, AC-020 deferred part)
  - real model behavior in documentation mode
  - telemetry from a real Ollama response
  - `benchmark-models.ps1`
- **Never run during Phase 0:**
  - the repository's `test-all.ps1 -IncludeLive`. AC-028 runs a TEMP copy of test-all, with stub suites and a fake `Invoke-RestMethod`; that is not a live run and cannot reach Ollama.
  - `specify.ps1`, `review-spec.ps1` or `revise-spec.ps1` against the real config without the fakes
  - `benchmark-models.ps1`

## Edge Cases

- **Variants of `None`.** Defined by the None-marker definition (OD-05):
  - `none`, `NONE` and a fenced `None` are the marker.
  - `None.` is text. In documentation mode, an FR or AC section containing `None.` fails FR-007, and Context `None.` counts as context. Covered by AC-025.
- **Context with only whitespace or an empty code fence.** Treated as empty, so exit 3 in documentation mode.
- **Section capture fails.** The section-capture pattern (`(?=^## )`) may not match a section that is the last `## ` heading. Context and FR are always followed by another required section in specs that pass the section check, but the implementation must still treat a failed capture as empty.
- **AC entries without FR entries in documentation mode.** Allowed (FR-005). Whether they are semantically justified is left to the reviewer.
- **A validator declares `-Mode` but restricts its values,** for example a `ValidateSet` without `documentation`. Declaring `Mode` means accepting the three harness values. Any other value set produces a binding error, which becomes workflow exit 2 (the existing trap). This is documented, not handled.
- **A validator reads `-Mode` from `$args` without declaring it.** It is treated as not declaring `Mode` and gets no `-Mode` (FR-019). This matches today's behavior.
- **`baseline` mode with a validator that doesn't declare `-Mode`.** No warning (FR-019). A custom validator's own default rules apply, as they do today.
- **Revision validation exit 3.** In documentation mode, if a revised spec has Context `None`, the validator exits 3. `specify.ps1` maps that to 2 ("failed structural validation"), which is current behavior and out of scope.
- **A reviewer call that succeeds but returns empty text or no `## Status`.** Telemetry records `success`, because the request succeeded. The reviewer still exits 2. This matches run-agent, which logs `success` before rejecting an empty result.
- **`/api/tags` returns a name that differs only in case.** Treated as installed (FR-010, FR-014). `name` versus `name:latest` is still not normalized.
- **`AI_HARNESS_MODEL` is set.** The integration suite, `test-all` and the reviewer all resolve through the same `Resolve-HarnessModel` chain, so they agree. With the variable set, test-all's resolution succeeds even if `.ai/config.json` is missing, which is consistent with the reviewer.
- **Telemetry write failure** (locked file, read-only `logs/`). A warning is printed and exit codes are unchanged.
- **Invalid `-Mode` passed directly to the validator.** PowerShell's parameter binding rejects it with exit 1, the same code as FAIL. This is existing behavior for argument errors.

## Dependencies

- **Phase 0 depends on nothing** from later phases. Phase 1 (registry v2) depends on Phase 0 being complete and approved.
- **Runtime:** Windows PowerShell 5.1. No Ollama is needed for any Phase 0 exit criterion.
- **Internal dependencies:**
  - WP-C depends on WP-A, for its AC-011 exit check only.
  - WP-E depends on WP-C, because both edit the `test-all` table.
  - WP-D is independent.
- **Tooling:** the one-time comparisons (AC-017, AC-024, AC-026) use `git show 2e85dbe:<path>`, which is read-only.
- **Existing test infrastructure:**
  - the `test-all.ps1` suite contract
  - sandbox isolation and the repository tripwire

## Risks and Rollback

| ID | Risk | Mitigation |
|---|---|---|
| RK-01 | Documentation-mode logic changes the result in requirements or baseline mode. | Keep the non-documentation path as the unchanged code path. AC-001 checks exit codes, AC-026 checks output lines plus a one-time full comparison, and AC-009 runs the existing suite. |
| RK-02 | Documentation mode is used to skip AC for real functional work. | FR-005 (FR requires AC) and FR-007 (no unstructured FR or AC). The mode is chosen explicitly by the caller and is checked semantically by the reviewer. |
| RK-03 | The parameter check gives the wrong answer, so a validator gets `-Mode` when it shouldn't, or doesn't get it when it should. | The check uses PowerShell's own parameter metadata and only parses the script. If it fails, the old invocation is used (FR-019). AC-023 covers an advanced script without `-Mode`; AC-024 covers a simple script, a script that fails to parse, and both invocation points. |
| RK-04 | A validator without `-Mode` is mistaken for a documentation-aware one. | The mandatory FR-019 warning and summary note. FR-019 forbids any output that implies documentation-mode rules were applied. |
| RK-05 | The live reviewer test now uses `deepseek-r1:32b` (about 2.2 tokens/s here). It is slower and may hit the 900 s `timeoutSec`, which is not fixed in Phase 0. | Recorded. The live suite is not a Phase 0 exit criterion. Revisit together with the timeout decision. |
| RK-06 | The telemetry suite makes a real HTTP request. | The four FR-018 guards and the AC-030 negative cases. |
| RK-07 | A broken `.ai/config.json`, or a live-suite model that doesn't resolve, goes unnoticed in an offline run, because the run still passes with skips. | By design (FR-014, OD-06): the offline suites don't use the config. The reason is printed in the live suite's SKIPPED detail, any `-IncludeLive` run fails with that reason, and the live suite is never reported as verified. AC-028 covers both modes. |
| RK-08 | The extra `/api/tags` call in the reviewer and reviser adds up to 15 s when Ollama hangs. | The same trade-off run-agent already makes. A missing model now fails earlier, with a clearer message and the same exit code. |
| RK-09 | More telemetry lines are written, or records are written with the wrong schema. | Same function, same 14 fields (NFR-005, AC-012). Only appends. |
| RK-10 | Prompt text changes by accident while telemetry is being wired in. | The AC-017 hash comparison against the scripts from `2e85dbe`. |

**Rollback.** Each WP is one commit and is reverted with `git revert`. No data migration is needed. `.ai/config.json`, the telemetry schema and the existing mocks are never changed, so there is nothing to restore outside the reverted commits.

| Revert | Allowed when | Effect |
|---|---|---|
| WP-E | Any time | `test-all` and the integration suite go back to their literal models (the D-04 and D-06 behavior). Offline runs stop reading the config. |
| WP-D | Any time (independent) | The reviewer and reviser lose the availability check and telemetry. Telemetry lines already written stay valid. |
| WP-C | Any time, provided WP-E is reverted first or has not been applied (both edit the `test-all` table) | `specify.ps1` stops checking validator parameters and never passes `-Mode` to the validator, exactly the pre-Phase-0 workflow. The validator from WP-A still defaults to `requirements`. |
| WP-A | Only after WP-C is reverted, or together with it | Run-time safety doesn't depend on this order: with WP-C still applied, the parameter check sees that the old validator lacks `-Mode`, calls it as before, and in documentation mode prints the FR-019 warning. But WP-C's AC-011 test needs WP-A's rules and would fail. Reverting WP-A brings back D-01: documentation specs with FR `None` exit 3. |

To roll back everything, revert in the order E, D, C, A.

## Resolved Decisions

Confirmed on 2026-11-19:

| ID | Decision | Effect on this spec |
|---|---|---|
| OD-01 | Accept: reject FR or AC free text without numbered entries in documentation mode | FR-007 (Source changed from ASSUMPTION to USER), AC-008, AC-025 |
| OD-02 | Accept: move changes to the benchmark's model list to Phase 1 | Exclusions |
| OD-03 | Accept: pass `-Mode` only to validators that declare it, using `Get-Command`; keep the old invocation otherwise and warn in documentation mode | FR-008, FR-019, AC-023, AC-024; FR-009 and WP-B removed |
| OD-04 | Accept: telemetry only for generation requests actually sent | FR-011 |
| OD-05 | Accept: `None.` is ordinary text, which keeps current behavior | None-marker definition, FR-004, FR-007, AC-025 |
| OD-06 | Accept: test-all resolves the live-suite model on a best-effort basis. Offline runs never fail because of it; `-IncludeLive` runs fail without contacting Ollama. | FR-014, NFR-003, AC-028, RK-07 |

## Open Questions

None

## Assumptions

- **A-01:** `-RunnerScript`, `-ValidatorScript`, `-ReviewerScript` and `-ReviserScript` on `specify.ps1` are test seams. Revision 1 no longer depends on this assumption for validators, because FR-019 preserves validators that don't declare `-Mode` whoever uses them.
- **A-02:** Inside the child test process, a function named `Invoke-RestMethod` takes precedence over the cmdlet for scripts run with `&`. This was verified with script blocks on 2026-11-19, and is confirmed for script files in WP-D step 3a before anything depends on it. FR-018 guards 2 and 3 make a wrong assumption fail the test rather than send a real request.
- **A-03:** The configured `agentModels.spec-reviewer` (`deepseek-r1:32b`) is the model the live reviewer test is meant to exercise. This follows from defect 6 in the Phase 0 request.
- **A-04:** The previous audit recovered from the earlier session transcript is complete for Phase 0. No copy exists in the repository, in the project memory, or in the sibling backup folder `AI-Dev-Harness-backup-20261117-104625`, which was searched on 2026-11-19 and predates the audit.

## Revision History

| Revision | Date | Changes |
|---|---|---|
| Draft | 2026-11-19 | First extraction from the audit's Phase 0. |
| Revision 1 | 2026-11-19 | Applied the read-only review findings and the confirmed decisions OD-01 to OD-05. See the list below. |
| Revision 2 | 2026-11-19 | Applied the final audit findings and decision OD-06. See the list below. |

**Revision 1 changes:**

- **AC-009** now expects `Passed: 17`, `Failed: 0`, the verified baseline.
- **OD-03 redesigned:**
  - FR-008 rewritten to pass `-Mode` only to validators that declare it.
  - New FR-019 keeps the old invocation for other validators, with a documentation-mode warning and summary note.
  - FR-009 and WP-B removed; the existing validator mocks stay unchanged.
  - New AC-023 and AC-024 cover validators without `-Mode`, including both invocation points.
- **Execution order and rollback** rewritten for the new design, including the WP-C/WP-A revert order.
- **FR-018 hardened** with four guards and new AC-030: a configuration check with negative cases, a check that the fake is active, a URL allowlist, and a static check for other HTTP routes.
- **FR-014** now defines what happens when the model can't be resolved, with new one-time check AC-028. It also aligns case-insensitive matching with run-agent, with new AC-029 and the AC-014 case variant.
- **Traceability:** every `Verifies:` line now matches the table. FR-016 is added to AC-001 to AC-008, and FR-001 to AC-002.
- **New fixture:** `documentation-empty-context-spec.md`, used by AC-003. `documentation-prose-ac-spec.md` is now named explicitly.
- **New criteria:**
  - AC-025: the None-marker semantics (`none`, fenced `None`, `None.`)
  - AC-026: FR-002 output lines, plus a one-time full comparison
  - AC-027: `AI_HARNESS_RUN_ID` precedence
- **Context** gains three facts: how `-Mode` binds to validators, the verified None-marker behavior, and the Ollama state.
- **Resolved Decisions** replaces the open decisions.

**Revision 2 changes:**

- **AC-024:**
  - Every scenario now names all four injected scripts. The simple-validator case uses `recording-runner.ps1`.
  - The parse-failure case runs in both requirements and documentation mode, with a fixed expected exit code of 2.
  - The comparison with the `2e85dbe` version of `specify.ps1` is now a one-time implementation check, so no permanent test needs Git history.
- **Injected scripts:**
  - FR-017 now requires every workflow scenario to inject all four scripts, and notes the sandbox's second line of defense.
  - AC-010, AC-011 and AC-023 now name their injected scripts explicitly.
- **FR-014 rewritten for best-effort resolution (OD-06):**
  - Offline runs report a resolution failure only in the SKIPPED detail, and never fail because of it.
  - `-IncludeLive` runs fail without any request to Ollama.
  - A live table entry must have exactly one of `Model` or `ModelAgent`, and a malformed live entry is never executed.
  - NFR-003, AC-028 (now both modes, with a fake `Invoke-RestMethod` and new cases e and f), RK-07 and the Offline Verification Strategy were updated to match.
  - AC-028 now also verifies NFR-002.
- **FR-019:**
  - The warning now has two variants: "not declared", and "not confirmed" for when inspection failed.
  - The warning text no longer includes the `WARNING: ` prefix, because `Write-Warning` adds it.
  - The summary line now reads "validator called without -Mode".
  - AC-023 and AC-024 check both variants, and check that the prefix appears only once.
- **Context:** gains the verified points where inspection can fail.
- **AC-026:** the expected sequence now starts with the header line, and the separate, contradictory header assertion was removed.
- **Execution order:** AC-029 moved to step 5, after both WP-D and WP-E.
