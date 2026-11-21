# Specification

**Title:** Harness modernization, Phase 1: configuration registry v2
**Status:** Implemented (2026-11-21), revision 3. Phase 1 is merged and tagged `phase1-done`; offline verification passed (final QA: `docs/audits/2026-11-20-phase1-final-qa.md`). Live behavior with a real model is NOT VERIFIED. Revision 3 adds the validation of `ollama.healthTimeoutSec` and `ollama.url` (FR-103, AC-114) and states two existing behaviors (FR-103 `schemaVersion`, FR-104 rule 2). OQ-101 to OQ-106 are resolved (OD-106 to OD-111) and the profile assignment is decided (OD-112); there are no open questions.
**Applies to:** AI-Dev-Harness. Baseline: commit `5ffc33f` (tag `phase0-done`).
**Requirement ID scheme:** Phase 1 uses `FR-1nn`, `NFR-1nn`, `AC-1nn`. Phase 0 IDs are cited as "Phase 0 NFR-006" and similar (`specs/harness-phase-0-defect-corrections.md`).

## Goal

Add a configuration registry v2 to `.ai/config.json` (`schemaVersion: 2`) with named profiles and per-agent profile assignment, behind one loader that accepts the current v1 file or a v2 file and always returns a normalized v2 object, with simple validation. Remove the model-name literals that remain in scripts. Nothing outside configuration changes.

## Context

**Origin.** The Phase 1 section, XR-01 (backward compatibility) and XR-02 (how the model and profile are chosen) of `docs/roadmap/modernization-roadmap.md`, narrowed here (OD-107), and the decisions of 2026-11-20 (OD-101 to OD-112).

**Current behavior** (FACT, verified in the repository at `5ffc33f`):

- **The v1 file.** `.ai/config.json` has `ollamaUrl`, `defaultModel` (`qwen3.5:9b`), `agentModels` (`spec` `qwen3.5:9b`; `spec-reviewer`, `spec-reviser`, `developer` `qwen3.6:35b`), `options` (`temperature` 0.2, `num_ctx` 16384), `timeoutSec` 900 and `stripThinking` true. Four agents have a file in `.ai/agents/`: `spec`, `spec-reviewer`, `spec-reviser`, `developer`.
- **Loading.** `Get-HarnessConfig` (`scripts/lib/config.ps1`) returns the parsed JSON, or an empty object when the file is missing; invalid JSON throws "Invalid JSON in config file: ...".
- **Model selection.** `Resolve-HarnessModel -Agent -ModelWasProvided -ExplicitModel -Config` returns, in order: the explicit model (even if blank; callers reject a blank one), `AI_HARNESS_MODEL` when not blank, `agentModels.<Agent>`, `defaultModel`; otherwise it throws "No model configured. Use -Model, set AI_HARNESS_MODEL, or define defaultModel in .ai\config.json." Callers: `run-agent.ps1`, `review-spec.ps1`, `revise-spec.ps1`, `test-all.ps1` (`Resolve-LiveSuiteModel`, through the `ModelAgent` field) and `test-spec-integration.ps1`.
- **Other reads.** `Invoke-HarnessGenerate` and `run-agent.ps1` read `ollamaUrl`, `timeoutSec` (default 600), `stripThinking` (default true) and `options`. `Test-HarnessModelAvailable` and `run-agent.ps1` use a fixed 15 s health timeout.
- **Literals.** The only model names found in `scripts/*.ps1` are the default `-Models` of `benchmark-models.ps1`: `qwen2.5-coder:7b`, `qwen2.5-coder:32b`, `deepseek-r1:32b`.
- **Test seam.** `scripts/test-agent-telemetry.ps1` runs the real scripts in a temporary harness root with a fake `Invoke-RestMethod` and four guards that make a real request impossible (Phase 0 FR-018).

**Out of scope.** Phase 2: streaming, `num_predict`, transport, budget enforcement, any use of `think` or of the `thinking` response field, and the roadmap's `reasoning`, `transport`, `agents.<A>.promptFile`, `defaults.charsPerToken` and `tests` keys (OD-107). Phase 3: the unified CLI, `-Profile` on `specify.ps1`, manifests, background runs (OD-108). Not changed at all: prompts, `.ai/agents/*.md`, telemetry, the timeout and the models in use (Phase 0 deferred O-01).

## Functional Requirements

### FR-101 — Registry v2 format

**Source:** USER

`.ai/config.json` may be a v2 file, marked `"schemaVersion": 2`. A file without `schemaVersion` is v1 and stays valid (OD-101). A v2 file has these top-level keys:

