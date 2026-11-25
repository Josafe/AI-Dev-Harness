# Phase 3 specification: independent adversarial review

**Reviewed:** `specs/harness-phase-3-unified-cli.md` (revision 1) and `docs/audits/2026-11-25-phase3-spec-notes.md`, at `f5d33b9`. "spec:N" is a line of the specification.
**Branch:** `docs/phase3-spec-review`, from `docs/phase3-spec`. Only this file was added. The reviewer did not write the spec. Nothing was pushed.
**Host:** Windows PowerShell 5.1.26100.9818, culture es-ES, not elevated. No Ollama, no network. Experiments ran in `%TEMP%\p3rev*` with time limits and are not committed.

## 1. Verdict

**APPROVE WITH CHANGES. Not ready to implement as written.** 8 blockers, 16 important, 8 nits.

The direction is right: one CLI over the existing scripts, manifests, no job daemon, no new telemetry columns, legacy scripts kept. The traceability is formally clean. The problems are that several criteria cannot be met as written, two mechanisms break each other (telemetry correlation and the telemetry lock), the stage contract does not match the real scripts, and resume can report a review verdict for a different specification. Every blocker can be fixed in text. Nobody needs to redesign the phase, but it is too large for the 8 packages it lists (section 9).

## 2. MUST changes before implementation

