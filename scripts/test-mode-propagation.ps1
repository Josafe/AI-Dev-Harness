<#
.SYNOPSIS
    Offline regression suite: -Mode passed through the specification workflow
    (FR-017; AC-010, AC-011, AC-023, AC-024).

.DESCRIPTION
    Runs scripts\specify.ps1 in a child Windows PowerShell 5.1 process with
    recording mocks. The mocks append what each stage received to the file
    named by AI_HARNESS_TEST_RECORD_FILE, which this suite places under TEMP.

    - Every scenario injects all four scripts (-RunnerScript, -ValidatorScript,
      -ReviewerScript, -ReviserScript). Only AC-011 injects the real
      validate-spec.ps1; everything else is a mock. The real run-agent.ps1,
      review-spec.ps1 and revise-spec.ps1 are never invoked.
    - specify.ps1 writes test-mock-mode-* files into <root>\specs, so test-all
      runs this suite in a sandbox. Record files and the generated validator
      that fails to parse live in a TEMP folder that is deleted at the end.
    - Assertions match only exit codes, record entries and the harness's own
      fixed wording, line by line. Nothing depends on localized PowerShell or
      .NET text or on console wrapping (NFR-006).
#>

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$specify = Join-Path $PSScriptRoot "specify.ps1"
$realValidator = Join-Path $PSScriptRoot "validate-spec.ps1"
$mocksDirectory = Join-Path $root "tests\mocks"
$powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

foreach ($path in @($specify, $realValidator, $mocksDirectory, $powerShellExe)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required path not found: $path"
    }
}

$workDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-harness-mode-propagation-" + [guid]::NewGuid().ToString())
[void][System.IO.Directory]::CreateDirectory($workDirectory)

$script:passed = 0
$script:failed = 0

$warningPrefix = "WARNING: "
$rulesNotApplied = "documentation-mode validation rules are NOT applied"
$plainSummary = "Validation   : PASS"
$withoutModeSummary = "Validation   : PASS (validator called without -Mode; documentation-mode rules NOT applied)"

function Get-MockPath {
    param([string]$Name)

    $path = Join-Path $mocksDirectory $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required mock not found: $path"
    }
    return $path
}

# Runs specify.ps1 with all four scripts injected. $Mode = "" means no -Mode.
function Invoke-Specify {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Mode = "",
        [Parameter(Mandatory = $true)][string]$Runner,
        [Parameter(Mandatory = $true)][string]$Validator,
        [Parameter(Mandatory = $true)][string]$Reviewer,
        [Parameter(Mandatory = $true)][string]$Reviser
    )

    $recordFile = Join-Path $workDirectory "$Name.record.txt"
    if (Test-Path -LiteralPath $recordFile) { Remove-Item -LiteralPath $recordFile -Force }

    $arguments = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", $specify,
        "-Task", "Deterministic test task",
        "-Name", $Name,
        "-RunnerScript", $Runner,
        "-ValidatorScript", $Validator,
        "-ReviewerScript", $Reviewer,
        "-ReviserScript", $Reviser)
    if ($Mode -ne "") { $arguments += @("-Mode", $Mode) }

    # Error records from the child's stderr are dropped: they are PowerShell
    # text, never asserted on (NFR-006).
    $env:AI_HARNESS_TEST_RECORD_FILE = $recordFile
    $ErrorActionPreference = "Continue"
    try {
        $raw = @(& $powerShellExe @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = "Stop"
        Remove-Item Env:\AI_HARNESS_TEST_RECORD_FILE -ErrorAction SilentlyContinue
    }

    $lines = @($raw |
        Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
        ForEach-Object { [string]$_ })

    $record = @()
    if (Test-Path -LiteralPath $recordFile -PathType Leaf) {
        $record = @([System.IO.File]::ReadAllLines($recordFile) | Where-Object { $_ -ne "" })
    }

    return [pscustomobject]@{ ExitCode = $exitCode; Lines = $lines; Record = $record }
}

function Get-WarningLines {
    param([string[]]$Lines)
    return @($Lines | Where-Object { $_.StartsWith($warningPrefix, [System.StringComparison]::Ordinal) })
}

function Get-PrefixCount {
    param([string]$Line)
    return [regex]::Matches($Line, [regex]::Escape($warningPrefix)).Count
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
    if ($null -ne $Run) {
        Write-Host "       actual exit code: $($Run.ExitCode)"
        foreach ($entry in $Run.Record) { Write-Host "       record: $entry" }
        foreach ($line in $Run.Lines) { Write-Host "       | $line" }
    }
    $script:failed++
}

