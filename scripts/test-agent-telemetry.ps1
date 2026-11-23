<#
.SYNOPSIS
    Offline regression suite: reviewer and reviser availability checks and
    telemetry (FR-018; AC-012 to AC-016, AC-027, AC-030).

.DESCRIPTION
    Runs copies of review-spec.ps1 and revise-spec.ps1 from a temporary
    harness root under TEMP, never from the repository, and never against a
    real server:

    - The temporary root holds copies of review-spec.ps1, revise-spec.ps1 and
      lib\*.ps1, stub AGENTS.md, contract and agent files, and a stub
      .ai\config.json whose ollamaUrl is http://127.0.0.1:9. Telemetry goes to
      its logs\ folder only. The root is deleted at the end.
    - Each script runs in a child powershell.exe (a generated "fake host") in
      which a function named Invoke-RestMethod stands in for the cmdlet,
      returns the responses set by the case, and records every call.

    Guards against a real request (FR-018, all mandatory):
      1. Test-TempHarnessConfig checks the temporary config before every case;
         at startup the suite proves it rejects a missing file, invalid JSON,
         http://localhost:11434 and any other URL.
      2. The fake host confirms Invoke-RestMethod resolves to the fake
         function before it runs the script; otherwise it exits 97.
      3. The fake accepts only URIs starting with http://127.0.0.1:9/; any
         other URI is recorded as a violation and refused before any request.
      4. A static check refuses to start if the copied scripts contain another
         HTTP route (module-qualified Invoke-RestMethod, Invoke-WebRequest,
         System.Net.WebClient, HttpWebRequest, HttpClient, or the aliases irm,
         iwr, curl, wget).

    Assertions use only exit codes, call records, telemetry records and the
    harness's own fixed wording, never localized PowerShell or .NET text
    (NFR-006). For the one-time AC-017 comparison, the suite also prints the
    SHA-256 of the system and prompt fields sent by the successful calls.
#>

$ErrorActionPreference = "Stop"

$scriptsDirectory = $PSScriptRoot
$powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$fakeUrl = "http://127.0.0.1:9"
$fakeModel = "phase0-fake:1b"

foreach ($path in @(
        (Join-Path $scriptsDirectory "review-spec.ps1"),
        (Join-Path $scriptsDirectory "revise-spec.ps1"),
        (Join-Path $scriptsDirectory "lib\config.ps1"),
        (Join-Path $scriptsDirectory "lib\telemetry.ps1"),
        $powerShellExe)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file not found: $path"
    }
}

$script:passed = 0
$script:failed = 0
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-harness-agent-telemetry-" + [guid]::NewGuid().ToString())
$harnessRoot = Join-Path $tempRoot "harness"
$harnessConfig = Join-Path $harnessRoot ".ai\config.json"
$harnessLogs = Join-Path $harnessRoot "logs"
$casesDirectory = Join-Path $tempRoot "cases"
$fakeHost = Join-Path $tempRoot "fake-host.ps1"

$reviewPass = @"
# Specification Review

## Status

PASS

## Summary

Fake reviewer response for the offline telemetry suite.
"@

$revisedSpec = @"
# Specification

## Goal

Fake revised specification for the offline telemetry suite.
"@

# ---------------------------------------------------------------------------
# Result bookkeeping
# ---------------------------------------------------------------------------

function Write-Result {
    param(
        [string]$Name,
        [string[]]$Problems,
        $Run
    )

    if ($Problems.Count -eq 0) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
        $script:passed++
        return
    }

    Write-Host "[FAIL] $Name" -ForegroundColor Red
    foreach ($problem in $Problems) { Write-Host "       $problem" -ForegroundColor Red }
    if ($null -ne $Run) {
        Write-Host "       actual exit code: $($Run.ExitCode)"
        foreach ($call in $Run.Calls) { Write-Host "       call: $($call.method) $($call.uri) violation=$($call.violation)" }
        foreach ($line in $Run.Lines) { Write-Host "       | $line" }
    }
    $script:failed++
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

