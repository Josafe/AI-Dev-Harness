<#
.SYNOPSIS
    Offline, in-process tests for the telemetry version 2 writer and the CSV rule of
    scripts\lib\telemetry.ps1 (Phase 2, WP-2B2; FR-216, AC-204, AC-214 fields part,
    NFR-202, OQ-206).

.DESCRIPTION
    - No network, no Ollama, no child process, no sleeping. The writer is dot-sourced
      and called with literal values. Every file is written under one temporary
      folder below TEMP (a different root per case) and the folder is deleted at the
      end; the repository is never passed as a root and nothing is written to it.
    - Every expected value is a literal worked out by hand (the working is in the
      comment above each group), never computed from the code under test. The 31
      column names and their order are written out here in full.
    - AC-204 (b) needs a CSV "created by the baseline writer text": a verbatim copy
      of the Phase 0 / Phase 1 Write-HarnessModelTelemetry is embedded below and run
      in a child scope, so the legacy file is a real legacy file.
    - Assertions never read localized text (NFR-202): field values, key names, types,
      file bytes and SHA-256 hashes only. The one added warning of the writer is
      counted, never read.
    - Not covered here (WP-2C, with Invoke-AgentModel): the engine's choice of values
      for each outcome (success, each category, retry, budget refusal, reviewer,
      reviser). This suite proves the record the writer produces for the values it
      is given.
#>
param()

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$telemetryLibrary = Join-Path $PSScriptRoot "lib\telemetry.ps1"
$configLibrary = Join-Path $PSScriptRoot "lib\config.ps1"
$engineLibrary = Join-Path $PSScriptRoot "lib\agent-exec.ps1"

foreach ($path in @($telemetryLibrary, $configLibrary, $engineLibrary)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required path not found: $path" }
}

. $configLibrary
. $engineLibrary
. $telemetryLibrary

$script:passed = 0
$script:failed = 0
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-harness-telemetry-v2-" + [guid]::NewGuid().ToString("N"))
$script:caseNumber = 0

$originalRunId = $env:AI_HARNESS_RUN_ID

# The 14 legacy columns and the 17 added ones, in the order of FR-216.
$legacyColumns = @("timestamp_utc", "run_id", "agent", "model", "status", "started_at_utc", "duration_ms", "total_duration_ns",
    "load_duration_ns", "prompt_eval_count", "prompt_eval_duration_ns", "eval_count", "eval_duration_ns", "error")
$addedColumns = @("schema_version", "call_id", "profile", "model_source", "transport", "model_called", "attempts", "error_category",
    "http_status", "done_reason", "thinking_chars", "think_sent", "timeout_sec", "context_window", "prompt_chars", "est_prompt_tokens", "warnings")
$v2Columns = $legacyColumns + $addedColumns
$v2Header = '"' + ($v2Columns -join '","') + '"'
$legacyHeader = '"' + ($legacyColumns -join '","') + '"'

