param(
    [Parameter(Mandatory = $true)][string]$Task,
    [Parameter(Mandatory = $true)][string]$SpecFile,
    [Parameter(Mandatory = $true)][string]$ReviewFile,
    [ValidateSet("requirements", "baseline", "documentation")]
    [string]$Mode = "requirements",
    [string]$Model,
    [string]$OutputFile,
    [string]$Profile
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot

$agentFile        = Join-Path $root ".ai\agents\spec-reviser.md"
$contractFile     = Join-Path $root ".ai\rules\agent-contract.md"
$instructionsFile = Join-Path $root "AGENTS.md"
$configFile       = Join-Path $root ".ai\config.json"

foreach ($required in @(
    @{ Path = $SpecFile;         Label = "Specification file" },
    @{ Path = $ReviewFile;       Label = "Review file" },
    @{ Path = $agentFile;        Label = "Specification reviser agent" },
    @{ Path = $contractFile;     Label = "Agent contract" },
    @{ Path = $instructionsFile; Label = "AGENTS.md" }
)) {
    if (-not (Test-Path $required.Path -PathType Leaf)) {
        throw "$($required.Label) not found: $($required.Path)"
    }
}

. (Join-Path $PSScriptRoot "lib\config.ps1")
. (Join-Path $PSScriptRoot "lib\telemetry.ps1")
. (Join-Path $PSScriptRoot "lib\agent-exec.ps1")

$config = Get-HarnessRegistry -ConfigPath $configFile

$executionArguments = @{ Agent = "spec-reviser"; Registry = $config }
if ($PSBoundParameters.ContainsKey('Model'))   { $executionArguments.Model = $Model }
if ($PSBoundParameters.ContainsKey('Profile')) { $executionArguments.Profile = $Profile }
$execution = Resolve-HarnessExecution @executionArguments

$Model = "$($execution.model)".Trim()
if ([string]::IsNullOrWhiteSpace($Model)) {
    throw "Model name cannot be empty."
}

# The engine and the availability check read the model from the execution record.
$execution.model = $Model

$specContent         = Get-Content $SpecFile -Raw -Encoding UTF8
$reviewContent       = Get-Content $ReviewFile -Raw -Encoding UTF8
$agentInstructions   = Get-Content $agentFile -Raw -Encoding UTF8
$agentContract       = Get-Content $contractFile -Raw -Encoding UTF8
$projectInstructions = Get-Content $instructionsFile -Raw -Encoding UTF8

if ([string]::IsNullOrWhiteSpace($specContent))   { throw "Specification file is empty." }
if ([string]::IsNullOrWhiteSpace($reviewContent)) { throw "Review file is empty." }

Write-Host ""
Write-Host "=== Specification Reviser ===" -ForegroundColor Cyan
Write-Host "Model : $Model"
Write-Host "Mode  : $Mode"
Write-Host "Spec  : $SpecFile"
Write-Host "Review: $ReviewFile"
Write-Host ""

$built = New-SpecRevisePrompt `
    -ProjectInstructions ([string]$projectInstructions) `
    -AgentContract ([string]$agentContract) `
    -AgentInstructions ([string]$agentInstructions) `
    -Mode ([string]$Mode) `
    -Task ([string]$Task) `
    -Specification ([string]$specContent) `
    -Review ([string]$reviewContent)

$ollamaUrl = ([string]$config.ollama.url).TrimEnd('/')

# FR-010: no generation request unless Ollama is reachable and the model installed.
# Test-OllamaModel prints nothing; this script prints the legacy lines. A failed
# check writes the one telemetry record of the call (model_called false).
$availability = Test-OllamaModel `
    -Execution $execution `
    -Registry $config `
    -TelemetryRoot $root `
    -Agent "spec-reviser"

if (-not $availability.available) {
    if ($availability.category -ceq 'model_not_installed') {
        Write-Host "Model not found: $Model" -ForegroundColor Red
        Write-Host "Available models:" -ForegroundColor Yellow
        foreach ($m in @($availability.models)) { Write-Host "  - $m" }
        $availabilityProblem = "The requested Ollama model is not installed. Try: ollama pull $Model"
    }
    else {
        # Any failure of /api/tags (timeout, refused, 5xx...) keeps the legacy line.
        $availabilityProblem = "Ollama is not reachable at $ollamaUrl. Make sure Ollama is running."
        Write-Host $availabilityProblem -ForegroundColor Red
    }
    Write-Host "Category: $($availability.category)" -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($availability.hint)) { Write-Host "Hint: $($availability.hint)" -ForegroundColor Yellow }
    throw $availabilityProblem
}

Write-Host "Sending specification to reviser..." -ForegroundColor Yellow
Write-Host ""

# One line before each retry wait, so that a retry never looks like a hang. The
# hook uses only its parameters (see the hook rule in lib\agent-exec.ps1).
$retryNotice = {
    param($NextAttempt, $MaxAttempts, $RetryCategory, $WaitSeconds)
    Write-Host "Retrying (attempt $NextAttempt of $MaxAttempts) after $RetryCategory, waiting $WaitSeconds s." -ForegroundColor Yellow
}

$call = Invoke-AgentModel `
    -Execution $execution `
    -Registry $config `
    -System $built.system `
    -Prompt $built.prompt `
    -Parts $built.parts `
    -Agent "spec-reviser" `
    -TelemetryRoot $root `
    -OnRetry $retryNotice

# budgetMode warn (the default): the prompt was sent, the overflow is not silent.
if (@($call.meta.warnings) -ccontains 'budget_exceeded') {
    Write-Host "Warning: budget_exceeded (estimated $($call.meta.budget.estTokens) tokens, available $($call.meta.budget.available))." -ForegroundColor Yellow
}

if ($call.status -ne 'ok') {
    $failure = $call.error

    if ($failure.category -ceq 'empty_response' -or $failure.category -ceq 'thinking_budget_exhausted') {
        Write-Host "Category: $($failure.category)" -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($failure.hint)) { Write-Host "Hint: $($failure.hint)" -ForegroundColor Yellow }
        throw "Reviser returned an empty response."
    }

    if ($failure.category -ceq 'context_budget_exceeded') {
        Write-Host "Category: $($failure.category)" -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($failure.hint)) { Write-Host "Hint: $($failure.hint)" -ForegroundColor Yellow }
        Write-Host "Estimated $($call.meta.budget.estTokens) tokens, available $($call.meta.budget.available)." -ForegroundColor Yellow
        foreach ($section in @($call.meta.budget.sections)) {
            Write-Host "  $($section.name) ($($section.kind)): $($section.chars) characters, about $($section.estTokens) tokens" -ForegroundColor Yellow
        }
        throw "Agent execution failed."
    }

    Write-Host "Category: $($failure.category)" -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($failure.hint)) { Write-Host "Hint: $($failure.hint)" -ForegroundColor Yellow }
    throw "Ollama request failed: $($failure.category): $($failure.detail)"
}

$revision = $call.text

if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
    [System.IO.File]::WriteAllText(
        $OutputFile, $revision, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host "=== Revised Specification ===" -ForegroundColor Green
Write-Host ""

$revision
exit 0
