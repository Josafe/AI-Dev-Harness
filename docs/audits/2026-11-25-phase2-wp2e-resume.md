# Phase 2 WP-2E: live validation, resumed after a machine reboot

**Branch:** `feat/phase2-wp2e-live`, created from `origin/feat/phase2-wp2e` (it holds the earlier partial report `docs/audits/2026-11-25-phase2-wp2e.md` and its CSV, both untouched). Added by this run: this file and `docs/audits/data/2026-11-25-wp2e-resume/telemetry-rows.csv`. No source, test, spec, prompt or `.ai/config.json` file was modified (`git status` was empty before the report was written). Nothing was pushed, reset, cleaned, rebased, tagged or amended.
**Host:** Windows PowerShell 5.1, es-ES, Ollama 0.40.13 (`library=CUDA`, compute 12.0, `cuda_v13`), RTX 5070 Ti Laptop 12 GB, `qwen3.5:9b` and `qwen3.6:35b`. Live calls 2026-11-25 15:16 to 15:55 host time (UTC+1), about 39 minutes of the 120 allowed.
**How the calls were made:** every call went through the real scripts (`review-spec.ps1`, `revise-spec.ps1`, `run-agent.ps1`), each in its own child `powershell.exe -File`, started with `&`, and the exit code is `$LASTEXITCODE` (anomaly A1 of the earlier run is fixed: every exit code below is measured). The scripts ran from a scratch copy of the harness root (`%TEMP%\wp2e-live`, not committed; 14 files, SHA-256 identical to the committed ones). Variants (warm-up on, `think`, a 32,768 window) are TEMP copies of that root with one line of `.ai/config.json` changed (shown in section 8). Strictly sequential, one call at a time. Before every call the runner recorded `ollama ps` (A2) and the free VRAM; between a model change it ran `ollama stop <previous>` and waited 3 s.

## 1. Verdict

| Item | Result |
|---|---|
| Offline `scripts\test-all.ps1` (Step 0) | 19 discovered, 18 executed, **18 PASS, 0 FAIL**, 1 skipped (`test-spec-integration.ps1`), `STATUS: PASS WITH SKIPS`, 283 s |
| **AC-205** (one real call per agent returns the expected format) | **PASSES on this host.** 4 of 4 agents: `spec` (valid, `validate-spec.ps1` exit 0), `spec-reviewer` (valid `## Status`: FAIL on the invalid fixture, PASS on the valid one), `spec-reviser` (output passes `validate-spec.ps1`), `developer` (all contract headings present). `prompt_eval_count`, `done_reason` and `thinking_chars` were recorded in every row. The `charsPerToken` ratio, the overflow behaviour and the warm-up experiment are reported below. |
| Live calls | 34 script calls, 36 generation requests (2 are warm-up requests), of 60 allowed. 33 calls succeeded; the one error is the deliberate 60 KB overflow call (`format_invalid`, exit 2, not an HTTP error). 0 `http_5xx`, 0 `transport_reset`, 0 retries (`attempts` is 1 in every row), 0 CUDA errors in `server.log` since the boot. |
| Stop rule | Never triggered. |
| Intermittent CUDA fault | **Not reproduced**: 8 model loads of mine (7 of `qwen3.6:35b`, 1 of `qwen3.5:9b`) plus 18 loads that the log shows before my first call, 0 faults (section 9). |

Main findings, each with its section:

1. **Ollama truncates an overflowing prompt silently** (it does not error): a prompt of 19,142 tokens was cut to 8,194, the reviewer lost its instructions and answered without `## Status`. `possible_prompt_truncation` did fire, but it also fires on two prompts that were NOT truncated (8,573 and 9,237 tokens). Section 5.
2. **`charsPerToken` 3.5 over-estimates every one of the 16 distinct prompts measured** (real 3.93 to 5.43 characters per token). The shipped `budget_exceeded` warning of the reviewer and the reviser is a **false positive** at fixture size (estimate 7,552 and 8,412 against real 4,986 and 5,649; 6,553 available). Section 4.
3. **The reviewer on `review` (35b, seed 42) gave byte-identical output in every repeated run of the same state** (5 of 5 on the invalid fixture, 3 of 3 on the valid one in the stable session), but the valid-fixture output after a fresh server process (4 runs) differs from the one before it (same verdict PASS, 2,260 against 1,699 tokens). On `fast` (9b) the reviewer is **not reliable**: the invalid fixture got FAIL once and PASS twice. Section 6.
4. **`think: false` and `think: true` are accepted** by both models (no HTTP 400); `false` removes all reasoning (0 thinking characters) and cut the reviewer from 4,296 to 1,398 generated tokens. Section 7.
5. **Warm-up (`warmup: true`) does not shorten the total** (99.9 s against 101.2 s); it only moves the 43 s model load into its own request. Section 8.

## 2. Preflight (before any call, at 15:12 local)

| Check | Value |
|---|---|
| System boot (`LastBootUpTime`) | 2026-11-25 14:52:06 (uptime 21 min at the preflight, 24 min at the first call, 63 min at the end) |
| `ollama` processes | 2: the server `ollama` (PID 19680, started 14:53:52) and the tray `ollama app` (PID 17908). One server process. |
| `ollama --version` | 0.40.13 |
| `nvidia-smi` memory | total 12,227 MiB, used 346, **free 11,599 MiB** (11.3 GiB, limit 10 GiB). No compute process listed. Driver 621.01. |
| `server.log` last `inference compute` line | `library=CUDA compute=12.0 name=CUDA0 description="NVIDIA GeForce RTX 5070 Ti Laptop GPU" libdirs=ollama,cuda_v13 driver=13.5 ... total="11.9 GiB" available="10.8 GiB"` (14:54:11) |
| `ollama ps` | empty |
| `OLLAMA_*` environment variables | none |
| Installed | `qwen3.6:35b` (22 GB), `qwen3.5:9b` (6.6 GB), three older models (not used) |