| Key | Content |
|---|---|
| `ollama` | `url` (default `http://localhost:11434`), `healthTimeoutSec` (default 15) |
| `defaults` | `profile` (the default profile name); `options` (an object); `timeoutSec` (fallback for profiles, default 600); `safetyMarginRatio` (default 0.10); `stripThinking` (default true, OD-106) |
| `profiles` | `<name>`: `model` (required), `contextWindow`, `timeoutSec`, `reservedOutputTokens`, `think` (`true`, `false` or `"default"`; absent means `"default"`), `options` |
| `agents` | `<name>`: `profile` |

The profiles of the migrated `.ai/config.json` are `fast`, `deep` and `review` (OD-103, OD-105, OD-112; table below). The example that follows is the strict v2 translation of the current v1 file (profiles `fast` and `deep`, no `review`, same options). It is the fixture `config-v2-current.json`, so that the golden equality of AC-101 stays exact. This spec task does not edit `.ai/config.json`.

```json
{
  "schemaVersion": 2,
  "ollama":   { "url": "http://localhost:11434", "healthTimeoutSec": 15 },
  "defaults": { "profile": "fast", "options": { "temperature": 0.2 },
                "safetyMarginRatio": 0.10, "stripThinking": true },
  "profiles": {
    "fast": { "model": "qwen3.5:9b",  "contextWindow": 16384, "timeoutSec": 900,
              "reservedOutputTokens": 4096, "think": "default" },
    "deep": { "model": "qwen3.6:35b", "contextWindow": 16384, "timeoutSec": 900,
              "reservedOutputTokens": 8192, "think": "default" }
  },
  "agents": { "spec": { "profile": "fast" }, "spec-reviser": { "profile": "deep" },
              "spec-reviewer": { "profile": "deep" }, "developer": { "profile": "deep" } }
}
```

**Effective options** of a profile: `defaults.options`, then `profile.options`, then `num_ctx` set to `contextWindow` when `contextWindow` is present. In the example, this equals the v1 `options` (`temperature` 0.2, `num_ctx` 16384).

**Profiles and agents of the migrated `.ai/config.json` (OD-112, WP-1B):**

| Profile | Model | `think` | `reservedOutputTokens` | Profile `options` |
|---|---|---|---|---|
| `fast` | `qwen3.5:9b` | `"default"` | 4096 | none |
| `deep` | `qwen3.6:35b` | `"default"` | 8192 | none |
| `review` | `qwen3.6:35b` | `"default"` | 8192 | `temperature` 0.1, `seed` 42 |

All three profiles keep `contextWindow` 16384 and `timeoutSec` 900; `defaults` is as in the example. Agents: `spec` uses `fast`; `spec-reviewer` uses `review`; `spec-reviser` and `developer` use `deep`; `defaults.profile` is `fast`. The effective options of `review` are `temperature` 0.1, `seed` 42 and `num_ctx` 16384.

**Rationale** (FACT unless marked):

- The 9B model is unreliable as a reviser: 1 good output in 4 attempts (`docs/audits/2026-11-19-model-validation-2.md`, check B; `docs/audits/2026-11-19-model-validation.md`). So the reviser and the developer use the 35B model.
- The reviewer needs stable verdicts. In the live runs of 2026-11-20 one fixture gave opposite verdicts in 1 of 5 runs, and one reviewer call produced 5,076 output tokens. (Reported by the user from those runs; no repository document records them.) So `review` pins `temperature` and `seed`, and `reservedOutputTokens` for `deep` and `review` is raised from 6144 to 8192, which supersedes OD-105 for those two profiles; `fast` stays at 4096.
- With this assignment a spec, review and revise run swaps models only once: the 9B model for `spec`, then the 35B model for the reviewer and the reviser.
- `review` uses `temperature` 0.1 and not 0, because greedy decoding can loop with reasoning models (ASSUMPTION; to be measured later, not in Phase 1).
- `think` is only stored in Phase 1, and every profile has `"default"`. The intended later value for the reviser is `false`; it is noted here, not configured.

### FR-102 — One loader that returns a normalized v2 object

**Source:** USER

`Get-HarnessRegistry -ConfigPath <path>` (in `scripts/lib/config.ps1`) reads the file and returns a normalized v2 object with the keys of FR-101, every default filled in. It reuses `Get-HarnessConfig` for reading, so a missing file and invalid JSON behave as today (a missing file is an empty v1 file: no profiles, no agents).

**A v1 file is converted on load:**

