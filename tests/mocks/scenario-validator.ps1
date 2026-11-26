param(
    [Parameter(Mandatory = $true)]
    [string]$SpecFile,

    [string]$Mode
)

# Scenario mock of validate-spec.ps1 (Phase 3 B2; AC-303, AC-330). Declares
# -Mode. Records like scenario-runner.ps1 ("validator|..."), prints
# "ANSWER validator <n>", then: ok (exit 0), exitN (exit N), throw, noexit
# (no exit statement).

$stage = "validator"
$recordFile = $env:AI_HARNESS_TEST_RECORD_FILE
if ([string]::IsNullOrWhiteSpace($recordFile)) {
    Write-Host "AI_HARNESS_TEST_RECORD_FILE is not set."
    exit 1
}

$previous = 0
if (Test-Path -LiteralPath $recordFile -PathType Leaf) {
    $previous = @([System.IO.File]::ReadAllLines($recordFile) | Where-Object { $_.StartsWith("$stage|", [System.StringComparison]::Ordinal) }).Count
}
$actions = @("ok")
foreach ($part in ([string]$env:AI_HARNESS_TEST_SCENARIO).Split(';')) {
    if ($part.StartsWith("$stage=", [System.StringComparison]::Ordinal)) { $actions = @($part.Substring($stage.Length + 1).Split(',')) }
}
$action = if ($previous -lt $actions.Count) { $actions[$previous] } else { $actions[$actions.Count - 1] }

$entry = $stage
$keys = [string[]]@($PSBoundParameters.Keys)
[Array]::Sort($keys, [System.StringComparer]::Ordinal)
foreach ($key in $keys) {
    $value = ([string]$PSBoundParameters[$key]).Replace('\', '\\').Replace("`r", '\r').Replace("`n", '\n')
    $entry += "|$key=$value"
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::AppendAllText($recordFile, "$entry`r`n", $utf8NoBom)

Write-Output "ANSWER $stage $($previous + 1)"
Write-Host "=== MOCK VALIDATOR (SCENARIO) === $action"

if ($action -eq "throw") { throw "mock $stage failure" }
if ($action -match '^exit(\d+)$') { exit ([int]$Matches[1]) }
if ($action -eq "noexit") { return }
exit 0
