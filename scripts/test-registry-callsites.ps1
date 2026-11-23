<#
.SYNOPSIS
    Offline suite for the registry call sites (Phase 1, WP-1B): run-agent.ps1,
    review-spec.ps1, revise-spec.ps1, benchmark-models.ps1 and test-all.ps1.

.DESCRIPTION
    Covers AC-104, AC-105 (script part), AC-106 (script part), AC-107, AC-108,
    AC-109 (request bodies), AC-110 and AC-113 of
    specs\harness-phase-1-config-registry.md.

    Scripts are never run from the repository and never against a real
    server. Each one runs from a temporary harness root under TEMP, in a child
    powershell.exe (a generated "fake host") in which a function named
    Invoke-RestMethod stands in for the cmdlet, returns the responses set by
    the case and records every call. This is the approach of
    test-agent-telemetry.ps1, with the same four guards (Phase 0 FR-018):

      1. Test-TempHarnessConfig checks the temporary config before every case
         (its Ollama URL must be the fake URL); at startup the suite proves
         that it rejects a missing file, invalid JSON, http://localhost:11434
         and any other URL, in the v1 and in the v2 form.
      2. The fake host confirms Invoke-RestMethod resolves to the fake
         function before it runs the script; otherwise it exits 97.
      3. The fake accepts only URIs starting with http://127.0.0.1:9/; any
         other URI is recorded as a violation and refused.
      4. A static check refuses to start if the copied scripts contain another
         HTTP route.

    Assertions use exit codes, call records, telemetry files and the harness's
    own wording (registry_invalid:, invalid_arguments:, the fixed messages),
    never text produced by PowerShell or .NET. benchmark-models.ps1 is only
    inspected, never run.

    AC-113 checks the migrated .ai\config.json. While that file is still v1
    the check is reported as SKIPPED_TESTS (NOT verified); its checker is
    tested here on a configuration generated from the frozen v1 fixture.
#>
param()

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$scriptsDirectory = $PSScriptRoot
$fixtures = Join-Path $root "tests\fixtures"
$powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$fakeUrl = "http://127.0.0.1:9"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

foreach ($path in @(
        (Join-Path $scriptsDirectory "run-agent.ps1"),
        (Join-Path $scriptsDirectory "review-spec.ps1"),
        (Join-Path $scriptsDirectory "revise-spec.ps1"),
        (Join-Path $scriptsDirectory "benchmark-models.ps1"),
        (Join-Path $scriptsDirectory "test-all.ps1"),
        (Join-Path $scriptsDirectory "lib\config.ps1"),
        (Join-Path $scriptsDirectory "lib\telemetry.ps1"),
        (Join-Path $fixtures "config-v1-current.json"),
        (Join-Path $fixtures "config-v2-current.json"),
        (Join-Path $fixtures "historical-model-names.txt"),
        $powerShellExe)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file not found: $path" }
}

. (Join-Path $scriptsDirectory "lib\config.ps1")

$script:passed = 0
$script:failed = 0
$script:skipped = @()

$originalModelVariable = $env:AI_HARNESS_MODEL
$env:AI_HARNESS_MODEL = $null

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-harness-registry-callsites-" + [guid]::NewGuid().ToString())
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

# "key=value" pairs of an options object, sorted.
function Get-Pairs {
    param($Options)
    if ($null -eq $Options) { return "" }
    return (@($Options.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ";")
}

function Get-RawJson {
    param([string]$Path)
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
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
# Temporary harness root and fake host
# ---------------------------------------------------------------------------

function New-TempHarness {
    foreach ($directory in @("scripts\lib", ".ai\agents", ".ai\rules")) {
        [void][System.IO.Directory]::CreateDirectory((Join-Path $harnessRoot $directory))
    }
    [void][System.IO.Directory]::CreateDirectory($casesDirectory)

    foreach ($name in @("run-agent.ps1", "review-spec.ps1", "revise-spec.ps1")) {
        Copy-Item -LiteralPath (Join-Path $scriptsDirectory $name) -Destination (Join-Path $harnessRoot "scripts\$name")
    }
    Get-ChildItem -LiteralPath (Join-Path $scriptsDirectory "lib") -Filter "*.ps1" -File |
        Where-Object { $_.Extension -eq ".ps1" } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $harnessRoot "scripts\lib\$($_.Name)") }

    $stubs = @{
        "AGENTS.md"                     = "# Stub project instructions for the call-site suite."
        ".ai\rules\agent-contract.md"   = "# Stub agent contract for the call-site suite."
        ".ai\agents\spec.md"            = "# Stub specification agent for the call-site suite."
        ".ai\agents\spec-reviewer.md"   = "# Stub specification reviewer for the call-site suite."
        ".ai\agents\spec-reviser.md"    = "# Stub specification reviser for the call-site suite."
    }
    foreach ($relative in $stubs.Keys) {
        [System.IO.File]::WriteAllText((Join-Path $harnessRoot $relative), $stubs[$relative], $utf8NoBom)
    }

    [System.IO.File]::WriteAllText((Join-Path $casesDirectory "input-spec.md"),
        "# Specification`r`n`r`n## Goal`r`n`r`nStub specification for the call-site suite.", $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $casesDirectory "input-review.md"),
        "# Specification Review`r`n`r`n## Status`r`n`r`nFAIL`r`n`r`n## Summary`r`n`r`nStub review.", $utf8NoBom)

    $fakeHostSource = @'
