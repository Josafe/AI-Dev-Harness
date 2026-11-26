<#
.SYNOPSIS
    AC-323 check: the case names of the three engine call-site suites against the
    names printed by the old single suite. Not a suite (not named test-*).

.DESCRIPTION
    The reference is tests\fixtures\engine-callsites-cases.txt: one case name per line,
    in the order the old scripts\test-engine-callsites.ps1 printed them (the text
    after "[PASS] ", at the commit before the split, FR-314 already done).

    Two kinds of name are in it:
      - the startup proofs of the four guards, whose names begin with "guard ":
        every suite runs the four guards (FR-315), so every suite prints each of
        them once. This is the only addition AC-323 lets a suite make.
      - the cases: each one is printed by exactly one suite.

    The check FAILS (exit 1) on any of:
      - a case of the fixture that no suite printed (missing);
      - a case printed by two suites, or twice by one (duplicated);
      - a case that is not in the fixture (renamed or invented; a rename shows as
        one missing and one unknown name);
      - a suite whose guard proofs are not exactly the fixture's, once each;
      - a [FAIL] line, a log without "STATUS: PASS", or a "Passed:" count that is
        not the number of [PASS] lines;
      - total [PASS] lines not equal to cases + guards x number of suites.

.PARAMETER Fixture
    The reference list. Default: ..\fixtures\engine-callsites-cases.txt.

.PARAMETER LogPath
    Console logs of the suites (the output of one run each). Use this or -RunSuites.

.PARAMETER RunSuites
    Run the three suites from ..\..\scripts in child Windows PowerShell 5.1
    processes, one after the other, and check their output.

.PARAMETER SuiteName
    The suites to run with -RunSuites.
#>
param(
    [string]$Fixture = "",
    [string[]]$LogPath = @(),
    [switch]$RunSuites,
    [string[]]$SuiteName = @("test-engine-callsites-run-agent.ps1", "test-engine-callsites-review-spec.ps1", "test-engine-callsites-revise-spec.ps1")
)

$ErrorActionPreference = "Stop"

$libDirectory = $PSScriptRoot
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $libDirectory "..\.."))
# powershell.exe -File passes "a,b" as one string: split it.
$LogPath = @($LogPath | ForEach-Object { $_ -split "," } | Where-Object { $_ -ne "" })
$SuiteName = @($SuiteName | ForEach-Object { $_ -split "," } | Where-Object { $_ -ne "" })
if ([string]::IsNullOrWhiteSpace($Fixture)) { $Fixture = Join-Path $repositoryRoot "tests\fixtures\engine-callsites-cases.txt" }

if (-not (Test-Path -LiteralPath $Fixture -PathType Leaf)) { throw "Fixture not found: $Fixture" }

$logs = [ordered]@{}
if ($RunSuites) {
    $powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    foreach ($name in $SuiteName) {
        $suitePath = Join-Path $repositoryRoot "scripts\$name"
        if (-not (Test-Path -LiteralPath $suitePath -PathType Leaf)) { throw "Suite not found: $suitePath" }
        $started = Get-Date
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try { $lines = @(& $powerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $suitePath 2>&1 | ForEach-Object { [string]$_ }) }
        finally { $ErrorActionPreference = $previous }
        $logs[$name] = $lines
        Write-Host ("ran {0}: {1} lines, {2:N0} s" -f $name, $lines.Count, ((Get-Date) - $started).TotalSeconds)
    }
}
foreach ($path in $LogPath) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Log not found: $path" }
    $logs[[System.IO.Path]::GetFileName($path)] = @([System.IO.File]::ReadAllLines($path))
}
if ($logs.Count -eq 0) { throw "Give -LogPath or -RunSuites." }

$problems = New-Object System.Collections.Generic.List[string]