All conditions held. VRAM free in the session: 11,596 MiB before the first call, 11,778 to 11,924 MiB after each `ollama stop`, 929 to 1,257 MiB while `qwen3.6:35b` was resident (it runs 58 % CPU / 42 % GPU at 16,384 context, `ollama ps`), 4,992 MiB while `qwen3.5:9b` was resident.

## 3. Measurement 1: AC-205, one real call per agent

Inputs: the task text "Create a specification for a simple user registration feature with email and password."; the reviewer and reviser read `tests/fixtures/semantic-invalid-spec.md` (712 bytes, invalid) and `minimal-valid-spec.md` (valid); the reviser got the reviewer's actual output for the invalid fixture; the developer got a 826-character task (a small PowerShell function). Profiles are the shipped ones (`fast` for `spec`, `review` for `spec-reviewer`, `deep` for `spec-reviser` and `developer`).

| Field | `spec` | `spec-reviewer` (invalid) | `spec-reviewer` (valid) | `spec-reviser` | `developer` |
|---|---|---|---|---|---|
| Label | `spec-1` | `rev-invalid-1` | `rev-valid-1` | `reviser-1` | `dev-small` |
| Model (resident before) | `qwen3.5:9b` (none) | `qwen3.6:35b` (none, cold) | `qwen3.6:35b` (35b) | `qwen3.6:35b` (35b) | `qwen3.6:35b` (35b) |
| Script exit code | 0 | 1 (FAIL verdict) | 0 (PASS verdict) | 0 | 0 |
| `status` | success | success | success | success | success |
| `duration_ms` | 21,820 | 136,431 | 33,192 | 41,504 | 50,165 |
| `attempts` | 1 | 1 | 1 | 1 | 1 |
| `eval_count` | 402 | 4,296 | 1,699 | 1,779 | 2,447 |
| `prompt_eval_count` | 5,384 | 4,986 | 4,971 | 5,649 | 3,116 |
| `thinking_chars` | 1,359 | 15,895 | 6,513 | 7,173 | 8,161 |
| `done_reason` | stop | stop | stop | stop | stop |
| `warnings` | (none) | `budget_exceeded` | `budget_exceeded` | `budget_exceeded` | (none) |
| `http_status` / `error_category` | blank / blank | blank / blank | blank / blank | blank / blank | blank / blank |
| `prompt_chars` / `est_prompt_tokens` | 29,247 / 8,357 | 26,431 / 7,552 | 26,386 / 7,539 | 29,441 / 8,412 | 14,776 / 4,222 |
| `load_duration` (ms) | 13,168 | 44,528 | 10 | 8 | 8 |
| Format valid? | **Yes**: `validate-spec.ps1` `STATUS: PASS`, exit 0 | **Yes**: `## Status` `FAIL`, 3 findings (Edge Cases, Dependencies, NFR-001) | **Yes**: `## Status` `PASS`, 0 findings | **Yes**: output passes `validate-spec.ps1` (exit 0) | **Yes** (checked by reading, no validator exists): `SUMMARY`, `FILE`, `CHANGES TO EXISTING FILES`, `ASSUMPTIONS`, `RISKS`, `OPEN QUESTIONS`, the headings of `.ai/agents/developer.md` |

Verdict content (OBSERVATION, not a quality evaluation): the reviewer marked the invalid fixture FAIL and the valid one PASS, as the fixtures intend (`test-spec-integration.ps1` uses the same pair). The generated specification carries an entry `**Source:** USER` and `Context: None`.

Raw rows of all 34 calls: `docs/audits/data/2026-11-25-wp2e-resume/telemetry-rows.csv` (every telemetry column, plus label, exit code, wall seconds, resident models before the call, free VRAM before the call).

## 4. Measurement 2: `charsPerToken` calibration

**The prompt cache (A3) does not distort `prompt_eval_count` in this Ollama.** In `server.log` the second reviewer call had `cached n_tokens = 4474`, and the runner evaluated only 497 tokens (`prompt eval time = 676.58 ms / 497 tokens`), yet the response said `prompt_eval_count` 4,971, the full prompt. The repeated stability runs (same prompt) show the same: 4,986 in all five, while the slot evaluated 4 to 512 tokens (`prompt_eval_duration` fell from 7,246 ms to 111 ms). So the count is the real token count of the prompt. What the cache does distort is `prompt_eval_duration` (do not derive a prompt speed from a cached call). For the calibration I still gave every calibration call a distinct prefix, to keep the prompt-processing times clean: the runner prepended one HTML comment line (about 30 characters) to the scratch copy of `AGENTS.md`, different in every call; `prompt_chars` includes it. The same 4,986 tokens for the same prompt on both models (`rev-invalid-1` on 35b and `revfast-invalid-1` on 9b) shows that both use the same tokenizer.

### 4.1 Every distinct prompt (16 with a real count; whole-prompt ratio = `prompt_chars` / `prompt_eval_count`)

