# Test double: an injectable transport for in-process tests
# (Phase 2, WP-2B2; FR-204, FR-218 scope per M-5, AC-208 to AC-213).
#
# A transport is a script block taking -Request (a hashtable with Url, Method,
# Body as UTF-8 bytes or $null, TimeoutSec and Purpose: generate, warmup or tags)
# and returning a record: ok, response, httpStatus, failure. This file builds
# such transports from a list of steps and records every request. It sends
# nothing, opens no socket and writes no file; dot-sourcing it only defines
# functions.
#
# A step is one of:
#   - a record from New-FakeOkRecord or New-FakeFailureRecord (returned as is);
#   - a [System.Exception] (thrown, to model a transport that throws);
#   - a script block, called with the request, whose result is returned.
# Steps are used in order. When they run out, the last step repeats if
# -RepeatLast was given; otherwise the transport throws a plain exception and
# the call is recorded as unexpected.

# A successful transport record.
function New-FakeOkRecord {
    param($Response = $null, $HttpStatus = 200)

    return [pscustomobject][ordered]@{
        ok         = $true
        response   = $Response
        httpStatus = $HttpStatus
        failure    = $null
    }
}

# A failed transport record: failure.exceptionType (full type name), webStatus
# (WebExceptionStatus name or $null), body (text or $null, at most 4096 chars).
# -Message is a display-only member (OQ-214); nothing may decide on it.
function New-FakeFailureRecord {
    param(
        [string]$ExceptionType = "System.Net.WebException",
        $WebStatus = $null,
        $HttpStatus = $null,
        [AllowNull()][string]$Body = $null,
        [string]$Message = "fake failure"
    )

    return [pscustomobject][ordered]@{
        ok         = $false
        response   = $null
        httpStatus = $HttpStatus
        failure    = [pscustomobject][ordered]@{
            exceptionType = $ExceptionType
            webStatus     = $WebStatus
            body          = $Body
            message       = $Message
        }
    }
}

# An Ollama-like /api/generate response object.
function New-FakeGenerateResponse {
    param(
        [string]$Text = "answer",
        [AllowNull()][string]$Thinking = $null,
        [string]$DoneReason = "stop",
        [long]$PromptEvalCount = 10,
        [long]$EvalCount = 5
    )

    $response = [ordered]@{
        model                = "fake-model"
        response             = $Text
        done                 = $true
        done_reason          = $DoneReason
        total_duration       = 1000
        load_duration        = 100
        prompt_eval_count    = $PromptEvalCount
        prompt_eval_duration = 200
        eval_count           = $EvalCount
        eval_duration        = 300
    }
    if ($null -ne $Thinking) { $response["thinking"] = $Thinking }
    return [pscustomobject]$response
}

# An Ollama-like /api/tags response object.
function New-FakeTagsResponse {
    param([string[]]$Models = @())

    return [pscustomobject]@{ models = @($Models | ForEach-Object { [pscustomobject]@{ name = [string]$_ } }) }
}

# Builds a transport. Returns an object with:
#   Transport  the script block to pass as -Transport;
#   Calls      a list of the requests seen, each with Url, Method, Purpose,
#              TimeoutSec, BodyText (decoded UTF-8 or $null), Body (parsed JSON
#              or $null) and Step (the index used, or -1 when out of steps);
#   Count(Purpose)  number of requests of a purpose ('' for all).
function New-FakeTransport {
    param(
        [object[]]$Steps = @(),
        [switch]$RepeatLast
    )

    $state = @{
        Steps      = @($Steps)
        Index      = 0
        RepeatLast = [bool]$RepeatLast
        Calls      = (New-Object 'System.Collections.Generic.List[object]')
    }

    $transport = {
        param([hashtable]$Request)

        $text = $null
        $parsed = $null
        if ($Request.Body -is [byte[]]) {
            $text = [System.Text.Encoding]::UTF8.GetString($Request.Body)
            try { $parsed = $text | ConvertFrom-Json } catch { $parsed = $null }
        }

        $steps = $state.Steps
        $position = $state.Index
        if ($position -ge $steps.Count -and $state.RepeatLast -and $steps.Count -gt 0) { $position = $steps.Count - 1 }
        $usable = ($position -lt $steps.Count)
        $state.Calls.Add([pscustomobject][ordered]@{
                Url        = [string]$Request.Url
                Method     = [string]$Request.Method
                Purpose    = [string]$Request.Purpose
                TimeoutSec = $Request.TimeoutSec
                BodyText   = $text
                Body       = $parsed
                Step       = $(if ($usable) { $position } else { -1 })
            })
        if (-not $usable) { throw "fake transport: no step left for request $($state.Calls.Count)" }
        $state.Index = $state.Index + 1

        $step = $steps[$position]
        if ($step -is [System.Exception]) { throw $step }
        if ($step -is [scriptblock]) { return (& $step $Request) }
        return $step
    }.GetNewClosure()

    $handle = [pscustomobject][ordered]@{
        Transport = $transport
        Calls     = $state.Calls
    }
    $handle | Add-Member -MemberType ScriptMethod -Name Count -Value {
        param([string]$Purpose = "")
        if ($Purpose -eq "") { return $this.Calls.Count }
        return @($this.Calls | Where-Object { $_.Purpose -ceq $Purpose }).Count
    }
    return $handle
}
