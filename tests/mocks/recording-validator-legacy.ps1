param(
    [string]$SpecFile
)

# A simple script (no [Parameter] or [CmdletBinding]) that does not declare
# -Mode, so an unknown -Mode would land in $args instead of failing.
# Records "validator-legacy|args=<count of $args>" and passes (FR-019, AC-024).

$recordFile = $env:AI_HARNESS_TEST_RECORD_FILE
if ([string]::IsNullOrWhiteSpace($recordFile)) {
    Write-Host "AI_HARNESS_TEST_RECORD_FILE is not set."
    exit 1
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::AppendAllText($recordFile, "validator-legacy|args=$($args.Count)`r`n", $utf8NoBom)

Write-Host ""
Write-Host "=== MOCK VALIDATOR (LEGACY) ===" -ForegroundColor DarkCyan
Write-Host "Spec: $SpecFile"
Write-Host "STATUS: PASS"

exit 0
