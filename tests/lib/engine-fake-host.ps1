<#
.SYNOPSIS
    Shared helper of the three engine call-site suites (Phase 3, FR-315). Not a
    suite: it is not named test-*, so scripts\test-all.ps1 never runs it.

.DESCRIPTION
    Dot-sourced by scripts\test-engine-callsites-run-agent.ps1,
    test-engine-callsites-review-spec.ps1 and test-engine-callsites-revise-spec.ps1.
    The caller sets $scriptsDirectory before dot-sourcing. This file holds what the
    old single suite held outside its cases: the engine fake host, New-TempHarness,
    Invoke-Case, the four guards (Phase 0 FR-018 and Phase 1), the assertion helpers,
    the configurations and data the cases share, and the summary.

    The four guards:
      1. Test-TempHarnessConfig checks the temporary config before every case (the
         Ollama URL must be http://127.0.0.1:9); at startup Initialize-EngineSuite
         proves that it rejects a missing file, invalid JSON, http://localhost:11434
         and any other URL, in the v1 and the v2 form.
      2. The fake host exits 97 unless Invoke-RestMethod resolves to the fake.
      3. The fake accepts only URIs starting with http://127.0.0.1:9/ and records
         any other as a violation, refused before any request.
      4. A static scan refuses to start when the copied scripts hold another HTTP
         route, and when Invoke-RestMethod is called from anywhere but the places
         that are allowed to call it.
#>

if ([string]::IsNullOrWhiteSpace($scriptsDirectory)) { throw "engine-fake-host.ps1 must be dot-sourced by a suite that sets `$scriptsDirectory." }

$root = Split-Path -Parent $scriptsDirectory
$goldenDirectory = Join-Path $root "tests\golden"
$inputsDirectory = Join-Path $goldenDirectory "inputs"
$mocksDirectory = Join-Path $root "tests\mocks"
$powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$fakeUrl = "http://127.0.0.1:9"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

foreach ($path in @(
        (Join-Path $scriptsDirectory "run-agent.ps1"),
        (Join-Path $scriptsDirectory "review-spec.ps1"),
        (Join-Path $scriptsDirectory "revise-spec.ps1"),
        (Join-Path $scriptsDirectory "lib\config.ps1"),
        (Join-Path $scriptsDirectory "lib\telemetry.ps1"),
        (Join-Path $scriptsDirectory "lib\agent-exec.ps1"),
        (Join-Path $mocksDirectory "fake-web-response.ps1"),
        $goldenDirectory,
        $inputsDirectory,
        $powerShellExe)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required path not found: $path" }
}

$script:passed = 0
$script:failed = 0

$originalModelVariable = $env:AI_HARNESS_MODEL
$originalRunId = $env:AI_HARNESS_RUN_ID
$env:AI_HARNESS_MODEL = $null
$env:AI_HARNESS_RUN_ID = $null

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-harness-engine-callsites-" + [guid]::NewGuid().ToString())
$harnessRoot = Join-Path $tempRoot "harness"
$harnessConfig = Join-Path $harnessRoot ".ai\config.json"
$harnessLogs = Join-Path $harnessRoot "logs"
$casesDirectory = Join-Path $tempRoot "cases"
$fakeHost = Join-Path $tempRoot "fake-host.ps1"

# ---------------------------------------------------------------------------
# Bookkeeping and assertions
# ---------------------------------------------------------------------------

function Test-Case {
    param([string]$Name, [scriptblock]$Body)

    try {
        & $Body
        $script:passed++
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    catch {
        $script:failed++
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Stop-Suite {
    param([string]$Reason)

    Write-Host ""
    Write-Host "SAFETY GUARD FAILED, no further script is started: $Reason" -ForegroundColor Red
    Write-Host "Passed: $script:passed"
    Write-Host "Failed: $($script:failed + 1)"
    Write-Host "STATUS: FAIL" -ForegroundColor Red
    exit 1
}

function Assert-Equal {
    param([string]$What, $Expected, $Actual)
    if (-not ("$Expected" -ceq "$Actual")) { throw "$What : expected '$Expected', got '$Actual'" }
}

function Assert-True {
    param([string]$What, $Condition)
    if (-not $Condition) { throw "$What : condition is false" }
}

# CRLF -> LF and nothing else (FR-203 rule 2).
function ConvertTo-NormalizedEol {
    param([string]$Text)
    return $Text.Replace("`r`n", "`n")
}

function Read-Utf8 {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, $utf8NoBom)
}

function ConvertFrom-Base64Utf8 {
    param($Text)
    if ($null -eq $Text -or "$Text" -eq "") { return "" }
    return $utf8NoBom.GetString([System.Convert]::FromBase64String([string]$Text))
}

# ---------------------------------------------------------------------------
# Guard 1: the temporary configuration must point at the fake URL
# ---------------------------------------------------------------------------

function Test-TempHarnessConfig {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { $config = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json }
    catch { return $false }
    if ($null -eq $config) { return $false }

    $url = $null
    if ($null -ne $config.PSObject.Properties["schemaVersion"]) {
        if ($null -ne $config.PSObject.Properties["ollama"] -and $null -ne $config.ollama.PSObject.Properties["url"]) { $url = $config.ollama.url }
    }
    elseif ($null -ne $config.PSObject.Properties["ollamaUrl"]) { $url = $config.ollamaUrl }
    if ($null -eq $url) { return $false }
    return ([string]$url -ceq $fakeUrl)
}

# ---------------------------------------------------------------------------
# Temporary harness root and the engine fake host
# ---------------------------------------------------------------------------

function New-TempHarness {
    foreach ($directory in @("scripts\lib", ".ai\agents", ".ai\rules")) {
        [void][System.IO.Directory]::CreateDirectory((Join-Path $harnessRoot $directory))
    }
    [void][System.IO.Directory]::CreateDirectory($casesDirectory)
    [void][System.IO.Directory]::CreateDirectory((Join-Path $tempRoot "mocks"))

    foreach ($scriptName in @("run-agent.ps1", "review-spec.ps1", "revise-spec.ps1")) {
        Copy-Item -LiteralPath (Join-Path $scriptsDirectory $scriptName) -Destination (Join-Path $harnessRoot "scripts\$scriptName")
    }
    Get-ChildItem -LiteralPath (Join-Path $scriptsDirectory "lib") -Filter "*.ps1" -File |
        Where-Object { $_.Extension -eq ".ps1" } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $harnessRoot "scripts\lib\$($_.Name)") }
    Copy-Item -LiteralPath (Join-Path $mocksDirectory "fake-web-response.ps1") -Destination (Join-Path $tempRoot "mocks\fake-web-response.ps1")

    # The golden inputs are the project files of the agent: bytes copied unchanged.
    Copy-Item -LiteralPath (Join-Path $inputsDirectory "project-instructions.txt") -Destination (Join-Path $harnessRoot "AGENTS.md")
    Copy-Item -LiteralPath (Join-Path $inputsDirectory "agent-contract.txt") -Destination (Join-Path $harnessRoot ".ai\rules\agent-contract.md")
    Copy-Item -LiteralPath (Join-Path $inputsDirectory "role-a.txt") -Destination (Join-Path $harnessRoot ".ai\agents\spec.md")
    Copy-Item -LiteralPath (Join-Path $inputsDirectory "role-b.txt") -Destination (Join-Path $harnessRoot ".ai\agents\developer.md")
    # The reviewer and the reviser read the same fixture texts as their agent files.
    Copy-Item -LiteralPath (Join-Path $inputsDirectory "role-a.txt") -Destination (Join-Path $harnessRoot ".ai\agents\spec-reviewer.md")
    Copy-Item -LiteralPath (Join-Path $inputsDirectory "role-b.txt") -Destination (Join-Path $harnessRoot ".ai\agents\spec-reviser.md")
    Copy-Item -LiteralPath (Join-Path $inputsDirectory "spec.txt") -Destination (Join-Path $casesDirectory "spec-input.md")
    Copy-Item -LiteralPath (Join-Path $inputsDirectory "review.txt") -Destination (Join-Path $casesDirectory "review-input.md")
    Copy-Item -LiteralPath (Join-Path $inputsDirectory "repo-context.txt") -Destination (Join-Path $casesDirectory "repo-context.txt")
    Copy-Item -LiteralPath (Join-Path $inputsDirectory "task.txt") -Destination (Join-Path $casesDirectory "task.txt")

    $fakeHostSource = @'
param([Parameter(Mandatory = $true)][string]$ScenarioFile)

$ErrorActionPreference = "Stop"
$global:FakeScenario = [System.IO.File]::ReadAllText($ScenarioFile) | ConvertFrom-Json
$global:FakeIndex = @{ tags = 0; generate = 0 }

if ($global:FakeScenario.typedExceptions) {
    . $global:FakeScenario.webResponseMock
}

function global:Write-FakeCall {
    param([hashtable]$Entry)
    $line = ([pscustomobject]$Entry | ConvertTo-Json -Compress) + "`r`n"
    [System.IO.File]::AppendAllText($global:FakeScenario.callLog, $line, (New-Object System.Text.UTF8Encoding($false)))
}

# Exactly the five parameters of the Phase 0 and Phase 1 fake hosts: an extra one in
# the engine's call would make every case of the suite fail.
function global:Invoke-RestMethod {
    param(
        [string]$Uri,
        [string]$Method = "Get",
        $Body,
        [string]$ContentType,
        [int]$TimeoutSec
    )

    # A simple function silently collects any parameter it does not declare (even
    # -ErrorAction or -Headers) in $args, so the check is explicit: the engine must call
    # the cmdlet with exactly the five declared parameters.
    if ($args.Count -gt 0) {
        Write-FakeCall @{ uri = $Uri; method = $Method; violation = $false; extraArgs = $args.Count }
        throw "Fake Invoke-RestMethod: parameters outside the five declared ones"
    }

    # Guard 3: URL allowlist. Anything else is refused before any request.
    if (-not $Uri.StartsWith("http://127.0.0.1:9/", [System.StringComparison]::Ordinal)) {
        Write-FakeCall @{ uri = $Uri; method = $Method; violation = $true }
        throw "Fake Invoke-RestMethod: URI not allowed, no request sent: $Uri"
    }

    $entry = @{ uri = $Uri; method = $Method; violation = $false; extraArgs = 0; timeoutSec = $TimeoutSec; contentType = [string]$ContentType }
    if ($Body -is [byte[]]) {
        $request = [System.Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        $names = @($request.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
        $entry.members = ($names -join ",")
        $entry.model = [string]$request.model
        $entry.hasPrompt = ($null -ne $request.PSObject.Properties["prompt"])
        $entry.hasThink = ($null -ne $request.PSObject.Properties["think"])
        $entry.thinkValue = $null
        if ($entry.hasThink) { $entry.thinkValue = $request.think }
        $entry.streamIsBool = ($request.stream -is [bool])
        $entry.streamValue = [string]$request.stream
        $pairs = ""
        if ($null -ne $request.PSObject.Properties["options"]) {
            $pairs = (@($request.options.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ";")
        }
        $entry.optionsPairs = $pairs
        $entry.systemB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$request.system))
        $entry.promptB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$request.prompt))
    }
    Write-FakeCall $entry

    $route = $null
    if ($Uri -ceq "http://127.0.0.1:9/api/tags") { $route = "tags" }
    elseif ($Uri -ceq "http://127.0.0.1:9/api/generate") { $route = "generate" }
    else { throw "Fake Invoke-RestMethod: unknown route: $Uri" }

    $section = $global:FakeScenario.$route
    $steps = @($section.steps)
    $position = $global:FakeIndex[$route]
    $global:FakeIndex[$route] = $position + 1
    if ($position -ge $steps.Count) {
        if ($section.repeatLast -and $steps.Count -gt 0) { $position = $steps.Count - 1 }
        else { throw "Fake Invoke-RestMethod: no step left for $route (call $($position + 1))" }
    }
    $step = $steps[$position]

    switch ([string]$step.kind) {
        "ok" {
            if ($route -ceq "tags") {
                return [pscustomobject]@{ models = @($step.models | ForEach-Object { [pscustomobject]@{ name = [string]$_ } }) }
            }
            $answer = [ordered]@{
                response             = [string]$step.response
                total_duration       = 1000
                load_duration        = 100
                prompt_eval_count    = 5
                prompt_eval_duration = 200
                eval_count           = 10
                eval_duration        = 300
            }
            if ($step.doneReason) { $answer.done_reason = [string]$step.doneReason }
            if ($step.thinking) { $answer.thinking = [string]$step.thinking }
            return [pscustomobject]$answer
        }
        "http" { throw (New-FakeHttpWebException -StatusCode ([int]$step.status) -Body ([string]$step.body)) }
        "status" { throw (New-FakeStatusWebException -Status ([System.Net.WebExceptionStatus][string]$step.webStatus)) }
        "plain" { throw "Fake Invoke-RestMethod: plain failure" }
        default { throw "Fake Invoke-RestMethod: unknown step kind" }
    }
}

# Guard 2: the name must resolve to the fake function, or nothing runs.
if ((Get-Command Invoke-RestMethod).CommandType -ne [System.Management.Automation.CommandTypes]::Function) {
    Write-Host "FAKE-HOST: Invoke-RestMethod is NOT the fake function"
    exit 97
}
Write-Host "FAKE-HOST: fake Invoke-RestMethod active"

Remove-Item Env:\AI_HARNESS_MODEL -ErrorAction SilentlyContinue
Remove-Item Env:\AI_HARNESS_RUN_ID -ErrorAction SilentlyContinue
if ($global:FakeScenario.runId) { $env:AI_HARNESS_RUN_ID = [string]$global:FakeScenario.runId }

$arguments = @{}
foreach ($property in $global:FakeScenario.arguments.PSObject.Properties) {
    $arguments[$property.Name] = [string]$property.Value
}
if ($global:FakeScenario.taskFile) {
    $arguments["Task"] = [System.IO.File]::ReadAllText($global:FakeScenario.taskFile, (New-Object System.Text.UTF8Encoding($false)))
}

$exitCode = 0
try {
    & $global:FakeScenario.script @arguments
    $exitCode = $LASTEXITCODE
}
catch {
    # A script that ends with a throw (revise-spec.ps1): its own message is printed
    # so that the harness's wording can be asserted; the exit code is non-zero.
    Write-Host "FAKE-HOST: unhandled error"
    Write-Host "FAKE-HOST-ERROR: $($_.Exception.Message)"
    $exitCode = 1
}
exit $exitCode
'@
    [System.IO.File]::WriteAllText($fakeHost, $fakeHostSource, $utf8NoBom)
}

