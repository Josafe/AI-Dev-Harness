<#
.SYNOPSIS
    Offline child-process suite for the engine call sites (Phase 2, WP-2D1:
    run-agent.ps1 and the deprecated wrappers).

.DESCRIPTION
    Covers, for run-agent.ps1: AC-201 (script part: the system and prompt strings
    the real script sends equal the goldens), AC-202 (failure matrix: legacy exit
    code, error category, exactly one telemetry line), AC-203 (an oversized prompt
    stops before any request in enforce mode and is sent with a warning in warn
    mode), AC-213 (child-process part: the default transport reaches the fake
    Invoke-RestMethod with the profile's timeoutSec and healthTimeoutSec) and
    AC-216 (parameter block, exit codes, the wrappers Invoke-HarnessGenerate and
    Test-HarnessModelAvailable). WP-2D2 adds review-spec.ps1 and revise-spec.ps1.

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

    Copy-Item -LiteralPath (Join-Path $scriptsDirectory "run-agent.ps1") -Destination (Join-Path $harnessRoot "scripts\run-agent.ps1")
    Get-ChildItem -LiteralPath (Join-Path $scriptsDirectory "lib") -Filter "*.ps1" -File |
        Where-Object { $_.Extension -eq ".ps1" } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $harnessRoot "scripts\lib\$($_.Name)") }
    Copy-Item -LiteralPath (Join-Path $mocksDirectory "fake-web-response.ps1") -Destination (Join-Path $tempRoot "mocks\fake-web-response.ps1")

    # The golden inputs are the project files of the agent: bytes copied unchanged.
    Copy-Item -LiteralPath (Join-Path $inputsDirectory "project-instructions.txt") -Destination (Join-Path $harnessRoot "AGENTS.md")
    Copy-Item -LiteralPath (Join-Path $inputsDirectory "agent-contract.txt") -Destination (Join-Path $harnessRoot ".ai\rules\agent-contract.md")
    Copy-Item -LiteralPath (Join-Path $inputsDirectory "role-a.txt") -Destination (Join-Path $harnessRoot ".ai\agents\spec.md")
    Copy-Item -LiteralPath (Join-Path $inputsDirectory "role-b.txt") -Destination (Join-Path $harnessRoot ".ai\agents\developer.md")
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

    # Guard 3: URL allowlist. Anything else is refused before any request.
    if (-not $Uri.StartsWith("http://127.0.0.1:9/", [System.StringComparison]::Ordinal)) {
        Write-FakeCall @{ uri = $Uri; method = $Method; violation = $true }
        throw "Fake Invoke-RestMethod: URI not allowed, no request sent: $Uri"
    }

    $entry = @{ uri = $Uri; method = $Method; violation = $false; timeoutSec = $TimeoutSec; contentType = [string]$ContentType }
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
    Write-Host "FAKE-HOST: unhandled error"
    $exitCode = 1
}
exit $exitCode
'@
    [System.IO.File]::WriteAllText($fakeHost, $fakeHostSource, $utf8NoBom)

    # Driver of the wrapper cases: runs one deprecated wrapper inside the fake host
    # and prints markers the suite can read.
    $driverSource = @'
param([string]$Case, [string]$Root)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\config.ps1")
. (Join-Path $PSScriptRoot "lib\telemetry.ps1")
. (Join-Path $PSScriptRoot "lib\agent-exec.ps1")

$config = Get-HarnessConfig -ConfigPath (Join-Path $Root ".ai\config.json")