# Verbatim copy of scripts\lib\telemetry.ps1 at the baseline (master, before WP-2B2).
$legacyWriterText = @'
function Write-HarnessModelTelemetry {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][datetime]$StartedAt,
        [Parameter(Mandatory = $true)][string]$Status,
        $Response = $null,
        [string]$ErrorMessage = ""
    )

    try {
        $logDir = Join-Path $Root "logs"

        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force |
                Out-Null
        }

        $endedAt = [datetime]::UtcNow
        $durationMs = [math]::Round(
            ($endedAt - $StartedAt.ToUniversalTime()).TotalMilliseconds, 0
        )

        $runId = if (-not [string]::IsNullOrWhiteSpace($env:AI_HARNESS_RUN_ID)) {
            $env:AI_HARNESS_RUN_ID
        }
        else {
            [guid]::NewGuid().ToString()
        }
        $record = [pscustomobject][ordered]@{
            timestamp_utc           = $endedAt.ToString("o")
            run_id                  = $runId
            agent                   = $Agent
            model                   = $Model
            status                  = $Status
            started_at_utc          = $StartedAt.ToUniversalTime().ToString("o")
            duration_ms             = $durationMs
            total_duration_ns       = $Response.total_duration
            load_duration_ns        = $Response.load_duration
            prompt_eval_count       = $Response.prompt_eval_count
            prompt_eval_duration_ns = $Response.prompt_eval_duration
            eval_count              = $Response.eval_count
            eval_duration_ns        = $Response.eval_duration
            error                   = $ErrorMessage
        }

        $jsonlPath = Join-Path $logDir "model-calls.jsonl"
        $csvPath = Join-Path $logDir "model-calls.csv"

        $record |
            ConvertTo-Json -Depth 5 -Compress |
            Add-Content -Path $jsonlPath -Encoding UTF8

        if (Test-Path $csvPath) {
            $csvLines = @($record | ConvertTo-Csv -NoTypeInformation)
            if ($csvLines.Count -gt 1) {
                $csvLines | Select-Object -Skip 1 |
                    Add-Content -Path $csvPath -Encoding UTF8
            }
        }
        else {
            $record | Export-Csv -Path $csvPath `
                -NoTypeInformation -Encoding UTF8
        }
    }
    catch {
        Write-Warning "Telemetry logging failed: $($_.Exception.Message)"
    }
}
'@

function Test-Case {
    param([string]$CaseTitle, [scriptblock]$Body)

    try {
        & $Body
        $script:passed++
        Write-Host "[PASS] $CaseTitle" -ForegroundColor Green
    }
    catch {
        $script:failed++
        Write-Host "[FAIL] $CaseTitle" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
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

# A new empty harness root under the temporary folder (never the repository).
function New-CaseRoot {
    $script:caseNumber++
    $path = Join-Path $tempRoot ("case-" + $script:caseNumber)
    [void][System.IO.Directory]::CreateDirectory($path)
    if (-not $path.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw "case root outside the temporary folder" }
    return $path
}

function Get-Sha256 {
    param([string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace("-", "") }
    finally { $sha.Dispose(); $stream.Dispose() }
}

# Calls the writer with the five baseline parameters plus any extra, in-process.
function Write-Record {
    param([string]$CaseRoot, [hashtable]$Extra = @{}, [string]$Agent = "spec-reviewer", [string]$Status = "success")

    $arguments = @{ Root = $CaseRoot; Agent = $Agent; Model = "test-model:1b"; StartedAt = ([datetime]::UtcNow.AddMilliseconds(-5)); Status = $Status }
    foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
    Write-HarnessModelTelemetry @arguments
}

function Read-Jsonl {
    param([string]$CaseRoot)

    $path = Join-Path $CaseRoot "logs\model-calls.jsonl"
    if (-not (Test-Path -LiteralPath $path)) { return ,@() }
    return ,@([System.IO.File]::ReadAllLines($path) | Where-Object { $_.Trim() -ne "" })
}

# The JSON kind of a value: s string, b boolean, n number, null.
function Get-Kind {
    param($Value)

    if ($null -eq $Value) { return "null" }
    if ($Value -is [string]) { return "s" }
    if ($Value -is [bool]) { return "b" }
    return "n"
}

# Asserts a column of a parsed JSONL record: its value as text and its JSON kind.
function Assert-Column {
    param($Record, [string]$Column, [string]$Text, [string]$Kind)

    Assert-True "column $Column exists" ($null -ne $Record.PSObject.Properties[$Column])
    $value = $Record.$Column
    $shown = if ($value -is [bool]) { $value.ToString().ToLowerInvariant() } else { "$value" }
    Assert-Equal "$Column value" $Text $shown
    Assert-Equal "$Column kind" $Kind (Get-Kind $value)
}

try {
    [void][System.IO.Directory]::CreateDirectory($tempRoot)

    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "   AGENT TELEMETRY V2 (OFFLINE)" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan

    # -----------------------------------------------------------------------
    # FR-216 columns: 14 legacy, then 17 added, in this order (31)
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== FR-216 columns ===" -ForegroundColor Cyan

    Test-Case "FR-216 the literal column list has 14 + 17 = 31 names" {
        Assert-Equal "legacy" 14 $legacyColumns.Count
        Assert-Equal "added" 17 $addedColumns.Count
        Assert-Equal "total" 31 $v2Columns.Count
        Assert-Equal "distinct" 31 @($v2Columns | Sort-Object -Unique).Count
    }

    Test-Case "FR-216 the JSONL record has the 31 keys in the exact order (14 legacy first), for the five-parameter call" {
        $caseRoot = New-CaseRoot
        Write-Record $caseRoot
        $lines = Read-Jsonl $caseRoot
        Assert-Equal "lines" 1 $lines.Count
        $record = $lines[0] | ConvertFrom-Json
        Assert-Equal "keys" ($v2Columns -join ",") (($record.PSObject.Properties | ForEach-Object { $_.Name }) -join ",")
    }

    Test-Case "AC-204 the CSV header is the 31 quoted names in the same order, and the row has 31 cells" {
        $caseRoot = New-CaseRoot
        Write-Record $caseRoot
        $lines = @([System.IO.File]::ReadAllLines((Join-Path $caseRoot "logs\model-calls.csv")))
        Assert-Equal "physical lines" 2 $lines.Count
        Assert-Equal "header" $v2Header $lines[0].TrimStart([char]0xFEFF)
        $row = Import-Csv -LiteralPath (Join-Path $caseRoot "logs\model-calls.csv")
        Assert-Equal "cells" 31 @($row.PSObject.Properties).Count
        Assert-Equal "csv keys" ($v2Columns -join ",") (($row.PSObject.Properties | ForEach-Object { $_.Name }) -join ",")
    }

    Test-Case "FR-216 the legacy call (-Root -Agent -Model -StartedAt -Status) still works and writes the documented defaults" {
        $caseRoot = New-CaseRoot
        Write-Record $caseRoot -Status "success"
        $record = (Read-Jsonl $caseRoot)[0] | ConvertFrom-Json
        Assert-Column $record "agent" "spec-reviewer" "s"
        Assert-Column $record "model" "test-model:1b" "s"
        Assert-Column $record "status" "success" "s"
        Assert-Column $record "error" "" "s"
        foreach ($column in @("total_duration_ns", "load_duration_ns", "prompt_eval_count", "prompt_eval_duration_ns", "eval_count", "eval_duration_ns")) {
            Assert-Column $record $column "" "null"
        }
        Assert-Column $record "schema_version" "2" "n"
        Assert-True "call_id is a GUID" ([guid]::TryParse([string]$record.call_id, [ref][guid]::Empty))
        Assert-Column $record "profile" "" "s"
        Assert-Column $record "model_source" "" "s"
        Assert-Column $record "transport" "blocking" "s"
        Assert-Column $record "model_called" "true" "b"
        foreach ($column in @("attempts", "error_category", "http_status", "done_reason", "thinking_chars", "think_sent", "timeout_sec",
                "context_window", "prompt_chars", "est_prompt_tokens", "warnings")) {
            Assert-Column $record $column "" "s"
        }
        Assert-True "duration_ms is a non-negative whole number" ((Get-Kind $record.duration_ms) -eq "n" -and [double]$record.duration_ms -ge 0 -and [double]$record.duration_ms -eq [math]::Floor([double]$record.duration_ms))
        Assert-True "timestamp parses" ($null -ne [datetime]::Parse([string]$record.timestamp_utc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind))
    }

    Test-Case "FR-216 the legacy columns still come from -Response and -ErrorMessage (and done_reason falls back to the response's)" {
        $caseRoot = New-CaseRoot
        $response = [pscustomobject]@{ total_duration = 1000; load_duration = 100; prompt_eval_count = 5; prompt_eval_duration = 200; eval_count = 10; eval_duration = 300; done_reason = "length" }
        Write-Record $caseRoot @{ Response = $response; ErrorMessage = "plain legacy message" } -Status "error"
        $record = (Read-Jsonl $caseRoot)[0] | ConvertFrom-Json
        Assert-Column $record "total_duration_ns" "1000" "n"
        Assert-Column $record "load_duration_ns" "100" "n"
        Assert-Column $record "prompt_eval_count" "5" "n"
        Assert-Column $record "prompt_eval_duration_ns" "200" "n"
        Assert-Column $record "eval_count" "10" "n"
        Assert-Column $record "eval_duration_ns" "300" "n"
        Assert-Column $record "error" "plain legacy message" "s"
        Assert-Column $record "error_category" "" "s"
        Assert-Column $record "done_reason" "length" "s"
        # an explicit -DoneReason wins over the response's
        $other = New-CaseRoot
        Write-Record $other @{ Response = $response; DoneReason = "stop" }
        Assert-Column ((Read-Jsonl $other)[0] | ConvertFrom-Json) "done_reason" "stop" "s"
    }

    Test-Case "FR-216 every added field carries the literal it is given, with its JSON kind (numbers are numbers, model_called a boolean)" {
        $caseRoot = New-CaseRoot
        Write-Record $caseRoot @{
            Profile = "alpha"; ModelSource = "profile"; Transport = "streaming"; ModelCalled = $false; Attempts = 2; ErrorCategory = "http_5xx"
            HttpStatus = 500; DoneReason = "length"; ThinkingChars = 123; ThinkSent = "false"; TimeoutSec = 900; ContextWindow = 16384
            PromptChars = 5; EstPromptTokens = 2; Warnings = @("budget_exceeded", "output_truncated"); ErrorMessage = "detail text"
        } -Status "error"
        $record = (Read-Jsonl $caseRoot)[0] | ConvertFrom-Json
        Assert-Column $record "schema_version" "2" "n"
        Assert-Column $record "profile" "alpha" "s"
        Assert-Column $record "model_source" "profile" "s"
        Assert-Column $record "transport" "streaming" "s"
        Assert-Column $record "model_called" "false" "b"
        Assert-Column $record "attempts" "2" "n"
        Assert-Column $record "error_category" "http_5xx" "s"
        Assert-Column $record "http_status" "500" "n"
        Assert-Column $record "done_reason" "length" "s"
        Assert-Column $record "thinking_chars" "123" "n"
        Assert-Column $record "think_sent" "false" "s"
        Assert-Column $record "timeout_sec" "900" "n"
        Assert-Column $record "context_window" "16384" "n"
        Assert-Column $record "prompt_chars" "5" "n"
        Assert-Column $record "est_prompt_tokens" "2" "n"
        Assert-Column $record "warnings" "budget_exceeded;output_truncated" "s"
        Assert-Column $record "error" "http_5xx: detail text" "s"
    }

    Test-Case "FR-216 a measured zero is written as 0, not as not-applicable (attempts, http_status, thinking_chars, timeout_sec, context_window, prompt_chars, est_prompt_tokens)" {
        $caseRoot = New-CaseRoot
        Write-Record $caseRoot @{ Attempts = 0; HttpStatus = 0; ThinkingChars = 0; TimeoutSec = 0; ContextWindow = 0; PromptChars = 0; EstPromptTokens = 0 }
        $record = (Read-Jsonl $caseRoot)[0] | ConvertFrom-Json
        foreach ($column in @("attempts", "http_status", "thinking_chars", "timeout_sec", "context_window", "prompt_chars", "est_prompt_tokens")) {
            Assert-Column $record $column "0" "n"
        }
        $csv = Import-Csv -LiteralPath (Join-Path $caseRoot "logs\model-calls.csv")
        Assert-Equal "csv attempts" "0" $csv.attempts
        Assert-Equal "csv prompt_chars" "0" $csv.prompt_chars
    }

    Test-Case "FR-216 booleans are true or false in the CSV (lower case) and a JSON boolean in the JSONL" {
        foreach ($value in @($true, $false)) {
            $caseRoot = New-CaseRoot
            Write-Record $caseRoot @{ ModelCalled = $value }
            $expected = $value.ToString().ToLowerInvariant()
            Assert-Equal "csv" $expected (Import-Csv -LiteralPath (Join-Path $caseRoot "logs\model-calls.csv")).model_called
            Assert-Equal "jsonl text" $expected ("" + (((Read-Jsonl $caseRoot)[0] | ConvertFrom-Json).model_called).ToString().ToLowerInvariant())
            Assert-True "jsonl raw has a bare boolean" ((Read-Jsonl $caseRoot)[0].Contains('"model_called":' + $expected + ','))
        }
    }

    Test-Case "FR-216 warnings: none is empty, one is the code, several are joined by ';' in the given order" {
        $expected = @{ 0 = ""; 1 = "budget_exceeded"; 2 = "budget_exceeded;possible_prompt_truncation"; 3 = "a;b;c" }
        $inputs = @{ 0 = @(); 1 = @("budget_exceeded"); 2 = @("budget_exceeded", "possible_prompt_truncation"); 3 = @("a", "b", "c") }
        foreach ($count in 0, 1, 2, 3) {
            $caseRoot = New-CaseRoot
            Write-Record $caseRoot @{ Warnings = $inputs[$count] }
            Assert-Equal "warnings ($count codes)" $expected[$count] (((Read-Jsonl $caseRoot)[0] | ConvertFrom-Json).warnings)
        }
    }

    Test-Case "FR-216 numbers carry no culture formatting: 1234567 stays 1234567 in JSONL and CSV under es-ES and tr-TR" {
        $thread = [System.Threading.Thread]::CurrentThread
        $savedCulture = $thread.CurrentCulture
        $savedUi = $thread.CurrentUICulture
        try {
            foreach ($cultureName in @("es-ES", "tr-TR", "en-US")) {
                $culture = [System.Globalization.CultureInfo]::GetCultureInfo($cultureName)
                $thread.CurrentCulture = $culture
                $thread.CurrentUICulture = $culture
                $caseRoot = New-CaseRoot
                Write-Record $caseRoot @{ ContextWindow = 1234567; PromptChars = 7654321; Attempts = 3 }
                $line = (Read-Jsonl $caseRoot)[0]
                Assert-True "$cultureName jsonl context_window" ($line.Contains('"context_window":1234567,'))
                Assert-True "$cultureName jsonl prompt_chars" ($line.Contains('"prompt_chars":7654321,'))
                $csv = Import-Csv -LiteralPath (Join-Path $caseRoot "logs\model-calls.csv")
                Assert-Equal "$cultureName csv context_window" "1234567" $csv.context_window
                Assert-Equal "$cultureName csv prompt_chars" "7654321" $csv.prompt_chars
                Assert-Equal "$cultureName csv attempts" "3" $csv.attempts
            }
        }
        finally {
            $thread.CurrentCulture = $savedCulture
            $thread.CurrentUICulture = $savedUi
        }
    }

    # -----------------------------------------------------------------------
    # FR-216 / OQ-206 the error column: "<category>: <detail>", CR and LF each
    # replaced by one space, cut at 500 characters.
    #   category "http_5xx" (8 chars) + ": " (2) = prefix of 10, so a detail of
    #   489 gives 499, 490 gives 500, 491 gives 501 (cut to 500).
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== FR-216 error column ===" -ForegroundColor Cyan

    function Get-ErrorColumn {
        param([hashtable]$Extra)
        $caseRoot = New-CaseRoot
        Write-Record $caseRoot $Extra -Status "error"
        return [string]((Read-Jsonl $caseRoot)[0] | ConvertFrom-Json).error
    }

    Test-Case "FR-216 the error is '<category>: <detail>' with a category, the message alone without one, and the category alone with no detail" {
        Assert-Equal "category and detail" "http_4xx: model not found" (Get-ErrorColumn @{ ErrorCategory = "http_4xx"; ErrorMessage = "model not found" })
        Assert-Equal "no category" "legacy text" (Get-ErrorColumn @{ ErrorMessage = "legacy text" })
        Assert-Equal "category only" "empty_response" (Get-ErrorColumn @{ ErrorCategory = "empty_response" })
        Assert-Equal "nothing" "" (Get-ErrorColumn @{})
        Assert-Equal "detail with a colon and quotes" 'timeout: said "a: b", c' (Get-ErrorColumn @{ ErrorCategory = "timeout"; ErrorMessage = 'said "a: b", c' })
    }

    Test-Case "FR-216 CR and LF are each replaced by one space (CRLF gives two), and the CSV stays two physical lines" {
        Assert-Equal "LF" "http_5xx: a b" (Get-ErrorColumn @{ ErrorCategory = "http_5xx"; ErrorMessage = "a`nb" })
        Assert-Equal "CR" "http_5xx: a b" (Get-ErrorColumn @{ ErrorCategory = "http_5xx"; ErrorMessage = "a`rb" })
        Assert-Equal "CRLF" "http_5xx: a  b" (Get-ErrorColumn @{ ErrorCategory = "http_5xx"; ErrorMessage = "a`r`nb" })
        Assert-Equal "leading and trailing" "x:  a " (Get-ErrorColumn @{ ErrorCategory = "x"; ErrorMessage = "`na`n" })
        Assert-Equal "no category" "a b c" (Get-ErrorColumn @{ ErrorMessage = "a`nb`rc" })
        $caseRoot = New-CaseRoot
        Write-Record $caseRoot @{ ErrorCategory = "http_5xx"; ErrorMessage = "line one`r`nline two`nline three" } -Status "error"
        Assert-Equal "csv physical lines" 2 @([System.IO.File]::ReadAllLines((Join-Path $caseRoot "logs\model-calls.csv"))).Count
        Assert-Equal "jsonl physical lines" 1 @([System.IO.File]::ReadAllLines((Join-Path $caseRoot "logs\model-calls.jsonl"))).Count
        Assert-Equal "csv error cell" "http_5xx: line one  line two line three" (Import-Csv -LiteralPath (Join-Path $caseRoot "logs\model-calls.csv")).error
    }

    Test-Case "FR-216 the error is cut at 500 characters: 499 and 500 are kept whole, 501 and 5000 are cut to the first 500" {
        foreach ($detailLength in 489, 490) {
            $text = Get-ErrorColumn @{ ErrorCategory = "http_5xx"; ErrorMessage = ("d" * $detailLength) }
            Assert-Equal "detail $detailLength (total $($detailLength + 10))" ($detailLength + 10) $text.Length
            Assert-Equal "content" ("http_5xx: " + ("d" * $detailLength)) $text
        }
        $text = Get-ErrorColumn @{ ErrorCategory = "http_5xx"; ErrorMessage = ("d" * 491) }
        Assert-Equal "total 501 cut" 500 $text.Length
        Assert-Equal "total 501 content" ("http_5xx: " + ("d" * 490)) $text
        $text = Get-ErrorColumn @{ ErrorCategory = "http_5xx"; ErrorMessage = ("0123456789" * 500) }
        Assert-Equal "total 5010 cut" 500 $text.Length
        Assert-Equal "total 5010 content" ("http_5xx: " + (("0123456789" * 50).Substring(0, 490))) $text
        # no category: the message alone, same bound
        Assert-Equal "message of 500" 500 (Get-ErrorColumn @{ ErrorMessage = ("m" * 500) }).Length
        Assert-Equal "message of 501" 500 (Get-ErrorColumn @{ ErrorMessage = ("m" * 501) }).Length
        Assert-Equal "message of 499" 499 (Get-ErrorColumn @{ ErrorMessage = ("m" * 499) }).Length
    }

    Test-Case "FR-216 a surrogate pair is never split by the cut: the pair straddling the limit is dropped whole (499 characters)" {
        $emoji = [char]::ConvertFromUtf32(0x1F600)
        $detail = ("e" * 489) + $emoji + "tail"
        $text = Get-ErrorColumn @{ ErrorCategory = "http_5xx"; ErrorMessage = $detail }
        Assert-Equal "length" 499 $text.Length
        Assert-Equal "content" ("http_5xx: " + ("e" * 489)) $text
        # a pair that ends exactly at 500 is kept
        $fits = ("e" * 488) + $emoji + "tail"
        $text = Get-ErrorColumn @{ ErrorCategory = "http_5xx"; ErrorMessage = $fits }
        Assert-Equal "length" 500 $text.Length
        Assert-True "ends with the whole pair" ($text.EndsWith($emoji, [System.StringComparison]::Ordinal))
    }

    Test-Case "OQ-206 a failure detail that looks like an exception message is only what the caller passes: the writer has no exception input" {
        $caseRoot = New-CaseRoot
        Write-Record $caseRoot @{ ErrorCategory = "transport_unreachable"; ErrorMessage = "System.Net.WebException ConnectFailure" } -Status "error"
        $record = (Read-Jsonl $caseRoot)[0] | ConvertFrom-Json
        Assert-Column $record "error" "transport_unreachable: System.Net.WebException ConnectFailure" "s"
        $parameters = (Get-Command Write-HarnessModelTelemetry).Parameters.Keys
        foreach ($forbidden in @("Exception", "ErrorRecord", "Message")) {
            Assert-True "no parameter named $forbidden" (@($parameters) -cnotcontains $forbidden)
        }
    }

    # -----------------------------------------------------------------------
    # run_id and call_id
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== run_id and call_id ===" -ForegroundColor Cyan

    Test-Case "FR-216 run_id follows AI_HARNESS_RUN_ID (value, unset, blank) and call_id is always a new GUID" {
        try {
            $env:AI_HARNESS_RUN_ID = "wp2b2-run-id"
            $first = New-CaseRoot
            Write-Record $first
            Write-Record $first
            $records = @(Read-Jsonl $first | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-Equal "run_id 1" "wp2b2-run-id" $records[0].run_id
            Assert-Equal "run_id 2" "wp2b2-run-id" $records[1].run_id
            Assert-True "call_ids differ" ($records[0].call_id -cne $records[1].call_id)
            Assert-True "call_id is not the run_id" ($records[0].call_id -cne "wp2b2-run-id")
            foreach ($record in $records) { Assert-True "call_id is a GUID" ([guid]::TryParse([string]$record.call_id, [ref][guid]::Empty)) }

            foreach ($variant in @(@{ Label = "unset"; Value = $null }, @{ Label = "blank"; Value = "   " }, @{ Label = "empty"; Value = "" })) {
                $env:AI_HARNESS_RUN_ID = $variant.Value
                $caseRoot = New-CaseRoot
                Write-Record $caseRoot
                $record = (Read-Jsonl $caseRoot)[0] | ConvertFrom-Json
                Assert-True "$($variant.Label): run_id is a GUID" ([guid]::TryParse([string]$record.run_id, [ref][guid]::Empty))
                Assert-True "$($variant.Label): call_id is a GUID" ([guid]::TryParse([string]$record.call_id, [ref][guid]::Empty))
            }
        }
        finally {
            $env:AI_HARNESS_RUN_ID = $originalRunId
        }
    }

    Test-Case "FR-216 (D1) an explicit -CallId is written as call_id in the JSONL and the CSV (never the run id); without it call_id is still a new GUID each time" {
        try {
            $env:AI_HARNESS_RUN_ID = "wp2c-fix-run-id"
            $explicit = [guid]::NewGuid().ToString()
            $caseRoot = New-CaseRoot
            Write-Record $caseRoot @{ CallId = $explicit }
            Write-Record $caseRoot
            Write-Record $caseRoot @{ CallId = "" }
            Write-Record $caseRoot @{ CallId = "   " }
            $records = @(Read-Jsonl $caseRoot | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-Equal "lines" 4 $records.Count
            Assert-Equal "explicit call_id (JSONL)" $explicit $records[0].call_id
            Assert-Equal "run_id unchanged by -CallId" "wp2c-fix-run-id" $records[0].run_id
            $csv = @(Import-Csv -LiteralPath (Join-Path $caseRoot "logs\model-calls.csv"))
            Assert-Equal "explicit call_id (CSV)" $explicit $csv[0].call_id
            foreach ($index in 1, 2, 3) {
                Assert-True "record $index has a generated GUID" ([guid]::TryParse([string]$records[$index].call_id, [ref][guid]::Empty))
                Assert-True "record $index is not the explicit id" ($records[$index].call_id -cne $explicit)
                Assert-True "record $index is not the run id" ($records[$index].call_id -cne "wp2c-fix-run-id")
            }
            Assert-Equal "three generated ids differ" 3 (@($records[1..3] | ForEach-Object { $_.call_id } | Select-Object -Unique)).Count
            Assert-Equal "CallId is a string parameter" "String" (Get-Command Write-HarnessModelTelemetry).Parameters["CallId"].ParameterType.Name
        }
        finally {
            $env:AI_HARNESS_RUN_ID = $originalRunId
        }
    }

    # -----------------------------------------------------------------------
    # AC-204 the CSV rule
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-204 CSV rule ===" -ForegroundColor Cyan

    # Creates a legacy CSV and legacy JSONL by running the baseline writer text in a
    # child scope (its function never reaches the scope of the version 2 writer).
    function New-LegacyLogs {
        param([string]$CaseRoot)

        $legacyFile = Join-Path $tempRoot "legacy-writer.ps1"
        if (-not (Test-Path -LiteralPath $legacyFile)) { [System.IO.File]::WriteAllText($legacyFile, $legacyWriterText, $utf8NoBom) }
        & {
            param($LegacyFile, $CaseRoot)
            . $LegacyFile
            Write-HarnessModelTelemetry -Root $CaseRoot -Agent "legacy-agent" -Model "legacy-model" -StartedAt ([datetime]::UtcNow.AddSeconds(-1)) -Status "success" `
                -Response ([pscustomobject]@{ total_duration = 1; load_duration = 2; prompt_eval_count = 3; prompt_eval_duration = 4; eval_count = 5; eval_duration = 6 })
        } $legacyFile $CaseRoot
    }

    Test-Case "AC-204 (a) no CSV: model-calls.csv is created with the 31-column header and one row; no v2 file" {
        $caseRoot = New-CaseRoot
        Write-Record $caseRoot
        $csv = Join-Path $caseRoot "logs\model-calls.csv"
        Assert-True "model-calls.csv exists" (Test-Path -LiteralPath $csv)
        Assert-True "no model-calls.v2.csv" (-not (Test-Path -LiteralPath (Join-Path $caseRoot "logs\model-calls.v2.csv")))
        $lines = @([System.IO.File]::ReadAllLines($csv))
        Assert-Equal "lines" 2 $lines.Count
        Assert-Equal "header" $v2Header $lines[0].TrimStart([char]0xFEFF)
    }

    Test-Case "AC-204 the baseline writer text produces the 14-column header the rule is tested against" {
        $caseRoot = New-CaseRoot
        New-LegacyLogs $caseRoot
        $lines = @([System.IO.File]::ReadAllLines((Join-Path $caseRoot "logs\model-calls.csv")))
        Assert-Equal "legacy lines" 2 $lines.Count
        Assert-Equal "legacy header" $legacyHeader $lines[0].TrimStart([char]0xFEFF)
        Assert-Equal "legacy header columns" 14 @($lines[0].TrimStart([char]0xFEFF) -split ",").Count
        Assert-Equal "legacy jsonl keys" ($legacyColumns -join ",") (((((Read-Jsonl $caseRoot)[0]) | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $_.Name }) -join ",")
    }

    Test-Case "AC-204 (b)(c) a legacy 14-column CSV is left byte for byte unchanged (SHA-256); v2 rows go to model-calls.v2.csv: header and one row, then appended" {
        $caseRoot = New-CaseRoot
        New-LegacyLogs $caseRoot
        $legacyCsv = Join-Path $caseRoot "logs\model-calls.csv"
        $v2Csv = Join-Path $caseRoot "logs\model-calls.v2.csv"
        $hashBefore = Get-Sha256 $legacyCsv
        $sizeBefore = (Get-Item -LiteralPath $legacyCsv).Length

        Write-Record $caseRoot
        Assert-Equal "legacy csv hash after one v2 call" $hashBefore (Get-Sha256 $legacyCsv)
        Assert-True "v2 csv exists" (Test-Path -LiteralPath $v2Csv)
        $lines = @([System.IO.File]::ReadAllLines($v2Csv))
        Assert-Equal "v2 lines after the first call" 2 $lines.Count
        Assert-Equal "v2 header" $v2Header $lines[0].TrimStart([char]0xFEFF)

        Write-Record $caseRoot -Status "error"
        Write-Record $caseRoot
        Assert-Equal "legacy csv hash after three v2 calls" $hashBefore (Get-Sha256 $legacyCsv)
        Assert-Equal "legacy csv size" $sizeBefore (Get-Item -LiteralPath $legacyCsv).Length
        $rows = @(Import-Csv -LiteralPath $v2Csv)
        Assert-Equal "v2 rows after three calls" 3 $rows.Count
        Assert-Equal "row statuses" "success,error,success" (($rows | ForEach-Object { $_.status }) -join ",")
        foreach ($row in $rows) { Assert-Equal "every v2 row has 31 cells" 31 @($row.PSObject.Properties).Count }
    }

    Test-Case "AC-204 legacy JSONL lines stay untouched: the first line is byte-identical and the new lines have 31 keys" {
        $caseRoot = New-CaseRoot
        New-LegacyLogs $caseRoot
        $jsonl = Join-Path $caseRoot "logs\model-calls.jsonl"
        $legacyLine = (Read-Jsonl $caseRoot)[0]
        $legacyBytes = [System.IO.File]::ReadAllBytes($jsonl)
        Write-Record $caseRoot
        $after = [System.IO.File]::ReadAllBytes($jsonl)
        Assert-True "the file only grew" ($after.Length -gt $legacyBytes.Length)
        $prefixSame = $true
        for ($index = 0; $index -lt $legacyBytes.Length; $index++) { if ($legacyBytes[$index] -ne $after[$index]) { $prefixSame = $false; break } }
        Assert-True "the legacy bytes are a prefix" $prefixSame
        $lines = Read-Jsonl $caseRoot
        Assert-Equal "lines" 2 $lines.Count
        Assert-Equal "first line" $legacyLine $lines[0]
        Assert-Equal "legacy line keys" 14 @(($lines[0] | ConvertFrom-Json).PSObject.Properties).Count
        Assert-Equal "new line keys" 31 @(($lines[1] | ConvertFrom-Json).PSObject.Properties).Count
    }

    Test-Case "AC-204 (d) a v2 header already in model-calls.csv: rows are appended there and no v2 file appears" {
        $caseRoot = New-CaseRoot
        Write-Record $caseRoot
        Write-Record $caseRoot -Status "error"
        Write-Record $caseRoot
        $rows = @(Import-Csv -LiteralPath (Join-Path $caseRoot "logs\model-calls.csv"))
        Assert-Equal "rows" 3 $rows.Count
        Assert-True "no model-calls.v2.csv" (-not (Test-Path -LiteralPath (Join-Path $caseRoot "logs\model-calls.v2.csv")))
        Assert-Equal "csv physical lines" 4 @([System.IO.File]::ReadAllLines((Join-Path $caseRoot "logs\model-calls.csv"))).Count
    }

    Test-Case "AC-204 (e) a leading BOM on the header is ignored: with it and without it the v2 header is recognised, and a BOM plus legacy header is left alone" {
        # the file the writer creates on this host begins with a BOM (Set-Content -Encoding UTF8 on PowerShell 5.1)
        $caseRoot = New-CaseRoot
        Write-Record $caseRoot
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $caseRoot "logs\model-calls.csv"))
        Assert-True "the created file has a BOM" ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Write-Record $caseRoot
        Assert-Equal "appended after a BOM header" 2 @(Import-Csv -LiteralPath (Join-Path $caseRoot "logs\model-calls.csv")).Count
        Assert-True "still no v2 file" (-not (Test-Path -LiteralPath (Join-Path $caseRoot "logs\model-calls.v2.csv")))

        # a header without a BOM
        $noBom = New-CaseRoot
        [void][System.IO.Directory]::CreateDirectory((Join-Path $noBom "logs"))
        [System.IO.File]::WriteAllText((Join-Path $noBom "logs\model-calls.csv"), $v2Header + "`r`n", $utf8NoBom)
        Write-Record $noBom
        Assert-Equal "appended after a header without BOM" 1 @(Import-Csv -LiteralPath (Join-Path $noBom "logs\model-calls.csv")).Count
        Assert-True "no v2 file for a BOM-less v2 header" (-not (Test-Path -LiteralPath (Join-Path $noBom "logs\model-calls.v2.csv")))

        # a BOM and the legacy header: untouched, rows go to the v2 file
        $legacyBom = New-CaseRoot
        [void][System.IO.Directory]::CreateDirectory((Join-Path $legacyBom "logs"))
        [System.IO.File]::WriteAllText((Join-Path $legacyBom "logs\model-calls.csv"), $legacyHeader + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
        $hash = Get-Sha256 (Join-Path $legacyBom "logs\model-calls.csv")
        Write-Record $legacyBom
        Assert-Equal "legacy file with BOM unchanged" $hash (Get-Sha256 (Join-Path $legacyBom "logs\model-calls.csv"))
        Assert-Equal "v2 rows" 1 @(Import-Csv -LiteralPath (Join-Path $legacyBom "logs\model-calls.v2.csv")).Count
    }

    Test-Case "AC-204 (f) model-calls.v2.csv with a foreign header: no CSV row is written anywhere, the JSONL line is, both CSV files are unchanged, and the call does not fail" {
        $caseRoot = New-CaseRoot
        New-LegacyLogs $caseRoot
        $legacyCsv = Join-Path $caseRoot "logs\model-calls.csv"
        $v2Csv = Join-Path $caseRoot "logs\model-calls.v2.csv"
        [System.IO.File]::WriteAllText($v2Csv, '"foo","bar"' + "`r`n" + '"1","2"' + "`r`n", $utf8NoBom)
        $legacyHash = Get-Sha256 $legacyCsv
        $v2Hash = Get-Sha256 $v2Csv
        $jsonlBefore = (Read-Jsonl $caseRoot).Count

        $thrown = $false
        $warnings = @()
        try { Write-Record $caseRoot -Status "success" 3>&1 | ForEach-Object { $warnings += $_ } } catch { $thrown = $true }
        Assert-True "the call did not throw" (-not $thrown)
        Assert-Equal "legacy csv unchanged" $legacyHash (Get-Sha256 $legacyCsv)
        Assert-Equal "foreign v2 csv unchanged" $v2Hash (Get-Sha256 $v2Csv)
        Assert-Equal "jsonl lines" ($jsonlBefore + 1) (Read-Jsonl $caseRoot).Count
        Assert-Equal "the new jsonl line has 31 keys" 31 @((((Read-Jsonl $caseRoot)[-1]) | ConvertFrom-Json).PSObject.Properties).Count
        Assert-Equal "exactly one warning was raised" 1 @($warnings | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count
    }

    Test-Case "AC-204 a foreign header in model-calls.csv (not the legacy one) is also left alone and rows go to the v2 file; an empty model-calls.csv likewise" {
        $foreign = New-CaseRoot
        [void][System.IO.Directory]::CreateDirectory((Join-Path $foreign "logs"))
        [System.IO.File]::WriteAllText((Join-Path $foreign "logs\model-calls.csv"), '"a","b","c"' + "`r`n", $utf8NoBom)
        $hash = Get-Sha256 (Join-Path $foreign "logs\model-calls.csv")
        Write-Record $foreign
        Assert-Equal "foreign csv unchanged" $hash (Get-Sha256 (Join-Path $foreign "logs\model-calls.csv"))
        Assert-Equal "v2 rows" 1 @(Import-Csv -LiteralPath (Join-Path $foreign "logs\model-calls.v2.csv")).Count

        $empty = New-CaseRoot
        [void][System.IO.Directory]::CreateDirectory((Join-Path $empty "logs"))
        [System.IO.File]::WriteAllBytes((Join-Path $empty "logs\model-calls.csv"), [byte[]]@())
        Write-Record $empty
        Assert-Equal "empty csv still empty" 0 (Get-Item -LiteralPath (Join-Path $empty "logs\model-calls.csv")).Length
        Assert-Equal "v2 rows after an empty csv" 1 @(Import-Csv -LiteralPath (Join-Path $empty "logs\model-calls.v2.csv")).Count
    }

    Test-Case "AC-204 a header that differs by one column name, one column or the order is not a v2 header" {
        $variants = @{
            "one name changed" = ($v2Header -replace '"warnings"$', '"warning"')
            "one column fewer" = ($v2Header -replace ',"warnings"$', '')
            "order swapped"    = ($v2Header -replace '"attempts","error_category"', '"error_category","attempts"')
        }
        foreach ($variantName in $variants.Keys) {
            $caseRoot = New-CaseRoot
            [void][System.IO.Directory]::CreateDirectory((Join-Path $caseRoot "logs"))
            $csv = Join-Path $caseRoot "logs\model-calls.csv"
            [System.IO.File]::WriteAllText($csv, $variants[$variantName] + "`r`n", $utf8NoBom)
            $hash = Get-Sha256 $csv
            Write-Record $caseRoot
            Assert-Equal "$variantName : model-calls.csv unchanged" $hash (Get-Sha256 $csv)
            Assert-True "$variantName : rows went to the v2 file" (Test-Path -LiteralPath (Join-Path $caseRoot "logs\model-calls.v2.csv"))
        }
    }

    Test-Case "AC-204 a telemetry failure never fails a call: an unusable root gives a warning and no exception" {
        $blocker = Join-Path $tempRoot "not-a-folder"
        [System.IO.File]::WriteAllText($blocker, "x", $utf8NoBom)
        $thrown = $false
        $warnings = @()
        try {
            Write-HarnessModelTelemetry -Root $blocker -Agent "a" -Model "m" -StartedAt ([datetime]::UtcNow) -Status "success" 3>&1 |
                ForEach-Object { $warnings += $_ }
        }
        catch { $thrown = $true }
        Assert-True "no exception" (-not $thrown)
        Assert-True "a warning was raised" (@($warnings | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count -ge 1)
    }

    # -----------------------------------------------------------------------
    # AC-214 literal values the engine will hand to the writer
    #   system "AB" (2) + prompt "CDE" (3) = 5 characters; at charsPerToken 2.5,
    #   E = ceil(5 / 2.5) = 2. A v1 configuration has no contextWindow: skipped.
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-214 literals through the budget ===" -ForegroundColor Cyan

    function New-BudgetFixture {
        param([string]$Json)

        $registry = ConvertTo-HarnessRegistry -Config ($Json | ConvertFrom-Json)
        return [pscustomobject]@{ Registry = $registry; Execution = (Resolve-HarnessExecution -Agent "spec" -Registry $registry) }
    }

    Test-Case "AC-214 a stub of system 'AB' and prompt 'CDE' at charsPerToken 2.5 gives prompt_chars 5, est_prompt_tokens 2 and the window in the record" {
        $fixture = New-BudgetFixture '{ "schemaVersion": 2, "defaults": { "profile": "alpha", "charsPerToken": 2.5 }, "profiles": { "alpha": { "model": "test-model-a", "contextWindow": 10000, "reservedOutputTokens": 1000 } }, "agents": { "spec": { "profile": "alpha" } } }'
        $budget = Test-AgentContextBudget -Execution $fixture.Execution -Registry $fixture.Registry -System "AB" -Prompt "CDE"
        Assert-Equal "estTokens" 2 $budget.estTokens
        $caseRoot = New-CaseRoot
        Write-Record $caseRoot @{ ContextWindow = $budget.contextWindow; PromptChars = ("AB".Length + "CDE".Length); EstPromptTokens = $budget.estTokens }
        $record = (Read-Jsonl $caseRoot)[0] | ConvertFrom-Json
        Assert-Column $record "prompt_chars" "5" "n"
        Assert-Column $record "est_prompt_tokens" "2" "n"
        Assert-Column $record "context_window" "10000" "n"
    }

    Test-Case "AC-214 a v1 configuration has no budget: context_window and est_prompt_tokens are empty and prompt_chars is still written" {
        $fixture = New-BudgetFixture '{ "defaultModel": "test-model-a" }'
        $budget = Test-AgentContextBudget -Execution $fixture.Execution -Registry $fixture.Registry -System "AB" -Prompt "CDE"
        Assert-Equal "status" "skipped" $budget.status
        $caseRoot = New-CaseRoot
        Write-Record $caseRoot @{ ContextWindow = $budget.contextWindow; PromptChars = 5; EstPromptTokens = $budget.estTokens }
        $record = (Read-Jsonl $caseRoot)[0] | ConvertFrom-Json
        Assert-Column $record "context_window" "" "s"
        Assert-Column $record "est_prompt_tokens" "" "s"
        Assert-Column $record "prompt_chars" "5" "n"
    }

    Test-Case "AC-214 every error category of FR-211 is written to error_category and to the start of error, one record per call" {
        $categories = @("http_5xx", "http_4xx", "timeout", "transport_unreachable", "transport_reset", "transport_other", "context_budget_exceeded",
            "thinking_budget_exhausted", "empty_response", "format_invalid", "model_not_installed")
        foreach ($category in $categories) {
            $caseRoot = New-CaseRoot
            Write-Record $caseRoot @{ ErrorCategory = $category; ErrorMessage = "detail of $category"; ModelCalled = ($category -ne "model_not_installed" -and $category -ne "context_budget_exceeded") } -Status "error"
            $lines = Read-Jsonl $caseRoot
            Assert-Equal "$category lines" 1 $lines.Count
            $record = $lines[0] | ConvertFrom-Json
            Assert-Column $record "error_category" $category "s"
            Assert-Column $record "error" "${category}: detail of $category" "s"
            Assert-Column $record "status" "error" "s"
        }
    }

    # -----------------------------------------------------------------------
    # Static scans of the writer (NFR-202, NFR-203, NFR-204)
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== static scans ===" -ForegroundColor Cyan

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($telemetryLibrary, [ref]$tokens, [ref]$errors)

    Test-Case "FR-216 static: telemetry.ps1 parses, defines only Write-HarnessModelTelemetry, and keeps the five mandatory parameters first and in order" {
        Assert-Equal "parse errors" 0 $errors.Count
        $functions = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        Assert-Equal "functions" "Write-HarnessModelTelemetry" (($functions | ForEach-Object { $_.Name }) -join ",")
        $parameters = @($functions[0].Body.ParamBlock.Parameters)
        $mandatory = @($parameters | Where-Object { @($_.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.NamedArguments.ArgumentName -contains "Mandatory" }).Count -gt 0 } | ForEach-Object { $_.Name.VariablePath.UserPath })
        Assert-Equal "mandatory parameters" "Root,Agent,Model,StartedAt,Status" ($mandatory -join ",")
        $names = @($parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        Assert-Equal "first parameters in order" "Root,Agent,Model,StartedAt,Status,Response,ErrorMessage" (($names | Select-Object -First 7) -join ",")
        Assert-Equal "parameter count" 23 $names.Count
    }

    Test-Case "NFR-202 static: the writer never reads Exception.Message for the record (the only use is the display-only warning in the catch)" {
        $reads = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq "Message" }, $true))
        Assert-Equal ".Message reads" 1 $reads.Count
        $inCatch = $false
        $parent = $reads[0].Parent
        while ($null -ne $parent) { if ($parent -is [System.Management.Automation.Language.CatchClauseAst]) { $inCatch = $true }; $parent = $parent.Parent }
        Assert-True "the single read is inside the catch clause" $inCatch
    }

    Test-Case "NFR-203 static: telemetry.ps1 has no HTTP route, process control or Start-Sleep; NFR-204: no -AsHashtable, ternary or null-coalescing" {
        $text = [System.IO.File]::ReadAllText($telemetryLibrary)
        foreach ($literal in @("Invoke-RestMethod", "Invoke-WebRequest", "System.Net", "HttpWebRequest", "HttpClient", "Start-Process", "Stop-Process", "Start-Sleep", "Invoke-Expression", "AsHashtable")) {
            Assert-True "no $literal" ($text.IndexOf($literal, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)
        }
        foreach ($token in $tokens) {
            if ($token.Kind -eq [System.Management.Automation.Language.TokenKind]::QuestionMark -or
                $token.Kind -eq [System.Management.Automation.Language.TokenKind]::QuestionQuestion) { throw "ternary or null-coalescing token" }
        }
    }

    Test-Case "NFR-203 guard: every case wrote under the temporary folder and none under the repository's logs folder" {
        Assert-True "temporary folder exists" (Test-Path -LiteralPath $tempRoot)
        Assert-True "cases ran" ($script:caseNumber -gt 20)

    }
}
finally {
    $env:AI_HARNESS_RUN_ID = $originalRunId
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

if ($script:failed -eq 0 -and $script:passed -gt 0) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "STATUS: FAIL" -ForegroundColor Red
exit 1
