function Get-HarnessConfig {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    if (-not (Test-Path $ConfigPath -PathType Leaf)) {
        return [pscustomobject]@{}
    }

    try {
        return Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Invalid JSON in config file: $ConfigPath. $($_.Exception.Message)"
    }
}

function Get-ConfigValue {
    param($Object, [string]$Name, $Default)

    if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and
        $null -ne $Object.$Name) {
        return $Object.$Name
    }
    return $Default
}

function Resolve-HarnessModel {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [bool]$ModelWasProvided,
        [string]$ExplicitModel,
        $Config
    )

    # 1. Parámetro explícito (aunque venga vacío: se valida, no se sustituye)
    if ($ModelWasProvided) { return $ExplicitModel }

    # 2. Variable de entorno
    if (-not [string]::IsNullOrWhiteSpace($env:AI_HARNESS_MODEL)) {
        return $env:AI_HARNESS_MODEL
    }

    # 3. Modelo específico del agente
    $agentModels = Get-ConfigValue $Config "agentModels" $null
    if ($agentModels -and $agentModels.PSObject.Properties[$Agent]) {
        return $agentModels.$Agent
    }

    # 4. Modelo por defecto
    $default = Get-ConfigValue $Config "defaultModel" $null
    if ($default) { return $default }

    throw "No model configured. Use -Model, set AI_HARNESS_MODEL, or define defaultModel in .ai\config.json."
}
function Invoke-HarnessGenerate {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$System,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)]$Config,
        [string]$TelemetryAgent,
        [string]$TelemetryRoot
    )

    $ollamaUrl     = (Get-ConfigValue $Config "ollamaUrl" "http://localhost:11434").TrimEnd('/')
    $timeoutSec    = [int](Get-ConfigValue $Config "timeoutSec" 600)
    $stripThinking = [bool](Get-ConfigValue $Config "stripThinking" $true)
    $options       = Get-ConfigValue $Config "options" $null

    $payload = @{ model = $Model; system = $System; prompt = $Prompt; stream = $false }
    if ($options) { $payload.options = $options }

    $json  = $payload | ConvertTo-Json -Depth 10
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)

    # Telemetry only when both parameters are given (FR-011): exactly one record
    # per request actually sent, written before an error is rethrown. Calls
    # without them behave as before. Needs lib\telemetry.ps1 dot-sourced.
    $writeTelemetry = (-not [string]::IsNullOrWhiteSpace($TelemetryAgent)) -and
        (-not [string]::IsNullOrWhiteSpace($TelemetryRoot))
    $startedAt = [datetime]::UtcNow

    try {
        $response = Invoke-RestMethod `
            -Uri "$ollamaUrl/api/generate" `
            -Method Post `
            -ContentType "application/json; charset=utf-8" `
            -Body $bytes `
            -TimeoutSec $timeoutSec
    }
    catch {
        $requestError = $_.Exception.Message

        if ($writeTelemetry) {
            Write-HarnessModelTelemetry -Root $TelemetryRoot -Agent $TelemetryAgent -Model $Model `
                -StartedAt $startedAt -Status "error" -ErrorMessage $requestError
        }

        throw "Ollama request failed: $requestError"
    }

    if ($writeTelemetry) {
        Write-HarnessModelTelemetry -Root $TelemetryRoot -Agent $TelemetryAgent -Model $Model `
            -StartedAt $startedAt -Status "success" -Response $response
    }

    $text = "$($response.response)"
    if ($stripThinking) {
        $text = [regex]::Replace($text, '(?s)<think>.*?</think>\s*', '')
    }
    return $text.Trim()
}

# Same check as run-agent.ps1 (FR-010): Ollama is reachable and the model is
# installed (exact name, case-insensitive). Prints the problem and returns it;
# returns nothing when the model is available. Sends no generation request.
function Test-HarnessModelAvailable {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)]$Config
    )

    $ollamaUrl = (Get-ConfigValue $Config "ollamaUrl" "http://localhost:11434").TrimEnd('/')

    try {
        $ollamaTags = Invoke-RestMethod -Uri "$ollamaUrl/api/tags" -Method Get -TimeoutSec 15
    }
    catch {
        $problem = "Ollama is not reachable at $ollamaUrl. Make sure Ollama is running."
        Write-Host $problem -ForegroundColor Red
        return $problem
    }

    $availableModels = @($ollamaTags.models | ForEach-Object { $_.name })

    if ($availableModels -notcontains $Model) {
        Write-Host "Model not found: $Model" -ForegroundColor Red
        Write-Host "Available models:" -ForegroundColor Yellow
        foreach ($m in $availableModels) { Write-Host "  - $m" }
        return "The requested Ollama model is not installed. Try: ollama pull $Model"
    }
}