param(
    [Parameter(Mandatory = $true)]
    [string]$Task,

    [Parameter(Mandatory = $true)]
    [string]$SpecFile,

    [Parameter(Mandatory = $true)]
    [string]$ReviewFile,

    [string]$Mode,
    [string]$Model,
    [string]$OutputFile,
    [string]$ContextFile,
    [string]$Profile
)

# CLI mock of revise-spec.ps1 (Phase 3 B4): Invoke-CliStageExtras (telemetry records,
# manifest snapshot), then scenario-reviser.ps1 with the same parameters; its exit code is
# passed on, a throw propagates, no code stays no code.

. (Join-Path $PSScriptRoot "cli-stage-extras.ps1")
Invoke-CliStageExtras -Stage "reviser"
$global:LASTEXITCODE = $null
& (Join-Path $PSScriptRoot "scenario-reviser.ps1") @PSBoundParameters
if ($null -ne $global:LASTEXITCODE) { exit $global:LASTEXITCODE }
