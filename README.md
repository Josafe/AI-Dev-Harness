# AI Development Harness

Reusable AI-assisted software development environment.

## Purpose

This project provides a controlled environment for coordinating AI agents during software development.

It is designed around:

* Specification-Driven Development (SDD)
* Agent specialization
* Automated verification
* Git-based workflows
* Human approval
* Local and cloud AI models

## Architecture

The harness separates:

* orchestration
* specification
* architecture
* implementation
* testing
* review

The system is intentionally project-agnostic.

## Planned Components

* Agent definitions
* Shared development rules
* SDD workflows
* Agent orchestration
* Local model integration
* Cloud model integration
* Automated verification
* Git/GitHub integration

## Requirements

* Windows with Windows PowerShell 5.1 (`powershell.exe`, included in Windows). The scripts are written for it, and `scripts\test-all.ps1` stops if it is missing.
* Ollama, for agent runs and live test suites. The server URL and the models are set in `.ai/config.json`.

## Agents

Agent definitions are in `.ai/agents/`, and every agent follows `.ai/rules/agent-contract.md`. Run an agent from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\run-agent.ps1 -Agent developer -Task "<task>"
```

`-Model` (or the `AI_HARNESS_MODEL` environment variable) overrides the model configured for the agent.

The `developer` agent (`.ai/agents/developer.md`) returns an implementation proposal: complete file contents, changes to existing files, assumptions, risks, open questions and suggested verification. It does not write files or run commands; the proposal must be reviewed and applied separately.

## Tests

Run all regression suites from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\test-all.ps1
```

* `scripts\test-all.ps1` runs every `scripts\test-*.ps1` suite in its own Windows PowerShell 5.1 process and fails any suite that modifies the repository.
* Suites that call a real model through Ollama are reported as `SKIPPED` unless you add `-IncludeLive`. With `-IncludeLive`, they fail if Ollama or the required model is unavailable.
* The exit code is 0 only when no suite failed and at least one passed. `STATUS: PASS WITH SKIPS` means that some tests were skipped and are not verified by that run.

## Status

Early development.
