param(
    [Parameter(Mandatory = $true)]
    [string]$SpecFile,

    [string]$Mode
)

# Declares -Mode and records the value it receives as "validator|<mode>",
# or "validator|(not passed)" when the caller omits -Mode. Always passes (FR-017).

$recordFile = $env:AI_HARNESS_TEST_RECORD_FILE
if ([string]::IsNullOrWhiteSpace($recordFile)) {
    Write-Host "AI_HARNESS_TEST_RECORD_FILE is not set."
    exit 1
}

$received = if ($PSBoundParameters.ContainsKey("Mode")) { $Mode } else { "(not passed)" }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::AppendAllText($recordFile, "validator|$received`r`n", $utf8NoBom)

Write-Host ""
Write-Host "=== MOCK VALIDATOR ===" -ForegroundColor DarkCyan
Write-Host "Spec: $SpecFile"
Write-Host "STATUS: PASS"

exit 0