| Label | Content | `prompt_chars` | `prompt_eval_count` | chars/token | estimate at 3.5 | estimate / real |
|---|---|---|---|---|---|---|
| `rev-invalid-1` | reviewer, 0.7 KB spec (fixture) | 26,431 | 4,986 | 5.30 | 7,552 | 1.51 |
| `rev-valid-1` | reviewer, 0.7 KB spec (fixture) | 26,386 | 4,971 | 5.31 | 7,539 | 1.52 |
| `cal-rev-2k` | reviewer, 2 KB English spec | 27,786 | 5,279 | 5.26 | 7,939 | 1.50 |
| `cal-rev-8k` | reviewer, 8 KB English spec | 33,939 | 6,737 | 5.04 | 9,697 | 1.44 |
| `cal-rev-16k` | reviewer, 16 KB English spec | 41,770 | 8,573 | 4.87 | 11,935 | 1.39 |
| `reviser-1` | reviser, 0.7 KB spec + 4.4 KB review | 29,441 | 5,649 | 5.21 | 8,412 | 1.49 |
| `cal-reviser-2k` | reviser, 2 KB spec, same review | 30,800 | 5,943 | 5.18 | 8,800 | 1.48 |
| `cal-reviser-8k` | reviser, 8 KB spec | 36,953 | 7,401 | 4.99 | 10,558 | 1.43 |
| `cal-reviser-16k` | reviser, 16 KB spec | 44,784 | 9,237 | 4.85 | 12,796 | 1.39 |
| `spec-1` | `spec` agent (9b), one-sentence task | 29,247 | 5,384 | 5.43 | 8,357 | 1.55 |
| `dev-small` | developer, 826-char English task | 14,776 | 3,116 | 4.74 | 4,222 | 1.35 |
| `cal-dev-task12k` | developer, 11.9 KB English task | 25,899 | 5,638 | 4.59 | 7,400 | 1.31 |
| `cal-dev-ctx-en` | developer + 8 KB English context | 22,123 | 4,773 | 4.64 | 6,321 | 1.32 |
| `cal-dev-ctx-code` | developer + 8 KB real PowerShell code | 22,125 | 4,932 | 4.49 | 6,322 | 1.28 |
| `cal-dev-ctx-es` | developer + 8 KB Spanish text | 22,123 | 5,196 | 4.26 | 6,321 | 1.22 |
| `cal-dev-ctx-ca` | developer + 8 KB Catalan text | 22,123 | 5,627 | **3.93** | 6,321 | **1.12** |

Calls with the same prompt are not repeated here (the 8 stability runs, the 4 warm-up runs and the `think` variants add rows with identical prompts and identical counts). The three `spec` rows have 5,384 tokens (5,386 with `think: false`: Ollama adds 2 tokens to the prompt when `think` is false). The synthetic specifications and the Spanish and Catalan texts were generated by scratch scripts from a pool of 16 sentences each (with a running note number), so they are repetitive; the English prose is the same kind. The code is the unedited first 8,000 characters of `scripts/lib/agent-exec.ps1`.

### 4.2 Mean, min and max per content type (whole-prompt ratio)

| Content type | Prompts | Mean | Min | Max |
|---|---|---|---|---|
| Reviewer and reviser prompts (agent files + English specification 0.7 to 16 KB) | 9 | 5.11 | 4.85 | 5.31 |
| `spec` agent prompt (9b) | 1 | 5.43 | 5.43 | 5.43 |
| Developer, English task or context | 3 | 4.66 | 4.59 | 4.74 |
| Developer + PowerShell code context | 1 | 4.49 | 4.49 | 4.49 |
| Developer + Spanish context | 1 | 4.26 | 4.26 | 4.26 |
| Developer + Catalan context | 1 | 3.93 | 3.93 | 3.93 |
| All 16 distinct prompts | 16 | 4.88 | 3.93 | 5.43 |

The whole-prompt ratio mixes the English instructions (agent files, contract, `AGENTS.md`: 13 to 25 KB, about 5.2 to 5.3 chars/token) with the content under test. The **marginal ratio** isolates the content: (extra characters) / (extra tokens) against a base prompt of the same agent:

| Content added (against base) | Extra chars | Extra tokens | Marginal chars/token |
|---|---|---|---|
| Spec text, reviewer, +1.4 KB / +7.5 KB / +15.3 KB | 1,355 / 7,508 / 15,339 | 293 / 1,751 / 3,587 | 4.63 / 4.29 / 4.28 |
| Spec text, reviser, +1.4 / +7.5 / +15.3 KB | 1,359 / 7,512 / 15,343 | 294 / 1,752 / 3,588 | 4.62 / 4.29 / 4.28 |
| English task text 11.1 KB | 11,123 | 2,522 | 4.41 |
| English context 7.3 KB | 7,347 | 1,657 | 4.43 |
| PowerShell code 7.3 KB | 7,349 | 1,816 | 4.05 |
| Spanish text 7.3 KB | 7,347 | 2,080 | 3.53 |
| Catalan text 7.3 KB | 7,347 | 2,511 | **2.93** |

(Bases: `rev-invalid-1`, `reviser-1`, `dev-small`.)

### 4.3 Do the shipped `budget_exceeded` warnings match reality?

| Call | `est_prompt_tokens` (3.5) | Real `prompt_eval_count` | Available (C - R - S = 16,384 - 8,192 - 1,639) | Warning in the row | Real fit? (real + R + S <= C) |
|---|---|---|---|---|---|
| Reviewer, fixture-size spec | 7,552 | 4,986 | 6,553 | `budget_exceeded` | **Fits** (4,986 + 8,192 + 1,639 = 14,817) |
| Reviser, fixture-size spec | 8,412 | 5,649 | 6,553 | `budget_exceeded` | **Fits** (15,480) |
| `spec` agent (`fast`, available 10,649) | 8,357 | 5,384 | 10,649 | none | fits |
| Developer, 826-char task | 4,222 | 3,116 | 6,553 | none | fits |
| Reviewer, 8 KB spec | 9,697 | 6,737 | 6,553 | `budget_exceeded` | does not fit by the formula (16,568); the call worked (output 2,142 tokens) |
| Reviewer, 16 KB spec | 11,935 | 8,573 | 6,553 | `budget_exceeded;possible_prompt_truncation` | does not fit by the formula; the call worked and `truncated = 0` |

