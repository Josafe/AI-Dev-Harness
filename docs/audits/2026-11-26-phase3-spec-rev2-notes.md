# Phase 3 specification, revision 2: notes

**Branch:** `docs/phase3-spec-rev2`, from `master` at `ec05225` (tag `phase2-calibrated` is an ancestor). Revision 1, its notes and the review were brought in by checkout from `origin/docs/phase3-spec-review` (no merge). Deliverable: `specs/harness-phase-3-unified-cli.md`, revision 2. Only documents were added or changed. Nothing was pushed. Written unattended; every choice not covered by the owner decisions is an Open Question with a RECOMMENDATION in the spec.

**Checks run:** `scripts\validate-spec.ps1`: STATUS PASS. A separate script (in `%TEMP%`, not committed) confirmed: 18 FR, 5 NFR, 33 AC (AC-318 cut); every FR and NFR has at least one AC; every AC has exactly one `Verifies:` and one `Source:` line; every requirement has one `Source:` line, all of USER, PROJECT, FACT or ASSUMPTION; the traceability matrix equals the inverse of the `Verifies:` lines (23 rows); every FR, NFR, AC, D, OQ, RK and A id used in the text is defined; no non-ASCII characters. No code of the harness was run, so none of this verifies behavior.

**Size: 68.4 KB (66.8 KiB), above the 55 KB target. It does not fit.** Revision 1 was 53.6 KB, and the owner decisions add scope (WP-2E requirements, argument table, stage contract and outcome table, name and overwrite policy, split into stages). Three compression passes saved about 3 KB of wording and the sections are now dense. To reach 55 KB the owner would have to cut about 13 KB of scope, in this order of cost to value:

| Cut | Saves | Effect |
|---|---|---|
| FR-318 and AC-333 (`doctor` preflight, VRAM, load check) | about 2.7 KB | decision 13(c) would go to a later phase |
| FR-315, AC-323, package A3 (suite split) | about 1.5 KB | decision 14 would go to a later phase |
| Review and revise commands: FR-319 second paragraph, AC-334, package B5 | about 1.8 KB | CLI keeps `specify`, `scan`, `context` |
| FR-309 detail and AC-314, AC-315 (`list`, `status` derived state) | about 3 KB | `status` and `list` deferred |
| AC-329, AC-330, AC-331 literal lists shortened | about 1.2 KB | weaker criteria |
| Risks, Edge Cases, Not Verified, Open Questions text | about 2.5 KB | less context in the spec |
| Execution Order shortened to a list of package ids | about 1.5 KB | less detail on exit checks |

None of these was applied, because each contradicts a decision or weakens a criterion.

## 1. Owner decisions and where they are applied

