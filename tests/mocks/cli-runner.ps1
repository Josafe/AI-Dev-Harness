param(
    [string]$Agent,
    [string]$Task,
    [string]$Model,
    [string]$OutputFile,
    [string]$ContextFile,
    [string]$Profile
)

# CLI mock of run-agent.ps1 (Phase 3 B4): Invoke-CliStageExtras (telemetry records,
# manifest snapshot), then scenario-runner.ps1 with the same parameters; its exit code is
# passed on, a throw propagates, no code stays no code.

. (Join-Path $PSScriptRoot "cli-stage-extras.ps1")
Invoke-CliStageExtras -Stage "runner"
$global:LASTEXITCODE = $null
& (Join-Path $PSScriptRoot "scenario-runner.ps1") @PSBoundParameters
if ($null -ne $global:LASTEXITCODE) { exit $global:LASTEXITCODE }