**The shipped warning for the reviewer and the reviser is a false positive at fixture size**: the estimate is 1.5 times the real count and the real prompt fits with 1,567 and 904 tokens to spare after R and S. By the formula the warning becomes true when the real count exceeds 6,553: between the 2 KB specification (5,279) and the 8 KB one (6,737) with R = 8,192 kept, and then only by the formula: the largest answers measured with normal inputs are 4,296 tokens (reviewer, thinking included, `eval_count`), so R = 8,192 reserves almost twice what was ever generated.

### 4.4 Proposed value and safety argument

**Proposal: `charsPerToken` 4.0.** Arguments, all from the tables:

1. Every one of the 16 distinct prompts has a whole-prompt ratio of at least 3.93. At 4.0 the estimate is below the real count only for the Catalan prompt (5,531 against 5,627, 1.7 % low); at 3.5 no prompt is under-estimated (smallest margin 1.12).
2. The under-estimate at 4.0 is bounded by the safety margin. A prompt that is entirely Catalan would have a marginal ratio of about 2.93; for a Catalan specification of 16 KB the error would be 16,000 / 2.93 - 16,000 / 4.0 = 1,460 tokens, below the margin S = 1,639 (10 % of 16,384). A prompt that is mostly Catalan or Spanish is outside what the harness has been used for (English specifications), and a larger one would be caught by the `possible_prompt_truncation` signal and the server's own handling (section 5).
3. The English content the harness sends today has whole-prompt ratios of 4.5 to 5.4. At 4.0 the estimate is 1.1 to 1.4 times the real count, still on the safe side.
4. Evidence is limited: 16 prompts, two models with one tokenizer, synthetic Spanish and Catalan, a single sample per non-English type. If the owner prefers zero risk of under-estimating, **keep 3.5**: it is safe for every measured prompt and costs only false warnings. Both options are given; 4.0 is the one the data supports for the English workflow.

## 5. Measurement 3: overflow behaviour (A-204)

One reviewer call (`review`, 35b, `num_ctx` 16,384) with a 60,210-byte specification (a valid-format synthetic spec, passes `validate-spec.ps1`): `prompt_chars` 85,957, estimate 24,560 tokens.

| Field | Value |
|---|---|
| Script exit code | 2 |
| `status` / `error_category` | error / `format_invalid` (the reviewer did not return a `## Status`) |
| `prompt_eval_count` | **8,194** |
| `eval_count` / `thinking_chars` / `done_reason` | 5,108 / 15,034 / `stop` |
| `warnings` | `budget_exceeded;possible_prompt_truncation` |
| `http_status` | none (HTTP 200) |
| `duration_ms` | 116,281 (no retry, `attempts` 1) |
| `server.log`, before the request | `level=WARN source=llama_server.go:344 msg="truncating input prompt" limit=8194 prompt=19142 keep=4 new=8194` |
| `server.log`, slot lines | `new prompt, n_ctx_slot = 16384, n_keep = 4, task.n_tokens = 8194` and, at the end, `stop processing: n_tokens = 13301, truncated = 0` |

**Answers (FACT, from the rows and log above):**

- **Ollama truncates; it does not return an error.** The prompt had 19,142 tokens; the server cut it to 8,194 (`keep=4`: the first 4 tokens are kept; that the other 8,190 come from the end of the prompt is my reading of the log fields, not stated by it). The call answered HTTP 200.
- The returned `prompt_eval_count` is the **truncated** count (8,194), not 19,142. The slot flag `truncated = 0` at the end of the request does not report this truncation, so it cannot be used to detect it; the line `truncating input prompt` is the only trace.
- **`possible_prompt_truncation` fired** here (8,194 >= C - R = 8,192), correctly. The consequence is visible: the answer had no `## Status`. Most likely the instructions at the start of the prompt were cut (inference from `keep=4`; the dropped text was not inspected).
- **The warning has false positives.** With the shipped `review`/`deep` profiles the threshold is C - R = 8,192, which is half the context. Two prompts above it were **not truncated** (`truncating input prompt` absent, `truncated = 0`): the 16 KB reviewer (8,573 tokens) and the 16 KB reviser (9,237 tokens), and both returned valid results. So the warning means "above C - R", not "truncated".
- The limit of 8,194 equals half of `n_ctx` plus 2. The smallest prompt that gets truncated lies between 9,237 (not truncated) and 19,142 (truncated); I did not find the exact threshold (NOT determined).
- The console of the script printed only the `budget_exceeded` line; `possible_prompt_truncation` is in the telemetry row but the three scripts do not print it. The user sees `format_invalid` and no hint that the prompt was cut.