# Guard 4: no other HTTP route in the copied scripts, and Invoke-RestMethod is called
# only where it is allowed to be called.
function Get-ForbiddenRoutes {
    $copied = @(Get-ChildItem -LiteralPath (Join-Path $harnessRoot "scripts") -Filter "*.ps1" -File -Recurse)
    $found = @()
    $restCalls = @()
    foreach ($file in $copied) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        foreach ($literal in @("Microsoft.PowerShell.Utility\Invoke-RestMethod", "Invoke-WebRequest",
                "System.Net.WebClient", "System.Net.WebRequest", "Net.WebClient", "HttpWebRequest", "HttpClient",
                "TcpClient", "Start-BitsTransfer")) {
            if ($text.IndexOf($literal, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $found += "$($file.Name): $literal"
            }
        }
        foreach ($match in [regex]::Matches($text, '(?im)(?<![\w-])(irm|iwr|curl|wget)(?![\w-])')) {
            $found += "$($file.Name): alias $($match.Value)"
        }
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { $found += "$($file.Name): parse errors" }
        foreach ($command in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            if ([string]$command.GetCommandName() -ieq "Invoke-RestMethod") {
                $owner = $command.Parent
                while ($null -ne $owner -and -not ($owner -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $owner = $owner.Parent }
                $ownerName = "(script)"
                if ($null -ne $owner) { $ownerName = $owner.Name }
                $restCalls += "$($file.Name):$ownerName"
            }
        }
    }
    return @{ Files = $copied.Count; Found = $found; RestCalls = $restCalls }
}

# ---------------------------------------------------------------------------
# One case: one script in one fake host
# ---------------------------------------------------------------------------

function New-Step {
    param([string]$Kind, [hashtable]$Fields = @{})
    $step = [ordered]@{ kind = $Kind }
    foreach ($key in $Fields.Keys) { $step[$key] = $Fields[$key] }
    return $step
}

function Invoke-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ConfigText,
        [string]$Script = "run-agent.ps1",
        [hashtable]$Arguments = @{},
        [string]$TaskFile = "",
        [object[]]$TagsSteps = @(),
        [object[]]$GenerateSteps = @(),
        [switch]$RepeatLastGenerate,
        [switch]$TypedExceptions,
        [string]$RunId = ""
    )

    [System.IO.File]::WriteAllText($harnessConfig, $ConfigText, $utf8NoBom)

    # Guard 1 before every case.
    if (-not (Test-TempHarnessConfig -Path $harnessConfig)) {
        Stop-Suite "the temporary .ai\config.json is missing, invalid or not $fakeUrl"
    }

    if (Test-Path -LiteralPath $harnessLogs) { Remove-Item -LiteralPath $harnessLogs -Recurse -Force }
    $callLog = Join-Path $casesDirectory "$Name.calls.jsonl"
    $scenarioFile = Join-Path $casesDirectory "$Name.scenario.json"
    $outputFile = Join-Path $casesDirectory "$Name.output.md"
    foreach ($file in @($callLog, $outputFile)) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }

    $scriptArguments = [ordered]@{}
    if ($Script -ceq "run-agent.ps1") {
        $scriptArguments.Agent = "spec"
        $scriptArguments.Task = "Stub task for the engine call-site suite."
        $scriptArguments.OutputFile = $outputFile
    }
    if ($Script -ceq "review-spec.ps1" -or $Script -ceq "revise-spec.ps1") {
        $scriptArguments.Task = "Stub task for the engine call-site suite."
        $scriptArguments.SpecFile = (Join-Path $casesDirectory "spec-input.md")
        if ($Script -ceq "revise-spec.ps1") { $scriptArguments.ReviewFile = (Join-Path $casesDirectory "review-input.md") }
        $scriptArguments.OutputFile = $outputFile
    }
    foreach ($key in $Arguments.Keys) { $scriptArguments[$key] = $Arguments[$key] }

    $scenario = [ordered]@{
        script           = (Join-Path $harnessRoot "scripts\$Script")
        arguments        = $scriptArguments
        taskFile         = $TaskFile
        callLog          = $callLog
        typedExceptions  = [bool]$TypedExceptions
        runId            = $RunId
        webResponseMock  = (Join-Path $tempRoot "mocks\fake-web-response.ps1")
        tags             = [ordered]@{ repeatLast = $false; steps = @($TagsSteps) }
        generate         = [ordered]@{ repeatLast = [bool]$RepeatLastGenerate; steps = @($GenerateSteps) }
    }
    [System.IO.File]::WriteAllText($scenarioFile, ($scenario | ConvertTo-Json -Depth 8), $utf8NoBom)

    # stderr error records are PowerShell text: dropped, never asserted on.
    $ErrorActionPreference = "Continue"
    try {
        $raw = @(& $powerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $fakeHost -ScenarioFile $scenarioFile 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = "Stop"
    }

    $lines = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })

    $calls = @()
    if (Test-Path -LiteralPath $callLog -PathType Leaf) {
        $calls = @([System.IO.File]::ReadAllLines($callLog) | Where-Object { $_ -ne "" } | ForEach-Object { $_ | ConvertFrom-Json })
    }

    $telemetry = @()
    $jsonl = Join-Path $harnessLogs "model-calls.jsonl"
    if (Test-Path -LiteralPath $jsonl -PathType Leaf) {
        $telemetry = @([System.IO.File]::ReadAllLines($jsonl) | Where-Object { $_.Trim() -ne "" } | ForEach-Object { $_ | ConvertFrom-Json })
    }

    return [pscustomobject]@{
        ExitCode   = $exitCode
        Lines      = $lines
        Calls      = $calls
        Telemetry  = $telemetry
        OutputFile = $outputFile
        Output     = $(if (Test-Path -LiteralPath $outputFile -PathType Leaf) { [System.IO.File]::ReadAllText($outputFile) } else { $null })
        FakeActive = ($lines -ccontains "FAKE-HOST: fake Invoke-RestMethod active")
    }
}

