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
# call_id is a new GUID unless -CallId is given (the engine passes its own, so that
# meta.callId equals call_id); it is never the run id. run_id is AI_HARNESS_RUN_ID or a GUID.
#
# Files: JSONL always gets the new keys. CSV: no logs\model-calls.csv -> create it
# with the version 2 header; its first line equals the version 2 header (a leading
# BOM ignored) -> append; any other header -> leave the file untouched and use
# logs\model-calls.v2.csv the same way (create, append when the header matches, or
# skip the CSV row when that file has another header). A telemetry failure never
# fails a call: it is a warning.

# ---------------------------------------------------------------------------
# Phase 3 A1 (FR-311 c, FR-307 reader, D-308): one named mutex around the whole file
# section, one FileStream append per file, a locked reader. Bytes written equal what
# Add-Content -Encoding UTF8 wrote (BOM only when the file is empty, CRLF).
# ---------------------------------------------------------------------------

# The resolved long path of a directory: absolute, 8.3 components expanded,
# trailing separators trimmed (the root keeps its one).
function Get-HarnessLongPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $rootPart = [System.IO.Path]::GetPathRoot($full)
    $rest = $full.Substring($rootPart.Length).Trim([char]'\', [char]'/')
    $current = $rootPart
    if ($rest.Length -eq 0) { return $current }
    foreach ($component in ($rest -split "[\\/]")) {
        if ($component.Length -eq 0) { continue }
        $long = $component
        try {
            $found = @([System.IO.Directory]::GetFileSystemEntries($current, $component))
            if ($found.Count -ge 1) { $long = [System.IO.Path]::GetFileName([string]$found[0]) }
        }
        catch { $long = $component }
        $current = Join-Path $current $long
    }
    return $current
}

# Global\AiHarnessTelemetry-<first 16 hex of SHA-256 of the lower-cased resolved log directory>.
function Get-HarnessTelemetryMutexName {
    param([Parameter(Mandatory = $true)][string]$LogDir)

    $key = (Get-HarnessLongPath -Path $LogDir).ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key)) }
    finally { $sha.Dispose() }
    $hex = [System.BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant()
    return "Global\AiHarnessTelemetry-" + $hex.Substring(0, 16)
}

# Takes the telemetry mutex, waiting up to WaitMs. Acquired is true also for an
# abandoned mutex; Unavailable is true when the name is refused or the wait is spent.
# No Local\ fallback.
function Enter-HarnessTelemetryLock {
    param([Parameter(Mandatory = $true)][string]$LogDir, [int]$WaitMs = 10000)

    $state = [pscustomobject]@{ Mutex = $null; Acquired = $false; Unavailable = $false }
    try {
        $state.Mutex = New-Object System.Threading.Mutex -ArgumentList $false, (Get-HarnessTelemetryMutexName -LogDir $LogDir)
    }
    catch {
        $state.Unavailable = $true
        return $state
    }
    try {
        $state.Acquired = $state.Mutex.WaitOne([Math]::Max(0, $WaitMs))
    }
    catch [System.Threading.AbandonedMutexException] {
        $state.Acquired = $true
    }
    if (-not $state.Acquired) {
        $state.Unavailable = $true
        $state.Mutex.Dispose()
        $state.Mutex = $null
    }
    return $state
}

function Exit-HarnessTelemetryLock {
    param($State)

    if ($null -ne $State -and $null -ne $State.Mutex) {
        try { if ($State.Acquired) { $State.Mutex.ReleaseMutex() } } catch { }
        $State.Mutex.Dispose()
        $State.Mutex = $null
        $State.Acquired = $false
    }
}

# Appends the lines as UTF-8 with CRLF line ends through one FileStream (Append, Write,
# FileShare.ReadWrite) in a single write; the BOM is added only when the file is empty
# or new. An IOException is retried every 25 ms until RetryMs is spent.
function Add-HarnessTelemetryText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Lines,
        [string]$Prefix = "",
        [int]$RetryMs = 10000
    )

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            $stream = New-Object System.IO.FileStream -ArgumentList $Path, ([System.IO.FileMode]::Append), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::ReadWrite)
            try {
                $text = $Prefix + ((@($Lines) | ForEach-Object { "$_`r`n" }) -join "")
                $bytes = $utf8.GetBytes($text)
                if ($stream.Length -eq 0) { $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + $bytes) }
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
            }
            finally { $stream.Dispose() }
            return
        }
        catch [System.IO.DirectoryNotFoundException] { throw }
        catch [System.IO.PathTooLongException] { throw }
        catch [System.IO.IOException] {
            if ($watch.ElapsedMilliseconds -ge $RetryMs) { throw }
            [System.Threading.Thread]::Sleep(25)
        }
    }
}