# --- the reference ---
$reference = @([System.IO.File]::ReadAllLines($Fixture) | Where-Object { $_.Trim() -ne "" })
$seen = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
foreach ($name in $reference) {
    if ($seen.ContainsKey($name)) { $problems.Add("fixture: duplicated name: $name") }
    $seen[$name] = $true
}
$referenceGuards = @($reference | Where-Object { $_.StartsWith("guard ", [System.StringComparison]::Ordinal) })
$referenceCases = @($reference | Where-Object { -not $_.StartsWith("guard ", [System.StringComparison]::Ordinal) })

# --- the logs ---
$caseCount = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
$totalPass = 0
foreach ($suite in $logs.Keys) {
    $lines = $logs[$suite]
    $pass = @($lines | Where-Object { $_.StartsWith("[PASS] ", [System.StringComparison]::Ordinal) } | ForEach-Object { $_.Substring(7) })
    $fail = @($lines | Where-Object { $_.StartsWith("[FAIL] ", [System.StringComparison]::Ordinal) })
    $totalPass += $pass.Count

    foreach ($line in $fail) { $problems.Add("${suite}: $line") }
    if (-not ($lines -ccontains "STATUS: PASS")) { $problems.Add("${suite}: no 'STATUS: PASS' line") }
    $passedLine = @($lines | Where-Object { $_ -match '^Passed: \d+$' }) | Select-Object -Last 1
    if ($null -eq $passedLine) { $problems.Add("${suite}: no 'Passed: n' line") }
    elseif ([int]($passedLine -replace '^Passed: ', '') -ne $pass.Count) { $problems.Add("${suite}: '$passedLine' but $($pass.Count) [PASS] lines") }

    $guards = @($pass | Where-Object { $_.StartsWith("guard ", [System.StringComparison]::Ordinal) })
    foreach ($guard in $referenceGuards) {
        $times = @($guards | Where-Object { $_ -ceq $guard }).Count
        if ($times -ne 1) { $problems.Add("${suite}: guard proof printed $times times (must be once): $guard") }
    }
    foreach ($guard in $guards) {
        if ($referenceGuards -cnotcontains $guard) { $problems.Add("${suite}: guard proof not in the fixture: $guard") }
    }

    foreach ($name in @($pass | Where-Object { -not $_.StartsWith("guard ", [System.StringComparison]::Ordinal) })) {
        if (-not $caseCount.ContainsKey($name)) { $caseCount[$name] = @() }
        $caseCount[$name] += $suite
    }
}

foreach ($name in $referenceCases) {
    if (-not $caseCount.ContainsKey($name)) { $problems.Add("MISSING (in the fixture, in no suite): $name") }
}
foreach ($name in $caseCount.Keys) {
    if ($caseCount[$name].Count -gt 1) { $problems.Add("DUPLICATED ($($caseCount[$name].Count) times, in $($caseCount[$name] -join ', ')): $name") }
    if ($referenceCases -cnotcontains $name) { $problems.Add("UNKNOWN (not in the fixture: renamed or added, in $($caseCount[$name] -join ', ')): $name") }
}

$expectedPass = $referenceCases.Count + ($referenceGuards.Count * $logs.Count)
if ($totalPass -ne $expectedPass) {
    $problems.Add("count: $totalPass [PASS] lines, expected $expectedPass ($($referenceCases.Count) cases + $($referenceGuards.Count) guard proofs x $($logs.Count) suites)")
}

Write-Host ""
Write-Host "AC-323 case-name check"
Write-Host "  fixture   : $($reference.Count) names ($($referenceCases.Count) cases, $($referenceGuards.Count) guard proofs)"
Write-Host "  suites    : $($logs.Count) ($($logs.Keys -join ', '))"
Write-Host "  [PASS]    : $totalPass (expected $expectedPass)"
if ($problems.Count -gt 0) {
    foreach ($problem in @($problems | Select-Object -First 40)) { Write-Host "  PROBLEM: $problem" }
    if ($problems.Count -gt 40) { Write-Host "  ... and $($problems.Count - 40) more problems" }
    Write-Host "STATUS: FAIL"
    exit 1
}
Write-Host "STATUS: PASS"
exit 0