# Runs one scenario; any unexpected exception is a failed assertion.
function Invoke-Scenario {
    param(
        [string]$Name,
        [scriptblock]$Body
    )

    try {
        $result = & $Body
        Write-Result -Name $Name -Problems @($result.Problems) -Run $result.Run
    }
    catch {
        Write-Result -Name $Name -Problems @("scenario error: $($_.Exception.GetType().Name)") -Run $null
    }
}

function Compare-Record {
    param(
        [string[]]$Actual,
        [string[]]$Expected
    )

    $problems = @()
    if (($Actual -join "`n") -cne ($Expected -join "`n")) {
        $problems += "expected record: " + ($Expected -join ", ")
        $problems += "actual record  : " + ($Actual -join ", ")
    }
    return $problems
}

try {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "    MODE PROPAGATION TEST SUITE" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""

    $recordingRunner = Get-MockPath "recording-runner.ps1"
    $recordingValidator = Get-MockPath "recording-validator.ps1"
    $legacyValidator = Get-MockPath "recording-validator-legacy.ps1"
    $recordingReviewer = Get-MockPath "recording-reviewer.ps1"
    $recordingReviser = Get-MockPath "recording-reviser.ps1"

    # AC-010: the mode reaches every stage, through one revision cycle.
    foreach ($case in @(
            @{ Mode = "requirements"; Expected = "requirements" },
            @{ Mode = "baseline"; Expected = "baseline" },
            @{ Mode = "documentation"; Expected = "documentation" },
            @{ Mode = ""; Expected = "requirements" })) {

        $mode = $case.Mode
        $expected = $case.Expected
        $label = if ($mode -eq "") { "no -Mode" } else { "-Mode $mode" }
        $suffix = if ($mode -eq "") { "default" } else { $mode }

        Invoke-Scenario -Name "AC-010 mode reaches every stage ($label)" -Body {
            $run = Invoke-Specify -Name "test-mock-mode-propagation-$suffix" -Mode $mode `
                -Runner $recordingRunner -Validator $recordingValidator `
                -Reviewer $recordingReviewer -Reviser $recordingReviser
            $problems = @()
            if ($run.ExitCode -ne 0) { $problems += "expected exit code 0" }
            $problems += @(Compare-Record -Actual $run.Record -Expected @(
                "runner|$expected", "validator|$expected", "reviewer|$expected",
                "reviser|$expected", "validator|$expected", "reviewer|$expected"))
            @{ Problems = $problems; Run = $run }
        }
    }

    # AC-011: end-to-end documentation run with the real validator.
    Invoke-Scenario -Name "AC-011 documentation run with the real validator" -Body {
        $run = Invoke-Specify -Name "test-mock-mode-documentation-e2e" -Mode "documentation" `
            -Runner (Get-MockPath "runner-documentation.ps1") -Validator $realValidator `
            -Reviewer (Get-MockPath "reviewer-pass.ps1") -Reviser (Get-MockPath "reviser-success.ps1")
        $problems = @()
        if ($run.ExitCode -ne 0) { $problems += "expected exit code 0" }
        if ((Get-WarningLines $run.Lines).Count -ne 0) { $problems += "expected no FR-019 warning" }
        @{ Problems = $problems; Run = $run }
    }
    Invoke-Scenario -Name "AC-011 same run without -Mode needs human input" -Body {
        $run = Invoke-Specify -Name "test-mock-mode-documentation-e2e-default" `
            -Runner (Get-MockPath "runner-documentation.ps1") -Validator $realValidator `
            -Reviewer (Get-MockPath "reviewer-pass.ps1") -Reviser (Get-MockPath "reviser-success.ps1")
        $problems = @()
        if ($run.ExitCode -ne 3) { $problems += "expected exit code 3" }
        if (-not ($run.Lines -ccontains "=== Specification Needs Human Input ===")) {
            $problems += "missing line: === Specification Needs Human Input ==="
        }
        @{ Problems = $problems; Run = $run }
    }

    # AC-023: an advanced validator without -Mode ("not declared").
    $classicScripts = @{
        Runner    = (Get-MockPath "runner-success.ps1")
        Validator = (Get-MockPath "validator-success.ps1")
        Reviewer  = (Get-MockPath "reviewer-pass.ps1")
        Reviser   = (Get-MockPath "reviser-success.ps1")
    }

    Invoke-Scenario -Name "AC-023 validator without -Mode (-Mode documentation)" -Body {
        $run = Invoke-Specify -Name "test-mock-mode-undeclared-documentation" -Mode "documentation" @classicScripts
        $problems = @()
        if ($run.ExitCode -ne 0) { $problems += "expected exit code 0 (so -Mode was not passed)" }
        $warnings = @(Get-WarningLines $run.Lines)
        if ($warnings.Count -ne 1) { $problems += "expected exactly one line starting with '$warningPrefix', got $($warnings.Count)" }
        else {
            if ((Get-PrefixCount $warnings[0]) -ne 1) { $problems += "the warning line must contain '$warningPrefix' exactly once" }
            if (-not $warnings[0].Contains("does not declare a -Mode parameter")) { $problems += "warning lacks 'does not declare a -Mode parameter'" }
            if (-not $warnings[0].Contains($rulesNotApplied)) { $problems += "warning lacks '$rulesNotApplied' on the same line" }
        }
        if (@($run.Lines | Where-Object { $_.Contains("WARNING: WARNING:") }).Count -gt 0) { $problems += "output contains 'WARNING: WARNING:'" }
        if (-not ($run.Lines -ccontains $withoutModeSummary)) { $problems += "missing summary line: $withoutModeSummary" }
        @{ Problems = $problems; Run = $run }
    }
    Invoke-Scenario -Name "AC-023 validator without -Mode (-Mode baseline)" -Body {
        $run = Invoke-Specify -Name "test-mock-mode-undeclared-baseline" -Mode "baseline" @classicScripts
        $problems = @()
        if ($run.ExitCode -ne 0) { $problems += "expected exit code 0" }
        if ((Get-WarningLines $run.Lines).Count -ne 0) { $problems += "expected no FR-019 warning" }
        if (-not ($run.Lines -ccontains $plainSummary)) { $problems += "missing summary line: $plainSummary" }
        @{ Problems = $problems; Run = $run }
    }

    # AC-024: a simple validator without -Mode, at both invocation points.
    Invoke-Scenario -Name "AC-024 simple validator without -Mode gets no -Mode at either point" -Body {
        $run = Invoke-Specify -Name "test-mock-mode-legacy" -Mode "documentation" `
            -Runner $recordingRunner -Validator $legacyValidator `
            -Reviewer $recordingReviewer -Reviser $recordingReviser
        $problems = @()
        if ($run.ExitCode -ne 0) { $problems += "expected exit code 0" }
        $validatorEntries = @($run.Record | Where-Object { $_.StartsWith("validator-legacy|", [System.StringComparison]::Ordinal) })
        if ($validatorEntries.Count -ne 2) { $problems += "expected two validator entries, got $($validatorEntries.Count)" }
        foreach ($entry in $validatorEntries) {
            if ($entry -cne "validator-legacy|args=0") { $problems += "expected validator-legacy|args=0, got $entry" }
        }
        @{ Problems = $problems; Run = $run }
    }

    # AC-024: a validator that fails to parse ("not confirmed").
    $brokenValidator = Join-Path $workDirectory "validator-parse-error.ps1"
    [System.IO.File]::WriteAllText($brokenValidator,
        "param([Parameter(Mandatory = `$true)][string]`$SpecFile)`r`nif (`$true {`r`n",
        (New-Object System.Text.UTF8Encoding($false)))

    foreach ($mode in @("requirements", "documentation")) {
        Invoke-Scenario -Name "AC-024 validator that fails to parse (-Mode $mode)" -Body {
            $run = Invoke-Specify -Name "test-mock-mode-parse-error-$mode" -Mode $mode `
                -Runner $recordingRunner -Validator $brokenValidator `
                -Reviewer $recordingReviewer -Reviser $recordingReviser
            $problems = @()
            if ($run.ExitCode -ne 2) { $problems += "expected exit code 2" }
            $problems += @(Compare-Record -Actual $run.Record -Expected @("runner|$mode"))
            $warnings = @(Get-WarningLines $run.Lines)
            if ($mode -eq "requirements") {
                if ($warnings.Count -ne 0) { $problems += "expected no FR-019 warning" }
            }
            elseif ($warnings.Count -ne 1) {
                $problems += "expected exactly one line starting with '$warningPrefix', got $($warnings.Count)"
            }
            else {
                if ((Get-PrefixCount $warnings[0]) -ne 1) { $problems += "the warning line must contain '$warningPrefix' exactly once" }
                if (-not $warnings[0].Contains("support for -Mode could not be confirmed")) { $problems += "warning lacks 'support for -Mode could not be confirmed'" }
                if (-not $warnings[0].Contains($rulesNotApplied)) { $problems += "warning lacks '$rulesNotApplied' on the same line" }
                if ($warnings[0].Contains("does not declare")) { $problems += "warning must not contain 'does not declare'" }
            }
            @{ Problems = $problems; Run = $run }
        }
    }
}
finally {
    Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "              TEST SUMMARY" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Passed: $script:passed"
Write-Host "Failed: $script:failed"
Write-Host ""

if ($script:failed -eq 0 -and $script:passed -gt 0) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "STATUS: FAIL" -ForegroundColor Red
exit 1