param([Parameter(Mandatory = $true)][string]$ScenarioFile)

$ErrorActionPreference = "Stop"
$global:FakeScenario = [System.IO.File]::ReadAllText($ScenarioFile) | ConvertFrom-Json

function global:Write-FakeCall {
    param([hashtable]$Entry)
    $line = ([pscustomobject]$Entry | ConvertTo-Json -Compress) + "`r`n"
    [System.IO.File]::AppendAllText($global:FakeScenario.callLog, $line, (New-Object System.Text.UTF8Encoding($false)))
}

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

    $entry = @{ uri = $Uri; method = $Method; violation = $false; timeoutSec = $TimeoutSec }
    if ($Body -is [byte[]]) {
        $request = [System.Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        $entry.model = [string]$request.model
        $entry.hasOptions = ($null -ne $request.PSObject.Properties["options"])
        $entry.hasThink = ($null -ne $request.PSObject.Properties["think"])
        $entry.thinkValue = $null
        if ($entry.hasThink) { $entry.thinkValue = $request.think }
        $pairs = ""
        if ($entry.hasOptions) {
            $pairs = (@($request.options.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ";")
        }
        $entry.optionsPairs = $pairs
    }
    Write-FakeCall $entry

    $scenario = $global:FakeScenario
    if ($Uri -ceq "http://127.0.0.1:9/api/tags") {
        if ($scenario.tags.fail) { throw "Fake Invoke-RestMethod: /api/tags is unreachable" }
        return [pscustomobject]@{ models = @($scenario.tags.models | ForEach-Object { [pscustomobject]@{ name = [string]$_ } }) }
    }
    if ($Uri -ceq "http://127.0.0.1:9/api/generate") {
        return [pscustomobject]@{
            response             = [string]$scenario.generate.response
            total_duration       = 1000
            load_duration        = 100
            prompt_eval_count    = 5
            prompt_eval_duration = 200
            eval_count           = 10
            eval_duration        = 300
        }
    }
    throw "Fake Invoke-RestMethod: unknown route: $Uri"
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

$exitCode = 0
try {
    & $global:FakeScenario.script @arguments
    $exitCode = $LASTEXITCODE
}
catch {
    Write-Host "FAKE-HOST: unhandled error: $($_.Exception.Message)"
    $exitCode = 1
}
exit $exitCode
'@
    [System.IO.File]::WriteAllText($fakeHost, $fakeHostSource, $utf8NoBom)
}

# Guard 4: no other HTTP route in the copied scripts.
function Get-ForbiddenRoutes {
    $copied = @(Get-ChildItem -LiteralPath (Join-Path $harnessRoot "scripts") -Filter "*.ps1" -File -Recurse)
    $found = @()
    foreach ($file in $copied) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        foreach ($literal in @("Microsoft.PowerShell.Utility\Invoke-RestMethod", "Invoke-WebRequest",
                "System.Net.WebClient", "HttpWebRequest", "HttpClient")) {
            if ($text.IndexOf($literal, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $found += "$($file.Name): $literal"
            }
        }
        foreach ($match in [regex]::Matches($text, '(?im)(?<![\w-])(irm|iwr|curl|wget)(?![\w-])')) {
            $found += "$($file.Name): alias $($match.Value)"
        }
    }
    return @{ Files = $copied.Count; Found = $found }
}

# ---------------------------------------------------------------------------
# One case: one script in one fake host
# ---------------------------------------------------------------------------

$defaultResponses = @{
    "run-agent"   = "Fake agent response for the call-site suite."
    "review-spec" = "# Specification Review`r`n`r`n## Status`r`n`r`nPASS`r`n`r`n## Summary`r`n`r`nFake reviewer response."
    "revise-spec" = "# Specification`r`n`r`n## Goal`r`n`r`nFake revised specification."
}

function Invoke-Script {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("run-agent", "review-spec", "revise-spec")][string]$Script,
        [Parameter(Mandatory = $true)][string]$ConfigText,
        [hashtable]$Extra = @{},
        [string[]]$TagModels = @()
    )

    [System.IO.File]::WriteAllText($harnessConfig, $ConfigText, $utf8NoBom)

    # Guard 1 before every case.
    if (-not (Test-TempHarnessConfig -Path $harnessConfig)) {
        Stop-Suite "the temporary .ai\config.json is missing, invalid or not $fakeUrl"
    }

    if (Test-Path -LiteralPath $harnessLogs) { Remove-Item -LiteralPath $harnessLogs -Recurse -Force }
    $callLog = Join-Path $casesDirectory "$Script.calls.jsonl"
    $scenarioFile = Join-Path $casesDirectory "$Script.scenario.json"
    if (Test-Path -LiteralPath $callLog) { Remove-Item -LiteralPath $callLog -Force }

    $arguments = [ordered]@{ Task = "Stub task for the call-site suite." }
    if ($Script -eq "run-agent") { $arguments.Agent = "spec" }
    else { $arguments.SpecFile = (Join-Path $casesDirectory "input-spec.md") }
    if ($Script -eq "revise-spec") { $arguments.ReviewFile = (Join-Path $casesDirectory "input-review.md") }
    foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }

    $scenario = [ordered]@{
        script    = (Join-Path $harnessRoot "scripts\$Script.ps1")
        arguments = $arguments
        callLog   = $callLog
        tags      = [ordered]@{ fail = $false; models = @($TagModels) }
        generate  = [ordered]@{ response = $defaultResponses[$Script] }
    }
    [System.IO.File]::WriteAllText($scenarioFile, ($scenario | ConvertTo-Json -Depth 5), $utf8NoBom)

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

    $telemetryLines = 0
    $jsonl = Join-Path $harnessLogs "model-calls.jsonl"
    if (Test-Path -LiteralPath $jsonl -PathType Leaf) {
        $telemetryLines = @([System.IO.File]::ReadAllLines($jsonl) | Where-Object { $_.Trim() -ne "" }).Count
    }

    return [pscustomobject]@{
        ExitCode       = $exitCode
        Lines          = $lines
        Calls          = $calls
        TelemetryLines = $telemetryLines
        FakeActive     = ($lines -ccontains "FAKE-HOST: fake Invoke-RestMethod active")
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

function Assert-Line {
    param($Run, [string]$Text)
    if (@($Run.Lines | Where-Object { $_.Contains($Text) }).Count -eq 0) { throw "missing a line containing: $Text" }
}

function Assert-NoRequest {
    param($Run)
    if ($Run.Calls.Count -ne 0) { throw "expected no request, got $($Run.Calls.Count)" }
    if ($Run.TelemetryLines -ne 0) { throw "expected no telemetry line, got $($Run.TelemetryLines)" }
}

# ---------------------------------------------------------------------------
# Configurations used by the child-process cases (synthetic model names)
# ---------------------------------------------------------------------------

$v2Valid = @"
{
  "schemaVersion": 2,
  "ollama": { "url": "$fakeUrl", "healthTimeoutSec": 7 },
  "defaults": { "profile": "alpha", "options": { "temperature": 0.2 }, "timeoutSec": 111, "stripThinking": true },
  "profiles": {
    "alpha": { "model": "test-model-alpha", "contextWindow": 8192, "timeoutSec": 222, "reservedOutputTokens": 1024, "think": true },
    "beta":  { "model": "test-model-beta", "timeoutSec": 333, "options": { "seed": 5 } }
  },
  "agents": {
    "spec": { "profile": "alpha" },
    "spec-reviewer": { "profile": "beta" },
    "spec-reviser": { "profile": "beta" }
  }
}
"@
$v2Invalid = "{ ""schemaVersion"": 3, ""ollama"": { ""url"": ""$fakeUrl"" } }"
$v1Valid = "{ ""ollamaUrl"": ""$fakeUrl"", ""defaultModel"": ""test-model-a"", ""agentModels"": { ""spec-reviewer"": ""test-model-b"" }, ""options"": { ""temperature"": 0.3, ""num_ctx"": 4096 }, ""timeoutSec"": 444 }"
$v1NoOptions = "{ ""ollamaUrl"": ""$fakeUrl"", ""defaultModel"": ""test-model-a"" }"

$scriptsUnderTest = @(
    @{ Script = "run-agent";   Agent = "spec";          Exit = "1";  Label = "run-agent" },
    @{ Script = "review-spec"; Agent = "spec-reviewer"; Exit = "2";  Label = "review-spec" },
    @{ Script = "revise-spec"; Agent = "spec-reviser";  Exit = "nz"; Label = "revise-spec" }
)

function Assert-ExitCode {
    param($Entry, $Run)

    if ($Entry.Exit -eq "nz") {
        if ($Run.ExitCode -eq 0) { throw "expected a non-zero exit code" }
    }
    elseif ($Run.ExitCode -ne [int]$Entry.Exit) {
        throw "expected exit code $($Entry.Exit), got $($Run.ExitCode)"
    }
}

# ---------------------------------------------------------------------------
# AC-107 helper: model names found in the files of a directory
# ---------------------------------------------------------------------------

function Find-ModelNames {
    param([string]$Directory, [string[]]$Names)

    $files = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force)
    $found = @()
    foreach ($name in $Names) {
        foreach ($hit in @(Select-String -LiteralPath $files.FullName -Pattern $name -SimpleMatch)) {
            $found += "$($hit.Path.Substring($Directory.Length).TrimStart('\')):$($hit.LineNumber)"
        }
    }
    return @{ Files = $files.Count; Found = $found }
}