switch ($Case) {
    "generate" {
        $text = Invoke-HarnessGenerate -Model "test-model-alpha" -System "AB" -Prompt "CDE" -Config $config
        Write-Host "TEXT[$text]"
    }
    "generate-telemetry" {
        $text = Invoke-HarnessGenerate -Model "test-model-alpha" -System "AB" -Prompt "CDE" -Config $config -TelemetryAgent "driver-agent" -TelemetryRoot $Root
        Write-Host "TEXT[$text]"
    }
    "generate-throws" {
        try {
            $text = Invoke-HarnessGenerate -Model "test-model-alpha" -System "AB" -Prompt "CDE" -Config $config
            Write-Host "NOTHROW[$text]"
        }
        catch {
            Write-Host "THROW[$($_.Exception.Message)]"
        }
    }
    "available" {
        $problem = Test-HarnessModelAvailable -Model "test-model-alpha" -Config $config
        Write-Host "PROBLEM[$problem]"
        Write-Host "PROBLEM-COUNT[$(@($problem).Count)]"
    }
}
exit 0
'@
    [System.IO.File]::WriteAllText((Join-Path $harnessRoot "scripts\wrapper-driver.ps1"), $driverSource, $utf8NoBom)
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
        [switch]$TypedExceptions
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
    foreach ($key in $Arguments.Keys) { $scriptArguments[$key] = $Arguments[$key] }
    if ($Script -ceq "wrapper-driver.ps1") { $scriptArguments.Root = $harnessRoot }

    $scenario = [ordered]@{
        script           = (Join-Path $harnessRoot "scripts\$Script")
        arguments        = $scriptArguments
        taskFile         = $TaskFile
        callLog          = $callLog
        typedExceptions  = [bool]$TypedExceptions
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
    param($Run, [string]$Status, [string]$Category, [bool]$ModelCalled)
    if ($Run.Telemetry.Count -ne 1) { throw "expected exactly one telemetry line, got $($Run.Telemetry.Count)" }
    $record = $Run.Telemetry[0]
    Assert-Equal "telemetry agent" "spec" $record.agent
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
    "developer": { "profile": "alpha" }
  }
}
"@
}

$v2Invalid = "{ ""schemaVersion"": 3, ""ollama"": { ""url"": ""$fakeUrl"" } }"
$v1Valid = "{ ""ollamaUrl"": ""$fakeUrl"", ""defaultModel"": ""test-model-a"", ""options"": { ""temperature"": 0.3, ""num_ctx"": 4096 }, ""timeoutSec"": 444 }"