- `ollamaUrl` becomes `ollama.url`.
- `options` becomes `defaults.options`; `timeoutSec` becomes `defaults.timeoutSec`; `stripThinking` becomes `defaults.stripThinking`. A missing value takes the default.
- Each distinct model in `agentModels` and `defaultModel` becomes the synthetic profile `legacy:<model>`, with only `model` set, so it inherits the defaults.
- `agents.<A>.profile` is the synthetic profile of `agentModels.<A>`.
- `defaults.profile` is the synthetic profile of `defaultModel`, when present.
- `contextWindow` is left absent, because v1 has no such value; `num_ctx` stays in `defaults.options`.

### FR-103 — Validation on load

**Source:** USER

`Get-HarnessRegistry` validates a v2 file and, if a rule fails, throws a message that starts with the fixed token `registry_invalid:` followed by the rule and the offending name. The rules:

- `schemaVersion` is `2`; any other value is invalid. Only a file without the `schemaVersion` key is v1: an explicit `"schemaVersion": 1` or `null` is invalid (`registry_invalid: schemaVersion`), not v1.
- `ollama.healthTimeoutSec`, when present, is an integer from 1 to 600 (the error token is `registry_invalid: ollama.healthTimeoutSec`). `ollama.url`, when present, is a non-blank string (`registry_invalid: ollama.url`). Absent, they take the defaults of FR-101.
- Every profile has a non-blank string `model`.
- `defaults.profile` and every `agents.<A>.profile` name an existing profile.
- `timeoutSec` (in a profile or in `defaults`) is an integer from 30 to 14400.
- `contextWindow` and `reservedOutputTokens`, when present, are positive integers. When both are present, `contextWindow` must be greater than `reservedOutputTokens` plus `ceil(safetyMarginRatio × contextWindow)`.
- When a profile has a `contextWindow`, any `num_ctx` in `defaults.options` or in that profile's `options` equals it (XR-03: `contextWindow` is the only source of `num_ctx`).
- `think`, when present, is `true`, `false` or the string `"default"`.

**Warnings, not errors.** Unknown keys, and an `ollama.url` whose host is not `localhost`, `127.0.0.1` or `::1`, add a code to the registry's `warnings` list (`unknown_key:<path>`, `non_loopback_ollama_url`). Nothing is printed (NFR-103).

**Scope.** These checks apply to v2 files only; a v1 file is accepted as today, whatever its values (NFR-103). They read the file only and run before any network call.

### FR-104 — Execution resolution and `-Profile`

**Source:** USER

`Resolve-HarnessExecution -Agent <A> -Registry <normalized registry> [-Model <M>] [-Profile <P>]` returns the resolved record and implements XR-02 of the roadmap. A bound but blank `-Model` is passed through, as today.

**Rules, in order:**

1. `-Model` together with `-Profile` is an error that starts with the token `invalid_arguments:` (OD-102).
2. `-Model M`: the model is `M`; `modelSource` is `explicit-model`. The parameters come from the one profile whose `model` equals `M`, if exactly one does; otherwise from agent `A`'s profile, or from `defaults.profile` when `A` has no registry entry, and, if no profile has that model, the warning code `unregistered_model_override` is added, in the record only and never printed (OD-109).
3. `-Profile P`: `P` must exist, otherwise `registry_invalid:`; `modelSource` is `explicit-profile`.
4. `AI_HARNESS_MODEL` set and not blank: handled like rule 2; `modelSource` is `env`.
5. `agents.<A>.profile`: `modelSource` is `agent`.
6. `defaults.profile`: `modelSource` is `default`.
7. Otherwise the error is the existing message "No model configured. Use -Model, set AI_HARNESS_MODEL, or define defaultModel in .ai\config.json."

**The record** has: `agent`, `profile`, `model`, `modelSource`, `parametersFrom` (the profile that supplied the parameters), `contextWindow`, `timeoutSec` (profile, else `defaults.timeoutSec`), `reservedOutputTokens`, `options` (the effective options of FR-101), `think` and `warnings`. When rule 2 or 4 finds no profile to take the parameters from, the record uses the defaults and `parametersFrom` is empty.

### FR-105 — `Resolve-HarnessModel` stays a compatibility wrapper

**Source:** USER

`Resolve-HarnessModel` keeps its parameters (`-Agent`, `-ModelWasProvided`, `-ExplicitModel`, `-Config`), where `-Config` is the object returned by `Get-HarnessConfig`, v1 or v2. It normalizes it and returns the model of `Resolve-HarnessExecution` as a string, with today's behavior: an explicit model is returned unchanged (even when blank), the error message of rule 7 is unchanged, and an empty configuration object works when `AI_HARNESS_MODEL` is set.

### FR-106 — Call sites read configuration through the registry

**Source:** USER

