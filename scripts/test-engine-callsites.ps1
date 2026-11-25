<#
.SYNOPSIS
    Offline child-process suite for the engine call sites (Phase 2, WP-2D1:
    run-agent.ps1; WP-2D2: review-spec.ps1 and
    revise-spec.ps1).

.DESCRIPTION
    Covers, for run-agent.ps1: AC-201 (script part: the system and prompt strings
    the real script sends equal the goldens), AC-202 (failure matrix: legacy exit
    code, error category, exactly one telemetry line), AC-203 (an oversized prompt
    stops before any request in enforce mode and is sent with a warning in warn
    mode), AC-213 (child-process part: the default transport reaches the fake
    Invoke-RestMethod with the profile's timeoutSec and healthTimeoutSec) and
    AC-216 (parameter block, exit codes) and AC-322 (the wrappers are gone). The same criteria are covered for review-spec.ps1
    and revise-spec.ps1 (WP-2D2), plus AC-214 (the telemetry record of the reviewer
    and the reviser) and the legacy failure-path wording of both scripts.

    Scripts are never run from the repository and never against a real server.
    Each one runs from a temporary harness root under TEMP in a child
    powershell.exe (the "engine fake host"). In it a function named
    Invoke-RestMethod stands in for the cmdlet. Unlike the fake hosts of Phase 0
    and Phase 1 (which throw a plain RuntimeException, so every failure is
    transport_other), this host throws typed System.Net.WebException objects built
    with the compiled fake WebResponse of tests\mocks\fake-web-response.ps1, so
    timeout, http_4xx, http_5xx and transport_reset can be produced.

    The four guards of Phase 0 FR-018 and Phase 1 apply:
      1. Test-TempHarnessConfig checks the temporary config before every case (the
         Ollama URL must be http://127.0.0.1:9); at startup the suite proves that it
         rejects a missing file, invalid JSON, http://localhost:11434 and any other
         URL, in the v1 and the v2 form.
      2. The fake host exits 97 unless Invoke-RestMethod resolves to the fake.
      3. The fake accepts only URIs starting with http://127.0.0.1:9/ and records
         any other as a violation, refused before any request.
      4. A static scan refuses to start when the copied scripts hold another HTTP
         route, and when Invoke-RestMethod is called from anywhere but the places
         that are allowed to call it.

    Assertions use exit codes, call records, telemetry records, error categories
    and the harness's own fixed wording, never text produced by PowerShell, .NET or
    Ollama (NFR-202). The fake Invoke-RestMethod declares exactly -Uri, -Method,
    -Body, -ContentType and -TimeoutSec, so an extra parameter in the engine call
    makes every case fail.
#>
param()

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$scriptsDirectory = $PSScriptRoot
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "   ENGINE CALL-SITE SUITE (OFFLINE)" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan

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
    # WP-2D2: the wrappers are relocated and delegate to the engine, so the transport
    # of the engine is the only function of the harness that calls the cmdlet.
    $allowedRestCalls = @("agent-exec.ps1:Invoke-OllamaHttp")
    $unexpectedRest = @($routes.RestCalls | Where-Object { $allowedRestCalls -notcontains $_ })
    if ($unexpectedRest.Count -gt 0) { Stop-Suite "guard 4: Invoke-RestMethod is called from: $($unexpectedRest -join ', ')" }
    if (@($routes.RestCalls | Where-Object { $_ -ceq "agent-exec.ps1:Invoke-OllamaHttp" }).Count -ne 1) { Stop-Suite "guard 4: agent-exec.ps1 must call Invoke-RestMethod exactly once, inside Invoke-OllamaHttp" }
    Write-Host "[PASS] guard 4: no other HTTP route in the $($routes.Files) copied scripts; Invoke-RestMethod only where allowed" -ForegroundColor Green
    $script:passed++

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-201 (script part): the strings run-agent sends equal the goldens ===" -ForegroundColor Cyan

    $inputsText = @{}
    foreach ($name in @("project-instructions", "agent-contract", "role-a", "role-b", "repo-context", "task")) {
        $inputsText[$name] = Read-Utf8 (Join-Path $inputsDirectory "$name.txt")
    }
    $goldenCases = @(
        @{ Name = "run-nocontext-role-a"; Agent = "spec"; Role = "role-a"; Context = $false },
        @{ Name = "run-context-role-a"; Agent = "spec"; Role = "role-a"; Context = $true },
        @{ Name = "run-nocontext-role-b"; Agent = "developer"; Role = "role-b"; Context = $false },
        @{ Name = "run-context-role-b"; Agent = "developer"; Role = "role-b"; Context = $true }
    )
    foreach ($case in $goldenCases) {
        Test-Case "AC-201 run-agent $($case.Name): system and prompt equal the golden (CRLF -> LF comparison), inputs pass through" {
            $arguments = @{ Agent = $case.Agent }
            if ($case.Context) { $arguments.ContextFile = (Join-Path $casesDirectory "repo-context.txt") }
            $run = Invoke-Case -Name $case.Name -ConfigText (New-V2Config) -Arguments $arguments -TaskFile (Join-Path $casesDirectory "task.txt") `
                -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "Fake agent response."))
            Assert-Guards $run
            Assert-Equal "exit code" 0 $run.ExitCode
            $generations = @(Get-Generations $run)
            Assert-Equal "generate calls" 1 $generations.Count
            $system = ConvertFrom-Base64Utf8 $generations[0].systemB64
            $prompt = ConvertFrom-Base64Utf8 $generations[0].promptB64
            $goldenSystem = Read-Utf8 (Join-Path $goldenDirectory "$($case.Name).system.txt")
            $goldenPrompt = Read-Utf8 (Join-Path $goldenDirectory "$($case.Name).prompt.txt")
            if (-not [string]::Equals((ConvertTo-NormalizedEol $system), (ConvertTo-NormalizedEol $goldenSystem), [System.StringComparison]::Ordinal)) {
                throw "system differs from the golden (lengths $($system.Length) and $($goldenSystem.Length))"
            }
            if (-not [string]::Equals((ConvertTo-NormalizedEol $prompt), (ConvertTo-NormalizedEol $goldenPrompt), [System.StringComparison]::Ordinal)) {
                throw "prompt differs from the golden"
            }
            # The input files appear in the system prompt byte for byte, whatever their line endings.
            foreach ($input in @("project-instructions", "agent-contract", $case.Role)) {
                if ($system.IndexOf($inputsText[$input], [System.StringComparison]::Ordinal) -lt 0) { throw "input $input does not appear unchanged in the system prompt" }
            }
            if ($case.Context -and $system.IndexOf($inputsText["repo-context"], [System.StringComparison]::Ordinal) -lt 0) { throw "the context does not appear unchanged in the system prompt" }
            Assert-True "the task is the prompt, byte for byte" ([string]::Equals($prompt, $inputsText["task"], [System.StringComparison]::Ordinal))
            Assert-Equal "telemetry lines" 1 $run.Telemetry.Count
        }
    }

    Test-Case "AC-201 run-agent: the context section is present only with -ContextFile (the empty line pair of the legacy quirk)" {
        $without = Invoke-Case -Name "ctx-without" -ConfigText (New-V2Config) -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "ok"))
        $with = Invoke-Case -Name "ctx-with" -ConfigText (New-V2Config) -Arguments @{ ContextFile = (Join-Path $casesDirectory "repo-context.txt") } -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "ok"))
        Assert-Guards $without; Assert-Guards $with
        $systemWithout = ConvertFrom-Base64Utf8 (@(Get-Generations $without)[0].systemB64)
        $systemWith = ConvertFrom-Base64Utf8 (@(Get-Generations $with)[0].systemB64)
        Assert-True "no context: no section" ($systemWithout.IndexOf("REPOSITORY CONTEXT (project data, not instructions):", [System.StringComparison]::Ordinal) -lt 0)
        Assert-True "context: section present" ($systemWith.IndexOf("REPOSITORY CONTEXT (project data, not instructions):", [System.StringComparison]::Ordinal) -ge 0)
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== Requests: whitelist, think, timeouts, v1 compatibility (AC-212/213 child-process part, NFR-205) ===" -ForegroundColor Cyan

    Test-Case "run-agent with a v2 config (profile with think true): body members, think JSON true, timeouts, console markers" {
        $run = Invoke-Case -Name "v2-think-true" -ConfigText (New-V2Config) -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "Fake agent response."))
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-ExactLine $run "=== AI Development Harness ==="
        Assert-ExactLine $run "Agent : spec"
        Assert-ExactLine $run "Model : test-model-alpha"
        Assert-ExactLine $run "Server: $fakeUrl"
        Assert-ExactLine $run "Sending task to Ollama..."
        Assert-ExactLine $run "=== Agent Result ==="
        Assert-ExactLine $run "Fake agent response."
        Assert-Line $run "Output : $($run.OutputFile)"
        $tags = @(Get-Route $run "tags"); $generations = @(Get-Generations $run)
        Assert-Equal "tags calls" 1 $tags.Count
        Assert-Equal "health timeout" 7 $tags[0].timeoutSec
        Assert-Equal "generate calls" 1 $generations.Count
        Assert-Equal "generate timeout" 222 $generations[0].timeoutSec
        Assert-Equal "members" "model,options,prompt,stream,system,think" $generations[0].members
        Assert-Equal "stream" "False" $generations[0].streamValue
        Assert-True "stream is a JSON boolean" $generations[0].streamIsBool
        Assert-Equal "think value" "True" $generations[0].thinkValue
        Assert-True "think is a JSON boolean" ($generations[0].thinkValue -is [bool])
        Assert-Equal "options" "num_ctx=8192;temperature=0.2" $generations[0].optionsPairs
        Assert-Equal "content type" "application/json; charset=utf-8" $generations[0].contentType
        Assert-Equal "output file" "Fake agent response." $run.Output
        Assert-OneRecord $run "success" "" $true
        Assert-Equal "attempts" 1 $run.Telemetry[0].attempts
        Assert-Equal "think_sent" "true" $run.Telemetry[0].think_sent
    }

    Test-Case "run-agent with think false: the member is present and false; with a profile that has no think: no member" {
        $run = Invoke-Case -Name "v2-think-false" -ConfigText (New-V2Config -Think "false") -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "ok"))
        Assert-Guards $run
        $generations = @(Get-Generations $run)
        Assert-Equal "members" "model,options,prompt,stream,system,think" $generations[0].members
        Assert-Equal "think value" "False" $generations[0].thinkValue
        Assert-True "think is a JSON boolean" ($generations[0].thinkValue -is [bool])
        $run = Invoke-Case -Name "v2-think-default" -ConfigText (New-V2Config -Think '"default"') -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "ok"))
        Assert-Guards $run
        Assert-Equal "members" "model,options,prompt,stream,system" (@(Get-Generations $run)[0].members)
        Assert-Equal "think_sent" "omitted" $run.Telemetry[0].think_sent
    }

    Test-Case "run-agent -Profile beta and a v1 configuration: no think, no extra body member, legacy parameters and exit 0" {
        $run = Invoke-Case -Name "profile-beta" -ConfigText (New-V2Config) -Arguments @{ Profile = "beta" } -TagsSteps @((New-Step "ok" @{ models = @("test-model-beta") })) -GenerateSteps @((& $okReply "ok"))
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        $generation = @(Get-Generations $run)[0]
        Assert-Equal "model" "test-model-beta" $generation.model
        Assert-Equal "timeout" 333 $generation.timeoutSec
        Assert-Equal "members" "model,options,prompt,stream,system" $generation.members
        $run = Invoke-Case -Name "v1" -ConfigText $v1Valid -TagsSteps @((New-Step "ok" @{ models = @("test-model-a") })) -GenerateSteps @((& $okReply "ok"))
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        $generation = @(Get-Generations $run)[0]
        Assert-Equal "model" "test-model-a" $generation.model
        Assert-Equal "timeout" 444 $generation.timeoutSec
        Assert-Equal "options" "num_ctx=4096;temperature=0.3" $generation.optionsPairs
        Assert-Equal "members" "model,options,prompt,stream,system" $generation.members
        Assert-Equal "health timeout (default)" 15 (@(Get-Route $run "tags")[0].timeoutSec)
        Assert-Equal "telemetry context_window (v1: skipped budget)" "" $run.Telemetry[0].context_window
    }

    Test-Case "run-agent success adds no console line (no Category, Hint, Retrying or Warning), and creates a missing output directory" {
        $nested = Join-Path $casesDirectory "nested-output\sub\result.md"
        if (Test-Path -LiteralPath (Join-Path $casesDirectory "nested-output")) { Remove-Item -LiteralPath (Join-Path $casesDirectory "nested-output") -Recurse -Force }
        $run = Invoke-Case -Name "success-quiet" -ConfigText (New-V2Config) -Arguments @{ OutputFile = $nested } -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "Quiet answer."))
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        foreach ($text in @("Category:", "Hint:", "Retrying", "Warning:", "=== OLLAMA ERROR ===")) { Assert-NoLine $run $text }
        Assert-ExactLine $run "Output : $nested"
        Assert-Equal "output file" "Quiet answer." ([System.IO.File]::ReadAllText($nested))
    }

    Test-Case "run-agent trims -Model before the availability check and the request, as before" {
        $run = Invoke-Case -Name "model-trim" -ConfigText (New-V2Config) -Arguments @{ Model = "  test-model-alpha  " } -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "ok"))
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-ExactLine $run "Model : test-model-alpha"
        Assert-Equal "model in the request" "test-model-alpha" (@(Get-Generations $run)[0].model)
        Assert-Equal "model in the record" "test-model-alpha" $run.Telemetry[0].model
    }
    Test-Case "run-agent strips <think> blocks from the answer exactly as before and trims" {
        $run = Invoke-Case -Name "strip-think" -ConfigText (New-V2Config) -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "ok" @{ response = "<think>hidden reasoning</think>  Visible answer.  "; doneReason = "stop" }))
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-Equal "output file" "Visible answer." $run.Output
        Assert-NoLine $run "hidden reasoning"
        Assert-Equal "thinking_chars" 16 $run.Telemetry[0].thinking_chars
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== FR-202: errors before resolution and before the call ===" -ForegroundColor Cyan

    Test-Case "FR-202 a configuration error: exit 1, registry_invalid, no request, no telemetry line" {
        $run = Invoke-Case -Name "bad-config" -ConfigText $v2Invalid
        Assert-Guards $run
        Assert-Equal "exit code" 1 $run.ExitCode
        Assert-Line $run "registry_invalid:"
        Assert-NoRequestNoRecord $run
    }

    Test-Case "FR-202 a blank -Model: exit 1, the legacy message, no request, no telemetry line" {
        $run = Invoke-Case -Name "blank-model" -ConfigText (New-V2Config) -Arguments @{ Model = "" }
        Assert-Guards $run
        Assert-Equal "exit code" 1 $run.ExitCode
        Assert-Line $run "Model name cannot be empty."
        Assert-NoRequestNoRecord $run
    }

    Test-Case "FR-202 model not installed: legacy lines, Category and Hint, exit 1, no generation, one record with model_called false" {
        $run = Invoke-Case -Name "model-missing" -ConfigText (New-V2Config) -TagsSteps @((New-Step "ok" @{ models = @("other-model-1", "other-model-2") }))
        Assert-Guards $run
        Assert-Equal "exit code" 1 $run.ExitCode
        Assert-ExactLine $run "Model not found: test-model-alpha"
        Assert-ExactLine $run "Available models:"
        Assert-ExactLine $run "  - other-model-1"
        Assert-ExactLine $run "  - other-model-2"
        Assert-ExactLine $run "Category: model_not_installed"
        Assert-Line $run "Hint: "
        Assert-Line $run "The requested Ollama model is not installed. Try: ollama pull test-model-alpha"
        Assert-Equal "generate calls" 0 (@(Get-Route $run "generate").Count)
        Assert-OneRecord $run "error" "model_not_installed" $false
    }

    Test-Case "FR-202 model name that differs only in case is installed (exact, case-insensitive match)" {
        $run = Invoke-Case -Name "model-case" -ConfigText (New-V2Config) -TagsSteps @((New-Step "ok" @{ models = @("TEST-MODEL-ALPHA") })) -GenerateSteps @((& $okReply "ok"))
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-Equal "generate calls" 1 (@(Get-Generations $run).Count)
    }

    foreach ($unreachable in @(
            @{ Name = "tags-connect"; Step = (New-Step "status" @{ webStatus = "ConnectFailure" }); Category = "transport_unreachable"; Typed = $true },
            @{ Name = "tags-timeout"; Step = (New-Step "status" @{ webStatus = "Timeout" }); Category = "timeout"; Typed = $true },
            @{ Name = "tags-plain"; Step = (New-Step "plain"); Category = "transport_other"; Typed = $false })) {
        Test-Case "FR-202 /api/tags fails ($($unreachable.Category)): the legacy 'not reachable' error, Category, exit 1, no generation, one record" {
            $run = Invoke-Case -Name $unreachable.Name -ConfigText (New-V2Config) -TagsSteps @($unreachable.Step) -TypedExceptions:$unreachable.Typed
            Assert-Guards $run
            Assert-Equal "exit code" 1 $run.ExitCode
            Assert-ExactLine $run "ERROR: Ollama is not reachable at $fakeUrl. Make sure Ollama is running."
            Assert-ExactLine $run "Category: $($unreachable.Category)"
            Assert-Line $run "Hint: "
            Assert-Equal "tags calls" 1 (@(Get-Route $run "tags").Count)
            Assert-Equal "generate calls" 0 (@(Get-Route $run "generate").Count)
            Assert-OneRecord $run "error" $unreachable.Category $false
            Assert-Equal "error column starts with the category" $true ([string]$run.Telemetry[0].error).StartsWith($unreachable.Category + ":", [System.StringComparison]::Ordinal)
        }
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-202: failure matrix of run-agent (maxAttempts 2, retryBackoffSec 0) ===" -ForegroundColor Cyan

    $matrixConfig = New-V2Config -MaxAttempts 2 -BackoffSec 0

    Test-Case "AC-202 injected timeout: exit 1, OLLAMA ERROR block, timeout, one request, no output file, one record" {
        $run = Invoke-Case -Name "m-timeout" -ConfigText $matrixConfig -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "status" @{ webStatus = "Timeout" })) -TypedExceptions
        Assert-Guards $run
        Assert-Equal "exit code" 1 $run.ExitCode
        Assert-ExactLine $run "=== OLLAMA ERROR ==="
        Assert-ExactLine $run "Category: timeout"
        Assert-Line $run "Hint: "
        Assert-ExactLine $run "=== END OLLAMA ERROR ==="
        Assert-Line $run "ERROR: Agent execution failed."
        Assert-NoLine $run "Status:"
        Assert-Equal "generate calls (timeout is not retried)" 1 (@(Get-Generations $run).Count)
        Assert-True "no output file" ($null -eq $run.Output)
        Assert-OneRecord $run "error" "timeout" $true
        Assert-Equal "attempts" 1 $run.Telemetry[0].attempts
    }

    Test-Case "AC-202 HTTP 500 on every attempt: two requests, the Status and body lines, retry line, http_5xx, attempts 2, one record" {
        $run = Invoke-Case -Name "m-500" -ConfigText $matrixConfig -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "http" @{ status = 500; body = '{"error":"boom from the fake server"}' })) -RepeatLastGenerate -TypedExceptions
        Assert-Guards $run
        Assert-Equal "exit code" 1 $run.ExitCode
        Assert-Equal "generate calls" 2 (@(Get-Generations $run).Count)
        Assert-ExactLine $run "=== OLLAMA ERROR ==="
        Assert-ExactLine $run "Status: 500"
        Assert-ExactLine $run "boom from the fake server"
        Assert-ExactLine $run "Category: http_5xx"
        Assert-Line $run "Hint: "
        Assert-ExactLine $run "Retrying (attempt 2 of 2) after http_5xx, waiting 0 s."
        Assert-ExactLine $run "=== END OLLAMA ERROR ==="
        Assert-True "no output file" ($null -eq $run.Output)
        Assert-OneRecord $run "error" "http_5xx" $true
        Assert-Equal "attempts" 2 $run.Telemetry[0].attempts
        Assert-Equal "http_status" 500 $run.Telemetry[0].http_status
    }

    Test-Case "AC-202 HTTP 400: one request, Status 400, http_4xx, no retry line, one record" {
        $run = Invoke-Case -Name "m-400" -ConfigText $matrixConfig -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "http" @{ status = 400; body = '{"error":"bad request from the fake server"}' })) -TypedExceptions
        Assert-Guards $run
        Assert-Equal "exit code" 1 $run.ExitCode
        Assert-Equal "generate calls" 1 (@(Get-Generations $run).Count)
        Assert-ExactLine $run "Status: 400"
        Assert-ExactLine $run "bad request from the fake server"
        Assert-ExactLine $run "Category: http_4xx"
        Assert-NoLine $run "Retrying"
        Assert-True "no output file" ($null -eq $run.Output)
        Assert-OneRecord $run "error" "http_4xx" $true
        Assert-Equal "attempts" 1 $run.Telemetry[0].attempts
    }

    Test-Case "AC-202 a connection reset on the first attempt, then success: two requests, exit 0, output file, one record, attempts 2" {
        $run = Invoke-Case -Name "m-reset" -ConfigText $matrixConfig -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "status" @{ webStatus = "ReceiveFailure" }), (& $okReply "Answer after the retry.")) -TypedExceptions
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-Equal "generate calls" 2 (@(Get-Generations $run).Count)
        Assert-ExactLine $run "Retrying (attempt 2 of 2) after transport_reset, waiting 0 s."
        Assert-NoLine $run "=== OLLAMA ERROR ==="
        Assert-NoLine $run "Category:"
        Assert-Equal "output file" "Answer after the retry." $run.Output
        Assert-OneRecord $run "success" "" $true
        Assert-Equal "attempts" 2 $run.Telemetry[0].attempts
    }

    Test-Case "AC-202 an empty response: exit 1, the legacy message, Category empty_response, no output file, one error record" {
        $run = Invoke-Case -Name "m-empty" -ConfigText $matrixConfig -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "ok" @{ response = "   "; doneReason = "stop" }))
        Assert-Guards $run
        Assert-Equal "exit code" 1 $run.ExitCode
        Assert-ExactLine $run "ERROR: Agent returned an empty response."
        Assert-ExactLine $run "Category: empty_response"
        Assert-NoLine $run "=== OLLAMA ERROR ==="
        Assert-NoLine $run "=== Agent Result ==="
        Assert-Equal "generate calls (not retried)" 1 (@(Get-Generations $run).Count)
        Assert-True "no output file" ($null -eq $run.Output)
        Assert-OneRecord $run "error" "empty_response" $true
    }

    Test-Case "AC-202 an empty response with done_reason length: thinking_budget_exhausted, the same exit code and message" {
        $run = Invoke-Case -Name "m-length" -ConfigText $matrixConfig -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "ok" @{ response = ""; doneReason = "length"; thinking = ("t" * 40) }))
        Assert-Guards $run
        Assert-Equal "exit code" 1 $run.ExitCode
        Assert-ExactLine $run "ERROR: Agent returned an empty response."
        Assert-ExactLine $run "Category: thinking_budget_exhausted"
        Assert-True "no output file" ($null -eq $run.Output)
        Assert-OneRecord $run "error" "thinking_budget_exhausted" $true
        Assert-Equal "thinking_chars" 40 $run.Telemetry[0].thinking_chars
    }

    Test-Case "AC-202 maxAttempts 1 disables the retry (one request, attempts 1)" {
        $run = Invoke-Case -Name "m-attempts-1" -ConfigText (New-V2Config -MaxAttempts 1) -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "http" @{ status = 503; body = "" })) -RepeatLastGenerate -TypedExceptions
        Assert-Guards $run
        Assert-Equal "exit code" 1 $run.ExitCode
        Assert-Equal "generate calls" 1 (@(Get-Generations $run).Count)
        Assert-NoLine $run "Retrying"
        Assert-ExactLine $run "Status: 503"
        Assert-OneRecord $run "error" "http_5xx" $true
        Assert-Equal "attempts" 1 $run.Telemetry[0].attempts
    }

    Test-Case "AC-202 the default transport reaches the fake with the profile's timeoutSec (AC-213 child-process part)" {
        $run = Invoke-Case -Name "m-timeouts" -ConfigText $matrixConfig -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "ok"))
        Assert-Guards $run
        Assert-Equal "tags timeout = healthTimeoutSec" 7 (@(Get-Route $run "tags")[0].timeoutSec)
        Assert-Equal "generate timeout = profile timeoutSec" 222 (@(Get-Generations $run)[0].timeoutSec)
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-203 (run-agent part): an oversized prompt ===" -ForegroundColor Cyan

    # window 1000, reserved 100, default margin 0.1 -> S 100, available 800 tokens (2800
    # characters at 3.5 characters per token). A task of 4000 characters is 1143 tokens.
    $bigTask = Join-Path $casesDirectory "big-task.txt"
    [System.IO.File]::WriteAllText($bigTask, ("x" * 4000), $utf8NoBom)
    $tinyEnforce = New-V2Config -ContextWindow 1000 -Reserved 100 -BudgetMode "enforce" -Warmup $true
    $tinyWarn = New-V2Config -ContextWindow 1000 -Reserved 100 -BudgetMode "warn" -Warmup $false
    $tinyDefault = New-V2Config -ContextWindow 1000 -Reserved 100 -Warmup $false

    Test-Case "AC-203 enforce: exit 1, Category context_budget_exceeded, one line per section, no generate, no warm-up, one record with model_called false" {
        $run = Invoke-Case -Name "budget-enforce" -ConfigText $tinyEnforce -TaskFile $bigTask -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "never sent"))
        Assert-Guards $run
        Assert-Equal "exit code" 1 $run.ExitCode
        Assert-ExactLine $run "Category: context_budget_exceeded"
        Assert-Line $run "Hint: "
        Assert-Line $run "ERROR: Agent execution failed."
        Assert-Equal "generate calls (and warm-ups)" 0 (@(Get-Route $run "generate").Count)
        Assert-Equal "warm-up calls" 0 (@(Get-Warmups $run).Count)
        $sectionLines = @($run.Lines | Where-Object { $_ -match '^  \S+ \((instruction|data)\): \d+ characters, about \d+ tokens$' })
        Assert-Equal "section lines (9 parts of the prompt without context)" 9 $sectionLines.Count
        Assert-ExactLine $run "  task (data): 4000 characters, about 1143 tokens"
        Assert-True "no output file" ($null -eq $run.Output)
        Assert-OneRecord $run "error" "context_budget_exceeded" $false
        $record = $run.Telemetry[0]
        Assert-Equal "context_window" 1000 $record.context_window
        Assert-True "est_prompt_tokens above the available 800" ([long]$record.est_prompt_tokens -gt 800)
        Assert-Equal "think_sent is blank on a refusal" "" $record.think_sent
        Assert-Equal "attempts is blank on a refusal" "" $record.attempts
    }

    Test-Case "AC-203 enforce with a context file: one line per section (11 parts)" {
        $run = Invoke-Case -Name "budget-enforce-ctx" -ConfigText $tinyEnforce -TaskFile $bigTask -Arguments @{ ContextFile = (Join-Path $casesDirectory "repo-context.txt") } -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "never sent"))
        Assert-Guards $run
        Assert-Equal "exit code" 1 $run.ExitCode
        $sectionLines = @($run.Lines | Where-Object { $_ -match '^  \S+ \((instruction|data)\): \d+ characters, about \d+ tokens$' })
        Assert-Equal "section lines" 11 $sectionLines.Count
        Assert-Equal "generate calls" 0 (@(Get-Route $run "generate").Count)
    }

    foreach ($warnCase in @(@{ Name = "budget-warn"; Config = $tinyWarn; Label = "warn" }, @{ Name = "budget-default"; Config = $tinyDefault; Label = "the default (no budgetMode key)" })) {
        Test-Case "AC-203 $($warnCase.Label): the same prompt is sent, one Warning line, exit 0, the record carries the warning" {
            $run = Invoke-Case -Name $warnCase.Name -ConfigText $warnCase.Config -TaskFile $bigTask -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "Sent in warn mode."))
            Assert-Guards $run
            Assert-Equal "exit code" 0 $run.ExitCode
            Assert-Equal "generate calls" 1 (@(Get-Generations $run).Count)
            $system = ConvertFrom-Base64Utf8 (@(Get-Generations $run)[0].systemB64)
            $prompt = ConvertFrom-Base64Utf8 (@(Get-Generations $run)[0].promptB64)
            Assert-Equal "the prompt is never truncated" 4000 $prompt.Length
            $estimated = [long][math]::Ceiling([decimal]($system.Length + $prompt.Length) / [decimal]3.5)
            Assert-ExactLine $run "Warning: budget_exceeded (estimated $estimated tokens, available 800)."
            Assert-Equal "warning lines" 1 @($run.Lines | Where-Object { $_.StartsWith("Warning:", [System.StringComparison]::Ordinal) }).Count
            Assert-NoLine $run "Category:"
            Assert-Equal "output file" "Sent in warn mode." $run.Output
            Assert-OneRecord $run "success" "" $true
            Assert-Equal "warnings column" "budget_exceeded" $run.Telemetry[0].warnings
            Assert-Equal "est_prompt_tokens" $estimated $run.Telemetry[0].est_prompt_tokens
            Assert-Equal "prompt_chars" ($system.Length + $prompt.Length) $run.Telemetry[0].prompt_chars
        }
    }

    Test-Case "AC-203 a prompt that fits prints no Warning line and writes an empty warnings column" {
        $run = Invoke-Case -Name "budget-fits" -ConfigText $tinyWarn -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "ok")) -TaskFile (Join-Path $casesDirectory "task.txt")
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-NoLine $run "Warning:"
        Assert-Equal "warnings column" "" $run.Telemetry[0].warnings
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-216: interfaces are preserved ===" -ForegroundColor Cyan

    Test-Case "WP-2D hook rule (F-07): the -OnRetry script block of run-agent.ps1 reads only its own parameters, and no -Transport, -Sleep or -ResponseCheck is passed" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsDirectory "run-agent.ps1"), [ref]$tokens, [ref]$errors)
        Assert-Equal "parse errors" 0 @($errors).Count
        $assignment = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$retryNotice' }, $true))
        Assert-Equal "the retry notice assignment" 1 $assignment.Count
        $block = @($assignment[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true))[0].ScriptBlock
        $declared = @($block.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        Assert-Equal "parameters of the hook" 4 $declared.Count
        $read = @($block.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique)
        $foreign = @($read | Where-Object { $declared -notcontains $_ })
        if ($foreign.Count -gt 0) { throw "the hook reads variables that are not its parameters: $($foreign -join ', ')" }
        $callNames = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ceq "Invoke-AgentModel" }, $true))
        Assert-Equal "Invoke-AgentModel calls" 1 $callNames.Count
        $parametersPassed = @($callNames[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName } | Sort-Object)
        Assert-Equal "parameters passed to Invoke-AgentModel" "Agent,Execution,OnRetry,Parts,Prompt,Registry,System,TelemetryRoot" ($parametersPassed -join ",")
    }
    Test-Case "AC-216 the parameter block of run-agent.ps1 equals the baseline list (names, types, mandatory flags, ValidateSet)" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsDirectory "run-agent.ps1"), [ref]$tokens, [ref]$errors)
        Assert-Equal "parse errors" 0 @($errors).Count
        $actual = @($ast.ParamBlock.Parameters | ForEach-Object {
                $mandatory = @($_.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -ieq "Parameter" }).Count
                $validate = @($_.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -ine "Parameter" }).Count
                $typeName = ($_.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } | Select-Object -First 1).TypeName.Name
                "$($_.Name.VariablePath.UserPath):${typeName}:parameter=${mandatory}:other=${validate}:default=$($null -ne $_.DefaultValue)"
            })
        $baseline = @("Agent:string:parameter=0:other=0:default=False", "Task:string:parameter=0:other=0:default=False", "Model:string:parameter=0:other=0:default=False",
            "OutputFile:string:parameter=0:other=0:default=False", "ContextFile:string:parameter=0:other=0:default=False", "Profile:string:parameter=0:other=0:default=False")
        Assert-Equal "parameters" ($baseline -join "|") ($actual -join "|")
    }

    foreach ($missing in @(
            @{ Label = "no -Agent"; Args = @{ Agent = ""; Task = "t" } },
            @{ Label = "no -Task"; Args = @{ Agent = "spec"; Task = "" } },
            @{ Label = "an invalid agent name"; Args = @{ Agent = "../outside"; Task = "t" } },
            @{ Label = "an unknown agent"; Args = @{ Agent = "agent-does-not-exist"; Task = "t" } })) {
        Test-Case "AC-216 run-agent with $($missing.Label): exit 1 before any request or telemetry" {
            $run = Invoke-Case -Name "iface-$($missing.Label -replace '\W', '-')" -ConfigText (New-V2Config) -Arguments $missing.Args
            Assert-Guards $run
            Assert-Equal "exit code" 1 $run.ExitCode
            Assert-NoRequestNoRecord $run
        }
    }

    Test-Case "AC-216 a missing context file: exit 1, the legacy message, no generation request" {
        $run = Invoke-Case -Name "iface-ctx-missing" -ConfigText (New-V2Config) -Arguments @{ ContextFile = (Join-Path $casesDirectory "does-not-exist.txt") } -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "ok"))
        Assert-Guards $run
        Assert-Equal "exit code" 1 $run.ExitCode
        Assert-Line $run "Context file not found:"
        Assert-Equal "generate calls" 0 (@(Get-Route $run "generate").Count)
    }

    # =======================================================================
    # WP-2D2: review-spec.ps1 and revise-spec.ps1
    # =======================================================================
    Write-Host ""
    Write-Host "=== AC-201 (script part): the strings review-spec and revise-spec send equal the goldens (three modes each) ===" -ForegroundColor Cyan

    $taskPath = Join-Path $casesDirectory "task.txt"
    $specInputPath = Join-Path $casesDirectory "spec-input.md"
    $reviewInputPath = Join-Path $casesDirectory "review-input.md"
    $specText = Read-Utf8 (Join-Path $inputsDirectory "spec.txt")
    $reviewText = Read-Utf8 (Join-Path $inputsDirectory "review.txt")

    foreach ($subject in $subjects) {
        foreach ($mode in @("requirements", "baseline", "documentation")) {
            Test-Case "AC-201 $($subject.Label) -Mode ${mode}: system and prompt equal the golden (CRLF -> LF comparison), inputs pass through, exit 0, one record" {
                $golden = "$($subject.Key)-$mode"
                $run = Invoke-Case -Name "g-$golden" -ConfigText (New-V2Config) -Script $subject.Script -Arguments @{ Mode = $mode } -TaskFile $taskPath `
                    -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $subject.Answer))
                Assert-Guards $run
                Assert-Equal "exit code" 0 $run.ExitCode
                $generations = @(Get-Generations $run)
                Assert-Equal "generate calls" 1 $generations.Count
                $system = ConvertFrom-Base64Utf8 $generations[0].systemB64
                $prompt = ConvertFrom-Base64Utf8 $generations[0].promptB64
                $goldenSystem = Read-Utf8 (Join-Path $goldenDirectory "$golden.system.txt")
                $goldenPrompt = Read-Utf8 (Join-Path $goldenDirectory "$golden.prompt.txt")
                if (-not [string]::Equals((ConvertTo-NormalizedEol $system), (ConvertTo-NormalizedEol $goldenSystem), [System.StringComparison]::Ordinal)) {
                    throw "system differs from the golden (lengths $($system.Length) and $($goldenSystem.Length))"
                }
                if (-not [string]::Equals((ConvertTo-NormalizedEol $prompt), (ConvertTo-NormalizedEol $goldenPrompt), [System.StringComparison]::Ordinal)) {
                    throw "prompt differs from the golden"
                }
                # Every input appears in the system prompt byte for byte, whatever its line endings.
                $inputsToFind = @($inputsText["project-instructions"], $inputsText["agent-contract"], $inputsText[$subject.Role], $inputsText["task"], $specText)
                if ($subject.Key -ceq "revise") { $inputsToFind += $reviewText }
                foreach ($input in $inputsToFind) {
                    if ($system.IndexOf($input, [System.StringComparison]::Ordinal) -lt 0) { throw "an input does not appear unchanged in the system prompt" }
                }
                if ((ConvertTo-NormalizedEol $system).IndexOf("SPECIFICATION MODE (AUTHORITATIVE):`n$mode`n`nORIGINAL USER REQUEST:", [System.StringComparison]::Ordinal) -lt 0) { throw "the mode '$mode' is not the authoritative mode of the prompt" }
                Assert-OneRecord $run "success" "" $true -Agent $subject.Agent
            }
        }
    }

    # The golden fixtures end without whitespace, so a trim of an input would not show
    # in them: here every input has leading and trailing whitespace and a final newline.
    foreach ($subject in $subjects) {
        Test-Case "FR-203 $($subject.Label) inputs with leading and trailing whitespace and a final newline appear in the system prompt byte for byte" {
            $variants = [ordered]@{
                role     = ($inputsText[$subject.Role] + "  `r`n`n  `r`n")
                contract = (" `r`n" + $inputsText["agent-contract"] + "`n")
                project  = ($inputsText["project-instructions"] + "`t`r`n")
                spec     = ("`r`n  " + $specText + "  `r`n`r`n")
                review   = ("`n" + $reviewText + " `r`n")
                task     = ("  " + $inputsText["task"] + "  `r`n")
            }
            $targets = @{
                role     = (Join-Path $harnessRoot ".ai\agents\$($subject.Agent).md")
                contract = (Join-Path $harnessRoot ".ai\rules\agent-contract.md")
                project  = (Join-Path $harnessRoot "AGENTS.md")
                spec     = (Join-Path $casesDirectory "spec-ws.md")
                review   = (Join-Path $casesDirectory "review-ws.md")
                task     = (Join-Path $casesDirectory "task-ws.txt")
            }
            $originals = @{ role = (Join-Path $inputsDirectory "$($subject.Role).txt"); contract = (Join-Path $inputsDirectory "agent-contract.txt"); project = (Join-Path $inputsDirectory "project-instructions.txt") }
            try {
                foreach ($name in $variants.Keys) { [System.IO.File]::WriteAllText($targets[$name], $variants[$name], $utf8NoBom) }
                $extra = @{ SpecFile = $targets.spec }
                if ($subject.Key -ceq "revise") { $extra.ReviewFile = $targets.review }
                $run = Invoke-Case -Name "$($subject.Key)-whitespace" -ConfigText (New-V2Config) -Script $subject.Script -Arguments $extra -TaskFile $targets.task `
                    -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $subject.Answer))
            }
            finally {
                foreach ($name in $originals.Keys) { Copy-Item -LiteralPath $originals[$name] -Destination $targets[$name] -Force }
            }
            Assert-Guards $run
            Assert-Equal "exit code" 0 $run.ExitCode
            $system = ConvertFrom-Base64Utf8 (@(Get-Generations $run)[0].systemB64)
            $names = @("role", "contract", "project", "spec", "task")
            if ($subject.Key -ceq "revise") { $names += "review" }
            foreach ($name in $names) {
                if ($system.IndexOf($variants[$name], [System.StringComparison]::Ordinal) -lt 0) { throw "the $name input does not appear unchanged (with its whitespace) in the system prompt" }
            }
        }
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== review-spec and revise-spec: requests, console markers, output files (AC-213 child-process part, NFR-205) ===" -ForegroundColor Cyan

    Test-Case "review-spec success: markers, Review Status line, the review on the console and in the output file, body members, think JSON true, timeouts, no added line" {
        $run = Invoke-Case -Name "rv-success" -ConfigText (New-V2Config) -Script "review-spec.ps1" -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $reviewPass))
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-ExactLine $run "=== Specification Reviewer ==="
        Assert-ExactLine $run "Model : test-model-alpha"
        Assert-ExactLine $run "Spec  : $specInputPath"
        Assert-ExactLine $run "Sending specification to reviewer..."
        Assert-ExactLine $run "Review Status: PASS"
        Assert-ExactLine $run "Fake reviewer response."
        foreach ($text in @("Category:", "Hint:", "Retrying", "Warning:", "=== OLLAMA ERROR ===", "ERROR")) { Assert-NoLine $run $text }
        $tags = @(Get-Route $run "tags"); $generations = @(Get-Generations $run)
        Assert-Equal "tags calls" 1 $tags.Count
        Assert-Equal "health timeout" 7 $tags[0].timeoutSec
        Assert-Equal "generate calls" 1 $generations.Count
        Assert-Equal "generate timeout" 222 $generations[0].timeoutSec
        Assert-Equal "members" "model,options,prompt,stream,system,think" $generations[0].members
        Assert-Equal "stream" "False" $generations[0].streamValue
        Assert-True "stream is a JSON boolean" $generations[0].streamIsBool
        Assert-Equal "think value" "True" $generations[0].thinkValue
        Assert-True "think is a JSON boolean" ($generations[0].thinkValue -is [bool])
        Assert-Equal "options" "num_ctx=8192;temperature=0.2" $generations[0].optionsPairs
        Assert-Equal "content type" "application/json; charset=utf-8" $generations[0].contentType
        Assert-Equal "output file" $reviewPass $run.Output
        Assert-OneRecord $run "success" "" $true -Agent "spec-reviewer"
    }

    Test-Case "revise-spec success: markers, the revision on the console and in the output file, body members, think JSON true, timeouts, no added line" {
        $run = Invoke-Case -Name "rs-success" -ConfigText (New-V2Config) -Script "revise-spec.ps1" -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $revisedSpec))
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-ExactLine $run "=== Specification Reviser ==="
        Assert-ExactLine $run "Model : test-model-alpha"
        Assert-ExactLine $run "Mode  : requirements"
        Assert-ExactLine $run "Spec  : $specInputPath"
        Assert-ExactLine $run "Review: $reviewInputPath"
        Assert-ExactLine $run "Sending specification to reviser..."
        Assert-ExactLine $run "=== Revised Specification ==="
        Assert-ExactLine $run "Fake revised specification."
        foreach ($text in @("Category:", "Hint:", "Retrying", "Warning:", "=== OLLAMA ERROR ===", "ERROR")) { Assert-NoLine $run $text }
        $tags = @(Get-Route $run "tags"); $generations = @(Get-Generations $run)
        Assert-Equal "tags calls" 1 $tags.Count
        Assert-Equal "health timeout" 7 $tags[0].timeoutSec
        Assert-Equal "generate calls" 1 $generations.Count
        Assert-Equal "generate timeout" 222 $generations[0].timeoutSec
        Assert-Equal "members" "model,options,prompt,stream,system,think" $generations[0].members
        Assert-Equal "think value" "True" $generations[0].thinkValue
        Assert-True "think is a JSON boolean" ($generations[0].thinkValue -is [bool])
        Assert-Equal "output file" $revisedSpec $run.Output
        Assert-OneRecord $run "success" "" $true -Agent "spec-reviser"
    }

    foreach ($subject in $subjects) {
        Test-Case "$($subject.Label) think false: the member is present and false; think default: no member, think_sent omitted" {
            $run = Invoke-Case -Name "$($subject.Key)-think-false" -ConfigText (New-V2Config -Think "false") -Script $subject.Script -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $subject.Answer))
            Assert-Guards $run
            Assert-Equal "exit code" 0 $run.ExitCode
            $generation = @(Get-Generations $run)[0]
            Assert-Equal "members" "model,options,prompt,stream,system,think" $generation.members
            Assert-Equal "think value" "False" $generation.thinkValue
            Assert-True "think is a JSON boolean" ($generation.thinkValue -is [bool])
            $run = Invoke-Case -Name "$($subject.Key)-think-default" -ConfigText (New-V2Config -Think '"default"') -Script $subject.Script -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $subject.Answer))
            Assert-Guards $run
            Assert-Equal "members" "model,options,prompt,stream,system" (@(Get-Generations $run)[0].members)
            Assert-Equal "think_sent" "omitted" $run.Telemetry[0].think_sent
        }

        Test-Case "$($subject.Label) -Profile beta and a v1 configuration: no think member, no extra body member, legacy parameters, exit 0" {
            $run = Invoke-Case -Name "$($subject.Key)-profile-beta" -ConfigText (New-V2Config) -Script $subject.Script -Arguments @{ Profile = "beta" } `
                -TagsSteps @((New-Step "ok" @{ models = @("test-model-beta") })) -GenerateSteps @((& $okReply $subject.Answer))
            Assert-Guards $run
            Assert-Equal "exit code" 0 $run.ExitCode
            $generation = @(Get-Generations $run)[0]
            Assert-Equal "model" "test-model-beta" $generation.model
            Assert-Equal "timeout" 333 $generation.timeoutSec
            Assert-Equal "members" "model,options,prompt,stream,system" $generation.members
            $run = Invoke-Case -Name "$($subject.Key)-v1" -ConfigText $v1Valid -Script $subject.Script -TagsSteps @((New-Step "ok" @{ models = @("test-model-a") })) -GenerateSteps @((& $okReply $subject.Answer))
            Assert-Guards $run
            Assert-Equal "exit code" 0 $run.ExitCode
            $generation = @(Get-Generations $run)[0]
            Assert-Equal "model" "test-model-a" $generation.model
            Assert-Equal "timeout" 444 $generation.timeoutSec
            Assert-Equal "options" "num_ctx=4096;temperature=0.3" $generation.optionsPairs
            Assert-Equal "members" "model,options,prompt,stream,system" $generation.members
            Assert-Equal "health timeout (default)" 15 (@(Get-Route $run "tags")[0].timeoutSec)
            Assert-Equal "telemetry context_window (v1: skipped budget)" "" $run.Telemetry[0].context_window
        }

        Test-Case "$($subject.Label) trims -Model before the availability check and the request, as before" {
            $run = Invoke-Case -Name "$($subject.Key)-model-trim" -ConfigText (New-V2Config) -Script $subject.Script -Arguments @{ Model = "  test-model-alpha  " } -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $subject.Answer))
            Assert-Guards $run
            Assert-Equal "exit code" 0 $run.ExitCode
            Assert-ExactLine $run "Model : test-model-alpha"
            Assert-Equal "model in the request" "test-model-alpha" (@(Get-Generations $run)[0].model)
            Assert-Equal "model in the record" "test-model-alpha" $run.Telemetry[0].model
        }

        Test-Case "$($subject.Label) strips <think> blocks from the answer exactly as before and trims" {
            $answer = "<think>hidden reasoning</think>  " + $subject.Answer + "  "
            $run = Invoke-Case -Name "$($subject.Key)-strip-think" -ConfigText (New-V2Config) -Script $subject.Script -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "ok" @{ response = $answer; doneReason = "stop" }))
            Assert-Guards $run
            Assert-Equal "exit code" 0 $run.ExitCode
            Assert-Equal "output file" $subject.Answer $run.Output
            Assert-NoLine $run "hidden reasoning"
            Assert-Equal "thinking_chars" 16 $run.Telemetry[0].thinking_chars
        }
    }

    Test-Case "review-spec: a FAIL review exits 1 and still writes the output file; a lower-case status is accepted as before" {
        $run = Invoke-Case -Name "rv-fail" -ConfigText (New-V2Config) -Script "review-spec.ps1" -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $reviewFail))
        Assert-Guards $run
        Assert-Equal "exit code" 1 $run.ExitCode
        Assert-ExactLine $run "Review Status: FAIL"
        Assert-Equal "output file" $reviewFail $run.Output
        Assert-OneRecord $run "success" "" $true -Agent "spec-reviewer"
        $lower = "# Review`r`n`r`n## status`r`npass`r`n"
        $run = Invoke-Case -Name "rv-lower" -ConfigText (New-V2Config) -Script "review-spec.ps1" -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $lower))
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-ExactLine $run "Review Status: PASS"
    }

    Test-Case "review-spec: an output file that cannot be written exits 2 with the legacy REVIEW OUTPUT ERROR lines" {
        $unwritable = Join-Path $casesDirectory "no-such-directory\review.md"
        $run = Invoke-Case -Name "rv-unwritable" -ConfigText (New-V2Config) -Script "review-spec.ps1" -Arguments @{ OutputFile = $unwritable } -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $reviewPass))
        Assert-Guards $run
        Assert-Equal "exit code" 2 $run.ExitCode
        Assert-ExactLine $run "=== REVIEW OUTPUT ERROR ==="
        Assert-ExactLine $run "Could not write review file: $unwritable"
        Assert-NoLine $run "Review Status:"
    }

    Test-Case "revise-spec: an answer without a Status section is a success (no response check on the reviser)" {
        $run = Invoke-Case -Name "rs-no-status" -ConfigText (New-V2Config) -Script "revise-spec.ps1" -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "Plain text, no status heading."))
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-Equal "output file" "Plain text, no status heading." $run.Output
        Assert-OneRecord $run "success" "" $true -Agent "spec-reviser"
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== FR-202: errors before resolution and before the call (review-spec, revise-spec) ===" -ForegroundColor Cyan

    foreach ($subject in $subjects) {
        Test-Case "FR-202 $($subject.Label) a configuration error: the legacy exit, registry_invalid, no request, no telemetry line" {
            $run = Invoke-Case -Name "$($subject.Key)-bad-config" -ConfigText $v2Invalid -Script $subject.Script
            Assert-Guards $run
            Assert-SubjectFailureExit $subject $run
            Assert-Line $run "registry_invalid:"
            if ($subject.Key -ceq "review") { Assert-ExactLine $run "=== REVIEWER INPUT ERROR ===" }
            Assert-NoRequestNoRecord $run
        }

        Test-Case "FR-202 $($subject.Label) a blank -Model: the legacy exit and message, no request, no telemetry line" {
            $run = Invoke-Case -Name "$($subject.Key)-blank-model" -ConfigText (New-V2Config) -Script $subject.Script -Arguments @{ Model = "" }
            Assert-Guards $run
            Assert-SubjectFailureExit $subject $run
            Assert-Line $run "Model name cannot be empty."
            if ($subject.Key -ceq "review") { Assert-ExactLine $run "=== REVIEWER INPUT ERROR ===" }
            Assert-NoRequestNoRecord $run
        }

        Test-Case "FR-202 $($subject.Label) a missing specification file: the legacy exit and message, no request, no telemetry line" {
            $missing = Join-Path $casesDirectory "no-such-spec.md"
            $run = Invoke-Case -Name "$($subject.Key)-spec-missing" -ConfigText (New-V2Config) -Script $subject.Script -Arguments @{ SpecFile = $missing }
            Assert-Guards $run
            Assert-SubjectFailureExit $subject $run
            Assert-Line $run "Specification file not found: $missing"
            Assert-NoRequestNoRecord $run
        }

        Test-Case "FR-202 $($subject.Label) an empty specification file: the legacy exit and message, no request, no telemetry line" {
            $empty = Join-Path $casesDirectory "empty-spec.md"
            [System.IO.File]::WriteAllText($empty, "  `r`n", $utf8NoBom)
            $run = Invoke-Case -Name "$($subject.Key)-spec-empty" -ConfigText (New-V2Config) -Script $subject.Script -Arguments @{ SpecFile = $empty } -TagsSteps $tagsAlpha
            Assert-Guards $run
            Assert-SubjectFailureExit $subject $run
            Assert-Line $run "Specification file is empty."
            Assert-NoRequestNoRecord $run
        }
    }

    Test-Case "FR-202 revise-spec a missing or empty review file: a throw with the legacy message, no request, no telemetry line" {
        $missing = Join-Path $casesDirectory "no-such-review.md"
        $run = Invoke-Case -Name "rs-review-missing" -ConfigText (New-V2Config) -Script "revise-spec.ps1" -Arguments @{ ReviewFile = $missing }
        Assert-Guards $run
        Assert-True "a non-zero exit code" ($run.ExitCode -ne 0)
        Assert-Line $run "Review file not found: $missing"
        Assert-NoRequestNoRecord $run
        $empty = Join-Path $casesDirectory "empty-review.md"
        [System.IO.File]::WriteAllText($empty, "`r`n", $utf8NoBom)
        $run = Invoke-Case -Name "rs-review-empty" -ConfigText (New-V2Config) -Script "revise-spec.ps1" -Arguments @{ ReviewFile = $empty } -TagsSteps $tagsAlpha
        Assert-Guards $run
        Assert-True "a non-zero exit code" ($run.ExitCode -ne 0)
        Assert-Line $run "Review file is empty."
        Assert-NoRequestNoRecord $run
    }

    foreach ($subject in $subjects) {
        Test-Case "FR-202 $($subject.Label) model not installed: legacy lines, Category and Hint, the legacy exit, no generation, one record with model_called false" {
            $run = Invoke-Case -Name "$($subject.Key)-model-missing" -ConfigText (New-V2Config) -Script $subject.Script -TagsSteps @((New-Step "ok" @{ models = @("other-model-1", "other-model-2") }))
            Assert-Guards $run
            Assert-SubjectFailureExit $subject $run
            Assert-ExactLine $run "Model not found: test-model-alpha"
            Assert-ExactLine $run "Available models:"
            Assert-ExactLine $run "  - other-model-1"
            Assert-ExactLine $run "  - other-model-2"
            Assert-ExactLine $run "Category: model_not_installed"
            Assert-Line $run "Hint: "
            if ($subject.Key -ceq "revise") { Assert-Line $run "The requested Ollama model is not installed. Try: ollama pull test-model-alpha" }
            Assert-NoLine $run "Sending specification"
            Assert-Equal "generate calls" 0 (@(Get-Route $run "generate").Count)
            Assert-OneRecord $run "error" "model_not_installed" $false -Agent $subject.Agent
        }

        Test-Case "FR-202 $($subject.Label) a model name that differs only in case is installed" {
            $run = Invoke-Case -Name "$($subject.Key)-model-case" -ConfigText (New-V2Config) -Script $subject.Script -TagsSteps @((New-Step "ok" @{ models = @("TEST-MODEL-ALPHA") })) -GenerateSteps @((& $okReply $subject.Answer))
            Assert-Guards $run
            Assert-Equal "exit code" 0 $run.ExitCode
            Assert-Equal "generate calls" 1 (@(Get-Generations $run).Count)
        }

        foreach ($unreachable in @(
                @{ Name = "tags-connect"; Step = (New-Step "status" @{ webStatus = "ConnectFailure" }); Category = "transport_unreachable"; Typed = $true },
                @{ Name = "tags-timeout"; Step = (New-Step "status" @{ webStatus = "Timeout" }); Category = "timeout"; Typed = $true },
                @{ Name = "tags-plain"; Step = (New-Step "plain"); Category = "transport_other"; Typed = $false })) {
            Test-Case "FR-202 $($subject.Label) /api/tags fails ($($unreachable.Category)): the legacy 'not reachable' line, Category, the legacy exit, no generation, one record" {
                $run = Invoke-Case -Name "$($subject.Key)-$($unreachable.Name)" -ConfigText (New-V2Config) -Script $subject.Script -TagsSteps @($unreachable.Step) -TypedExceptions:$unreachable.Typed
                Assert-Guards $run
                Assert-SubjectFailureExit $subject $run
                Assert-ExactLine $run "Ollama is not reachable at $fakeUrl. Make sure Ollama is running."
                Assert-ExactLine $run "Category: $($unreachable.Category)"
                Assert-Line $run "Hint: "
                Assert-NoLine $run "Sending specification"
                Assert-Equal "tags calls" 1 (@(Get-Route $run "tags").Count)
                Assert-Equal "generate calls" 0 (@(Get-Route $run "generate").Count)
                Assert-OneRecord $run "error" $unreachable.Category $false -Agent $subject.Agent
                Assert-Equal "error column starts with the category" $true ([string]$run.Telemetry[0].error).StartsWith($unreachable.Category + ":", [System.StringComparison]::Ordinal)
            }
        }
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-202: failure matrix of review-spec and revise-spec (maxAttempts 2, retryBackoffSec 0) ===" -ForegroundColor Cyan

    foreach ($subject in $subjects) {
        $label = $subject.Label
        $key = $subject.Key

        Test-Case "AC-202 $label injected timeout: the legacy exit, Category timeout, one request, no output file, one record" {
            $run = Invoke-Case -Name "$key-m-timeout" -ConfigText $matrixConfig -Script $subject.Script -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "status" @{ webStatus = "Timeout" })) -TypedExceptions
            Assert-Guards $run
            Assert-SubjectFailureExit $subject $run
            if ($key -ceq "review") { Assert-ExactLine $run "=== OLLAMA ERROR ===" }
            Assert-Line $run "Ollama request failed: timeout:"
            Assert-ExactLine $run "Category: timeout"
            Assert-Line $run "Hint: "
            Assert-Equal "generate calls (timeout is not retried)" 1 (@(Get-Generations $run).Count)
            Assert-NoLine $run "Retrying"
            Assert-True "no output file" ($null -eq $run.Output)
            Assert-OneRecord $run "error" "timeout" $true -Agent $subject.Agent
            Assert-Equal "attempts" 1 $run.Telemetry[0].attempts
        }

        Test-Case "AC-202 $label HTTP 500 on every attempt: two requests, the retry line, http_5xx with the server detail, attempts 2, one record" {
            $run = Invoke-Case -Name "$key-m-500" -ConfigText $matrixConfig -Script $subject.Script -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "http" @{ status = 500; body = '{"error":"boom from the fake server"}' })) -RepeatLastGenerate -TypedExceptions
            Assert-Guards $run
            Assert-SubjectFailureExit $subject $run
            Assert-Equal "generate calls" 2 (@(Get-Generations $run).Count)
            if ($key -ceq "review") { Assert-ExactLine $run "=== OLLAMA ERROR ===" }
            Assert-Line $run "Ollama request failed: http_5xx: boom from the fake server"
            Assert-ExactLine $run "Category: http_5xx"
            Assert-Line $run "Hint: "
            Assert-ExactLine $run "Retrying (attempt 2 of 2) after http_5xx, waiting 0 s."
            Assert-True "no output file" ($null -eq $run.Output)
            Assert-OneRecord $run "error" "http_5xx" $true -Agent $subject.Agent
            Assert-Equal "attempts" 2 $run.Telemetry[0].attempts
            Assert-Equal "http_status" 500 $run.Telemetry[0].http_status
        }

        Test-Case "AC-202 $label HTTP 400: one request, http_4xx, no retry line, one record" {
            $run = Invoke-Case -Name "$key-m-400" -ConfigText $matrixConfig -Script $subject.Script -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "http" @{ status = 400; body = '{"error":"bad request from the fake server"}' })) -TypedExceptions
            Assert-Guards $run
            Assert-SubjectFailureExit $subject $run
            Assert-Equal "generate calls" 1 (@(Get-Generations $run).Count)
            Assert-Line $run "Ollama request failed: http_4xx: bad request from the fake server"
            Assert-ExactLine $run "Category: http_4xx"
            Assert-NoLine $run "Retrying"
            Assert-True "no output file" ($null -eq $run.Output)
            Assert-OneRecord $run "error" "http_4xx" $true -Agent $subject.Agent
            Assert-Equal "attempts" 1 $run.Telemetry[0].attempts
        }

        Test-Case "AC-202 $label a connection reset on the first attempt, then success: two requests, the legacy success exit, output file, one record, attempts 2" {
            $run = Invoke-Case -Name "$key-m-reset" -ConfigText $matrixConfig -Script $subject.Script -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "status" @{ webStatus = "ReceiveFailure" }), (& $okReply $subject.Answer)) -TypedExceptions
            Assert-Guards $run
            Assert-Equal "exit code" 0 $run.ExitCode
            Assert-Equal "generate calls" 2 (@(Get-Generations $run).Count)
            Assert-ExactLine $run "Retrying (attempt 2 of 2) after transport_reset, waiting 0 s."
            Assert-NoLine $run "=== OLLAMA ERROR ==="
            Assert-NoLine $run "Category:"
            Assert-Equal "output file" $subject.Answer $run.Output
            Assert-OneRecord $run "success" "" $true -Agent $subject.Agent
            Assert-Equal "attempts" 2 $run.Telemetry[0].attempts
        }

        Test-Case "AC-202 $label an empty response: the legacy exit and message, Category empty_response, no output file, one error record" {
            $run = Invoke-Case -Name "$key-m-empty" -ConfigText $matrixConfig -Script $subject.Script -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "ok" @{ response = "   "; doneReason = "stop" }))
            Assert-Guards $run
            Assert-SubjectFailureExit $subject $run
            if ($key -ceq "review") {
                Assert-ExactLine $run "=== REVIEWER OUTPUT ERROR ==="
                Assert-ExactLine $run "Reviewer returned an empty response."
            }
            else { Assert-Line $run "Reviser returned an empty response." }
            Assert-ExactLine $run "Category: empty_response"
            Assert-Line $run "Hint: "
            Assert-NoLine $run "=== OLLAMA ERROR ==="
            Assert-Equal "generate calls (not retried)" 1 (@(Get-Generations $run).Count)
            Assert-True "no output file" ($null -eq $run.Output)
            Assert-OneRecord $run "error" "empty_response" $true -Agent $subject.Agent
        }

        Test-Case "AC-202 $label an empty response with done_reason length: thinking_budget_exhausted, the same exit code and message" {
            $run = Invoke-Case -Name "$key-m-length" -ConfigText $matrixConfig -Script $subject.Script -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "ok" @{ response = ""; doneReason = "length"; thinking = ("t" * 40) }))
            Assert-Guards $run
            Assert-SubjectFailureExit $subject $run
            if ($key -ceq "review") { Assert-ExactLine $run "Reviewer returned an empty response." } else { Assert-Line $run "Reviser returned an empty response." }
            Assert-ExactLine $run "Category: thinking_budget_exhausted"
            Assert-True "no output file" ($null -eq $run.Output)
            Assert-OneRecord $run "error" "thinking_budget_exhausted" $true -Agent $subject.Agent
            Assert-Equal "thinking_chars" 40 $run.Telemetry[0].thinking_chars
        }

        Test-Case "AC-202 $label maxAttempts 1 disables the retry (one request, attempts 1)" {
            $run = Invoke-Case -Name "$key-m-attempts-1" -ConfigText (New-V2Config -MaxAttempts 1) -Script $subject.Script -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "http" @{ status = 503; body = "" })) -RepeatLastGenerate -TypedExceptions
            Assert-Guards $run
            Assert-SubjectFailureExit $subject $run
            Assert-Equal "generate calls" 1 (@(Get-Generations $run).Count)
            Assert-NoLine $run "Retrying"
            Assert-OneRecord $run "error" "http_5xx" $true -Agent $subject.Agent
            Assert-Equal "attempts" 1 $run.Telemetry[0].attempts
        }

        Test-Case "AC-214 $label the localized exception message of a failed request never reaches the console or the record (OQ-214)" {
            $run = Invoke-Case -Name "$key-m-plain" -ConfigText $matrixConfig -Script $subject.Script -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "plain"))
            Assert-Guards $run
            Assert-SubjectFailureExit $subject $run
            Assert-NoLine $run "plain failure"
            Assert-ExactLine $run "Category: transport_other"
            Assert-OneRecord $run "error" "transport_other" $true -Agent $subject.Agent
            Assert-Equal "error column starts with the category" $true ([string]$run.Telemetry[0].error).StartsWith("transport_other:", [System.StringComparison]::Ordinal)
            Assert-Equal "the sentinel text is not in the error column" $false ([string]$run.Telemetry[0].error).Contains("plain failure")
        }
    }

    foreach ($noStatus in @(
            @{ Name = "no-section"; Text = "The specification looks fine to me, no section here." },
            @{ Name = "wrong-value"; Text = "# Review`r`n`r`n## Status`r`n`r`nMAYBE`r`n" },
            @{ Name = "not-a-heading"; Text = "# Review`r`n`r`nStatus: PASS`r`n" })) {
        Test-Case "AC-202 review-spec an answer without a valid Status section ($($noStatus.Name)): the legacy exit and REVIEW VALIDATION ERROR lines, format_invalid, one request, no output file" {
            $run = Invoke-Case -Name "rv-m-$($noStatus.Name)" -ConfigText $matrixConfig -Script "review-spec.ps1" -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $noStatus.Text))
            Assert-Guards $run
            Assert-Equal "exit code" 2 $run.ExitCode
            Assert-ExactLine $run "=== REVIEW VALIDATION ERROR ==="
            Assert-ExactLine $run "Reviewer did not return a valid Status section."
            Assert-ExactLine $run "Expected:"
            Assert-ExactLine $run "## Status"
            Assert-ExactLine $run "PASS or FAIL"
            Assert-ExactLine $run "Category: format_invalid"
            Assert-Line $run "Hint: "
            Assert-NoLine $run "Review Status:"
            Assert-NoLine $run "Retrying"
            Assert-Equal "generate calls (format_invalid is not retried)" 1 (@(Get-Generations $run).Count)
            Assert-True "no output file" ($null -eq $run.Output)
            Assert-OneRecord $run "error" "format_invalid" $true -Agent "spec-reviewer"
            Assert-Equal "error column" "format_invalid: status_missing" $run.Telemetry[0].error
        }
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-203: an oversized prompt (review-spec, revise-spec) ===" -ForegroundColor Cyan

    foreach ($subject in $subjects) {
        Test-Case "AC-203 $($subject.Label) enforce: the legacy exit, Category context_budget_exceeded, one line per section, no generate, no warm-up, one record with model_called false" {
            $run = Invoke-Case -Name "$($subject.Key)-budget-enforce" -ConfigText $tinyEnforce -Script $subject.Script -TaskFile $bigTask -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "never sent"))
            Assert-Guards $run
            Assert-SubjectFailureExit $subject $run
            Assert-ExactLine $run "Category: context_budget_exceeded"
            Assert-Line $run "Hint: "
            Assert-Line $run "Estimated "
            Assert-Equal "generate calls (and warm-ups)" 0 (@(Get-Route $run "generate").Count)
            Assert-Equal "warm-up calls" 0 (@(Get-Warmups $run).Count)
            $sectionLines = @($run.Lines | Where-Object { $_ -match '^  \S+ \((instruction|data)\): \d+ characters, about \d+ tokens$' })
            Assert-Equal "section lines (one per part of the prompt)" $subject.SectionLines $sectionLines.Count
            Assert-ExactLine $run "  task (data): 4000 characters, about 1143 tokens"
            Assert-True "no output file" ($null -eq $run.Output)
            Assert-OneRecord $run "error" "context_budget_exceeded" $false -Agent $subject.Agent
            $record = $run.Telemetry[0]
            Assert-Equal "context_window" 1000 $record.context_window
            Assert-True "est_prompt_tokens above the available 800" ([long]$record.est_prompt_tokens -gt 800)
            Assert-Equal "think_sent is blank on a refusal" "" $record.think_sent
            Assert-Equal "attempts is blank on a refusal" "" $record.attempts
        }

        foreach ($warnCase in @(@{ Name = "budget-warn"; Config = $tinyWarn; Label = "warn" }, @{ Name = "budget-default"; Config = $tinyDefault; Label = "the default (no budgetMode key)" })) {
            Test-Case "AC-203 $($subject.Label) $($warnCase.Label): the same prompt is sent, one Warning line, the legacy success exit, the record carries the warning" {
                $run = Invoke-Case -Name "$($subject.Key)-$($warnCase.Name)" -ConfigText $warnCase.Config -Script $subject.Script -TaskFile $bigTask -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $subject.Answer))
                Assert-Guards $run
                Assert-Equal "exit code" 0 $run.ExitCode
                Assert-Equal "generate calls" 1 (@(Get-Generations $run).Count)
                $system = ConvertFrom-Base64Utf8 (@(Get-Generations $run)[0].systemB64)
                $prompt = ConvertFrom-Base64Utf8 (@(Get-Generations $run)[0].promptB64)
                $estimated = [long][math]::Ceiling([decimal]($system.Length + $prompt.Length) / [decimal]3.5)
                Assert-ExactLine $run "Warning: budget_exceeded (estimated $estimated tokens, available 800)."
                Assert-Equal "warning lines" 1 @($run.Lines | Where-Object { $_.StartsWith("Warning:", [System.StringComparison]::Ordinal) }).Count
                Assert-NoLine $run "Category:"
                Assert-Equal "output file" $subject.Answer $run.Output
                Assert-OneRecord $run "success" "" $true -Agent $subject.Agent
                Assert-Equal "warnings column" "budget_exceeded" $run.Telemetry[0].warnings
                Assert-Equal "est_prompt_tokens" $estimated $run.Telemetry[0].est_prompt_tokens
                Assert-Equal "prompt_chars" ($system.Length + $prompt.Length) $run.Telemetry[0].prompt_chars
            }
        }

        Test-Case "AC-203 $($subject.Label) a prompt that fits prints no Warning line and writes an empty warnings column" {
            $run = Invoke-Case -Name "$($subject.Key)-budget-fits" -ConfigText (New-V2Config) -Script $subject.Script -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $subject.Answer)) -TaskFile $taskPath
            Assert-Guards $run
            Assert-Equal "exit code" 0 $run.ExitCode
            Assert-NoLine $run "Warning:"
            Assert-Equal "warnings column" "" $run.Telemetry[0].warnings
        }
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-214: the telemetry record of the reviewer and the reviser ===" -ForegroundColor Cyan

    foreach ($subject in $subjects) {
        Test-Case "AC-214 $($subject.Label) success record: every field of FR-216, literal expectations, run_id and call_id" {
            $run = Invoke-Case -Name "$($subject.Key)-t-success" -ConfigText (New-V2Config) -Script $subject.Script -TaskFile $taskPath -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $subject.Answer)) -RunId "wp2d2-run-id"
            Assert-Guards $run
            Assert-Equal "exit code" 0 $run.ExitCode
            Assert-OneRecord $run "success" "" $true -Agent $subject.Agent
            $record = $run.Telemetry[0]
            $system = ConvertFrom-Base64Utf8 (@(Get-Generations $run)[0].systemB64)
            $prompt = ConvertFrom-Base64Utf8 (@(Get-Generations $run)[0].promptB64)
            Assert-Equal "model" "test-model-alpha" $record.model
            Assert-Equal "profile" "alpha" $record.profile
            Assert-Equal "transport" "blocking" $record.transport
            Assert-Equal "attempts" 1 $record.attempts
            Assert-Equal "http_status (not measured on a success)" "" $record.http_status
            Assert-Equal "done_reason" "stop" $record.done_reason
            Assert-Equal "thinking_chars" 0 $record.thinking_chars
            Assert-Equal "think_sent" "true" $record.think_sent
            Assert-Equal "timeout_sec" 222 $record.timeout_sec
            Assert-Equal "context_window" 8192 $record.context_window
            Assert-Equal "prompt_chars" ($system.Length + $prompt.Length) $record.prompt_chars
            Assert-Equal "est_prompt_tokens" ([long][math]::Ceiling([decimal]($system.Length + $prompt.Length) / [decimal]3.5)) $record.est_prompt_tokens
            Assert-Equal "warnings" "" $record.warnings
            Assert-Equal "eval_count" 10 $record.eval_count
            Assert-Equal "run_id follows AI_HARNESS_RUN_ID" "wp2d2-run-id" $record.run_id
            $parsed = [guid]::Empty
            Assert-True "call_id is a GUID" ([guid]::TryParse([string]$record.call_id, [ref]$parsed))
        }

        Test-Case "AC-214 $($subject.Label) run_id is a GUID when AI_HARNESS_RUN_ID is unset, and call_id differs between two calls" {
            $first = Invoke-Case -Name "$($subject.Key)-t-run-a" -ConfigText (New-V2Config) -Script $subject.Script -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $subject.Answer))
            $second = Invoke-Case -Name "$($subject.Key)-t-run-b" -ConfigText (New-V2Config) -Script $subject.Script -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply $subject.Answer))
            Assert-Guards $first; Assert-Guards $second
            $parsed = [guid]::Empty
            Assert-True "run_id is a GUID" ([guid]::TryParse([string]$first.Telemetry[0].run_id, [ref]$parsed))
            Assert-True "call_id differs between two calls" ([string]$first.Telemetry[0].call_id -cne [string]$second.Telemetry[0].call_id)
        }
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== Final QA N-14, N-15: the Warning line, the line order of a failure block, the hint of each category ===" -ForegroundColor Cyan

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

    foreach ($warnOnly in @(
            @{ Key = "run"; Script = "run-agent.ps1"; Answer = "Partial answer."; Agent = "spec" },
            @{ Key = "review"; Script = "review-spec.ps1"; Answer = $reviewPass; Agent = "spec-reviewer" },
            @{ Key = "revise"; Script = "revise-spec.ps1"; Answer = $revisedSpec; Agent = "spec-reviser" })) {
        Test-Case "N-14 $($warnOnly.Script) a warning other than budget_exceeded (output_truncated) prints no Warning line; exit 0, the record carries the warning" {
            $run = Invoke-Case -Name "n14-$($warnOnly.Key)-truncated" -ConfigText (New-V2Config) -Script $warnOnly.Script -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "ok" @{ response = $warnOnly.Answer; doneReason = "length" }))
            Assert-Guards $run
            Assert-Equal "exit code" 0 $run.ExitCode
            Assert-Equal "generate calls" 1 (@(Get-Generations $run).Count)
            Assert-NoLine $run "Warning:"
            Assert-NoLine $run "Category:"
            Assert-Equal "output file" $warnOnly.Answer $run.Output
            Assert-OneRecord $run "success" "" $true -Agent $warnOnly.Agent
            Assert-Equal "warnings column" "output_truncated" $run.Telemetry[0].warnings
        }
    }

    Test-Case "N-15 run-agent failure block: the lines are consecutive in the order OLLAMA ERROR, Status, detail, Category, Hint, END" {
        $run = Invoke-Case -Name "n15-run-500" -ConfigText $matrixConfig -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "http" @{ status = 500; body = '{"error":"boom from the fake server"}' })) -RepeatLastGenerate -TypedExceptions
        Assert-Guards $run
        Assert-Equal "exit code" 1 $run.ExitCode
        Assert-LineBlock $run @("=== OLLAMA ERROR ===", "Status: 500", "boom from the fake server", "Category: http_5xx", @{ Prefix = "Hint: "; Contains = "GPU or CUDA" }, "=== END OLLAMA ERROR ===")
    }

    Test-Case "N-15 run-agent a failure without an HTTP status: no Status line, the block is OLLAMA ERROR, detail, Category, Hint, END" {
        $run = Invoke-Case -Name "n15-run-timeout" -ConfigText $matrixConfig -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "status" @{ webStatus = "Timeout" })) -TypedExceptions
        Assert-Guards $run
        Assert-LineBlock $run @("=== OLLAMA ERROR ===", @{ Prefix = "System.Net.WebException"; Contains = "Timeout" }, "Category: timeout", @{ Prefix = "Hint: "; Contains = "timeoutSec" }, "=== END OLLAMA ERROR ===")
    }

    Test-Case "N-15 run-agent budget refusal: Category, Hint, the Estimated line, then the section lines" {
        $run = Invoke-Case -Name "n15-run-budget" -ConfigText $tinyEnforce -TaskFile $bigTask -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "never sent"))
        Assert-Guards $run
        Assert-LineBlock $run @("Category: context_budget_exceeded", @{ Prefix = "Hint: "; Contains = "does not fit the context budget" }, @{ Prefix = "Estimated "; Contains = " tokens, available 800." }, @{ Prefix = "  "; Contains = " characters, about " })
    }

    foreach ($hintCase in @(
            @{ Name = "reset"; Steps = @((New-Step "status" @{ webStatus = "ReceiveFailure" })); Repeat = $true; Typed = $true; Tags = $tagsAlpha; Category = "transport_reset"; Phrase = "dropped" },
            @{ Name = "4xx"; Steps = @((New-Step "http" @{ status = 400; body = '{"error":"bad"}' })); Repeat = $false; Typed = $true; Tags = $tagsAlpha; Category = "http_4xx"; Phrase = "Ollama rejected the request" },
            @{ Name = "empty"; Steps = @((New-Step "ok" @{ response = " "; doneReason = "stop" })); Repeat = $false; Typed = $false; Tags = $tagsAlpha; Category = "empty_response"; Phrase = "empty answer" },
            @{ Name = "exhausted"; Steps = @((New-Step "ok" @{ response = ""; doneReason = "length" })); Repeat = $false; Typed = $false; Tags = $tagsAlpha; Category = "thinking_budget_exhausted"; Phrase = "reasoning" },
            @{ Name = "other"; Steps = @((New-Step "plain")); Repeat = $false; Typed = $false; Tags = $tagsAlpha; Category = "transport_other"; Phrase = "does not classify" },
            @{ Name = "unreachable"; Steps = @(); Repeat = $false; Typed = $true; Tags = @((New-Step "status" @{ webStatus = "ConnectFailure" })); Category = "transport_unreachable"; Phrase = "Ollama server is running" },
            @{ Name = "tags-timeout"; Steps = @(); Repeat = $false; Typed = $true; Tags = @((New-Step "status" @{ webStatus = "Timeout" })); Category = "timeout"; Phrase = "timeoutSec" },
            @{ Name = "not-installed"; Steps = @(); Repeat = $false; Typed = $false; Tags = @((New-Step "ok" @{ models = @("other-model") })); Category = "model_not_installed"; Phrase = "ollama pull" })) {
        foreach ($target in @(
                @{ Key = "run"; Script = "run-agent.ps1" },
                @{ Key = "review"; Script = "review-spec.ps1" },
                @{ Key = "revise"; Script = "revise-spec.ps1" })) {
            # the availability hints (unreachable, tags timeout, not installed) are
            # printed by every script; the generation hints are pinned for run-agent
            # here and for the other two below and in the failure-block cases
            $generationOnly = ($hintCase.Steps.Count -gt 0)
            if ($generationOnly -and $target.Key -cne "run") { continue }
            Test-Case "N-15 $($target.Script) the hint of $($hintCase.Category) ($($hintCase.Name)) follows its Category line and names the category's own wording" {
                $run = Invoke-Case -Name "n15-$($target.Key)-hint-$($hintCase.Name)" -ConfigText $matrixConfig -Script $target.Script -TagsSteps $hintCase.Tags -GenerateSteps $hintCase.Steps -RepeatLastGenerate:$hintCase.Repeat -TypedExceptions:$hintCase.Typed
                Assert-Guards $run
                Assert-True "a failure exit code" ($run.ExitCode -ne 0)
                Assert-CategoryHint $run $hintCase.Category $hintCase.Phrase
            }
        }
    }

    foreach ($reviewHint in @(
            @{ Name = "500"; Step = (New-Step "http" @{ status = 500; body = '{"error":"boom from the fake server"}' }); Category = "http_5xx"; Phrase = "GPU or CUDA" },
            @{ Name = "timeout"; Step = (New-Step "status" @{ webStatus = "Timeout" }); Category = "timeout"; Phrase = "timeoutSec" })) {
        foreach ($target in @(@{ Key = "review"; Script = "review-spec.ps1" }, @{ Key = "revise"; Script = "revise-spec.ps1" })) {
            Test-Case "N-15 $($target.Script) the hint of $($reviewHint.Category) follows its Category line" {
                $run = Invoke-Case -Name "n15-$($target.Key)-hint-$($reviewHint.Name)" -ConfigText $matrixConfig -Script $target.Script -TagsSteps $tagsAlpha -GenerateSteps @($reviewHint.Step) -RepeatLastGenerate -TypedExceptions
                Assert-Guards $run
                Assert-True "a failure exit code" ($run.ExitCode -ne 0)
                Assert-CategoryHint $run $reviewHint.Category $reviewHint.Phrase
            }
        }
    }

    Test-Case "N-15 review-spec failure blocks: OLLAMA ERROR, the failed-request line, Category, Hint; REVIEWER OUTPUT ERROR, message, Category, Hint" {
        $run = Invoke-Case -Name "n15-rv-500" -ConfigText $matrixConfig -Script "review-spec.ps1" -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "http" @{ status = 500; body = '{"error":"boom from the fake server"}' })) -RepeatLastGenerate -TypedExceptions
        Assert-Guards $run
        Assert-Equal "exit code" 2 $run.ExitCode
        Assert-LineBlock $run @("=== OLLAMA ERROR ===", "Ollama request failed: http_5xx: boom from the fake server", "Category: http_5xx", @{ Prefix = "Hint: "; Contains = "GPU or CUDA" })
        $empty = Invoke-Case -Name "n15-rv-empty" -ConfigText $matrixConfig -Script "review-spec.ps1" -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "ok" @{ response = " "; doneReason = "stop" }))
        Assert-Guards $empty
        Assert-LineBlock $empty @("=== REVIEWER OUTPUT ERROR ===", "Reviewer returned an empty response.", "Category: empty_response", @{ Prefix = "Hint: "; Contains = "empty answer" })
    }

    Test-Case "N-15 review-spec validation block: the Expected lines come first, then Category and Hint (format_invalid hint)" {
        $run = Invoke-Case -Name "n15-rv-format" -ConfigText $matrixConfig -Script "review-spec.ps1" -TagsSteps $tagsAlpha -GenerateSteps @((& $okReply "No status section in this answer."))
        Assert-Guards $run
        Assert-Equal "exit code" 2 $run.ExitCode
        Assert-LineBlock $run @("=== REVIEW VALIDATION ERROR ===", "Reviewer did not return a valid Status section.", "", "Expected:", "", "## Status", "PASS or FAIL", "Category: format_invalid", @{ Prefix = "Hint: "; Contains = "expected format" })
    }

    Test-Case "N-15 revise-spec failure: Category, then Hint (the thrown text goes to the error stream)" {
        $run = Invoke-Case -Name "n15-rs-empty" -ConfigText $matrixConfig -Script "revise-spec.ps1" -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "ok" @{ response = " "; doneReason = "stop" }))
        Assert-Guards $run
        Assert-True "a failure exit code" ($run.ExitCode -ne 0)
        Assert-CategoryHint $run "empty_response" "empty answer"
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-216: interfaces are preserved (review-spec, revise-spec) ===" -ForegroundColor Cyan

    Test-Case "AC-216 the parameter block of review-spec.ps1 equals the baseline list (names, types, mandatory flags, ValidateSet, default)" {
        $baseline = @(
            "Task:string:mandatory=True:set=:default=:other=",
            "SpecFile:string:mandatory=True:set=:default=:other=",
            'Mode:string:mandatory=False:set=requirements/baseline/documentation:default="requirements":other=',
            "Model:string:mandatory=False:set=:default=:other=",
            "OutputFile:string:mandatory=False:set=:default=:other=",
            "Profile:string:mandatory=False:set=:default=:other=")
        Assert-Equal "parameters" ($baseline -join "|") ((Get-ParameterSummary (Join-Path $scriptsDirectory "review-spec.ps1")) -join "|")
    }

    Test-Case "AC-216 the parameter block of revise-spec.ps1 equals the baseline list (names, types, mandatory flags, ValidateSet, default)" {
        $baseline = @(
            "Task:string:mandatory=True:set=:default=:other=",
            "SpecFile:string:mandatory=True:set=:default=:other=",
            "ReviewFile:string:mandatory=True:set=:default=:other=",
            'Mode:string:mandatory=False:set=requirements/baseline/documentation:default="requirements":other=',
            "Model:string:mandatory=False:set=:default=:other=",
            "OutputFile:string:mandatory=False:set=:default=:other=",
            "Profile:string:mandatory=False:set=:default=:other=")
        Assert-Equal "parameters" ($baseline -join "|") ((Get-ParameterSummary (Join-Path $scriptsDirectory "revise-spec.ps1")) -join "|")
    }

    Test-Case "AC-216 review-spec and revise-spec reject a -Mode outside the ValidateSet before any request or record" {
        foreach ($subject in $subjects) {
            $run = Invoke-Case -Name "$($subject.Key)-bad-mode" -ConfigText (New-V2Config) -Script $subject.Script -Arguments @{ Mode = "everything" } -TagsSteps $tagsAlpha
            Assert-Guards $run
            Assert-True "a non-zero exit code" ($run.ExitCode -ne 0)
            Assert-NoRequestNoRecord $run
        }
    }

    foreach ($subject in $subjects) {
        Test-Case "WP-2D hook rule (F-07): the -OnRetry script block of $($subject.Script) reads only its own parameters, and no -Transport or -Sleep is passed" {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsDirectory $subject.Script), [ref]$tokens, [ref]$errors)
            Assert-Equal "parse errors" 0 @($errors).Count
            $hook = Get-HookInfo $ast '$retryNotice'
            Assert-Equal "parameters of the hook" 4 @($hook.Declared).Count
            if (@($hook.Foreign).Count -gt 0) { throw "the hook reads variables that are not its parameters: $($hook.Foreign -join ', ')" }
            $expected = "Agent,Execution,OnRetry,Parts,Prompt,Registry,System,TelemetryRoot"
            if ($subject.Key -ceq "review") { $expected = "Agent,Execution,OnRetry,Parts,Prompt,Registry,ResponseCheck,System,TelemetryRoot" }
            Assert-Equal "parameters passed to Invoke-AgentModel" $expected (Get-EngineCallParameters $ast)
        }
    }

    Test-Case "WP-2D hook rule (F-07): the -ResponseCheck script block of review-spec.ps1 reads only its own parameter" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsDirectory "review-spec.ps1"), [ref]$tokens, [ref]$errors)
        $hook = Get-HookInfo $ast '$statusCheck'
        Assert-Equal "parameters of the hook" 1 @($hook.Declared).Count
        if (@($hook.Foreign).Count -gt 0) { throw "the hook reads variables that are not its parameter: $($hook.Foreign -join ', ')" }
    }

    Test-Case "AC-322 the wrappers are gone: not defined in agent-exec.ps1, no command in the libraries, no file under scripts\ or tests\ names them (FR-314)" {
        $wrapperNames = @(("Invoke-Harness" + "Generate"), ("Test-Harness" + "ModelAvailable"))
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsDirectory "lib\agent-exec.ps1"), [ref]$tokens, [ref]$errors)
        Assert-Equal "parse errors" 0 @($errors).Count
        $definedNames = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
        foreach ($name in $wrapperNames) {
            if ($definedNames -contains $name) { throw "agent-exec.ps1 still defines $name" }
        }
        $found = & {
            . (Join-Path $scriptsDirectory "lib\config.ps1")
            . (Join-Path $scriptsDirectory "lib\telemetry.ps1")
            . (Join-Path $scriptsDirectory "lib\agent-exec.ps1")
            @($wrapperNames | Where-Object { $null -ne (Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue) })
        }
        Assert-Equal "wrapper commands found after dot-sourcing" 0 @($found).Count
        $repositoryRoot = Split-Path -Parent $scriptsDirectory
        $naming = @()
        foreach ($directory in @($scriptsDirectory, (Join-Path $repositoryRoot "tests"))) {
            if (-not (Test-Path -LiteralPath $directory)) { continue }
            foreach ($file in Get-ChildItem -LiteralPath $directory -File -Recurse) {
                $text = [System.IO.File]::ReadAllText($file.FullName)
                foreach ($name in $wrapperNames) {
                    if ($text.IndexOf($name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $naming += "$($file.Name) names $name" }
                }
            }
        }
        Assert-Equal "files naming a wrapper" "" ($naming -join "; ")
    }
}
finally {
    $env:AI_HARNESS_MODEL = $originalModelVariable
    $env:AI_HARNESS_RUN_ID = $originalRunId
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "              TEST SUMMARY" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Passed: $script:passed"
Write-Host "Failed: $script:failed"

if ($script:failed -eq 0) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "STATUS: FAIL" -ForegroundColor Red
exit 1
