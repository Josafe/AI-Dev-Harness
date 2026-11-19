# AI Development Harness: context for an external reviewer

**Date:** 2026-11-19. Facts were measured between 21:55 and 22:05 CET (UTC+1).
**Repository:** AI-Dev-Harness, a PowerShell 5.1 harness that runs specialized local Ollama agents under a Specification-Driven Development workflow.

You cannot see the machine or the working session, so this document is self-contained.

## Labels used

| Label | Meaning |
|---|---|
| **FACT** | Verified during this handoff. The command or file that proves it is given. |
| **DECISION** | Made by the human owner. |
| **ASSUMPTION** | Believed but not verified. |
| **UNVERIFIED** | Reported earlier, for example by the earlier audit, but not re-checked now. |

Paths are relative to the repository root unless they start with `<HOME>` (the user's home folder) or `%LOCALAPPDATA%`.

---

## 1. Repository snapshot

| Item | Value | Evidence |
|---|---|---|
| Branch | `master` | FACT: `git rev-parse --abbrev-ref HEAD` |
| HEAD | `b8cae9f` "v0.1 unstable pre phase 0" (2026-11-19 21:53:54 +0100) | FACT: `git rev-parse --short HEAD`, `git show --stat b8cae9f` |
| `git status --short` | *(empty: no modified or untracked files)* | FACT |
| Sync with remote | `master` and `origin/master` are the same commit (0 ahead, 0 behind). The remote branch `origin/claude/compassionate-shannon-7jnz4t` also points to `b8cae9f`. | FACT: `git rev-list --left-right --count origin/master...HEAD` returned `0 0` |

**Last commits.** There are only 8 commits.

```text
b8cae9f 2026-11-19 v0.1 unstable pre phase 0
2e85dbe 2026-11-18 feat: add developer agent and unified offline test runner
cff8275 2026-11-17 feat: add repository context pipeline and specification modes
83bf9ce 2026-11-09 feat(runner): add repository context injection
40c3960 2026-11-05 Tests, benchmarks, Telemetry, regression
615f1ff 2026-10-21 Canvi arg @modelArgs specify
ead508e 2026-10-16 Actualització specs, agents, config.json
4aaa602 2026-10-15 MVP AgenticEnv
```

**What `b8cae9f` contains** (FACT: `git show --stat b8cae9f`). It touches 6 files, all additions:

- `specs/harness-phase-0-defect-corrections.md`: the Phase 0 specification, Revision 2 (1,340 lines)
- `.gitignore`: one blank line added at the top
- four `specs/portfolio-lockfile-deployment-fix*.md` files, which are unrelated work (see section 10)

The commit was made outside the assistant session that wrote the Phase 0 specification. That session never staged, committed or pushed anything.

**Modified or untracked files:** none (FACT).

**Implementation work packages:** none has started. FACT: `git diff --stat 2e85dbe HEAD -- scripts tests .ai AGENTS.md README.md` is empty. No script, test, mock, fixture, agent prompt or configuration has changed since `2e85dbe`.

**Tracked backup files** (FACT: `git ls-files | grep .bak`):

- `scripts/lib/telemetry.ps1.bak`
- `scripts/run-agent.ps1.bak`
- `scripts/specify.ps1.bak`

**Local files ignored by `.gitignore`** (FACT: `git status --short --ignored`). These are not part of the repository, but they exist on the machine:

- `*.bak-mode` backups of 3 scripts and 7 mocks
- 2 timestamped `run-agent.ps1.*.bak` files
- generated specifications: `specs/smoke-*`, `specs/insufficient-*`, `specs/mode-probe-*`
- `logs/`

---

## 2. Environment

| Item | Value | Status and method |
|---|---|---|
| Windows | Windows 11 Pro, version 10.0.26200 (build 26200), 64-bit | Measured: `Get-CimInstance Win32_OperatingSystem` |
| UI culture | **es-ES** (also the culture of the `powershell.exe` 5.1 process) | Measured: `[Globalization.CultureInfo]::CurrentUICulture` |
| Windows PowerShell | 5.1.26100.9818, Desktop edition, CLR 4.0.30319.42000 | Measured: `$PSVersionTable` in `powershell.exe` |
| CPU | Intel Core Ultra 9 275HX, 24 logical processors | Measured: `Win32_Processor`, `Win32_ComputerSystem` |
| RAM | 31.5 GiB | Measured: `Win32_ComputerSystem.TotalPhysicalMemory` |
| GPU | NVIDIA GeForce RTX 5070 Ti Laptop GPU, **12,227 MiB VRAM**, driver 621.01; plus Intel integrated graphics | Measured: `nvidia-smi --query-gpu=name,memory.total,driver_version` and `Win32_VideoController` |
| Ollama version | 0.40.13 | Measured from Ollama's own `%LOCALAPPDATA%\Ollama\server.log` (`version=0.40.13`, last written 2026-11-19 15:23). The executable has no version metadata. The CLI was not run, to avoid starting anything. |
| Ollama update | `app.log` contains "update already downloaded" 4 times. The audit reported the downloaded version as 0.40.16. | Measured (the message); UNVERIFIED (the version number) |
| Ollama server | **Not running**: no `ollama*` process, and nothing listening on port 11434 | Measured: `Get-Process`, `Get-NetTCPConnection` |
| `ollama list` | **Not run**: it needs the server, and the server must not be started | — |
| Installed models | `deepseek-r1:32b`, `qwen2.5-coder:32b`, `qwen2.5-coder:7b` | Measured from the manifest files in `<HOME>\.ollama\models\manifests\registry.ollama.ai\library\` (`OLLAMA_MODELS` is not set) |
| Model sizes and quantization | unknown | — |
| How much of `deepseek-r1:32b` runs on the GPU | 27 of 65 layers on the GPU, with the rest on the CPU | UNVERIFIED: read by the audit from Ollama's log on 2026-11-19 |
| `AI_HARNESS_MODEL` | not set in this shell | Measured |

**Effective configuration** (FACT: file `.ai/config.json`, unchanged since `2e85dbe`):

| Key | Value |
|---|---|
| `ollamaUrl` | `http://localhost:11434` |
| `defaultModel` | `qwen2.5-coder:32b` |
| `agentModels.spec` | `deepseek-r1:32b` |
| `agentModels.spec-reviewer` | `deepseek-r1:32b` |
| `agentModels.spec-reviser` | `qwen2.5-coder:32b` |
| `agentModels.developer` | `qwen2.5-coder:32b` |
| `options` | `temperature 0.2`, `num_ctx 16384` (global, for every agent) |
| `timeoutSec` | `900` (one global, wall-clock limit per request; requests are not streamed) |
| `stripThinking` | `true` |

---

## 3. Roadmap and current position

**Where the roadmap comes from.** It comes from a read-only architecture audit and modernization specification produced in an earlier assistant session on 2026-11-19. **That document is not stored in the repository** (FACT: a search of the repository finds no copy). Only Phase 0 has been extracted into a specification in the repository.

| Phase | Content | Status |
|---|---|---|
| **0** | Stabilization: fix 6 verified defects. Small, offline-testable, backward-compatible. | **Specification at Revision 2, committed in `b8cae9f`. Implementation not started.** |
| 1 | Configuration v2: profiles, agents, model assignment in one registry, with v1 still accepted | Planned (audit only) |
| 2 | Shared execution engine: one library for prompts, transport and telemetry; context-window budget | Planned |
| 3 | Unified CLI, JSON run manifests, background runs (`status`/`cancel`), artifacts in `<target>/.ai-harness/` | Planned |
| 4 | Claude Code integration: `CLAUDE.md`, a project-level `/harness` skill, a read-only reviewer subagent | Planned |
| 5 | Structured developer proposals: parse the developer agent's output into `proposal.json`, then validate it | Planned |
| 6 | Controlled application: stale-file checks, backups, verification records, traceability. The harness never applies changes itself. | Planned |

**Current position.** Phase 0, between specification and implementation. No work package is in progress.

**Exact next step:**

1. **Decide V-1** (section 4): how the FR-019 warning is printed. Then make a small spec edit to FR-019, AC-023 and AC-024. This blocks only WP-C.
2. **Begin WP-A**, the validator's `-Mode` parameter, its fixtures and `scripts/test-validate-spec.ps1`. WP-A does not depend on V-1, so it can start before the decision.

---

## 4. Phase 0 specification status

**File:** `specs/harness-phase-0-defect-corrections.md`, Revision 2. It is 78,619 bytes and identical to the committed version (FACT: `git diff --quiet HEAD -- <file>`; last modified 21:39:42).

**Defects covered:**

| ID | Defect (one line) |
|---|---|
| D-01 | Documentation mode can't pass validation: the agents are told to write `None` for FR/NFR/AC, but the validator rejects that, and `specify.ps1` never passes `-Mode` to the validator. |
| D-02 | Calls to the reviewer and reviser models write no telemetry. |
| D-03 | The reviewer and reviser don't check that Ollama is reachable or that the model is installed. |
| D-04 | Test scripts contain hardcoded model names. The benchmark's model list is deferred to Phase 1. |
| D-05 | No test checks that `-Mode` reaches every stage. |
| D-06 | The live reviewer test uses `qwen2.5-coder:32b`, but the configured reviewer is `deepseek-r1:32b`. |

**Size:** 18 functional requirements (FR-001 to FR-019; FR-009 is retired), 5 non-functional requirements, and AC-001 to AC-030.

**Work packages:**

| WP | Content | Depends on | Exit check |
|---|---|---|---|
| WP-A | Validator `-Mode` and documentation-mode rules, new fixtures, `test-validate-spec.ps1` | baseline | AC-001 to AC-008, AC-025, AC-026 |
| WP-C | `specify.ps1` checks whether the validator declares `-Mode` and passes it only then; older validators keep their current invocation; recording mocks; `test-mode-propagation.ps1` | WP-A (only because AC-011 needs WP-A's rules) | AC-009 to AC-011, AC-023, AC-024 |
| WP-D | Reviewer and reviser: availability check and telemetry; `test-agent-telemetry.ps1` with four guards against real network calls | none (can run in parallel) | AC-012 to AC-017, AC-027, AC-030 |
| WP-E | Test model names come from the configuration; `test-all.ps1` resolves the live-suite model on a best-effort basis | WP-C (both edit the `test-all` table) | AC-018 to AC-020, AC-028 |
| Final | Full regression run, file-change check, case-insensitive matching inspection | all | AC-021, AC-022, AC-029 |

WP-B was removed in Revision 1.

**Allowed rollbacks.** Reverts can only happen in this order: E before C, and C before or together with A. The resulting allowed sets of reverted packages are:

```text
{}, {E}, {D}, {E,D}, {E,C}, {E,D,C}, {E,C,A}, {E,D,C,A}
```

- A full rollback goes E, D, C, A.
- In every allowed set the workflow still runs. `specify.ps1` works with both the old and the new validator, the reviewer and reviser are independent, and `test-all` does not depend on WP-D.
- The ordering rules exist only to keep the test suites consistent and to avoid Git conflicts.
- This was verified by reasoning over the spec, not by executing reverts.

**Open findings from the latest verification:**

| ID | Severity | Finding | In the spec? |
|---|---|---|---|
| **V-1** | **Blocks WP-C** | FR-019 requires the warning to be printed with `Write-Warning`, and AC-023 and AC-024 expect exactly one console line starting with `WARNING: `. On this machine (es-ES), a 359-character `Write-Warning` captured from a child `powershell.exe` printed the **localized prefix `ADVERTENCIA:`** and was **wrapped over 4 lines** (about 120 characters each). FACT: measured with an in-memory `powershell.exe -Command "Write-Warning …"`. The same text printed with `Write-Host "WARNING: …"` stayed on **one line** (368 characters) with the literal prefix (FACT, same method). **Recommendation:** use `Write-Host` with a literal, non-localized `WARNING: ` prefix, on one line, and use the exception's **type name** (for example `ParseException`) as `<reason>`, because exception messages are localized and can span several lines. | **Not yet applied.** The spec still requires `Write-Warning` (lines 466–467, 865, 868, 909, 1335). The change needs a human decision, because it reverses an explicit Revision 2 instruction. |
| V-2 | Low | AC-028 checks "the reason" for a resolution failure. That reason can contain localized .NET text, so the check should match the harness's own wording instead. | Not applied |
| V-3 | Low | FR-017 (line 405) says "The only exception is the real `validate-spec.ps1`", which reads as if AC-011 doesn't supply that script. It does: AC-011 passes it explicitly. | Not applied |
| V-4 | Low | `Get-Command -Name` treats `[` and `]` as wildcards. A validator path containing them falls into the safe "could not confirm" fallback, with a misleading warning. | Not applied |
| V-5 | To confirm during implementation | Replacing `Invoke-RestMethod` with a function works with script blocks (FACT). It has not yet been confirmed for script files run with `&`; that is step 3a of WP-D. | Already noted in the spec (A-02) |
| V-6 | To confirm during implementation | A validator that fails to parse should make `specify.ps1` exit 2. This is inferred from the `trap` in `specify.ps1:21-26`, but has not been run. | Covered by AC-024 |

**Specification validator.**

- The last run (`scripts/validate-spec.ps1 -SpecFile <spec>`) gave `STATUS: PASS`, exit 0. It ran earlier on 2026-11-19, after the last edit at 21:39:42.
- **It was not re-run for this handoff**, but the file is byte-identical to that run (same modification time, identical to `HEAD`).

**Traceability** (FACT: re-checked now with a read-only Python script):

- 53 IDs, all unique (18 FR, 5 NFR, 30 AC).
- Every FR and NFR maps to at least one AC.
- Every AC has a `Verifies:` line, and the traceability matrix matches those lines exactly.
- FR-009 appears only in the retirement and history notes.

---

## 5. Test status

**Latest offline run:** `scripts/test-all.ps1 -ShowOutput`, without `-IncludeLive`, from 2026-11-19 21:59:06 to 21:59:15 CET. **FACT: it was run for this handoff.**

- Result: exit 0, `STATUS: PASS WITH SKIPS`.
- The repository was unchanged by the run: `git status --short --ignored` had the same hash before and after, and no file was newer than a marker created just before the run.

| Suite | Result | Counts | Tripwire |
|---|---|---|---|
| `test-syntax.ps1` | PASS (0.3 s) | 30 files checked, 0 syntax errors | clean (164 entries) |
| `test-build-context.ps1` | PASS (0.5 s) | 15 passed, 0 failed | clean |
| `test-run-agent.ps1` | PASS (1.5 s) | 5 passed, 0 failed | clean |
| `test-scan-repository.ps1` | PASS (1.8 s) | 26 passed, 0 failed, 0 skipped | clean |
| `test-spec.ps1` | PASS (3.9 s, sandboxed) | 17 passed, 0 failed | clean |
| `test-spec-integration.ps1` | **SKIPPED** (NOT VERIFIED) | — | — |

The integration suite was skipped because it needs Ollama and is only run with `-IncludeLive`.

**Never verified live:**

- **`test-spec-integration.ps1`.** UNVERIFIED whether it has ever been run live. Reviewer calls write no telemetry, so there is no record either way.
- **Reviewer and reviser telemetry.** It does not exist yet (D-02).
- **Documentation mode with a real model.** The `mode-probe-*` artifacts contain placeholder FR/AC entries, so they never reached the `None` path (FACT).
- **Every Phase 0 behavior.** Nothing is implemented yet.

**Has run live** (FACT, from the telemetry in section 6): the `spec` and `developer` agents through `run-agent.ps1`, and the benchmark between 2026-11-02 and 2026-11-05. A full `specify.ps1` workflow also ran once for an unrelated project on 2026-11-19 (see section 10).

---

## 6. Telemetry and benchmarks

**Data files.** Raw contents are not included here; ask for them by name.

| File | Size (bytes) | Last modified |
|---|---|---|
| `logs/model-calls.csv` | 17,969 | 2026-11-19 |
| `logs/model-calls.jsonl` | 34,120 | 2026-11-19 |
| `logs/benchmarks/benchmark-runs-20261102-194541.csv` | 583 | 2026-11-02 |
| `logs/benchmarks/benchmark-runs-20261102-195238.csv` | 569 | 2026-11-02 |
| `logs/benchmarks/benchmark-runs-20261102-195635.csv` | 2,768 | 2026-11-02 |
| `logs/benchmarks/benchmark-runs-20261102-202008.csv` | 571 | 2026-11-02 |
| `logs/benchmarks/benchmark-runs-20261102-202505.csv` | 853 | 2026-11-02 |
| `logs/benchmarks/benchmark-runs-20261102-204713.csv` | 3,178 | 2026-11-02 |
| `logs/benchmarks/benchmark-runs-20261103-170551.csv` | 3,074 | 2026-11-03 |
| `logs/benchmarks/benchmark-runs-20261104-152854.csv` | 1,299 | 2026-11-04 |
| `logs/benchmarks/benchmark-runs-20261105-124305.csv` | 1,308 | 2026-11-05 |
| `logs/benchmarks/benchmark-summary-*.csv` (9 files, same timestamps) | 241 to 1,010 each | 2026-11-02 to 2026-11-05 |
| `logs/benchmarks/responses/*.txt` | 37 files, 32,954 total | — |

`logs/` is git-ignored, so these files exist only on this machine.

**Model-call telemetry** (FACT: computed from `logs/model-calls.csv`). 83 records from 2026-10-29 to 2026-11-19. The medians cover successful calls only. Tokens per second is `eval_count / eval_duration`.

| Agent | Model | Calls | OK | Errors | Median duration | Median output tokens/s | Median `prompt_eval_count` | Median `eval_count` |
|---|---|---|---|---|---|---|---|---|
| developer | qwen2.5-coder:32b | 5 | 5 | 0 | 328.7 s | 2.6 | 4,088 | 734 |
| developer | qwen2.5-coder:7b | 16 | 16 | 0 | 11.3 s | 83.8 | 3,945 | 802 |
| spec | deepseek-r1:32b | 26 | 21 | 5 | 321.5 s | 2.4 | 3,797 | 692 |
| spec | qwen2.5-coder:32b | 15 | 14 | 1 | 82.1 s | 2.6 | 3,843 | 182.5 |
| spec | qwen2.5-coder:7b | 20 | 20 | 0 | 5.4 s | 84.9 | 3,843 | 172 |
| telemetry-test | synthetic-test | 1 | 0 | 1 | — | — | — | — |

**How the errors break down.** They are grouped by duration only; the messages are not reproduced.

- `spec`/`deepseek-r1:32b`: 1 hit the 900 s timeout (900,030 ms, the most recent record, 2026-11-19 14:23 UTC), and 4 failed in under 60 s.
- `spec`/`qwen2.5-coder:32b`: 1 failed in under 60 s.
- 1 synthetic test record.

The audit attributed two of the fast failures to a CUDA initialization crash inside Ollama (UNVERIFIED now).

**Records that don't exist.** There are no records for `spec-reviewer` or `spec-reviser` (FACT; this is defect D-02).

**Benchmarks** (FACT: computed from the 9 `benchmark-runs-*.csv` files). There are 38 runs, all with agent `spec`.

| Model | Runs | OK | Failed | Median model duration | Median output tokens/s | Median prompt tokens/s | Median `prompt_eval_count` | Median `eval_count` |
|---|---|---|---|---|---|---|---|---|
| deepseek-r1:32b | 13 | 12 | 1 | 293.2 s | 2.4 | 5,135 | 3,797 | 664.5 |
| qwen2.5-coder:32b | 13 | 12 | 1 | 78.1 s | 2.6 | 5,523 | 3,843 | 186.5 |
| qwen2.5-coder:7b | 12 | 11 | 1 | 2.5 s | 85.8 | 23,117 | 3,843 | 184 |

**Interpretation:**

- The 32b models generate about 30 times more slowly than the 7b model. This is consistent with the 32b models running only partly on the GPU, given 12 GiB of VRAM. That cause is an ASSUMPTION.
- **Data-quality issue (FACT):** the benchmark CSV columns `generation_tokens_second` and `prompt_tokens_per_second` were written with the es-ES decimal comma (for example `82,14`). The rates above were therefore recomputed from the raw token counts and nanosecond durations.

---

## 7. Prompt inventory

**Method:**

- Lines and characters are counted from each file (FACT).
- Tokens are **estimated as characters ÷ 4**.
- Calibration: for the `spec` agent with `deepseek-r1:32b` since its prompts last changed on 2026-11-17, Ollama measured `prompt_eval_count` = 5,287 to 5,362 (n = 2, from telemetry). The characters ÷ 4 estimate for the same prompt is about 7,000 tokens. **So characters ÷ 4 overestimates by roughly 30%.** These prompts work out to about 5.3 characters per token.

| File | Lines | Characters | Estimated tokens (÷ 4) | Model (`.ai/config.json`) | Last changed |
|---|---|---|---|---|---|
| `.ai/agents/spec.md` | 412 | 20,620 | ~5,155 | deepseek-r1:32b | `cff8275` |
| `.ai/agents/spec-reviewer.md` | 401 | 16,581 | ~4,145 | deepseek-r1:32b | `cff8275` |
| `.ai/agents/spec-reviser.md` | 431 | 13,369 | ~3,342 | qwen2.5-coder:32b | `cff8275` |
| `.ai/agents/developer.md` | 131 | 5,788 | ~1,447 | qwen2.5-coder:32b | `2e85dbe` |
| `.ai/rules/agent-contract.md` (shared) | 162 | 3,274 | ~818 | added to every agent's prompt | — |
| `AGENTS.md` (shared) | 184 | 4,264 | ~1,066 | added to every agent's prompt | — |

Every call's system prompt is built from `AGENTS.md`, the contract and the agent file. This is FACT, at [run-agent.ps1:125-143](../../scripts/run-agent.ps1#L125-L143), [review-spec.ps1:70-108](../../scripts/review-spec.ps1#L70-L108) and [revise-spec.ps1:64-144](../../scripts/revise-spec.ps1#L64-L144). The reviewer and reviser then add the task and the spec, and the reviser also adds the review. With `num_ctx` = 16,384, the reviewer's fixed part alone is roughly 6,000 tokens by the ÷ 4 estimate.

**Rules duplicated across agents** (FACT: heading and line search):

- **Specification modes.** The sections "Specification Modes", "Requirements Mode", "Baseline Mode", "Documentation Mode" and "Mixed Requests" appear in `spec.md`, `spec-reviewer.md` and `spec-reviser.md` (6 mode headings in `spec-reviser.md`). The acceptance-criteria rules per mode appear a fourth time, inline in [revise-spec.ps1:104-115](../../scripts/revise-spec.ps1#L104-L115).
- **Source labels.** The definitions of `USER` / `PROJECT` / `FACT` / `ASSUMPTION` appear in both `spec.md` and `spec-reviewer.md` (8 definition lines each).
- **Spec structure.** The 10 required headings and the "write `None`" rule appear in `spec.md`, `spec-reviser.md` and again inline in [revise-spec.ps1:118-141](../../scripts/revise-spec.ps1#L118-L141).
- **Shared section names.** "Output Format" appears in all four agent files, and "Role" in three.

**Text tied to one example** (FACT: search for registration, email, password):

- **`spec.md`:** lines 91–94 (rules naming email validation, password complexity and email case-sensitivity), and lines 231–235 and 294–308 (the "simple user registration with email and password" example).
- **`spec-reviewer.md`:** lines 74–81, 114–120, 232–241 and 263–264.
- **`spec-reviser.md`:** lines 267–296, 337–338 and 400–418.
- **The same example in the tests:** `tests/fixtures/minimal-valid-spec.md`, `tests/fixtures/semantic-invalid-spec.md` and `scripts/test-spec-integration.ps1`.
- **SUSPECTED risk:** the prompts are tuned to the scenario the live test checks, so passing that test may say little about other tasks.

---

## 8. Known issues not yet fixed

Phase 0 is meant to fix D-01 to D-06. Everything else here is outside Phase 0 unless noted.

| # | Issue | Label | Location |
|---|---|---|---|
| 1 | Three backup files are tracked in Git | FACT | `scripts/lib/telemetry.ps1.bak`, `scripts/run-agent.ps1.bak`, `scripts/specify.ps1.bak` |
| 2 | The Ollama call logic exists twice: request building, the call and stripping `<think>` text | FACT | [run-agent.ps1:145-216](../../scripts/run-agent.ps1#L145-L216) and [lib/config.ps1:54-90](../../scripts/lib/config.ps1#L54-L90) |
| 3 | Reviewer and reviser calls write no telemetry (D-02) | FACT | [review-spec.ps1:114-118](../../scripts/review-spec.ps1#L114-L118), [revise-spec.ps1:149-153](../../scripts/revise-spec.ps1#L149-L153) |
| 4 | Reviewer and reviser don't check model availability (D-03) | FACT | the same scripts; compare [run-agent.ps1:83-97](../../scripts/run-agent.ps1#L83-L97) |
| 5 | Telemetry gaps: no workflow, stage, task hash or prompt size; failures before the request (unreachable server, missing model) are not logged | FACT | [lib/telemetry.ps1:31-46](../../scripts/lib/telemetry.ps1#L31-L46), [run-agent.ps1:83-97](../../scripts/run-agent.ps1#L83-L97) |
| 6 | Error messages are stored in localized text. The last record's error is Spanish .NET text, so errors can't be classified by their message. | FACT | `logs/model-calls.jsonl`, last record |
| 7 | One global timeout of 900 s on a non-streamed request: a slow model looks the same as a hung server. The last `spec` run timed out while still generating. | FACT (config); UNVERIFIED (the "still generating" part, from the audit's reading of the Ollama log) | `.ai/config.json:14`, [run-agent.ps1:149](../../scripts/run-agent.ps1#L149), [run-agent.ps1:169](../../scripts/run-agent.ps1#L169) |
| 8 | One global `num_ctx` of 16,384, and no budget check on prompt size | FACT | `.ai/config.json:12` |
| 9 | The validator has no `-Mode` parameter and rejects documentation-mode `None` (D-01) | FACT | [validate-spec.ps1:1-4](../../scripts/validate-spec.ps1#L1-L4), [:61-65](../../scripts/validate-spec.ps1#L61-L65), [:70-75](../../scripts/validate-spec.ps1#L70-L75) |
| 10 | The validator reads the spec without `-Encoding UTF8` | FACT. Its impact is SUSPECTED to be low, because the current checks only use ASCII. | [validate-spec.ps1:12](../../scripts/validate-spec.ps1#L12) |
| 11 | Validator weaknesses: the Source check needs only one `**Source:**` line in the whole file, not one per entry; the NFR section is never checked; extra sections are accepted, although `spec.md` forbids them | FACT | [validate-spec.ps1:76-92](../../scripts/validate-spec.ps1#L76-L92) |
| 12 | `specify.ps1` never passes `-ContextFile`, so the workflow never uses repository context | FACT (`grep -c ContextFile scripts/specify.ps1` returns 0) | `scripts/specify.ps1` |
| 13 | During revision validation, exit 3 (insufficient input) becomes exit 2 | FACT | [specify.ps1:330-339](../../scripts/specify.ps1#L330-L339) |
| 14 | Hardcoded model names (D-04) | FACT | [test-spec.ps1:3](../../scripts/test-spec.ps1#L3) (the parameter is unused), [test-spec-integration.ps1:2](../../scripts/test-spec-integration.ps1#L2), [test-all.ps1:111](../../scripts/test-all.ps1#L111), [benchmark-models.ps1:8-12](../../scripts/benchmark-models.ps1#L8-L12) |
| 15 | The live reviewer test model differs from the configured reviewer (D-06) | FACT | [test-spec-integration.ps1:2](../../scripts/test-spec-integration.ps1#L2) vs `.ai/config.json:6` |
| 16 | The `test-all` live precondition matches model names case-sensitively, unlike `run-agent.ps1` | FACT | [test-all.ps1:602](../../scripts/test-all.ps1#L602) vs [run-agent.ps1:92](../../scripts/run-agent.ps1#L92) |
| 17 | Benchmark CSVs use the decimal separator of the current culture (`82,14`) | FACT (data). Where in `benchmark-models.ps1` it comes from is SUSPECTED, not traced. | `logs/benchmarks/*.csv` |
| 18 | `Write-Warning` output is localized and wraps (V-1, which affects the Phase 0 spec) | FACT | section 4 |
| 19 | If the config file is missing, `Get-HarnessConfig` silently returns an empty object and every default applies | FACT | [lib/config.ps1:4-6](../../scripts/lib/config.ps1#L4-L6) |
| 20 | `AGENTS.md`, which holds the harness's own development rules, goes into every agent's prompt, including prompts for tasks on other projects | FACT (code). Whether this is desirable is an open question. | see section 7 |
| 21 | Ollama/GPU instability: `CUDA error: shared object initialization failed` at two times on 2026-11-19 | UNVERIFIED (audit, from Ollama's logs) | `%LOCALAPPDATA%\Ollama\server-1.log` |
| 22 | The modernization specification and audit (the roadmap for Phases 1–6) exist only in a local session transcript, not in the repository | FACT | — |
| 23 | Project-specific artifacts from another project are now committed in the harness repository, which contradicts the `AGENTS.md` principle that the harness stays project-agnostic | FACT | `b8cae9f`, see section 10 |

---

## 9. Decisions and open questions

**Decisions already taken (DECISION):**

*Architecture* (from the modernization request):

- Claude Code is the main orchestrator.
- Ollama agents stay local and specialized, with no permission to write files or run commands.
- Claude selects the project context and delegates tasks.
- Output from local models is an untrusted draft, never proof of verification.
- Claude reviews and applies changes through its permission-controlled editing.
- Artifacts for a target project go in `<target>/.ai-harness/`. Temporary execution data and logs stay in the harness repository.
- Planned components: a configuration registry v2 that still accepts v1; a shared execution library; a unified PowerShell CLI with JSON manifests; Claude Code integration through `CLAUDE.md`, a `/harness` skill and a read-only reviewer subagent.
- No MCP server at first.
- The skill becomes user-level only after it has been validated at project level.
- Documentation mode supports FR/AC = `None` without weakening validation of functional specs.
- Preserve existing functionality, and avoid unnecessary dependencies.

*Phase 0 constraints:*

- Do not fix the local model timeout yet.
- No registry or profiles in Phase 0.
- Move test-model centralization that needs the registry to Phase 1.
- Keep Phase 0 small, independently testable and backward-compatible.
- In documentation mode, a spec may pass without FR/NFR/AC when there is enough context. If FR entries are present, at least one AC is required. Purely descriptive documentation needs no functional AC.

*Phase 0 resolved decisions:*

| ID | Decision |
|---|---|
| OD-01 | In documentation mode, reject free text without numbered entries in the FR or AC section. |
| OD-02 | Move the benchmark's default model list to Phase 1. |
| OD-03 | Pass `-Mode` only to validators that declare it (checked with `Get-Command`); older validators keep their current invocation, with a warning in documentation mode. |
| OD-04 | Telemetry only for generation requests that are actually sent. |
| OD-05 | `None.` is ordinary text, not the `None` marker (this keeps current behavior). |
| OD-06 | `test-all` resolves the live-suite model on a best-effort basis: an offline run never fails because of it; with `-IncludeLive`, the live suite fails without contacting Ollama. |

- The existing validator mocks stay unchanged.
- One-time comparisons against `2e85dbe` are implementation checks, not permanent tests.

**Open questions that need a human decision:**

- **V-1 (blocks WP-C):** should the FR-019 warning be printed with `Write-Host` and a literal `WARNING: ` prefix, using the exception's type name as `<reason>`? This is the recommendation. The alternative is to keep `Write-Warning` and make AC-023 and AC-024 independent of language and wrapping.
- **V-2 to V-4:** small spec wording fixes (section 4).
- **Timeout and model mapping** (audit O-01): raise `timeoutSec` for reasoning models, or map `spec` to a faster model. This is deferred until local Ollama runs resume.
- **Store the roadmap in the repository?** The modernization specification and audit (item 22) currently exist only in a session transcript.
- **What to do with the committed `specs/portfolio-*` files and the `.gitignore` blank line** (audit O-08; section 10).
- **Tracked `.bak` files** (audit O-15): remove them in a separate cleanup commit?
- **Purpose of the remote branch** `origin/claude/compassionate-shannon-7jnz4t`, which currently equals `master`.
- **Open audit questions for later phases:**
  - O-06: should `<target>/.ai-harness/` be committed?
  - O-07: should `-TargetPath` be mandatory?
  - O-10: should streaming transport be required or optional?
  - O-12: should full prompts be saved in run folders?
  - O-14: should telemetry store only a hash of the task?
  - O-16: how many tokens to reserve for output per profile?
  - O-17: criteria for making the skill user-level.
  - O-18: CLI exit code 4.
  - Q-04: may specs contain extra sections?
  - Q-06: should `AGENTS.md` be added to prompts for target-project tasks?

---

## 10. Out of scope and unrelated work

- **`specs/portfolio-lockfile-deployment-fix.md`** and its three companion files (`.review.md`, `.revised-v1.md`, `.revised-v1.review.md`):
  - They are output of the harness's specification workflow for a **separate, unrelated project** (named "Portfolio").
  - They were written 2026-11-19, 12:42–13:03 (FACT: file timestamps). That is before the Phase 0 audit session, which started later that afternoon (the session's start time, about 16:51, is not a repository fact).
  - They were committed in `b8cae9f`.
  - **They are unrelated to Phase 0** and are not harness code.
  - Their contents are deliberately not described here.
- **The blank line at the top of `.gitignore`:**
  - It was added at 09:18:31 on 2026-11-19, before Phase 0 work. Who added it cannot be determined from the available evidence.
  - It was committed in `b8cae9f`.
  - **It is unrelated to Phase 0** and has no functional effect.
- **Other local projects** on the machine (for example "SME-Management-Pilot" and "Portfolio") are unrelated to this harness and to this review.
