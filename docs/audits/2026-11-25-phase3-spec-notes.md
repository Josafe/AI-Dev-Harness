# Phase 3 specification: notes

**Branch:** `docs/phase3-spec`, from `master` at `8c26f72` (tag `phase2-done` is an ancestor). Deliverable: `specs/harness-phase-3-unified-cli.md` (revision 1, draft). Only documents were added; no script, test, config or other spec was changed. Nothing was pushed. Written unattended: no decision was waited for, so every choice beyond the roadmap is an Open Question with a recommendation.

**Checks run:** `scripts\validate-spec.ps1` on the spec: STATUS PASS. A separate script (kept in `%TEMP%`, not committed) confirmed: 20 requirements (15 FR, 5 NFR), 27 ACs, every FR and NFR has at least one AC, every AC has exactly one `Verifies:` line and one `Source:` line, every requirement has one `Source:` line, and the traceability matrix equals the inverse of the `Verifies:` lines. No code was run, so nothing here is verification of behavior.

**Size:** 53 KB, above the 45 KB target. The roadmap scope list (items 1 to 11) plus 27 testable criteria did not fit. If the owner wants it smaller, the cheapest cuts are, in order: FR-312 and AC-318 (resume, about 2 KB), the `config` and `doctor` detail of FR-309 and AC-314 (about 1.5 KB), and the prose of FR-313 (about 1 KB).

## 1. Assumptions made