**Extra experiment (not requested; 1 call): the same 60 KB specification with `review` `contextWindow` 32,768** (TEMP config): the 35b model was reloaded (`load_duration` 45.2 s, `n_ctx_slot = 32768`), `prompt_eval_count` **19,142** (the whole prompt), no truncation line, `truncated = 0`, a valid `## Status` (FAIL, exit 1), 3,370 tokens generated at 46.7 tokens/s, prompt processing of 19,142 tokens in 24.2 s. `warnings`: `budget_exceeded` only (C - R = 24,576 is above 19,142, so `possible_prompt_truncation` correctly did not fire). On this card the KV buffer grew from 320 to 640 MiB, the model buffer on the GPU dropped from 8,194 to 7,695 MiB (Ollama moved a little more of the model to the CPU: 61 % CPU / 39 % GPU instead of 58 / 42), and 1,375 MiB of VRAM remained free (1,257 MiB at 16,384). One call, one sample.

## 6. Measurement 5: reviewer stability (RK-105)

Profile `review` (temperature 0.1, seed 42), 35b, same prompt each time (scripts run from the scratch root without a cache buster, so runs 2 to 5 reused the prompt cache; `prompt_eval_count` stayed 4,986):

| Group | Runs | Verdicts | `## Status` valid | `thinking_chars` | `eval_count` | Output SHA-256 (first 12) |
|---|---|---|---|---|---|---|
| `review`, invalid fixture | 5 (`rev-invalid-1..5`) | **5 FAIL** (exit 1 each) | 5 of 5 | 15,895 in all 5 (spread 0) | 4,296 in all 5 | `FF7D67510401` in all 5 (**byte-identical**, 4,422 bytes) |
| `review`, valid fixture | 3 (`rev-valid-1..3`) | **3 PASS** (exit 0 each) | 3 of 3 | 6,513 in all (spread 0) | 1,699 in all | `CB580F230258` in all 3 (**byte-identical**, 1,150 bytes) |
| `review`, valid fixture, fresh server process each time (the 4 `warm-*` runs of section 8, same prompt, same seed) | 4 | **4 PASS** (exit 0 each) | 4 of 4 | 9,122 in all 4 | 2,260 in all 4 | `AEC89498A4C3` in all 4 (byte-identical to each other, 1,390 bytes; **different from `CB580F230258`**) |
| `-Profile fast` (9b, temperature 0.2, no seed), invalid fixture | 3 (`revfast-invalid-1..3`) | **1 FAIL, 2 PASS** (exit 1, 0, 0) | 3 of 3 | 8,232 / 4,106 / 5,554 | 2,162 / 1,227 / 1,384 | three different outputs |

Findings:

- Invalid fixture: the run with a cold model (run 1, empty cache) and the runs with the prompt cache (runs 2 to 5, only 4 to 512 tokens evaluated) gave the **same bytes**. Valid fixture: runs 1 to 3 in the stable session are identical, and the four runs after a fresh server process (empty cache; the model was reloaded after `ollama stop`) are identical to each other, **but not to the first three**: same prompt, same seed, same verdict (PASS), different text (1,390 against 1,150 bytes, 2,260 against 1,699 tokens, 9,122 against 6,513 thinking characters). I did not find why (NOT determined; the first valid run reused a cached prefix of 4,474 tokens from the invalid prompt, the fresh runs reused nothing). So the seed gives the same bytes in repeated runs of the same state of the server, **not** a guarantee across reloads; the verdict was the same in all 12 runs of the `review` profile on the two fixtures (5 FAIL, 7 PASS).
- The `fast` profile as a reviewer **failed the fixture 2 times out of 3**: it called the specification PASS, with 3 and 1 findings, all of severity INFO and category COVERAGE (the one FAIL run had 3 findings, 1 BLOCKING). `review` found 3 BLOCKING findings in all 5 runs. One sample of 3; no seed on `fast`. It supports the choice of `review` (35b) for the reviewer (RK-105) and does not support using `-Profile fast` for it.
- `think: false` on `review` (section 7) gave FAIL as well.

## 7. Measurement 6: `think` (FR-214, A-205)

TEMP config copies; one real call each. `think_sent` in the telemetry shows what the request carried.

| Case | `think_sent` | Accepted? | `eval_count` | `thinking_chars` | `duration_ms` (load) | Format valid? | Exit |
|---|---|---|---|---|---|---|---|
| `spec`, `fast`, default (`spec-1`) | `omitted` | yes | 402 | 1,359 | 21,820 (13,168 load) | yes, `validate-spec` PASS | 0 |
| `spec`, `fast`, `think: false` | `false` | **yes, no 400** | 130 | **0** | 2,703 (9 ms load) | yes, `validate-spec` PASS | 0 |
| `spec`, `fast`, `think: true` | `true` | **yes, no 400** | 440 | 1,342 | 7,102 (9 ms load) | yes, `validate-spec` PASS | 0 |
| `spec-reviewer`, `review`, default (`rev-invalid-1`) | `omitted` | yes | 4,296 | 15,895 | 136,431 (44,528 load) | yes, FAIL | 1 |
| `spec-reviewer`, `review`, `think: false` | `false` | **yes, no 400** | 1,398 | **0** | 84,926 (46,634 load) | yes, `## Status` FAIL | 1 |

Observations (not a quality evaluation; one sample per case, `fast` has no seed):

- Both models accept `think: true` and `think: false`: no HTTP 400, so the first half of A-205 holds for the two models used. The second half (an HTTP 4xx for `think` on a model that does not support it) was **not tested** (no unsupporting model was called).
- `think: false` removes the hidden reasoning (0 thinking characters) and the generation time: 130 tokens against 402 for `spec` (2.0 s of generation against 6.7 s), 1,398 against 4,296 for the reviewer. `think: true` on `fast` is the same as the default (1,342 against 1,359 thinking characters): the models already think by default.
- Content: the `think: false` specification is structurally the same as the default. The `think: true` specification added a second requirement (`FR-002`, "store the registered user information", marked `**Source:** USER`) and a second criterion that the default and the `false` runs do not have: an observation of an invented requirement in one sample, and a reminder that `fast` is not seeded. The `think: false` reviewer reported 5 findings (the default: 3) with the same verdict. I did not judge which review is better. The 2026-11-19 validation found specifications worse with thinking off; this run neither confirms nor refutes it (OQ-209 stands).