- `run-agent.ps1`, `review-spec.ps1` and `revise-spec.ps1` accept a new optional `-Profile`, resolve with `Resolve-HarnessExecution`, and take `timeoutSec`, `options`, `stripThinking` and the Ollama URL from the record and the registry. `run-agent.ps1` also uses `ollama.healthTimeoutSec` (default 15) for its `/api/tags` check. Their other parameters, exit codes, console output and output files do not change.
- `Invoke-HarnessGenerate` and `Test-HarnessModelAvailable` read the same values from the registry and the record.
- `test-all.ps1` and `test-spec-integration.ps1` resolve their model through the same resolution as production. The `ModelAgent` field and its contract do not change.
- `specify.ps1` is not changed (OD-108).
- A configuration error (`registry_invalid:`, `invalid_arguments:`) ends each script with the exit code it already gives for a configuration error (1 for `run-agent.ps1`, 2 for `review-spec.ps1`, non-zero for `revise-spec.ps1`), before any request to Ollama, writing no telemetry.

### FR-107 — No model-name literals in scripts

**Source:** USER

No file in `scripts/` (including `scripts/lib/`) contains a model name. The default `-Models` of `benchmark-models.ps1` is the distinct profile models of the registry, in profile order, taken at run time; an explicit `-Models` is unchanged. Any other script that needs a model name resolves it through the registry. Test fixtures that need model names live in `tests/fixtures/`.

### FR-108 — `think` is stored, not used

**Source:** USER

The loader keeps `think` (`true`, `false` or `"default"`, normalized to `"default"` when absent) in the profile and in the resolved record. No script sends `think` to Ollama or changes behavior because of it in Phase 1. Phase 2 uses it.

## Non-Functional Requirements

### NFR-101 — Platform and dependencies

**Source:** PROJECT

Windows PowerShell 5.1 only. No modules, packages or executables are added. `ConvertFrom-Json` is not used with `-AsHashtable`; JSON is read and written with depth at least 10.

### NFR-102 — Offline, side-effect-free tests

**Source:** USER

Every new or changed suite follows Phase 0 NFR-002 and NFR-006: it runs without Ollama or any network, writes only under `TEMP` (or its `test-all` sandbox), leaves the repository tripwire clean, has no mandatory parameters and ends with an explicit `exit`. Assertions match only the harness's own wording (`registry_invalid:`, `invalid_arguments:`, warning codes, exit codes, resolved values), never text produced by PowerShell or .NET. Where a test must run a real script that could make a request, it reuses the fake-host approach and the four guards of `scripts/test-agent-telemetry.ps1`.

### NFR-103 — Backward compatibility (XR-01)

**Source:** USER

With a v1 configuration, every agent resolves to exactly the model it resolves to today, under no override, `-Model`, `AI_HARNESS_MODEL`, and `-Model` with `AI_HARNESS_MODEL`; and the effective `timeoutSec`, `options`, `stripThinking` and Ollama URL equal today's values. The parameters, exit codes, console output and output files of every existing script, the environment variables `AI_HARNESS_MODEL` and `AI_HARNESS_RUN_ID`, the telemetry files and schema, the `test-all.ps1` contract (including `ModelAgent`) and the prompts sent to models do not change. The only intentional changes are the optional `-Profile`, the new benchmark default and, once `.ai/config.json` is migrated to v2 (WP-1B), the sampling options of `spec-reviewer`, which gain `temperature` 0.1 and `seed` 42 (OD-112, AC-113). Under a v1 configuration the harness prints nothing new.

### NFR-104 — Change footprint

**Source:** USER

Only the files under "Affected Files" are created or modified. No unrelated refactoring. The prompts and `.ai/agents/*` are untouched.

## Acceptance Criteria

