param(
    [string]$Agent,
    [string]$Task,
    [string]$Model,
    [string]$OutputFile,
    [string]$ContextFile,
    [string]$Profile
)

$ErrorActionPreference = "Stop"

# Cualquier error termina con mensaje limpio y exit code 1 explícito
trap {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

. (Join-Path $PSScriptRoot "lib\config.ps1")
. (Join-Path $PSScriptRoot "lib\telemetry.ps1")
. (Join-Path $PSScriptRoot "lib\agent-exec.ps1")

# ---------- 1. Validación de entrada (sin tocar config ni Ollama) ----------

if ([string]::IsNullOrWhiteSpace($Agent)) {
    throw "Agent is required. Example: -Agent spec"
}

if ([string]::IsNullOrWhiteSpace($Task)) {
    throw "Task is required. Example: -Task 'Create a specification...'"
}

if ($Agent -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]*$') {
    throw "Invalid agent name: $Agent"
}

# ---------- 2. Ficheros del proyecto ----------

$root             = Split-Path -Parent $PSScriptRoot
$agentFile        = Join-Path $root ".ai\agents\$Agent.md"
$rulesFile        = Join-Path $root ".ai\rules\agent-contract.md"
$instructionsFile = Join-Path $root "AGENTS.md"
$configFile       = Join-Path $root ".ai\config.json"

if (-not (Test-Path $agentFile -PathType Leaf)) {
    throw "Agent not found: $agentFile"
}
if (-not (Test-Path $rulesFile -PathType Leaf)) {
    throw "Agent contract not found: $rulesFile"
}
if (-not (Test-Path $instructionsFile -PathType Leaf)) {
    throw "AGENTS.md not found: $instructionsFile"
}

# ---------- 3. Configuración y modelo ----------

$config = Get-HarnessRegistry -ConfigPath $configFile

$executionArguments = @{ Agent = $Agent; Registry = $config }
if ($PSBoundParameters.ContainsKey('Model'))   { $executionArguments.Model = $Model }
if ($PSBoundParameters.ContainsKey('Profile')) { $executionArguments.Profile = $Profile }
$execution = Resolve-HarnessExecution @executionArguments

$Model = "$($execution.model)".Trim()

if ([string]::IsNullOrWhiteSpace($Model)) {
    throw "Model name cannot be empty."
}

# The engine and the availability check read the model from the execution record.
$execution.model = $Model

$ollamaUrl = ([string]$config.ollama.url).TrimEnd('/')
$telemetryRoot = Split-Path -Parent $PSScriptRoot

Write-Host ""
Write-Host "=== AI Development Harness ===" -ForegroundColor Cyan
Write-Host "Agent : $Agent"
Write-Host "Model : $Model"
Write-Host "Server: $ollamaUrl"
Write-Host ""

# ---------- 4. Comprobar Ollama y el modelo ----------
# Test-OllamaModel prints nothing; this script prints the legacy lines. A failed
# check writes the one telemetry record of the call (model_called false).

$availability = Test-OllamaModel `
    -Execution $execution `
    -Registry $config `
    -TelemetryRoot $telemetryRoot `
    -Agent $Agent

if (-not $availability.available) {
    if ($availability.category -ceq 'model_not_installed') {
        Write-Host "Model not found: $Model" -ForegroundColor Red
        Write-Host "Available models:" -ForegroundColor Yellow
        foreach ($m in @($availability.models)) { Write-Host "  - $m" }
        Write-Host "Category: $($availability.category)" -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($availability.hint)) { Write-Host "Hint: $($availability.hint)" -ForegroundColor Yellow }
        throw "The requested Ollama model is not installed. Try: ollama pull $Model"
    }

    # Any failure of /api/tags (timeout, refused, 5xx...) keeps the legacy line.
    Write-Host "Category: $($availability.category)" -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($availability.hint)) { Write-Host "Hint: $($availability.hint)" -ForegroundColor Yellow }
    throw "Ollama is not reachable at $ollamaUrl. Make sure Ollama is running."
}