# ---------------------------------------------------------------------------
# Guard 1: the temporary configuration must point at the fake URL
# ---------------------------------------------------------------------------

function Test-TempHarnessConfig {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { $config = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json }
    catch { return $false }
    if ($null -eq $config -or $null -eq $config.PSObject.Properties["ollamaUrl"]) { return $false }
    return ([string]$config.ollamaUrl -ceq $fakeUrl)
}

# ---------------------------------------------------------------------------
# Temporary harness root
# ---------------------------------------------------------------------------

function New-TempHarness {
    foreach ($directory in @("scripts\lib", ".ai\agents", ".ai\rules")) {
        [void][System.IO.Directory]::CreateDirectory((Join-Path $harnessRoot $directory))
    }
    [void][System.IO.Directory]::CreateDirectory($casesDirectory)

    foreach ($name in @("review-spec.ps1", "revise-spec.ps1")) {
        Copy-Item -LiteralPath (Join-Path $scriptsDirectory $name) -Destination (Join-Path $harnessRoot "scripts\$name")
    }
    Get-ChildItem -LiteralPath (Join-Path $scriptsDirectory "lib") -Filter "*.ps1" -File |
        Where-Object { $_.Extension -eq ".ps1" } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $harnessRoot "scripts\lib\$($_.Name)") }

    $stubs = @{
        "AGENTS.md"                     = "# Stub project instructions for the offline telemetry suite."
        ".ai\rules\agent-contract.md"   = "# Stub agent contract for the offline telemetry suite."
        ".ai\agents\spec-reviewer.md"   = "# Stub specification reviewer for the offline telemetry suite."
        ".ai\agents\spec-reviser.md"    = "# Stub specification reviser for the offline telemetry suite."
        ".ai\config.json"               = "{ ""ollamaUrl"": ""$fakeUrl"" }"
    }
    foreach ($relative in $stubs.Keys) {
        [System.IO.File]::WriteAllText((Join-Path $harnessRoot $relative), $stubs[$relative], $utf8NoBom)
    }

    [System.IO.File]::WriteAllText((Join-Path $casesDirectory "input-spec.md"),
        "# Specification`r`n`r`n## Goal`r`n`r`nStub specification for the offline telemetry suite.", $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $casesDirectory "input-review.md"),
        "# Specification Review`r`n`r`n## Status`r`n`r`nFAIL`r`n`r`n## Summary`r`n`r`nStub review.", $utf8NoBom)

    # The fake host: defines the fake, checks it is active, runs one script.
    $fakeHostSource = @'
param([Parameter(Mandatory = $true)][string]$ScenarioFile)

$ErrorActionPreference = "Stop"
$global:FakeScenario = [System.IO.File]::ReadAllText($ScenarioFile) | ConvertFrom-Json

function global:Write-FakeCall {
    param([hashtable]$Entry)
    $line = ([pscustomobject]$Entry | ConvertTo-Json -Compress) + "`r`n"
    [System.IO.File]::AppendAllText($global:FakeScenario.callLog, $line, (New-Object System.Text.UTF8Encoding($false)))
}

