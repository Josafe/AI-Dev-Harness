# Phase 1 final QA: configuration registry v2

**Date:** 2026-11-21 (file name keeps the date given in the task)
**Reviewer:** independent QA agent. I did not implement any part of Phase 1.
**Subject:** `master` at `0baaf29` (merges of PR #1 and PR #2), checked out on the branch `chore/phase1-final-qa`.
**Spec:** `specs/harness-phase-1-config-registry.md` (Revision 2). **Baseline:** `5ffc33f` (tag `phase0-done`).
**Verdict: ready to tag `phase1-done`: YES.** No blocker. Findings and NOT VERIFIED items are listed below; none of them changes the verdict.

## 1. Scope and limits

**What I did (facts, with commands actually run):**

- Step 0: clean tree, branch `master`, `git pull --ff-only origin master` (5ffc33f to 0baaf29). `git log --oneline -8` contains "Merge pull request #1 from Josafe/feat/phase1-wp1b" and "Merge pull request #2 from Josafe/feat/phase1-migration". `.ai/config.json` has `"schemaVersion": 2`. Branch `chore/phase1-final-qa` created.
- Part A: offline `scripts\test-all.ps1` twice, `git diff --stat 5ffc33f HEAD`, the model-name scan, greps for `think`, `$PROFILE` and `11434`, and `scripts\test-registry-callsites.ps1` alone.
- Part B, read in full, line by line: `scripts/lib/config.ps1` (all of it), `scripts/test-registry.ps1`, `scripts/test-registry-callsites.ps1`, the 15 `tests/fixtures/config-*.json`, `historical-model-names.txt`, the migrated `.ai/config.json`, the complete spec, and `scripts/run-agent.ps1`, `review-spec.ps1`, `benchmark-models.ps1`. I read the diffs of `revise-spec.ps1`, `test-all.ps1` (and lines 600 to 735 of it) and `test-spec-integration.ps1` against `5ffc33f`, not the whole files.
- My own checks, beyond the suites (all offline, nothing sent to any model server):
  - A differential test of the old `Resolve-HarnessModel` (taken from `git show 5ffc33f`) against the new one: 16 configuration shapes (blank, null, whitespace, numeric and array agent entries, `agentModels` as string or array, case differences and others) x 4 agents x 2 `AI_HARNESS_MODEL` values x 3 `-Model` states (unbound, set, blank) = 384 combinations.
  - About 25 in-process probes of `Get-HarnessRegistry` (listed under findings).
  - Two real child-process runs of `revise-spec.ps1` and `review-spec.ps1` from a temporary harness root with an invalid configuration. Both failed on the configuration before any request, and the URL in them was `http://127.0.0.1:9`, not Ollama.

**What I did not do:**

- No live test, no Ollama, no `-IncludeLive`, no `benchmark-models.ps1`, no `test-spec-integration.ps1`.
- I did not re-run the baseline at `5ffc33f`. The "unchanged" check of the Phase 0 suites compares today's counts with the counts in the Phase 0 QA report (`test-spec` 17/0, `test-validate-spec` 54/0) and in the WP-1A report (the other suites).
- I did not read `scripts/lib/telemetry.ps1`, `specify.ps1` and the Phase 0 suites: I only checked that the first two are byte-unchanged in `git diff`.
- I did not read the whole of `revise-spec.ps1`, `test-all.ps1` and `test-spec-integration.ps1` (see above).
- Windows is localized (decimal comma in timings): the suites passed there, which is some evidence for Phase 0 NFR-006, but I tested no other locale.

## 2. Part A: quick facts

| Check | Result | Evidence |
|---|---|---|
| **AC-111** two offline `test-all` runs | **PASS** | Both runs exit 0, `STATUS: PASS WITH SKIPS`, 10 executed / 10 PASS / 1 SKIPPED (the live `test-spec-integration.ps1`). After normalizing timings and temp names, the two outputs have 0 differing lines. Every tripwire is `clean (237 entries before, 237 after)`. `git status --short` is empty after both runs. |
| Counts, run 1 | as expected | `test-spec` 17/0, `test-validate-spec` 54/0 (39 validator runs), `test-agent-telemetry` 23/0, `test-build-context` 15/0, `test-mode-propagation` 11/0, `test-run-agent` 5/0, `test-scan-repository` 26/0, `test-registry` 67/0, `test-registry-callsites` 52/0 (`SKIPPED_TESTS: none` when run alone), `test-syntax` PASS. |
| **AC-112** `git diff --stat 5ffc33f HEAD` | **PASS** | 31 files. Code: `scripts/lib/config.ps1`, `run-agent.ps1`, `review-spec.ps1`, `revise-spec.ps1`, `benchmark-models.ps1`, `test-all.ps1`, `test-spec-integration.ps1`, `.ai/config.json`, the two new suites, 15 fixtures with `historical-model-names.txt`; all are in "Affected Files". Documentation: the spec, 3 audit reports and `docs/roadmap/modernization-roadmap.md` (status block, O-03/O-04/O-07/O-08/O-11/O-15/O-16 rows, FR-101 `think`): housekeeping. `git diff --stat` on `.ai/agents`, `.ai/rules`, `scripts/lib/telemetry.ps1`, `scripts/specify.ps1`, `validate-spec.ps1`, `scan-repository.ps1`, `build-context.ps1`, `AGENTS.md` and `README.md` is empty. The `review-spec.ps1` and `revise-spec.ps1` diffs have 3 hunks each (the `-Profile` parameter, the resolution lines, `-Execution`); none touches the here-string system prompt or the user prompt. |
| **AC-107** model-name scan | **PASS** | Names: `qwen3.5:9b`, `qwen3.6:35b` (from `.ai/config.json`), plus the 3 in `historical-model-names.txt`. `Select-String -SimpleMatch` over the 30 files of `scripts/` (recursive, `-Force`): 0 hits. A wider regex for `qwen`, `deepseek`, `llama`, `mistral`, `gemma` and `phi` finds only unrelated words (for example "OLLAMA" in messages). |
| **AC-108** | **PASS (inspection)** | `benchmark-models.ps1:8` declares `[string[]]$Models` with no default. Lines 54-60: only when `-not $PSBoundParameters.ContainsKey('Models')` it calls `Get-HarnessRegistryModels (Get-HarnessRegistry ...)` and throws if the list is empty. An explicit `-Models` is not touched. The helper (`config.ps1:341-351`) is distinct, ordered and case-insensitive. Not run. |
| **AC-109** | **PASS** | `config.ps1:519` builds `@{ model; system; prompt; stream }` and line 520 adds only `options`; `run-agent.ps1:146-152` is the same. The only `think` hits in non-test scripts: `config.ps1:212-217` (validation), `294` (copy into the profile), `461-474` (copy into the record), and the `<think>` tag stripper (`config.ps1:558`, `run-agent.ps1:214`). No script reads `think` for anything else. |
| **AC-113** `test-registry-callsites.ps1` alone | **PASS** | Exit 0, 52 passed, 0 failed. The AC-113 section has 10 assertions (checker accepts a generated migration; rejects 8 mutations; checks the real `.ai/config.json`). |

## 3. Part B: acceptance criteria

Legend: `R` is `scripts/test-registry.ps1`, `C` is `scripts/test-registry-callsites.ps1`. "Independent" means the expected value does not come from the code under test.

| AC | Verifying assertions | Verdict | Notes |
|---|---|---|---|
| **AC-101** golden resolution | R:172-205 (5 agents x 4 cases x v1/v2, wrapper and `Resolve-HarnessExecution`); expected value `Get-ExpectedModel` R:147-154 reads only the raw v1 JSON (`agentModels.<A>` else `defaultModel`, explicit first, variable second); variable set and restored R:91-100; fixtures differ in format R:207-210. | **PASS** | Independent, not a tautology. "No entry" agent covered (`agent-without-entry`). I also ran my own differential test against the old implementation: 384 combinations, 0 differences except `schemaVersion: 1` (see F-09). |
| **AC-102** conversion | R:218-239 (profiles `legacy:*`, agent assignments, `defaults.profile`, url, timeout, options, stripThinking, no `contextWindow`, 0 warnings, all derived from raw v1); R:241-257 (timeout, options pairs, stripThinking, url equal under v1 and v2, for 5 agents); R:259-270 (minimal v1 gets 600, true, default url, no options, health 15, ratio 0.1); R:272-285 (missing file, empty file, `{}`); R:287-299 (wrapper needs `AI_HARNESS_MODEL`; rule-7 message); R:301-314 (blank agent entry, models differing only by case, blank default). | **PASS** | Options compared as sorted pairs (key order irrelevant), as the spec requires. Pairs are strings, so `16384` and `"16384"` would compare equal (nit, F-14). A whitespace-only file is not tested; my probe shows it loads as an empty registry like the old code. |
| **AC-103** validation, warnings | R:340-357 (one fixture per rule: schema 3, no model, unknown default profile, unknown agent profile, timeout 29, 14401, margin, `num_ctx`, `think` "maybe"; each asserts `registry_invalid: <rule>` through the loader and through the wrapper, so the rule name proves which rule fired); R:359-393 (30 and 14400 accepted, defaults 29 rejected, margin 8999 accepted / 9000 rejected at window 10000, `reservedOutputTokens` 0, `contextWindow` -1, defaults `num_ctx` mismatch, blank model, non-object `profiles`, non-numeric ratio); R:395-400 (v1 `timeoutSec` 10 loads); R:402-410 (`unknown_key:profiles.alpha.colour`, `unknown_key:extraSection`, `non_loopback_ollama_url`); R:412-417 (3 loopback URLs, 0 warnings); R:616-631 (`think`). | **PASS** (spec text) with coverage gaps | Every item of the AC text is exercised. The fixture `invalid-margin` (8192 / 7500) is a good one: it fails only because of the margin, not because of the plain window. Gaps beyond the AC text: F-01 (margin `ceil` and non-default `safetyMarginRatio` untested), F-05 (warning paths, non-integer types, `think` edge values untested). I probed those by hand and the code behaves correctly. |
| **AC-104** invalid config stops the scripts | C:588-596: for `run-agent` (exit 1), `review-spec` (exit 2), `revise-spec` (non-zero): `Assert-Guards`, exit code, a line containing `registry_invalid:`, `Assert-NoRequest` (0 calls recorded, 0 telemetry lines; the logs folder is removed before each case, C:319). | **PASS** | One invalid file only (`schemaVersion` 3). For `revise-spec` the suite's fake host prints the uncaught error and exits 1 (emulation, as the WP-1B report says). I confirmed with a real `powershell -File` process: exit 1, `registry_invalid:` on the error stream, no telemetry file. |
| **AC-105** `-Model` with `-Profile` | Function part R:429-440 (v1 and v2; blank model; blank profile; variable set). Script part C:600-615 (3 scripts x v1/v2: configuration exit code, `invalid_arguments:` line, no request, no telemetry). | **PASS** | The check uses `ContainsKey`, so blank values still count as bound (`config.ps1:377-382`). Scripts with a blank `-Profile` are not tested (nit). |
| **AC-106** selection rules, record | R:461-486 (agent, default, env beats agent, blank variable ignored); R:488-501 (`-Profile` beats the variable; record fields; options `num_ctx=8192;seed=7;temperature=0.2` from raw expectations); R:503-505 (`-Profile` case); R:507-510 (unknown and blank `-Profile`); R:512-525 (`-Model` matching one profile, also upper case); R:527-537 (unregistered: agent parameters plus warning; no-entry agent uses the default profile); R:539-558 (variable unregistered, two profiles match: agent profile, no warning); R:560-577 (blank `-Model`, wrapper on v2); R:579-590 (11 fields); R:592-608. Scripts: C:619-629 (blank `-Model`, 3 scripts x v1/v2, line `Model name cannot be empty.`, no request). | **PASS** | Agent-name case (spec A-103, Edge Cases "Case") has no test (F-05); my probe shows `SPEC-REVIEWER` and `-Profile DEEP` resolve. The fields assertion compares property order (the record's own order): fine, but order-dependent (F-14). |
| **AC-107** no literals | C:742-765 (names from the registry helper and from the data file; lists non-empty; scanner proven on a planted name; `Select-String -SimpleMatch` over every file under `scripts/`, at least 10 files). | **PASS** | I repeated the scan independently: 0 hits in 30 files. The suite scans itself and `test-all.ps1` too. |
| **AC-108** benchmark default | C:771-777 (helper order `fast,deep` and v1 models, expected from raw fixture JSON); C:779-789 (AST: no default value, text contains the helper call and the `ContainsKey('Models')` condition). | **PASS** (inspection) | I read `benchmark-models.ps1:54-60` myself. The benchmark was not run. The AST test checks substrings, not that the branch executes; acceptable for an "inspection" criterion. |
| **AC-109** `think` stored, never sent | Record part R:616-631 (absent, true, false, "default"; boolean types kept; v1 gives "default"). Request bodies C:634-736: the fake reads each real request body and records `hasThink`; asserted `False` for `review-spec`, `revise-spec`, `run-agent` (profile `alpha` has `think: true`) and for the v1 cases. | **PASS** | The body is parsed from the bytes actually sent, so this is stronger than inspection. My grep (section 2) covers the static part. |
| **AC-110** live-suite model | C:795-819: `Resolve-LiveSuiteModel` extracted by AST from `test-all.ps1`, run in-process under v1 and v2; compared with the `Model :` line of a real `review-spec` run in the fake host, and with the raw v1 file. C:821-829 (configuration error becomes a problem, not an exception). Offline sentence: my own `test-all` output has `requires Ollama and model 'qwen3.6:35b' (agent 'spec-reviewer')`. | **PASS** | |
| **AC-111** regression | Section 2: two runs, 0 differing lines, all PASS but the live suite. | **PASS** | Baseline counts compared with reports, not re-run (section 1). |
| **AC-112** footprint | Section 2. | **PASS** | |
| **AC-113** migrated config | C:459-503 (checker: 5 agents against the raw v1 file, expected reviewer options from literals 0.1 and 42, names `deep,fast,review`, assignments, `defaults.profile`, `reservedOutputTokens` 4096/8192/8192, `think`, `stripThinking`, URL); C:506-531 and 835-859 (generated migration accepted; 8 mutations rejected); C:861-871 (runs on the real `.ai/config.json`, which is v2, so no skip). I also read the real file: the profiles, the assignments, `contextWindow` 16384, `timeoutSec` 900 and the `review` options match the spec table. | **PASS** | Two weaknesses: the mutation tests only assert "at least one problem" (F-06) and warnings of the real file are not checked (F-06). |

## 4. Findings

No blocker. Severity: **important** means a gap I would fix soon but that does not stop the tag; **nit** is minor.

### Important

- **F-01 (important, test weakness): the margin formula is only tested at the default ratio and with integer products.**
  - Evidence: R:372-375 uses window 10000, so `ratio x window` is exactly 1000; `invalid-margin.json` (8192 / 7500) gives 819.2, but both `Ceiling` and `Floor` reject it. No case uses a `safetyMarginRatio` other than the default or "lots" (R:391).
  - Failure scenario: replacing `[math]::Ceiling` with `Floor` or `Round`, or hardcoding 0.10 instead of reading `defaults.safetyMarginRatio` (`config.ps1:148`, `191`), still passes every suite.
  - My probes show the current code is right (ratio 0.9 rejects 200 of 1000; ratio 0.5 accepts 499 of 1000; negative ratio rejected). Phase 2 consumes this value, so add one fixture with a non-default ratio and a fractional product.
- **F-02 (important, spec gap, hardening): `ollama.healthTimeoutSec` (and a blank `ollama.url`) are not validated.**
  - Evidence: `config.ps1:315` accepts any value. My probes load `0`, `-5` and `"abc"` without error; `url ""` loads with only a `non_loopback_ollama_url` warning.
  - Real run: `review-spec.ps1` with `healthTimeoutSec: "abc"` exits with code 1 (FR-106 says 2 for a configuration error), prints a raw PowerShell cast error from `Test-HarnessModelAvailable` (`config.ps1:574`) and no `registry_invalid:`. It fails before any request.
  - `0` means no timeout in `Invoke-RestMethod` on Windows PowerShell 5.1 (documented behavior, not executed here), so the reachability check could hang. A negative value is turned into "Ollama is not reachable" (`run-agent.ps1:85-89`, `config.ps1:577-583`).
  - FR-103 does not list this field, so it is not a violation. Recommended: add a rule (integer, for example 1 to 600) in a later spec revision.

### Nit

- **F-03 (nit): `Test-OllamaPrecondition` now swallows configuration read errors** (confirmed, `test-all.ps1:617-622`: `catch { }`). Before, it returned "could not read .ai\config.json: ...". Now it silently probes the default `http://localhost:11434`, even if the file names another URL. Practical effect today is nil: the only live entry uses `ModelAgent`, and `Resolve-LiveSuiteModel` (called first, lines 698-709) already turns the same error into a FAIL with the `registry_invalid:` text. It would matter for a future live entry with a fixed `Model`. Only the live path (`-IncludeLive`) is affected.
- **F-04 (nit): `-Profile` shadows the automatic variable `$PROFILE`** (confirmed: `run-agent.ps1:7`, `review-spec.ps1:8`, `revise-spec.ps1:9`, and the parameter of `Resolve-HarnessExecution`, `config.ps1:374`). Harmless: no script reads `$PROFILE` (grep, section 2) and PowerShell resolves script scope first. Local variables named `$profile` in the suites (R:225, 360; C:478) do the same. It would only matter if someone later needs the user profile path inside these scripts.
- **F-05 (nit, test gaps, behavior verified by my probes):**
  - agent-name case is not tested;
  - unknown-key warnings are tested for 2 paths only (not `defaults.*`, `ollama.*`, `agents.*.*`);
  - one non-loopback URL;
  - non-integer `timeoutSec` (30.5, "900"), `"Default"` and `null` for `think`, and a numeric `model` are not tested;
  - no script-level test of an unknown or blank `-Profile`;
  - no test that registry warnings (not only `unregistered_model_override`) are never printed by a script (C:678);
  - `revise-spec` is not asserted for options or health timeout under v2 (only `run-agent` and `review-spec` are);
  - NFR-103 effective `timeoutSec`, `options` and URL under `-Model` or `AI_HARNESS_MODEL` are not compared with v1 (only the model is); they are equal by construction because legacy profiles only carry `model`.
- **F-06 (nit): AC-113 checker oracle.** The 8 mutation tests assert only `$problems.Count -ge 1` (C:857), so a mutation could be rejected for the wrong reason (for example a load failure). The checker also ignores `warnings` (a typo'd key in the real file would pass) and extra agent entries.
- **F-07 (nit, spec deviation, documented and tested): for `-Model` or `AI_HARNESS_MODEL` with an agent that has no entry, parameters come from `defaults.profile`** (`config.ps1:426-431`; asserted at R:535-536). FR-104 rule 2 mentions only "agent A's profile" and then "defaults, `parametersFrom` empty". The behavior matches the Edge Case "an agent with no registry entry resolves to the default profile", and the WP-1A report lists it as an assumption. The spec text should say so.
- **F-08 (nit, documentation): the spec header (line 4) still says "Draft ... Not approved and not implemented".** Its "Affected Files" row for `test-registry-callsites.ps1` omits AC-106 and AC-109, which the suite covers (both implementers flagged this; not fixed). Roadmap O-16 still says `deep` is 6144 while the spec (OD-112) and the migrated file use 8192.
- **F-09 (nit, observation): an explicit `"schemaVersion": 1` (or `null`) is not "v1".** The loader treats any file that has the key as v2 and rejects it with `registry_invalid: schemaVersion` (`config.ps1:271`; my differential test). This is consistent with FR-103 ("any other value is invalid") and no current file has the key, but it is worth one sentence in the spec.
- **F-10 (nit): v1 `"options": {}` is no longer sent.** The old code sent `"options":{}` (an empty object is truthy); now `run-agent.ps1:152` and `config.ps1:520` omit an empty object. Ollama treats both the same; the WP-1A report records the decision.
- **F-11 (nit): `Resolve-HarnessExecution` expects a normalized registry** (FR-104 says so) and has no guard: a raw configuration object passed by mistake would fail with an obscure error instead of a clear one. The wrapper and all call sites normalize correctly.
- **F-12 (nit, guard 4 coverage):** the static scan (C:276-292) catches `Invoke-WebRequest`, `System.Net.WebClient`, `HttpWebRequest`, `HttpClient`, the module-qualified cmdlet, and the words `irm`, `iwr`, `curl` (also `curl.exe`) and `wget`. It would miss `Net.WebClient` without `System.`, `System.Net.WebRequest`, `TcpClient` and `Start-BitsTransfer`. See section 5 for why this is low risk.
- **F-13 (nit): `ollama.url` loopback detection is narrow by design** (`localhost`, `127.0.0.1`, `::1`): `127.0.0.2`, `localhost.` and `0.0.0.0` warn as non-loopback (probe). Matches FR-103.
- **F-14 (nit): some assertions depend on formatting I do not control:** options pairs are strings (type differences hidden); the record-fields test compares property order; `Assert-Equal` compares through string conversion. All are the harness's own output, none is PowerShell or .NET message text.

## 5. Guards of the child-process suite (point 4)

- **Can any path reach `http://localhost:11434`?** Not in the call-site suite, on my reading:
  - Guard 1 (C:136-151, startup proof C:548-575): the temporary config must name exactly `http://127.0.0.1:9`; the proof rejects a missing file, invalid JSON, `localhost:11434` in v1 and v2, another URL, and a v2 file with only the v1 key.
  - Guard 2 (C:247-250): the child exits 97 unless `Invoke-RestMethod` resolves to the fake function; `Assert-Guards` (C:372-379) also requires the "fake active" line in every case.
  - Guard 3 (C:207-211): the fake refuses and records any URI not starting with `http://127.0.0.1:9/`; a script that fell back to the default URL would produce a recorded violation and fail `Assert-Guards`. Even with the fake absent, port 9 is not Ollama.
  - Guard 4 (C:276-292): static scan of the copied scripts and `lib\*.ps1`.
  - The parent process only reads files, resolves models in-process and parses scripts; it sends nothing.
- **Aliases and `curl.exe`:** aliases of `Invoke-RestMethod` would resolve through the same command lookup, where a function wins over a cmdlet; the static scan also rejects the alias words and `curl.exe` textually. The hole is the list in F-12, which only matters if someone adds new network code to the scripts; it is a regression net, not a security boundary.
- **Other `localhost:11434` uses:** `config.ps1:314` (default URL, never reachable in the suite because guard 1 requires a URL) and `test-all.ps1:612` (live path only, not copied into the temporary harness).

## 6. Claims of the implementers' reports checked

All claims I could test held: the suite counts (67, 52, 23, 15, 11, 5, 26, 17, 54), AC-107 over the git-ignored backups (30 files scanned), the offline SKIPPED detail naming the model, the `-Profile nope` rejection, and the honest statement that `revise-spec` output is emulated by the fake host. Differences found: the tripwire count is 237 here versus 236 in the migration report (probably a file added after that report; not investigated); the spec still says "Draft" (F-08).

## 7. NOT VERIFIED

- Any live behavior: `test-all.ps1 -IncludeLive`, `test-spec-integration.ps1`, any real call to Ollama, the migrated profiles on the real models.
- Whether `temperature` 0.1 and `seed` 42 actually stabilize the reviewer's verdicts (RK-105): only the stored configuration and the request options (checked with a fake) are verified.
- `benchmark-models.ps1`: never run, so its output with the new two-model default is untested. When `-Model` matches both `deep` and `review`, parameters come from the agent's profile (OD-109); they are equal today, so results would not differ.
- The `-TimeoutSec 0` behavior in F-02 (documented, not executed).
- The Phase 0 suites at `5ffc33f` were not re-run for a before/after comparison (section 1).
- A configuration edited by hand for a non-default Ollama host (warning only) and any locale other than the one of this machine.

## 8. Verdict

**Ready to tag `phase1-done`: YES.** Blockers: none.

Basis: the offline regression is green and stable over two runs; all 13 acceptance criteria are verified by assertions I read, with independent expected values where the spec requires them (AC-101, AC-113); my differential test found no difference from the old resolution beyond the one spec-consistent case (F-09); the migration keeps every model, timeout, URL and option except the intended `spec-reviewer` change; the footprint is as specified.

Before or soon after tagging, I recommend: F-01 (one more margin fixture), F-02 (validate `healthTimeoutSec` in a spec revision), F-08 (spec header and roadmap wording). The live items in section 7 stay open as stated in the spec's Execution Order.
