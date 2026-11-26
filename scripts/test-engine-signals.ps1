<#
.SYNOPSIS
    Offline suite for the Phase 3 engine signals (work package A4): the truncation
    warning, the model_load_failed category and Test-OllamaModelLoad.
    FR-316, FR-317, FR-318 (library half), AC-331, AC-332 and the library half of AC-333.

.DESCRIPTION
    Two parts, one fake host (tests\lib\engine-fake-host.ps1, FR-315):
      - in-process: Invoke-AgentModel, Get-AgentErrorCategory and Test-OllamaModelLoad
        with an injected fake transport (tests\mocks\fake-transport.ps1) and an injected
        -Sleep; nothing sleeps, the default transport is never reached;
      - child-process: run-agent.ps1, review-spec.ps1 and revise-spec.ps1 in the engine
        fake host (the four guards of FR-315 run at startup and before every case).
    No Ollama, no network. Expected values are literals worked out by hand from the
    spec (AC-331 and AC-332 name every number), never computed with the code under test.
    The case names are not part of the AC-323 reference list: this suite is not one of
    the three call-site suites.
#>
param()

$ErrorActionPreference = "Stop"

$scriptsDirectory = $PSScriptRoot
. (Join-Path $scriptsDirectory "..\tests\lib\engine-fake-host.ps1")
. (Join-Path $scriptsDirectory "lib\config.ps1")
. (Join-Path $scriptsDirectory "lib\telemetry.ps1")
. (Join-Path $scriptsDirectory "lib\agent-exec.ps1")
. (Join-Path $mocksDirectory "fake-web-response.ps1")
. (Join-Path $mocksDirectory "fake-transport.ps1")

# In-process guard: the default transport must never be reached by this suite.
$script:httpViolations = 0
function Invoke-OllamaHttp {
    param($Request)
    $script:httpViolations++
    throw "violation: Invoke-OllamaHttp was called by an offline in-process case"
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

# A normalized v2 registry: alpha (window 16384, reserved 8192, timeout 44) and delta
# (no window, no options). maxAttempts 2 and backoff 5 s, so a retry is visible.
function New-SignalRegistry {
    param([bool]$Warmup = $false)

    $config = [ordered]@{
        schemaVersion = 2
        ollama        = [ordered]@{ url = "http://127.0.0.1:9"; healthTimeoutSec = 7; maxAttempts = 2; retryBackoffSec = 5; warmup = $Warmup }
        defaults      = [ordered]@{ profile = "alpha"; timeoutSec = 600; safetyMarginRatio = 0.1; stripThinking = $true; charsPerToken = 4 }
        profiles      = [ordered]@{
            alpha = [ordered]@{ model = "m-alpha"; contextWindow = 16384; reservedOutputTokens = 8192; timeoutSec = 44; options = [ordered]@{ temperature = 0.2 } }
            delta = [ordered]@{ model = "m-delta" }
        }
        agents        = [ordered]@{
            "a-alpha" = [ordered]@{ profile = "alpha" }
            "a-delta" = [ordered]@{ profile = "delta" }
        }
    }
    $parsed = ($config | ConvertTo-Json -Depth 10) | ConvertFrom-Json
    return ConvertTo-HarnessRegistry -Config $parsed
}

$script:inProcessCase = 0
function New-InProcessRoot {
    $script:inProcessCase++
    $path = Join-Path $tempRoot ("inproc" + $script:inProcessCase)
    [void][System.IO.Directory]::CreateDirectory($path)
    return $path
}

function Read-Records {
    param([string]$CaseRoot)

    $path = Join-Path $CaseRoot "logs\model-calls.jsonl"
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { $_ | ConvertFrom-Json })
}

function New-SleepRecorder {
    $list = New-Object 'System.Collections.Generic.List[int]'
    $block = { param($Seconds) $list.Add([int]$Seconds) }.GetNewClosure()
    return [pscustomobject]@{ Sleep = $block; List = $list }
}