# FR-307 reader. Reads logs\model-calls.jsonl from byte FromOffset under the telemetry
# mutex (FileShare.ReadWrite, IOException retried), drops a leading BOM and returns
# { Exists, Length, Lines, LockTimedOut }. Length is the file length that was read, the
# next FromOffset. -LengthOnly returns the length without reading the bytes. When the
# lock cannot be taken it reads unlocked and sets LockTimedOut (the caller adds the
# warning telemetry_lock_timeout).
function Read-HarnessModelTelemetry {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [long]$FromOffset = 0,
        [switch]$LengthOnly,
        [int]$LockWaitMs = 10000
    )

    $logDir = Join-Path $Root "logs"
    $path = Join-Path $logDir "model-calls.jsonl"
    $result = [pscustomobject]@{ Exists = $false; Length = 0L; Lines = @(); LockTimedOut = $false }
    if (-not (Test-Path -LiteralPath $logDir)) { return $result }

    $lock = Enter-HarnessTelemetryLock -LogDir $logDir -WaitMs $LockWaitMs
    try {
        $result.LockTimedOut = [bool]$lock.Unavailable
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            try {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $result }
                $stream = New-Object System.IO.FileStream -ArgumentList $path, ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::Read), ([System.IO.FileShare]::ReadWrite)
                try {
                    $length = $stream.Length
                    $start = [Math]::Min([Math]::Max($FromOffset, 0L), $length)
                    $bytes = New-Object byte[] $(if ($LengthOnly) { 0 } else { $length - $start })
                    if (-not $LengthOnly -and $bytes.Length -gt 0) {
                        [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin)
                        $got = 0
                        while ($got -lt $bytes.Length) {
                            $n = $stream.Read($bytes, $got, $bytes.Length - $got)
                            if ($n -le 0) { break }
                            $got += $n
                        }
                    }
                }
                finally { $stream.Dispose() }
                $skip = 0
                if ($start -eq 0 -and $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $skip = 3 }
                $result.Exists = $true
                $result.Length = [long]$length
                if (-not $LengthOnly) {
                    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes, $skip, $bytes.Length - $skip)
                    $result.Lines = @($text -split "\r?\n" | Where-Object { $_.Length -gt 0 })
                }
                return $result
            }
            catch [System.IO.FileNotFoundException] { return $result }
            catch [System.IO.DirectoryNotFoundException] { return $result }
            catch [System.IO.IOException] {
                if ($watch.ElapsedMilliseconds -ge $LockWaitMs) { throw }
                [System.Threading.Thread]::Sleep(25)
            }
        }
    }
    finally { Exit-HarnessTelemetryLock -State $lock }
}

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
        [string[]]$Warnings = @(),
        [string]$CallId = "",
        [int]$LockWaitMs = 10000
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
            call_id                 = $(if ([string]::IsNullOrWhiteSpace($CallId)) { [guid]::NewGuid().ToString() } else { $CallId })
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

        # File section under the named mutex (FR-311 c): JSONL append, CSV header
        # decision, CSV append. A refused name or a spent wait warns and writes anyway;
        # the FileStream retry covers the overlap.
        $lock = Enter-HarnessTelemetryLock -LogDir $logDir -WaitMs $LockWaitMs
        try {
            if ($lock.Unavailable) {
                Write-Warning "Telemetry lock not taken (name refused or wait spent); writing without it."
            }

            Add-HarnessTelemetryText -Path $jsonlPath -Lines @($record | ConvertTo-Json -Depth 5 -Compress) -RetryMs $LockWaitMs

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
                    # A file without a final newline (edited by hand, or cut by a crash) would
                    # have the new row joined to its last row (final QA N-10): the last byte
                    # is read and a line end is put in front of the row, in the same single
                    # write, when it is missing. A last byte of 0 is a UTF-16 file, which is
                    # left as it is (as before).
                    $lastByte = -1
                    $tail = [System.IO.File]::Open($target, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    try {
                        if ($tail.Length -gt 0) {
                            [void]$tail.Seek(-1, [System.IO.SeekOrigin]::End)
                            $lastByte = $tail.ReadByte()
                        }
                    }
                    finally { $tail.Dispose() }
                    $lineEnd = ""
                    if ($lastByte -gt 0 -and $lastByte -ne 10) {
                        $lineEnd = if ($lastByte -eq 13) { "`n" } else { "`r`n" }
                    }
                    Add-HarnessTelemetryText -Path $target -Lines @($csvLines | Select-Object -Skip 1) -Prefix $lineEnd -RetryMs $LockWaitMs
                }
                else {
                    Add-HarnessTelemetryText -Path $target -Lines @($csvLines) -RetryMs $LockWaitMs
                }
            }
        }
        finally { Exit-HarnessTelemetryLock -State $lock }
    }
    catch {
        Write-Warning "Telemetry logging failed: $($_.Exception.Message)"
    }
}