| Decision | Spec |
|---|---|
| 1 cut `-Resume` | D-301; FR-312 and AC-318 not used; WP-3H gone; listed under Deferred |
| 2 no `-Background`, `cancel`, `console.log`; roadmap deviation | D-302 (states XR-06 and Phase 3 AC-302 scope drop, XR-04 policy and XR-03 derived budget deferred); FR-310; OQ-322 (roadmap edit left to the owner) |
| 3 `develop` exits 4; legacy writes no manifest | D-303; FR-301, FR-308, AC-312 |
| 4 split into 3A and 3B with a gate | D-304; Execution Order (A1 to A4, gate, B1 to B9); sonnet and opus marked |
| 5 overwrite policy, name grammar | D-305; FR-319; AC-328 |
| 6 `-Include` is one comma string | D-306; FR-313; AC-301, AC-320 |
| 7 target is not the harness root; no reparse points | D-307; FR-302, FR-319; AC-301, AC-328 |
| 8 telemetry: mutex plus `FileStream` append, locked reader, no `Local\` | D-308; FR-311(c), FR-307; AC-317 |
| 9 run claim, run id, `AI_HARNESS_RUN_ID` reuse, `File.Replace`, .NET strings | D-309; FR-304, FR-305; AC-308, AC-329 |
| 10 seams are not CLI parameters; `$args` parser; table | D-310; FR-302; AC-301 |
| 11 stage contract, outcome table | D-311; FR-303, FR-308; AC-303, AC-311, AC-330 |
| 12 schema enums equal XR-08; written subset; JSON Schema subset | D-312; FR-305, FR-306; AC-307, AC-309 |
| 13(a) truncation signal | FR-316; AC-331, AC-321 |
| 13(b) model-load category, no retry | FR-317; AC-332, AC-311, AC-321 |
| 13(c) `doctor` preflight and optional load check | FR-318; AC-333 |
| 13(d) model-switch policy | OQ-317 only, with the live data; nothing designed |
| 14 kept items (join by ids, no daemon, nine wrapper cases and driver, suite split with names from a run log, AC-325 footprint, NFR-302 exceptions, `--no-optional-locks`, `runs` excluded from scan when relevant) | D-314; FR-305, FR-314, FR-315, NFR-302, AC-322, AC-323, AC-325; `runs` case: see I-16 |

## 2. Review findings

"Applied" means the review text or an equivalent is in the spec. IDs are those of `docs/audits/2026-11-25-phase3-spec-review.md`.

| ID | Result | Where and note |
|---|---|---|
| M-1 (B-1) | applied | FR-311(c), FR-307 (reader inside the lock, retries, BOM), AC-317 (two readers plus a looping reader lose nothing). Added: the bytes equal `Add-Content -Encoding UTF8` (BOM only on creation), so the CSV and JSONL stay byte-compatible |
| M-2 (B-2) | applied | FR-303 stage contract (statement call, pass-through, `-Result`, `$global:LASTEXITCODE` reset, throw is a failed stage, legacy rethrow, no exit codes for scan and context), AC-330, AC-311, AC-321 (real `revise-spec.ps1` 500 is `http_error`; `specify.ps1` output equals the frozen lines) |
| M-3 (B-3) | applied as a cut | the review prefers cutting resume (decision 1); all four B-3 contradictions vanish with it |
| M-4 (B-4) | applied | FR-302 (no attributes, `$args`, literal table, one error format `ERROR: invalid_arguments:`, argument errors never create a manifest); AC-301 |
| M-5 (B-5) | applied | Execution Order; each exit check can pass at its step (AC-306 and AC-308 checkpoints moved to the packages where they can) |
| M-6 (B-6) | applied, one extension | FR-304 (claim, regex, device names, env id reuse), FR-311(d) (no fallback, abandoned counts as acquired, key from the resolved long trimmed path and the name family), FR-302 (resolved against the PowerShell location); AC-329, AC-316. Extension: the device-name rule applies to the text before the first dot (`con.x`), because Windows treats `CON.txt` as a device |
| M-7 (B-7) | applied | FR-305 states, FR-306 (type arrays, ordinal comparison, literal path), AC-309 |
| M-8 (B-8) | applied | FR-319, FR-302 (reparse points), AC-328 |
| M-9 (I-1, I-2) | applied | AC-320 (placeholders), FR-305 (share modes, retries on both sides, `[NullString]::Value`), AC-308 |
| M-10 (I-3 to I-6) | applied | FR-308 outcome table (13 rows), FR-305 (skip reasons, `attempt`, `retryable`) |
| B-1 to B-8 | applied | by M-1 to M-8 |
| I-3 | applied | FR-308 table |
| I-4 | changed | `error.retryable` is derived from `engineCategory` (true for `http_5xx`, `transport_reset`), not from a telemetry field; meaning documented as "the engine retried it itself" |
| I-5 | applied | `dependency failed: <id>` or `not reached: <category>` (FR-305); `attempt` source stated |
| I-6 | applied | FR-311(d): `artifact_in_use` touches no artifact; resume is gone |
| I-7 | applied | FR-319 reads and writes per command; AC-334 |
| I-8 | applied | FR-305 string rule; AC-308 (200 KB task under 5 s) |
| I-9 | applied | `--no-optional-locks` in FR-301 and FR-305; AC-306 checks `.git\index` |
| I-10 | applied | NFR-302 states the legacy `logs\` footprint; the target-equals-harness-root case is refused |
| I-11 | applied | FR-314 and Context name the nine cases (lines 1192, 1211, 1225, 1233, 1243, 1254, 1266, 1276, 2044, verified by grep at `phase2-calibrated`) and the driver; AC-322 |
| I-12 | applied | FR-315 (loop list edit, names from a run log, line 2013), AC-323 |
| I-13 | applied | event-file handshakes in AC-315, AC-316; the limit of the proof is stated in AC-316 |
| I-14 | applied | AC-325 allows `docs/audits/*phase3*` |
| I-15 | applied | D-302 and OQ-322 record the dropped `[M]` scope; the roadmap is not edited here |
| I-16 | changed | decision 14 says "`runs` excluded from scan when relevant". The relevant case is a target that contains the harness root; the spec refuses such a target instead of excluding (OQ-314, RECOMMENDATION, applied), because `scan-repository.ps1` has no exclusion parameter and adding one changes its interface (AC-302) |
| T-1 | applied | this file uses `RN-` ids |
| T-2 | applied | the ID line cites the roadmap as "roadmap FR-3nn" |
| T-3 | applied | NFR-301 "Tests may use `Start-Process`" |
| T-4 | applied | AC-315 covers a pid that does not exist |
| T-5 | applied | AC-326 no longer repeats the static scan of AC-324 |
| T-6 | applied | Edge Cases and AC-316 say a record may be lost without the lock |
| T-7 | applied | FR-309, AC-315 (`unreadable`, `manifest_invalid`) |
| T-8 | applied | `artifacts[].root` in FR-305 |
| Review section 6 (OQ-301 to OQ-313) | applied | OQ-301, 305, 308, 310 stay as Open Questions (recommendation applied); OQ-302 is D-302; OQ-303 is D-301; OQ-304 is D-314; OQ-306, OQ-307 are D-303; OQ-309 is under Deferred; OQ-311 is D-308 and D-309; OQ-312, OQ-313 are in D-302 |
| Review section 7 (owner decisions 1 to 7) | applied | 1, 2 are D-305; 3 is D-306; 4 is D-307; 5 (retention of `runs\`) is OQ-319 (README note, no pruning); 6 is D-310; 7 is D-302 and D-304 |
| Review section 8 (security) | applied | name and run-id patterns, junction checks, no prompt text in `error.message`; absolute paths in the manifest are OQ-319 |
| Review section 9 (packages) | applied, one added | its 12 packages are A1 to A3 and B1 to B9; A4 (engine signals) is new, so 13 packages; the order is telemetry, wrappers, split, signals (the review had wrappers after telemetry too) |

## 3. Choices made beyond the decisions (all in the spec as RECOMMENDATIONS or fixed wording)

| ID | Choice | Why |
|---|---|---|
| RN-1 | Detection rule `promptChars > 7 * n` (FR-316), constant 7 in the engine | From WP-2E s4 and s5: healthy 3.93 to 5.43, cut prompt 10.49; a cut to half the window doubles the ratio, so 7 sits between 5.43 and 7.86. One live truncation in WP-2E, three more in the owner's 2026-11-25 probe (FR-316 Probe): OQ-316, OQ-320 |
| RN-2 | The new warning is `prompt_truncation_detected`; `possible_prompt_truncation` keeps its rule and is printed too | Changing the old rule would change Phase 2 goldens and cases; the owner asked for the old name to be loud |
| RN-3 | The stage outcome does not change when truncation is detected | A failing rule needs more live evidence (OQ-316) |
| RN-4 | `model_load_failed` is chosen from the Ollama JSON `error` text for a 5xx (three literal substrings, case-sensitive) | The data (WP-2E s13.1, s13.2) has no other discriminator; this is the one exception to Phase 2 NFR-202 "never from message text", noted in FR-317 |
| RN-5 | `Test-OllamaModelLoad` is a new engine function; `-LoadCheck` on `doctor` and as stage `load-check` of `specify` | Decision 13(c) asks for one tiny request per model; the warm-up request shape loads without generating (A-307) and uses the profile's `num_ctx` so no later reload |
| RN-6 | `doctor` reads the version with `GET /api/version` and VRAM with `nvidia-smi` (optional, 5 s, no admin) | "Ollama version" and "free-VRAM note only if readable without admin rights"; `nvidia-smi` is the only unprivileged source known here; not verified on this machine |
| RN-7 | `lib\cli.ps1` with `Invoke-HarnessCli -Command -Options [-StageScripts] [-Hook]` is the test entry | Decision 10 forbids script-path parameters; tests still need mock stages |
| RN-8 | `$null` exit code counts as success, except for the reviewer | `validate-spec.ps1` has no `exit`; with the reset to `$null` required by decision 11 the PASS must not become a failure. Legacy sees the same result today only because the previous stage left 0 |
| RN-9 | Categories `artifact_exists`, `artifact_in_use`, `stage_failed`, `model_load_failed` added; read-only tokens `manifest_invalid` etc. are not manifest categories | Needed by decisions 5, 8 and 13 and by FR-309 |
| RN-10 | Telemetry bytes must equal `Add-Content -Encoding UTF8` output (BOM at creation, CRLF) | Keeps the Phase 2 telemetry files and golden header unchanged |
| RN-11 | `specify` and `review` hold the artifact lock; `scan` and `context` do not | They write only under `runs\<id>\` |
| RN-12 | `harness review` with a FAIL verdict exits 1 `review_failed`; `revise` also validates its output | XR-10 and the workflow; one stage `revised-validate` more |
| RN-13 | A new engine warning could change a Phase 2 case whose fake `prompt_eval_count` is small against a large prompt | RK-305; A4 must list each edited fake value; no expected value changes |
| RN-14 | Packages are named A1 to A4 and B1 to B9 instead of WP-3x | "3A" and "3B" would clash with WP-3A and WP-3B of revision 1 |
| RN-15 | Not applied: WP-2E s13.6 (run-time `charsPerToken`), 13.7 (`num_ctx` in the warm-up key), 13.8 (short load-failure column), 13.9 | The owner listed (a) to (d) only; they are under Deferred |
| RN-16 | Hints of `http_5xx` and `transport_reset` not reworded | Phase 2 tests pin them; OQ-318 |

## 4. Not verified

- No harness script, test or suite was run; no Ollama, no network. Only `validate-spec.ps1` and the consistency script ran, on the spec text.
- Facts about current behavior come from reading the files at `phase2-calibrated`: `specify.ps1` (382 lines), the exits and throws of `run-agent.ps1` (ends `exit 0`, prints the answer), `revise-spec.ps1` (ends `exit 0`), `validate-spec.ps1` (no `exit`), `Get-AgentErrorCategory`, `Invoke-OllamaHttp` (a GET without a body works for another `Purpose`, so `/api/version` needs no engine change), the telemetry writer, the nine wrapper cases (grep), the WP-2E numbers (copied from sections 4.1, 5, 9, 12, 13).
- The concurrency, `File.Replace` and run-claim numbers are the review's experiments; they were not repeated.
- Whether `Test-OllamaModel` can be called per model without a telemetry root (read, not run); whether `nvidia-smi` prints one integer per GPU line with those flags on the owner's driver; whether the 8.3 short-name expansion by a component walk behaves as intended.
- The constant 7 was derived from 16 prompts and one truncation; nothing was tested at another window size.
- Windows device-name behavior for `CON.txt`-style names was taken from general Windows rules, not tested here.
- The size target was not met (section above).
