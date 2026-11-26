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

# Scenario mock of review-spec.ps1 (Phase 3 B2; AC-303, AC-304, AC-330).
# Records like scenario-runner.ps1 ("reviewer|..."), prints
# "ANSWER reviewer <n>", then: pass (PASS review, exit 0), fail (FAIL review,
# exit 1), exitN (no review, exit N), nooutput (no review, exit 0), throw,
# noexit (PASS review, no exit statement).

$stage = "reviewer"
$recordFile = $env:AI_HARNESS_TEST_RECORD_FILE
if ([string]::IsNullOrWhiteSpace($recordFile)) {
    Write-Host "AI_HARNESS_TEST_RECORD_FILE is not set."
    exit 1
}

$previous = 0
if (Test-Path -LiteralPath $recordFile -PathType Leaf) {
    $previous = @([System.IO.File]::ReadAllLines($recordFile) | Where-Object { $_.StartsWith("$stage|", [System.StringComparison]::Ordinal) }).Count
}
$actions = @("pass")
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
Write-Host "=== MOCK REVIEWER (SCENARIO) === $action"

if ($action -eq "throw") { throw "mock $stage failure" }
if ($action -eq "nooutput") { exit 0 }
if ($action -match '^exit(\d+)$') { exit ([int]$Matches[1]) }

$verdict = if ($action -eq "fail") { "FAIL" } else { "PASS" }
$review = "# Specification Review`r`n`r`n## Status`r`n`r`n$verdict`r`n`r`n## Final Decision`r`n`r`n$verdict`r`n"
[System.IO.File]::WriteAllText($OutputFile, $review, $utf8NoBom)

if ($action -eq "noexit") { return }
if ($verdict -eq "FAIL") { exit 1 }
exit 0
