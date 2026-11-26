param(
    [Parameter(Mandatory = $true)]
    [string]$Task,

    [Parameter(Mandatory = $true)]
    [string]$SpecFile,

    [string]$Mode,
    [string]$Model,
    [string]$OutputFile,
    [string]$ContextFile,
    [string]$Profile
)

# CLI mock of review-spec.ps1 that never finishes by itself (Phase 3 B5; AC-315).
# It writes "started" to AI_HARNESS_TEST_EVENT_FILE (the handshake: the run is in its
# stage, so its manifest says running), then sleeps until the test kills the process.
# If nobody does, it ends after 120 s with exit code 2 and no review file.

$eventFile = $env:AI_HARNESS_TEST_EVENT_FILE
if (-not [string]::IsNullOrWhiteSpace($eventFile)) {
    [System.IO.File]::WriteAllText($eventFile, "started", (New-Object System.Text.UTF8Encoding($false)))
}
Start-Sleep -Seconds 120
exit 2