"Resolves" below means the resolved model, and also `timeoutSec`, `options`, `stripThinking` and the Ollama URL where stated. The golden tables use the fixtures `config-v1-current.json` (a frozen copy of today's `.ai/config.json`) and `config-v2-current.json` (the example of FR-101).

### AC-101 — Golden model resolution is identical under v1 and its v2 translation

**Source:** USER

Verifies: FR-102, FR-104, FR-105, NFR-103.

For each of five agents (`spec`, `spec-reviewer`, `spec-reviser`, `developer`, and one agent with no registry entry) and each of four cases (no override; `-Model`; `AI_HARNESS_MODEL`; both), `Resolve-HarnessModel` and `Resolve-HarnessExecution` give the same model under `config-v1-current.json` and `config-v2-current.json`. The expected value is computed by the test from the v1 file's raw JSON (`agentModels.<A>`, else `defaultModel`, with `-Model` first and the variable second), not from the code under test. An agent with no entry resolves to the default. The test sets and restores `AI_HARNESS_MODEL`.

### AC-102 — v1 conversion and normalization

**Source:** USER

Verifies: FR-101, FR-102, NFR-103.

- Loading `config-v1-current.json` returns `schemaVersion` 2, the profiles `legacy:qwen3.5:9b` and `legacy:qwen3.6:35b`, the four agent assignments and `defaults.profile`, with `ollama.url`, `defaults.timeoutSec`, `defaults.options` and `defaults.stripThinking` equal to the v1 values.
- The effective `timeoutSec`, `options` (as key and value pairs, not serialized text), `stripThinking` and URL of every agent are equal under both fixtures.
- A v1 fixture without `timeoutSec`, `stripThinking`, `ollamaUrl` and `options` gets the defaults (600, true, `http://localhost:11434`, none). An empty or missing file loads as an empty registry: the wrapper resolves with `AI_HARNESS_MODEL` set, and throws the rule 7 message without it.

### AC-103 — Invalid v2 files are rejected; warnings are not errors

**Source:** USER

Verifies: FR-103, FR-108, NFR-102.

One fixture per rule, each rejected by `Get-HarnessRegistry` with the token `registry_invalid:`: `schemaVersion` 3; a profile without `model`; an unknown `defaults.profile`; an unknown agent profile; `timeoutSec` 29 and 14401; a `contextWindow` not greater than `reservedOutputTokens` plus the margin; `options.num_ctx` different from `contextWindow`; `think` equal to `"maybe"`. A v1 fixture with `timeoutSec` 10 loads. A v2 fixture with an unknown key and a non-loopback URL loads and carries `unknown_key:` and `non_loopback_ollama_url` in `warnings`. `think` is `"default"` when absent and `true`, `false` and `"default"` are kept. The margin rule is checked with a non-default `defaults.safetyMarginRatio` and with a fractional product (ratio 0.1 and window 8191 give 819.1, rounded up to 820), at the exact accepted and rejected boundaries, with expected values written as literals. An explicit `"schemaVersion": 1` and `"schemaVersion": null` are rejected.

### AC-104 — Invalid configuration stops the scripts before any request

**Source:** USER

Verifies: FR-103, FR-106, NFR-102.

Using a temporary harness root and the guards of NFR-102, `run-agent.ps1`, `review-spec.ps1` and `revise-spec.ps1` run with an invalid v2 `.ai/config.json` each exit with the code they give for a configuration error today (1, 2 and non-zero), print a line containing `registry_invalid:`, make no request, and write no telemetry line.

### AC-105 — `-Model` with `-Profile` is rejected

**Source:** USER

Verifies: FR-104, FR-106.

`Resolve-HarnessExecution` with both throws a message that starts with `invalid_arguments:`, under v1 and v2 fixtures. With the same guards as AC-104, `run-agent.ps1`, `review-spec.ps1` and `revise-spec.ps1` given both parameters print a line containing `invalid_arguments:`, exit with their configuration-error code, make no request and write no telemetry.

### AC-106 — Selection rules and resolved record

**Source:** USER

Verifies: FR-104, FR-105.

Under `config-v2-current.json` plus one extra profile that shares no model with the others:

- the order `-Profile`, then `AI_HARNESS_MODEL`, then agent profile, then default profile holds, with `modelSource` equal to `explicit-profile`, `env`, `agent` and `default`
- an unknown `-Profile` gives `registry_invalid:`
- `-Model` equal to the model of exactly one profile takes that profile's parameters, with no warning
- `-Model` with an unregistered name takes the agent's profile parameters and adds `unregistered_model_override`
- a blank `-Model` is returned unchanged by the wrapper, and `run-agent.ps1`, `review-spec.ps1` and `revise-spec.ps1` still reject it with "Model name cannot be empty." (their existing wording)
- the record has the fields of FR-104

### AC-107 — No model-name literals in `scripts/`

**Source:** USER

Verifies: FR-107, NFR-102.

A static check reads every model name from `.ai/config.json` (v1 `defaultModel` and `agentModels`, or v2 profile models) and from `tests/fixtures/historical-model-names.txt` (the three names of the Context section). With `Select-String -SimpleMatch`, none appears in any file under `scripts/`, not even in a comment. No file is exempt: the check reads its names from data files, so it contains none.

### AC-108 — The benchmark default comes from the registry

**Source:** USER

Verifies: FR-107, FR-106.

A registry helper returns the distinct profile models in profile order (checked on `config-v2-current.json`, expecting the order `fast`, `deep`, and on `config-v1-current.json`). Inspection: `benchmark-models.ps1` uses it when `-Models` is not bound, and an explicit `-Models` is unchanged. `benchmark-models.ps1` is not run.

### AC-109 — `think` is stored and never sent

**Source:** USER

Verifies: FR-108, FR-106.

The record carries `think` for each fixture value (`true`, `false`, `"default"`, absent). Inspection: the request bodies built by `Invoke-HarnessGenerate` and `run-agent.ps1` have no `think` member, and no changed script reads `think` for anything but copying it into the record.

### AC-110 — The live-suite model resolves like production

**Source:** USER

Verifies: FR-106, NFR-103.

The `ModelAgent = "spec-reviewer"` resolution used by `test-all.ps1` (`Resolve-LiveSuiteModel`) gives the same model as `review-spec.ps1` does, under the v1 fixture and its v2 translation. Offline `test-all.ps1` still prints that model in the SKIPPED detail of the live suite (the Phase 0 AC-019 procedure).

### AC-111 — Full offline regression

**Source:** USER

Verifies: NFR-101, NFR-102, NFR-103.

`scripts/test-all.ps1` without `-IncludeLive` ends with `STATUS: PASS WITH SKIPS`, every suite that passed at `5ffc33f` still passes with the same counts (`test-spec` 17/0, Phase 0 suites included), the new registry suites pass, `test-syntax.ps1` parses every new and changed script, and the repository tripwire is clean.

### AC-112 — Only the expected files change

**Source:** USER

Verifies: NFR-103, NFR-104.

`git diff --stat` against `5ffc33f` lists only files in "Affected Files". The diff has no change in the system or user prompt strings of `review-spec.ps1` and `revise-spec.ps1`, and `.ai/agents/*`, `.ai/rules/*` and `scripts/lib/telemetry.ps1` are unmodified. `.ai/config.json` changes only in WP-1B.

### AC-113 — The migrated `.ai/config.json` keeps every model and changes only the reviewer's options

**Source:** USER

Verifies: FR-101, NFR-103.

With the migrated v2 `.ai/config.json` (WP-1B), for `spec`, `spec-reviewer`, `spec-reviser`, `developer` and one agent with no registry entry:

- `Resolve-HarnessExecution` gives the same model as under `config-v1-current.json`, and the same `timeoutSec`, `stripThinking` and Ollama URL.
- The effective options are identical to v1, except for `spec-reviewer`, whose effective options differ only by `temperature` 0.1 (instead of 0.2) and `seed` 42 (added). This change is intentional (OD-112).
- The file has exactly the profiles `fast`, `deep` and `review` and the agent assignments of FR-101 (`spec` to `fast`, `spec-reviewer` to `review`, `spec-reviser` and `developer` to `deep`, `defaults.profile` `fast`); `reservedOutputTokens` is 4096, 8192 and 8192; `think` is `"default"` in all three.

The expected values are read from the raw JSON of `config-v1-current.json`, not from the code under test, and the check contains no model name (AC-107).

### AC-114 — `ollama.healthTimeoutSec` and `ollama.url` are validated

**Source:** USER

Verifies: FR-103.

`Get-HarnessRegistry` and the `Resolve-HarnessModel` wrapper accept a v2 file with `healthTimeoutSec` 1 and 600, and reject 0, -5, 601, `"abc"` and 30.5 with `registry_invalid: ollama.healthTimeoutSec`. A blank `ollama.url` is rejected with `registry_invalid: ollama.url`. A v1 file, and a v2 file without these fields, still load with `healthTimeoutSec` 15. With the guards of NFR-102, `review-spec.ps1` run with an invalid `healthTimeoutSec` exits 2, prints a line containing `registry_invalid: ollama.healthTimeoutSec`, makes no request and writes no telemetry line.

## Traceability Matrix

This table is the inverse of the `Verifies:` lines above. The two must stay identical.

| Requirement | Acceptance criteria |
|---|---|
| FR-101 | AC-102, AC-113 |
| FR-102 | AC-101, AC-102 |
| FR-103 | AC-103, AC-104, AC-114 |
| FR-104 | AC-101, AC-105, AC-106 |
| FR-105 | AC-101, AC-106 |
| FR-106 | AC-104, AC-105, AC-108, AC-109, AC-110 |
| FR-107 | AC-107, AC-108 |
| FR-108 | AC-103, AC-109 |
| NFR-101 | AC-111 |
| NFR-102 | AC-103, AC-104, AC-107, AC-111 |
| NFR-103 | AC-101, AC-102, AC-110, AC-111, AC-112, AC-113 |
| NFR-104 | AC-112 |

## Affected Files

| File | Change | Requirements |
|---|---|---|
| `scripts/lib/config.ps1` (modified) | Add `Get-HarnessRegistry` and `Resolve-HarnessExecution`; make `Resolve-HarnessModel` a wrapper; make `Invoke-HarnessGenerate` and `Test-HarnessModelAvailable` read the registry. | FR-101 to FR-106 |
| `scripts/run-agent.ps1`, `review-spec.ps1`, `revise-spec.ps1` (modified) | Add `-Profile`, resolve through the registry, read timeouts and options from it. Prompts unchanged. | FR-104, FR-106 |
| `scripts/benchmark-models.ps1` (modified) | Remove the literal default `-Models`; build it from the registry. | FR-107 |
| `scripts/test-all.ps1`, `scripts/test-spec-integration.ps1` (modified) | Resolve the live-suite model through the registry resolution. | FR-106 |
| `.ai/config.json` (modified) | WP-1B only, last commit, with human approval: rewrite as v2 with the profiles `fast`, `deep` and `review` (OD-110, OD-112). | FR-101 |
| `scripts/test-registry.ps1` (new) | WP-1A, in-process: golden table, conversion, validation, selection rules, `think` | AC-101, AC-102, AC-103, AC-105 (function part), AC-106, AC-109 (record part), AC-114 |
| `scripts/test-registry-callsites.ps1` (new) | WP-1B: child-process cases with the fake-host guards, the literal scan, the benchmark helper, the live-suite model | AC-104, AC-105, AC-106 (script part), AC-107, AC-108, AC-109 (request bodies), AC-110, AC-113, AC-114 |
| `tests/fixtures/config-v1-current.json`, `config-v2-current.json` (new) | Frozen v1 file and its strict v2 translation (no `review` profile) | AC-101, AC-102, AC-110 |
| `tests/fixtures/config-v1-minimal.json`, `config-v2-*.json` (new) | One per invalid rule, plus warnings and `think` cases, with synthetic model names | AC-102, AC-103, AC-106 |
| `tests/fixtures/historical-model-names.txt` (new, WP-1B) | The three historical model names, as data | AC-107 |

**Not modified:** `specify.ps1`, `validate-spec.ps1`, `scan-repository.ps1`, `build-context.ps1`, `lib/telemetry.ps1`, `.ai/agents/*`, `.ai/rules/*`, `AGENTS.md`, `README.md`, and all Phase 0 suites, mocks and fixtures.

## Execution Order

Two work packages, each one commit. Run `scripts/test-all.ps1` offline after each. Only commands actually run count as verification, and local model output never does. The live suite and any call to Ollama are NOT VERIFIED in Phase 1.

| Step | Work package | Depends on | Exit check |
|---|---|---|---|
| 0 | Record the baseline: offline `test-all` at `5ffc33f`. Freeze `config-v1-current.json` from `.ai/config.json`. | Phase 0 done | Baseline recorded |
| 1 | **WP-1A Registry library.** `Get-HarnessRegistry`, `Resolve-HarnessExecution`, the `Resolve-HarnessModel` wrapper, fixtures and `test-registry.ps1`. No call site changes. | Step 0 | AC-101, AC-102, AC-103, AC-105 (function part), AC-106, AC-109 (record part), AC-111 |
| 2 | **WP-1B Call sites and migration.** FR-106 and FR-107, `test-registry-callsites.ps1`, then (after approval) the v2 rewrite of `.ai/config.json` as the last commit. | WP-1A | AC-104, AC-105, AC-107, AC-108, AC-109, AC-110, AC-111, AC-112, AC-113 |
| 3 | Final QA, independent review and human approval. | WP-1B | All |

## Edge Cases

- **Empty or missing config.** An empty v1 registry. Resolution works only with `-Model` or `AI_HARNESS_MODEL`; otherwise the existing "No model configured" message (AC-102).
- **An agent with no registry entry** (a new `.ai/agents/<A>.md`) resolves to the default profile (AC-101).
- **v1 without `num_ctx`.** `contextWindow` stays absent, no margin check runs, and nothing is added to `options`.
- **`options` key order.** Effective options are compared as key and value pairs; the JSON key order in the request body may differ from v1, which Ollama ignores.
- **`-Model` and `-Profile` both bound, one of them blank.** Still rejected: the check looks at whether each parameter was bound.
- **`-Model` matching two or more profiles.** The agent's profile supplies the parameters, with no warning (OD-109). `-Profile` also wins over `AI_HARNESS_MODEL` (rule 3 before rule 4).
- **Case.** Agent and profile names are looked up as PowerShell looks up a property, which ignores case (A-103). Model names are compared without regard to case when `-Model` is matched to a profile, as the availability check does (Phase 0 FR-010).

## Dependencies

- Phase 0 complete (tag `phase0-done`). Phase 2 depends on this phase and consumes `think`, `reservedOutputTokens`, `contextWindow` and `safetyMarginRatio`.
- Runtime: Windows PowerShell 5.1; no Ollama, network or new tools. The roadmap's platform decision gate (PowerShell 5.1, 7 or Python) is settled before Phase 2, not before this phase.
- Test infrastructure: the `test-all.ps1` suite contract, sandbox and tripwire; the fake-host approach of `test-agent-telemetry.ps1`.

## Risks and Rollback

| ID | Risk | Mitigation |
|---|---|---|
| RK-101 | A v1 file resolves differently after the change. | AC-101 and AC-102 (golden tables on the frozen v1 file and its v2 translation); the wrapper keeps the old signature (FR-105). |
| RK-102 | A test makes a real request. | NFR-102 guards on every child-process case; resolution tests are in-process and need no request. |
| RK-103 | The v2 rewrite of `.ai/config.json` breaks live use. | It is the last commit of WP-1B, needs approval, and is reverted alone; v1 stays valid. |
| RK-104 | The provisional `reservedOutputTokens` values are wrong. | They are only stored in Phase 1; calibrated in Phase 2 (OD-105, OD-112). |
| RK-105 | The reviewer's options (`temperature` 0.1, `seed` 42) change its behavior compared with v1. | Intentional and bounded by AC-113; stored in one profile (`review`), so it is reverted by editing that profile or the migration commit; to be measured later (OD-112). |

**Rollback.** Each work package is one commit, reverted with `git revert`: WP-1B first (including the config rewrite), then WP-1A. Reverting only the `.ai/config.json` commit returns the file to v1, which every version of the loader accepts. Telemetry and logs are never changed.

## Resolved Decisions

| ID | Decision (2026-11-20, source USER) | Effect on this spec |
|---|---|---|
| OD-101 | The registry lives in the same `.ai/config.json` with `schemaVersion: 2`; v1 stays valid (roadmap O-03). | FR-101, FR-102 |
| OD-102 | `-Model` together with `-Profile` is rejected with a clear error (roadmap O-04). | FR-104, AC-105 |
| OD-103 | The initial profiles are `fast` (`qwen3.5:9b`) and `deep` (`qwen3.6:35b`). | FR-101 |
| OD-104 | Each profile has a `think` field (`true`, `false` or `default`); Phase 1 only stores it, Phase 2 uses it. | FR-101, FR-108 |
| OD-105 | `reservedOutputTokens` is 4096 for `fast` and 6144 for `deep`, to calibrate in Phase 2 (roadmap O-16, provisional). Superseded for `deep` (and the new `review`) by OD-112: 8192. | FR-101, RK-104 |
| OD-106 | `stripThinking` lives in `defaults.stripThinking` (was OQ-101, A-101). | FR-101 |
| OD-107 | `reasoning`, `transport`, `agents.<A>.promptFile`, `defaults.charsPerToken` and the `tests` section move to Phase 2 (was OQ-102). | Out of scope |
| OD-108 | Phase 1 adds no `-Profile` to `specify.ps1`; only the three scripts that resolve a model get it (was OQ-103). | FR-106 |
| OD-109 | `-Model M` matching two or more profiles uses the agent's profile with no warning; `unregistered_model_override` is only in the record, never printed (was OQ-104). | FR-104, Edge Cases |
| OD-110 | `.ai/config.json` is migrated to v2 as the last commit of WP-1B, with human approval (was OQ-105). | FR-101, RK-103 |
| OD-111 | `timeoutSec` 900 and `contextWindow` 16384 stay as today in every profile (was OQ-106). | FR-101 |
| OD-112 | The migrated `.ai/config.json` has three profiles: `fast` (`qwen3.5:9b`, `think` `"default"`, `reservedOutputTokens` 4096), `deep` (`qwen3.6:35b`, `think` `"default"`, 8192) and `review` (`qwen3.6:35b`, options `temperature` 0.1 and `seed` 42, `think` `"default"`, 8192). Agents: `spec` to `fast`, `spec-reviewer` to `review`, `spec-reviser` and `developer` to `deep`; `defaults.profile` is `fast`. The rationale is in FR-101. The fixture `config-v2-current.json` stays a strict translation of v1. | FR-101, NFR-103, AC-113, RK-105 |

## Open Questions

None.

## Assumptions

- **A-101:** `defaults.stripThinking` is the home for `stripThinking` (confirmed by OD-106).
- **A-102:** A `think` value of `"default"` means no `think` member is sent, as the harness does today. Phase 2 defines how `true` and `false` are sent.
- **A-103:** PowerShell property lookup ignores case, so agent and profile keys read from parsed JSON are found regardless of case, as the current `agentModels` lookup does. This spec does not change that.
- **A-104:** The three historical model names are the only ones that could reappear as literals; the scan also covers every configured name.