# Guards 2 and 3, checked for every case.
function Assert-Guards {
    param($Run)

    if ($Run.ExitCode -eq 97) { throw "guard 2: the fake host reported that the fake was not active (exit 97)" }
    if (-not $Run.FakeActive) { throw "guard 2: the child did not report the fake as active" }
    $violations = @($Run.Calls | Where-Object { $_.violation })
    if ($violations.Count -gt 0) { throw "guard 3: URL allowlist violations: " + (($violations | ForEach-Object { $_.uri }) -join ", ") }
    $extra = @($Run.Calls | Where-Object { $_.extraArgs -gt 0 })
    if ($extra.Count -gt 0) { throw "the engine called Invoke-RestMethod with parameters outside -Uri -Method -Body -ContentType -TimeoutSec ($($extra.Count) calls)" }
}

function Get-Route {
    param($Run, [string]$Route)
    return @($Run.Calls | Where-Object { -not $_.violation -and $_.uri -ceq "$fakeUrl/api/$Route" })
}

# /api/generate requests that carry a prompt (the generations).
function Get-Generations {
    param($Run)
    return @(@(Get-Route $Run "generate") | Where-Object { $_.hasPrompt })
}

# /api/generate requests without a prompt (warm-ups).
function Get-Warmups {
    param($Run)
    return @(@(Get-Route $Run "generate") | Where-Object { -not $_.hasPrompt })
}