$tagsAlpha = @((New-Step "ok" @{ models = @("test-model-alpha") }))
$okReply = { param($Text) (New-Step "ok" @{ response = $Text; doneReason = "stop" }) }

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
    $allowedRestCalls = @("agent-exec.ps1:Invoke-OllamaHttp", "config.ps1:Invoke-HarnessGenerate", "config.ps1:Test-HarnessModelAvailable")
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

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-216: the deprecated wrappers keep their names, parameters and behavior ===" -ForegroundColor Cyan

    Test-Case "AC-216 Invoke-HarnessGenerate and Test-HarnessModelAvailable exist after dot-sourcing the three libraries with the baseline parameters" {
        $problems = & {
            . (Join-Path $scriptsDirectory "lib\config.ps1")
            . (Join-Path $scriptsDirectory "lib\telemetry.ps1")
            . (Join-Path $scriptsDirectory "lib\agent-exec.ps1")
            $generate = Get-Command Invoke-HarnessGenerate -CommandType Function
            $available = Get-Command Test-HarnessModelAvailable -CommandType Function
            $found = @()
            $found += "generate:" + ((@($generate.Parameters.Keys | Where-Object { @("Verbose", "Debug", "ErrorAction", "WarningAction", "InformationAction", "ErrorVariable", "WarningVariable", "InformationVariable", "OutVariable", "OutBuffer", "PipelineVariable") -notcontains $_ })) -join ",")
            $found += "available:" + ((@($available.Parameters.Keys | Where-Object { @("Verbose", "Debug", "ErrorAction", "WarningAction", "InformationAction", "ErrorVariable", "WarningVariable", "InformationVariable", "OutVariable", "OutBuffer", "PipelineVariable") -notcontains $_ })) -join ",")
            $mandatory = @($generate.Parameters.Values | Where-Object { $_.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory } } | ForEach-Object { $_.Name } | Sort-Object)
            $found += "generate-mandatory:" + ($mandatory -join ",")
            $found
        }
        Assert-Equal "Invoke-HarnessGenerate parameters" "generate:Model,System,Prompt,Config,TelemetryAgent,TelemetryRoot,Execution" $problems[0]
        Assert-Equal "Test-HarnessModelAvailable parameters" "available:Model,Config" $problems[1]
        Assert-Equal "Invoke-HarnessGenerate mandatory" "generate-mandatory:Config,Model,Prompt,System" $problems[2]
    }

    Test-Case "AC-216 Invoke-HarnessGenerate returns the trimmed text with <think> blocks removed (no think member without -Execution)" {
        $run = Invoke-Case -Name "w-generate" -ConfigText (New-V2Config) -Script "wrapper-driver.ps1" -Arguments @{ Case = "generate" } `
            -GenerateSteps @((New-Step "ok" @{ response = "<think>x</think>  Wrapper answer.  "; doneReason = "stop" }))
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-ExactLine $run "TEXT[Wrapper answer.]"
        $generation = @(Get-Generations $run)[0]
        Assert-Equal "members" "model,options,prompt,stream,system" $generation.members
        Assert-Equal "system" "AB" (ConvertFrom-Base64Utf8 $generation.systemB64)
        Assert-Equal "prompt" "CDE" (ConvertFrom-Base64Utf8 $generation.promptB64)
        Assert-Equal "timeout (the registry default, no -Execution)" 111 $generation.timeoutSec
        Assert-Equal "telemetry lines (none without TelemetryAgent and TelemetryRoot)" 0 $run.Telemetry.Count
    }

    Test-Case "AC-216 Invoke-HarnessGenerate returns an empty string for an empty answer (the callers check it)" {
        $run = Invoke-Case -Name "w-generate-empty" -ConfigText (New-V2Config) -Script "wrapper-driver.ps1" -Arguments @{ Case = "generate" } `
            -GenerateSteps @((New-Step "ok" @{ response = "   "; doneReason = "stop" }))
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-ExactLine $run "TEXT[]"
    }

    Test-Case "AC-216 Invoke-HarnessGenerate throws a message starting with 'Ollama request failed:' when the request fails" {
        $run = Invoke-Case -Name "w-generate-throws" -ConfigText (New-V2Config) -Script "wrapper-driver.ps1" -Arguments @{ Case = "generate-throws" } `
            -GenerateSteps @((New-Step "http" @{ status = 400; body = '{"error":"wrapper failure"}' })) -TypedExceptions
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        $thrown = @($run.Lines | Where-Object { $_.StartsWith("THROW[Ollama request failed:", [System.StringComparison]::Ordinal) })
        Assert-Equal "throw lines" 1 $thrown.Count
        Assert-NoLine $run "NOTHROW"
    }

    Test-Case "AC-216 Invoke-HarnessGenerate with -TelemetryAgent and -TelemetryRoot writes exactly one record" {
        $run = Invoke-Case -Name "w-generate-telemetry" -ConfigText (New-V2Config) -Script "wrapper-driver.ps1" -Arguments @{ Case = "generate-telemetry" } `
            -GenerateSteps @((& $okReply "Wrapper answer."))
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-Equal "telemetry lines" 1 $run.Telemetry.Count
        Assert-Equal "agent" "driver-agent" $run.Telemetry[0].agent
        Assert-Equal "status" "success" $run.Telemetry[0].status
        Assert-Equal "model" "test-model-alpha" $run.Telemetry[0].model
    }

    Test-Case "AC-216 Test-HarnessModelAvailable returns nothing and prints nothing when the model is installed (case-insensitive)" {
        $run = Invoke-Case -Name "w-available" -ConfigText (New-V2Config) -Script "wrapper-driver.ps1" -Arguments @{ Case = "available" } `
            -TagsSteps @((New-Step "ok" @{ models = @("TEST-MODEL-ALPHA") }))
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-ExactLine $run "PROBLEM[]"
        Assert-ExactLine $run "PROBLEM-COUNT[0]"
        Assert-NoLine $run "Model not found"
        Assert-Equal "generate calls" 0 (@(Get-Route $run "generate").Count)
        Assert-Equal "health timeout" 7 (@(Get-Route $run "tags")[0].timeoutSec)
    }

    Test-Case "AC-216 Test-HarnessModelAvailable prints the legacy lines and returns the legacy problem string when the model is missing" {
        $run = Invoke-Case -Name "w-missing" -ConfigText (New-V2Config) -Script "wrapper-driver.ps1" -Arguments @{ Case = "available" } `
            -TagsSteps @((New-Step "ok" @{ models = @("other-model-1") }))
        Assert-Guards $run
        Assert-ExactLine $run "Model not found: test-model-alpha"
        Assert-ExactLine $run "Available models:"
        Assert-ExactLine $run "  - other-model-1"
        Assert-ExactLine $run "PROBLEM[The requested Ollama model is not installed. Try: ollama pull test-model-alpha]"
    }

    Test-Case "AC-216 Test-HarnessModelAvailable prints the legacy line and returns the legacy problem string when Ollama is unreachable" {
        $run = Invoke-Case -Name "w-unreachable" -ConfigText (New-V2Config) -Script "wrapper-driver.ps1" -Arguments @{ Case = "available" } `
            -TagsSteps @((New-Step "status" @{ webStatus = "ConnectFailure" })) -TypedExceptions
        Assert-Guards $run
        Assert-ExactLine $run "Ollama is not reachable at $fakeUrl. Make sure Ollama is running."
        Assert-ExactLine $run "PROBLEM[Ollama is not reachable at $fakeUrl. Make sure Ollama is running.]"
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
