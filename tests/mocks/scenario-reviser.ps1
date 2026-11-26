param(
    [Parameter(Mandatory = $true)]
    [string]$Task,

    [Parameter(Mandatory = $true)]
    [string]$SpecFile,

    [Parameter(Mandatory = $true)]
    [string]$ReviewFile,

    [string]$Mode,
    [string]$Model,
    [string]$OutputFile,
    [string]$ContextFile,
    [string]$Profile
)

# Scenario mock of revise-spec.ps1 (Phase 3 B2; AC-303, AC-304, AC-330).
# Records like scenario-runner.ps1 ("reviser|..."), prints
# "ANSWER reviser <n>", then: ok (write a spec, exit 0), exitN (write nothing,
# exit N), nooutput (exit 0), empty (empty file, exit 0), throw, noexit (write
# a spec, no exit statement).

$stage = "reviser"
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
Write-Host "=== MOCK REVISER (SCENARIO) === $action"

$spec = "# Specification`r`n`r`n## Goal`r`n`r`nRevised scenario specification.`r`n"

if ($action -eq "throw") { throw "mock $stage failure" }
if ($action -eq "nooutput") { exit 0 }
if ($action -eq "empty") { [System.IO.File]::WriteAllText($OutputFile, "", $utf8NoBom); exit 0 }
if ($action -match '^exit(\d+)$') { exit ([int]$Matches[1]) }
[System.IO.File]::WriteAllText($OutputFile, $spec, $utf8NoBom)
if ($action -eq "noexit") { return }
exit 0