function Assert-Line {
    param($Run, [string]$Text)
    if (@($Run.Lines | Where-Object { $_.Contains($Text) }).Count -eq 0) { throw "missing a line containing: $Text" }
}

function Assert-ExactLine {
    param($Run, [string]$Text)
    if (-not ($Run.Lines -ccontains $Text)) { throw "missing the line: $Text" }
}

function Assert-NoLine {
    param($Run, [string]$Text)
    if (@($Run.Lines | Where-Object { $_.Contains($Text) }).Count -ne 0) { throw "unexpected line containing: $Text" }
}

function Assert-OneRecord {
    param($Run, [string]$Status, [string]$Category, [bool]$ModelCalled, [string]$Agent = "spec")
    if ($Run.Telemetry.Count -ne 1) { throw "expected exactly one telemetry line, got $($Run.Telemetry.Count)" }
    $record = $Run.Telemetry[0]
    Assert-Equal "telemetry agent" $Agent $record.agent
    Assert-Equal "telemetry status" $Status $record.status
    Assert-Equal "telemetry error_category" $Category $record.error_category
    Assert-Equal "telemetry model_called" $ModelCalled $record.model_called
    Assert-Equal "telemetry schema_version" 2 $record.schema_version
}

function Assert-NoRequestNoRecord {
    param($Run)
    if ($Run.Calls.Count -ne 0) { throw "expected no request, got $($Run.Calls.Count)" }
    if ($Run.Telemetry.Count -ne 0) { throw "expected no telemetry line, got $($Run.Telemetry.Count)" }
}

