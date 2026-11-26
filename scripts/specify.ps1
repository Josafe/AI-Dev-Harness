param(
    [Parameter(Mandatory = $true)]
    [string]$Task,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [string]$Model,

    [ValidateSet("requirements", "baseline", "documentation")]
    [string]$Mode = "requirements",

    [string]$RunnerScript,
    [string]$ValidatorScript,
    [string]$ReviewerScript,
    [string]$ReviserScript,

    [string]$Profile
)

$ErrorActionPreference = "Stop"

trap {
    Write-Host ""
    Write-Host "=== Specification Workflow Failed ===" -ForegroundColor Red
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

$root = Split-Path -Parent $PSScriptRoot

if ($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') {
    Write-Host ""
    Write-Host "=== Specification Workflow Failed ===" -ForegroundColor Red
    Write-Host "Invalid specification name: $Name" -ForegroundColor Red
    Write-Host "Use only letters, numbers, dots, underscores and hyphens."
    Write-Host "The name must start with a letter or number."
    exit 2
}

# The workflow lives in lib\workflow.ps1 (Phase 3 FR-303), shared with the CLI.
# This script is the legacy front end: same parameters (plus -Profile), folder,
# file names, maxRevisions, exit codes and console lines; it passes no hook, run
# directory or context and writes no manifest (D-303).
. (Join-Path $PSScriptRoot "lib\workflow.ps1")

$specDirectory = Join-Path $root "specs"

$runner = if ($RunnerScript) {
    $RunnerScript
}
else {
    Join-Path $PSScriptRoot "run-agent.ps1"
}

$validator = if ($ValidatorScript) {
    $ValidatorScript
}
else {
    Join-Path $PSScriptRoot "validate-spec.ps1"
}

$reviewer = if ($ReviewerScript) {
    $ReviewerScript
}
else {
    Join-Path $PSScriptRoot "review-spec.ps1"
}

$reviser = if ($ReviserScript) {
    $ReviserScript
}
else {
    Join-Path $PSScriptRoot "revise-spec.ps1"
}

$workflowArguments = @{
    RunnerScript    = $runner
    ValidatorScript = $validator
    ReviewerScript  = $reviewer
    ReviserScript   = $reviser
    Mode            = $Mode
    Task            = $Task
    Name            = $Name
    OutputDirectory = $specDirectory
}
if ($PSBoundParameters.ContainsKey('Model')) {
    $workflowArguments.Model = $Model
}
# -Profile is passed to the three agent scripts only when bound (FR-303).
if ($PSBoundParameters.ContainsKey('Profile')) {
    $workflowArguments.Profile = $Profile
}

$workflowResult = @{}
Invoke-SpecifyWorkflow @workflowArguments -Result $workflowResult

# A throw (a stage, a missing script, -Model with -Profile) is rethrown, so the
# trap above prints it and exits 2 as before.
if ($null -ne $workflowResult.error) {
    throw $workflowResult.error
}

exit $workflowResult.legacyExitCode
