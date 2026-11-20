<#
.SYNOPSIS
    Offline regression suite for the modes of scripts\validate-spec.ps1 (FR-016).

.DESCRIPTION
    Runs the real validator in a child Windows PowerShell 5.1 process, once
    per fixture and mode, and checks exit codes and output lines
    (AC-001 to AC-008, AC-025, AC-026).

    - Reads files only. It writes nothing, needs no Ollama and no network,
      and runs from the temp folder as its working directory.
    - Assertions match only exit codes and the validator's own fixed wording,
      line by line. Nothing depends on localized PowerShell or .NET text or on
      console wrapping (NFR-006).
#>

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $PSScriptRoot "validate-spec.ps1"
$fixturesDirectory = Join-Path $root "tests\fixtures"
$powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

foreach ($path in @($validator, $fixturesDirectory, $powerShellExe)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required path not found: $path"
    }
}

$script:passed = 0
$script:failed = 0
$script:runs = @{}

$header = "=== Specification Validator ==="
$insufficientInput = "The task did not contain enough information. See Open Questions."
$frSectionError = "- Functional Requirements section must be None or contain at least one '### FR-n' entry."
$acSectionError = "- Acceptance Criteria section must be None or contain at least one '### AC-n' entry."

# Runs the validator once per fixture and mode (cached). $Mode = "" means no -Mode.
function Get-ValidatorRun {
    param(
        [string]$Fixture,
        [string]$Mode = ""
    )

    $key = "$Fixture|$Mode"
    if ($script:runs.ContainsKey($key)) { return $script:runs[$key] }

    $specPath = Join-Path $fixturesDirectory $Fixture
    if (-not (Test-Path -LiteralPath $specPath -PathType Leaf)) {
        $run = [pscustomobject]@{ ExitCode = $null; Lines = @(); Error = "fixture not found: $specPath" }
        $script:runs[$key] = $run
        return $run
    }

    $arguments = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", $validator, "-SpecFile", $specPath)
    if ($Mode -ne "") { $arguments += @("-Mode", $Mode) }

    # Error records from the child's stderr are dropped: they are PowerShell
    # text, never asserted on (NFR-006).
    $ErrorActionPreference = "Continue"
    $raw = @(& $powerShellExe @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"

    $lines = @($raw |
        Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
        ForEach-Object { [string]$_ })

    $run = [pscustomobject]@{ ExitCode = $exitCode; Lines = $lines; Error = "" }
    $script:runs[$key] = $run
    return $run
}

function Get-ModeLabel {
    param([string]$Mode)
    if ($Mode -eq "") { return "no -Mode" }
    return "-Mode $Mode"
}

function Write-Result {
    param(
        [string]$Name,
        [string[]]$Problems,
        $Run
    )

    if ($Problems.Count -eq 0) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
        $script:passed++
        return
    }

    Write-Host "[FAIL] $Name" -ForegroundColor Red
    foreach ($problem in $Problems) { Write-Host "       $problem" -ForegroundColor Red }
    Write-Host "       actual exit code: $($Run.ExitCode)"
    foreach ($line in $Run.Lines) { Write-Host "       | $line" }
    $script:failed++
}

# Exit code plus lines that must, or must not, appear (exact, case-sensitive).
function Assert-ValidatorResult {
    param(
        [string]$Id,
        [string]$Fixture,
        [string]$Mode = "",
        [int]$ExpectedExitCode = 0,
        [switch]$ExpectNonZero,
        [string[]]$RequiredLines = @(),
        [string[]]$ForbiddenLines = @()
    )

    $run = Get-ValidatorRun -Fixture $Fixture -Mode $Mode
    $name = "$Id $Fixture ($(Get-ModeLabel $Mode))"
    $problems = @()

    if ($run.Error) { $problems += $run.Error }
    elseif ($ExpectNonZero) {
        if ($run.ExitCode -eq 0) { $problems += "expected a non-zero exit code" }
    }
    elseif ($run.ExitCode -ne $ExpectedExitCode) {
        $problems += "expected exit code $ExpectedExitCode"
    }

    foreach ($line in $RequiredLines) {
        if (-not ($run.Lines -ccontains $line)) { $problems += "missing line: $line" }
    }
    foreach ($line in $ForbiddenLines) {
        if ($run.Lines -ccontains $line) { $problems += "unexpected line: $line" }
    }

    Write-Result -Name $name -Problems $problems -Run $run
}