## 8. Measurement 4: warm-up (FR-213)

Reviewer on the valid fixture (`review`, 35b), each run after `ollama stop qwen3.6:35b` (resident list empty, free VRAM 11,924 MiB), a new script process each time. Shipped `ollama.warmup: false` against a TEMP config with `"warmup": true` (the only line changed).

| Run | `warmup` | Script wall s | `duration_ms` | Warm-up request (GIN) | Generate request (GIN) | `load_duration` of the generate response | Prompt processing | Generation (`eval_duration`) | `attempts` |
|---|---|---|---|---|---|---|---|---|---|
| `warm-off-1` | false | 105.4 | 101,851 | none | 100 s (`1m40s`) | 44,864 ms | 7,463 ms | 49.3 s | 1 |
| `warm-off-2` | false | 104.1 | 100,534 | none | 100 s | 43,297 ms | 7,578 ms | 49.4 s | 1 |
| `warm-on-1` | true | 104.0 | 100,423 | **43.25 s** | **57 s** | 12 ms | 7,568 ms | 49.3 s | 1 |
| `warm-on-2` | true | 102.8 | 99,277 | **42.97 s** | **56.14 s** | 12 ms | 7,083 ms | 49.0 s | 1 |

The model load is about 42 to 45 s (the server's own line: `llama-server started in 42.0 to 43.8 seconds`). Mean `duration_ms`: 101,193 with warm-up off, 99,850 with it on (1.3 % less, inside the run-to-run noise of 1 to 2 s). **Warm-up does not save time; it moves the load into a separate request**, so the generate request that carries the real prompt waits 56 to 57 s instead of 100 s. The 1 to 2 s difference per run is not evidence of a gain.

The four runs produced the same output (`eval_count` 2,260, same SHA-256), so the generation time is comparable.

**Key of the warmed set (F-19 note):** the key is the lower-cased URL and model only. This run observed that **changing `num_ctx` reloads the resident model**: the extra experiment of section 5 (`review` window 32,768, with the model resident at 16,384) had `load_duration` 45.2 s inside the generate call, no `ollama stop` before it. A model warmed with one window is therefore not warm for another one. The options belong in the key (or at least `num_ctx`) if warm-up is ever turned on with profiles that have different windows.

## 9. Measurement 8: model-switch reliability record

The 18 loads before my first call were not made by me: the log shows them between 14:54 and 15:05, after the boot and before the preflight. The task statement mentions 12 loads after the reboot without a fault; I assume they are those, and I did not look into them beyond the log lines.

| # | Change | How | Resident before | Free VRAM before | First load succeeded? | Load time |
|---|---|---|---|---|---|---|
| 1 | nothing -> `qwen3.6:35b` | first call (`rev-invalid-1`) | none | 11,596 MiB | **yes** | 44.5 s |
| 2 | `qwen3.6:35b` -> `qwen3.5:9b` | `ollama stop qwen3.6:35b`, wait 3 s (`ollama ps` empty, 11,778 MiB free), then `spec-1` | none | 11,915 MiB | **yes** | 13.2 s |
| 3 | `qwen3.5:9b` -> `qwen3.6:35b` | `ollama stop qwen3.5:9b`, wait 3 s (empty, 11,915 MiB free), then `rev-think-false` | none | (empty) | **yes** | 46.6 s |
| 4-7 | `qwen3.6:35b` reloaded after `ollama stop` (same model) | 4 times, section 8 | none | 11,924 MiB | **yes** (4 of 4) | 42.0 to 45.5 s |
| 8 | `qwen3.6:35b` reloaded for a new `num_ctx` (16,384 -> 32,768) | no stop | `qwen3.6:35b` | 1,257 MiB | **yes** | 45.2 s |

**Result: 8 of 8 first loads succeeded, 0 CUDA errors, 0 retries**, at uptimes of 24 to 63 minutes. The direction that failed before the reboot (a 9b resident, then the 35b) was done once with an explicit `ollama stop` in between (row 3). The log shows that **before my session** the scheduler also had the second situation (35b requested while 9b was resident, `llama-server model predicted to exceed available memory, evicting`, predicted 20.9 GiB against 5.1 GiB available) **6 times between 14:54 and 15:00 (the 35b loads at 14:54:39, 14:55:40, 14:56:40, 14:57:41, 14:58:42 and 14:59:44) with no fault**, plus 6 more 35b-only reloads at 15:00 to 15:05. The whole `server.log` since the boot (70,276 lines) contains no `CUDA error`, no `Load failed`, no `level=ERROR`, no `0xc0000409`; its only `WARN` is the truncation line of section 5. Total loads visible since the boot: 26 (18 before my first call, 8 mine), 0 faults.

## 10. Measurement 7: speed

All numbers are `eval_count` / `eval_duration` (generated tokens, thinking included, since Ollama does not split them) from the telemetry.

| Model | Calls | Generation tokens/s mean | Min | Max |
|---|---|---|---|---|
| `qwen3.6:35b` (58 % CPU / 42 % GPU at 16,384) | 28 | **48.8** | 45.0 | 53.2 |
| `qwen3.5:9b` | 6 | **62.9** | 58.0 | 67.4 |

Prompt processing, `qwen3.6:35b`, calls with a cold prefix (the 11 calibration calls, prompts of 4,773 to 9,237 tokens): 853 to 909 tokens/s; 19,142 tokens at the 32,768 window: 792 tokens/s. `qwen3.5:9b`, `spec-1` (cold): 5,384 tokens in 1.74 s = 3,090 tokens/s.

Thinking share. Ollama gives no token split between thinking and answer, so the share below is in **characters**: `thinking_chars` / (`thinking_chars` + length of the answer file):

| Call group | Thinking share (characters) |
|---|---|
| Reviewer, invalid fixture (`review`) | 78 % |
| Reviewer, valid fixture | 85 % |
| Reviser (4 calls) | 92 to 97 % |
| Developer (6 calls) | 82 to 93 % |
| Reviewer on large specs (2, 8, 16 KB; answers are long) | 44 to 57 % |
| `spec` (9b) | 64 to 72 % (0 % with `think: false`) |
| Reviewer, `fast` (9b) | 66 to 79 % |

On the 35b, hidden reasoning is the larger part of what is generated for the reviser and the developer (92 to 97 % and 82 to 93 % of the characters).

## 11. Anomalies and notes of this run

| ID | What | Effect |
|---|---|---|
| A1 (fixed) | The earlier run did not record exit codes. This run read `$LASTEXITCODE` after `&` in a child `powershell.exe -File`. | All 34 exit codes are measured: 0 for success and the PASS verdict, 1 for the FAIL verdict of `review-spec.ps1`, 2 for the overflow call. |
| A2 (controlled) | `ollama ps` and free VRAM were recorded before every call; a model change was always preceded by `ollama stop` and a 3 s wait. A resident 9b model never met a 35b load in my sequence. | The earlier condition (a second model resident at the time of the 35b load, 4.7 GiB free) was not repeated by me. |
| A3 (resolved) | Prompt cache. | `prompt_eval_count` includes cached tokens in this Ollama (section 4); only `prompt_eval_duration` is affected. |
| A4 | `overflow-60k` is the only row with an error; it is a format error caused by silent truncation, not an HTTP error. | See section 5. |
| N1 | `possible_prompt_truncation` is not printed by the three scripts, only recorded. | See section 5 and the recommendations. |
| N2 | `think: false` adds 2 tokens to the prompt (5,386 against 5,384; 4,988 against 4,986). | Cosmetic. |
| N3 | The scratch inputs for the calibration (specifications, Spanish, Catalan, English prose) are synthetic and repetitive. | Ratios of real, varied text could differ by a few percent. |
| N4 | The root of every call is a copy of the harness, not the repository tree, so telemetry went to `%TEMP%`, not to `logs\`. | The repository `logs\` was not touched; the CSV extract is built from the scratch telemetry. |

## 12. PROPOSED `.ai/config.json` changes (NOT applied)

Nothing in `.ai/config.json` was changed. This is the proposal, with the evidence for each line; the owner decides.

```diff
   "defaults": {
     "profile": "fast",
     "options": { "temperature": 0.2 },
     "safetyMarginRatio": 0.10,
-    "charsPerToken": 3.5,
+    "charsPerToken": 4.0,
     "stripThinking": true
   },
   "profiles": {
     "deep":   { ..., "contextWindow": 16384, "reservedOutputTokens": 8192, ... },
-    "review": { ..., "reservedOutputTokens": 8192, ... }
+    "review": { ..., "reservedOutputTokens": 6144, ... }
   }
```

| Setting | Proposal | Reasoning |
|---|---|---|
| `defaults.charsPerToken` | **3.5 -> 4.0** (or keep 3.5, see section 4.4) | Measured: 16 prompts, whole-prompt ratio 3.93 to 5.43, mean 4.88; marginal ratio 4.3 to 4.6 for English, 3.5 Spanish, 2.9 Catalan. At 4.0 the only prompt under-estimated is the Catalan one, by 1.7 %, and a 16 KB all-Catalan specification would be off by about 1,460 tokens, below the 1,639-token margin. 3.5 never under-estimates a measured prompt; 4.0 halves the false warnings. The benefit is small by itself: at 4.0 the fixture-size reviewer (26,431 chars) is estimated at 6,608 tokens, still above 6,553 available. |
| `defaults.budgetMode` | **Keep `warn` (no key)** | With the shipped numbers `enforce` would block the fixture-size reviewer and reviser (estimate 7,552 and 8,412 against 6,553 available), calls that work (real 4,986 and 5,649) (RK-201). With `charsPerToken` 4.0 and `review` `reservedOutputTokens` 6,144 the available budget is 8,601 and the estimates are 6,608 (reviewer) and 7,361 (reviser): they pass. Even then `enforce` would block the 8 KB reviser (estimate 9,239 at 4.0) and the 16 KB reviewer and reviser (10,443 and 11,196), which worked here (real 7,401, 8,573 and 9,237 tokens; the 16 KB reviewer fits with R 6,144 and S 1,639: 8,573 + 7,783 = 16,356 <= 16,384; the 16 KB reviser does not: 17,020). `enforce` is a reasonable choice only if the owner prefers a clean refusal to a silent truncation (section 5); then raise `contextWindow` first. |
| `review` / `deep` `reservedOutputTokens` | 8,192 -> **6,144** for `review` (and `deep` if the owner agrees) | Largest normal answer measured: 4,296 tokens (`eval_count`, thinking included; reviser 3,665; developer 2,619; the abnormal truncated call 5,108). 6,144 is 1.43 times the largest. Not tested: what happens when prompt + output exceed the window (the model has no KV-cache shifting, `common_init_` line of the earlier run) and the developer with long output (the calls here asked for short answers). Treat as a proposal with a margin that is thin for long code answers. |
| `review` / `deep` `contextWindow` | **Keep 16,384** as the default; 32,768 verified to work for `review` on this GPU (one call) | All prompts of the normal workflow are 3,116 to 9,237 tokens (a 16 KB specification), which fit. 32,768 handled a 19,142-token prompt without truncation and cost a reload (45 s), 320 MiB more KV and 0.5 GiB less of the model on the GPU; speed was unchanged (46.7 tokens/s). It is the fix for large specifications. Not proposed as a default because the evidence is one call and every change of window forces a model reload. |
| `ollama.warmup` | **Keep `false`** | No total-time gain (99.9 s against 101.2 s). Its only effect is to separate the 43 s load from the generate request. Do not turn it on while the key ignores `num_ctx` (section 8). |
| `think` per agent | **Keep `"default"` everywhere** | `false` and `true` are accepted by both models; `false` cuts the reasoning completely and generation time by two thirds, but quality was not evaluated and the 2026-11-19 validation found specifications worse (OQ-209). A quality evaluation is needed before changing a value, especially for `spec-reviser` and `developer`, where reasoning is 82 to 97 % of what is generated. |
| `agents."spec-reviewer"` | **Keep `review` (35b)** | On `fast` the reviewer judged the invalid fixture wrongly 2 times in 3; on `review` 5 times out of 5 correctly (section 6). |

## 13. Recommendations for Phase 3

1. **The intermittent CUDA fault looks uptime-related, not harness- or model-switch-related.** The earlier run (a machine with days of uptime) lost 11 of 18 loads of `qwen3.6:35b` after `qwen3.5:9b` with `CUDA error: shared object initialization failed` in `ggml_cuda_flash_attn_ext_mma_f16_case` (exit `0xc0000409`); right after the reboot the same load pattern had 0 faults in 12 loads (task statement) and then 0 faults in 8 more of mine, and in 6 of the pre-session loads the 9b model was resident when the 35b was requested, which is the situation of the earlier failure. The engine's retry (5 s) cleared the fault only about half the time before the reboot (per the task statement: 11 of 18 loads lost; in the first report a retry failed again after 55 s). **The hint text** ("restarting the Ollama server usually clears it") **does not match what cured it here: the cure was rebooting the machine** (and restarting the server had cleared it once, on 2026-11-19). Proposal: reword the hint to say that a restart of the Ollama server may clear it and that a reboot of the machine is the remedy if it comes back, and add the uptime to the hint context. (This is an inference from two sessions; the cause itself is NOT determined.)
2. **Do not retry a model-load failure with the same 5 s wait.** A `http_5xx` whose body says `Load failed` or names a CUDA error is a runtime fault: a second identical load took another 55 s in the earlier run. Consider a category of its own, no retry, and the hint at once.
3. **Fail-fast check before a long workflow**: load every model of the workflow with one tiny request at the start of `specify.ps1`, so that a fault shows after one minute.
4. **Handle the model switch explicitly**: `ollama stop` is cheap and was used 7 times without a problem here; a policy for when a workflow unloads the previous model (the 35b is 58 % CPU / 42 % GPU, so the 9b and the 35b do not fit together: the scheduler evicts one to load the other).
5. **Make overflow loud.** Ollama truncates silently and the truncation is not visible in the response: `prompt_eval_count` is the truncated count and `truncated = 0` even on truncation. Print `possible_prompt_truncation` in the three scripts (today only `budget_exceeded` is printed), and compare it with the real prompt size: at 16,384 the 16 KB specification was above C - R = 8,192 without being truncated, so the warning also fires on healthy prompts. A better signal: warn when `prompt_eval_count` is far below the estimate divided by a known maximum ratio, or when the estimate is above `contextWindow` (the real overflow, 19,142 against 16,384).
6. **Use the real count to calibrate at run time**: the telemetry already has `prompt_chars` and `prompt_eval_count`; a per-profile running ratio could replace the fixed `charsPerToken`.
7. **Put `num_ctx` in the warm-up key** (F-19) before turning warm-up on.
8. **Telemetry**: record the `Load failed` text and the `truncating input prompt` fact (the second is only in `server.log`) in a short column.
9. Keep DF-201 to DF-203 as they are in the spec.

## 14. NOT VERIFIED

- `think` on a model that does not support it (HTTP 4xx): not tested; only `qwen3.5:9b` and `qwen3.6:35b` were called with `think` set.
- The quality of the specifications and reviews under `think: false` and `think: true`; one sample per case, no seed on `fast`.
- The exact size at which Ollama starts to truncate (between 9,237 and 19,142 tokens); a prompt plus output that exceeds the window without the prompt alone doing so.
- `charsPerToken` for real Spanish and Catalan documents and for other languages: the texts here are synthetic; the figures are single samples per type.
- Long developer outputs (the developer calls were short) and therefore the proposed `reservedOutputTokens` 6,144 for `deep`.
- That the CUDA fault is caused by uptime: an inference from the before and after of one reboot; not reproduced, not tested by repeating it.
- Anything about `-IncludeLive`, `test-spec-integration.ps1` and `scripts\benchmark-models.ps1`: not run (not permitted by the task).
- A restart of the Ollama server: not done (not permitted).
- The 32,768 window beyond one call (stability over repeated loads, speed on long prompts, behaviour at 12 GB when another application holds VRAM).
