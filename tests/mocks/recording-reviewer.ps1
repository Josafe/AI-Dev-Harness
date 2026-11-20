param(
    [Parameter(Mandatory = $true)]
    [string]$Task,

    [Parameter(Mandatory = $true)]
    [string]$SpecFile,
    [string]$Mode,

    [string]$Model,

    [string]$OutputFile
)

# Records -Mode as "reviewer|<mode>" ("(not passed)" when omitted).
# Returns FAIL on its first call per record file, and PASS after that (FR-017).

$recordFile = $env:AI_HARNESS_TEST_RECORD_FILE
if ([string]::IsNullOrWhiteSpace($recordFile)) {
    Write-Host "AI_HARNESS_TEST_RECORD_FILE is not set."
    exit 1
}

$previousCalls = 0
if (Test-Path -LiteralPath $recordFile -PathType Leaf) {
    $previousCalls = @([System.IO.File]::ReadAllLines($recordFile) | Where-Object { $_ -like "reviewer|*" }).Count
}

$received = if ($PSBoundParameters.ContainsKey("Mode")) { $Mode } else { "(not passed)" }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::AppendAllText($recordFile, "reviewer|$received`r`n", $utf8NoBom)

$status = if ($previousCalls -eq 0) { "FAIL" } else { "PASS" }

$review = @"
# Specification Review

## Status

$status

## Summary

Recording mock reviewer.

## Findings

None.

## Unsupported Requirements

None.

## Missing Open Questions

None.

## Final Decision

$status
"@

if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
    [System.IO.File]::WriteAllText($OutputFile, $review, $utf8NoBom)
}

Write-Host ""
Write-Host "=== MOCK REVIEWER (RECORDING) ===" -ForegroundColor DarkCyan
Write-Host "Review Status: $status"

if ($status -eq "PASS") {
    exit 0
}

exit 1