# ---------- 5. Construir prompt ----------

$agentInstructions   = Get-Content $agentFile -Raw -Encoding UTF8
$agentContract       = Get-Content $rulesFile -Raw -Encoding UTF8
$projectInstructions = Get-Content $instructionsFile -Raw -Encoding UTF8

$promptArguments = @{
    ProjectInstructions = [string]$projectInstructions
    AgentContract       = [string]$agentContract
    AgentInstructions   = [string]$agentInstructions
    Task                = [string]$Task
}

if (-not [string]::IsNullOrWhiteSpace($ContextFile)) {
    if (-not (Test-Path $ContextFile -PathType Leaf)) {
        throw "Context file not found: $ContextFile"
    }

    $repositoryContext = Get-Content $ContextFile -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($repositoryContext)) {
        throw "Context file is empty: $ContextFile"
    }

    $promptArguments.RepositoryContext = [string]$repositoryContext
}

$built = New-RunAgentPrompt @promptArguments

# ---------- 6. Llamada a Ollama ----------

Write-Host "Sending task to Ollama..." -ForegroundColor Yellow
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
    -Agent $Agent `
    -TelemetryRoot $telemetryRoot `
    -OnRetry $retryNotice

# budgetMode warn (the default): the prompt was sent, the overflow is not silent.
if (@($call.meta.warnings) -ccontains 'budget_exceeded') {
    Write-Host "Warning: budget_exceeded (estimated $($call.meta.budget.estTokens) tokens, available $($call.meta.budget.available))." -ForegroundColor Yellow
}

# Prompt truncation (FR-316): the server may cut a prompt that does not fit the window
# with HTTP 200. The strong rule is printed first; the old rule is weak. Both are
# warnings only: the outcome of the call is not changed.
if (@($call.meta.warnings) -ccontains 'prompt_truncation_detected') {
    Write-Host "Warning: prompt_truncation_detected (the prompt of $($call.meta.promptChars) characters was evaluated as only $($call.meta.promptEvalCount) tokens: the server probably cut it, so the answer may ignore part of the input)." -ForegroundColor Yellow
}
if (@($call.meta.warnings) -ccontains 'possible_prompt_truncation') {
    Write-Host "Warning: possible_prompt_truncation (weak signal: the evaluated tokens, $($call.meta.promptEvalCount), reach the context window minus the reserved output tokens; it also fires on healthy prompts)." -ForegroundColor Yellow
}

# ---------- 7. Resultado ----------

if ($call.status -ne 'ok') {
    $failure = $call.error

    if ($failure.category -ceq 'empty_response' -or $failure.category -ceq 'thinking_budget_exhausted') {
        Write-Host "Category: $($failure.category)" -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($failure.hint)) { Write-Host "Hint: $($failure.hint)" -ForegroundColor Yellow }
        throw "Agent returned an empty response."
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

    Write-Host "=== OLLAMA ERROR ===" -ForegroundColor Red

    if ($null -ne $failure.httpStatus) {
        Write-Host "Status: $([int]$failure.httpStatus)" -ForegroundColor Red
    }
    if (-not [string]::IsNullOrWhiteSpace($failure.detail)) {
        Write-Host $failure.detail -ForegroundColor Yellow
    }
    Write-Host "Category: $($failure.category)" -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($failure.hint)) { Write-Host "Hint: $($failure.hint)" -ForegroundColor Yellow }

    Write-Host "=== END OLLAMA ERROR ===" -ForegroundColor Red
    throw "Agent execution failed."
}

$result = $call.text

Write-Host "=== Agent Result ===" -ForegroundColor Green
Write-Host ""

if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
    $outputDirectory = Split-Path -Parent $OutputFile

    if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and
        -not (Test-Path $outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText(
        $OutputFile, $result, (New-Object System.Text.UTF8Encoding($false)))

    Write-Host "Output : $OutputFile" -ForegroundColor DarkGray
}

$result
exit 0