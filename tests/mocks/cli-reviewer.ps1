param(
    [Parameter(Mandatory = $true)]
    [string]$Task,

    [Parameter(Mandatory = $true)]
    [string]$SpecFile,

    [string]$Mode,
    [string]$Model,
    [string]$OutputFile,
    [string]$ContextFile,
    [string]$Profile
)

# CLI mock of review-spec.ps1 (Phase 3 B4): Invoke-CliStageExtras (telemetry records,
# manifest snapshot), then scenario-reviewer.ps1 with the same parameters; its exit code
# is passed on, a throw propagates, no code stays no code.

. (Join-Path $PSScriptRoot "cli-stage-extras.ps1")
Invoke-CliStageExtras -Stage "reviewer"
$global:LASTEXITCODE = $null
& (Join-Path $PSScriptRoot "scenario-reviewer.ps1") @PSBoundParameters
if ($null -ne $global:LASTEXITCODE) { exit $global:LASTEXITCODE }