# ---------------------------------------------------------------------------
# Configurations used by the cases (synthetic model names)
# ---------------------------------------------------------------------------

function New-V2Config {
    param(
        [int]$MaxAttempts = 2,
        [int]$BackoffSec = 0,
        [bool]$Warmup = $false,
        [string]$BudgetMode = "",
        [int]$ContextWindow = 8192,
        [int]$Reserved = 1024,
        [string]$Think = "true"
    )

    $budget = ""
    if ($BudgetMode -ne "") { $budget = ", ""budgetMode"": ""$BudgetMode""" }
    $warm = if ($Warmup) { "true" } else { "false" }
    return @"
{
  "schemaVersion": 2,
  "ollama": { "url": "$fakeUrl", "healthTimeoutSec": 7, "maxAttempts": $MaxAttempts, "retryBackoffSec": $BackoffSec, "warmup": $warm },
  "defaults": { "profile": "alpha", "options": { "temperature": 0.2 }, "timeoutSec": 111, "stripThinking": true$budget },
  "profiles": {
    "alpha": { "model": "test-model-alpha", "contextWindow": $ContextWindow, "timeoutSec": 222, "reservedOutputTokens": $Reserved, "think": $Think },
    "beta":  { "model": "test-model-beta", "timeoutSec": 333, "options": { "seed": 5 } }
  },
  "agents": {
    "spec": { "profile": "alpha" },
    "developer": { "profile": "alpha" },
    "spec-reviewer": { "profile": "alpha" },
    "spec-reviser": { "profile": "alpha" }
  }
}
"@
}