# ---------------------------------------------------------------------------
# AC-113 helper: the migrated configuration, checked against the v1 file
# ---------------------------------------------------------------------------

function Get-MigrationProblems {
    param([string]$Path, $V1Raw)

    $problems = @()
    try { $registry = Get-HarnessRegistry -ConfigPath $Path }
    catch { return @("the file does not load: $($_.Exception.Message)") }

    $names = @($registry.profiles.PSObject.Properties.Name | Sort-Object)
    if (($names -join ",") -cne "deep,fast,review") { $problems += "profiles are '$($names -join ',')', expected deep,fast,review" }

    $expectedAgents = [ordered]@{ "spec" = "fast"; "spec-reviewer" = "review"; "spec-reviser" = "deep"; "developer" = "deep" }
    foreach ($agent in $expectedAgents.Keys) {
        $entry = $registry.agents.PSObject.Properties[$agent]
        if ($null -eq $entry -or [string]$entry.Value.profile -cne $expectedAgents[$agent]) { $problems += "agent $agent is not assigned to $($expectedAgents[$agent])" }
    }
    if ([string]$registry.defaults.profile -cne "fast") { $problems += "defaults.profile is not fast" }

    $reserved = [ordered]@{ "fast" = 4096; "deep" = 8192; "review" = 8192 }
    foreach ($name in $reserved.Keys) {
        $profile = $registry.profiles.PSObject.Properties[$name]
        if ($null -eq $profile) { continue }
        if ("$($profile.Value.reservedOutputTokens)" -cne "$($reserved[$name])") { $problems += "profile $name reservedOutputTokens is not $($reserved[$name])" }
        if ("$($profile.Value.think)" -cne "default") { $problems += "profile $name think is not default" }
    }

    $v1Agents = @("spec", "spec-reviewer", "spec-reviser", "developer", "agent-without-entry")
    foreach ($agent in $v1Agents) {
        $expectedModel = $V1Raw.defaultModel
        if ($V1Raw.agentModels.PSObject.Properties[$agent]) { $expectedModel = $V1Raw.agentModels.$agent }

        $expectedOptions = [ordered]@{}
        foreach ($option in $V1Raw.options.PSObject.Properties) { $expectedOptions[$option.Name] = $option.Value }
        if ($agent -eq "spec-reviewer") { $expectedOptions["temperature"] = 0.1; $expectedOptions["seed"] = 42 }

        try { $record = Resolve-HarnessExecution -Agent $agent -Registry $registry }
        catch { $problems += "$agent does not resolve: $($_.Exception.Message)"; continue }

        if ($record.model -cne $expectedModel) { $problems += "$agent model differs from v1" }
        if ("$($record.timeoutSec)" -cne "$($V1Raw.timeoutSec)") { $problems += "$agent timeoutSec differs from v1" }
        if ((Get-Pairs $record.options) -cne (Get-Pairs ([pscustomobject]$expectedOptions))) { $problems += "$agent options differ from the expected ones" }
    }
    if ("$($registry.defaults.stripThinking)" -cne "$($V1Raw.stripThinking)") { $problems += "stripThinking differs from v1" }
    if ([string]$registry.ollama.url -cne [string]$V1Raw.ollamaUrl) { $problems += "the Ollama URL differs from v1" }
    return $problems
}

