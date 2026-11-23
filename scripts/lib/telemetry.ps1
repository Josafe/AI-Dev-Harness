# Telemetry writer (Phase 0 14 columns; Phase 2 WP-2B2: version 2, 31 columns, FR-216).
#
# Every record has the 14 legacy columns in the same order, then, appended in this
# order: schema_version, call_id, profile, model_source, transport, model_called,
# attempts, error_category, http_status, done_reason, thinking_chars, think_sent,
# timeout_sec, context_window, prompt_chars, est_prompt_tokens, warnings.
#
# All parameters after -Status are optional, so the legacy call
#   Write-HarnessModelTelemetry -Root -Agent -Model -StartedAt -Status
# still works and writes a version 2 record with the defaults below.
#   Not measured numbers (attempts, http_status, thinking_chars, timeout_sec,
#   context_window, prompt_chars, est_prompt_tokens): written as an empty string.
#   Strings not given: empty. model_called: true unless -ModelCalled $false.
#   transport: blocking unless given. warnings: codes joined by ';'.
# error column: "<category>: <detail>" when -ErrorCategory is given (the detail is
#   -ErrorMessage), else -ErrorMessage alone. CR and LF are each replaced by a space
#   and the text is cut at 500 characters (a surrogate pair is never split). The
#   writer never reads Exception.Message: the caller passes the detail.
# call_id is always a new GUID. run_id is AI_HARNESS_RUN_ID or a GUID.
#
# Files: JSONL always gets the new keys. CSV: no logs\model-calls.csv -> create it
# with the version 2 header; its first line equals the version 2 header (a leading
# BOM ignored) -> append; any other header -> leave the file untouched and use
# logs\model-calls.v2.csv the same way (create, append when the header matches, or
# skip the CSV row when that file has another header). A telemetry failure never
# fails a call: it is a warning.

function Write-HarnessModelTelemetry {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][datetime]$StartedAt,
        [Parameter(Mandatory = $true)][string]$Status,
        $Response = $null,
        [string]$ErrorMessage = "",
        [string]$Profile = "",
        [string]$ModelSource = "",
        [string]$Transport = "blocking",
        [bool]$ModelCalled = $true,
        [Nullable[long]]$Attempts = $null,
        [string]$ErrorCategory = "",
        [Nullable[long]]$HttpStatus = $null,
        [string]$DoneReason = "",
        [Nullable[long]]$ThinkingChars = $null,
        [string]$ThinkSent = "",
        [Nullable[long]]$TimeoutSec = $null,
        [Nullable[long]]$ContextWindow = $null,
        [Nullable[long]]$PromptChars = $null,
        [Nullable[long]]$EstPromptTokens = $null,
        [string[]]$Warnings = @()
    )

    try {
        $logDir = Join-Path $Root "logs"

        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force |
                Out-Null
        }

        $endedAt = [datetime]::UtcNow
        $durationMs = [long][math]::Round(
            ($endedAt - $StartedAt.ToUniversalTime()).TotalMilliseconds, 0
        )

        $runId = if (-not [string]::IsNullOrWhiteSpace($env:AI_HARNESS_RUN_ID)) {
            $env:AI_HARNESS_RUN_ID
        }
        else {
            [guid]::NewGuid().ToString()
        }

        # error column
        $errorText = [string]$ErrorMessage
        if ($ErrorCategory.Length -gt 0) {
            $errorText = if ($errorText.Length -gt 0) { "${ErrorCategory}: $errorText" } else { $ErrorCategory }
        }
        $errorText = $errorText -replace "[\r\n]", " "
        if ($errorText.Length -gt 500) {
            $cut = 500
            if ([char]::IsHighSurrogate($errorText[$cut - 1])) { $cut = 499 }
            $errorText = $errorText.Substring(0, $cut)
        }

        if ($DoneReason.Length -eq 0 -and $null -ne $Response -and $null -ne $Response.PSObject.Properties["done_reason"] -and $null -ne $Response.done_reason) {
            $DoneReason = [string]$Response.done_reason
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
            error                   = $errorText
            schema_version          = 2
            call_id                 = [guid]::NewGuid().ToString()
            profile                 = $Profile
            model_source            = $ModelSource
            transport               = $Transport
            model_called            = $ModelCalled
            attempts                = $(if ($null -eq $Attempts) { "" } else { [long]$Attempts })
            error_category          = $ErrorCategory
            http_status             = $(if ($null -eq $HttpStatus) { "" } else { [long]$HttpStatus })
            done_reason             = $DoneReason
            thinking_chars          = $(if ($null -eq $ThinkingChars) { "" } else { [long]$ThinkingChars })
            think_sent              = $ThinkSent
            timeout_sec             = $(if ($null -eq $TimeoutSec) { "" } else { [long]$TimeoutSec })
            context_window          = $(if ($null -eq $ContextWindow) { "" } else { [long]$ContextWindow })
            prompt_chars            = $(if ($null -eq $PromptChars) { "" } else { [long]$PromptChars })
            est_prompt_tokens       = $(if ($null -eq $EstPromptTokens) { "" } else { [long]$EstPromptTokens })
            warnings                = (@($Warnings | Where-Object { $_ -ne $null -and "$_".Length -gt 0 }) -join ";")
        }

        $jsonlPath = Join-Path $logDir "model-calls.jsonl"
        $csvPath = Join-Path $logDir "model-calls.csv"
        $csvV2Path = Join-Path $logDir "model-calls.v2.csv"

        $record |
            ConvertTo-Json -Depth 5 -Compress |
            Add-Content -Path $jsonlPath -Encoding UTF8

        # CSV copy: booleans as true/false (ConvertTo-Csv would write True/False).
        $csvFields = [ordered]@{}
        foreach ($property in $record.PSObject.Properties) {
            $value = $property.Value
            if ($value -is [bool]) { $value = $value.ToString().ToLowerInvariant() }
            $csvFields[$property.Name] = $value
        }
        $csvLines = @(([pscustomobject]$csvFields) | ConvertTo-Csv -NoTypeInformation)
        $v2Header = [string]$csvLines[0]

        # First line of an existing CSV, a leading BOM ignored; $null when unreadable.
        $readHeader = {
            param([string]$Path)
            $reader = New-Object System.IO.StreamReader -ArgumentList $Path, $true
            try {
                $line = $reader.ReadLine()
                if ($null -eq $line) { return "" }
                return $line.TrimStart([char]0xFEFF)
            }
            finally { $reader.Dispose() }
        }

        $target = $null
        if (-not (Test-Path -LiteralPath $csvPath)) {
            $target = $csvPath
        }
        elseif ((& $readHeader $csvPath) -ceq $v2Header) {
            $target = $csvPath
        }
        elseif (-not (Test-Path -LiteralPath $csvV2Path)) {
            $target = $csvV2Path
        }
        elseif ((& $readHeader $csvV2Path) -ceq $v2Header) {
            $target = $csvV2Path
        }
        else {
            Write-Warning "Telemetry CSV row skipped: neither model-calls.csv nor model-calls.v2.csv has the version 2 header."
        }

        if ($null -ne $target) {
            if (Test-Path -LiteralPath $target) {
                $csvLines | Select-Object -Skip 1 |
                    Add-Content -LiteralPath $target -Encoding UTF8
            }
            else {
                $csvLines |
                    Set-Content -LiteralPath $target -Encoding UTF8
            }
        }
    }
    catch {
        Write-Warning "Telemetry logging failed: $($_.Exception.Message)"
    }
}