$v2Invalid = "{ ""schemaVersion"": 3, ""ollama"": { ""url"": ""$fakeUrl"" } }"
$v1Valid = "{ ""ollamaUrl"": ""$fakeUrl"", ""defaultModel"": ""test-model-a"", ""options"": { ""temperature"": 0.3, ""num_ctx"": 4096 }, ""timeoutSec"": 444 }"

$tagsAlpha = @((New-Step "ok" @{ models = @("test-model-alpha") }))
$okReply = { param($Text) (New-Step "ok" @{ response = $Text; doneReason = "stop" }) }

# WP-2D2: the answers of the reviewer and the reviser, and the two subjects of the cases.
$reviewPass = "# Specification Review`r`n`r`n## Status`r`n`r`nPASS`r`n`r`n## Summary`r`n`r`nFake reviewer response."
$reviewFail = "# Specification Review`r`n`r`n## Status`r`n`r`nFAIL`r`n`r`n## Summary`r`n`r`nFake reviewer response."
$revisedSpec = "# Specification`r`n`r`n## Goal`r`n`r`nFake revised specification."
$subjects = @(
    @{ Key = "review"; Script = "review-spec.ps1"; Agent = "spec-reviewer"; Label = "review-spec"; Role = "role-a"; Answer = $reviewPass; SectionLines = 14 },
    @{ Key = "revise"; Script = "revise-spec.ps1"; Agent = "spec-reviser"; Label = "revise-spec"; Role = "role-b"; Answer = $revisedSpec; SectionLines = 16 }
)

# The reviewer ends with the exit code 2 for every failure; the reviser ends with a
# throw, which is a non-zero exit code (FR-202).
function Assert-SubjectFailureExit {
    param($Subject, $Run)
    if ($Subject.Key -ceq "review") { Assert-Equal "exit code" 2 $Run.ExitCode }
    else { Assert-True "a non-zero exit code (the script ends with a throw)" ($Run.ExitCode -ne 0) }
}

