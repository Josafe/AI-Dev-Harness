<#
.SYNOPSIS
    Offline child-process suite for review-spec.ps1 and the engine (Phase 2 WP-2D2, split by FR-315).

.DESCRIPTION
    Covers, for review-spec.ps1: AC-201 (script part, three modes), FR-203, AC-213
    (child-process part), FR-202, AC-202 (failure matrix), AC-203, AC-214 (telemetry
    record), AC-216 (parameter block, -Mode, hook rules) and the review-spec cases
    of the Final QA N-14 and N-15.
    The engine fake host, the four guards, Invoke-Case and the assertion helpers
    live in tests\lib\engine-fake-host.ps1 (FR-315); this suite only holds the cases
    of review-spec.ps1. The case names are compared with tests\fixtures\engine-callsites-cases.txt by
    tests\lib\compare-engine-case-names.ps1 (AC-323).
#>
param()

$ErrorActionPreference = "Stop"

$scriptsDirectory = $PSScriptRoot
. (Join-Path $scriptsDirectory "..\tests\lib\engine-fake-host.ps1")

try {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "   ENGINE CALL-SITE SUITE: review-spec.ps1 (OFFLINE)" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan

    Initialize-EngineSuite

    # FR-315: the loops below build cases for both scripts; this suite keeps one.
    $allSubjects = $subjects
    $subjects = @($subjects | Where-Object { $_.Key -ceq "review" })

    Write-Host ""
    Write-Host "=== AC-201 (script part): the strings review-spec and revise-spec send equal the goldens (three modes each) ===" -ForegroundColor Cyan

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
                $run = Invoke-Case -Name "$($subject.Key)-$($warnCase.Name)" -ConfigText $warnCase.Config -Script $subject.Script -TaskFile $bigTask -TagsSteps $tagsAlpha -GenerateSteps @((& $okReplyNoCount $subject.Answer))
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


    foreach ($warnOnly in @(
            @{ Key = "review"; Script = "review-spec.ps1"; Answer = $reviewPass; Agent = "spec-reviewer" })) {
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


    foreach ($hintCase in @(
            @{ Name = "reset"; Steps = @((New-Step "status" @{ webStatus = "ReceiveFailure" })); Repeat = $true; Typed = $true; Tags = $tagsAlpha; Category = "transport_reset"; Phrase = "dropped" },
            @{ Name = "4xx"; Steps = @((New-Step "http" @{ status = 400; body = '{"error":"bad"}' })); Repeat = $false; Typed = $true; Tags = $tagsAlpha; Category = "http_4xx"; Phrase = "Ollama rejected the request" },
            @{ Name = "empty"; Steps = @((New-Step "ok" @{ response = " "; doneReason = "stop" })); Repeat = $false; Typed = $false; Tags = $tagsAlpha; Category = "empty_response"; Phrase = "empty answer" },
            @{ Name = "exhausted"; Steps = @((New-Step "ok" @{ response = ""; doneReason = "length" })); Repeat = $false; Typed = $false; Tags = $tagsAlpha; Category = "thinking_budget_exhausted"; Phrase = "reasoning" },
            @{ Name = "other"; Steps = @((New-Step "plain")); Repeat = $false; Typed = $false; Tags = $tagsAlpha; Category = "transport_other"; Phrase = "does not classify" },
            @{ Name = "unreachable"; Steps = @(); Repeat = $false; Typed = $true; Tags = @((New-Step "status" @{ webStatus = "ConnectFailure" })); Category = "transport_unreachable"; Phrase = "Ollama server is running" },
            @{ Name = "tags-timeout"; Steps = @(); Repeat = $false; Typed = $true; Tags = @((New-Step "status" @{ webStatus = "Timeout" })); Category = "timeout"; Phrase = "timeoutSec" },
            @{ Name = "not-installed"; Steps = @(); Repeat = $false; Typed = $false; Tags = @((New-Step "ok" @{ models = @("other-model") })); Category = "model_not_installed"; Phrase = "ollama pull" })) {
        foreach ($target in @(@{ Key = "review"; Script = "review-spec.ps1" })) {
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
        foreach ($target in @(@{ Key = "review"; Script = "review-spec.ps1" })) {
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

    Test-Case "AC-216 review-spec and revise-spec reject a -Mode outside the ValidateSet before any request or record" {
        foreach ($subject in $allSubjects) {
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
}
finally {
    Restore-EngineSuite
}

Write-EngineSuiteSummary
if ($script:failed -eq 0) { exit 0 }
exit 1
