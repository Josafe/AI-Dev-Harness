<#
.SYNOPSIS
    Offline child-process suite for run-agent.ps1 and the engine (Phase 2 WP-2D1, split by FR-315).

.DESCRIPTION
    Covers, for run-agent.ps1: AC-201 (script part), AC-202 (failure matrix), AC-203
    (oversized prompt), AC-213 (child-process part), AC-216 (parameter block, exit
    codes), the run-agent cases of the Final QA N-14 and N-15, and AC-322 (the
    deprecated wrappers are gone; not tied to one script, kept here).
    The engine fake host, the four guards, Invoke-Case and the assertion helpers
    live in tests\lib\engine-fake-host.ps1 (FR-315); this suite only holds the cases
    of run-agent.ps1. The case names are compared with tests\fixtures\engine-callsites-cases.txt by
    tests\lib\compare-engine-case-names.ps1 (AC-323).
#>
param()

$ErrorActionPreference = "Stop"

$scriptsDirectory = $PSScriptRoot
. (Join-Path $scriptsDirectory "..\tests\lib\engine-fake-host.ps1")

try {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "   ENGINE CALL-SITE SUITE: run-agent.ps1 (OFFLINE)" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan

    Initialize-EngineSuite

    Write-Host ""
    Write-Host "=== AC-201 (script part): the strings run-agent sends equal the goldens ===" -ForegroundColor Cyan

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
            $run = Invoke-Case -Name $warnCase.Name -ConfigText $warnCase.Config -TaskFile $bigTask -TagsSteps $tagsAlpha -GenerateSteps @((& $okReplyNoCount "Sent in warn mode."))
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

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== Final QA N-14, N-15: the Warning line, the line order of a failure block, the hint of each category ===" -ForegroundColor Cyan

    foreach ($warnOnly in @(
            @{ Key = "run"; Script = "run-agent.ps1"; Answer = "Partial answer."; Agent = "spec" })) {
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
        foreach ($target in @(@{ Key = "run"; Script = "run-agent.ps1" })) {
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
    Restore-EngineSuite
}

Write-EngineSuiteSummary
if ($script:failed -eq 0) { exit 0 }
exit 1