# "name:type:mandatory:set:default" of every parameter of a script, read with the parser.
function Get-ParameterSummary {
    param([string]$Path)

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "parse errors in $Path" }
    $summary = @()
    foreach ($parameter in @($ast.ParamBlock.Parameters)) {
        $mandatory = $false
        $set = ""
        $other = @()
        foreach ($attribute in @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] })) {
            if ($attribute.TypeName.Name -ieq "Parameter") {
                foreach ($named in @($attribute.NamedArguments)) {
                    if ($named.ArgumentName -ieq "Mandatory" -and $named.Argument.Extent.Text -ceq '$true') { $mandatory = $true }
                    elseif ($named.ArgumentName -ine "Mandatory") { $other += "Parameter." + $named.ArgumentName }
                }
                if (@($attribute.PositionalArguments).Count -gt 0) { $other += "Parameter.positional" }
            }
            elseif ($attribute.TypeName.Name -ieq "ValidateSet") { $set = (@($attribute.PositionalArguments | ForEach-Object { $_.Value }) -join "/") }
            else { $other += $attribute.TypeName.Name }
        }
        $typeName = ($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } | Select-Object -First 1).TypeName.Name
        $default = ""
        if ($null -ne $parameter.DefaultValue) { $default = $parameter.DefaultValue.Extent.Text }
        $summary += "$($parameter.Name.VariablePath.UserPath):${typeName}:mandatory=${mandatory}:set=${set}:default=${default}:other=$($other -join '+')"
    }
    return $summary
}

# A hook of a script: the declared parameters and the variables it reads besides them.
function Get-HookInfo {
    param($Ast, [string]$VariableText)

    $assignment = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $VariableText }, $true))
    if ($assignment.Count -ne 1) { throw "expected exactly one assignment of $VariableText, got $($assignment.Count)" }
    $block = @($assignment[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true))[0].ScriptBlock
    $declared = @($block.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $read = @($block.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique)
    return [pscustomobject]@{ Declared = $declared; Foreign = @($read | Where-Object { $declared -notcontains $_ }) }
}

# The parameters named in the call of Invoke-AgentModel in a script.
function Get-EngineCallParameters {
    param($Ast)

    $calls = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq "Invoke-AgentModel" }, $true))
    if ($calls.Count -ne 1) { throw "expected one call of Invoke-AgentModel, got $($calls.Count)" }
    return (@($calls[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName } | Sort-Object) -join ",")
}

# Closing round of the Phase 2 final QA: cases added only; no existing assertion
# was edited. A hint is pinned by one phrase of the harness's own fixed wording
# that names its category, on the line right after the Category line (NFR-202).

# The lines of Expected appear consecutively, in this order. An item is an exact
# line or @{ Prefix = ...; Contains = ... }.
function Assert-LineBlock {
    param($Run, [object[]]$Expected)

    $all = @($Run.Lines)
    $isMatch = {
        param($Line, $Item)
        if ($Item -is [hashtable]) { return ($Line.StartsWith($Item.Prefix, [System.StringComparison]::Ordinal) -and $Line.Contains($Item.Contains)) }
        return ($Line -ceq $Item)
    }
    for ($start = 0; $start -le $all.Count - $Expected.Count; $start++) {
        $ok = $true
        for ($k = 0; $k -lt $Expected.Count; $k++) {
            if (-not (& $isMatch $all[$start + $k] $Expected[$k])) { $ok = $false; break }
        }
        if ($ok) { return }
    }
    throw "no block of consecutive lines in this order: " + (($Expected | ForEach-Object { if ($_ -is [hashtable]) { $_.Prefix + "..." + $_.Contains + "..." } else { "'" + $_ + "'" } }) -join " | ") + " -- the lines were: " + ($all -join " | ")
}

function Assert-CategoryHint {
    param($Run, [string]$Category, [string]$Phrase)
    Assert-LineBlock $Run @("Category: $Category", @{ Prefix = "Hint: "; Contains = $Phrase })
}

# ---------------------------------------------------------------------------
# Startup of a suite: the temporary harness root, the guard 1 and guard 4 proofs
# (printed by every suite) and the data the cases share
# ---------------------------------------------------------------------------

