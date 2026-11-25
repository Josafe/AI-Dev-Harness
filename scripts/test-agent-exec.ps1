<#
.SYNOPSIS
    Offline, in-process tests for the engine core of scripts\lib\agent-exec.ps1:
    Invoke-OllamaHttp, Test-OllamaModel, Invoke-AgentModel
    (Phase 2, WP-2C; FR-204, FR-207, FR-209 to FR-216, NFR-201, AC-208 to AC-213,
    AC-217 NFR-201, and the engine part of AC-214).

.DESCRIPTION
    - No network, no Ollama, no child process, no real sleeping: the engine gets an
      injected fake transport (tests\mocks\fake-transport.ps1) and an injected -Sleep
      that only records its argument. Invoke-OllamaHttp is tested against a function
      named Invoke-RestMethod defined here (the Phase 1 method).
    - Guards (the four guards of the child-process suites, in-process form):
        1. the suite's Invoke-RestMethod refuses every URI outside http://127.0.0.1:9/
           and every call made while no test installed a handler (a violation);
        2. the suite's Invoke-RestMethod is the one that runs (it records every call);
        3. Invoke-OllamaHttp is replaced by a stub that records a violation unless a
           test installed a recording stub; the real function is captured before and
           run only through the fake Invoke-RestMethod;
        4. a static scan finds no HTTP route in agent-exec.ps1 other than the single
           Invoke-RestMethod call inside Invoke-OllamaHttp.
    - Expected values are literals worked out by hand (window 10000, ratio 0.1,
      reserved 1000 -> 8000 available tokens at 4 characters per token, and so on),
      never computed with the code under test.
    - Assertions never read localized text (NFR-202): categories, status values,
      record fields, request members, and the harness's own fixed codes.
    - Writes only under one folder in TEMP, removed at the end.
#>
param()

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$configLibrary = Join-Path $PSScriptRoot "lib\config.ps1"
$telemetryLibrary = Join-Path $PSScriptRoot "lib\telemetry.ps1"
$engineLibrary = Join-Path $PSScriptRoot "lib\agent-exec.ps1"
$mockWebResponse = Join-Path $root "tests\mocks\fake-web-response.ps1"
$mockTransport = Join-Path $root "tests\mocks\fake-transport.ps1"

foreach ($path in @($configLibrary, $telemetryLibrary, $engineLibrary, $mockWebResponse, $mockTransport)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required path not found: $path" }
}

. $configLibrary
. $telemetryLibrary
. $engineLibrary
. $mockWebResponse
. $mockTransport

# The real transport, captured before the guard stub replaces it by name.
$realHttp = (Get-Command -Name Invoke-OllamaHttp -CommandType Function).ScriptBlock

# Guard 3: the default transport must not be reached unless a test installed a stub.
$script:httpStub = $null
$script:httpViolations = 0
function Invoke-OllamaHttp {
    param($Request)
    if ($null -eq $script:httpStub) {
        $script:httpViolations++
        throw "violation: Invoke-OllamaHttp was called by an offline in-process suite"
    }
    return (& $script:httpStub $Request)
}

# Guards 1 and 2: the only Invoke-RestMethod that can run. Declares exactly the
# parameters the Phase 0 and Phase 1 fake hosts declare, so an extra parameter in
# the call (for example -ErrorAction or -Headers) fails the call.
$script:rest = [pscustomobject]@{
    Handler    = $null
    Calls      = (New-Object 'System.Collections.Generic.List[object]')
    Violations = 0
}
function Invoke-RestMethod {
    param([string]$Uri, [string]$Method, $Body, [string]$ContentType, [int]$TimeoutSec)

    $script:rest.Calls.Add([pscustomobject]@{
            Uri         = $Uri
            Method      = $Method
            Body        = $Body
            ContentType = $ContentType
            TimeoutSec  = $TimeoutSec
            Bound       = (($PSBoundParameters.Keys | Sort-Object) -join ",")
        })
    if (-not $Uri.StartsWith("http://127.0.0.1:9/", [System.StringComparison]::Ordinal) -or $null -eq $script:rest.Handler) {
        $script:rest.Violations++
        throw "violation: Invoke-RestMethod reached outside a test that installed a handler, or outside http://127.0.0.1:9/"
    }
    return (& $script:rest.Handler $Uri)
}

$script:passed = 0
$script:failed = 0
$script:caseNumber = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Body)

    # Every in-process case starts from a clean engine state (FR-213, FR-215).
    Reset-AgentExecState
    $script:httpStub = $null
    $script:rest.Handler = $null
    $script:rest.Calls.Clear()
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
    finally {
        $script:httpStub = $null
        $script:rest.Handler = $null
    }
}

function Assert-Equal {
    param([string]$What, $Expected, $Actual)

    if (-not ("$Expected" -ceq "$Actual")) {
        throw "$What : expected '$Expected', got '$Actual'"
    }
}

function Assert-True {
    param([string]$What, $Condition)

    if (-not $Condition) { throw "$What : condition is false" }
}

function Assert-Throws {
    param([string]$What, [scriptblock]$Action, [string]$Prefix = "")

    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }

    if ($null -eq $message) { throw "$What : nothing was thrown" }
    if ($Prefix -and -not $message.StartsWith($Prefix, [System.StringComparison]::Ordinal)) {
        throw "$What : expected a message starting with '$Prefix', got '$message'"
    }
}

# ---- fixtures ---------------------------------------------------------------------

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-exec-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-CaseRoot {
    $script:caseNumber++
    $path = Join-Path $tempRoot ("case" + $script:caseNumber)
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

# A normalized v2 registry built through the real loader. Profiles:
#   alpha  m-alpha  window 10000, reserved 1000, timeout 44, think true,  options temperature 0.2, num_predict 77
#   beta   m-beta   window 10000, reserved 1000, timeout 44, think false
#   gamma  m-gamma  window 10000, reserved 1000, timeout 44, think "default"
#   delta  m-delta  no window, no reserved, no think, no options
# With ratio 0.1 the margin of a 10000 window is 1000, so 8000 tokens are available.
function New-TestRegistry {
    param(
        [int]$MaxAttempts = 2,
        [int]$Backoff = 5,
        [bool]$Warmup = $false,
        [string]$BudgetMode = "",
        $CharsPerToken = 4,
        [bool]$StripThinking = $true
    )

    $defaults = [ordered]@{ profile = "alpha"; timeoutSec = 600; safetyMarginRatio = 0.1; stripThinking = $StripThinking; charsPerToken = $CharsPerToken }
    if ($BudgetMode.Length -gt 0) { $defaults.budgetMode = $BudgetMode }
    $config = [ordered]@{
        schemaVersion = 2
        ollama        = [ordered]@{ url = "http://127.0.0.1:9"; healthTimeoutSec = 7; maxAttempts = $MaxAttempts; retryBackoffSec = $Backoff; warmup = $Warmup }
        defaults      = $defaults
        profiles      = [ordered]@{
            alpha = [ordered]@{ model = "m-alpha"; contextWindow = 10000; reservedOutputTokens = 1000; timeoutSec = 44; think = $true; options = [ordered]@{ temperature = 0.2; num_predict = 77 } }
            beta  = [ordered]@{ model = "m-beta"; contextWindow = 10000; reservedOutputTokens = 1000; timeoutSec = 44; think = $false }
            gamma = [ordered]@{ model = "m-gamma"; contextWindow = 10000; reservedOutputTokens = 1000; timeoutSec = 44; think = "default" }
            delta = [ordered]@{ model = "m-delta" }
        }
        agents        = [ordered]@{
            "a-alpha" = [ordered]@{ profile = "alpha" }
            "a-beta"  = [ordered]@{ profile = "beta" }
            "a-gamma" = [ordered]@{ profile = "gamma" }
            "a-delta" = [ordered]@{ profile = "delta" }
        }
    }
    $parsed = ($config | ConvertTo-Json -Depth 10) | ConvertFrom-Json
    return ConvertTo-HarnessRegistry -Config $parsed
}

function Get-TestExecution {
    param($Registry, [string]$Agent = "a-alpha")
    return Resolve-HarnessExecution -Agent $Agent -Registry $Registry
}

# Records the seconds passed to -Sleep; nothing sleeps.
function New-SleepRecorder {
    $list = New-Object 'System.Collections.Generic.List[int]'
    $block = { param($Seconds) $list.Add([int]$Seconds) }.GetNewClosure()
    return [pscustomobject]@{ Sleep = $block; List = $list }
}

# Records the arguments of -OnRetry as "attempt|max|category|wait".
function New-RetryRecorder {
    $list = New-Object 'System.Collections.Generic.List[string]'
    $block = { param($Attempt, $Max, $Category, $Wait) $list.Add("$Attempt|$Max|$Category|$Wait") }.GetNewClosure()
    return [pscustomobject]@{ OnRetry = $block; List = $list }
}

function Invoke-Engine {
    param(
        $Exec, $Registry, $Fake,
        [string]$System = "AB", [string]$Prompt = "CDE",
        [string]$TelemetryRoot = "", $Parts = $null, $Check = $null, $Sleeper = $null, $Retry = $null
    )

    $arguments = @{ Execution = $Exec; Registry = $Registry; System = $System; Prompt = $Prompt; Transport = $Fake.Transport }
    if ($TelemetryRoot.Length -gt 0) { $arguments.TelemetryRoot = $TelemetryRoot }
    if ($null -ne $Parts) { $arguments.Parts = $Parts }
    if ($null -ne $Check) { $arguments.ResponseCheck = $Check }
    # the engine is never allowed to really sleep in this suite
    if ($null -eq $Sleeper) { $Sleeper = New-SleepRecorder }
    $arguments.Sleep = $Sleeper.Sleep
    if ($null -ne $Retry) { $arguments.OnRetry = $Retry.OnRetry }
    return Invoke-AgentModel @arguments
}

function Read-Records {
    param([string]$CaseRoot)

    $path = Join-Path $CaseRoot "logs\model-calls.jsonl"
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { $_ | ConvertFrom-Json })
}

function New-Ok {
    param([string]$Text = "answer", $Thinking = $null, [string]$DoneReason = "stop", [long]$PromptEvalCount = 10, [long]$EvalCount = 5)
    return New-FakeOkRecord -Response (New-FakeGenerateResponse -Text $Text -Thinking $Thinking -DoneReason $DoneReason -PromptEvalCount $PromptEvalCount -EvalCount $EvalCount)
}

function New-Fail5xx { return New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus 500 -Body '{"error":"gpu init failed"}' }
function New-FailReset { return New-FakeFailureRecord -WebStatus "ConnectionClosed" }
function New-FailTimeout { return New-FakeFailureRecord -WebStatus "Timeout" }