# The migrated file, generated from the frozen v1 file (no model name in this script).
function New-ExpectedMigration {
    param($V1Raw, [string]$Path, [scriptblock]$Mutate = $null)

    $fast = $V1Raw.defaultModel
    $deep = $V1Raw.agentModels."spec-reviewer"
    $window = $V1Raw.options.num_ctx
    $profileCommon = { param($Model, $Reserved) [ordered]@{ model = $Model; contextWindow = $window; timeoutSec = $V1Raw.timeoutSec; reservedOutputTokens = $Reserved; think = "default" } }

    $review = & $profileCommon $deep 8192
    $review.options = [ordered]@{ temperature = 0.1; seed = 42 }

    $config = [ordered]@{
        schemaVersion = 2
        ollama        = [ordered]@{ url = $V1Raw.ollamaUrl; healthTimeoutSec = 15 }
        defaults      = [ordered]@{ profile = "fast"; options = [ordered]@{ temperature = $V1Raw.options.temperature }; safetyMarginRatio = 0.10; stripThinking = $V1Raw.stripThinking }
        profiles      = [ordered]@{ fast = (& $profileCommon $fast 4096); deep = (& $profileCommon $deep 8192); review = $review }
        agents        = [ordered]@{
            "spec"          = [ordered]@{ profile = "fast" }
            "spec-reviser"  = [ordered]@{ profile = "deep" }
            "spec-reviewer" = [ordered]@{ profile = "review" }
            "developer"     = [ordered]@{ profile = "deep" }
        }
    }
    if ($null -ne $Mutate) { & $Mutate $config }
    [System.IO.File]::WriteAllText($Path, ($config | ConvertTo-Json -Depth 10), $utf8NoBom)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$v1Raw = Get-RawJson (Join-Path $fixtures "config-v1-current.json")
$v2Raw = Get-RawJson (Join-Path $fixtures "config-v2-current.json")

try {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "   REGISTRY CALL-SITE SUITE (OFFLINE)" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan

    New-TempHarness

    # Guard 1 startup proof: it rejects every unsafe configuration and accepts the good ones.
    $guardDirectory = Join-Path $tempRoot "guard1"
    [void][System.IO.Directory]::CreateDirectory($guardDirectory)
    $probes = [ordered]@{
        "a missing file"                  = $null
        "invalid JSON"                    = "{ ""ollamaUrl"": "
        "v1 localhost URL"                = "{ ""ollamaUrl"": ""http://localhost:11434"" }"
        "v1 other URL"                    = "{ ""ollamaUrl"": ""http://127.0.0.1:10"" }"
        "v2 localhost URL"                = "{ ""schemaVersion"": 2, ""ollama"": { ""url"": ""http://localhost:11434"" } }"
        "v2 without URL"                  = "{ ""schemaVersion"": 2 }"
        "v2 with only the v1 key"         = "{ ""schemaVersion"": 2, ""ollamaUrl"": ""$fakeUrl"" }"
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
    foreach ($good in @($v1Valid, $v2Valid, $v2Invalid)) {
        $goodPath = Join-Path $guardDirectory "good.json"
        [System.IO.File]::WriteAllText($goodPath, $good, $utf8NoBom)
        if (-not (Test-TempHarnessConfig -Path $goodPath)) { Stop-Suite "guard 1 rejected a configuration with the fake URL" }
    }
    Write-Host "[PASS] guard 1 accepts configurations whose URL is the fake URL" -ForegroundColor Green
    $script:passed++

    # Guard 4 startup proof.
    $routes = Get-ForbiddenRoutes
    if ($routes.Files -lt 4 -or $routes.Found.Count -gt 0) {
        Stop-Suite "guard 4: files checked $($routes.Files); found: $($routes.Found -join ', ')"
    }
    Write-Host "[PASS] guard 4: no other HTTP route in the $($routes.Files) copied scripts" -ForegroundColor Green
    $script:passed++

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-104 invalid configuration stops the scripts before any request ===" -ForegroundColor Cyan
    foreach ($entry in $scriptsUnderTest) {
        Test-Case "AC-104 $($entry.Label) with an invalid v2 config" {
            $run = Invoke-Script -Script $entry.Script -ConfigText $v2Invalid -Extra @{ Model = "test-model-alpha" }
            Assert-Guards $run
            Assert-ExitCode $entry $run
            Assert-Line $run "registry_invalid:"
            Assert-NoRequest $run
        }
    }

    # AC-114: an invalid ollama.healthTimeoutSec is a configuration error (exit 2 for review-spec).
    foreach ($badHealth in @('"abc"', '0', '601')) {
        Test-Case "AC-114 review-spec with ollama.healthTimeoutSec $badHealth exits 2 with registry_invalid:" {
            $badConfig = "{ ""schemaVersion"": 2, ""ollama"": { ""url"": ""$fakeUrl"", ""healthTimeoutSec"": $badHealth }, ""defaults"": { ""profile"": ""alpha"" }, ""profiles"": { ""alpha"": { ""model"": ""test-model-alpha"" } } }"
            $run = Invoke-Script -Script "review-spec" -ConfigText $badConfig
            Assert-Guards $run
            Assert-Equal "exit code" 2 $run.ExitCode
            Assert-Line $run "registry_invalid: ollama.healthTimeoutSec"
            Assert-NoRequest $run
        }
    }

    Write-Host ""
    Write-Host "=== AC-105 -Model with -Profile ===" -ForegroundColor Cyan
    foreach ($entry in $scriptsUnderTest) {
        Test-Case "AC-105 $($entry.Label) rejects -Model with -Profile (v2 config)" {
            $run = Invoke-Script -Script $entry.Script -ConfigText $v2Valid -Extra @{ Model = "test-model-alpha"; Profile = "beta" }
            Assert-Guards $run
            Assert-ExitCode $entry $run
            Assert-Line $run "invalid_arguments:"
            Assert-NoRequest $run
        }
        Test-Case "AC-105 $($entry.Label) rejects -Model with -Profile (v1 config)" {
            $run = Invoke-Script -Script $entry.Script -ConfigText $v1Valid -Extra @{ Model = "test-model-a"; Profile = "alpha" }
            Assert-Guards $run
            Assert-ExitCode $entry $run
            Assert-Line $run "invalid_arguments:"
            Assert-NoRequest $run
        }
    }

    Write-Host ""
    Write-Host "=== AC-106 a blank -Model is still rejected ===" -ForegroundColor Cyan
    foreach ($entry in $scriptsUnderTest) {
        foreach ($config in @(@{ Label = "v1"; Text = $v1Valid }, @{ Label = "v2"; Text = $v2Valid })) {
            Test-Case "AC-106 $($entry.Label) rejects a blank -Model ($($config.Label) config)" {
                $run = Invoke-Script -Script $entry.Script -ConfigText $config.Text -Extra @{ Model = "" }
                Assert-Guards $run
                Assert-ExitCode $entry $run
                Assert-Line $run "Model name cannot be empty."
                Assert-NoRequest $run
            }
        }
    }

    Write-Host ""
    Write-Host "=== Requests built from the registry (AC-109 request bodies, NFR-103) ===" -ForegroundColor Cyan

    Test-Case "review-spec with a v2 config: agent profile, health timeout and request body" {
        $run = Invoke-Script -Script "review-spec" -ConfigText $v2Valid -TagModels @("test-model-beta")
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-Line $run "Model : test-model-beta"
        $tags = @(Get-Route $run "tags"); $generate = @(Get-Route $run "generate")
        Assert-Equal "tags calls" 1 $tags.Count
        Assert-Equal "health timeout" 7 $tags[0].timeoutSec
        Assert-Equal "generate calls" 1 $generate.Count
        Assert-Equal "model" "test-model-beta" $generate[0].model
        Assert-Equal "timeout" 333 $generate[0].timeoutSec
        Assert-Equal "options" "seed=5;temperature=0.2" $generate[0].optionsPairs
        Assert-Equal "think member" "False" $generate[0].hasThink
        Assert-Equal "telemetry lines" 1 $run.TelemetryLines
    }

    Test-Case "review-spec -Profile alpha: profile parameters, num_ctx from contextWindow, think never sent" {
        $run = Invoke-Script -Script "review-spec" -ConfigText $v2Valid -Extra @{ Profile = "alpha" } -TagModels @("test-model-alpha")
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        $generate = @(Get-Route $run "generate")
        Assert-Equal "model" "test-model-alpha" $generate[0].model
        Assert-Equal "timeout" 222 $generate[0].timeoutSec
        Assert-Equal "options" "num_ctx=8192;temperature=0.2" $generate[0].optionsPairs
        Assert-Equal "think member (the profile has think true)" "False" $generate[0].hasThink
    }

    Test-Case "review-spec -Model of a registered profile takes that profile's parameters" {
        $run = Invoke-Script -Script "review-spec" -ConfigText $v2Valid -Extra @{ Model = "test-model-alpha" } -TagModels @("test-model-alpha")
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        $generate = @(Get-Route $run "generate")
        Assert-Equal "timeout" 222 $generate[0].timeoutSec
        Assert-Equal "options" "num_ctx=8192;temperature=0.2" $generate[0].optionsPairs
    }

    Test-Case "review-spec -Model with an unregistered name: agent profile parameters, nothing new printed" {
        $run = Invoke-Script -Script "review-spec" -ConfigText $v2Valid -Extra @{ Model = "test-model-unregistered" } -TagModels @("test-model-unregistered")
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        $generate = @(Get-Route $run "generate")
        Assert-Equal "model" "test-model-unregistered" $generate[0].model
        Assert-Equal "timeout" 333 $generate[0].timeoutSec
        Assert-Equal "options" "seed=5;temperature=0.2" $generate[0].optionsPairs
        if (@($run.Lines | Where-Object { $_.Contains("unregistered_model_override") }).Count -ne 0) { throw "the warning code was printed" }
    }

    Test-Case "revise-spec with a v2 config: agent profile, and -Profile alpha" {
        $run = Invoke-Script -Script "revise-spec" -ConfigText $v2Valid -TagModels @("test-model-beta")
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-Line $run "Model : test-model-beta"
        $generate = @(Get-Route $run "generate")
        Assert-Equal "timeout" 333 $generate[0].timeoutSec
        Assert-Equal "think member" "False" $generate[0].hasThink
        $run = Invoke-Script -Script "revise-spec" -ConfigText $v2Valid -Extra @{ Profile = "alpha" } -TagModels @("test-model-alpha")
        Assert-Guards $run
        Assert-Equal "exit code with -Profile" 0 $run.ExitCode
        Assert-Equal "model with -Profile" "test-model-alpha" @(Get-Route $run "generate")[0].model
    }

    Test-Case "run-agent with a v2 config: agent profile, server line, health timeout and body" {
        $run = Invoke-Script -Script "run-agent" -ConfigText $v2Valid -TagModels @("test-model-alpha")
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        Assert-Line $run "Model : test-model-alpha"
        Assert-Line $run "Server: $fakeUrl"
        $tags = @(Get-Route $run "tags"); $generate = @(Get-Route $run "generate")
        Assert-Equal "health timeout" 7 $tags[0].timeoutSec
        Assert-Equal "model" "test-model-alpha" $generate[0].model
        Assert-Equal "timeout" 222 $generate[0].timeoutSec
        Assert-Equal "options" "num_ctx=8192;temperature=0.2" $generate[0].optionsPairs
        Assert-Equal "think member" "True" $generate[0].hasThink
        Assert-Equal "think value" "True" $generate[0].thinkValue
        Assert-True "think value is a JSON boolean" ($generate[0].thinkValue -is [bool])
        $run = Invoke-Script -Script "run-agent" -ConfigText $v2Valid -Extra @{ Profile = "beta" } -TagModels @("test-model-beta")
        Assert-Guards $run
        Assert-Equal "exit code with -Profile" 0 $run.ExitCode
        Assert-Equal "model with -Profile" "test-model-beta" @(Get-Route $run "generate")[0].model
    }

    foreach ($entry in $scriptsUnderTest) {
        Test-Case "NFR-103 $($entry.Label) with a v1 config keeps the v1 model, timeout and options" {
            $model = if ($entry.Agent -eq "spec-reviewer") { "test-model-b" } else { "test-model-a" }
            $run = Invoke-Script -Script $entry.Script -ConfigText $v1Valid -TagModels @($model)
            Assert-Guards $run
            Assert-Equal "exit code" 0 $run.ExitCode
            Assert-Line $run "Model : $model"
            $tags = @(Get-Route $run "tags"); $generate = @(Get-Route $run "generate")
            Assert-Equal "health timeout (default)" 15 $tags[0].timeoutSec
            Assert-Equal "model" $model $generate[0].model
            Assert-Equal "timeout" 444 $generate[0].timeoutSec
            Assert-Equal "options" "num_ctx=4096;temperature=0.3" $generate[0].optionsPairs
            Assert-Equal "think member" "False" $generate[0].hasThink
        }
    }

    Test-Case "NFR-103 a v1 config without options sends no options member" {
        $run = Invoke-Script -Script "review-spec" -ConfigText $v1NoOptions -TagModels @("test-model-a")
        Assert-Guards $run
        Assert-Equal "exit code" 0 $run.ExitCode
        $generate = @(Get-Route $run "generate")
        Assert-Equal "hasOptions" "False" $generate[0].hasOptions
        Assert-Equal "timeout (default)" 600 $generate[0].timeoutSec
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-107 no model-name literals in scripts\ ===" -ForegroundColor Cyan

    $configuredNames = @(Get-HarnessRegistryModels -Registry (Get-HarnessRegistry -ConfigPath (Join-Path $root ".ai\config.json")))
    $historicalNames = @([System.IO.File]::ReadAllLines((Join-Path $fixtures "historical-model-names.txt")) |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    $allNames = @($configuredNames + $historicalNames | Select-Object -Unique)

    Test-Case "AC-107 the name lists are not empty (the scan cannot pass vacuously)" {
        Assert-True "configured names" ($configuredNames.Count -ge 1)
        Assert-Equal "historical names" 3 $historicalNames.Count
    }

    Test-Case "AC-107 the scanner finds a planted name" {
        $planted = Join-Path $tempRoot "planted"
        [void][System.IO.Directory]::CreateDirectory((Join-Path $planted "lib"))
        [System.IO.File]::WriteAllText((Join-Path $planted "lib\sample.ps1"), "# comment with test-planted-model:1b inside`r`n", $utf8NoBom)
        $result = Find-ModelNames -Directory $planted -Names @("test-planted-model:1b", "test-absent-model:1b")
        Assert-Equal "files scanned" 1 $result.Files
        Assert-Equal "hits" 1 @($result.Found).Count
    }

    Test-Case "AC-107 none of the configured or historical names appears in any file under scripts\" {
        $result = Find-ModelNames -Directory $scriptsDirectory -Names $allNames
        Assert-True "files scanned" ($result.Files -ge 10)
        if (@($result.Found).Count -gt 0) { throw "model names found: $(@($result.Found) -join ', ')" }
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-108 the benchmark default comes from the registry ===" -ForegroundColor Cyan

    Test-Case "AC-108 the helper returns the distinct profile models in profile order (v2 and v1 fixtures)" {
        $v2 = @(Get-HarnessRegistryModels -Registry (Get-HarnessRegistry -ConfigPath (Join-Path $fixtures "config-v2-current.json")))
        Assert-Equal "v2 profile order" "fast,deep" (@($v2Raw.profiles.PSObject.Properties.Name) -join ",")
        Assert-Equal "v2 models" (@($v2Raw.profiles.fast.model, $v2Raw.profiles.deep.model) -join ",") ($v2 -join ",")
        $v1 = @(Get-HarnessRegistryModels -Registry (Get-HarnessRegistry -ConfigPath (Join-Path $fixtures "config-v1-current.json")))
        Assert-Equal "v1 models" (@($v1Raw.agentModels.PSObject.Properties.Value + $v1Raw.defaultModel | Select-Object -Unique) -join ",") ($v1 -join ",")
    }

    Test-Case "AC-108 benchmark-models.ps1 has no default -Models and builds it from the registry (inspection, not run)" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsDirectory "benchmark-models.ps1"), [ref]$tokens, [ref]$errors)
        Assert-Equal "parse errors" 0 @($errors).Count
        $parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "Models" })
        Assert-Equal "Models parameter" 1 $parameter.Count
        Assert-True "no default value" ($null -eq $parameter[0].DefaultValue)
        $text = $ast.Extent.Text
        Assert-True "uses the registry helper" ($text.Contains("Get-HarnessRegistryModels"))
        Assert-True "only when -Models is not bound" ($text.Contains("-not `$PSBoundParameters.ContainsKey('Models')"))
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-110 the live-suite model resolves like production ===" -ForegroundColor Cyan

    $testAllTokens = $null; $testAllErrors = $null
    $testAllAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsDirectory "test-all.ps1"), [ref]$testAllTokens, [ref]$testAllErrors)
    $liveFunction = @($testAllAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Resolve-LiveSuiteModel" }, $true))
    . ([scriptblock]::Create($liveFunction[0].Extent.Text))

    foreach ($case in @(@{ Label = "v1"; Fixture = "config-v1-current.json" }, @{ Label = "v2"; Fixture = "config-v2-current.json" })) {
        Test-Case "AC-110 Resolve-LiveSuiteModel (test-all) and review-spec agree under the $($case.Label) fixture" {
            $liveRoot = Join-Path $tempRoot "live-$($case.Label)"
            [void][System.IO.Directory]::CreateDirectory((Join-Path $liveRoot ".ai"))
            Copy-Item -LiteralPath (Join-Path $fixtures $case.Fixture) -Destination (Join-Path $liveRoot ".ai\config.json")

            $repoRoot = $liveRoot
            $live = Resolve-LiveSuiteModel -Agent "spec-reviewer"
            Assert-Equal "no problem" "" $live.Problem
            Assert-True "a model" (-not [string]::IsNullOrWhiteSpace($live.Model))

            # The same configuration, with the Ollama URL replaced by the fake URL.
            $config = Get-RawJson (Join-Path $fixtures $case.Fixture)
            if ($null -ne $config.PSObject.Properties["ollama"]) { $config.ollama.url = $fakeUrl } else { $config.ollamaUrl = $fakeUrl }
            $run = Invoke-Script -Script "review-spec" -ConfigText ($config | ConvertTo-Json -Depth 10) -TagModels @($live.Model)
            Assert-Guards $run
            Assert-Line $run "Model : $($live.Model)"
            Assert-Equal "same model as the v1 raw file" $(if ($v1Raw.agentModels.PSObject.Properties["spec-reviewer"]) { $v1Raw.agentModels."spec-reviewer" } else { $v1Raw.defaultModel }) $live.Model
        }
    }

    Test-Case "AC-110 Resolve-LiveSuiteModel reports a configuration error as a problem, without throwing" {
        $badRoot = Join-Path $tempRoot "live-bad"
        [void][System.IO.Directory]::CreateDirectory((Join-Path $badRoot ".ai"))
        [System.IO.File]::WriteAllText((Join-Path $badRoot ".ai\config.json"), $v2Invalid, $utf8NoBom)
        $repoRoot = $badRoot
        $live = Resolve-LiveSuiteModel -Agent "spec-reviewer"
        Assert-Equal "model" "" $live.Model
        Assert-True "problem names the rule" ($live.Problem.StartsWith("registry_invalid:", [System.StringComparison]::Ordinal))
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-113 the migrated .ai\config.json ===" -ForegroundColor Cyan

    Test-Case "AC-113 the checker accepts a configuration generated from the v1 fixture" {
        $path = Join-Path $tempRoot "migrated-ok.json"
        New-ExpectedMigration -V1Raw $v1Raw -Path $path
        $problems = @(Get-MigrationProblems -Path $path -V1Raw $v1Raw)
        if ($problems.Count -gt 0) { throw "unexpected problems: $($problems -join '; ')" }
    }

    $mutations = [ordered]@{
        "the reviewer keeps temperature 0.2"          = { param($c) $c.profiles.review.options.temperature = 0.2 }
        "the reviewer has no seed"                    = { param($c) $c.profiles.review.options.Remove("seed") }
        "the developer is assigned to fast"           = { param($c) $c.agents.developer.profile = "fast" }
        "the review profile is missing"               = { param($c) $c.profiles.Remove("review"); $c.agents."spec-reviewer".profile = "deep" }
        "deep reservedOutputTokens is 6144"           = { param($c) $c.profiles.deep.reservedOutputTokens = 6144 }
        "the timeout changed"                         = { param($c) foreach ($p in @("fast", "deep", "review")) { $c.profiles[$p].timeoutSec = 600 } }
        "the default profile is deep"                 = { param($c) $c.defaults.profile = "deep" }
        "an extra option changes the spec agent"      = { param($c) $c.profiles.fast.options = [ordered]@{ seed = 1 } }
    }
    foreach ($label in $mutations.Keys) {
        Test-Case "AC-113 the checker rejects: $label" {
            $path = Join-Path $tempRoot "migrated-bad.json"
            New-ExpectedMigration -V1Raw $v1Raw -Path $path -Mutate $mutations[$label]
            $problems = @(Get-MigrationProblems -Path $path -V1Raw $v1Raw)
            Assert-True "at least one problem" ($problems.Count -ge 1)
        }
    }

    $realConfig = Get-RawJson (Join-Path $root ".ai\config.json")
    if ($null -eq $realConfig.PSObject.Properties["schemaVersion"]) {
        $script:skipped += "AC-113"
        Write-Host "[SKIP] AC-113 the repository .ai\config.json is still v1 (migration not done): NOT VERIFIED" -ForegroundColor Yellow
    }
    else {
        Test-Case "AC-113 the repository .ai\config.json keeps every model and changes only the reviewer's options" {
            $problems = @(Get-MigrationProblems -Path (Join-Path $root ".ai\config.json") -V1Raw $v1Raw)
            if ($problems.Count -gt 0) { throw ($problems -join "; ") }
        }
    }
}
finally {
    $env:AI_HARNESS_MODEL = $originalModelVariable
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "              TEST SUMMARY" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Passed: $script:passed"
Write-Host "Failed: $script:failed"
if ($script:skipped.Count -gt 0) { Write-Host "SKIPPED_TESTS: $($script:skipped -join ', ')" }
else { Write-Host "SKIPPED_TESTS: none" }

if ($script:failed -eq 0 -and $script:passed -gt 0) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "STATUS: FAIL" -ForegroundColor Red
exit 1
