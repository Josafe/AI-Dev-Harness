param(
    [Parameter(Mandatory = $true)][string]$Task,
    [Parameter(Mandatory = $true)][string]$SpecFile,
    [ValidateSet("requirements", "baseline", "documentation")]
    [string]$Mode = "requirements",
    [string]$Model,
    [string]$OutputFile,
    [string]$Profile
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot

$agentFile        = Join-Path $root ".ai\agents\spec-reviewer.md"
$contractFile     = Join-Path $root ".ai\rules\agent-contract.md"
$instructionsFile = Join-Path $root "AGENTS.md"
$configFile       = Join-Path $root ".ai\config.json"

foreach ($required in @(
    @{ Path = $SpecFile;         Label = "Specification file" },
    @{ Path = $agentFile;        Label = "Specification reviewer agent" },
    @{ Path = $contractFile;     Label = "Agent contract" },
    @{ Path = $instructionsFile; Label = "AGENTS.md" }
)) {
    if (-not (Test-Path $required.Path -PathType Leaf)) {
        Write-Host "$($required.Label) not found: $($required.Path)" -ForegroundColor Red
        exit 2
    }
}

try {
    . (Join-Path $PSScriptRoot "lib\config.ps1")
    . (Join-Path $PSScriptRoot "lib\telemetry.ps1")
    . (Join-Path $PSScriptRoot "lib\agent-exec.ps1")

    $config = Get-HarnessRegistry -ConfigPath $configFile

    $executionArguments = @{ Agent = "spec-reviewer"; Registry = $config }
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
    $agentInstructions   = Get-Content $agentFile -Raw -Encoding UTF8
    $agentContract       = Get-Content $contractFile -Raw -Encoding UTF8
    $projectInstructions = Get-Content $instructionsFile -Raw -Encoding UTF8
}
catch {
    Write-Host ""
    Write-Host "=== REVIEWER INPUT ERROR ===" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 2
}

if ([string]::IsNullOrWhiteSpace($specContent)) {
    Write-Host "Specification file is empty." -ForegroundColor Red
    exit 2
}

Write-Host ""
Write-Host "=== Specification Reviewer ===" -ForegroundColor Cyan
Write-Host "Model : $Model"
Write-Host "Spec  : $SpecFile"
Write-Host ""

$built = New-SpecReviewPrompt `
    -ProjectInstructions ([string]$projectInstructions) `
    -AgentContract ([string]$agentContract) `
    -AgentInstructions ([string]$agentInstructions) `
    -Mode ([string]$Mode) `
    -Task ([string]$Task) `
    -Specification ([string]$specContent)

$ollamaUrl = ([string]$config.ollama.url).TrimEnd('/')

# FR-010: no generation request unless Ollama is reachable and the model installed.
# Test-OllamaModel prints nothing; this script prints the legacy lines. A failed
# check writes the one telemetry record of the call (model_called false).
$availability = Test-OllamaModel `
    -Execution $execution `
    -Registry $config `
    -TelemetryRoot $root `
    -Agent "spec-reviewer"

if (-not $availability.available) {
    if ($availability.category -ceq 'model_not_installed') {
        Write-Host "Model not found: $Model" -ForegroundColor Red
        Write-Host "Available models:" -ForegroundColor Yellow
        foreach ($m in @($availability.models)) { Write-Host "  - $m" }
    }
    else {
        # Any failure of /api/tags (timeout, refused, 5xx...) keeps the legacy line.
        Write-Host "Ollama is not reachable at $ollamaUrl. Make sure Ollama is running." -ForegroundColor Red
    }
    Write-Host "Category: $($availability.category)" -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($availability.hint)) { Write-Host "Hint: $($availability.hint)" -ForegroundColor Yellow }
    exit 2
}

Write-Host "Sending specification to reviewer..." -ForegroundColor Yellow
Write-Host ""

# One line before each retry wait, so that a retry never looks like a hang. The
# hook uses only its parameters (see the hook rule in lib\agent-exec.ps1).
$retryNotice = {
    param($NextAttempt, $MaxAttempts, $RetryCategory, $WaitSeconds)
    Write-Host "Retrying (attempt $NextAttempt of $MaxAttempts) after $RetryCategory, waiting $WaitSeconds s." -ForegroundColor Yellow
}