function Initialize-EngineSuite {
    New-TempHarness

    # Guard 1 startup proof: it rejects every unsafe configuration and accepts the good ones.
    $guardDirectory = Join-Path $tempRoot "guard1"
    [void][System.IO.Directory]::CreateDirectory($guardDirectory)
    $probes = [ordered]@{
        "a missing file"          = $null
        "invalid JSON"            = "{ ""ollamaUrl"": "
        "v1 localhost URL"        = "{ ""ollamaUrl"": ""http://localhost:11434"" }"
        "v1 other URL"            = "{ ""ollamaUrl"": ""http://127.0.0.1:10"" }"
        "v2 localhost URL"        = "{ ""schemaVersion"": 2, ""ollama"": { ""url"": ""http://localhost:11434"" } }"
        "v2 without URL"          = "{ ""schemaVersion"": 2 }"
        "v2 with only the v1 key" = "{ ""schemaVersion"": 2, ""ollamaUrl"": ""$fakeUrl"" }"
    }
    $probeIndex = 0
    foreach ($label in $probes.Keys) {
        $probeIndex++
        $probePath = Join-Path $guardDirectory "probe-$probeIndex.json"
        if ($null -ne $probes[$label]) { [System.IO.File]::WriteAllText($probePath, $probes[$label], $utf8NoBom) }
        if (Test-TempHarnessConfig -Path $probePath) { Stop-Suite "guard 1 accepted $label" }
        Write-Host "[PASS] guard 1 rejects $label" -ForegroundColor Green
        $script:passed++
    }
    foreach ($good in @($v1Valid, (New-V2Config), $v2Invalid)) {
        $goodPath = Join-Path $guardDirectory "good.json"
        [System.IO.File]::WriteAllText($goodPath, $good, $utf8NoBom)
        if (-not (Test-TempHarnessConfig -Path $goodPath)) { Stop-Suite "guard 1 rejected a configuration with the fake URL" }
    }
    Write-Host "[PASS] guard 1 accepts configurations whose URL is the fake URL" -ForegroundColor Green
    $script:passed++

    # Guard 4 startup proof.
    $routes = Get-ForbiddenRoutes
    if ($routes.Files -lt 5 -or $routes.Found.Count -gt 0) {
        Stop-Suite "guard 4: files checked $($routes.Files); found: $($routes.Found -join ', ')"
    }
    # The wrappers no longer exist (FR-314); the transport of the engine is the
    # only function of the harness that calls the cmdlet.
    $allowedRestCalls = @("agent-exec.ps1:Invoke-OllamaHttp")
    $unexpectedRest = @($routes.RestCalls | Where-Object { $allowedRestCalls -notcontains $_ })
    if ($unexpectedRest.Count -gt 0) { Stop-Suite "guard 4: Invoke-RestMethod is called from: $($unexpectedRest -join ', ')" }
    if (@($routes.RestCalls | Where-Object { $_ -ceq "agent-exec.ps1:Invoke-OllamaHttp" }).Count -ne 1) { Stop-Suite "guard 4: agent-exec.ps1 must call Invoke-RestMethod exactly once, inside Invoke-OllamaHttp" }
    Write-Host "[PASS] guard 4: no other HTTP route in the $($routes.Files) copied scripts; Invoke-RestMethod only where allowed" -ForegroundColor Green
    $script:passed++

    # Data shared by the cases of the three suites (the old suite defined it in its
    # main body, in the order of its sections).
    $script:inputsText = @{}
    foreach ($name in @("project-instructions", "agent-contract", "role-a", "role-b", "repo-context", "task")) {
        $script:inputsText[$name] = Read-Utf8 (Join-Path $inputsDirectory "$name.txt")
    }

    $script:matrixConfig = New-V2Config -MaxAttempts 2 -BackoffSec 0

    # window 1000, reserved 100, default margin 0.1 -> S 100, available 800 tokens (2800
    # characters at 3.5 characters per token). A task of 4000 characters is 1143 tokens.
    $script:bigTask = Join-Path $casesDirectory "big-task.txt"
    [System.IO.File]::WriteAllText($script:bigTask, ("x" * 4000), $utf8NoBom)
    $script:tinyEnforce = New-V2Config -ContextWindow 1000 -Reserved 100 -BudgetMode "enforce" -Warmup $true
    $script:tinyWarn = New-V2Config -ContextWindow 1000 -Reserved 100 -BudgetMode "warn" -Warmup $false
    $script:tinyDefault = New-V2Config -ContextWindow 1000 -Reserved 100 -Warmup $false

    $script:taskPath = Join-Path $casesDirectory "task.txt"
    $script:specInputPath = Join-Path $casesDirectory "spec-input.md"
    $script:reviewInputPath = Join-Path $casesDirectory "review-input.md"
    $script:specText = Read-Utf8 (Join-Path $inputsDirectory "spec.txt")
    $script:reviewText = Read-Utf8 (Join-Path $inputsDirectory "review.txt")
}

# The environment the suite changed and the temporary root, restored at the end.
function Restore-EngineSuite {
    $env:AI_HARNESS_MODEL = $originalModelVariable
    $env:AI_HARNESS_RUN_ID = $originalRunId
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# The summary block; the suite itself ends with the exit statements.
function Write-EngineSuiteSummary {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "              TEST SUMMARY" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "Passed: $script:passed"
    Write-Host "Failed: $script:failed"

    if ($script:failed -eq 0) {
        Write-Host "STATUS: PASS" -ForegroundColor Green
    }
    else {
        Write-Host "STATUS: FAIL" -ForegroundColor Red
    }
}