| ID | Fixes | Where | Proposed replacement text |
|---|---|---|---|
| M-1 | B-1 | FR-311(c), FR-307 (spec:104, 130) | FR-311(c): "...takes a named mutex around its file section **and** appends each file through one `FileStream` (`Append`, `Write`, `FileShare.ReadWrite`) with a bounded retry on `IOException` (until `-LockWaitMs` is spent), instead of `Add-Content`." FR-307: "The CLI reads the appended bytes with `FileShare.ReadWrite`, while holding the telemetry mutex, retries an `IOException`, and drops a leading BOM before parsing." New AC-317 case: "two writers that each read the JSONL after every write, plus a third process reading in a loop, lose no record." |
| M-2 | B-2 | FR-303 (spec:58), FR-308 | Add: "A stage is called as a statement of the workflow. Its success-stream output passes through unchanged to the caller. The workflow result is therefore returned through a `-Result` hashtable parameter, not the pipeline. `$global:LASTEXITCODE` is set to `$null` before each stage. A stage that **throws** is a failed stage: the workflow catches it, calls `stage_end` with exit code null, and, for the legacy front end, rethrows so that the `trap` of `specify.ps1` prints and exits 2 as today. `scan-repository.ps1` and `build-context.ps1` never call `exit`: success is 'returned without throwing and the output file exists'." Add to AC-311 and AC-321: a real `revise-spec.ps1` 500 (it throws) gives 2 and `http_error`, not `internal_error`; a real `scan` that throws; and `specify.ps1` called in process with its output captured returns the same lines as at `phase2-done`. |
| M-3 | B-3 | FR-312, FR-303, AC-318 (spec:58, 136, 334) | Preferred: cut FR-312, AC-318 and WP-3H from this phase (OQ-303). If kept: "A stage may be reused only if **every earlier stage of this replay was reused**, its recorded input hashes (task, spec, review, context, registry) equal the current ones, and its output hash matches. The superseded record gets a new field `supersededBy`; uniqueness is (`id`, `attempt`, `resume`). A recorded-`running` stage of a dead run is closed as `failed` with `stage_interrupted`. `stage_begin` may return `{ reuse, verdict }`. Task, name and mode come from the manifest and `inputs\task.md`; `-Task` is not given. Checks run in this order: lock (`artifact_in_use`, manifest untouched), then state (`invalid_arguments`)." |
| M-4 | B-4 | FR-301, FR-302, FR-308, AC-301, AC-313 | "`harness.ps1` declares no `[CmdletBinding()]`, no `[Parameter()]` and no validation attribute; it parses `$args` itself against a literal command-by-option table in this spec, so that every bad input reaches the harness and exits 2. An option without a value, an unknown option and a leftover positional value are `invalid_arguments`; option names must be complete. `-Include` is one string with comma-separated relative paths (a path containing a comma is `context_invalid`)." Add that table. One error format: `ERROR: <token>: <text>`, and say whether an argument error creates a manifest (proposed: **never**; delete "a failed manifest otherwise" in AC-301). |
| M-5 | B-5 | Execution Order (spec:463-468) | Replace by the packages of section 9, whose exit checks only name criteria that can pass at that step. |
| M-6 | B-6 | FR-304, FR-311 | "The run directory is claimed by `CreateDirectory` and then opening `.claim` with `FileMode.CreateNew`; the loser gets `invalid_arguments`." Run id: `\A[A-Za-z0-9](?:[A-Za-z0-9_-]\|\.(?!\z)){0,63}\z`, not a device name (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`). `AI_HARNESS_RUN_ID` is a telemetry correlation id, not a unique run id: an environment value whose directory exists makes the CLI append `-<4 hex>` and warn `run_id_env_reused`, never fail. Delete the `Local\` fallback: when the `Global\` name is refused, the artifact lock is `artifact_in_use` and the telemetry lock prints a warning and relies on the retry of M-1. For (d) add: "`AbandonedMutexException` counts as acquired." Lock key: the resolved, long, trimmed path plus the name **family** (M-8). |
| M-7 | B-7 | FR-305, FR-306, AC-309 | One statement: "The schema enums are the XR-08 lists, including the states this phase never writes; the CLI writes only the states listed in FR-305." Subset of JSON Schema: `type` may be an array (nullable fields). Comparisons are ordinal (`-ceq`, `-ccontains`). Give the JSON path format literally, for example `$.stages[0].status`. |
| M-8 | B-8 | FR-302, FR-303, FR-304, new AC | "`specify` through the CLI refuses a name whose `<Name>.md` or any `<Name>.revised-vN*` exists, with `artifact_exists` (exit 2), unless `-Overwrite`; with it the old family is first moved to `runs\<id>\replaced\`. Names ending in `.review` or `.revised-v<digits>` (or containing `.revised-v<digits>.`), in a dot, or equal to a device name are `invalid_arguments`. `<target>`, `.ai-harness` and `specs` must not be reparse points." New AC for each. |
| M-9 | I-1, I-2 | AC-320, AC-308 | AC-320: "byte-identical after `scannedAtUtc` and `rootPath` are replaced by a placeholder". AC-308 and FR-305: readers open with `FileShare.ReadWrite, Delete` and retry up to 25 times, 20 ms apart, on `IOException` **and `FileNotFoundException`**; the writer also retries (50 times, 20 ms); `File.Replace` gets `[NullString]::Value`. |
| M-10 | I-3 to I-6 | FR-308, FR-303, FR-305 | Close the outcome table: revised validation exit 1 and 3; validator exit other than 0, 1, 3 or a throw; reviewer exit outside 0, 1, 2; a stage that exits 0 with a missing or empty output; the skip reason when there is no failing stage. Say the source of `error.retryable` and of `attempt` for every stage. |

## 3. Findings

### Blockers

| ID | Where | Evidence | Suggestion |
|---|---|---|---|
| B-1 | spec:104 with spec:130; `scripts/lib/telemetry.ps1:132, 193, 197` | `Add-Content` fails while another process has the file open for reading, even with share `ReadWrite` (the exact share mode was not investigated). FR-307 makes the CLI read `model-calls.jsonl` after each stage, outside the lock. With the mutex of FR-311 **and** that read, 2 writers kept **43 and 5 of 80** records (80 and 80 without the read, and 80 and 80 when the read is inside the lock). A separate reader every 100 ms cost 6 and 12 of 80. AC-310 and AC-316 can therefore fail, or pass by luck. | M-1 |
| B-2 | spec:46, 58, 108, 142; `run-agent.ps1:220`, `review-spec.ps1:217`, `revise-spec.ps1:165` and `:103, 137, 147, 152`; `scan-repository.ps1`, `build-context.ps1` (no `exit`) | Three facts break FR-303 as written. (1) The agent scripts write the answer to the success stream, so a function that returns `{ outcome, ... }` returns an array (probe: `Object[]`, count 2). (2) `revise-spec.ps1` **throws** on every failure, so control leaves the workflow before `stage_end`. The mocks of AC-303 and AC-311 exit 2 and cannot see it; the only end-to-end failure in AC-321 is the reviewer, which exits. (3) `scan-repository.ps1` and `build-context.ps1` throw on error and set no exit code on success (probe: `$LASTEXITCODE` stayed 7 after a good scan). | M-2 |
| B-3 | spec:58, 98, 136, 334 | Four contradictions. (1) A stage is reused when its own output hash matches: edit the generated spec, resume, and `spec-generate` runs again but the old `spec-review` verdict (its file unchanged) is reused for the **new** spec. (2) "Earlier stage records are kept" while deterministic stages always rerun breaks the (`id`, `attempt`) uniqueness of FR-306, so every resume writes an invalid manifest. (3) A second resume of a live run is `invalid_arguments` in FR-312 and `artifact_in_use` in AC-318, which also lists a live run under `invalid_arguments`. (4) The hook of FR-303 returns nothing, so it cannot make the workflow skip a stage. Registry and context changes are not compared either. | M-3 |
| B-4 | spec:50, 52, 112, 198, 342 | Probes with `powershell.exe -File` (how Claude Code and every suite start a script): `-Include a.md,b.md` arrives as **one** string; `-Include a.md b.md` silently binds `b.md` to the next parameter. With `[Parameter]` or `[CmdletBinding]`, an unknown option, `-Revision abc`, an ambiguous prefix or a missing value ends with **exit 1** (a workflow failure in FR-308) and localized text, before the script runs. Without them, a missing value still exits 1. The first error line is `invalid_arguments:` in FR-302 and AC-301 but `ERROR: invalid_arguments:` in FR-308 and AC-313. AC-301 demands a failed manifest for a bad option of a read-only command, which FR-301 forbids. No table says which option belongs to which command. | M-4 |
| B-5 | spec:463-468 | Exit checks that cannot pass at their step: AC-308 in WP-3C (needs a running workflow, WP-3F); AC-315 and AC-326 ("every command") in WP-3E; AC-302 in WP-3D (wants `ContextFile` on two scripts, added in WP-3G); AC-306 in WP-3F (`scan`, `context` come in WP-3G). AC-303, the only regression oracle of the extraction, is in WP-3F although its legacy half is the gate of WP-3D. WP-3F carries 12 criteria. | M-5, section 9 |
| B-6 | spec:64, 130 | "Created with an existence check" is a race: 4 processes, 200 ids, 200 expected winners: `Test-Path` then `New-Item` gave **525**, then `CreateDirectory` gave 617, then `CreateNew` gave **200**. The `Local\` fallback creates a **second** mutex, so two refused processes do not exclude each other (probe: `Global\` refused with `UnauthorizedAccessException`, `Local\` acquired at once). `GetFullPath` does not resolve a relative path against the PowerShell location (probe: it used the process directory), so it can lock and write under another folder; it keeps a trailing backslash, so `C:\x` and `C:\x\` give two lock keys. The run-id pattern accepts `"abc\n"` (`$`), `CON` and `abc.` (created as `abc`). `NUL` is an error. A fixed `AI_HARNESS_RUN_ID`, which today groups several calls, makes the second command fail. | M-6 |
| B-7 | spec:82, 88, 92, 262 | FR-305 lists 4 run states and 6 stage states as the schema; AC-309 asserts that the accepted values equal the XR-08 lists, which have 7 and 7 (roadmap XR-08 table). Both cannot hold. | M-7 |
| B-8 | spec:52, 58, 66, 72; `specify.ps1:159, 242, 332` | The workflow deletes `<Name>.md` before generating. In the legacy folder that is disposable; in a target it is a spec a human may have approved or committed (O-06 is open), and a generation failure leaves nothing. Stale `.revised-vN` files of an older run stay beside new ones. Names alias: `foo.revised-v1` and `foo.review` are valid names and write the same files as `foo`, and the lock (target and name) does not see it. `<target>\.ai-harness` may be a junction (created without elevation in a probe; writes landed outside the target), which breaks NFR-302. | M-8 |

### Important

| ID | Where | Evidence | Suggestion |
|---|---|---|---|
| I-1 | spec:350; `scan-repository.ps1:144` | The scan output holds `scannedAtUtc` and an absolute `rootPath`, so "byte-identical to the frozen output" is impossible. | M-9 |
| I-2 | spec:78, 254 | With `File.Replace` and the retry of the spec (5 x 20 ms), the reader ran out in 8 of 9 runs (`ReadAllText`) and in 1 of 2 runs with `FileShare.Read`; `FileNotFoundException` occurs too (the replace is not gap-free). With share `ReadWrite, Delete` no reader ran out, and the writer never failed with 50 tries. `File.Replace(a, b, $null)` throws `ArgumentException` in PowerShell 5.1. FR-305 gives the writer no retry. | M-9 |
| I-3 | spec:108, 214, 278 | Undefined outcomes (revised validation, validator crash, unexpected reviewer exit, missing output with exit 0). `specify.ps1` tests all of them today. | M-10 |
| I-4 | spec:88, 104 | `error.retryable` is in FR-305 but the telemetry record has no such field, and FR-307 forbids other sources. | Derive it from the category table, or drop it |
| I-5 | spec:92, 278 | AC-311 wants every planned stage `skipped` with `dependency failed: <id>` for `registry_invalid` and `agent_not_found`, but no stage failed, so there is no id. `attempt` of `spec-revise` and of the validations is not given. | Literal reasons and attempts |
| I-6 | spec:108, 130, 98 | `artifact_in_use` with `-Resume` would write an error into the live run's manifest. | M-3 order |
| I-7 | spec:52 | `revise -Revision N` and `review -Revision N` do not say which files are read and written, or whether an existing output is overwritten; no AC runs either command against its files. | One table and one AC |
| I-8 | spec:78 | `ConvertTo-Json -Depth 10` of a string from `Get-Content` (with or without `-Raw`) was killed after 15 s (an ETS object graph); from `ReadAllText`, or cast to `[string]`, it took under 0.1 s. A manifest builder that reads a file this way hangs. | "Every string comes from .NET I/O or is cast" in FR-305, one AC |
| I-9 | spec:83 | `git status --porcelain` rewrote `.git\index` in a probe; with `--no-optional-locks` it did not. FR-305 calls it read-only. | Use `--no-optional-locks` |
| I-10 | spec:168, 476 | NFR-302 says the harness root changes only in `runs\` and `logs\`, but a target equal to the harness root is allowed and writes `<harness>\.ai-harness\specs\`. It also says legacy `specify.ps1` changes only `specs\`, but its agents write `logs\` today. | State both exceptions |
| I-11 | spec:146-148, 366; `test-engine-callsites.ps1:2044` | The "8 AC-216 cases" are 1192 to 1276, but a ninth AC-216 case (line 2044) asserts that the wrappers **exist** in `agent-exec.ps1` and must go too; the wrapper driver (about lines 335-375) also goes. "The authorized edits are exactly these" does not list them. The notes' N-7 (the 7 others "stay", "for the reviewer and reviser") is wrong: 3 are `run-agent` cases and 1 is the ninth. | Name 9 cases and the driver |
| I-12 | spec:154, 374 | The split is not "file and order only": many cases are produced by loops over several scripts (for example lines 1886, 1931 and 2022), and the case at line 2013 tests two scripts in one body. Names are built at run time (85 `Test-Case` sites, 160 cases), so the fixture must hold names printed by a run, not source names. | Allow a loop list edit; take names from the run log |
| I-13 | spec:318, 310 | AC-316 starts two runs "together" with no handshake: the first may finish before the second starts, and both exit 0. AC-315 and AC-317 have the same shape. | A mock that waits on an event file; state the limit |
| I-14 | spec:390 | AC-325 allows only listed files and fails on this review (as the Phase 2 footprint check did, final QA I-2). | Add `docs/audits/*phase3*` |
| I-15 | spec:27, 120-124; roadmap XR-06, section 5 "Scope classification", Phase 3 AC-302 | `-Background` and `cancel` are `[M]` in the roadmap, and Phase 3 AC-302 tests them. The spec drops them as an OQ, with O-11 still open. The argument is sound, but it is a change of mandatory scope and needs a recorded owner decision and a roadmap edit. The same holds for the XR-04 policy (OQ-313) and the XR-03 context budget (OQ-312). | Owner record, then a roadmap note |
| I-16 | spec:142 and `.ai-harness\` exclusion | With a target equal to the harness root, `scan` includes `runs\` (other runs' `task.md`), against NFR-305's intent. | Exclude `runs` in that case, or refuse that target |

### Nits

| ID | Where | Note |
|---|---|---|
| T-1 | spec:6 and notes section 1 | The notes' assumptions N-1 to N-7 reuse the final QA's N-1 to N-18. Rename them. |
| T-2 | roadmap Phase 3 | The roadmap also has FR-301 to FR-307, NFR-301/302 and AC-301 to AC-306, with other meanings. The spec's IDs do not collide with Phase 0 to 2 (checked), but citations in the notes mix both. Cite the roadmap as "roadmap FR-3nn". |
| T-3 | spec:162 | NFR-301 forbids `Start-Process` in the new files; the tests may use it. Say so. |
| T-4 | spec:310 | "A manifest edited to another start time" should also say the expected value for a pid that does not exist. |
| T-5 | spec:382, 398 | AC-324 and AC-326 repeat the same static scan. |
| T-6 | spec:130 | "Writes unlocked" after a timeout can lose a record, so "exactly one record holds under overlap" is too strong. |
| T-7 | spec:118 | `list` and `status` should say what they do with a corrupt manifest. |
| T-8 | spec:89 | `artifacts[].path` is relative to the target for specs and to the run folder for `context.txt`; add a root field. |

## 4. Re-verified claims

| Claim | Result |
|---|---|
| `specify.ps1` 382 lines, four seams, exit 0 to 3, no `-ContextFile`, no `-Profile` | confirmed (382 newlines) |
| One record per call, 31 columns, `run_id` from `AI_HARNESS_RUN_ID` or a GUID | confirmed by reading the engine and the writer |
| `ContextFile` only on `run-agent.ps1`; reviewer and reviser builders have no context part | confirmed |
| Telemetry loss: 2 processes 1 to 14 of 80, 4 processes 6 to 8 of 160 | confirmed in order of magnitude: 1 to 17 of 80, 1 to 16 of 160 |
| Wrappers unused in scripts; `Write-Host` exemption and pinned list in `test-agent-prompts.ps1` | confirmed (only the suites call them) |
| `test-engine-callsites.ps1` 2,081 lines, 160 cases, about 164 s | confirmed (160 passed, 164.8 s in this run) |
| 8 AC-216 wrapper cases | partly: 8 use the wrappers, a ninth asserts that they exist (I-11) |
| `scan-repository.ps1` does not exclude `.ai-harness`; no `runs/` in `.gitignore` | confirmed |
| `phase2-done` is `8c26f72`; only the spec and notes added since | confirmed |
| Notes: "A failed availability check or budget stop also writes one record" (N-3) | confirmed |
| Notes: `Test-OllamaModel` works with no `-TelemetryRoot` | confirmed by reading; not run |
| Notes: File.Replace and Global mutex "not tried" | tried here: usable, with the limits of I-2 and B-6 |
| `validate-spec.ps1` passes; 15 FR, 5 NFR, 27 AC; matrix is the inverse | confirmed with my own script (47 ids, no duplicate, no missing Source or Verifies, 20 rows equal) |
| Roadmap FR-304 wants context in every stage | confirmed; the spec's FR-313 covers it (requirement ids collide only with the roadmap, T-2) |
| Offline `test-all` at this commit | 19 discovered, 18 PASS, 0 FAIL, 1 SKIPPED (live), tripwire clean |

## 5. Concurrency experiments

Each child is a `powershell.exe` process, 40 writes, 5 ms pause, released together; times are the longest of the run; expected count in brackets. Retry modes append only a JSONL line (no CSV), so compare them only for loss.

### 5.1 Writers alone (3 runs each)

| Mechanism | 2 processes [80] | 4 processes [160] | 8 processes [320] | Longest single call |
|---|---|---|---|---|
| Current writer (`Add-Content`) | 1, 17, 4 | 1, 6, 16 | 3, 4, 1 | 200 ms |
| Named mutex around the real writer | 80, 80, 80 | 160, 160, 160 | 320, 320, 320 | 272 to 1,195 ms |
| Lock file, `FileShare.None`, 10 s | 80, 80, 80 | 160 x3 | 320 x3 | 313 to 1,700 ms |
| `FileStream` append, 5 tries | 80 x3 | 159, 160, 160 | 313, 311, 317 | 164 ms |
| `FileStream` append, up to 200 tries | 80 x3 | 160 x3 | 320 x3 | 228 ms |
| One file per process | 80 x3 | 160 x3 | 320 x3 | 162 ms |

The mutex and a bounded retry both work; a retry of 5 is not enough with 8 processes. A per-process file also works but changes XR-01 file names, so I do not recommend it.

### 5.2 Writers while someone reads (2 processes [80], 2 runs each)

| Writer | Reader | Kept |
|---|---|---|
| mutex + real writer | none | 80, 80 |
| mutex + real writer | FR-307 style read after each write, outside the lock | **43, 5** |
| mutex + real writer | read inside the lock | 80, 80 |
| mutex + real writer | separate reader every 100 ms | 68, 74 |
| mutex + real writer | separate reader every 20 ms | 6, 58 |
| mutex + `FileStream` append with retry and `FileShare.ReadWrite` | FR-307 style read, outside | 80, 80 |
| same | separate reader every 100 ms | 80, 80 |
| same | FR-307 style read plus a tight reader | 80, 80 |

A first run of this table was discarded: its children lacked `$ErrorActionPreference = 'Stop'` and an undrained stderr pipe hung them. It also showed that the writer loses records **silently** when the caller does not set `Stop` (the `Add-Content` failure is then a non-terminating error and the `catch` never sees it).

### 5.3 Locks, run directories, manifest writes

| Question | Result |
|---|---|
| Mutex held by another process | `WaitOne(0)` false |
| Holder killed, our handle open | `AbandonedMutexException` (must count as acquired) |
| Holder killed, new handle | acquired |
| Same thread, second `WaitOne(0)` | true (recursive: an in-process second run is not excluded) |
| Global name refused, Local fallback | Local acquired: no exclusion |
| Run directory claim, 4 processes, 200 ids (200 winners expected) | `Test-Path` + `New-Item` 525; `Test-Path` + `CreateDirectory` 617; `CreateNew` claim file 200 |
| `File.Replace`, reader `ReadAllText`, 5 x 20 ms (9 runs) | reader ran out 0 to 19 times per run, in 8 of 9 runs; no partial JSON |
| `File.Replace`, reader share `ReadWrite, Delete` | 0 exhausted at 5 tries; 9 to 87 `FileNotFoundException`; writer 0 failed with 50 tries |
| `MoveFileEx` (P/Invoke), reader share `ReadWrite, Delete` | 0 reader errors, writer 76 to 115 retries, 0 failed |

I recommend `File.Replace` with both sides retrying; `MoveFileEx` needs `Add-Type` and is not worth it.

## 6. Answers to the open questions

| OQ | Answer | Reason |
|---|---|---|
| OQ-301 | Accept | Also resolve the path against the PowerShell location, trim and reject reparse points (B-6, B-8). |
| OQ-302 | Accept, as a recorded owner decision | It removes `[M]` scope and a roadmap AC (I-15). |
| OQ-303 | **Change: cut resume from this phase** | B-3: the hardest item and the least defined. A killed run can be started again. |
| OQ-304 | Accept | With `retryable` resolved (I-4) and M-1. |
| OQ-305 | Accept | |
| OQ-306 | Accept | |
| OQ-307 | Accept | |
| OQ-308 | Accept | With the error format of M-4. |
| OQ-309 | Accept | O-12 stays open in the roadmap. |
| OQ-310 | Accept | Define the revised-validation and crash cases (M-10). |
| OQ-311 | **Change** | No `Local\` fallback; key on the canonical path and the name family; `FileStream` retry beside the mutex (M-1, M-6). |
| OQ-312 | Accept | |
| OQ-313 | Accept | Note in the roadmap that XR-04's shared policy is deferred (I-15). |

## 7. Decisions the owner must make (not in the spec)

1. Overwrite policy for an existing spec in a target (M-8). My recommendation: refuse, with an explicit `-Overwrite` that moves the old family into the run folder.
2. The name grammar (no `.review` or `.revised-vN` suffixes).
3. The option syntax of `-Include` (comma list, or a file).
4. Whether a target equal to the harness root is allowed at all.
5. Retention of `runs\`, which keeps full task texts (pruning is `[O]`, but nothing ever deletes them).
6. Whether the four script seams stay in the shipped CLI: they let an allowed `harness specify` run any script path. Phase 4 permission rules will need this answer.
7. Recording the dropped `[M]` scope (I-15) and whether Phase 3 is split (section 9).

## 8. Security notes

- Path traversal: `-RunId` and `-Name` patterns reject separators, but see B-6 and B-8 (device names, trailing dot, aliasing, reparse points).
- The existing `build-context.ps1` guards hold for `-Include`; `scan` and `context` write only into the run folder.
- `error.message` from the telemetry `error` column can contain an Ollama error string; no prompt text goes there. The manifest holds absolute local paths, which is acceptable in a git-ignored folder.
- No Phase 3 criterion needs a live model; `doctor` calls only `/api/tags`, and the tests use the fake host. WP-2E is correctly kept separate.

## 9. Size and split

By my estimate the phase is 12 to 13 sessions plus the final QA, not 8. Of those, the engine wrappers and the suite split are one session each and safe if M-5 and I-11, I-12 are applied; they should be separate, the wrapper deletion first. I recommend splitting the phase into 3A (steps 1 to 3 below, ready first) and 3B (the rest). Proposed packages:

| Step | Package | Implement / review | Exit check |
|---|---|---|---|
| 1 | Telemetry lock and append with retry | Sonnet / Opus | AC-317 with M-1 |
| 2 | Wrapper deletion | Sonnet / Sonnet | AC-322 |
| 3 | Suite split | Sonnet / Sonnet | AC-323 |
| 4 | Manifest library, schema, claim, atomic write (no workflow) | Sonnet / Opus | AC-309; the writer and reader half of AC-308 |
| 5 | Workflow extraction, `-Profile`, stage contract (M-2) | **Opus** / Opus | AC-304; legacy half of AC-303; AC-302 without the two new parameters |
| 6 | CLI dispatch and options (M-4), read-only commands except live-run status | Sonnet / Sonnet | AC-301, AC-312, AC-314 |
| 7 | `specify`: layout, manifest, checkpoints, correlation | **Opus** / Opus | AC-305, AC-307, AC-308, AC-310, AC-321 |
| 8 | `review`, `revise`, failure matrix, protocol, overwrite rule, status and list | Sonnet / Opus | AC-303, AC-311, AC-313, AC-315, AC-327 |
| 9 | Artifact lock, concurrent runs | **Opus** / Opus | AC-316 |
| 10 | Context: `-ContextFile` and builders | Sonnet / Opus | builder part of AC-319; AC-302 |
| 11 | Context: scan, include, exclusion | Sonnet / Opus | AC-319, AC-320, AC-306 |
| 12 | Unattended run of every command, footprint, regression | Sonnet / Sonnet | AC-324 to AC-326 |
| later | Resume, only if OQ-303 is kept | Opus / Opus | AC-318 |

Scope creep into Phase 4 to 6: none found beyond small fields (`verification`, `trust`, `process.background`), which the roadmap also wants. Duplication of Phase 2: none, the engine is reused.

## 10. Not verified

- Anything against Ollama, including real durations and `abandoned` detection in a real long call.
- A mutex or file owned by another Windows user or an elevated process (only a denied ACL was imitated), or another session.
- Whether a real antivirus or indexer changes the `File.Replace` numbers; the writer and reader were on one machine and disk.
- Cultures other than es-ES, other PowerShell 5.1 builds, a slower disk, and a network `TEMP`.
- The real 16 KB or larger manifest size; the probe used about 4 KB.
- `Process.StartTime` precision against the 2 s tolerance, `Claude Code run_in_background` behavior (A-305) and Phase 4's use of the exit codes.
- The proposed M-1 to M-10 texts were not implemented; only the mechanisms of section 5 were run, outside the repository.