function New-RetryRecorder {
    $list = New-Object 'System.Collections.Generic.List[string]'
    $block = { param($Attempt, $Max, $Category, $Wait) $list.Add("$Attempt|$Max|$Category|$Wait") }.GetNewClosure()
    return [pscustomobject]@{ OnRetry = $block; List = $list }
}

# One engine call on the fake transport; the engine never really sleeps here.
function Invoke-Signal {
    param($Registry, $Fake, [string]$System = "AB", [string]$Prompt = "CDE", [string]$Agent = "a-alpha", [string]$TelemetryRoot = "", $Sleeper = $null, $Retry = $null)

    Reset-AgentExecState
    $execution = Resolve-HarnessExecution -Agent $Agent -Registry $Registry
    if ($null -eq $Sleeper) { $Sleeper = New-SleepRecorder }
    $arguments = @{ Execution = $execution; Registry = $Registry; System = $System; Prompt = $Prompt; Transport = $Fake.Transport; Sleep = $Sleeper.Sleep }
    if ($TelemetryRoot.Length -gt 0) { $arguments.TelemetryRoot = $TelemetryRoot }
    if ($null -ne $Retry) { $arguments.OnRetry = $Retry.OnRetry }
    return Invoke-AgentModel @arguments
}

# A system plus prompt of exactly this many characters.
function Invoke-SignalChars {
    param($Registry, $Fake, [int]$Chars, [string]$TelemetryRoot = "")
    return (Invoke-Signal -Registry $Registry -Fake $Fake -System ("s" * ($Chars - 10)) -Prompt ("p" * 10) -TelemetryRoot $TelemetryRoot)
}

# The two truncation codes of a result, in the order the engine added them.
function Get-SignalCodes {
    param($Result)
    return ((@($Result.meta.warnings) | Where-Object { $_ -ceq "possible_prompt_truncation" -or $_ -ceq "prompt_truncation_detected" }) -join ",")
}

function New-Fail {
    param([int]$Status, [string]$Body)
    return (New-FakeFailureRecord -WebStatus "ProtocolError" -HttpStatus $Status -Body $Body)
}

$old = "possible_prompt_truncation"
$new = "prompt_truncation_detected"