# AC-026: the output, without blank lines and the File: line, is exactly the
# header followed by the given lines. (The validator prints no mode line.)
function Assert-ValidatorLines {
    param(
        [string]$Id,
        [string]$Fixture,
        [string]$Mode = "",
        [string[]]$ExpectedAfterHeader
    )

    $run = Get-ValidatorRun -Fixture $Fixture -Mode $Mode
    $name = "$Id $Fixture ($(Get-ModeLabel $Mode)): output lines"
    $problems = @()

    if ($run.Error) { $problems += $run.Error }
    else {
        $actual = @($run.Lines | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith("File: ")
        })
        $expected = @($header) + $ExpectedAfterHeader

        if ($actual.Count -ne $expected.Count) {
            $problems += "expected $($expected.Count) lines, got $($actual.Count)"
        }
        $count = [math]::Min($actual.Count, $expected.Count)
        for ($i = 0; $i -lt $count; $i++) {
            if ($actual[$i] -cne $expected[$i]) {
                $problems += "line $($i + 1): expected '$($expected[$i])', got '$($actual[$i])'"
            }
        }
    }

    Write-Result -Name $name -Problems $problems -Run $run
}

Push-Location -LiteralPath ([System.IO.Path]::GetTempPath())
try {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "     VALIDATOR MODE TEST SUITE" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""

    $nonDocumentationModes = @("", "requirements", "baseline")

    # AC-001: exit codes without documentation mode are unchanged.
    $expectedExitCodes = [ordered]@{
        "invalid-spec.md"                      = 1
        "minimal-valid-spec.md"                = 0
        "semantic-invalid-spec.md"             = 0
        "valid-spec.md"                        = 1
        "documentation-none-spec.md"           = 3
        "documentation-lowercase-none-spec.md" = 3
        "documentation-fenced-none-spec.md"    = 3
        "documentation-none-period-spec.md"    = 1
    }
    foreach ($mode in $nonDocumentationModes) {
        foreach ($fixture in $expectedExitCodes.Keys) {
            Assert-ValidatorResult -Id "AC-001" -Fixture $fixture -Mode $mode -ExpectedExitCode $expectedExitCodes[$fixture]
        }
    }
    Assert-ValidatorResult -Id "AC-001 invalid mode" -Fixture "minimal-valid-spec.md" -Mode "foo" `
        -ExpectNonZero -ForbiddenLines @("STATUS: PASS")

    # AC-002: a descriptive documentation spec passes.
    Assert-ValidatorResult -Id "AC-002" -Fixture "documentation-none-spec.md" -Mode "documentation" `
        -ExpectedExitCode 0 -RequiredLines @("STATUS: PASS")

    # AC-003: missing documentation context is insufficient input.
    foreach ($fixture in @("documentation-no-context-spec.md", "documentation-empty-context-spec.md")) {
        Assert-ValidatorResult -Id "AC-003" -Fixture $fixture -Mode "documentation" `
            -ExpectedExitCode 3 -RequiredLines @("STATUS: INSUFFICIENT INPUT")
    }

    # AC-004: FR without AC is rejected.
    Assert-ValidatorResult -Id "AC-004" -Fixture "documentation-fr-without-ac-spec.md" -Mode "documentation" `
        -ExpectedExitCode 1 -RequiredLines @("STATUS: FAIL", "- No acceptance criteria found.")

    # AC-005: FR with AC passes.
    foreach ($fixture in @("documentation-fr-with-ac-spec.md", "minimal-valid-spec.md", "semantic-invalid-spec.md")) {
        Assert-ValidatorResult -Id "AC-005" -Fixture $fixture -Mode "documentation" `
            -ExpectedExitCode 0 -RequiredLines @("STATUS: PASS")
    }

    # AC-006: invalid Source values are rejected.
    Assert-ValidatorResult -Id "AC-006" -Fixture "documentation-invalid-source-spec.md" -Mode "documentation" `
        -ExpectedExitCode 1 `
        -RequiredLines @("STATUS: FAIL", "- Invalid requirement source: 'GUESS'. Allowed values: USER, PROJECT, FACT, ASSUMPTION.")

    # AC-007: entries without Source are rejected.
    Assert-ValidatorResult -Id "AC-007" -Fixture "documentation-entry-without-source-spec.md" -Mode "documentation" `
        -ExpectedExitCode 1 -RequiredLines @("STATUS: FAIL", "- No requirement source annotations found.")

    # AC-008: unstructured FR or AC sections are rejected, naming the section.
    Assert-ValidatorResult -Id "AC-008" -Fixture "documentation-prose-fr-spec.md" -Mode "documentation" `
        -ExpectedExitCode 1 -RequiredLines @("STATUS: FAIL", $frSectionError) -ForbiddenLines @($acSectionError)
    Assert-ValidatorResult -Id "AC-008" -Fixture "documentation-prose-ac-spec.md" -Mode "documentation" `
        -ExpectedExitCode 1 -RequiredLines @("STATUS: FAIL", $acSectionError) -ForbiddenLines @($frSectionError)

    # AC-025: None-marker semantics in documentation mode. (The non-documentation
    # exit codes are in AC-001; the three None. errors are in AC-026.)
    foreach ($fixture in @("documentation-lowercase-none-spec.md", "documentation-fenced-none-spec.md")) {
        Assert-ValidatorResult -Id "AC-025" -Fixture $fixture -Mode "documentation" `
            -ExpectedExitCode 0 -RequiredLines @("STATUS: PASS")
    }
    Assert-ValidatorResult -Id "AC-025" -Fixture "documentation-none-period-spec.md" -Mode "documentation" `
        -ExpectedExitCode 1 -RequiredLines @("STATUS: FAIL", $frSectionError) `
        -ForbiddenLines @("STATUS: INSUFFICIENT INPUT")

    # AC-026: output lines in non-documentation modes are unchanged.
    $expectedLines = [ordered]@{
        "invalid-spec.md" = @(
            "STATUS: FAIL", "Missing required sections:",
            "- ## Context", "- ## Functional Requirements", "- ## Non-Functional Requirements",
            "- ## Acceptance Criteria", "- ## Edge Cases", "- ## Dependencies",
            "- ## Open Questions", "- ## Assumptions")
        "valid-spec.md" = @(
            "STATUS: FAIL", "Validation errors:", "- No requirement source annotations found.")
        "minimal-valid-spec.md" = @(
            "STATUS: PASS", "All required specification checks passed.")
        "documentation-none-spec.md" = @(
            "STATUS: INSUFFICIENT INPUT", $insufficientInput)
        "documentation-none-period-spec.md" = @(
            "STATUS: FAIL", "Validation errors:", "- No functional requirements found.",
            "- No acceptance criteria found.", "- No requirement source annotations found.")
    }
    foreach ($mode in $nonDocumentationModes) {
        foreach ($fixture in $expectedLines.Keys) {
            Assert-ValidatorLines -Id "AC-026" -Fixture $fixture -Mode $mode -ExpectedAfterHeader $expectedLines[$fixture]
        }
    }
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "              TEST SUMMARY" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Validator runs: $($script:runs.Count)"
Write-Host "Passed: $script:passed"
Write-Host "Failed: $script:failed"
Write-Host ""

if ($script:failed -eq 0 -and $script:passed -gt 0) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "STATUS: FAIL" -ForegroundColor Red
exit 1