# The reviewer output format check. It returns a code when the answer has no
# valid Status section (the engine then reports format_invalid, which is not
# retried) and nothing when it is acceptable. It uses only its parameter.
$statusCheck = {
    param($ReviewText)
    if (-not [regex]::IsMatch($ReviewText, '(?im)^##\s+Status\s*\r?\n\s*(PASS|FAIL)\s*$')) { 'status_missing' }
}

try {
    $call = Invoke-AgentModel `
        -Execution $execution `
        -Registry $config `
        -System $built.system `
        -Prompt $built.prompt `
        -Parts $built.parts `
        -Agent "spec-reviewer" `
        -TelemetryRoot $root `
        -ResponseCheck $statusCheck `
        -OnRetry $retryNotice
}
catch {
    Write-Host "=== OLLAMA ERROR ===" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    exit 2
}

# budgetMode warn (the default): the prompt was sent, the overflow is not silent.
if (@($call.meta.warnings) -ccontains 'budget_exceeded') {
    Write-Host "Warning: budget_exceeded (estimated $($call.meta.budget.estTokens) tokens, available $($call.meta.budget.available))." -ForegroundColor Yellow
}

if ($call.status -ne 'ok') {
    $failure = $call.error

    if ($failure.category -ceq 'empty_response' -or $failure.category -ceq 'thinking_budget_exhausted') {
        Write-Host "=== REVIEWER OUTPUT ERROR ===" -ForegroundColor Red
        Write-Host "Reviewer returned an empty response." -ForegroundColor Red
        Write-Host "Category: $($failure.category)" -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($failure.hint)) { Write-Host "Hint: $($failure.hint)" -ForegroundColor Yellow }
        exit 2
    }

    if ($failure.category -ceq 'format_invalid') {
        Write-Host "=== REVIEW VALIDATION ERROR ===" -ForegroundColor Red
        Write-Host "Reviewer did not return a valid Status section." -ForegroundColor Red
        Write-Host ""
        Write-Host "Expected:"
        Write-Host ""
        Write-Host "## Status"
        Write-Host "PASS or FAIL"
        Write-Host "Category: $($failure.category)" -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($failure.hint)) { Write-Host "Hint: $($failure.hint)" -ForegroundColor Yellow }
        exit 2
    }

    if ($failure.category -ceq 'context_budget_exceeded') {
        Write-Host "Category: $($failure.category)" -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($failure.hint)) { Write-Host "Hint: $($failure.hint)" -ForegroundColor Yellow }
        Write-Host "Estimated $($call.meta.budget.estTokens) tokens, available $($call.meta.budget.available)." -ForegroundColor Yellow
        foreach ($section in @($call.meta.budget.sections)) {
            Write-Host "  $($section.name) ($($section.kind)): $($section.chars) characters, about $($section.estTokens) tokens" -ForegroundColor Yellow
        }
        Write-Host "Agent execution failed." -ForegroundColor Red
        exit 2
    }

    Write-Host "=== OLLAMA ERROR ===" -ForegroundColor Red
    Write-Host "Ollama request failed: $($failure.category): $($failure.detail)" -ForegroundColor Yellow
    Write-Host "Category: $($failure.category)" -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($failure.hint)) { Write-Host "Hint: $($failure.hint)" -ForegroundColor Yellow }
    exit 2
}

$review = $call.text

$statusMatch = [regex]::Match(
    $review,
    '(?im)^##\s+Status\s*\r?\n\s*(PASS|FAIL)\s*$'
)
$status = $statusMatch.Groups[1].Value.ToUpperInvariant()

if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
    try {
        [System.IO.File]::WriteAllText(
            $OutputFile, $review, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        Write-Host "=== REVIEW OUTPUT ERROR ===" -ForegroundColor Red
        Write-Host "Could not write review file: $OutputFile" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        exit 2
    }
}

Write-Host ""
Write-Host "Review Status: $status" -ForegroundColor $(if ($status -eq "PASS") { "Green" } else { "Red" })
Write-Host ""

$review

if ($status -eq "FAIL") { exit 1 }
exit 0