try {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "   ENGINE SIGNALS SUITE (OFFLINE, PHASE 3 A4)" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan

    Initialize-EngineSuite

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-331 (engine): the truncation signal ===" -ForegroundColor Cyan

    Test-Case "AC-331 the rows of the spec: C 16384, R 8192, promptChars / prompt_eval_count give the literal warnings" {
        $registry = New-SignalRegistry
        $rows = @(
            @{ Chars = 85957; N = 8194; Codes = "$old,$new" },
            @{ Chars = 41770; N = 8573; Codes = "$old" },
            @{ Chars = 44784; N = 9237; Codes = "$old" },
            @{ Chars = 26431; N = 4986; Codes = "" },
            @{ Chars = 29247; N = 5384; Codes = "" },
            @{ Chars = 14776; N = 3116; Codes = "" },
            @{ Chars = 22123; N = 5627; Codes = "" },
            @{ Chars = 7000; N = 1000; Codes = "" },
            @{ Chars = 7001; N = 1000; Codes = "$new" }
        )
        foreach ($row in $rows) {
            $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response (New-FakeGenerateResponse -Text "fine" -PromptEvalCount $row.N)))
            $result = Invoke-SignalChars -Registry $registry -Fake $fake -Chars $row.Chars
            Assert-Equal "status for $($row.Chars) / $($row.N) (a warning never changes the outcome, RN-3)" "ok" $result.status
            Assert-Equal "promptChars for $($row.Chars) / $($row.N)" $row.Chars $result.meta.promptChars
            Assert-Equal "codes for $($row.Chars) / $($row.N)" $row.Codes (Get-SignalCodes $result)
        }
    }

    Test-Case "AC-331 a prompt_eval_count that is absent, 0, -1, the string 8194, NaN, a boolean, an array or an object adds no new warning and never throws (promptChars 85957)" {
        $registry = New-SignalRegistry
        $values = [ordered]@{
            "absent"  = "<absent>"
            "zero"    = 0
            "minus 1" = -1
            "string"  = "8194"
            "NaN"     = [double]::NaN
            "boolean" = $true
            "array"   = @(1, 2)
            "object"  = ([pscustomobject]@{ a = 1 })
        }
        foreach ($label in $values.Keys) {
            $response = New-FakeGenerateResponse -Text "fine" -PromptEvalCount 1
            if ($values[$label] -is [string] -and $values[$label] -ceq "<absent>") { $response.PSObject.Properties.Remove("prompt_eval_count") }
            else { $response.prompt_eval_count = $values[$label] }
            $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response $response))
            $caseRoot = New-InProcessRoot
            $result = Invoke-SignalChars -Registry $registry -Fake $fake -Chars 85957 -TelemetryRoot $caseRoot
            Assert-Equal "status ($label)" "ok" $result.status
            Assert-Equal "no truncation code ($label)" "" (Get-SignalCodes $result)
            Assert-Equal "one record ($label)" 1 (@(Read-Records $caseRoot)).Count
        }
    }

    Test-Case "AC-331 the telemetry warnings column holds the same codes as meta.warnings (live truncation row and the 7001 / 1000 row)" {
        $registry = New-SignalRegistry
        foreach ($row in @(@{ Chars = 85957; N = 8194; Column = "budget_exceeded;$old;$new" }, @{ Chars = 7001; N = 1000; Column = "$new" })) {
            $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response (New-FakeGenerateResponse -Text "fine" -PromptEvalCount $row.N)))
            $caseRoot = New-InProcessRoot
            $result = Invoke-SignalChars -Registry $registry -Fake $fake -Chars $row.Chars -TelemetryRoot $caseRoot
            Assert-Equal "meta.warnings $($row.Chars)" ($row.Column.Replace(";", ",")) ($result.meta.warnings -join ",")
            Assert-Equal "record warnings $($row.Chars)" $row.Column (@(Read-Records $caseRoot))[0].warnings
        }
    }

    Test-Case "AC-331 a decimal or double prompt_eval_count is a real number: 1000.0 against 7001 characters warns, 1001.0 does not" {
        $registry = New-SignalRegistry
        foreach ($row in @(@{ N = [double]1000; Codes = "$new" }, @{ N = [decimal]1001; Codes = "" })) {
            $response = New-FakeGenerateResponse -Text "fine"
            $response.prompt_eval_count = $row.N
            $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response $response))
            Assert-Equal "codes for $($row.N)" $row.Codes (Get-SignalCodes (Invoke-SignalChars -Registry $registry -Fake $fake -Chars 7001))
        }
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-332 (engine): model_load_failed ===" -ForegroundColor Cyan

    Test-Case "AC-332 the three load failures: one attempt, no sleep, no OnRetry, model_load_failed, not retryable, the hint, one record" {
        $registry = New-SignalRegistry
        $cases = @(
            @{ Status = 500; Body = '{"error":"llama-server process has terminated: exit status 0xc0000409"}' },
            @{ Status = 500; Body = '{"error":"model runner: Load failed (resource limit)"}' },
            @{ Status = 503; Body = '{"error":"CUDA error: out of memory"}' }
        )
        foreach ($case in $cases) {
            $fake = New-FakeTransport -Steps @((New-Fail $case.Status $case.Body)) -RepeatLast
            $sleeper = New-SleepRecorder
            $retry = New-RetryRecorder
            $caseRoot = New-InProcessRoot
            $result = Invoke-Signal -Registry $registry -Fake $fake -Sleeper $sleeper -Retry $retry -TelemetryRoot $caseRoot
            Assert-Equal "status $($case.Status)" "error" $result.status
            Assert-Equal "category $($case.Status)" "model_load_failed" $result.error.category
            Assert-Equal "retryable $($case.Status)" $false $result.error.retryable
            Assert-Equal "error.attempts $($case.Status)" 1 $result.error.attempts
            Assert-Equal "meta.attempts $($case.Status)" 1 $result.meta.attempts
            Assert-Equal "http status $($case.Status)" $case.Status $result.error.httpStatus
            Assert-Equal "generate requests $($case.Status)" 1 $fake.Count("generate")
            Assert-Equal "sleeps $($case.Status)" 0 $sleeper.List.Count
            Assert-Equal "OnRetry calls $($case.Status)" 0 $retry.List.Count
            Assert-True "hint names the restart" ($result.error.hint.IndexOf("Restarting the Ollama server", [System.StringComparison]::Ordinal) -ge 0)
            Assert-True "hint names the reboot" ($result.error.hint.IndexOf("rebooting the machine", [System.StringComparison]::Ordinal) -ge 0)
            $records = @(Read-Records $caseRoot)
            Assert-Equal "records $($case.Status)" 1 $records.Count
            Assert-Equal "record error_category $($case.Status)" "model_load_failed" $records[0].error_category
            Assert-Equal "record attempts $($case.Status)" 1 $records[0].attempts
        }
    }

    Test-Case "AC-332 the discriminator: other 5xx, other statuses and other texts keep their Phase 2 category (and a 5xx plain error still retries: maxAttempts requests, one wait of 5 s)" {
        $registry = New-SignalRegistry
        $cases = @(
            @{ Name = "internal server error"; Status = 500; Body = '{"error":"internal server error"}'; Category = "http_5xx"; Requests = 2; Sleeps = "5" },
            @{ Name = "400 with the marker"; Status = 400; Body = '{"error":"Load failed"}'; Category = "http_4xx"; Requests = 1; Sleeps = "" },
            @{ Name = "lower case load failed"; Status = 500; Body = '{"error":"load failed"}'; Category = "http_5xx"; Requests = 2; Sleeps = "5" },
            @{ Name = "plain body Load failed"; Status = 500; Body = "Load failed"; Category = "http_5xx"; Requests = 2; Sleeps = "5" },
            @{ Name = "lower case cuda error"; Status = 500; Body = '{"error":"cuda error"}'; Category = "http_5xx"; Requests = 2; Sleeps = "5" },
            @{ Name = "marker in another member"; Status = 500; Body = '{"error":"boom","detail":"CUDA error"}'; Category = "http_5xx"; Requests = 2; Sleeps = "5" },
            @{ Name = "error is not a string"; Status = 500; Body = '{"error":{"text":"CUDA error"}}'; Category = "http_5xx"; Requests = 2; Sleeps = "5" },
            @{ Name = "marker past 500 characters"; Status = 500; Body = ('{"error":"' + ("x" * 600) + 'CUDA error"}'); Category = "model_load_failed"; Requests = 1; Sleeps = "" }
        )
        foreach ($case in $cases) {
            $fake = New-FakeTransport -Steps @((New-Fail $case.Status $case.Body)) -RepeatLast
            $sleeper = New-SleepRecorder
            $result = Invoke-Signal -Registry $registry -Fake $fake -Sleeper $sleeper
            Assert-Equal "category ($($case.Name))" $case.Category $result.error.category
            Assert-Equal "requests ($($case.Name))" $case.Requests $fake.Count("generate")
            Assert-Equal "sleeps ($($case.Name))" $case.Sleeps ($sleeper.List -join ",")
        }
    }

    Test-Case "AC-332 the classifier by itself: the hints of http_5xx and transport_reset are not reworded (RN-16), the new hint is its own text, and the new category is by name not retryable" {
        $retryText = "A model request is repeated up to ollama.maxAttempts times; the availability check is asked once. If the Ollama log shows a GPU or CUDA initialization error, restarting the Ollama server usually clears it."
        Assert-Equal "http_5xx hint" ("The Ollama server answered with a server error. " + $retryText) (Get-AgentErrorCategory -Category "http_5xx").hint
        Assert-Equal "transport_reset hint" ("The connection to Ollama was dropped. " + $retryText) (Get-AgentErrorCategory -Category "transport_reset").hint
        $named = Get-AgentErrorCategory -Category "model_load_failed"
        Assert-Equal "by name: category" "model_load_failed" $named.category
        Assert-Equal "by name: retryable" $false $named.retryable
        Assert-True "the hint is one line of ASCII" ($named.hint -cmatch '^[\x20-\x7E]+$')
        $failure = [pscustomobject]@{ exceptionType = "System.Net.WebException"; webStatus = "ProtocolError"; body = '{"error":"CUDA error: out of memory"}' }
        $classified = Get-AgentErrorCategory -Failure $failure -HttpStatus 500
        Assert-Equal "classified: category" "model_load_failed" $classified.category
        Assert-Equal "classified: hint equals the hint by name" $named.hint $classified.hint
        Assert-Equal "classified: detail is the server text" "CUDA error: out of memory" $classified.detail
        # A transport failure without a status is never read for the marker.
        $reset = [pscustomobject]@{ exceptionType = "System.IO.IOException"; webStatus = $null; body = '{"error":"CUDA error"}' }
        Assert-Equal "transport_reset stays" "transport_reset" (Get-AgentErrorCategory -Failure $reset).category
    }

    Test-Case "AC-332 the same rule holds for a warm-up request: model_load_failed, one attempt, one warm-up request, no generation" {
        $registry = New-SignalRegistry -Warmup $true
        $fake = New-FakeTransport -Steps @((New-Fail 500 '{"error":"CUDA error: unspecified launch failure"}')) -RepeatLast
        $sleeper = New-SleepRecorder
        $caseRoot = New-InProcessRoot
        $result = Invoke-Signal -Registry $registry -Fake $fake -Sleeper $sleeper -TelemetryRoot $caseRoot
        Assert-Equal "status" "error" $result.status
        Assert-Equal "category" "model_load_failed" $result.error.category
        Assert-Equal "attempts" 1 $result.error.attempts
        Assert-Equal "warm-up requests" 1 $fake.Count("warmup")
        Assert-Equal "generate requests" 0 $fake.Count("generate")
        Assert-Equal "sleeps" 0 $sleeper.List.Count
        Assert-Equal "warm-up state" "failed" $result.meta.warmup.state
        Assert-Equal "warm-up category" "model_load_failed" $result.meta.warmup.category
        Assert-Equal "record error_category" "model_load_failed" (@(Read-Records $caseRoot))[0].error_category
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-333 (library half): Test-OllamaModelLoad ===" -ForegroundColor Cyan

    Test-Case "AC-333 a load check sends one request with only model, options (num_ctx = the contextWindow) and stream false; no prompt, no keep_alive; the profile's timeout; loaded true" {
        $registry = New-SignalRegistry
        $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response ([pscustomobject]@{ done = $true })))
        Reset-AgentExecState
        $execution = Resolve-HarnessExecution -Agent "a-alpha" -Registry $registry
        $answer = Test-OllamaModelLoad -Execution $execution -Registry $registry -Transport $fake.Transport
        Assert-Equal "result members" "loaded,category,hint,durationMs" ((@($answer.PSObject.Properties | ForEach-Object { $_.Name })) -join ",")
        Assert-Equal "loaded" $true $answer.loaded
        Assert-True "no category" ($null -eq $answer.category)
        Assert-True "no hint" ($null -eq $answer.hint)
        Assert-True "a duration" ($answer.durationMs -ge 0)
        Assert-Equal "requests" 1 $fake.Count("")
        $call = $fake.Calls[0]
        Assert-Equal "url" "http://127.0.0.1:9/api/generate" $call.Url
        Assert-Equal "method" "Post" $call.Method
        Assert-Equal "purpose" "warmup" $call.Purpose
        Assert-Equal "timeout" 44 $call.TimeoutSec
        Assert-Equal "members" "model,options,stream" ((@($call.Body.PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object) -join ",")
        Assert-Equal "model" "m-alpha" $call.Body.model
        Assert-Equal "num_ctx" 16384 $call.Body.options.num_ctx
        Assert-Equal "temperature" "0.2" $call.Body.options.temperature
        Assert-True "stream is the boolean false" ($call.Body.stream -is [bool] -and -not $call.Body.stream)
        Assert-True "the body bytes were sent as bytes" ($call.BodyText.Length -gt 0)
    }

    Test-Case "AC-333 a profile without options sends only model and stream; the function has no telemetry parameter and no retry or keep_alive text" {
        $registry = New-SignalRegistry
        $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response ([pscustomobject]@{ done = $true })))
        Reset-AgentExecState
        $execution = Resolve-HarnessExecution -Agent "a-delta" -Registry $registry
        $null = Test-OllamaModelLoad -Execution $execution -Registry $registry -Transport $fake.Transport
        Assert-Equal "members" "model,stream" ((@($fake.Calls[0].Body.PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object) -join ",")
        $parameters = @((Get-Command Test-OllamaModelLoad).Parameters.Keys)
        Assert-True "no -TelemetryRoot" ($parameters -cnotcontains "TelemetryRoot")
        $text = (Get-Command Test-OllamaModelLoad).ScriptBlock.ToString()
        Assert-True "no keep_alive in the function" ($text.IndexOf("keep_alive", [System.StringComparison]::OrdinalIgnoreCase) -lt 0)
        Assert-True "no Write-HarnessModelTelemetry in the function" ($text.IndexOf("Write-HarnessModelTelemetry", [System.StringComparison]::Ordinal) -lt 0)
    }

    Test-Case "AC-333 a 500 CUDA error body: loaded false, model_load_failed, the hint, exactly one request (maxAttempts is 2, and a plain 500 is not repeated either)" {
        $registry = New-SignalRegistry
        Reset-AgentExecState
        $execution = Resolve-HarnessExecution -Agent "a-alpha" -Registry $registry
        $fake = New-FakeTransport -Steps @((New-Fail 500 '{"error":"CUDA error: out of memory"}')) -RepeatLast
        $answer = Test-OllamaModelLoad -Execution $execution -Registry $registry -Transport $fake.Transport
        Assert-Equal "loaded" $false $answer.loaded
        Assert-Equal "category" "model_load_failed" $answer.category
        Assert-True "the FR-317 hint" ($answer.hint.IndexOf("Restarting the Ollama server", [System.StringComparison]::Ordinal) -ge 0 -and $answer.hint.IndexOf("rebooting the machine", [System.StringComparison]::Ordinal) -ge 0)
        Assert-Equal "requests" 1 $fake.Count("")
        $plain = New-FakeTransport -Steps @((New-Fail 500 '{"error":"internal server error"}')) -RepeatLast
        $other = Test-OllamaModelLoad -Execution $execution -Registry $registry -Transport $plain.Transport
        Assert-Equal "plain 500 category" "http_5xx" $other.category
        Assert-Equal "plain 500 requests (one attempt)" 1 $plain.Count("")
    }

    Test-Case "AC-333 a thrown transport, a result that is no record and a transport failure are classified, never thrown" {
        $registry = New-SignalRegistry
        Reset-AgentExecState
        $execution = Resolve-HarnessExecution -Agent "a-alpha" -Registry $registry
        $thrown = New-FakeTransport -Steps @((New-Object System.IO.IOException "dropped"))
        Assert-Equal "thrown IOException" "transport_reset" (Test-OllamaModelLoad -Execution $execution -Registry $registry -Transport $thrown.Transport).category
        $junk = New-FakeTransport -Steps @("not a record")
        $junkAnswer = Test-OllamaModelLoad -Execution $execution -Registry $registry -Transport $junk.Transport
        Assert-Equal "junk loaded" $false $junkAnswer.loaded
        Assert-Equal "junk category" "transport_other" $junkAnswer.category
        $refused = New-FakeTransport -Steps @((New-FakeFailureRecord -WebStatus "ConnectFailure"))
        Assert-Equal "connection refused" "transport_unreachable" (Test-OllamaModelLoad -Execution $execution -Registry $registry -Transport $refused.Transport).category
        $timeout = New-FakeTransport -Steps @((New-FakeFailureRecord -WebStatus "Timeout"))
        Assert-Equal "timeout" "timeout" (Test-OllamaModelLoad -Execution $execution -Registry $registry -Transport $timeout.Transport).category
    }

    Test-Case "AC-333 programmer errors throw invalid_arguments: an execution without a model, a registry without a url, a blank model" {
        $registry = New-SignalRegistry
        Reset-AgentExecState
        $execution = Resolve-HarnessExecution -Agent "a-alpha" -Registry $registry
        $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response ([pscustomobject]@{ done = $true })))
        Assert-Throws "no model member" { Test-OllamaModelLoad -Execution ([pscustomobject]@{ timeoutSec = 1; options = $null }) -Registry $registry -Transport $fake.Transport } "invalid_arguments:"
        Assert-Throws "no url" { Test-OllamaModelLoad -Execution $execution -Registry ([pscustomobject]@{ ollama = [pscustomobject]@{} }) -Transport $fake.Transport } "invalid_arguments:"
        Assert-Throws "blank model" { Test-OllamaModelLoad -Execution ([pscustomobject]@{ model = " "; timeoutSec = 1; options = $null }) -Registry $registry -Transport $fake.Transport } "invalid_arguments:"
        Assert-Equal "nothing was sent" 0 $fake.Count("")
    }

    Test-Case "the in-process cases never reached the default transport" {
        Assert-Equal "Invoke-OllamaHttp violations" 0 $script:httpViolations
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-331 and AC-332 (child process): run-agent.ps1, review-spec.ps1, revise-spec.ps1 ===" -ForegroundColor Cyan

    $targets = @(@{ Key = "run"; Script = "run-agent.ps1"; Agent = "spec"; Label = "run-agent"; Answer = "Fake agent response." }) + @($subjects)

    foreach ($target in $targets) {
        $key = $target.Key
        $label = $target.Label

        Test-Case "AC-331 $label prints Warning: prompt_truncation_detected when answered with n 1, and none when answered with n = prompt_chars / 5; the outcome is the same" {
            $reply = { param($Count) (New-Step "ok" @{ response = $target.Answer; doneReason = "stop"; promptEvalCount = $Count }) }
            $first = Invoke-Case -Name "$key-sig-n1" -ConfigText (New-V2Config) -Script $target.Script -TaskFile $taskPath -TagsSteps $tagsAlpha -GenerateSteps @((& $reply 1))
            Assert-Guards $first
            Assert-Equal "exit code" 0 $first.ExitCode
            Assert-Equal "warning lines" 1 @($first.Lines | Where-Object { $_.StartsWith("Warning: prompt_truncation_detected", [System.StringComparison]::Ordinal) }).Count
            Assert-OneRecord $first "success" "" $true -Agent $target.Agent
            Assert-True "the record carries the code" ($first.Telemetry[0].warnings.Contains("prompt_truncation_detected"))
            $chars = [long]$first.Telemetry[0].prompt_chars
            Assert-True "a real prompt length" ($chars -gt 100)
            $count = [long][math]::Floor($chars / 5)
            $second = Invoke-Case -Name "$key-sig-n5" -ConfigText (New-V2Config) -Script $target.Script -TaskFile $taskPath -TagsSteps $tagsAlpha -GenerateSteps @((& $reply $count))
            Assert-Guards $second
            Assert-Equal "exit code" 0 $second.ExitCode
            Assert-Equal "prompt_chars is the same" $chars ([long]$second.Telemetry[0].prompt_chars)
            Assert-NoLine $second "Warning: prompt_truncation_detected"
            Assert-Equal "warnings column" "" $second.Telemetry[0].warnings
        }

        Test-Case "AC-331 $label prints the weak possible_prompt_truncation line too (RN-2), after the budget_exceeded line, and the new line follows the budget line" {
            # tiny window 1000, reserved 100: n 1 is far below chars / 7 (new warning); n 900 = C - R (old warning)
            $reply = { param($Count) (New-Step "ok" @{ response = $target.Answer; doneReason = "stop"; promptEvalCount = $Count }) }
            $strong = Invoke-Case -Name "$key-sig-order-new" -ConfigText $tinyWarn -Script $target.Script -TaskFile $bigTask -TagsSteps $tagsAlpha -GenerateSteps @((& $reply 1))
            Assert-Guards $strong
            Assert-Equal "exit code" 0 $strong.ExitCode
            $budgetIndex = [array]::IndexOf(@($strong.Lines | ForEach-Object { $_.StartsWith("Warning: budget_exceeded", [System.StringComparison]::Ordinal) }), $true)
            $newIndex = [array]::IndexOf(@($strong.Lines | ForEach-Object { $_.StartsWith("Warning: prompt_truncation_detected", [System.StringComparison]::Ordinal) }), $true)
            Assert-True "both lines exist" ($budgetIndex -ge 0 -and $newIndex -ge 0)
            Assert-True "the new line is after the budget line" ($newIndex -gt $budgetIndex)
            Assert-Equal "warnings column" "budget_exceeded;prompt_truncation_detected" $strong.Telemetry[0].warnings

            $weak = Invoke-Case -Name "$key-sig-order-old" -ConfigText $tinyWarn -Script $target.Script -TaskFile $bigTask -TagsSteps $tagsAlpha -GenerateSteps @((& $reply 900))
            Assert-Guards $weak
            Assert-Equal "exit code" 0 $weak.ExitCode
            $oldIndex = [array]::IndexOf(@($weak.Lines | ForEach-Object { $_.StartsWith("Warning: possible_prompt_truncation", [System.StringComparison]::Ordinal) }), $true)
            $budgetWeak = [array]::IndexOf(@($weak.Lines | ForEach-Object { $_.StartsWith("Warning: budget_exceeded", [System.StringComparison]::Ordinal) }), $true)
            Assert-True "the old line exists and follows the budget line" ($oldIndex -gt $budgetWeak -and $budgetWeak -ge 0)
            Assert-True "the old line says it is weak" (@($weak.Lines | Where-Object { $_.StartsWith("Warning: possible_prompt_truncation", [System.StringComparison]::Ordinal) -and $_.Contains("weak") }).Count -eq 1)
            Assert-True "the record carries the old code" ($weak.Telemetry[0].warnings.Contains("possible_prompt_truncation"))
        }

        $loadBodies = @(
            @{ Index = 1; Status = 500; Body = '{"error":"llama-server process has terminated: exit status 0xc0000409"}' },
            @{ Index = 2; Status = 500; Body = '{"error":"... Load failed ..."}' },
            @{ Index = 3; Status = 503; Body = '{"error":"CUDA error: out of memory"}' }
        )
        foreach ($loadBody in $loadBodies) {
            Test-Case "AC-332 $label HTTP $($loadBody.Status) load failure ($($loadBody.Index)): one request, no Retrying line, Category model_load_failed and the hint, the failure exit, one record" {
                $run = Invoke-Case -Name "$key-ml-$($loadBody.Index)" -ConfigText $matrixConfig -Script $target.Script -TaskFile $taskPath -TagsSteps $tagsAlpha -GenerateSteps @((New-Step "http" @{ status = $loadBody.Status; body = $loadBody.Body })) -RepeatLastGenerate -TypedExceptions
                Assert-Guards $run
                if ($key -ceq "run") { Assert-Equal "exit code" 1 $run.ExitCode } else { Assert-SubjectFailureExit $target $run }
                Assert-Equal "generate calls" 1 (@(Get-Generations $run).Count)
                Assert-NoLine $run "Retrying (attempt"
                Assert-CategoryHint $run "model_load_failed" "Restarting the Ollama server"
                Assert-Line $run "rebooting the machine"
                Assert-True "no output file" ($null -eq $run.Output)
                Assert-OneRecord $run "error" "model_load_failed" $true -Agent $target.Agent
                Assert-Equal "attempts" 1 $run.Telemetry[0].attempts
                Assert-Equal "http_status" $loadBody.Status $run.Telemetry[0].http_status
            }
        }
    }
}
finally {
    Restore-EngineSuite
}

Write-EngineSuiteSummary
if ($script:failed -eq 0) { exit 0 }
exit 1