# The members of a decoded request body, sorted, as one string.
function Get-BodyMembers {
    param($Call)
    return ((@($Call.Body.PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object) -join ",")
}

try {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "   AGENT ENGINE CORE (OFFLINE)" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan

    # -----------------------------------------------------------------------
    # AC-208 retry behavior
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-208 retry ===" -ForegroundColor Cyan

    Test-Case "AC-208 Get-AgentRetryDelaySec: 5, 10, 20, 40, 60, 60 for base 5 (cap 60) and 0 for base 0" {
        $expected = @(5, 10, 20, 40, 60, 60)
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            Assert-Equal "base 5 attempt $attempt" $expected[$attempt - 1] (Get-AgentRetryDelaySec -Attempt $attempt -BackoffSec 5)
        }
        foreach ($attempt in 1, 2, 5, 9) { Assert-Equal "base 0 attempt $attempt" 0 (Get-AgentRetryDelaySec -Attempt $attempt -BackoffSec 0) }
        Assert-Equal "base 60 attempt 1" 60 (Get-AgentRetryDelaySec -Attempt 1 -BackoffSec 60)
        Assert-Equal "base 60 attempt 3" 60 (Get-AgentRetryDelaySec -Attempt 3 -BackoffSec 60)
        Assert-Equal "base 30 attempt 1" 30 (Get-AgentRetryDelaySec -Attempt 1 -BackoffSec 30)
        Assert-Equal "base 30 attempt 2" 60 (Get-AgentRetryDelaySec -Attempt 2 -BackoffSec 30)
    }

    Test-Case "AC-208 a retryable failure followed by success returns ok, attempts 2, one sleep of 5 s, one OnRetry call (2, 2, http_5xx, 5) and one telemetry record with attempts 2" {
        $registry = New-TestRegistry -MaxAttempts 2 -Backoff 5
        $fake = New-FakeTransport -Steps @((New-Fail5xx), (New-Ok -Text "fine"))
        $sleeper = New-SleepRecorder
        $retry = New-RetryRecorder
        $caseRoot = New-CaseRoot
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -Sleeper $sleeper -Retry $retry -TelemetryRoot $caseRoot
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "text" "fine" $result.text
        Assert-Equal "attempts" 2 $result.meta.attempts
        Assert-True "no error" ($null -eq $result.error)
        Assert-Equal "generate calls" 2 $fake.Count("generate")
        Assert-Equal "sleeps" "5" ($sleeper.List -join ",")
        Assert-Equal "OnRetry arguments" "2|2|http_5xx|5" ($retry.List -join ";")
        $records = @(Read-Records $caseRoot)
        Assert-Equal "telemetry lines" 1 $records.Count
        Assert-Equal "record attempts" 2 $records[0].attempts
        Assert-Equal "record status" "success" $records[0].status
        Assert-Equal "record error_category" "" $records[0].error_category
    }

    Test-Case "AC-208 maxAttempts 1 never retries: one transport call, no sleep, attempts 1, category http_5xx" {
        $registry = New-TestRegistry -MaxAttempts 1 -Backoff 5
        $fake = New-FakeTransport -Steps @((New-Fail5xx), (New-Ok))
        $sleeper = New-SleepRecorder
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -Sleeper $sleeper
        Assert-Equal "status" "error" $result.status
        Assert-Equal "category" "http_5xx" $result.error.category
        Assert-Equal "attempts" 1 $result.meta.attempts
        Assert-Equal "error attempts" 1 $result.error.attempts
        Assert-Equal "generate calls" 1 $fake.Count("generate")
        Assert-Equal "sleeps" 0 $sleeper.List.Count
    }

    Test-Case "AC-208 exhausted retries: maxAttempts 3, base 5 -> 3 calls, sleeps 5 and 10, last category, attempts 3, a hint, one telemetry line with attempts 3" {
        $registry = New-TestRegistry -MaxAttempts 3 -Backoff 5
        $fake = New-FakeTransport -Steps @((New-Fail5xx)) -RepeatLast
        $sleeper = New-SleepRecorder
        $retry = New-RetryRecorder
        $caseRoot = New-CaseRoot
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -Sleeper $sleeper -Retry $retry -TelemetryRoot $caseRoot
        Assert-Equal "status" "error" $result.status
        Assert-Equal "category" "http_5xx" $result.error.category
        Assert-Equal "attempts" 3 $result.meta.attempts
        Assert-Equal "error.attempts" 3 $result.error.attempts
        Assert-Equal "generate calls" 3 $fake.Count("generate")
        Assert-Equal "sleeps" "5,10" ($sleeper.List -join ",")
        Assert-Equal "OnRetry" "2|3|http_5xx|5;3|3|http_5xx|10" ($retry.List -join ";")
        Assert-True "hint present" ($result.error.hint.Length -gt 0)
        Assert-Equal "retryable flag" $true $result.error.retryable
        Assert-Equal "http status" 500 $result.error.httpStatus
        Assert-Equal "detail is the JSON error string" "gpu init failed" $result.error.detail
        Assert-Equal "text is empty on error" "" $result.text
        $records = @(Read-Records $caseRoot)
        Assert-Equal "telemetry lines" 1 $records.Count
        Assert-Equal "record attempts" 3 $records[0].attempts
        Assert-Equal "record error_category" "http_5xx" $records[0].error_category
        Assert-Equal "record status" "error" $records[0].status
    }

    Test-Case "AC-208 the waits never exceed 60 s: maxAttempts 5, base 30 -> 30, 60, 60, 60" {
        $registry = New-TestRegistry -MaxAttempts 5 -Backoff 30
        $fake = New-FakeTransport -Steps @((New-Fail5xx)) -RepeatLast
        $sleeper = New-SleepRecorder
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -Sleeper $sleeper
        Assert-Equal "calls" 5 $fake.Count("generate")
        Assert-Equal "attempts" 5 $result.meta.attempts
        Assert-Equal "sleeps" "30,60,60,60" ($sleeper.List -join ",")
        foreach ($seconds in $sleeper.List) { Assert-True "sleep $seconds is at most 60" ($seconds -le 60) }
    }

    Test-Case "AC-208 base 5, maxAttempts 5: the sleeps double from 5 and stop at the cap (5, 10, 20, 40)" {
        $registry = New-TestRegistry -MaxAttempts 5 -Backoff 5
        $fake = New-FakeTransport -Steps @((New-Fail5xx)) -RepeatLast
        $sleeper = New-SleepRecorder
        Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -Sleeper $sleeper | Out-Null
        Assert-Equal "sleeps" "5,10,20,40" ($sleeper.List -join ",")
    }

    Test-Case "AC-208 timeout, transport_unreachable, http_4xx, transport_other are never retried (one call, no sleep, attempts 1)" {
        $registry = New-TestRegistry -MaxAttempts 3 -Backoff 5
        $cases = @(
            @{ Name = "timeout"; Step = (New-FakeFailureRecord -WebStatus "Timeout") },
            @{ Name = "transport_unreachable"; Step = (New-FakeFailureRecord -WebStatus "ConnectFailure") },
            @{ Name = "http_4xx"; Step = (New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus 400 -Body '{"error":"bad"}') },
            @{ Name = "transport_other"; Step = (New-FakeFailureRecord -ExceptionType "Contoso.Unknown") }
        )
        foreach ($case in $cases) {
            $fake = New-FakeTransport -Steps @($case.Step, (New-Ok))
            $sleeper = New-SleepRecorder
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -Sleeper $sleeper
            Assert-Equal "$($case.Name) category" $case.Name $result.error.category
            Assert-Equal "$($case.Name) calls" 1 $fake.Count("generate")
            Assert-Equal "$($case.Name) sleeps" 0 $sleeper.List.Count
            Assert-Equal "$($case.Name) attempts" 1 $result.meta.attempts
            Assert-Equal "$($case.Name) retryable flag" $false $result.error.retryable
        }
    }

    Test-Case "AC-208 empty_response, thinking_budget_exhausted and format_invalid are never retried (one call, no sleep)" {
        $registry = New-TestRegistry -MaxAttempts 3 -Backoff 5
        $cases = @(
            @{ Name = "empty_response"; Step = (New-Ok -Text ""); Check = $null },
            @{ Name = "thinking_budget_exhausted"; Step = (New-Ok -Text "" -DoneReason "length"); Check = $null },
            @{ Name = "format_invalid"; Step = (New-Ok -Text "no status here"); Check = { param($t) "no_status" } }
        )
        foreach ($case in $cases) {
            $fake = New-FakeTransport -Steps @($case.Step, (New-Ok))
            $sleeper = New-SleepRecorder
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -Sleeper $sleeper -Check $case.Check
            Assert-Equal "$($case.Name) category" $case.Name $result.error.category
            Assert-Equal "$($case.Name) calls" 1 $fake.Count("generate")
            Assert-Equal "$($case.Name) sleeps" 0 $sleeper.List.Count
            Assert-Equal "$($case.Name) attempts" 1 $result.meta.attempts
        }
    }

    Test-Case "AC-208 a connection reset (and an IOException failure) is retried, then succeeds" {
        $registry = New-TestRegistry -MaxAttempts 2 -Backoff 5
        foreach ($first in @((New-FailReset), (New-FakeFailureRecord -ExceptionType "System.IO.IOException"), (New-FakeFailureRecord -ExceptionType "System.Net.Sockets.SocketException"))) {
            $fake = New-FakeTransport -Steps @($first, (New-Ok -Text "again"))
            $sleeper = New-SleepRecorder
            $retry = New-RetryRecorder
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -Sleeper $sleeper -Retry $retry
            Assert-Equal "status" "ok" $result.status
            Assert-Equal "attempts" 2 $result.meta.attempts
            Assert-Equal "sleeps" "5" ($sleeper.List -join ",")
            Assert-Equal "OnRetry" "2|2|transport_reset|5" ($retry.List -join ";")
        }
    }

    Test-Case "AC-208 a failure that changes category stops the retries: 500 then 400 -> two calls, http_4xx, attempts 2" {
        $registry = New-TestRegistry -MaxAttempts 4 -Backoff 5
        $fake = New-FakeTransport -Steps @((New-Fail5xx), (New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus 400), (New-Ok))
        $sleeper = New-SleepRecorder
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -Sleeper $sleeper
        Assert-Equal "category" "http_4xx" $result.error.category
        Assert-Equal "attempts" 2 $result.meta.attempts
        Assert-Equal "calls" 2 $fake.Count("generate")
        Assert-Equal "sleeps" "5" ($sleeper.List -join ",")
    }

    Test-Case "AC-208 retryBackoffSec 0 waits not at all: no sleep call, OnRetry still reports a wait of 0, and the default Start-Sleep is never reached" {
        $registry = New-TestRegistry -MaxAttempts 3 -Backoff 0
        $fake = New-FakeTransport -Steps @((New-Fail5xx), (New-FailReset), (New-Ok -Text "x"))
        $retry = New-RetryRecorder
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $sleeper = New-SleepRecorder
        $result = Invoke-AgentModel -Execution (Get-TestExecution $registry) -Registry $registry -System "AB" -Prompt "CDE" -Transport $fake.Transport -OnRetry $retry.OnRetry -Sleep $sleeper.Sleep
        $watch.Stop()
        Assert-Equal "-Sleep is not called for a wait of 0" 0 $sleeper.List.Count
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "attempts" 3 $result.meta.attempts
        Assert-Equal "OnRetry" "2|3|http_5xx|0;3|3|transport_reset|0" ($retry.List -join ";")
        Assert-True "no real waiting (under 3 s)" ($watch.ElapsedMilliseconds -lt 3000)
    }

    Test-Case "AC-208 an OnRetry hook that throws does not lose the call" {
        $registry = New-TestRegistry -MaxAttempts 2 -Backoff 0
        $fake = New-FakeTransport -Steps @((New-Fail5xx), (New-Ok -Text "kept"))
        $result = Invoke-AgentModel -Execution (Get-TestExecution $registry) -Registry $registry -System "A" -Prompt "B" -Transport $fake.Transport -OnRetry { throw "display hook failed" }
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "text" "kept" $result.text
    }

    Test-Case "AC-208 (M-3) a -Sleep or -OnRetry hook that throws, emits objects, breaks or continues never loses the call: the retry still happens, the status is ok, exactly one record, and the attempts are 2" {
        $registry = New-TestRegistry -MaxAttempts 2 -Backoff 5
        $hooks = @(
            @{ Name = "Sleep throw"; Sleep = { param($s) throw "sleep hook failed" }; Retry = $null },
            @{ Name = "Sleep emits an object with Attempts"; Sleep = { param($s) [pscustomobject]@{ Record = 1; Attempts = 99; Classification = "x" } }; Retry = $null },
            @{ Name = "Sleep break"; Sleep = { param($s) break }; Retry = $null },
            @{ Name = "Sleep continue"; Sleep = { param($s) continue }; Retry = $null },
            @{ Name = "OnRetry throw"; Sleep = $null; Retry = { param($a, $m, $c, $w) throw "retry hook failed" } },
            @{ Name = "OnRetry emits an object with Attempts"; Sleep = $null; Retry = { param($a, $m, $c, $w) [pscustomobject]@{ Record = 1; Attempts = 99; Classification = "x" } } },
            @{ Name = "OnRetry break"; Sleep = $null; Retry = { param($a, $m, $c, $w) break } },
            @{ Name = "OnRetry continue"; Sleep = $null; Retry = { param($a, $m, $c, $w) continue } },
            @{ Name = "OnRetry emits strings"; Sleep = $null; Retry = { param($a, $m, $c, $w) "one"; "two" } }
        )
        $hooksDone = 0
        foreach ($hook in $hooks) {
            $fake = New-FakeTransport -Steps @((New-Fail5xx), (New-Ok -Text "kept"))
            $caseRoot = New-CaseRoot
            $arguments = @{ Execution = (Get-TestExecution $registry); Registry = $registry; System = "A"; Prompt = "B"; Transport = $fake.Transport; TelemetryRoot = $caseRoot }
            if ($null -ne $hook.Sleep) { $arguments.Sleep = $hook.Sleep } else { $arguments.Sleep = (New-SleepRecorder).Sleep }
            if ($null -ne $hook.Retry) { $arguments.OnRetry = $hook.Retry }
            $result = Invoke-AgentModel @arguments
            Assert-Equal "$($hook.Name) status" "ok" $result.status
            Assert-Equal "$($hook.Name) text" "kept" $result.text
            Assert-Equal "$($hook.Name) attempts" 2 $result.meta.attempts
            Assert-Equal "$($hook.Name) generate calls" 2 $fake.Count("generate")
            $records = @(Read-Records $caseRoot)
            Assert-Equal "$($hook.Name) lines" 1 $records.Count
            Assert-Equal "$($hook.Name) record attempts" 2 $records[0].attempts
            Assert-Equal "$($hook.Name) record status" "success" $records[0].status
            $hooksDone++
        }
        Assert-Equal "every hook ran to the end of the loop body (a leaked break would end the loop early)" $hooks.Count $hooksDone
        # exhausted retries with a breaking hook: the real category, not an empty one
        $exhausted = New-FakeTransport -Steps @((New-Fail5xx)) -RepeatLast
        $caseRoot = New-CaseRoot
        $result = Invoke-AgentModel -Execution (Get-TestExecution $registry) -Registry $registry -System "A" -Prompt "B" -Transport $exhausted.Transport -TelemetryRoot $caseRoot -Sleep { param($s) break } -OnRetry { param($a, $m, $c, $w) continue }
        Assert-Equal "exhausted status" "error" $result.status
        Assert-Equal "exhausted category" "http_5xx" $result.error.category
        Assert-Equal "exhausted attempts" 2 $result.meta.attempts
        Assert-Equal "exhausted record category" "http_5xx" (@(Read-Records $caseRoot))[0].error_category
        Assert-Equal "exhausted lines" 1 (@(Read-Records $caseRoot)).Count
    }

    Test-Case "AC-213 (M-3) a transport that breaks or continues is a failure record (transport_other, invalid_transport_result), one record, no loop; also in Test-OllamaModel" {
        $registry = New-TestRegistry -MaxAttempts 2 -Backoff 0
        # a break or continue that escaped the engine would end this loop early and silently
        $completedIterations = 0
        foreach ($transport in @({ param($Request) break }, { param($Request) continue })) {
            $caseRoot = New-CaseRoot
            $result = Invoke-AgentModel -Execution (Get-TestExecution $registry) -Registry $registry -System "A" -Prompt "B" -Transport $transport -TelemetryRoot $caseRoot
            Assert-Equal "status" "error" $result.status
            Assert-Equal "category" "transport_other" $result.error.category
            Assert-True "detail names the shape" ($result.error.detail.Contains("invalid_transport_result"))
            Assert-Equal "lines" 1 (@(Read-Records $caseRoot)).Count

            Reset-AgentExecState
            $tagsRoot = New-CaseRoot
            $tags = Test-OllamaModel -Execution (Get-TestExecution $registry) -Registry $registry -Transport $transport -TelemetryRoot $tagsRoot
            Assert-Equal "tags available" $false $tags.available
            Assert-Equal "tags category" "transport_other" $tags.category
            Assert-Equal "tags lines" 1 (@(Read-Records $tagsRoot)).Count
            $completedIterations++
        }
        Assert-Equal "both transports ran to the end of the loop body" 2 $completedIterations
    }

    # -----------------------------------------------------------------------
    # AC-209 warm-up
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-209 warm-up ===" -ForegroundColor Cyan

    Test-Case "AC-209 warmup true: one warmup request (members exactly model, options, stream), then one generate; with options as resolved" {
        $registry = New-TestRegistry -Warmup $true
        $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response ([pscustomobject]@{ done = $true })), (New-Ok))
        $caseRoot = New-CaseRoot
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -TelemetryRoot $caseRoot
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "purposes" "warmup,generate" (($fake.Calls | ForEach-Object { $_.Purpose }) -join ",")
        $warm = $fake.Calls[0]
        Assert-Equal "warmup members" "model,options,stream" (Get-BodyMembers $warm)
        Assert-Equal "warmup model" "m-alpha" $warm.Body.model
        Assert-Equal "warmup stream is JSON false" $false $warm.Body.stream
        Assert-True "warmup stream is a JSON boolean, not the text False (M-5)" ($warm.Body.stream -is [bool])
        Assert-True "the raw warmup body has stream:false" ($warm.BodyText -match '"stream"\s*:\s*false')
        Assert-Equal "warmup option temperature" 0.2 $warm.Body.options.temperature
        Assert-Equal "warmup option num_predict" 77 $warm.Body.options.num_predict
        Assert-Equal "warmup option num_ctx" 10000 $warm.Body.options.num_ctx
        Assert-Equal "warmup has no prompt, system or think" "" ((@("prompt", "system", "think") | Where-Object { $null -ne $warm.Body.PSObject.Properties[$_] }) -join ",")
        Assert-Equal "warmup url" "http://127.0.0.1:9/api/generate" $warm.Url
        Assert-Equal "warmup method" "Post" $warm.Method
        Assert-Equal "warmup timeout is the profile's" 44 $warm.TimeoutSec
        Assert-Equal "generate members" "model,options,prompt,stream,system,think" (Get-BodyMembers $fake.Calls[1])
        Assert-Equal "meta.warmup state" "sent" $result.meta.warmup.state
        Assert-Equal "one telemetry line (the warm-up is not a record)" 1 (@(Read-Records $caseRoot)).Count
    }

    Test-Case "AC-209 the warm-up runs once per model per process, again for another model and again after Reset-AgentExecState" {
        $registry = New-TestRegistry -Warmup $true
        $alpha = Get-TestExecution $registry "a-alpha"
        $beta = Get-TestExecution $registry "a-beta"
        # a transport that answers warmup requests with a bare ok and generate requests with an answer
        $fake = New-FakeTransport -Steps @({ param($r) if ($r.Purpose -ceq "warmup") { New-FakeOkRecord -Response ([pscustomobject]@{ done = $true }) } else { New-Ok } }) -RepeatLast
        Invoke-Engine -Exec $alpha -Registry $registry -Fake $fake | Out-Null
        Invoke-Engine -Exec $alpha -Registry $registry -Fake $fake | Out-Null
        Assert-Equal "after two calls of one model: warmups" 1 $fake.Count("warmup")
        Assert-Equal "after two calls of one model: generates" 2 $fake.Count("generate")
        $second = Invoke-Engine -Exec $alpha -Registry $registry -Fake $fake
        Assert-Equal "cached state" "cached" $second.meta.warmup.state
        Invoke-Engine -Exec $beta -Registry $registry -Fake $fake | Out-Null
        Assert-Equal "another model warms again" 2 $fake.Count("warmup")
        Reset-AgentExecState
        Invoke-Engine -Exec $alpha -Registry $registry -Fake $fake | Out-Null
        Assert-Equal "after Reset-AgentExecState" 3 $fake.Count("warmup")
    }

    Test-Case "AC-209 warmup false: no warmup request and meta.warmup is null" {
        $registry = New-TestRegistry -Warmup $false
        $fake = New-FakeTransport -Steps @((New-Ok))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake
        Assert-Equal "warmup requests" 0 $fake.Count("warmup")
        Assert-Equal "generate requests" 1 $fake.Count("generate")
        Assert-True "meta.warmup is null" ($null -eq $result.meta.warmup)
    }

    Test-Case "AC-209 a warm-up that fails after its retries returns that category, meta.warmup, no generate request and one telemetry line" {
        $registry = New-TestRegistry -Warmup $true -MaxAttempts 2 -Backoff 5
        $fake = New-FakeTransport -Steps @((New-Fail5xx)) -RepeatLast
        $sleeper = New-SleepRecorder
        $caseRoot = New-CaseRoot
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -Sleeper $sleeper -TelemetryRoot $caseRoot
        Assert-Equal "status" "error" $result.status
        Assert-Equal "category" "http_5xx" $result.error.category
        Assert-Equal "warmup requests (retried)" 2 $fake.Count("warmup")
        Assert-Equal "generate requests" 0 $fake.Count("generate")
        Assert-Equal "sleeps" "5" ($sleeper.List -join ",")
        Assert-Equal "meta.warmup state" "failed" $result.meta.warmup.state
        Assert-Equal "meta.warmup category" "http_5xx" $result.meta.warmup.category
        Assert-Equal "meta.warmup attempts" 2 $result.meta.warmup.attempts
        $records = @(Read-Records $caseRoot)
        Assert-Equal "telemetry lines" 1 $records.Count
        Assert-Equal "record category" "http_5xx" $records[0].error_category
        Assert-Equal "record attempts" 2 $records[0].attempts
    }

    Test-Case "AC-209 a failed warm-up is not remembered: the next call warms again; a warm-up retry that succeeds proceeds to generate with attempts 1" {
        $registry = New-TestRegistry -Warmup $true -MaxAttempts 2 -Backoff 0
        $fake = New-FakeTransport -Steps @((New-Fail5xx), (New-FakeOkRecord -Response ([pscustomobject]@{ done = $true })), (New-Ok))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "purposes" "warmup,warmup,generate" (($fake.Calls | ForEach-Object { $_.Purpose }) -join ",")
        Assert-Equal "generation attempts" 1 $result.meta.attempts
        Assert-Equal "warmup attempts" 2 $result.meta.warmup.attempts

        Reset-AgentExecState
        $failing = New-FakeTransport -Steps @((New-FakeFailureRecord -WebStatus "ConnectFailure"), (New-FakeOkRecord -Response ([pscustomobject]@{ done = $true })), (New-Ok))
        $first = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $failing
        Assert-Equal "first call fails on warm-up" "transport_unreachable" $first.error.category
        $second = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $failing
        Assert-Equal "second call status" "ok" $second.status
        Assert-Equal "warmups" 2 $failing.Count("warmup")
    }

    Test-Case "AC-209 a profile without options sends a warm-up with members model and stream only" {
        $registry = New-TestRegistry -Warmup $true
        $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response ([pscustomobject]@{ done = $true })), (New-Ok))
        Invoke-Engine -Exec (Get-TestExecution $registry "a-delta") -Registry $registry -Fake $fake | Out-Null
        Assert-Equal "warmup members" "model,stream" (Get-BodyMembers $fake.Calls[0])
        Assert-Equal "generate members" "model,prompt,stream,system" (Get-BodyMembers $fake.Calls[1])
    }

    # -----------------------------------------------------------------------
    # AC-210 think only when explicit (FR-214)
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-210 think ===" -ForegroundColor Cyan

    Test-Case "AC-210 profile think true -> member think equal to JSON true; meta.thinkSent true" {
        $registry = New-TestRegistry
        $fake = New-FakeTransport -Steps @((New-Ok))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry "a-alpha") -Registry $registry -Fake $fake
        $body = $fake.Calls[0].Body
        Assert-True "think member present" ($null -ne $body.PSObject.Properties["think"])
        Assert-True "think is a JSON boolean" ($body.think -is [bool])
        Assert-Equal "think value" $true $body.think
        Assert-Equal "thinkSent" "true" $result.meta.thinkSent
    }

    Test-Case "AC-210 profile think false -> member think present and equal to JSON false (not omitted); meta.thinkSent false" {
        $registry = New-TestRegistry
        $fake = New-FakeTransport -Steps @((New-Ok))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry "a-beta") -Registry $registry -Fake $fake
        $body = $fake.Calls[0].Body
        Assert-True "think member present" ($null -ne $body.PSObject.Properties["think"])
        Assert-True "think is a JSON boolean" ($body.think -is [bool])
        Assert-Equal "think value" $false $body.think
        Assert-Equal "thinkSent" "false" $result.meta.thinkSent
        Assert-True "the raw body text has a think member" ($fake.Calls[0].BodyText -match '"think"\s*:\s*false')
    }

    Test-Case "AC-210 think 'default', absent, and a v1 configuration send no think member; meta.thinkSent omitted" {
        $registry = New-TestRegistry
        foreach ($agent in "a-gamma", "a-delta") {
            $fake = New-FakeTransport -Steps @((New-Ok))
            $result = Invoke-Engine -Exec (Get-TestExecution $registry $agent) -Registry $registry -Fake $fake
            Assert-True "$agent has no think member" ($null -eq $fake.Calls[0].Body.PSObject.Properties["think"])
            Assert-True "$agent raw body has no think text" ($fake.Calls[0].BodyText.IndexOf("think", [System.StringComparison]::Ordinal) -lt 0)
            Assert-Equal "$agent thinkSent" "omitted" $result.meta.thinkSent
        }
        $v1 = ConvertTo-HarnessRegistry -Config (('{"ollamaUrl":"http://127.0.0.1:9","defaultModel":"m-v1","timeoutSec":123}') | ConvertFrom-Json)
        $execution = Resolve-HarnessExecution -Agent "spec" -Registry $v1
        $fake = New-FakeTransport -Steps @((New-Ok))
        $result = Invoke-Engine -Exec $execution -Registry $v1 -Fake $fake
        Assert-Equal "v1 status" "ok" $result.status
        Assert-True "v1 has no think member" ($null -eq $fake.Calls[0].Body.PSObject.Properties["think"])
        Assert-Equal "v1 thinkSent" "omitted" $result.meta.thinkSent
        Assert-Equal "v1 timeout from defaults" 123 $fake.Calls[0].TimeoutSec
    }

    Test-Case "AC-210 a model from -Model that matches no profile borrows parameters but sends no think; one that matches a profile does" {
        $registry = New-TestRegistry
        $unmatched = Resolve-HarnessExecution -Agent "a-alpha" -Registry $registry -Model "some-other-model"
        Assert-Equal "borrowed profile name is empty" "" $unmatched.profile
        Assert-Equal "the record still carries think true" $true $unmatched.think
        $fake = New-FakeTransport -Steps @((New-Ok))
        $result = Invoke-Engine -Exec $unmatched -Registry $registry -Fake $fake
        Assert-True "no think member" ($null -eq $fake.Calls[0].Body.PSObject.Properties["think"])
        Assert-Equal "thinkSent" "omitted" $result.meta.thinkSent
        Assert-Equal "model is the override" "some-other-model" $fake.Calls[0].Body.model

        $matched = Resolve-HarnessExecution -Agent "a-gamma" -Registry $registry -Model "m-alpha"
        Assert-Equal "matched profile" "alpha" $matched.profile
        $fake2 = New-FakeTransport -Steps @((New-Ok))
        $result2 = Invoke-Engine -Exec $matched -Registry $registry -Fake $fake2
        Assert-Equal "matched: think member" $true $fake2.Calls[0].Body.think
        Assert-Equal "matched: thinkSent" "true" $result2.meta.thinkSent
    }

    Test-Case "AC-210 only a real boolean is sent: the strings 'true' and 'false', 1 and 0 are omitted" {
        $registry = New-TestRegistry
        $base = Get-TestExecution $registry "a-alpha"
        foreach ($value in @("true", "false", 1, 0, "default", $null)) {
            $execution = $base.PSObject.Copy()
            $execution.think = $value
            $fake = New-FakeTransport -Steps @((New-Ok))
            $result = Invoke-Engine -Exec $execution -Registry $registry -Fake $fake
            Assert-True "value '$value' is omitted" ($null -eq $fake.Calls[0].Body.PSObject.Properties["think"])
            Assert-Equal "value '$value' thinkSent" "omitted" $result.meta.thinkSent
        }
    }

    Test-Case "AC-210 an http_4xx answer to a think request is returned as is: one call, no second request without think" {
        $registry = New-TestRegistry -MaxAttempts 3 -Backoff 0
        $fake = New-FakeTransport -Steps @((New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus 400 -Body '{"error":"model does not support thinking"}'), (New-Ok))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry "a-alpha") -Registry $registry -Fake $fake
        Assert-Equal "status" "error" $result.status
        Assert-Equal "category" "http_4xx" $result.error.category
        Assert-Equal "detail" "model does not support thinking" $result.error.detail
        Assert-Equal "calls" 1 $fake.Count()
        Assert-Equal "thinkSent stays true" "true" $result.meta.thinkSent
    }

    Test-Case "AC-210 the record of Resolve-HarnessExecution is unchanged (Phase 1 record part of AC-109)" {
        $registry = New-TestRegistry
        $execution = Get-TestExecution $registry "a-alpha"
        Assert-Equal "members" "agent,profile,model,modelSource,parametersFrom,contextWindow,timeoutSec,reservedOutputTokens,options,think,warnings" ((@($execution.PSObject.Properties | ForEach-Object { $_.Name })) -join ",")
        Assert-Equal "think" $true $execution.think
        Assert-Equal "profile" "alpha" $execution.profile
    }

    # -----------------------------------------------------------------------
    # AC-211 response interpretation
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-211 interpretation ===" -ForegroundColor Cyan

    Test-Case "AC-211 '<think>x</think>answer' gives 'answer' when stripThinking is true and the trimmed full text when false" {
        $registry = New-TestRegistry -StripThinking $true
        $fake = New-FakeTransport -Steps @((New-Ok -Text "<think>x</think>answer"))
        Assert-Equal "stripped" "answer" (Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake).text
        $keep = New-TestRegistry -StripThinking $false
        $fake2 = New-FakeTransport -Steps @((New-Ok -Text "  <think>x</think>answer  "))
        $result = Invoke-Engine -Exec (Get-TestExecution $keep) -Registry $keep -Fake $fake2
        Assert-Equal "kept and trimmed" "<think>x</think>answer" $result.text
        Assert-Equal "thinkingChars counts no block when stripThinking is false" 0 $result.meta.thinkingChars
    }

    Test-Case "AC-211 the whitespace after a stripped think block is removed too (the legacy regex), text is trimmed" {
        $registry = New-TestRegistry
        $fake = New-FakeTransport -Steps @((New-Ok -Text "`r`n<think>reasoning</think>`r`n`r`n  answer line 1`nline 2  `r`n"))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake
        Assert-Equal "text" "answer line 1`nline 2" $result.text
    }

    Test-Case "AC-211 a separate thinking field of 123 characters gives thinkingChars 123 and its content is nowhere in the result or the telemetry" {
        $registry = New-TestRegistry
        $thinking = ("SECRETTHOUGHT" * 9) + ("t" * 6)
        Assert-Equal "fixture length" 123 $thinking.Length
        $fake = New-FakeTransport -Steps @((New-Ok -Text "visible" -Thinking $thinking))
        $caseRoot = New-CaseRoot
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -TelemetryRoot $caseRoot
        Assert-Equal "meta.thinkingChars" 123 $result.meta.thinkingChars
        $record = @(Read-Records $caseRoot)[0]
        Assert-Equal "telemetry thinking_chars" 123 $record.thinking_chars
        Assert-True "no content in the result" (($result | ConvertTo-Json -Depth 6).IndexOf("SECRETTHOUGHT", [System.StringComparison]::Ordinal) -lt 0)
        $logText = [System.IO.File]::ReadAllText((Join-Path $caseRoot "logs\model-calls.jsonl"))
        Assert-True "no content in the JSONL" ($logText.IndexOf("SECRETTHOUGHT", [System.StringComparison]::Ordinal) -lt 0)
        $csvText = [System.IO.File]::ReadAllText((Join-Path $caseRoot "logs\model-calls.csv"))
        Assert-True "no content in the CSV" ($csvText.IndexOf("SECRETTHOUGHT", [System.StringComparison]::Ordinal) -lt 0)
    }

    Test-Case "AC-211 removed <think> blocks add the length of their content: 'abc' and 'de' give 5; with a 4-character thinking field, 9" {
        $registry = New-TestRegistry
        $fake = New-FakeTransport -Steps @((New-Ok -Text "<think>abc</think> A <think>de</think>B"))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake
        Assert-Equal "text" "A B" $result.text
        Assert-Equal "thinkingChars" 5 $result.meta.thinkingChars
        $fake2 = New-FakeTransport -Steps @((New-Ok -Text "<think>abc</think> A <think>de</think>B" -Thinking "wxyz"))
        Assert-Equal "thinkingChars with the field" 9 (Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake2).meta.thinkingChars
    }

    Test-Case "AC-211 an empty thinking field and a non-empty response is a success with thinking_chars 0" {
        $registry = New-TestRegistry
        $fake = New-FakeTransport -Steps @((New-Ok -Text "x" -Thinking ""))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "thinkingChars" 0 $result.meta.thinkingChars
    }

    Test-Case "AC-211 empty response with done_reason length is thinking_budget_exhausted; empty with stop is empty_response; whitespace-only counts as empty" {
        $registry = New-TestRegistry
        $cases = @(
            @{ Text = ""; Reason = "length"; Expected = "thinking_budget_exhausted" },
            @{ Text = ""; Reason = "stop"; Expected = "empty_response" },
            @{ Text = " `r`n`t "; Reason = "stop"; Expected = "empty_response" },
            @{ Text = " `r`n`t "; Reason = "length"; Expected = "thinking_budget_exhausted" },
            @{ Text = "<think>only reasoning</think>"; Reason = "length"; Expected = "thinking_budget_exhausted" },
            @{ Text = "<think>only reasoning</think>"; Reason = "stop"; Expected = "empty_response" }
        )
        foreach ($case in $cases) {
            $fake = New-FakeTransport -Steps @((New-Ok -Text $case.Text -DoneReason $case.Reason))
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake
            Assert-Equal "'$($case.Text.Trim())' / $($case.Reason) status" "error" $result.status
            Assert-Equal "'$($case.Text.Trim())' / $($case.Reason) category" $case.Expected $result.error.category
            Assert-Equal "text is empty on error" "" $result.text
            Assert-True "has a hint" ($result.error.hint.Length -gt 0)
            Assert-Equal "doneReason copied" $case.Reason $result.meta.doneReason
        }
    }

    Test-Case "AC-211 non-empty text with done_reason length is ok plus the warning output_truncated" {
        $registry = New-TestRegistry
        $fake = New-FakeTransport -Steps @((New-Ok -Text "partial" -DoneReason "length"))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "text" "partial" $result.text
        Assert-Equal "warnings" "output_truncated" ($result.meta.warnings -join ",")
        $stop = New-FakeTransport -Steps @((New-Ok -Text "complete" -DoneReason "stop"))
        Assert-Equal "no warning with stop" 0 (Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $stop).meta.warnings.Count
    }

    Test-Case "AC-211 -ResponseCheck returning a code is format_invalid with that code as detail and the text kept; a null or blank result is ok; it never sees an empty text" {
        $registry = New-TestRegistry
        $fake = New-FakeTransport -Steps @((New-Ok -Text "  no status section  "))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -Check { param($t) "missing_status" }
        Assert-Equal "status" "error" $result.status
        Assert-Equal "category" "format_invalid" $result.error.category
        Assert-Equal "detail" "missing_status" $result.error.detail
        Assert-Equal "text kept (trimmed)" "no status section" $result.text
        Assert-Equal "retryable" $false $result.error.retryable

        foreach ($acceptable in @({ param($t) $null }, { param($t) "" }, { param($t) "  " }, { param($t) })) {
            $ok = New-FakeTransport -Steps @((New-Ok -Text "fine"))
            Assert-Equal "an acceptable check" "ok" (Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $ok -Check $acceptable).status
        }

        $script:checkCalls = 0
        $counting = { param($t) $script:checkCalls++; "x" }
        $empty = New-FakeTransport -Steps @((New-Ok -Text ""), (New-Ok -Text "  "), (New-Ok -Text "" -DoneReason "length"))
        foreach ($i in 1..3) {
            $r = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $empty -Check $counting
            Assert-True "empty text is not format_invalid ($i)" ($r.error.category -cne "format_invalid")
        }
        Assert-Equal "the check ran on no empty text" 0 $script:checkCalls

        $received = New-Object 'System.Collections.Generic.List[string]'
        $recording = { param($t) $received.Add($t); $null }.GetNewClosure()
        $one = New-FakeTransport -Steps @((New-Ok -Text "<think>r</think> body"))
        Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $one -Check $recording | Out-Null
        Assert-Equal "the check receives the interpreted text" "body" ($received -join "|")
    }

    Test-Case "AC-211 a -ResponseCheck that throws is format_invalid (response_check_error) and one telemetry line is written" {
        $registry = New-TestRegistry
        $fake = New-FakeTransport -Steps @((New-Ok -Text "text"))
        $caseRoot = New-CaseRoot
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -TelemetryRoot $caseRoot -Check { param($t) throw "check bug" }
        Assert-Equal "category" "format_invalid" $result.error.category
        Assert-Equal "detail" "response_check_error" $result.error.detail
        Assert-Equal "lines" 1 (@(Read-Records $caseRoot)).Count
    }

    Test-Case "AC-211 (M-2, F-25) a -ResponseCheck fails closed: break, continue, throw and any non-blank output (not only the first) give format_invalid with one record; blank outputs are accepted" {
        $registry = New-TestRegistry
        $rejecting = @(
            @{ Name = "break"; Check = { param($t) break }; Detail = "response_check_error" },
            @{ Name = "continue"; Check = { param($t) continue }; Detail = "response_check_error" },
            @{ Name = "throw"; Check = { param($t) throw "check bug" }; Detail = "response_check_error" },
            @{ Name = "output then break"; Check = { param($t) "x"; break }; Detail = "response_check_error" },
            @{ Name = "null then a code"; Check = { param($t) $null; "code_b" }; Detail = "code_b" },
            @{ Name = "blank then a code"; Check = { param($t) ""; "  "; "code_c" }; Detail = "code_c" },
            @{ Name = "false"; Check = { param($t) $false }; Detail = "False" }
        )
        $checksDone = 0
        foreach ($case in $rejecting) {
            $fake = New-FakeTransport -Steps @((New-Ok -Text "text"))
            $caseRoot = New-CaseRoot
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -TelemetryRoot $caseRoot -Check $case.Check
            Assert-Equal "$($case.Name) status" "error" $result.status
            Assert-Equal "$($case.Name) category" "format_invalid" $result.error.category
            Assert-Equal "$($case.Name) detail" $case.Detail $result.error.detail
            Assert-Equal "$($case.Name) text kept" "text" $result.text
            $records = @(Read-Records $caseRoot)
            Assert-Equal "$($case.Name) lines" 1 $records.Count
            Assert-Equal "$($case.Name) record category" "format_invalid" $records[0].error_category
            $checksDone++
        }
        Assert-Equal "every check ran to the end of the loop body (a leaked break or continue would end the loop early)" $rejecting.Count $checksDone
        foreach ($accepting in @({ param($t) $null; $null }, { param($t) ""; " " }, { param($t) $null; "" })) {
            $fake = New-FakeTransport -Steps @((New-Ok -Text "text"))
            Assert-Equal "blank outputs are accepted" "ok" (Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -Check $accepting).status
        }
    }

    Test-Case "AC-211 a body without a response member is empty_response (the error member becomes the detail); null and string responses too" {
        $registry = New-TestRegistry
        $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response ([pscustomobject]@{ error = "model is loading" })))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake
        Assert-Equal "category" "empty_response" $result.error.category
        Assert-Equal "detail" "model is loading" $result.error.detail
        foreach ($response in @($null, "plain string", ([pscustomobject]@{ done = $true }))) {
            $other = New-FakeTransport -Steps @((New-FakeOkRecord -Response $response))
            Assert-Equal "response '$response'" "empty_response" (Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $other).error.category
        }
    }

    Test-Case "AC-211 prompt_eval_count at or above C - R (9000 for window 10000, reserved 1000) records possible_prompt_truncation; below does not" {
        $registry = New-TestRegistry
        foreach ($case in @(@{ Count = 8999; Warn = $false }, @{ Count = 9000; Warn = $true }, @{ Count = 9001; Warn = $true }, @{ Count = 0; Warn = $false })) {
            $fake = New-FakeTransport -Steps @((New-Ok -PromptEvalCount $case.Count))
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake
            Assert-Equal "count $($case.Count)" $case.Warn ($result.meta.warnings -ccontains "possible_prompt_truncation")
        }
        $delta = New-FakeTransport -Steps @((New-Ok -PromptEvalCount 99999999))
        Assert-Equal "a profile without a window never warns" 0 (Invoke-Engine -Exec (Get-TestExecution $registry "a-delta") -Registry $registry -Fake $delta).meta.warnings.Count
    }

    Test-Case "AC-211 (M-1) a prompt_eval_count that is a string, an object, a boolean or a huge number never throws: ok, one record, and a warning only for a real number at or above C - R (fake transport and the real default-transport path)" {
        $registry = New-TestRegistry
        $values = @(
            @{ Name = "string n/a"; Value = "n/a"; Warn = $false },
            @{ Name = "numeric string"; Value = "99999"; Warn = $false },
            @{ Name = "object"; Value = ([pscustomobject]@{ a = 1 }); Warn = $false },
            @{ Name = "boolean"; Value = $true; Warn = $false },
            @{ Name = "array"; Value = @(9500, 9600); Warn = $false },
            @{ Name = "huge double 1e300"; Value = 1e300; Warn = $true },
            @{ Name = "huge long"; Value = [long]::MaxValue; Warn = $true },
            @{ Name = "decimal at the limit"; Value = [decimal]9000; Warn = $true },
            @{ Name = "double below the limit"; Value = [double]8999.5; Warn = $false }
        )
        foreach ($case in $values) {
            $response = New-FakeGenerateResponse -Text "fine"
            $response.prompt_eval_count = $case.Value
            $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response $response))
            $caseRoot = New-CaseRoot
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -TelemetryRoot $caseRoot
            Assert-Equal "$($case.Name) status (fake transport)" "ok" $result.status
            Assert-Equal "$($case.Name) warning (fake transport)" $case.Warn ($result.meta.warnings -ccontains "possible_prompt_truncation")
            Assert-Equal "$($case.Name) lines (fake transport)" 1 (@(Read-Records $caseRoot)).Count

            $script:wireValue = $case.Value
            $script:rest.Handler = {
                param($uri)
                $answer = New-FakeGenerateResponse -Text "fine"
                $answer.prompt_eval_count = $script:wireValue
                return $answer
            }
            $script:httpStub = { param($Request) & $realHttp -Request $Request }
            $wireRoot = New-CaseRoot
            $sleeper = New-SleepRecorder
            $wire = Invoke-AgentModel -Execution (Get-TestExecution $registry) -Registry $registry -System "AB" -Prompt "CDE" -Sleep $sleeper.Sleep -TelemetryRoot $wireRoot
            Assert-Equal "$($case.Name) status (default transport)" "ok" $wire.status
            Assert-Equal "$($case.Name) warning (default transport)" $case.Warn ($wire.meta.warnings -ccontains "possible_prompt_truncation")
            Assert-Equal "$($case.Name) lines (default transport)" 1 (@(Read-Records $wireRoot)).Count
            $script:httpStub = $null
            $script:rest.Handler = $null
        }
    }

    Test-Case "AC-211 counts and durations are copied from the response unchanged" {
        $registry = New-TestRegistry
        $response = [pscustomobject]@{
            response = "x"; done = $true; done_reason = "stop"; total_duration = 123456789012; load_duration = 111; prompt_eval_count = 4321
            prompt_eval_duration = 222; eval_count = 98; eval_duration = 333
        }
        $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response $response))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake
        Assert-Equal "evalCount" 98 $result.meta.evalCount
        Assert-Equal "promptEvalCount" 4321 $result.meta.promptEvalCount
        Assert-Equal "totalDurationNs" 123456789012 $result.meta.totalDurationNs
        Assert-Equal "loadDurationNs" 111 $result.meta.loadDurationNs
        Assert-Equal "promptEvalDurationNs" 222 $result.meta.promptEvalDurationNs
        Assert-Equal "evalDurationNs" 333 $result.meta.evalDurationNs
        Assert-Equal "doneReason" "stop" $result.meta.doneReason
        Assert-Equal "meta members" "callId,model,profile,modelSource,attempts,transport,modelCalled,thinkSent,doneReason,evalCount,promptEvalCount,totalDurationNs,loadDurationNs,promptEvalDurationNs,evalDurationNs,thinkingChars,promptChars,estPromptTokens,budget,warmup,warnings,elapsedMs" ((@($result.meta.PSObject.Properties | ForEach-Object { $_.Name })) -join ",")
        Assert-Equal "result members" "status,text,meta,error" ((@($result.PSObject.Properties | ForEach-Object { $_.Name })) -join ",")
        Assert-Equal "error members" "category,httpStatus,detail,hint,retryable,attempts" ((@((Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake (New-FakeTransport -Steps @((New-Fail5xx)))).error.PSObject.Properties | ForEach-Object { $_.Name })) -join ",")
    }

    # Closing round of the Phase 2 final QA (I-4, N-13, I-7): cases added to AC-211
    # and AC-215; no existing assertion was edited.

    Test-Case "AC-211 a <think> block that spans several lines is stripped and its characters are counted (final QA I-4)" {
        $registry = New-TestRegistry
        # 8 + 1 + 8 + 2 + 10 = 29 characters inside the block (LF and CRLF line ends)
        $reasoning = "line one`nline two`r`nline three"
        $fake = New-FakeTransport -Steps @((New-Ok -Text ("<think>" + $reasoning + "</think>`n`nanswer`nsecond line")))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "text" "answer`nsecond line" $result.text
        Assert-Equal "thinkingChars" 29 $result.meta.thinkingChars
        $keep = New-TestRegistry -StripThinking $false
        $fake2 = New-FakeTransport -Steps @((New-Ok -Text ("<think>" + $reasoning + "</think>`nanswer")))
        $kept = Invoke-Engine -Exec (Get-TestExecution $keep) -Registry $keep -Fake $fake2
        Assert-Equal "kept when stripThinking is false" ("<think>" + $reasoning + "</think>`nanswer") $kept.text
        $both = New-FakeTransport -Steps @((New-Ok -Text ("<think>a`nb</think>`nfirst`n<think>`n`nc`n</think>`nsecond")))
        $twice = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $both
        Assert-Equal "two multi-line blocks: text" "first`nsecond" $twice.text
        Assert-Equal "two multi-line blocks: thinkingChars (3 + 4)" 7 $twice.meta.thinkingChars
    }

    Test-Case "AC-211 the counts and durations reach the record of an empty_response and of a format_invalid (final QA N-13)" {
        $registry = New-TestRegistry
        $emptyAnswer = [pscustomobject]@{
            response = ""; done = $true; done_reason = "stop"; total_duration = 7654321; load_duration = 111; prompt_eval_count = 4321
            prompt_eval_duration = 222; eval_count = 98; eval_duration = 333
        }
        $cases = @(
            @{ Name = "empty_response"; Text = ""; Check = $null; Category = "empty_response" },
            @{ Name = "format_invalid"; Text = "no status"; Check = { param($t) "status_missing" }; Category = "format_invalid" }
        )
        foreach ($case in $cases) {
            $answer = $emptyAnswer.PSObject.Copy()
            $answer.response = $case.Text
            $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response $answer))
            $caseRoot = New-CaseRoot
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -TelemetryRoot $caseRoot -Check $case.Check
            Assert-Equal "$($case.Name) category" $case.Category $result.error.category
            Assert-Equal "$($case.Name) meta.evalCount" 98 $result.meta.evalCount
            $records = @(Read-Records $caseRoot)
            Assert-Equal "$($case.Name) lines" 1 $records.Count
            $r = $records[0]
            Assert-Equal "$($case.Name) status" "error" $r.status
            Assert-Equal "$($case.Name) error_category" $case.Category $r.error_category
            Assert-Equal "$($case.Name) eval_count" 98 $r.eval_count
            Assert-Equal "$($case.Name) prompt_eval_count" 4321 $r.prompt_eval_count
            Assert-Equal "$($case.Name) total_duration_ns" 7654321 $r.total_duration_ns
            Assert-Equal "$($case.Name) load_duration_ns" 111 $r.load_duration_ns
            Assert-Equal "$($case.Name) prompt_eval_duration_ns" 222 $r.prompt_eval_duration_ns
            Assert-Equal "$($case.Name) eval_duration_ns" 333 $r.eval_duration_ns
            Assert-Equal "$($case.Name) done_reason" "stop" $r.done_reason
        }
    }

    Test-Case "AC-215 a reviewer-sized stub prompt against the frozen Phase 1 baseline file is sent, not refused: warn, budget_exceeded, one request (final QA I-7)" {
        $baselinePath = Join-Path $root "tests\fixtures\config-v2-phase1-baseline.json"
        $registry = Get-HarnessRegistry -ConfigPath $baselinePath
        $reviewer = Resolve-HarnessExecution -Agent "spec-reviewer" -Registry $registry
        Assert-Equal "the baseline has no budgetMode: the default is warn" "warn" $registry.defaults.budgetMode
        # window 16384, reserved 8192, margin ceil(0.1 x 16384) = 1639 -> 6553 available;
        # 26000 characters at 3.5 per token are ceil(7428.57) = 7429 tokens.
        $fake = New-FakeTransport -Steps @((New-Ok -Text "reviewed"))
        $caseRoot = New-CaseRoot
        $result = Invoke-Engine -Exec $reviewer -Registry $registry -Fake $fake -System ("x" * 20000) -Prompt ("y" * 6000) -TelemetryRoot $caseRoot
        Assert-Equal "status (sent, not refused)" "ok" $result.status
        Assert-Equal "generate requests" 1 $fake.Count("generate")
        Assert-Equal "budget status" "exceeded" $result.meta.budget.status
        Assert-Equal "estimated tokens" 7429 $result.meta.budget.estTokens
        Assert-Equal "available tokens" 6553 $result.meta.budget.available
        Assert-Equal "warnings" "budget_exceeded" ($result.meta.warnings -join ",")
        Assert-Equal "model_called" $true $result.meta.modelCalled
        $record = @(Read-Records $caseRoot)[0]
        Assert-Equal "record status" "success" $record.status
        Assert-Equal "record warnings" "budget_exceeded" $record.warnings
        Assert-Equal "record model_called" $true $record.model_called
    }

    # -----------------------------------------------------------------------
    # AC-212 request body whitelist (FR-207, FR-206)
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-212 whitelist ===" -ForegroundColor Cyan

    Test-Case "AC-212 every generate body has only model, system, prompt, stream, options (when not empty) and think (when explicit); stream is JSON false" {
        $registry = New-TestRegistry
        $expected = @{
            "a-alpha" = "model,options,prompt,stream,system,think"
            "a-beta"  = "model,options,prompt,stream,system,think"
            "a-gamma" = "model,options,prompt,stream,system"
            "a-delta" = "model,prompt,stream,system"
        }
        foreach ($agent in $expected.Keys) {
            $fake = New-FakeTransport -Steps @((New-Ok))
            Invoke-Engine -Exec (Get-TestExecution $registry $agent) -Registry $registry -Fake $fake -System "SYS" -Prompt "PRM" | Out-Null
            Assert-Equal "$agent members" $expected[$agent] (Get-BodyMembers $fake.Calls[0])
            Assert-Equal "$agent stream" $false $fake.Calls[0].Body.stream
            Assert-True "$agent stream is a JSON boolean, not the text False (M-5)" ($fake.Calls[0].Body.stream -is [bool])
            Assert-True "$agent raw body has stream:false" ($fake.Calls[0].BodyText -match '"stream"\s*:\s*false')
            Assert-Equal "$agent system" "SYS" $fake.Calls[0].Body.system
            Assert-Equal "$agent prompt" "PRM" $fake.Calls[0].Body.prompt
            Assert-Equal "$agent purpose" "generate" $fake.Calls[0].Purpose
        }
    }

    Test-Case "AC-212 options.num_predict set in a profile reaches the body unchanged; num_ctx comes from the window" {
        $registry = New-TestRegistry
        $fake = New-FakeTransport -Steps @((New-Ok))
        Invoke-Engine -Exec (Get-TestExecution $registry "a-alpha") -Registry $registry -Fake $fake | Out-Null
        Assert-Equal "num_predict" 77 $fake.Calls[0].Body.options.num_predict
        Assert-Equal "temperature" 0.2 $fake.Calls[0].Body.options.temperature
        Assert-Equal "num_ctx" 10000 $fake.Calls[0].Body.options.num_ctx
        Assert-Equal "option names" "num_ctx,num_predict,temperature" ((@($fake.Calls[0].Body.options.PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object) -join ",")
    }

    Test-Case "AC-212 no request ever has tools, functions, format, images, keep_alive, template or raw, whatever the options hold (generate, warm-up)" {
        $registry = New-TestRegistry -Warmup $true
        $hostile = Get-TestExecution $registry "a-alpha"
        $hostile.options = [pscustomobject]@{ temperature = 0.2; note = "tools functions format keep_alive" }
        $forbidden = @("tools", "functions", "format", "images", "keep_alive", "template", "raw")
        foreach ($agent in "a-alpha", "a-beta", "a-gamma", "a-delta") {
            Reset-AgentExecState
            $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response ([pscustomobject]@{ done = $true })), (New-Ok))
            Invoke-Engine -Exec (Get-TestExecution $registry $agent) -Registry $registry -Fake $fake | Out-Null
            foreach ($call in $fake.Calls) {
                foreach ($member in $forbidden) {
                    Assert-True "$agent $($call.Purpose) has no top-level '$member'" ($null -eq $call.Body.PSObject.Properties[$member])
                }
            }
        }
        $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response ([pscustomobject]@{ done = $true })), (New-Ok))
        Invoke-Engine -Exec $hostile -Registry $registry -Fake $fake | Out-Null
        foreach ($call in $fake.Calls) {
            Assert-True "hostile options: top-level members are within the whitelist" ((Get-BodyMembers $call) -cmatch '^(model|options|prompt|stream|system|think)(,(model|options|prompt|stream|system|think))*$')
        }
    }

    Test-Case "AC-212 the body is UTF-8 without a byte order mark; multi-byte and awkward text survives" {
        $registry = New-TestRegistry
        $system = "caf" + [char]0x00E9 + " " + [char]0x4E2D + [char]::ConvertFromUtf32(0x1F600) + " {0} `$env:USERNAME `$(Get-Date) `` @`" `"@ <b> & '"
        $prompt = "line1`r`nline2`nline3"
        $fake = New-FakeTransport -Steps @((New-Ok))
        Invoke-Engine -Exec (Get-TestExecution $registry "a-delta") -Registry $registry -Fake $fake -System $system -Prompt $prompt | Out-Null
        $bytes = $null
        $capture = New-FakeTransport -Steps @({ param($r) $script:capturedBytes = $r.Body; New-Ok })
        Invoke-Engine -Exec (Get-TestExecution $registry "a-delta") -Registry $registry -Fake $capture -System $system -Prompt $prompt | Out-Null
        $bytes = $script:capturedBytes
        Assert-True "bytes were captured" ($bytes -is [byte[]])
        Assert-True "no BOM" (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF))
        Assert-Equal "system round trip" $system $fake.Calls[0].Body.system
        Assert-Equal "prompt round trip (CRLF and LF kept)" $prompt $fake.Calls[0].Body.prompt
    }

    Test-Case "AC-212 static: the payload is built from exactly model, system, prompt, stream, options and think; no tools, functions, keep_alive or format anywhere in the library" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($engineLibrary, [ref]$tokens, [ref]$errors)
        Assert-Equal "parse errors" 0 $errors.Count
        $function = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq "Invoke-AgentModel" }, $true)[0]
        $assigned = @($function.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Left.Expression.Extent.Text -in @('$payload', '$warmPayload') }, $true) |
                ForEach-Object { "$($_.Left.Expression.Extent.Text).$($_.Left.Member.Extent.Text)" } | Sort-Object)
        Assert-Equal "members assigned after the initial hashtables" '$payload.options,$payload.think,$warmPayload.options,$warmPayload.stream' ($assigned -join ",")
        $initial = @($function.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in @('$payload', '$warmPayload') }, $true))
        Assert-Equal "initial hashtables" 2 $initial.Count
        $keys = @()
        foreach ($assignment in $initial) {
            foreach ($hashtable in $assignment.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
                foreach ($pair in $hashtable.KeyValuePairs) { $keys += "$($assignment.Left.Extent.Text).$($pair.Item1.Extent.Text)" }
            }
        }
        $expectedKeys = @('$payload.model', '$payload.system', '$payload.prompt', '$payload.stream', '$warmPayload.model') | Sort-Object
        Assert-Equal "initial members" ($expectedKeys -join ",") ((@($keys) | Sort-Object) -join ",")
    }

    Test-Case "AC-212 static: no tools, functions, keep_alive or format as a string, bareword, key or member anywhere in agent-exec.ps1; and none of images, template, raw either inside Invoke-AgentModel (the prompt builders use 'template' as a part name)" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($engineLibrary, [ref]$tokens, [ref]$errors)
        $scopes = @(
            @{ Where = "library"; Node = $ast; Names = @("tools", "functions", "keep_alive", "format") },
            @{ Where = "Invoke-AgentModel"; Node = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq "Invoke-AgentModel" }, $true)[0]; Names = @("tools", "functions", "keep_alive", "format", "images", "template", "raw") }
        )
        foreach ($scope in $scopes) {
            $hits = @()
            foreach ($node in $scope.Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
                if ($scope.Names -contains $node.Value.ToLowerInvariant()) { $hits += $node.Value }
            }
            foreach ($node in $scope.Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)) {
                if ($scope.Names -contains $node.Member.Extent.Text.ToLowerInvariant()) { $hits += $node.Member.Extent.Text }
            }
            Assert-Equal "forbidden request member names in $($scope.Where)" "" ($hits -join ",")
        }
    }

    # -----------------------------------------------------------------------
    # AC-213 transport contract, no throw
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-213 transport contract ===" -ForegroundColor Cyan

    Test-Case "AC-213 failure records give status error and a category, never an exception (every shape of FR-204)" {
        $registry = New-TestRegistry -MaxAttempts 1
        $cases = @(
            @{ Step = (New-FakeFailureRecord -WebStatus "Timeout"); Expected = "timeout" },
            @{ Step = (New-FakeFailureRecord -WebStatus "ConnectFailure"); Expected = "transport_unreachable" },
            @{ Step = (New-FakeFailureRecord -WebStatus "ConnectionClosed"); Expected = "transport_reset" },
            @{ Step = (New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus 503); Expected = "http_5xx" },
            @{ Step = (New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus 404); Expected = "http_4xx" },
            @{ Step = (New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus 302); Expected = "transport_other" },
            @{ Step = (New-FakeFailureRecord -ExceptionType "Contoso.Unknown"); Expected = "transport_other" },
            @{ Step = [pscustomobject]@{ ok = $false; response = $null; httpStatus = $null; failure = $null }; Expected = "transport_other" }
        )
        foreach ($case in $cases) {
            $fake = New-FakeTransport -Steps @($case.Step)
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake
            Assert-Equal "status for $($case.Expected)" "error" $result.status
            Assert-Equal "category" $case.Expected $result.error.category
            Assert-True "hint" ($result.error.hint.Length -gt 0)
        }
    }

    Test-Case "AC-213 a transport that throws (plain, WebException, TimeoutException, IOException) is a failure with the exception's type name and no webStatus" {
        $registry = New-TestRegistry -MaxAttempts 1
        $cases = @(
            @{ Exception = (New-Object System.InvalidOperationException "boom"); Expected = "transport_other" },
            @{ Exception = (New-FakeHttpWebException -StatusCode 503 -Body '{"error":"x"}'); Expected = "transport_other" },
            @{ Exception = (New-FakeStatusWebException -Status Timeout); Expected = "transport_other" },
            @{ Exception = (New-Object System.TimeoutException "t"); Expected = "timeout" },
            @{ Exception = (New-Object System.IO.IOException "io"); Expected = "transport_reset" },
            @{ Exception = (New-Object System.Net.Sockets.SocketException); Expected = "transport_reset" }
        )
        foreach ($case in $cases) {
            $fake = New-FakeTransport -Steps @($case.Exception)
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake
            $type = $case.Exception.GetType().FullName
            Assert-Equal "$type status" "error" $result.status
            Assert-Equal "$type category" $case.Expected $result.error.category
            Assert-True "$type detail names the type" ($result.error.detail.Contains($type))
        }
    }

    Test-Case "AC-213 a thrown retryable type is retried like a returned failure (IOException twice then ok)" {
        $registry = New-TestRegistry -MaxAttempts 3 -Backoff 5
        $fake = New-FakeTransport -Steps @((New-Object System.IO.IOException "io"), (New-Object System.IO.IOException "io"), (New-Ok -Text "done"))
        $sleeper = New-SleepRecorder
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -Sleeper $sleeper
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "attempts" 3 $result.meta.attempts
        Assert-Equal "sleeps" "5,10" ($sleeper.List -join ",")
    }

    Test-Case "AC-213 a transport that returns nothing, a non-record, or a transport that ran out of steps is a failure, not an exception" {
        $registry = New-TestRegistry -MaxAttempts 1
        foreach ($step in @({ param($r) $null }, { param($r) "not a record" }, { param($r) [pscustomobject]@{ note = "no ok member" } })) {
            $fake = New-FakeTransport -Steps @($step)
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake
            Assert-Equal "status" "error" $result.status
            Assert-Equal "category" "transport_other" $result.error.category
            Assert-True "detail names the shape" ($result.error.detail.Contains("invalid_transport_result"))
        }
        $none = New-FakeTransport -Steps @()
        Assert-Equal "no steps" "transport_other" (Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $none).error.category
    }

    Test-Case "AC-213 a transport may be a function name; the last record wins when it also writes to the output stream" {
        $registry = New-TestRegistry
        function Invoke-NamedFakeTransport { param([hashtable]$Request) "noise"; return (New-Ok -Text "from a function") }
        $result = Invoke-AgentModel -Execution (Get-TestExecution $registry) -Registry $registry -System "A" -Prompt "B" -Transport "Invoke-NamedFakeTransport"
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "text" "from a function" $result.text
    }

    Test-Case "AC-213 programmer errors throw: a null or malformed Execution or Registry, a blank model, a TelemetryRoot without the writer's agent" {
        $registry = New-TestRegistry
        $execution = Get-TestExecution $registry
        $fake = New-FakeTransport -Steps @((New-Ok)) -RepeatLast
        Assert-Throws "null Execution" { Invoke-AgentModel -Execution $null -Registry $registry -System "A" -Prompt "B" -Transport $fake.Transport }
        Assert-Throws "null Registry" { Invoke-AgentModel -Execution $execution -Registry $null -System "A" -Prompt "B" -Transport $fake.Transport }
        Assert-Throws "Execution without members" { Invoke-AgentModel -Execution ([pscustomobject]@{ model = "m" }) -Registry $registry -System "A" -Prompt "B" -Transport $fake.Transport } "invalid_arguments:"
        Assert-Throws "Registry without members" { Invoke-AgentModel -Execution $execution -Registry ([pscustomobject]@{ ollama = $null }) -System "A" -Prompt "B" -Transport $fake.Transport } "invalid_arguments:"
        $blank = $execution.PSObject.Copy(); $blank.model = " "
        Assert-Throws "blank model" { Invoke-AgentModel -Execution $blank -Registry $registry -System "A" -Prompt "B" -Transport $fake.Transport } "invalid_arguments:"
        $anonymous = $execution.PSObject.Copy(); $anonymous.agent = ""
        Assert-Throws "TelemetryRoot without an agent" { Invoke-AgentModel -Execution $anonymous -Registry $registry -System "A" -Prompt "B" -Transport $fake.Transport -TelemetryRoot (New-CaseRoot) } "invalid_arguments:"
        Assert-Equal "none of them reached the transport" 0 $fake.Count()
    }

    Test-Case "AC-213 the default transport is Invoke-OllamaHttp, reached by name with the profile's timeoutSec for generate and healthTimeoutSec for tags" {
        $registry = New-TestRegistry -Warmup $true
        $seen = New-Object 'System.Collections.Generic.List[object]'
        $script:httpStub = {
            param($Request)
            $seen.Add([pscustomobject]@{ Purpose = $Request.Purpose; Url = $Request.Url; Method = $Request.Method; TimeoutSec = $Request.TimeoutSec; HasBody = ($Request.Body -is [byte[]]) })
            if ($Request.Purpose -ceq "tags") { return (New-FakeOkRecord -Response (New-FakeTagsResponse -Models @("m-alpha"))) }
            if ($Request.Purpose -ceq "warmup") { return (New-FakeOkRecord -Response ([pscustomobject]@{ done = $true })) }
            return (New-Ok)
        }.GetNewClosure()
        $execution = Get-TestExecution $registry
        $available = Test-OllamaModel -Execution $execution -Registry $registry
        Assert-Equal "available" $true $available.available
        $result = Invoke-AgentModel -Execution $execution -Registry $registry -System "A" -Prompt "B"
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "requests" "tags|Get|7|False;warmup|Post|44|True;generate|Post|44|True" (($seen | ForEach-Object { "$($_.Purpose)|$($_.Method)|$($_.TimeoutSec)|$($_.HasBody)" }) -join ";")
        Assert-Equal "urls" "http://127.0.0.1:9/api/tags,http://127.0.0.1:9/api/generate,http://127.0.0.1:9/api/generate" (($seen | ForEach-Object { $_.Url }) -join ",")
        Assert-Equal "the guard stub was not violated" 0 $script:httpViolations
    }

    # --- the real transport against a function named Invoke-RestMethod -------------

    Test-Case "AC-213 Invoke-OllamaHttp generate: exactly -Uri -Method -ContentType -Body -TimeoutSec, bytes unchanged, an ok record with httpStatus 200 and the parsed response" {
        $answer = [pscustomobject]@{ response = "hi" }
        $script:rest.Handler = { param($uri) $answer }.GetNewClosure()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"model":"m"}')
        $record = & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/generate"; Method = "Post"; Body = $bytes; TimeoutSec = 44; Purpose = "generate" }
        Assert-Equal "calls" 1 $script:rest.Calls.Count
        $call = $script:rest.Calls[0]
        Assert-Equal "bound parameters" "Body,ContentType,Method,TimeoutSec,Uri" $call.Bound
        Assert-Equal "uri" "http://127.0.0.1:9/api/generate" $call.Uri
        Assert-Equal "method" "Post" $call.Method
        Assert-Equal "timeout" 44 $call.TimeoutSec
        Assert-Equal "content type" "application/json; charset=utf-8" $call.ContentType
        Assert-True "the same bytes" ([object]::ReferenceEquals($call.Body, $bytes))
        Assert-Equal "ok" $true $record.ok
        Assert-True "httpStatus is not measured on success (null, D2 / M-4)" ($null -eq $record.httpStatus)
        Assert-True "response is the parsed object" ([object]::ReferenceEquals($record.response, $answer))
        Assert-True "failure is null" ($null -eq $record.failure)
        Assert-Equal "record members" "ok,response,httpStatus,failure" ((@($record.PSObject.Properties | ForEach-Object { $_.Name })) -join ",")
    }

    Test-Case "AC-213 (D2 / M-4) a success through the real transport path writes an empty http_status; a non-integer injected httpStatus never throws (F-21)" {
        $registry = New-TestRegistry
        $script:rest.Handler = { param($uri) New-FakeGenerateResponse -Text "wire" }
        $script:httpStub = { param($Request) & $realHttp -Request $Request }
        $caseRoot = New-CaseRoot
        $result = Invoke-AgentModel -Execution (Get-TestExecution $registry) -Registry $registry -System "A" -Prompt "B" -TelemetryRoot $caseRoot
        Assert-Equal "status" "ok" $result.status
        $record = @(Read-Records $caseRoot)[0]
        Assert-Equal "success http_status is empty" "" $record.http_status
        Assert-True "http_status is an empty string, not 200" ($record.http_status -is [string])
        $csv = @(Import-Csv -LiteralPath (Join-Path $caseRoot "logs\model-calls.csv"))
        Assert-Equal "csv http_status" "" $csv[0].http_status
        $script:httpStub = $null
        $script:rest.Handler = $null

        foreach ($odd in @("n/a", "abc", 12.5, ([pscustomobject]@{ x = 1 }), "")) {
            $okRecord = New-FakeOkRecord -Response (New-FakeGenerateResponse -Text "odd") -HttpStatus $odd
            $fake = New-FakeTransport -Steps @($okRecord)
            $caseRoot = New-CaseRoot
            $ok = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -TelemetryRoot $caseRoot
            Assert-Equal "ok with httpStatus '$odd' status" "ok" $ok.status
            Assert-Equal "ok with httpStatus '$odd' lines" 1 (@(Read-Records $caseRoot)).Count
            Assert-Equal "ok with httpStatus '$odd' http_status" "" (@(Read-Records $caseRoot))[0].http_status

            $failRecord = New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus $odd
            $fake2 = New-FakeTransport -Steps @($failRecord)
            $caseRoot2 = New-CaseRoot
            $failed = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake2 -TelemetryRoot $caseRoot2
            Assert-Equal "failure with httpStatus '$odd' status" "error" $failed.status
            Assert-Equal "failure with httpStatus '$odd' lines" 1 (@(Read-Records $caseRoot2)).Count
            Assert-Equal "failure with httpStatus '$odd' http_status" "" (@(Read-Records $caseRoot2))[0].http_status

            Reset-AgentExecState
            $tagsFake = New-FakeTransport -Steps @((New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus $odd))
            $caseRoot3 = New-CaseRoot
            $tags = Test-OllamaModel -Execution (Get-TestExecution $registry) -Registry $registry -Transport $tagsFake.Transport -TelemetryRoot $caseRoot3
            Assert-Equal "tags with httpStatus '$odd' available" $false $tags.available
            Assert-Equal "tags with httpStatus '$odd' lines" 1 (@(Read-Records $caseRoot3)).Count
        }
        # an integer status is still written
        $fake3 = New-FakeTransport -Steps @((New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus 503))
        $caseRoot4 = New-CaseRoot
        $single = New-TestRegistry -MaxAttempts 1
        Invoke-Engine -Exec (Get-TestExecution $single) -Registry $single -Fake $fake3 -TelemetryRoot $caseRoot4 | Out-Null
        Assert-Equal "integer status written" 503 (@(Read-Records $caseRoot4))[0].http_status
    }

    Test-Case "AC-213 Invoke-OllamaHttp warmup uses the same call shape; tags uses only -Uri -Method -TimeoutSec" {
        $script:rest.Handler = { param($uri) [pscustomobject]@{ models = @() } }
        & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/generate"; Method = "Post"; Body = [byte[]](1, 2); TimeoutSec = 30; Purpose = "warmup" } | Out-Null
        & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/tags"; Method = "Get"; Body = $null; TimeoutSec = 7; Purpose = "tags" } | Out-Null
        Assert-Equal "warmup bound" "Body,ContentType,Method,TimeoutSec,Uri" $script:rest.Calls[0].Bound
        Assert-Equal "tags bound" "Method,TimeoutSec,Uri" $script:rest.Calls[1].Bound
        Assert-Equal "tags method" "Get" $script:rest.Calls[1].Method
        Assert-Equal "tags timeout" 7 $script:rest.Calls[1].TimeoutSec
        Assert-True "tags has no body" ($null -eq $script:rest.Calls[1].Body)
    }

    Test-Case "AC-213 Invoke-OllamaHttp maps a WebException with a response: type, ProtocolError, StatusCode and the body read from the stream (ErrorDetails is null)" {
        $script:rest.Handler = { param($uri) throw (New-FakeHttpWebException -StatusCode 503 -Body '{"error":"gpu init failed"}' -Message "SENTINEL-MESSAGE-A") }
        $record = & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/generate"; Method = "Post"; Body = [byte[]](1); TimeoutSec = 9; Purpose = "generate" }
        Assert-Equal "ok" $false $record.ok
        Assert-Equal "httpStatus" 503 $record.httpStatus
        Assert-Equal "exceptionType" "System.Net.WebException" $record.failure.exceptionType
        Assert-Equal "webStatus" "ProtocolError" $record.failure.webStatus
        Assert-Equal "body" '{"error":"gpu init failed"}' $record.failure.body
        Assert-True "response is null" ($null -eq $record.response)
        Assert-Equal "failure members" "exceptionType,webStatus,body" ((@($record.failure.PSObject.Properties | ForEach-Object { $_.Name })) -join ",")
        Assert-True "the exception message is nowhere in the record" (($record | ConvertTo-Json -Depth 5).IndexOf("SENTINEL-MESSAGE-A", [System.StringComparison]::Ordinal) -lt 0)
        $classified = Get-AgentErrorCategory -Failure $record.failure -HttpStatus $record.httpStatus
        Assert-Equal "classified" "http_5xx" $classified.category
        Assert-Equal "detail" "gpu init failed" $classified.detail
    }

    Test-Case "AC-213 Invoke-OllamaHttp reads the body from ErrorDetails first (the Windows PowerShell 5.1 place) and falls back to the stream when it is empty" {
        $script:rest.Handler = {
            param($uri)
            $exception = New-FakeHttpWebException -StatusCode 400 -Body "BODY-FROM-STREAM" -Message "SENTINEL-MESSAGE-B"
            $errorRecord = New-Object System.Management.Automation.ErrorRecord -ArgumentList $exception, "HarnessFake", ([System.Management.Automation.ErrorCategory]::InvalidOperation), $null
            $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails -ArgumentList "BODY-FROM-DETAILS"
            throw $errorRecord
        }
        $record = & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/generate"; Method = "Post"; Body = [byte[]](1); TimeoutSec = 9; Purpose = "generate" }
        Assert-Equal "httpStatus" 400 $record.httpStatus
        Assert-Equal "body from ErrorDetails" "BODY-FROM-DETAILS" $record.failure.body
        Assert-True "message not in the record" (($record | ConvertTo-Json -Depth 5).IndexOf("SENTINEL-MESSAGE-B", [System.StringComparison]::Ordinal) -lt 0)

        $script:rest.Handler = {
            param($uri)
            $exception = New-FakeHttpWebException -StatusCode 400 -Body "BODY-FROM-STREAM"
            $errorRecord = New-Object System.Management.Automation.ErrorRecord -ArgumentList $exception, "HarnessFake", ([System.Management.Automation.ErrorCategory]::InvalidOperation), $null
            $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails -ArgumentList ""
            throw $errorRecord
        }
        $fallback = & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/generate"; Method = "Post"; Body = [byte[]](1); TimeoutSec = 9; Purpose = "generate" }
        Assert-Equal "body from the stream when ErrorDetails is empty" "BODY-FROM-STREAM" $fallback.failure.body
    }

    Test-Case "AC-213 Invoke-OllamaHttp maps a status-only WebException (Timeout, ConnectFailure): webStatus set, no HTTP status, no body" {
        foreach ($member in "Timeout", "ConnectFailure", "ConnectionClosed") {
            $script:rest.Handler = { param($uri) throw (New-FakeStatusWebException -Status ([System.Net.WebExceptionStatus]$member) -Message "SENTINEL-MESSAGE-C") }.GetNewClosure()
            $record = & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/tags"; Method = "Get"; Body = $null; TimeoutSec = 7; Purpose = "tags" }
            Assert-Equal "$member webStatus" $member $record.failure.webStatus
            Assert-True "$member httpStatus null" ($null -eq $record.httpStatus)
            Assert-True "$member body null" ($null -eq $record.failure.body)
            Assert-Equal "$member type" "System.Net.WebException" $record.failure.exceptionType
        }
    }

    Test-Case "AC-213 Invoke-OllamaHttp maps a non-web exception (plain throw, IOException): its type name, no webStatus, and never its message" {
        $script:rest.Handler = { param($uri) throw "SENTINEL-MESSAGE-D plain" }
        $plain = & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/generate"; Method = "Post"; Body = [byte[]](1); TimeoutSec = 9; Purpose = "generate" }
        Assert-Equal "plain type" "System.Management.Automation.RuntimeException" $plain.failure.exceptionType
        Assert-True "plain webStatus null" ($null -eq $plain.failure.webStatus)
        Assert-True "plain message absent" (($plain | ConvertTo-Json -Depth 5).IndexOf("SENTINEL-MESSAGE-D", [System.StringComparison]::Ordinal) -lt 0)
        $script:rest.Handler = { param($uri) throw (New-Object System.IO.IOException "SENTINEL-MESSAGE-E") }
        $io = & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/generate"; Method = "Post"; Body = [byte[]](1); TimeoutSec = 9; Purpose = "generate" }
        Assert-Equal "io type" "System.IO.IOException" $io.failure.exceptionType
        Assert-Equal "io category" "transport_reset" (Get-AgentErrorCategory -Failure $io.failure -HttpStatus $io.httpStatus).category
        Assert-True "io message absent" (($io | ConvertTo-Json -Depth 5).IndexOf("SENTINEL-MESSAGE-E", [System.StringComparison]::Ordinal) -lt 0)
    }

    Test-Case "AC-213 Invoke-OllamaHttp cuts the body at 4096 characters (4096 kept, 4097 and 10000 cut), from the stream and from ErrorDetails" {
        foreach ($length in 4096, 4097, 10000) {
            $text = "b" * $length
            $script:rest.Handler = { param($uri) throw (New-FakeHttpWebException -StatusCode 500 -Body $text) }.GetNewClosure()
            $record = & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/generate"; Method = "Post"; Body = [byte[]](1); TimeoutSec = 9; Purpose = "generate" }
            Assert-Equal "stream body of $length" ([math]::Min($length, 4096)) $record.failure.body.Length
        }
        $script:rest.Handler = {
            param($uri)
            $exception = New-FakeHttpWebException -StatusCode 500 -Body "x"
            $errorRecord = New-Object System.Management.Automation.ErrorRecord -ArgumentList $exception, "HarnessFake", ([System.Management.Automation.ErrorCategory]::InvalidOperation), $null
            $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails -ArgumentList ("d" * 5000)
            throw $errorRecord
        }
        $details = & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/generate"; Method = "Post"; Body = [byte[]](1); TimeoutSec = 9; Purpose = "generate" }
        Assert-Equal "ErrorDetails body cut" 4096 $details.failure.body.Length
    }

    Test-Case "AC-213 Invoke-OllamaHttp gives the same records under es-ES, en-US and tr-TR UI cultures" {
        $thread = [System.Threading.Thread]::CurrentThread
        $savedUi = $thread.CurrentUICulture
        $savedCulture = $thread.CurrentCulture
        try {
            foreach ($name in @("es-ES", "en-US", "tr-TR")) {
                $culture = [System.Globalization.CultureInfo]::GetCultureInfo($name)
                $thread.CurrentUICulture = $culture
                $thread.CurrentCulture = $culture
                $script:rest.Handler = { param($uri) throw (New-FakeHttpWebException -StatusCode 502 -Body '{"error":"bad gateway"}') }
                $http = & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/generate"; Method = "Post"; Body = [byte[]](1); TimeoutSec = 9; Purpose = "generate" }
                Assert-Equal "$name http" "http_5xx|502|ProtocolError" ((Get-AgentErrorCategory -Failure $http.failure -HttpStatus $http.httpStatus).category + "|" + $http.httpStatus + "|" + $http.failure.webStatus)
                $script:rest.Handler = { param($uri) throw (New-FakeStatusWebException -Status Timeout) }
                $timeout = & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/tags"; Method = "Get"; Body = $null; TimeoutSec = 7; Purpose = "tags" }
                Assert-Equal "$name timeout" "timeout" (Get-AgentErrorCategory -Failure $timeout.failure -HttpStatus $timeout.httpStatus).category
            }
        }
        finally {
            $thread.CurrentUICulture = $savedUi
            $thread.CurrentCulture = $savedCulture
        }
    }

    Test-Case "AC-213 end to end through the real transport and the fake Invoke-RestMethod: a 500 is retried once and the answer is returned" {
        $registry = New-TestRegistry -MaxAttempts 2 -Backoff 5
        $script:state = @{ Calls = 0 }
        $script:rest.Handler = {
            param($uri)
            $script:state.Calls++
            if ($script:state.Calls -eq 1) { throw (New-FakeHttpWebException -StatusCode 500 -Body '{"error":"first"}') }
            return (New-FakeGenerateResponse -Text "second time")
        }
        $script:httpStub = { param($Request) & $realHttp -Request $Request }
        $sleeper = New-SleepRecorder
        $result = Invoke-AgentModel -Execution (Get-TestExecution $registry) -Registry $registry -System "A" -Prompt "B" -Sleep $sleeper.Sleep
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "text" "second time" $result.text
        Assert-Equal "attempts" 2 $result.meta.attempts
        Assert-Equal "sleeps" "5" ($sleeper.List -join ",")
        Assert-Equal "rest calls" 2 $script:rest.Calls.Count
        Assert-Equal "rest timeouts" "44,44" (($script:rest.Calls | ForEach-Object { $_.TimeoutSec }) -join ",")
    }

    # -----------------------------------------------------------------------
    # Test-OllamaModel (FR-215)
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== Test-OllamaModel (FR-215) ===" -ForegroundColor Cyan

    Test-Case "FR-215 a model in /api/tags is available (match is exact and case-insensitive); nothing is written even with -TelemetryRoot; nothing is printed" {
        $registry = New-TestRegistry
        $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response (New-FakeTagsResponse -Models @("other:1b", "M-ALPHA"))))
        $caseRoot = New-CaseRoot
        $output = @(& { Test-OllamaModel -Execution (Get-TestExecution $registry) -Registry $registry -Transport $fake.Transport -TelemetryRoot $caseRoot } *>&1)
        Assert-Equal "output objects" 1 $output.Count
        $result = $output[0]
        Assert-Equal "available" $true $result.available
        Assert-True "category null" ($null -eq $result.category)
        Assert-Equal "models" "other:1b,M-ALPHA" ($result.models -join ",")
        Assert-Equal "records" 0 (@(Read-Records $caseRoot)).Count
        Assert-Equal "members" "available,category,models,detail,hint,httpStatus" ((@($result.PSObject.Properties | ForEach-Object { $_.Name })) -join ",")
    }

    Test-Case "FR-215 the tags request: method Get, purpose tags, healthTimeoutSec, /api/tags url, no body" {
        $registry = New-TestRegistry
        $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response (New-FakeTagsResponse -Models @("m-alpha"))))
        Test-OllamaModel -Execution (Get-TestExecution $registry) -Registry $registry -Transport $fake.Transport | Out-Null
        $call = $fake.Calls[0]
        Assert-Equal "purpose" "tags" $call.Purpose
        Assert-Equal "method" "Get" $call.Method
        Assert-Equal "timeout" 7 $call.TimeoutSec
        Assert-Equal "url" "http://127.0.0.1:9/api/tags" $call.Url
        Assert-True "no body" ($null -eq $call.BodyText)
    }

    Test-Case "FR-215 a model that is not installed: category model_not_installed, a hint, one record with model_called false and no attempts or status" {
        $registry = New-TestRegistry
        $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response (New-FakeTagsResponse -Models @("m-alpha:latest", "m-alph"))))
        $caseRoot = New-CaseRoot
        $result = Test-OllamaModel -Execution (Get-TestExecution $registry) -Registry $registry -Transport $fake.Transport -TelemetryRoot $caseRoot
        Assert-Equal "available" $false $result.available
        Assert-Equal "category" "model_not_installed" $result.category
        Assert-True "hint" ($result.hint.Length -gt 0)
        Assert-Equal "models are listed" "m-alpha:latest,m-alph" ($result.models -join ",")
        $records = @(Read-Records $caseRoot)
        Assert-Equal "lines" 1 $records.Count
        $record = $records[0]
        Assert-Equal "status" "error" $record.status
        Assert-Equal "model_called" $false $record.model_called
        Assert-Equal "error_category" "model_not_installed" $record.error_category
        Assert-Equal "model" "m-alpha" $record.model
        Assert-Equal "agent" "a-alpha" $record.agent
        Assert-Equal "profile" "alpha" $record.profile
        Assert-Equal "model_source" "agent" $record.model_source
        Assert-Equal "attempts" "" $record.attempts
        Assert-Equal "http_status" "" $record.http_status
        Assert-Equal "timeout_sec" 44 $record.timeout_sec
        Assert-Equal "think_sent" "" $record.think_sent
        Assert-Equal "schema_version" 2 $record.schema_version
    }

    Test-Case "FR-215 a failure of /api/tags returns its real category (timeout, unreachable, 5xx, 4xx, reset) and writes one model_called false record carrying it" {
        $registry = New-TestRegistry
        $cases = @(
            @{ Step = (New-FakeFailureRecord -WebStatus "Timeout"); Category = "timeout"; Status = "" },
            @{ Step = (New-FakeFailureRecord -WebStatus "ConnectFailure"); Category = "transport_unreachable"; Status = "" },
            @{ Step = (New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus 500 -Body '{"error":"x"}'); Category = "http_5xx"; Status = "500" },
            @{ Step = (New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus 404); Category = "http_4xx"; Status = "404" },
            @{ Step = (New-FakeFailureRecord -WebStatus "ConnectionClosed"); Category = "transport_reset"; Status = "" },
            @{ Step = (New-Object System.InvalidOperationException "boom"); Category = "transport_other"; Status = "" }
        )
        foreach ($case in $cases) {
            Reset-AgentExecState
            $fake = New-FakeTransport -Steps @($case.Step)
            $caseRoot = New-CaseRoot
            $result = Test-OllamaModel -Execution (Get-TestExecution $registry) -Registry $registry -Transport $fake.Transport -TelemetryRoot $caseRoot
            Assert-Equal "$($case.Category) available" $false $result.available
            Assert-Equal "$($case.Category) category" $case.Category $result.category
            Assert-Equal "$($case.Category) models" 0 @($result.models).Count
            Assert-Equal "$($case.Category) transport calls (no retry here)" 1 $fake.Count()
            $records = @(Read-Records $caseRoot)
            Assert-Equal "$($case.Category) lines" 1 $records.Count
            Assert-Equal "$($case.Category) record category" $case.Category $records[0].error_category
            Assert-Equal "$($case.Category) model_called" $false $records[0].model_called
            Assert-Equal "$($case.Category) http_status" $case.Status $records[0].http_status
        }
    }

    Test-Case "FR-215 /api/tags is requested once per process and URL; a failure is not cached; Reset-AgentExecState clears the cache" {
        $registry = New-TestRegistry
        $execution = Get-TestExecution $registry
        $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response (New-FakeTagsResponse -Models @("m-alpha")))) -RepeatLast
        Test-OllamaModel -Execution $execution -Registry $registry -Transport $fake.Transport | Out-Null
        Test-OllamaModel -Execution $execution -Registry $registry -Transport $fake.Transport | Out-Null
        Assert-Equal "two checks, one request" 1 $fake.Count("tags")
        Reset-AgentExecState
        Test-OllamaModel -Execution $execution -Registry $registry -Transport $fake.Transport | Out-Null
        Assert-Equal "after reset" 2 $fake.Count("tags")

        Reset-AgentExecState
        $flaky = New-FakeTransport -Steps @((New-FakeFailureRecord -WebStatus "ConnectFailure"), (New-FakeOkRecord -Response (New-FakeTagsResponse -Models @("m-alpha"))))
        Assert-Equal "first: unreachable" $false (Test-OllamaModel -Execution $execution -Registry $registry -Transport $flaky.Transport).available
        Assert-Equal "second: asked again, available" $true (Test-OllamaModel -Execution $execution -Registry $registry -Transport $flaky.Transport).available
        Assert-Equal "requests" 2 $flaky.Count("tags")

        # another URL is another cache entry
        Reset-AgentExecState
        $other = $registry.PSObject.Copy()
        $other.ollama = $registry.ollama.PSObject.Copy()
        $other.ollama.url = "http://127.0.0.1:19"
        $both = New-FakeTransport -Steps @((New-FakeOkRecord -Response (New-FakeTagsResponse -Models @("m-alpha")))) -RepeatLast
        Test-OllamaModel -Execution $execution -Registry $registry -Transport $both.Transport | Out-Null
        Test-OllamaModel -Execution $execution -Registry $other -Transport $both.Transport | Out-Null
        Assert-Equal "two URLs, two requests" 2 $both.Count("tags")
    }

    Test-Case "FR-215 a tags answer without a models member means the model is not installed; empty and odd entries are tolerated" {
        $registry = New-TestRegistry
        foreach ($response in @([pscustomobject]@{}, [pscustomobject]@{ models = @() }, [pscustomobject]@{ models = @([pscustomobject]@{ nope = 1 }, $null) }, $null)) {
            Reset-AgentExecState
            $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response $response))
            $result = Test-OllamaModel -Execution (Get-TestExecution $registry) -Registry $registry -Transport $fake.Transport
            Assert-Equal "category" "model_not_installed" $result.category
        }
    }

    Test-Case "FR-215 a mandatory argument problem throws (programmer error): bad Execution, bad Registry, TelemetryRoot without an agent" {
        $registry = New-TestRegistry
        $execution = Get-TestExecution $registry
        Assert-Throws "Execution" { Test-OllamaModel -Execution ([pscustomobject]@{}) -Registry $registry } "invalid_arguments:"
        Assert-Throws "Registry" { Test-OllamaModel -Execution $execution -Registry ([pscustomobject]@{}) } "invalid_arguments:"
        $anonymous = $execution.PSObject.Copy(); $anonymous.agent = ""
        Assert-Throws "agent" { Test-OllamaModel -Execution $anonymous -Registry $registry -TelemetryRoot (New-CaseRoot) } "invalid_arguments:"
    }

    # -----------------------------------------------------------------------
    # AC-203 (engine part) and FR-209: the budget before any request
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== budget (FR-209, AC-203 engine part) ===" -ForegroundColor Cyan

    Test-Case "AC-203 enforce: 32001 characters at 4 per token is 8001 tokens against 8000 available -> context_budget_exceeded, zero requests (no warm-up either), one record with model_called false" {
        $registry = New-TestRegistry -BudgetMode "enforce" -CharsPerToken 4 -Warmup $true
        $fake = New-FakeTransport -Steps @((New-Ok)) -RepeatLast
        $caseRoot = New-CaseRoot
        $parts = @((New-AgentPromptPart -Name "template" -Kind instruction -Text ("t" * 12000)), (New-AgentPromptPart -Name "task" -Kind data -Text ("d" * 20001)))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -System ("s" * 32000) -Prompt "p" -TelemetryRoot $caseRoot -Parts $parts
        Assert-Equal "status" "error" $result.status
        Assert-Equal "category" "context_budget_exceeded" $result.error.category
        Assert-Equal "requests" 0 $fake.Count()
        Assert-Equal "attempts" 0 $result.meta.attempts
        Assert-Equal "modelCalled" $false $result.meta.modelCalled
        Assert-Equal "text" "" $result.text
        Assert-True "hint" ($result.error.hint.Length -gt 0)
        Assert-Equal "budget status" "exceeded" $result.meta.budget.status
        Assert-Equal "budget estTokens" 8001 $result.meta.budget.estTokens
        Assert-Equal "budget available" 8000 $result.meta.budget.available
        Assert-Equal "budget over" 1 $result.meta.budget.over
        Assert-Equal "error detail (the harness's own fixed wording and the numbers)" "estimated 8001 tokens, available 8000" $result.error.detail
        Assert-Equal "sections" "template|instruction|12000|3000;task|data|20001|5001" (($result.meta.budget.sections | ForEach-Object { "$($_.name)|$($_.kind)|$($_.chars)|$($_.estTokens)" }) -join ";")
        $records = @(Read-Records $caseRoot)
        Assert-Equal "lines" 1 $records.Count
        Assert-Equal "model_called" $false $records[0].model_called
        Assert-Equal "error_category" "context_budget_exceeded" $records[0].error_category
        Assert-Equal "est_prompt_tokens" 8001 $records[0].est_prompt_tokens
        Assert-Equal "context_window" 10000 $records[0].context_window
        Assert-Equal "prompt_chars" 32001 $records[0].prompt_chars
        Assert-Equal "attempts" "" $records[0].attempts
        Assert-Equal "status" "error" $records[0].status
        Assert-True "error column starts with the category" ([string]$records[0].error).StartsWith("context_budget_exceeded: ", [System.StringComparison]::Ordinal)
    }

    Test-Case "AC-203 enforce: exactly 32000 characters is 8000 tokens, the limit is met, and the request is sent whole" {
        $registry = New-TestRegistry -BudgetMode "enforce" -CharsPerToken 4
        $fake = New-FakeTransport -Steps @((New-Ok))
        $system = "s" * 31999
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -System $system -Prompt "p"
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "budget status" "ok" $result.meta.budget.status
        Assert-Equal "estTokens" 8000 $result.meta.estPromptTokens
        Assert-Equal "requests" 1 $fake.Count("generate")
    }

    Test-Case "AC-203 warn: the same 32001-character prompt is sent whole (never truncated), with the warning budget_exceeded in meta and in the telemetry" {
        $registry = New-TestRegistry -BudgetMode "warn" -CharsPerToken 4
        $fake = New-FakeTransport -Steps @((New-Ok))
        $caseRoot = New-CaseRoot
        $system = ("s" * 31000) + "END"
        $prompt = ("p" * 1000) + "TAIL"
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -System $system -Prompt $prompt -TelemetryRoot $caseRoot
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "warnings" "budget_exceeded" ($result.meta.warnings -join ",")
        Assert-Equal "budget status" "exceeded" $result.meta.budget.status
        Assert-True "system sent whole" ([string]::Equals($fake.Calls[0].Body.system, $system, [System.StringComparison]::Ordinal))
        Assert-True "prompt sent whole" ([string]::Equals($fake.Calls[0].Body.prompt, $prompt, [System.StringComparison]::Ordinal))
        $record = @(Read-Records $caseRoot)[0]
        Assert-Equal "telemetry warnings" "budget_exceeded" $record.warnings
        Assert-Equal "status" "success" $record.status
    }

    Test-Case "AC-203 (final QA N-9) the smallest charsPerToken the registry accepts (0.01) and the largest (10) with a 1,000,001-character prompt never throw: one request, the warning, the literal estimate" {
        foreach ($case in @(@{ Chars = 0.01; Estimate = 100000100 }, @{ Chars = 10; Estimate = 100001 })) {
            $registry = New-TestRegistry -CharsPerToken $case.Chars
            $fake = New-FakeTransport -Steps @((New-Ok))
            $caseRoot = New-CaseRoot
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -System ("s" * 1000000) -Prompt "p" -TelemetryRoot $caseRoot
            Assert-Equal "$($case.Chars) status" "ok" $result.status
            Assert-Equal "$($case.Chars) estPromptTokens" $case.Estimate $result.meta.estPromptTokens
            Assert-Equal "$($case.Chars) warning" "budget_exceeded" ($result.meta.warnings -join ",")
            Assert-Equal "$($case.Chars) record est_prompt_tokens" $case.Estimate (@(Read-Records $caseRoot))[0].est_prompt_tokens
        }
    }

    Test-Case "AC-203 the default budgetMode is warn (a registry without the key): an oversized prompt is sent with the warning" {
        $registry = New-TestRegistry -CharsPerToken 4
        Assert-Equal "normalized budgetMode" "warn" $registry.defaults.budgetMode
        $fake = New-FakeTransport -Steps @((New-Ok))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -System ("s" * 40000) -Prompt "p"
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "warning" "budget_exceeded" ($result.meta.warnings -join ",")
    }

    Test-Case "AC-203 a profile without a window or reserved tokens skips the budget even in enforce mode; telemetry has empty context_window and est_prompt_tokens but a prompt_chars" {
        $registry = New-TestRegistry -BudgetMode "enforce" -CharsPerToken 4
        $fake = New-FakeTransport -Steps @((New-Ok))
        $caseRoot = New-CaseRoot
        $result = Invoke-Engine -Exec (Get-TestExecution $registry "a-delta") -Registry $registry -Fake $fake -System ("s" * 200000) -Prompt "p" -TelemetryRoot $caseRoot
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "budget status" "skipped" $result.meta.budget.status
        Assert-True "estPromptTokens null" ($null -eq $result.meta.estPromptTokens)
        $record = @(Read-Records $caseRoot)[0]
        Assert-Equal "context_window" "" $record.context_window
        Assert-Equal "est_prompt_tokens" "" $record.est_prompt_tokens
        Assert-Equal "prompt_chars" 200001 $record.prompt_chars
        Assert-Equal "warnings" "" $record.warnings
    }

    # -----------------------------------------------------------------------
    # AC-214 engine part: one record per call, field values
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-214 one record per call ===" -ForegroundColor Cyan

    Test-Case "AC-214 a success: every field of the record is the literal worked out by hand (system 'AB', prompt 'CDE', charsPerToken 2.5 -> prompt_chars 5, est_prompt_tokens 2)" {
        $registry = New-TestRegistry -CharsPerToken 2.5
        $response = New-FakeGenerateResponse -Text "good" -Thinking "12345" -DoneReason "stop" -PromptEvalCount 11 -EvalCount 6
        $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response $response))
        $caseRoot = New-CaseRoot
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -System "AB" -Prompt "CDE" -TelemetryRoot $caseRoot
        $records = @(Read-Records $caseRoot)
        Assert-Equal "lines" 1 $records.Count
        $r = $records[0]
        Assert-Equal "schema_version" 2 $r.schema_version
        Assert-Equal "agent" "a-alpha" $r.agent
        Assert-Equal "model" "m-alpha" $r.model
        Assert-Equal "status" "success" $r.status
        Assert-Equal "error" "" $r.error
        Assert-Equal "profile" "alpha" $r.profile
        Assert-Equal "model_source" "agent" $r.model_source
        Assert-Equal "transport" "blocking" $r.transport
        Assert-Equal "model_called" $true $r.model_called
        Assert-Equal "attempts" 1 $r.attempts
        Assert-Equal "error_category" "" $r.error_category
        Assert-Equal "http_status" 200 $r.http_status
        Assert-Equal "done_reason" "stop" $r.done_reason
        Assert-Equal "thinking_chars" 5 $r.thinking_chars
        Assert-Equal "think_sent" "true" $r.think_sent
        Assert-Equal "timeout_sec" 44 $r.timeout_sec
        Assert-Equal "context_window" 10000 $r.context_window
        Assert-Equal "prompt_chars" 5 $r.prompt_chars
        Assert-Equal "est_prompt_tokens" 2 $r.est_prompt_tokens
        Assert-Equal "warnings" "" $r.warnings
        Assert-Equal "prompt_eval_count (legacy column)" 11 $r.prompt_eval_count
        Assert-Equal "eval_count (legacy column)" 6 $r.eval_count
        Assert-Equal "total_duration_ns" 1000 $r.total_duration_ns
        Assert-True "call_id is a GUID" ($r.call_id -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        Assert-Equal "meta.promptChars" 5 $result.meta.promptChars
        Assert-Equal "meta.estPromptTokens" 2 $result.meta.estPromptTokens
        Assert-True "meta.callId is a GUID" ([guid]::TryParse([string]$result.meta.callId, [ref][guid]::Empty))
        Assert-Equal "meta.callId equals the JSONL call_id (D1)" $result.meta.callId $r.call_id
        Assert-Equal "meta.callId equals the CSV call_id (D1)" $result.meta.callId (@(Import-Csv -LiteralPath (Join-Path $caseRoot "logs\model-calls.csv")))[0].call_id
    }

    Test-Case "AC-214 each outcome writes exactly one line with its literal category, attempts, model_called, status and error column" {
        $registry = New-TestRegistry -MaxAttempts 2 -Backoff 0
        $reviewCheck = { param($t) "no_status" }
        $cases = @(
            @{ N = "http_5xx x2"; Steps = @((New-Fail5xx)); Repeat = $true; Check = $null; Cat = "http_5xx"; Attempts = 2; Status = "error"; Err = "http_5xx: gpu init failed"; Http = 500; Called = $true },
            @{ N = "http_4xx"; Steps = @((New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus 400 -Body '{"error":"bad model"}')); Repeat = $false; Check = $null; Cat = "http_4xx"; Attempts = 1; Status = "error"; Err = "http_4xx: bad model"; Http = 400; Called = $true },
            @{ N = "timeout"; Steps = @((New-FailTimeout)); Repeat = $false; Check = $null; Cat = "timeout"; Attempts = 1; Status = "error"; Err = "timeout: System.Net.WebException Timeout"; Http = ""; Called = $true },
            @{ N = "reset then ok"; Steps = @((New-FailReset), (New-Ok)); Repeat = $false; Check = $null; Cat = ""; Attempts = 2; Status = "success"; Err = ""; Http = 200; Called = $true },
            @{ N = "empty_response"; Steps = @((New-Ok -Text "")); Repeat = $false; Check = $null; Cat = "empty_response"; Attempts = 1; Status = "error"; Err = "empty_response"; Http = 200; Called = $true },
            @{ N = "thinking_budget_exhausted"; Steps = @((New-Ok -Text "" -DoneReason "length")); Repeat = $false; Check = $null; Cat = "thinking_budget_exhausted"; Attempts = 1; Status = "error"; Err = "thinking_budget_exhausted"; Http = 200; Called = $true },
            @{ N = "format_invalid"; Steps = @((New-Ok -Text "no status")); Repeat = $false; Check = $reviewCheck; Cat = "format_invalid"; Attempts = 1; Status = "error"; Err = "format_invalid: no_status"; Http = 200; Called = $true },
            @{ N = "thrown exception"; Steps = @((New-Object System.InvalidOperationException "boom")); Repeat = $false; Check = $null; Cat = "transport_other"; Attempts = 1; Status = "error"; Err = "transport_other: System.InvalidOperationException"; Http = ""; Called = $true }
        )
        foreach ($case in $cases) {
            $fake = if ($case.Repeat) { New-FakeTransport -Steps $case.Steps -RepeatLast } else { New-FakeTransport -Steps $case.Steps }
            $caseRoot = New-CaseRoot
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -TelemetryRoot $caseRoot -Check $case.Check
            $records = @(Read-Records $caseRoot)
            Assert-Equal "$($case.N): lines" 1 $records.Count
            Assert-Equal "$($case.N): error_category" $case.Cat $records[0].error_category
            Assert-Equal "$($case.N): attempts" $case.Attempts $records[0].attempts
            Assert-Equal "$($case.N): status" $case.Status $records[0].status
            Assert-Equal "$($case.N): error column" $case.Err $records[0].error
            Assert-Equal "$($case.N): http_status" $case.Http $records[0].http_status
            Assert-Equal "$($case.N): model_called" $case.Called $records[0].model_called
            Assert-Equal "$($case.N): result status agrees" $(if ($case.Status -ceq "success") { "ok" } else { "error" }) $result.status
            $csv = @(Import-Csv -LiteralPath (Join-Path $caseRoot "logs\model-calls.csv"))
            Assert-Equal "$($case.N): csv rows" 1 $csv.Count
            Assert-Equal "$($case.N): meta.callId equals the JSONL call_id" $result.meta.callId $records[0].call_id
            Assert-Equal "$($case.N): meta.callId equals the CSV call_id" $result.meta.callId $csv[0].call_id
        }
    }

    Test-Case "AC-214 a call writes one record each: three calls, three lines; a retry never adds a line; no -TelemetryRoot writes nothing" {
        $registry = New-TestRegistry -MaxAttempts 3 -Backoff 0
        $caseRoot = New-CaseRoot
        $fake = New-FakeTransport -Steps @((New-Fail5xx), (New-Fail5xx), (New-Ok), (New-Ok), (New-FailTimeout))
        Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -TelemetryRoot $caseRoot | Out-Null
        Assert-Equal "after the call that retried twice" 1 (@(Read-Records $caseRoot)).Count
        Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -TelemetryRoot $caseRoot | Out-Null
        Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -TelemetryRoot $caseRoot | Out-Null
        $records = @(Read-Records $caseRoot)
        Assert-Equal "after three calls" 3 $records.Count
        Assert-Equal "attempts of the calls" "3,1,1" (($records | ForEach-Object { $_.attempts }) -join ",")
        Assert-Equal "call_id differs between calls" 3 (@($records | ForEach-Object { $_.call_id } | Select-Object -Unique)).Count
        $bare = New-CaseRoot
        $fake2 = New-FakeTransport -Steps @((New-Ok))
        Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake2 | Out-Null
        Assert-True "no logs folder without -TelemetryRoot" (-not (Test-Path -LiteralPath (Join-Path $bare "logs")))
    }

    Test-Case "AC-214 a retry that ends in success and a warm-up failure each write one line (the retry and warm-up paths never write a second)" {
        $registry = New-TestRegistry -MaxAttempts 3 -Backoff 0 -Warmup $true
        $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response ([pscustomobject]@{ done = $true })), (New-FailReset), (New-FailReset), (New-Ok))
        $caseRoot = New-CaseRoot
        Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -TelemetryRoot $caseRoot | Out-Null
        $records = @(Read-Records $caseRoot)
        Assert-Equal "lines" 1 $records.Count
        Assert-Equal "attempts" 3 $records[0].attempts

        Reset-AgentExecState
        $failing = New-FakeTransport -Steps @((New-Fail5xx)) -RepeatLast
        $root2 = New-CaseRoot
        Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $failing -TelemetryRoot $root2 | Out-Null
        Assert-Equal "warm-up failure lines" 1 (@(Read-Records $root2)).Count
    }

    Test-Case "AC-214 the model call is recorded as called when only a warm-up was sent (the request reached the server)" {
        $registry = New-TestRegistry -MaxAttempts 1 -Warmup $true
        $failing = New-FakeTransport -Steps @((New-FakeFailureRecord -WebStatus "ConnectFailure"))
        $caseRoot = New-CaseRoot
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $failing -TelemetryRoot $caseRoot
        Assert-Equal "category" "transport_unreachable" $result.error.category
        Assert-Equal "meta.modelCalled" $true $result.meta.modelCalled
        Assert-Equal "record model_called" $true (@(Read-Records $caseRoot))[0].model_called
    }

    Test-Case "AC-214 the exception message never reaches the error column: a fake whose messages are sentinels" {
        $registry = New-TestRegistry -MaxAttempts 1
        $caseRoot = New-CaseRoot
        $steps = @(
            (New-FakeFailureRecord -WebStatus "Timeout" -Message "SENTINEL-FAILURE-MESSAGE"),
            (New-Object System.InvalidOperationException "SENTINEL-THROWN-MESSAGE"),
            (New-FakeHttpWebException -StatusCode 500 -Body "plain text body" -Message "SENTINEL-WEB-MESSAGE")
        )
        foreach ($step in $steps) {
            $fake = New-FakeTransport -Steps @($step)
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -TelemetryRoot $caseRoot
            Assert-Equal "status" "error" $result.status
            Assert-True "the result carries no sentinel" (($result | ConvertTo-Json -Depth 6).IndexOf("SENTINEL", [System.StringComparison]::Ordinal) -lt 0)
        }
        $jsonl = [System.IO.File]::ReadAllText((Join-Path $caseRoot "logs\model-calls.jsonl"))
        $csv = [System.IO.File]::ReadAllText((Join-Path $caseRoot "logs\model-calls.csv"))
        Assert-True "no sentinel in the JSONL" ($jsonl.IndexOf("SENTINEL", [System.StringComparison]::Ordinal) -lt 0)
        Assert-True "no sentinel in the CSV" ($csv.IndexOf("SENTINEL", [System.StringComparison]::Ordinal) -lt 0)
        Assert-Equal "lines" 3 (@(Read-Records $caseRoot)).Count
    }

    Test-Case "AC-214 a v1 configuration: empty context_window and est_prompt_tokens, prompt_chars still written, profile is the synthetic legacy name" {
        $v1 = ConvertTo-HarnessRegistry -Config (('{"ollamaUrl":"http://127.0.0.1:9","defaultModel":"m-v1"}') | ConvertFrom-Json)
        $execution = Resolve-HarnessExecution -Agent "spec" -Registry $v1
        $fake = New-FakeTransport -Steps @((New-Ok))
        $caseRoot = New-CaseRoot
        Invoke-Engine -Exec $execution -Registry $v1 -Fake $fake -System "AB" -Prompt "CDE" -TelemetryRoot $caseRoot | Out-Null
        $r = @(Read-Records $caseRoot)[0]
        Assert-Equal "context_window" "" $r.context_window
        Assert-Equal "est_prompt_tokens" "" $r.est_prompt_tokens
        Assert-Equal "prompt_chars" 5 $r.prompt_chars
        Assert-Equal "think_sent" "omitted" $r.think_sent
        Assert-Equal "profile" "legacy:m-v1" $r.profile
        Assert-Equal "model_source" "default" $r.model_source
        Assert-Equal "agent" "spec" $r.agent
    }

    Test-Case "AC-214 the warnings column joins the codes with ';' (budget_exceeded;possible_prompt_truncation;output_truncated)" {
        $registry = New-TestRegistry -BudgetMode "warn" -CharsPerToken 4
        $fake = New-FakeTransport -Steps @((New-Ok -Text "cut" -DoneReason "length" -PromptEvalCount 9500))
        $caseRoot = New-CaseRoot
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -System ("s" * 40000) -Prompt "p" -TelemetryRoot $caseRoot
        Assert-Equal "meta.warnings" "budget_exceeded,possible_prompt_truncation,output_truncated" ($result.meta.warnings -join ",")
        Assert-Equal "record" "budget_exceeded;possible_prompt_truncation;output_truncated" (@(Read-Records $caseRoot))[0].warnings
    }

    Test-Case "AC-214 -Agent overrides the agent of the Execution in the record; a telemetry failure never fails the call" {
        $registry = New-TestRegistry
        $fake = New-FakeTransport -Steps @((New-Ok))
        $caseRoot = New-CaseRoot
        Invoke-AgentModel -Execution (Get-TestExecution $registry) -Registry $registry -System "A" -Prompt "B" -Transport $fake.Transport -TelemetryRoot $caseRoot -Agent "custom-agent" | Out-Null
        Assert-Equal "agent" "custom-agent" (@(Read-Records $caseRoot))[0].agent

        # a root that cannot be created: a file where the logs directory should be
        $blocked = New-CaseRoot
        Set-Content -LiteralPath (Join-Path $blocked "logs") -Value "i am a file" -Encoding ASCII
        $fake2 = New-FakeTransport -Steps @((New-Ok -Text "still fine"))
        $result = Invoke-AgentModel -Execution (Get-TestExecution $registry) -Registry $registry -System "A" -Prompt "B" -Transport $fake2.Transport -TelemetryRoot $blocked 3>$null
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "text" "still fine" $result.text
    }

    # -----------------------------------------------------------------------
    # WP-2C fix round: gaps found by the independent review (M-5, F-08 to F-20)
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== WP-2C fix round ===" -ForegroundColor Cyan

    Test-Case "AC-208 (M-5, F-09) the default wait is Start-Sleep in seconds: backoff 1 and no -Sleep waits at least 900 ms and at most 5 s, then the retry succeeds" {
        $registry = New-TestRegistry -MaxAttempts 2 -Backoff 1
        $fake = New-FakeTransport -Steps @((New-Fail5xx), (New-Ok -Text "after the wait"))
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-AgentModel -Execution (Get-TestExecution $registry) -Registry $registry -System "A" -Prompt "B" -Transport $fake.Transport
        $watch.Stop()
        Assert-Equal "status" "ok" $result.status
        Assert-Equal "attempts" 2 $result.meta.attempts
        Write-Host ("       default wait measured: {0} ms" -f $watch.ElapsedMilliseconds)
        Assert-True "waited at least 900 ms (seconds, not milliseconds, not skipped)" ($watch.ElapsedMilliseconds -ge 900)
        Assert-True "waited at most 5 s" ($watch.ElapsedMilliseconds -le 5000)
        Assert-True "meta.elapsedMs covers the wait" ($result.meta.elapsedMs -ge 900)
    }

    Test-Case "AC-214 (F-11) without -TelemetryRoot nothing is written anywhere: no file appears under the suite's temporary folder or the case folder" {
        $registry = New-TestRegistry
        $bare = New-CaseRoot
        $before = @(Get-ChildItem -LiteralPath $tempRoot -Recurse -Force | ForEach-Object { $_.FullName }).Count
        $fake = New-FakeTransport -Steps @((New-Ok))
        Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake | Out-Null
        $after = @(Get-ChildItem -LiteralPath $tempRoot -Recurse -Force | ForEach-Object { $_.FullName }).Count
        Assert-Equal "entries under the temporary folder" $before $after
        Assert-Equal "entries in the case folder" 0 @(Get-ChildItem -LiteralPath $bare -Recurse -Force).Count
        Assert-True "no logs folder in the working directory from this call" (-not (Test-Path -LiteralPath (Join-Path (Get-Location).Path "logs\model-calls.jsonl")) -or (Get-Item -LiteralPath (Join-Path (Get-Location).Path "logs\model-calls.jsonl")).LastWriteTimeUtc -lt [datetime]::UtcNow.AddSeconds(-30))
    }

    Test-Case "AC-209 (F-15) a warm-up that fails carries its http status, detail and hint in the result and the record (http_status 500, error 'http_5xx: gpu init failed')" {
        $registry = New-TestRegistry -Warmup $true -MaxAttempts 2 -Backoff 5
        $fake = New-FakeTransport -Steps @((New-Fail5xx)) -RepeatLast
        $caseRoot = New-CaseRoot
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -TelemetryRoot $caseRoot
        Assert-Equal "error.httpStatus" 500 $result.error.httpStatus
        Assert-Equal "error.detail" "gpu init failed" $result.error.detail
        Assert-True "error.hint is the hint of the category" ($result.error.hint.Length -gt 0 -and $result.error.hint -ceq (Get-AgentErrorCategory -Category "http_5xx").hint)
        Assert-Equal "error.retryable" $true $result.error.retryable
        Assert-Equal "error.attempts" 2 $result.error.attempts
        $record = @(Read-Records $caseRoot)[0]
        Assert-Equal "record http_status" 500 $record.http_status
        Assert-Equal "record error column" "http_5xx: gpu init failed" $record.error
        Assert-Equal "record attempts" 2 $record.attempts
        Assert-Equal "record model_called" $true $record.model_called
    }

    Test-Case "FR-215 (F-15) a failed /api/tags carries its detail, hint and http status in the result and the error column; a missing model names the model" {
        $registry = New-TestRegistry
        $cases = @(
            @{ Step = (New-FakeFailureRecord -WebStatus "Timeout"); Category = "timeout"; Detail = "System.Net.WebException Timeout"; Status = "" },
            @{ Step = (New-FakeFailureRecord -WebStatus "ConnectFailure"); Category = "transport_unreachable"; Detail = "System.Net.WebException ConnectFailure"; Status = "" },
            @{ Step = (New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus 500 -Body '{"error":"x"}'); Category = "http_5xx"; Detail = "x"; Status = 500 },
            @{ Step = (New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus 404); Category = "http_4xx"; Detail = "System.Net.WebException ProtocolError"; Status = 404 },
            @{ Step = (New-FakeFailureRecord -WebStatus "ConnectionClosed"); Category = "transport_reset"; Detail = "System.Net.WebException ConnectionClosed"; Status = "" },
            @{ Step = (New-Object System.InvalidOperationException "boom"); Category = "transport_other"; Detail = "System.InvalidOperationException"; Status = "" }
        )
        foreach ($case in $cases) {
            Reset-AgentExecState
            $fake = New-FakeTransport -Steps @($case.Step)
            $caseRoot = New-CaseRoot
            $result = Test-OllamaModel -Execution (Get-TestExecution $registry) -Registry $registry -Transport $fake.Transport -TelemetryRoot $caseRoot
            Assert-Equal "$($case.Category) detail" $case.Detail $result.detail
            Assert-True "$($case.Category) hint is the hint of the category" ($result.hint.Length -gt 0 -and $result.hint -ceq (Get-AgentErrorCategory -Category $case.Category).hint)
            Assert-Equal "$($case.Category) httpStatus" $case.Status $result.httpStatus
            Assert-Equal "$($case.Category) error column" "$($case.Category): $($case.Detail)" (@(Read-Records $caseRoot))[0].error
        }
        Reset-AgentExecState
        $missing = New-FakeTransport -Steps @((New-FakeOkRecord -Response (New-FakeTagsResponse -Models @("other"))))
        $caseRoot = New-CaseRoot
        $result = Test-OllamaModel -Execution (Get-TestExecution $registry) -Registry $registry -Transport $missing.Transport -TelemetryRoot $caseRoot
        Assert-Equal "model_not_installed detail is the model" "m-alpha" $result.detail
        Assert-True "model_not_installed hint" ($result.hint.Length -gt 0 -and $result.hint -ceq (Get-AgentErrorCategory -Category "model_not_installed").hint)
        Assert-Equal "model_not_installed error column" "model_not_installed: m-alpha" (@(Read-Records $caseRoot))[0].error
    }

    Test-Case "AC-213 (F-16) the error body read from the response stream (chunked answer, empty ErrorDetails) is decoded as UTF-8: non-ASCII text survives, also as the detail" {
        $text = "caf" + [char]0x00E9 + " " + [char]0x4E2D + [char]0x6587 + " " + [char]::ConvertFromUtf32(0x1F600)
        $script:wireText = $text
        $script:rest.Handler = { param($uri) throw (New-FakeHttpWebException -StatusCode 500 -Body ('{"error":"' + $script:wireText + '"}')) }
        $record = & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/generate"; Method = "Post"; Body = [byte[]](1); TimeoutSec = 9; Purpose = "generate" }
        Assert-Equal "body round trip" ('{"error":"' + $text + '"}') $record.failure.body
        Assert-Equal "detail round trip" $text (Get-AgentErrorCategory -Failure $record.failure -HttpStatus $record.httpStatus).detail
    }

    Test-Case "FR-204 (F-20) a trailing slash of ollama.url is trimmed: generate, warm-up and tags requests go to /api/... with a single slash" {
        $registry = New-TestRegistry -Warmup $true
        foreach ($suffix in "/", "//") {
            Reset-AgentExecState
            $slashed = $registry.PSObject.Copy()
            $slashed.ollama = $registry.ollama.PSObject.Copy()
            $slashed.ollama.url = "http://127.0.0.1:9" + $suffix
            $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response (New-FakeTagsResponse -Models @("m-alpha"))), (New-FakeOkRecord -Response ([pscustomobject]@{ done = $true })), (New-Ok))
            $available = Test-OllamaModel -Execution (Get-TestExecution $registry) -Registry $slashed -Transport $fake.Transport
            Assert-Equal "available '$suffix'" $true $available.available
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $slashed -Fake $fake
            Assert-Equal "status '$suffix'" "ok" $result.status
            Assert-Equal "urls '$suffix'" "http://127.0.0.1:9/api/tags,http://127.0.0.1:9/api/generate,http://127.0.0.1:9/api/generate" (($fake.Calls | ForEach-Object { $_.Url }) -join ",")
        }
    }

    Test-Case "AC-211 (F-15, review N11) an interpretation failure (empty_response, thinking_budget_exhausted, format_invalid) carries the http status of the answer in error.httpStatus; a transport failure before any answer has no thinkingChars and a blank thinking_chars" {
        $registry = New-TestRegistry
        $cases = @(
            @{ Step = (New-Ok -Text ""); Check = $null; Category = "empty_response" },
            @{ Step = (New-Ok -Text "" -DoneReason "length"); Check = $null; Category = "thinking_budget_exhausted" },
            @{ Step = (New-Ok -Text "x"); Check = { param($t) "code" }; Category = "format_invalid" }
        )
        foreach ($case in $cases) {
            $fake = New-FakeTransport -Steps @($case.Step)
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -Check $case.Check
            Assert-Equal "$($case.Category) category" $case.Category $result.error.category
            Assert-Equal "$($case.Category) error.httpStatus" 200 $result.error.httpStatus
        }
        $single = New-TestRegistry -MaxAttempts 1
        $caseRoot = New-CaseRoot
        $failed = Invoke-Engine -Exec (Get-TestExecution $single) -Registry $single -Fake (New-FakeTransport -Steps @((New-Fail5xx))) -TelemetryRoot $caseRoot
        Assert-True "meta.thinkingChars is null without an answer" ($null -eq $failed.meta.thinkingChars)
        Assert-Equal "record thinking_chars is blank without an answer" "" (@(Read-Records $caseRoot))[0].thinking_chars
        $answered = Invoke-Engine -Exec (Get-TestExecution $single) -Registry $single -Fake (New-FakeTransport -Steps @((New-Ok -Text "x"))) -TelemetryRoot (New-CaseRoot)
        Assert-Equal "meta.thinkingChars is 0 with an answer" 0 $answered.meta.thinkingChars
    }

    Test-Case "AC-211 (F-25, review N19) the first non-blank output of a -ResponseCheck is the code (not the last)" {
        $registry = New-TestRegistry
        $fake = New-FakeTransport -Steps @((New-Ok -Text "text"))
        $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -Check { param($t) $null; "code_first"; "code_second" }
        Assert-Equal "category" "format_invalid" $result.error.category
        Assert-Equal "detail" "code_first" $result.error.detail
    }

    Test-Case "AC-214 (F-10, review N15 to N17) meta.callId is a new GUID per call; elapsedMs and the record's duration_ms measure the call (a 40 ms transport gives at least 30 ms)" {
        $registry = New-TestRegistry
        $slow = { param($r) $spin = [System.Diagnostics.Stopwatch]::StartNew(); while ($spin.ElapsedMilliseconds -lt 40) { }; New-Ok }
        $ids = New-Object 'System.Collections.Generic.List[string]'
        foreach ($i in 1..2) {
            $fake = New-FakeTransport -Steps @($slow)
            $caseRoot = New-CaseRoot
            $result = Invoke-Engine -Exec (Get-TestExecution $registry) -Registry $registry -Fake $fake -TelemetryRoot $caseRoot
            Assert-True "callId is a GUID ($i)" ([guid]::TryParse([string]$result.meta.callId, [ref][guid]::Empty))
            $ids.Add([string]$result.meta.callId)
            Assert-True "elapsedMs at least 30 ($i): $($result.meta.elapsedMs)" ($result.meta.elapsedMs -ge 30)
            Assert-True "elapsedMs under 5000 ($i)" ($result.meta.elapsedMs -lt 5000)
            $record = @(Read-Records $caseRoot)[0]
            Assert-True "record duration_ms at least 30 ($i): $($record.duration_ms)" ([long]$record.duration_ms -ge 30)
            Assert-True "record duration_ms under 5000 ($i)" ([long]$record.duration_ms -lt 5000)
        }
        Assert-True "the two calls have different callIds" ($ids[0] -cne $ids[1])
    }

    Test-Case "AC-210 (F-14) think_sent describes the generation request: blank after a failed warm-up and after a budget refusal, set when the generation is sent (also after a successful warm-up)" {
        $registry = New-TestRegistry -Warmup $true -MaxAttempts 1
        $caseRoot = New-CaseRoot
        $failed = Invoke-Engine -Exec (Get-TestExecution $registry "a-alpha") -Registry $registry -Fake (New-FakeTransport -Steps @((New-Fail5xx))) -TelemetryRoot $caseRoot
        Assert-Equal "failed warm-up: meta.thinkSent" "" $failed.meta.thinkSent
        Assert-Equal "failed warm-up: record think_sent" "" (@(Read-Records $caseRoot))[0].think_sent
        Assert-Equal "failed warm-up: modelCalled" $true $failed.meta.modelCalled

        Reset-AgentExecState
        $caseRoot2 = New-CaseRoot
        $sent = Invoke-Engine -Exec (Get-TestExecution $registry "a-beta") -Registry $registry -Fake (New-FakeTransport -Steps @((New-FakeOkRecord -Response ([pscustomobject]@{ done = $true })), (New-Ok))) -TelemetryRoot $caseRoot2
        Assert-Equal "after a successful warm-up: meta.thinkSent" "false" $sent.meta.thinkSent
        Assert-Equal "after a successful warm-up: record think_sent" "false" (@(Read-Records $caseRoot2))[0].think_sent

        $enforce = New-TestRegistry -BudgetMode "enforce" -CharsPerToken 4 -Warmup $true
        $caseRoot3 = New-CaseRoot
        $refused = Invoke-Engine -Exec (Get-TestExecution $enforce "a-alpha") -Registry $enforce -Fake (New-FakeTransport -Steps @((New-Ok))) -System ("s" * 40000) -TelemetryRoot $caseRoot3
        Assert-Equal "budget refusal: meta.thinkSent" "" $refused.meta.thinkSent
        Assert-Equal "budget refusal: record think_sent" "" (@(Read-Records $caseRoot3))[0].think_sent
    }

    Test-Case "FR-215 (F-18) a 200 answer of /api/tags without a models member is not cached and its detail names the type; an answer with a models member is cached" {
        $registry = New-TestRegistry
        $execution = Get-TestExecution $registry
        foreach ($shape in @(@{ Response = ""; Type = "System.String" }, @{ Response = $null; Type = "null" }, @{ Response = ([pscustomobject]@{ note = 1 }); Type = "System.Management.Automation.PSCustomObject" }, @{ Response = "<html></html>"; Type = "System.String" })) {
            Reset-AgentExecState
            $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response $shape.Response), (New-FakeOkRecord -Response (New-FakeTagsResponse -Models @("m-alpha"))))
            $first = Test-OllamaModel -Execution $execution -Registry $registry -Transport $fake.Transport
            Assert-Equal "category ($($shape.Type))" "model_not_installed" $first.category
            Assert-True "detail names the type ($($shape.Type)): $($first.detail)" ($first.detail.Contains($shape.Type) -and $first.detail.Contains("m-alpha"))
            $second = Test-OllamaModel -Execution $execution -Registry $registry -Transport $fake.Transport
            Assert-Equal "asked again ($($shape.Type))" 2 $fake.Count("tags")
            Assert-Equal "second answer is used ($($shape.Type))" $true $second.available
            $third = Test-OllamaModel -Execution $execution -Registry $registry -Transport $fake.Transport
            Assert-Equal "now cached ($($shape.Type))" 2 $fake.Count("tags")
            Assert-Equal "third available" $true $third.available
        }
        Reset-AgentExecState
        $empty = New-FakeTransport -Steps @((New-FakeOkRecord -Response (New-FakeTagsResponse -Models @()))) -RepeatLast
        $none = Test-OllamaModel -Execution $execution -Registry $registry -Transport $empty.Transport
        Test-OllamaModel -Execution $execution -Registry $registry -Transport $empty.Transport | Out-Null
        Assert-Equal "an empty models list is cached" 1 $empty.Count("tags")
        Assert-Equal "an empty models list: detail is the model only" "m-alpha" $none.detail
    }

    Test-Case "FR-215 (F-13) static: Test-OllamaModel has no unused modelCalled variable" {
        $parseTokens = $null; $parseErrors = $null
        $libraryAst = [System.Management.Automation.Language.Parser]::ParseFile($engineLibrary, [ref]$parseTokens, [ref]$parseErrors)
        $function = $libraryAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq "Test-OllamaModel" }, $true)[0]
        Assert-True "the function was found" ($null -ne $function)
        Assert-Equal "occurrences of modelCalled in Test-OllamaModel" 0 ([regex]::Matches($function.Extent.Text, 'modelCalled')).Count
    }

    if (-not ('HarnessEndlessResponse' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;

public class HarnessEndlessStream : Stream
{
    public long BytesRead;
    public override bool CanRead { get { return true; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return false; } }
    public override long Length { get { throw new NotSupportedException(); } }
    public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
    public override void SetLength(long value) { throw new NotSupportedException(); }
    public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    public override int Read(byte[] buffer, int offset, int count)
    {
        // a stream that never ends; reading past 8 MB is a failure of the reader, not a hang
        if (BytesRead > 8 * 1024 * 1024) { throw new IOException("endless stream read to its end"); }
        for (int i = 0; i < count; i++) { buffer[offset + i] = (byte)'a'; }
        BytesRead += count;
        return count;
    }
}

public class HarnessEndlessResponse : WebResponse
{
    public readonly HarnessEndlessStream Stream = new HarnessEndlessStream();
    public HttpStatusCode StatusCode { get { return HttpStatusCode.InternalServerError; } }
    public override long ContentLength { get { return -1; } set { } }
    public override string ContentType { get { return "application/json"; } set { } }
    public override Stream GetResponseStream() { return this.Stream; }
}
'@
    }

    Test-Case "AC-213 (F-23) the error body is read from the stream for at most 4096 characters: an endless stream is not read to its end" {
        $response = New-Object HarnessEndlessResponse
        $script:endless = $response
        $script:rest.Handler = { param($uri) throw (New-Object System.Net.WebException -ArgumentList "endless", $null, ([System.Net.WebExceptionStatus]::ProtocolError), $script:endless) }
        $record = & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/generate"; Method = "Post"; Body = [byte[]](1); TimeoutSec = 9; Purpose = "generate" }
        Assert-Equal "httpStatus" 500 $record.httpStatus
        Assert-Equal "body length" 4096 $record.failure.body.Length
        Assert-True "the stream was read for a few KB only ($($response.Stream.BytesRead) bytes)" ($response.Stream.BytesRead -lt 32768)
        $script:endless = $null
    }

    # -----------------------------------------------------------------------
    # NFR-201 / AC-217 library overhead
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== NFR-201 library overhead ===" -ForegroundColor Cyan

    Test-Case "NFR-201 / AC-217 20 calls with a fake transport and a 60,000-character prompt (budget, body, result and telemetry): median library time under 1000 ms" {
        $registry = New-TestRegistry -BudgetMode "warn" -CharsPerToken 3.5
        $execution = Get-TestExecution $registry
        $big = "x" * 59000
        $parts = @((New-AgentPromptPart -Name "template" -Kind instruction -Text ("t" * 1000)), (New-AgentPromptPart -Name "task" -Kind data -Text $big))
        $fake = New-FakeTransport -Steps @((New-Ok)) -RepeatLast
        $caseRoot = New-CaseRoot
        $samples = New-Object 'System.Collections.Generic.List[double]'
        for ($i = 1; $i -le 20; $i++) {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-AgentModel -Execution $execution -Registry $registry -System ("t" * 1000) -Prompt $big -Parts $parts -Transport $fake.Transport -TelemetryRoot $caseRoot
            $watch.Stop()
            Assert-Equal "call $i status" "ok" $result.status
            $samples.Add($watch.Elapsed.TotalMilliseconds)
        }
        $sorted = @($samples | Sort-Object)
        $median = ($sorted[9] + $sorted[10]) / 2
        $maximum = $sorted[19]
        Write-Host ("       NFR-201: 20 calls, 60,000 characters, median {0:N1} ms, max {1:N1} ms (limit: median < 1000 ms)" -f $median, $maximum)
        Assert-True "median under 1000 ms" ($median -lt 1000)
        Assert-Equal "records written" 20 (@(Read-Records $caseRoot)).Count
        Assert-Equal "the prompt was sent whole" 60000 ($fake.Calls[0].Body.system.Length + $fake.Calls[0].Body.prompt.Length)
    }

    # -----------------------------------------------------------------------
    # static scans and guards (NFR-203, NFR-204, AC-207, AC-219)
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== static scans and guards ===" -ForegroundColor Cyan

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($engineLibrary, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "agent-exec.ps1 has parse errors" }
    $functionAsts = @{}
    foreach ($function in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $functionAsts[$function.Name] = $function
    }

    Test-Case "FR-201 the library defines Reset-AgentExecState, Invoke-OllamaHttp, Test-OllamaModel and Invoke-AgentModel" {
        foreach ($name in "Reset-AgentExecState", "Invoke-OllamaHttp", "Test-OllamaModel", "Invoke-AgentModel") {
            Assert-True "$name is defined" ($functionAsts.ContainsKey($name))
        }
    }

    Test-Case "AC-207 static: no .Message read and no 'Message' lookup in Invoke-OllamaHttp, Test-OllamaModel, Invoke-AgentModel (only display fields would be exempt; there are none)" {
        foreach ($name in "Invoke-OllamaHttp", "Test-OllamaModel", "Invoke-AgentModel") {
            $function = $functionAsts[$name]
            Assert-Equal "$name .Message reads" 0 @($function.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq "Message" }, $true)).Count
            Assert-Equal "$name 'Message' constants" 0 @($function.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -ceq "Message" }, $true)).Count
            Assert-Equal "$name 'ErrorRecord.Exception.Message' text" 0 ([regex]::Matches($function.Extent.Text, '\.Message\b')).Count
        }
    }

    Test-Case "NFR-202 static: no text operator on message-like data in the engine functions (no -match, -like on bodies or messages; no Contains or IndexOf on them)" {
        foreach ($name in "Invoke-OllamaHttp", "Test-OllamaModel", "Invoke-AgentModel") {
            $function = $functionAsts[$name]
            foreach ($operator in $function.FindAll({ param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)) {
                $kind = [string]$operator.Operator
                if (@("Imatch", "Cmatch", "Ilike", "Clike", "Inotmatch", "Cnotmatch", "Inotlike", "Cnotlike") -contains $kind) { throw "$name uses text operator $kind in: $($operator.Extent.Text)" }
            }
            foreach ($call in $function.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
                if (@("Contains", "IndexOf", "StartsWith", "EndsWith", "Match", "IsMatch") -contains [string]$call.Member.Extent.Text) { throw "$name uses a text search: $($call.Extent.Text)" }
            }
        }
    }

    Test-Case "NFR-203 static: exactly one Invoke-RestMethod call in the library, inside Invoke-OllamaHttp, and no other HTTP route, process control or sleep outside the default of -Sleep" {
        $text = [System.IO.File]::ReadAllText($engineLibrary)
        foreach ($literal in @("Microsoft.PowerShell.Utility\Invoke-RestMethod", "Invoke-WebRequest", "System.Net.WebClient", "Net.WebClient", "HttpWebRequest", "HttpClient", "System.Net.WebRequest", "TcpClient", "Start-BitsTransfer")) {
            Assert-True "no $literal" ($text.IndexOf($literal, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)
        }
        $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $rest = @($commands | Where-Object { [string]$_.GetCommandName() -ieq "Invoke-RestMethod" })
        Assert-Equal "Invoke-RestMethod calls" 1 $rest.Count
        $inside = $false
        $parent = $rest[0].Parent
        while ($null -ne $parent) {
            if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $parent.Name -ceq "Invoke-OllamaHttp") { $inside = $true }
            $parent = $parent.Parent
        }
        Assert-True "inside Invoke-OllamaHttp" $inside
        Assert-Equal "alias routes" 0 @($commands | Where-Object { @("irm", "iwr", "curl", "wget") -contains [string]$_.GetCommandName() }).Count
        foreach ($name in @("Start-Process", "Stop-Process", "Restart-Service", "Stop-Service", "Start-Service", "taskkill", "ollama", "Invoke-Expression", "iex", "Invoke-Command")) {
            Assert-Equal "calls to $name" 0 @($commands | Where-Object { [string]$_.GetCommandName() -ieq $name }).Count
        }
        $sleeps = @($commands | Where-Object { @("Start-Sleep", "sleep") -contains [string]$_.GetCommandName() })
        Assert-Equal "Start-Sleep calls" 1 $sleeps.Count
        $sleepInside = $false
        $parent = $sleeps[0].Parent
        while ($null -ne $parent) {
            if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $parent.Name -ceq "Invoke-AgentModel") { $sleepInside = $true }
            $parent = $parent.Parent
        }
        Assert-True "the only Start-Sleep is the default of -Sleep in Invoke-AgentModel" $sleepInside
    }

    Test-Case "FR-204 static: the Invoke-RestMethod call takes only the splatted hashtable, whose members are Uri, Method, TimeoutSec, ContentType and Body (no -ErrorAction, -Headers or other parameter)" {
        $function = $functionAsts["Invoke-OllamaHttp"]
        $call = @($function.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ieq "Invoke-RestMethod" }, $true))[0]
        Assert-Equal "command elements (name and one splat)" 2 $call.CommandElements.Count
        Assert-True "the argument is the splatted variable" ($call.CommandElements[1] -is [System.Management.Automation.Language.VariableExpressionAst] -and $call.CommandElements[1].Splatted)
        $members = @()
        foreach ($table in $function.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
            foreach ($pair in $table.KeyValuePairs) { if ($table.Parent.Parent.Left.Extent.Text -ceq '$arguments') { $members += $pair.Item1.Extent.Text } }
        }
        foreach ($assignment in $function.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Left.Expression.Extent.Text -ceq '$arguments' }, $true)) {
            $members += $assignment.Left.Member.Extent.Text
        }
        Assert-Equal "members of the splat" "Body,ContentType,Method,TimeoutSec,Uri" ((@($members) | Sort-Object) -join ",")
    }

    Test-Case "NFR-203 static: the only catch clauses that build a failure record from an exception type are those of the default transport and of the two callers of an injected transport" {
        $withType = @()
        foreach ($name in $functionAsts.Keys) {
            foreach ($catch in $functionAsts[$name].FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true)) {
                if ($catch.Extent.Text.Contains("exceptionType")) { $withType += $name }
            }
        }
        # Invoke-AgentModel and Test-OllamaModel also wrap a throwing injected transport (FR-204, third bullet)
        Assert-Equal "functions whose catch builds a failure record" "Invoke-AgentModel,Invoke-OllamaHttp,Test-OllamaModel" ((@($withType | Sort-Object -Unique)) -join ",")
        $tryInOllamaHttp = @($functionAsts["Invoke-OllamaHttp"].FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
        Assert-True "Invoke-OllamaHttp has a catch for the call" ($tryInOllamaHttp.Count -ge 1)
    }

    Test-Case "NFR-204 static: no -AsHashtable, no ternary or null-coalescing operator in the library or this suite" {
        foreach ($path in @($engineLibrary, $PSCommandPath)) {
            $text = [System.IO.File]::ReadAllText($path)
            $sourceAst = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
            Assert-Equal "$([System.IO.Path]::GetFileName($path)) parse errors" 0 $errors.Count
            foreach ($command in $sourceAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                if ([string]$command.GetCommandName() -ieq "ConvertFrom-Json") {
                    foreach ($element in $command.CommandElements) {
                        if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -ieq "AsHashtable") { throw "-AsHashtable in $path" }
                    }
                }
            }
            foreach ($token in $tokens) {
                if ($token.Kind -eq [System.Management.Automation.Language.TokenKind]::QuestionMark -or
                    $token.Kind -eq [System.Management.Automation.Language.TokenKind]::QuestionQuestion) { throw "ternary or null-coalescing token in $path" }
            }
        }
    }

    Test-Case "NFR-203 static: ConvertTo-Json depth is at least 10 wherever the engine builds a body" {
        $calls = @($functionAsts["Invoke-AgentModel"].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ieq "ConvertTo-Json" }, $true))
        Assert-True "there is a ConvertTo-Json call" ($calls.Count -ge 1)
        foreach ($call in $calls) { Assert-True "depth 10 in: $($call.Extent.Text)" ($call.Extent.Text -match '-Depth\s+(1\d|[2-9]\d)\b') }
    }

    Test-Case "NFR-203 guards: nothing reached the real transport, and the fake Invoke-RestMethod saw no violation" {
        Assert-Equal "Invoke-OllamaHttp violations" 0 $script:httpViolations
        Assert-Equal "Invoke-RestMethod violations" 0 $script:rest.Violations
    }

    Test-Case "NFR-203 guard 3 proof: with no stub installed the default transport is refused and counted; an unprepared fake Invoke-RestMethod is refused and counted" {
        $before = $script:httpViolations
        $registry = New-TestRegistry -MaxAttempts 1
        $result = Invoke-AgentModel -Execution (Get-TestExecution $registry) -Registry $registry -System "A" -Prompt "B"
        Assert-Equal "the guard stub threw, the engine returned an error" "error" $result.status
        Assert-Equal "category" "transport_other" $result.error.category
        Assert-Equal "violations counted" ($before + 1) $script:httpViolations
        $script:httpViolations = $before

        $restBefore = $script:rest.Violations
        $record = & $realHttp -Request @{ Url = "http://127.0.0.1:9/api/tags"; Method = "Get"; Body = $null; TimeoutSec = 7; Purpose = "tags" }
        Assert-Equal "rest guard: failure record" $false $record.ok
        Assert-Equal "rest violations counted" ($restBefore + 1) $script:rest.Violations
        $script:rest.Handler = { param($uri) "x" }
        $outside = & $realHttp -Request @{ Url = "http://localhost:11434/api/tags"; Method = "Get"; Body = $null; TimeoutSec = 7; Purpose = "tags" }
        Assert-Equal "outside URL refused" $false $outside.ok
        Assert-Equal "outside URL counted" ($restBefore + 2) $script:rest.Violations
        $script:rest.Violations = $restBefore
    }
}
finally {
    Remove-Item Function:\Invoke-OllamaHttp -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "              TEST SUMMARY" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Passed: $script:passed"
Write-Host "Failed: $script:failed"

if ($script:failed -eq 0 -and $script:passed -gt 0) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "STATUS: FAIL" -ForegroundColor Red
exit 1