function global:Get-FakeSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))).Replace("-", "") }
    finally { $sha.Dispose() }
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

    $systemSha = ""
    $promptSha = ""
    if ($Body -is [byte[]]) {
        $request = [System.Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        $systemSha = Get-FakeSha256 ([string]$request.system)
        $promptSha = Get-FakeSha256 ([string]$request.prompt)
    }
    Write-FakeCall @{ uri = $Uri; method = $Method; violation = $false; systemSha256 = $systemSha; promptSha256 = $promptSha }

    $scenario = $global:FakeScenario
    if ($Uri -ceq "http://127.0.0.1:9/api/tags") {
        if ($scenario.tags.fail) { throw "Fake Invoke-RestMethod: /api/tags is unreachable" }
        return [pscustomobject]@{ models = @($scenario.tags.models | ForEach-Object { [pscustomobject]@{ name = [string]$_ } }) }
    }
    if ($Uri -ceq "http://127.0.0.1:9/api/generate") {
        if ($scenario.generate.fail) { throw "Fake Invoke-RestMethod: /api/generate failed" }
        return [pscustomobject]@{
            response             = [string]$scenario.generate.response
            total_duration       = 1000
            load_duration        = 100
            prompt_eval_count    = 5
            prompt_eval_duration = 200
            eval_count           = [int]$scenario.generate.evalCount
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
if ($global:FakeScenario.runIdMode -eq "value") {
    $env:AI_HARNESS_RUN_ID = [string]$global:FakeScenario.runId
}
else {
    Remove-Item Env:\AI_HARNESS_RUN_ID -ErrorAction SilentlyContinue
}

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
    Write-Host "FAKE-HOST: the script ended with an unhandled error"
    $exitCode = 1
}
exit $exitCode
'@
    [System.IO.File]::WriteAllText($fakeHost, $fakeHostSource, $utf8NoBom)
}

# ---------------------------------------------------------------------------
# Guard 4: no other HTTP route in the copied scripts
# ---------------------------------------------------------------------------

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

function Invoke-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet("reviewer", "reviser")][string]$Agent,
        [string[]]$TagModels = @($fakeModel),
        [switch]$TagsFail,
        [switch]$GenerateFail,
        [string]$GenerateResponse = "",
        [int]$EvalCount = 10,
        [ValidateSet("unset", "value")][string]$RunIdMode = "unset",
        [string]$RunId = "",
        [switch]$DeleteConfigAfterGuard
    )

    # Guard 1 before every case.
    if (-not (Test-TempHarnessConfig -Path $harnessConfig)) {
        Stop-Suite "the temporary .ai\config.json is missing, invalid or not $fakeUrl"
    }

    if (Test-Path -LiteralPath $harnessLogs) { Remove-Item -LiteralPath $harnessLogs -Recurse -Force }
    $outputFile = Join-Path $casesDirectory "$Name.output.md"
    $callLog = Join-Path $casesDirectory "$Name.calls.jsonl"
    $scenarioFile = Join-Path $casesDirectory "$Name.scenario.json"
    foreach ($file in @($outputFile, $callLog)) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }

    $arguments = [ordered]@{
        Task       = "Create a stub specification for the offline telemetry suite."
        SpecFile   = (Join-Path $casesDirectory "input-spec.md")
        Model      = $fakeModel
        OutputFile = $outputFile
    }
    $scriptName = "review-spec.ps1"
    if ($Agent -eq "reviser") {
        $arguments.ReviewFile = (Join-Path $casesDirectory "input-review.md")
        $scriptName = "revise-spec.ps1"
    }
    if ([string]::IsNullOrEmpty($GenerateResponse)) {
        $GenerateResponse = if ($Agent -eq "reviewer") { $reviewPass } else { $revisedSpec }
    }

    $scenario = [ordered]@{
        script    = (Join-Path $harnessRoot "scripts\$scriptName")
        arguments = $arguments
        callLog   = $callLog
        tags      = [ordered]@{ fail = [bool]$TagsFail; models = @($TagModels) }
        generate  = [ordered]@{ fail = [bool]$GenerateFail; response = $GenerateResponse; evalCount = $EvalCount }
        runIdMode = $RunIdMode
        runId     = $RunId
    }
    [System.IO.File]::WriteAllText($scenarioFile, ($scenario | ConvertTo-Json -Depth 5), $utf8NoBom)

    if ($DeleteConfigAfterGuard) { Remove-Item -LiteralPath $harnessConfig -Force }

    # Error records from the child's stderr are dropped: they are PowerShell
    # text, never asserted on (NFR-006).
    $ErrorActionPreference = "Continue"
    try {
        $raw = @(& $powerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $fakeHost -ScenarioFile $scenarioFile 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = "Stop"
    }

    $lines = @($raw |
        Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
        ForEach-Object { [string]$_ })

    $calls = @()
    if (Test-Path -LiteralPath $callLog -PathType Leaf) {
        $calls = @([System.IO.File]::ReadAllLines($callLog) | Where-Object { $_ -ne "" } | ForEach-Object { $_ | ConvertFrom-Json })
    }

    $telemetry = @()
    $jsonl = Join-Path $harnessLogs "model-calls.jsonl"
    if (Test-Path -LiteralPath $jsonl -PathType Leaf) {
        $telemetry = @([System.IO.File]::ReadAllLines($jsonl) | Where-Object { $_.Trim() -ne "" } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    $csvHeader = $null
    $csv = Join-Path $harnessLogs "model-calls.csv"
    if (Test-Path -LiteralPath $csv -PathType Leaf) {
        $csvHeader = @([System.IO.File]::ReadAllLines($csv))[0]
    }

    $output = $null
    if (Test-Path -LiteralPath $outputFile -PathType Leaf) {
        $output = [System.IO.File]::ReadAllText($outputFile)
    }

    return [pscustomobject]@{
        ExitCode   = $exitCode
        Lines      = $lines
        Calls      = $calls
        Telemetry  = $telemetry
        CsvHeader  = $csvHeader
        Output     = $output
        FakeActive = ($lines -ccontains "FAKE-HOST: fake Invoke-RestMethod active")
    }
}

function Get-GenerateCalls {
    param($Run)
    return @($Run.Calls | Where-Object { -not $_.violation -and $_.uri -ceq "$fakeUrl/api/generate" })
}

# Guards 2 and 3, checked for every case.
function Get-GuardProblems {
    param($Run)

    $problems = @()
    if ($Run.ExitCode -eq 97) { $problems += "guard 2: the fake host reported that the fake was not active (exit 97)" }
    if (-not $Run.FakeActive) { $problems += "guard 2: the child did not report the fake as active" }
    $violations = @($Run.Calls | Where-Object { $_.violation })
    if ($violations.Count -gt 0) {
        $problems += "guard 3: URL allowlist violations recorded: " + (($violations | ForEach-Object { $_.uri }) -join ", ")
    }
    return $problems
}

function Get-TelemetryProblems {
    param($Run, [string]$Agent, [string]$Status)

    $problems = @()
    if ($Run.Telemetry.Count -ne 1) {
        $problems += "expected exactly one telemetry line, got $($Run.Telemetry.Count)"
        return $problems
    }
    $record = $Run.Telemetry[0]
    if ($record.agent -cne $Agent) { $problems += "telemetry agent: expected $Agent, got $($record.agent)" }
    if ($record.model -cne $fakeModel) { $problems += "telemetry model: expected $fakeModel, got $($record.model)" }
    if ($record.status -cne $Status) { $problems += "telemetry status: expected $Status, got $($record.status)" }
    return $problems
}

function Write-PromptHashes {
    param($Run, [string]$Agent)
    foreach ($call in (Get-GenerateCalls $Run)) {
        Write-Host "PROMPT-SHA256 | $Agent | system=$($call.systemSha256) | prompt=$($call.promptSha256)"
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "   AGENT TELEMETRY TEST SUITE (OFFLINE)" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""

    New-TempHarness

    # AC-030 startup: guard 1 rejects every unsafe configuration...
    $guardDirectory = Join-Path $tempRoot "guard1"
    [void][System.IO.Directory]::CreateDirectory($guardDirectory)
    $probes = [ordered]@{
        "a missing .ai\config.json"           = (Join-Path $guardDirectory "missing.json")
        "invalid JSON"                        = (Join-Path $guardDirectory "invalid.json")
        "ollamaUrl = http://localhost:11434"  = (Join-Path $guardDirectory "localhost.json")
        "ollamaUrl = http://127.0.0.1:10"     = (Join-Path $guardDirectory "other-url.json")
    }
    [System.IO.File]::WriteAllText($probes["invalid JSON"], "{ ""ollamaUrl"": ", $utf8NoBom)
    [System.IO.File]::WriteAllText($probes["ollamaUrl = http://localhost:11434"], "{ ""ollamaUrl"": ""http://localhost:11434"" }", $utf8NoBom)
    [System.IO.File]::WriteAllText($probes["ollamaUrl = http://127.0.0.1:10"], "{ ""ollamaUrl"": ""http://127.0.0.1:10"" }", $utf8NoBom)

    foreach ($label in $probes.Keys) {
        if (Test-TempHarnessConfig -Path $probes[$label]) {
            Write-Result -Name "AC-030 guard 1 rejects $label" -Problems @("accepted") -Run $null
            Stop-Suite "guard 1 accepted $label"
        }
        Write-Result -Name "AC-030 guard 1 rejects $label" -Problems @() -Run $null
    }

    # ...and accepts the real temporary config.
    if (-not (Test-TempHarnessConfig -Path $harnessConfig)) {
        Write-Result -Name "AC-030 guard 1 accepts the temporary config" -Problems @("rejected") -Run $null
        Stop-Suite "guard 1 rejected the temporary config"
    }
    Write-Result -Name "AC-030 guard 1 accepts the temporary config" -Problems @() -Run $null

    # AC-030 startup: guard 4, no other HTTP route in the copied scripts.
    $routes = Get-ForbiddenRoutes
    if ($routes.Files -lt 4 -or $routes.Found.Count -gt 0) {
        Write-Result -Name "AC-030 guard 4: no other HTTP route in the copied scripts" `
            -Problems @("files checked: $($routes.Files); found: " + ($routes.Found -join ", ")) -Run $null
        Stop-Suite "guard 4 found another HTTP route"
    }
    Write-Result -Name "AC-030 guard 4: no other HTTP route in the $($routes.Files) copied scripts" -Problems @() -Run $null

    # Reference CSV header from the current Write-HarnessModelTelemetry.
    . (Join-Path $harnessRoot "scripts\lib\telemetry.ps1")
    $referenceRoot = Join-Path $tempRoot "csv-reference"
    Write-HarnessModelTelemetry -Root $referenceRoot -Agent "reference" -Model "reference" `
        -StartedAt ([datetime]::UtcNow) -Status "success"
    $referenceHeader = @([System.IO.File]::ReadAllLines((Join-Path $referenceRoot "logs\model-calls.csv")))[0]

    # AC-012: a successful reviewer call is logged.
    $run = Invoke-Case -Name "ac012-reviewer-success" -Agent "reviewer" -EvalCount 10
    $problems = @(Get-GuardProblems $run)
    if ($run.ExitCode -ne 0) { $problems += "expected exit code 0" }
    if (-not ($run.Lines -ccontains "Review Status: PASS")) { $problems += "missing line: Review Status: PASS" }
    if ([string]::IsNullOrEmpty($run.Output)) { $problems += "the output file was not written" }
    $problems += @(Get-TelemetryProblems $run "spec-reviewer" "success")
    if ($run.Telemetry.Count -eq 1 -and [string]$run.Telemetry[0].eval_count -cne "10") { $problems += "telemetry eval_count: expected 10, got $($run.Telemetry[0].eval_count)" }
    if ($run.CsvHeader -cne $referenceHeader) { $problems += "CSV header differs from the current Write-HarnessModelTelemetry header" }
    if (@($referenceHeader -split ",").Count -ne 31) { $problems += "reference CSV header does not have 31 columns" }
    if (@(Get-GenerateCalls $run).Count -ne 1) { $problems += "expected one /api/generate call" }
    Write-Result -Name "AC-012 successful reviewer call writes one success record" -Problems $problems -Run $run
    Write-PromptHashes $run "spec-reviewer"

    # AC-016: a successful reviser call is logged.
    $run = Invoke-Case -Name "ac016-reviser-success" -Agent "reviser"
    $problems = @(Get-GuardProblems $run)
    if ($run.ExitCode -ne 0) { $problems += "expected exit code 0" }
    if ($run.Output -cne $revisedSpec) { $problems += "the output file does not hold the returned text" }
    $problems += @(Get-TelemetryProblems $run "spec-reviser" "success")
    Write-Result -Name "AC-016 successful reviser call writes one success record" -Problems $problems -Run $run
    Write-PromptHashes $run "spec-reviser"

    # AC-013: failed generation calls are logged.
    $run = Invoke-Case -Name "ac013-reviewer-error" -Agent "reviewer" -GenerateFail
    $problems = @(Get-GuardProblems $run)
    if ($run.ExitCode -ne 2) { $problems += "expected exit code 2" }
    if (-not ($run.Lines -ccontains "=== OLLAMA ERROR ===")) { $problems += "missing line: === OLLAMA ERROR ===" }
    $problems += @(Get-TelemetryProblems $run "spec-reviewer" "error")
    if ($run.Telemetry.Count -eq 1 -and [string]::IsNullOrWhiteSpace([string]$run.Telemetry[0].error)) { $problems += "telemetry error is empty" }
    Write-Result -Name "AC-013 failed reviewer call writes one error record" -Problems $problems -Run $run

    $run = Invoke-Case -Name "ac013-reviser-error" -Agent "reviser" -GenerateFail
    $problems = @(Get-GuardProblems $run)
    if ($run.ExitCode -eq 0) { $problems += "expected a non-zero exit code" }
    $problems += @(Get-TelemetryProblems $run "spec-reviser" "error")
    if ($run.Telemetry.Count -eq 1 -and [string]::IsNullOrWhiteSpace([string]$run.Telemetry[0].error)) { $problems += "telemetry error is empty" }
    Write-Result -Name "AC-013 failed reviser call writes one error record" -Problems $problems -Run $run

    # AC-014: a missing model stops the call before generation.
    foreach ($agent in @("reviewer", "reviser")) {
        $run = Invoke-Case -Name "ac014-$agent-missing-model" -Agent $agent -TagModels @("other-model:1b")
        $problems = @(Get-GuardProblems $run)
        if ($agent -eq "reviewer" -and $run.ExitCode -ne 2) { $problems += "expected exit code 2" }
        if ($agent -eq "reviser" -and $run.ExitCode -eq 0) { $problems += "expected a non-zero exit code" }
        if (-not ($run.Lines -ccontains "Model not found: $fakeModel")) { $problems += "missing line: Model not found: $fakeModel" }
        if (@(Get-GenerateCalls $run).Count -ne 0) { $problems += "expected zero /api/generate calls" }
        if ($run.Telemetry.Count -ne 0) { $problems += "expected zero telemetry lines, got $($run.Telemetry.Count)" }
        Write-Result -Name "AC-014 $agent with a missing model sends no generation request" -Problems $problems -Run $run

        $run = Invoke-Case -Name "ac014-$agent-case-insensitive" -Agent $agent -TagModels @("PHASE0-FAKE:1B")
        $problems = @(Get-GuardProblems $run)
        if ($run.ExitCode -ne 0) { $problems += "expected exit code 0" }
        if (@(Get-GenerateCalls $run).Count -ne 1) { $problems += "expected one /api/generate call" }
        Write-Result -Name "AC-014 $agent treats a model that differs only in case as installed" -Problems $problems -Run $run
    }

    # AC-015: unreachable Ollama stops the call before generation.
    foreach ($agent in @("reviewer", "reviser")) {
        $run = Invoke-Case -Name "ac015-$agent-unreachable" -Agent $agent -TagsFail
        $problems = @(Get-GuardProblems $run)
        if ($agent -eq "reviewer" -and $run.ExitCode -ne 2) { $problems += "expected exit code 2" }
        if ($agent -eq "reviser" -and $run.ExitCode -eq 0) { $problems += "expected a non-zero exit code" }
        if (@($run.Lines | Where-Object { $_.StartsWith("Ollama is not reachable at", [System.StringComparison]::Ordinal) }).Count -eq 0) {
            $problems += "missing line starting with: Ollama is not reachable at"
        }
        if (@(Get-GenerateCalls $run).Count -ne 0) { $problems += "expected zero /api/generate calls" }
        if ($run.Telemetry.Count -ne 0) { $problems += "expected zero telemetry lines, got $($run.Telemetry.Count)" }
        Write-Result -Name "AC-015 $agent with Ollama unreachable sends no generation request" -Problems $problems -Run $run
    }

    # AC-027: run_id from AI_HARNESS_RUN_ID, or a GUID when unset or blank.
    foreach ($agent in @("reviewer", "reviser")) {
        $telemetryAgent = if ($agent -eq "reviewer") { "spec-reviewer" } else { "spec-reviser" }

        $run = Invoke-Case -Name "ac027-$agent-run-id" -Agent $agent -RunIdMode "value" -RunId "phase0-run-id-test"
        $problems = @(Get-GuardProblems $run)
        $problems += @(Get-TelemetryProblems $run $telemetryAgent "success")
        if ($run.Telemetry.Count -eq 1 -and $run.Telemetry[0].run_id -cne "phase0-run-id-test") { $problems += "run_id: expected phase0-run-id-test, got $($run.Telemetry[0].run_id)" }
        Write-Result -Name "AC-027 $agent uses AI_HARNESS_RUN_ID" -Problems $problems -Run $run

        foreach ($variant in @(@{ Label = "unset"; Mode = "unset"; Value = "" }, @{ Label = "blank"; Mode = "value"; Value = "   " })) {
            $run = Invoke-Case -Name "ac027-$agent-run-id-$($variant.Label)" -Agent $agent -RunIdMode $variant.Mode -RunId $variant.Value
            $problems = @(Get-GuardProblems $run)
            $problems += @(Get-TelemetryProblems $run $telemetryAgent "success")
            $parsed = [guid]::Empty
            if ($run.Telemetry.Count -eq 1 -and -not [guid]::TryParse([string]$run.Telemetry[0].run_id, [ref]$parsed)) {
                $problems += "run_id is not a GUID: $($run.Telemetry[0].run_id)"
            }
            Write-Result -Name "AC-027 $agent with AI_HARNESS_RUN_ID $($variant.Label) uses a GUID" -Problems $problems -Run $run
        }
    }

    # AC-030 negative case: the temporary config is deleted after guard 1, so the
    # scripts fall back to http://localhost:11434. The fake must refuse it.
    $run = Invoke-Case -Name "ac030-config-deleted" -Agent "reviewer" -DeleteConfigAfterGuard
    [System.IO.File]::WriteAllText($harnessConfig, "{ ""ollamaUrl"": ""$fakeUrl"" }", $utf8NoBom)
    $problems = @()
    if ($run.ExitCode -eq 97 -or -not $run.FakeActive) { $problems += "guard 2: the child did not report the fake as active" }
    $violations = @($run.Calls | Where-Object { $_.violation })
    if (@($violations | Where-Object { $_.uri -ceq "http://localhost:11434/api/tags" }).Count -ne 1) {
        $problems += "expected one recorded violation for http://localhost:11434/api/tags"
    }
    if (@($run.Calls | Where-Object { -not $_.violation }).Count -ne 0) { $problems += "expected no allowed call" }
    if ($run.ExitCode -ne 2) { $problems += "expected exit code 2" }
    if ($run.Telemetry.Count -ne 0) { $problems += "expected zero telemetry lines" }
    Write-Result -Name "AC-030 without a config the fallback URL is refused, never requested" -Problems $problems -Run $run
}
finally {
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
Write-Host ""

if ($script:failed -eq 0 -and $script:passed -gt 0) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "STATUS: FAIL" -ForegroundColor Red
exit 1