| ID | Assumption | Where |
|---|---|---|
| N-1 | The stage scripts keep running with `&` in the CLI's own process (as `specify.ps1` does), so no child process, job or runspace is added. | FR-301 |
| N-2 | Telemetry already carries what the manifest needs (`call_id`, `attempts`, `warnings`, `profile`, `model`, `model_source`, `error_category`, `http_status`, `duration_ms`, `context_window`, `est_prompt_tokens`), so the manifest is filled by reading telemetry lines by `run_id` (setting `AI_HARNESS_RUN_ID` for the stages), with no change to the three scripts or the engine. The cost: a stage that wrote no record has no call id. | FR-307 |
| N-3 | A failed availability check or budget stop also writes one record (Phase 2 FR-216), so failures before the call are correlated the same way. | FR-307 |
| N-4 | Reviewer and reviser prompt builders can take an optional context part without changing the no-context bytes, because the part is added only when a context string is given. | FR-313 |
| N-5 | `Get-Process` gives the start time of a same-user process with a resolution finer than the 2 s tolerance. | FR-309 |
| N-6 | A `Global\` mutex can be created by an ordinary user; if not, `Local\` applies. Not tested here. | FR-311 |
| N-7 | The 8 AC-216 wrapper cases are the ones at `test-engine-callsites.ps1` lines 1192 to 1276 (counted in the repository); the 7 other AC-216 cases are for the reviewer and reviser parameters and stay. | FR-314 |

## 2. Deviations from the roadmap text, with reasons

| Roadmap | This spec | Reason |
|---|---|---|
| XR-06: `-Background`, `cancel`, `concurrent_run_detected`, `console.log` | No `-Background`, no `cancel`, no `console.log`. `status` derives `abandoned`; `-Resume` added; `concurrent_run_detected` kept as a warning. | The owner's task and the roadmap's own updated O-11 recommendation: rely on Claude Code's background execution. A killed foreground run leaves a checkpointed manifest, which is all `status` and `-Resume` need. |
| XR-06: `status` marks an abandoned run | `status` and `list` only derive it; nothing rewrites the manifest. | `status` must stay a read-only command so Phase 4 can allow it without prompts. Cost: a stale manifest says `running` forever. |
| XR-07: `prompts/`, `outputs/*.raw.md`, `inputs/context-files.json`, `proposal/`, `backup/` | Only `manifest.json`, `inputs/task.md`, `inputs/scan.json`, `inputs/context.txt`. | Saving prompts and raw output needs a capture hook in the scripts or the engine; `context-files.json` duplicates `context.files[]`. `proposal/` and `backup/` belong to Phases 5 and 6. |
| XR-05: new telemetry columns (`workflow_id`, `workflow`, `stage`, `attempt`, `task_sha256`, `output_path`, `target_root`) | None added. The manifest joins to telemetry by `run_id` and `call_id`. | A new CSV header would again split the CSV file (XR-05's own rule) and change the engine. Phase 2 OQ-205 left the choice to Phase 3. |
| XR-08 example: `budget.reservedOutputTokens`, `resolution` taken from the registry | `reservedOutputTokens` dropped; `resolution` read from the telemetry record. | Avoids a second resolution in the CLI that could differ from what the script resolved. |
| XR-08: one `attempt` | `attempt` (position in the review loop) and `engineAttempts` (HTTP attempts from telemetry). | Final QA section 10 asked that a retried run can be told apart. |
| XR-10 category list | Same names, plus `artifact_in_use` and `stage_failed`; `unsupported_command` not added; `cancelled` and `abandoned` reserved. | Needed by the artifact lock and by a stage that exits non-zero without a record. Names are mapped from the engine's finer ones by the table in Phase 2 FR-211 (OQ-212). |
| XR-10: exit 1 for "validation failed" | CLI: 1. Legacy `specify.ps1`: 2, as today. | XR-01 forbids changing legacy codes; the table in XR-10 is for the CLI. Both come from one workflow result (FR-303). |
| XR-10: exit 4 "unsupported stage or command" | Unknown command is exit 2 `invalid_arguments`. | O-18 speaks of unsupported stages only; a typo is an argument error. |
| FR-301: `develop` is a Phase 3 command | `develop` exits 4 as unsupported until Phase 5. | Phase 5 FR-503 defines it with `proposal.json`; shipping a half version in Phase 3 would be a second design. |
| FR-304 / XR-03: context budgets from `C - R - S - fixed size` | Not built; the engine's own check applies to the prompt with context. | The reviewer's fixed text already exceeds the available tokens under the shipped configuration (Phase 2 Context), so a derived budget would be zero or negative; the ratio needs WP-2E. |
| XR-04: one shared sensitive-pattern policy | Not built; `.ai-harness/` exclusion and per-file SHA-256 are built. | No Phase 3 criterion needs the merge, and it changes two scripts. |
| FR-302: `-Include` for review and revise | `-Include` only builds a context for `specify`, `scan` and `context`; `review` and `revise` take `-Revision` and fixed names. | Keeps the output paths fixed inside `.ai-harness/specs/` with no free path parameter. |
| FR-307 (roadmap): `runs/` pruning | Not built (`[O]`). | Roadmap marks it optional. |
| Phase 3 FR-306: last line `MANIFEST:` | Kept, plus a first line `RUN_ID:`. | A caller running in the background can learn the id (and so the manifest path) before the end. |

## 3. Decisions that need the owner

All are OQ-301 to OQ-313 in the spec, each with a recommendation. The ones that change scope or cost most:

1. **OQ-302 (O-11).** No built-in `-Background` and `cancel`; rely on Claude Code's background execution. If the owner wants a detached mode anyway, add a package after WP-3F (it needs `-RunId`, a second process and `cancel` with the pid and start-time check; the manifest already has the fields).
2. **OQ-303.** Keep or cut `-Resume` (WP-3H). It is last and independent.
3. **OQ-304.** No telemetry columns. If the owner wants `workflow_id` and `stage` in the CSV, the engine, the writer and the CSV rule change, and AC-310 and NFR-304 change with them.
4. **OQ-306.** `develop` unsupported in Phase 3.
5. **OQ-307.** The legacy `specify.ps1` writes no manifest. Reversing it makes every suite that runs it create `runs/` under its root.
6. **OQ-311.** `artifact_in_use` hard stop for the same target and name; a shared Ollama URL only warns. The alternative (queue on one GPU) is `[O]` in the roadmap.
7. **OQ-312, OQ-313.** The derived context budget and the shared sensitive-pattern policy wait for WP-2E and for a later refactor.
8. **Size.** Accept 53 KB, or name a cut (see above).

## 4. What could not be verified

- No Ollama and no network were used; nothing in the spec was run. All claims about current behavior come from reading the repository at `8c26f72`: `specify.ps1` (382 lines), the three agent scripts, `lib/agent-exec.ps1`, `lib/telemetry.ps1`, the roadmap, the Phase 1 and 2 specs and the Phase 2 final QA.
- That `Write-HarnessModelTelemetry` writes exactly one record per script call in every path (the spec relies on the Phase 2 statement of FR-216; the reviewer's validation-failure path and the run-agent argument-error paths were not traced one by one). AC-310 and AC-321 test it, so a wrong reading fails there.
- That `Test-OllamaModel` can be called with no `-TelemetryRoot` (the signature shows it optional; not run).
- The 8 wrapper cases: counted by `Test-Case "AC-216` lines, 15 in total, of which the 8 listed in N-7 name the wrappers (read, not run). The exact number to delete must be rechecked in WP-3B.
- The Phase 2 spec's FR-211 mapping text was read from line 206 of the spec (a line inside or after FR-211); its exact position was not checked beyond the grep.
- How `test-all.ps1` sandboxing treats the new suites (new suites that write `runs/` and `.ai-harness/` under a temporary harness root probably need no entry, but this is not checked; "only if needed" in the spec).
- `File.Replace` over a file that a reader has open, `Global\` mutex creation, and `Process.StartTime` reads on this machine: all need a test in WP-3A and WP-3C; none was tried.
- Whether `junction` creation works without elevation on the owner's machine (AC-320 reports that case as skipped when it cannot be made).

## 5. Self-review of the spec

- **Ambiguity.** The stage and category tables are closed lists; the exit-code mapping per scenario is a literal list (AC-303, AC-311). Left deliberately open and flagged: how a stage hook is passed (a script block with only its parameters), and the exact JSON key names of `status -Json` (they are the ones listed in FR-309; no golden key set is frozen yet, which Phase 4 may want).
- **Circular expected values.** AC-303 was first written to compare `specify.ps1` with the CLI, which both call the new workflow, so it would have passed for any behavior; it now compares both with call records frozen from the unmodified `specify.ps1` at `phase2-done`. AC-302 uses a parameter list frozen at `phase2-done`. AC-307 and AC-319 take hashes from `Get-FileHash`. AC-310 and AC-314 use literal tables. AC-319's check of the reviewer and reviser context part uses `New-RunAgentPrompt` as reference (existing, goldened code); it is a consistency check, not an independent oracle for the wording, which is intentional (the wording must equal run-agent's).
- **Localized text (Phase 0 NFR-006).** Assertions name only exit codes, manifest values and harness tokens (`invalid_arguments:`, `RUN_ID:`, `MANIFEST:`, category names). `error.message` may carry the telemetry `error` column (Ollama's JSON error string, or an exception type name), and no AC asserts it.
- **Untestable criteria.** AC-317's sensitivity proof (the stress loses records without the lock) is a work package report item, not an automated test, because it needs a source edit; the stress itself is automated. AC-323's comparison against `git show` is likewise a report item next to the frozen case list.
- **Size.** 53 KB against a target of about 45 KB.
