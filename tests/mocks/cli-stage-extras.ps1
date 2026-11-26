# Shared part of the CLI stage mocks (Phase 3 B4; AC-305, AC-308, AC-310, AC-311).
# Dot-sourced by tests\mocks\cli-runner.ps1, cli-reviewer.ps1 and cli-reviser.ps1, each
# of which then delegates to its scenario mock (scenario-*.ps1, B2), so the recorded
# calls and the scenario actions are those of B2. Not a suite.
#
# Invoke-CliStageExtras -Stage <runner|reviewer|reviser> does, before the scenario mock:
#   n = 1 + the number of "<stage>|" lines already in AI_HARNESS_TEST_RECORD_FILE.
#   AI_HARNESS_TEST_SNAPSHOT_DIR set: copies runs\<AI_HARNESS_RUN_ID>\manifest.json of
#     AI_HARNESS_TEST_HARNESS_ROOT to <dir>\<stage><n>.json (shared read, .NET I/O) and
#     writes the run id the stage saw to <dir>\<stage><n>.runid.
#   AI_HARNESS_TEST_TELEMETRY_FILE set: a JSON object; its member "<stage><n>" is a list
#     of records, each written with Write-HarnessModelTelemetry (lib\telemetry.ps1 of
#     AI_HARNESS_TEST_HARNESS_ROOT) under that root. Record members (all optional):
#     callId, attempts, status, errorCategory, httpStatus, error, warnings (array),
#     profile, modelSource, model, timeoutSec, contextWindow, estPromptTokens, runId
#     (written as that run id instead of AI_HARNESS_RUN_ID).

function Invoke-CliStageExtras {
    param([Parameter(Mandatory = $true)][string]$Stage)

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $recordFile = $env:AI_HARNESS_TEST_RECORD_FILE
    $previous = 0
    if (-not [string]::IsNullOrWhiteSpace($recordFile) -and [System.IO.File]::Exists($recordFile)) {
        $previous = @([System.IO.File]::ReadAllLines($recordFile) | Where-Object { $_.StartsWith("$Stage|", [System.StringComparison]::Ordinal) }).Count
    }
    $call = $Stage + ($previous + 1)
    $harnessRoot = $env:AI_HARNESS_TEST_HARNESS_ROOT
    $runId = $env:AI_HARNESS_RUN_ID

    $snapshotDir = $env:AI_HARNESS_TEST_SNAPSHOT_DIR
    if (-not [string]::IsNullOrWhiteSpace($snapshotDir)) {
        [void][System.IO.Directory]::CreateDirectory($snapshotDir)
        [System.IO.File]::WriteAllText((Join-Path $snapshotDir "$call.runid"), [string]$runId, $utf8)
        if (-not [string]::IsNullOrWhiteSpace($harnessRoot) -and -not [string]::IsNullOrWhiteSpace($runId)) {
            $manifest = Join-Path (Join-Path (Join-Path $harnessRoot "runs") $runId) "manifest.json"
            if ([System.IO.File]::Exists($manifest)) {
                $share = [System.IO.FileShare]([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
                $stream = New-Object System.IO.FileStream($manifest, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
                try {
                    $memory = New-Object System.IO.MemoryStream
                    $stream.CopyTo($memory)
                    [System.IO.File]::WriteAllBytes((Join-Path $snapshotDir "$call.json"), $memory.ToArray())
                }
                finally { $stream.Dispose() }
            }
        }
    }

    $telemetryFile = $env:AI_HARNESS_TEST_TELEMETRY_FILE
    if (-not [string]::IsNullOrWhiteSpace($telemetryFile) -and [System.IO.File]::Exists($telemetryFile)) {
        $plan = [System.IO.File]::ReadAllText($telemetryFile, $utf8) | ConvertFrom-Json
        $records = $null
        if ($null -ne $plan.PSObject.Properties[$call]) { $records = @($plan.$call) }
        if ($null -ne $records -and $records.Count -gt 0) {
            . (Join-Path $harnessRoot "scripts\lib\telemetry.ps1")
            foreach ($record in $records) {
                $get = { param($name, $default) if ($null -ne $record.PSObject.Properties[$name]) { return $record.$name } return $default }
                $arguments = @{
                    Root      = $harnessRoot
                    Agent     = [string](& $get "agent" $Stage)
                    Model     = [string](& $get "model" "test-model-alpha")
                    StartedAt = [datetime]::UtcNow.AddMilliseconds(-25)
                    Status    = [string](& $get "status" "success")
                }
                foreach ($pair in @(
                        @("callId", "CallId"), @("errorCategory", "ErrorCategory"), @("error", "ErrorMessage"),
                        @("profile", "Profile"), @("modelSource", "ModelSource"))) {
                    $value = & $get $pair[0] $null
                    if ($null -ne $value) { $arguments[$pair[1]] = [string]$value }
                }
                foreach ($pair in @(
                        @("attempts", "Attempts"), @("httpStatus", "HttpStatus"), @("timeoutSec", "TimeoutSec"),
                        @("contextWindow", "ContextWindow"), @("estPromptTokens", "EstPromptTokens"))) {
                    $value = & $get $pair[0] $null
                    if ($null -ne $value) { $arguments[$pair[1]] = [long]$value }
                }
                $warnings = & $get "warnings" $null
                if ($null -ne $warnings) { $arguments.Warnings = [string[]]@($warnings) }
                $foreign = & $get "runId" $null
                $saved = $env:AI_HARNESS_RUN_ID
                try {
                    if ($null -ne $foreign) { $env:AI_HARNESS_RUN_ID = [string]$foreign }
                    Write-HarnessModelTelemetry @arguments
                }
                finally { $env:AI_HARNESS_RUN_ID = $saved }
            }
        }
    }
}
