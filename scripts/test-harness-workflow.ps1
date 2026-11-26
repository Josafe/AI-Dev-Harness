<#
.SYNOPSIS
    Offline suite of the shared specify workflow (Phase 3 B2): the stage
    contract (AC-330), -Profile on specify.ps1 (AC-304), the legacy parameters
    (AC-302 without the two -ContextFile additions of B7) and the legacy half
    of AC-303 (specify.ps1 calls, stdout and exit codes equal the frozen
    fixtures).

.DESCRIPTION
    Child-process cases copy scripts\specify.ps1 and scripts\lib\workflow.ps1
    into a fresh folder under TEMP and run that copy, so specify.ps1 writes its
    specs folder under TEMP and never into the repository. Stages are the
    scenario mocks tests\mocks\scenario-*.ps1, driven by
    AI_HARNESS_TEST_SCENARIO and recording to AI_HARNESS_TEST_RECORD_FILE.
    In-process cases dot-source scripts\lib\workflow.ps1 and call
    Invoke-SpecifyWorkflow and Invoke-HarnessFileStage directly. Nothing calls
    a model or the network. Assertions match exit codes, records, the
    harness's own fixed wording and the frozen fixture bytes, never localized
    PowerShell or .NET text.

    Record mode (-RecordFrom <specify.ps1> -RecordTo <folder>) writes the
    fixtures specify-calls-<scenario>.txt and specify-output-<scenario>.txt
    from the given specify.ps1, run alone (no lib folder). The committed
    fixtures were recorded from the specify.ps1 of tag phase2-calibrated
    (git show phase2-calibrated:scripts/specify.ps1), see
    docs\audits\2026-11-26-phase3-b2.md. Never record from the new code: the
    oracle is the unmodified script.

    -RecordParametersTag <tag> -RecordTo <file> writes legacy-parameters.json:
    name, type and mandatory flag of every parameter of the eight legacy
    scripts at that git tag, read with the PowerShell parser (AC-302). The
    committed file was recorded with tag phase2-calibrated.
#>
param(
    [string]$RecordFrom,
    [string]$RecordTo,
    [string]$RecordParametersTag
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$specifyScript = Join-Path $PSScriptRoot "specify.ps1"
$workflowLibrary = Join-Path $PSScriptRoot "lib\workflow.ps1"
$mocksDirectory = Join-Path $root "tests\mocks"
$fixturesDirectory = Join-Path $root "tests\fixtures"
$powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$latin1 = [System.Text.Encoding]::GetEncoding(28591)

$mockRunner = Join-Path $mocksDirectory "scenario-runner.ps1"
$mockValidator = Join-Path $mocksDirectory "scenario-validator.ps1"
$mockReviewer = Join-Path $mocksDirectory "scenario-reviewer.ps1"
$mockReviser = Join-Path $mocksDirectory "scenario-reviser.ps1"

$legacyScripts = @("benchmark-models.ps1", "build-context.ps1", "review-spec.ps1", "revise-spec.ps1",
    "run-agent.ps1", "scan-repository.ps1", "specify.ps1", "validate-spec.ps1")

# Name, type and mandatory flag of each parameter of a script text, in order,
# as "name|type|mandatory" lines (AC-302).
function Get-ScriptParameterLines {
    param([Parameter(Mandatory = $true)][string]$Text)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "The script does not parse." }
    $lines = @()
    if ($null -eq $ast.ParamBlock) { return $lines }
    foreach ($parameter in $ast.ParamBlock.Parameters) {
        $type = "object"
        $mandatory = $false
        foreach ($attribute in $parameter.Attributes) {
            if ($attribute -is [System.Management.Automation.Language.TypeConstraintAst]) {
                $type = $attribute.TypeName.FullName
            }
            elseif ($attribute -is [System.Management.Automation.Language.AttributeAst] -and $attribute.TypeName.Name -eq "Parameter") {
                foreach ($named in $attribute.NamedArguments) {
                    if ($named.ArgumentName -eq "Mandatory") {
                        $mandatory = ($named.ExpressionOmitted -or $named.Argument.Extent.Text -eq '$true')
                    }
                }
            }
        }
        $lines += "$($parameter.Name.VariablePath.UserPath)|$type|$($mandatory.ToString().ToLowerInvariant())"
    }
    return $lines
}

if ($PSBoundParameters.ContainsKey("RecordParametersTag")) {
    if ([string]::IsNullOrWhiteSpace($RecordTo)) { throw "-RecordTo is required with -RecordParametersTag." }
    $json = @("{", "  `"source`": `"git tag $RecordParametersTag, read with the PowerShell parser`",", "  `"scripts`": {")
    for ($i = 0; $i -lt $legacyScripts.Count; $i++) {
        $text = (@(& git -C $root show "$($RecordParametersTag):scripts/$($legacyScripts[$i])") -join "`n")
        if ($LASTEXITCODE -ne 0) { throw "git show failed for $($legacyScripts[$i])" }
        $parameterLines = @(Get-ScriptParameterLines -Text $text)
        $entries = @($parameterLines | ForEach-Object {
                $parts = $_.Split('|')
                "      { `"name`": `"$($parts[0])`", `"type`": `"$($parts[1])`", `"mandatory`": $($parts[2]) }"
            })
        $json += "    `"$($legacyScripts[$i])`": ["
        for ($j = 0; $j -lt $entries.Count; $j++) {
            $json += $entries[$j] + $(if ($j -lt $entries.Count - 1) { "," } else { "" })
        }
        $json += "    ]" + $(if ($i -lt $legacyScripts.Count - 1) { "," } else { "" })
    }
    $json += @("  }", "}")
    [System.IO.File]::WriteAllText($RecordTo, (($json -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Wrote $RecordTo"
    exit 0
}

$requiredFiles = @($mockRunner, $mockValidator, $mockReviewer, $mockReviser, $powerShellExe)
if (-not $PSBoundParameters.ContainsKey("RecordFrom")) { $requiredFiles += @($specifyScript, $workflowLibrary) }
foreach ($path in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file not found: $path"
    }
}

# Scenarios recorded from the legacy specify.ps1. The first 13 are AC-303 in its
# order (Legacy and Cli are the exit codes AC-303 lists); the others are B2
# additions that pin more legacy paths (throws, empty outputs, -Mode, -Model).
$scenarios = @(
    @{ Name = "pass-first-review";          Scenario = "reviewer=pass";                         Args = @(); Legacy = 0; Cli = 0 },
    @{ Name = "pass-after-revision";        Scenario = "reviewer=fail,pass";                    Args = @(); Legacy = 0; Cli = 0 },
    @{ Name = "fail-after-3-revisions";     Scenario = "reviewer=fail";                         Args = @(); Legacy = 1; Cli = 1 },
    @{ Name = "first-validation-exit-3";    Scenario = "validator=exit3";                       Args = @(); Legacy = 3; Cli = 3 },
    @{ Name = "first-validation-exit-1";    Scenario = "validator=exit1";                       Args = @(); Legacy = 2; Cli = 1 },
    @{ Name = "runner-exit-2";              Scenario = "runner=exit2";                          Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "reviewer-exit-2";            Scenario = "reviewer=exit2";                        Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "reviser-exit-2";             Scenario = "reviewer=fail;reviser=exit2";           Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "revised-validation-exit-1";  Scenario = "reviewer=fail;validator=ok,exit1";      Args = @(); Legacy = 2; Cli = 1 },
    @{ Name = "reviewer-exit-5";            Scenario = "reviewer=exit5";                        Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "runner-no-output";           Scenario = "runner=nooutput";                       Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "reviewer-throws";            Scenario = "reviewer=throw";                        Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "first-validation-exit-2";    Scenario = "validator=exit2";                       Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "runner-throws";              Scenario = "runner=throw";                          Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "validator-throws";           Scenario = "validator=throw";                       Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "reviser-throws";             Scenario = "reviewer=fail;reviser=throw";           Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "revised-validation-exit-3";  Scenario = "reviewer=fail;validator=ok,exit3";      Args = @(); Legacy = 2; Cli = 1 },
    @{ Name = "revised-validation-exit-2";  Scenario = "reviewer=fail;validator=ok,exit2";      Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "revised-validation-throws";  Scenario = "reviewer=fail;validator=ok,throw";      Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "runner-empty";               Scenario = "runner=empty";                          Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "reviewer-no-output";         Scenario = "reviewer=nooutput";                     Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "reviser-empty";              Scenario = "reviewer=fail;reviser=empty";           Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "reviser-no-output";          Scenario = "reviewer=fail;reviser=nooutput";        Args = @(); Legacy = 2; Cli = 2 },
    @{ Name = "mode-documentation";         Scenario = "reviewer=fail,pass";                    Args = @("-Mode", "documentation"); Legacy = 0; Cli = 0 },
    @{ Name = "model-bound";                Scenario = "reviewer=fail,pass";                    Args = @("-Model", "fixture-model:1b"); Legacy = 0; Cli = 0 },
    @{ Name = "invalid-name";               Scenario = "";                                      Args = @(); SpecName = "../outside"; Legacy = 2; Cli = 2 }
)

# Quotes one argument for a Windows command line (no embedded quotes here).
function ConvertTo-QuotedArgument {
    param([string]$Value)
    if ($Value.Contains('"')) { throw "Argument contains a double quote: $Value" }
    if ($Value.EndsWith('\')) { return '"' + $Value + '\"' }
    return '"' + $Value + '"'
}

# Runs a specify.ps1 copy in a fresh folder under TEMP. -Library copies
# lib\workflow.ps1 next to it. Returns exit code, stdout and stderr as Latin-1
# text (lossless for bytes) and the record, with the folder replaced by
# placeholders: <OUT> for its specs folder in the record, <HARNESS> for the
# folder in stdout.
function Invoke-SpecifyCopy {
    param(
        [Parameter(Mandatory = $true)][string]$Specify,
        [string]$Library = "",
        [string]$Scenario = "",
        [string[]]$Arguments = @(),
        [string]$SpecName = "demo",
        [hashtable]$Stages = $null
    )

    $harness = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-harness-b2-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
    $scriptsCopy = Join-Path $harness "scripts"
    [void][System.IO.Directory]::CreateDirectory((Join-Path $scriptsCopy "lib"))
    [System.IO.File]::Copy($Specify, (Join-Path $scriptsCopy "specify.ps1"))
    if ($Library -ne "") { [System.IO.File]::Copy($Library, (Join-Path $scriptsCopy "lib\workflow.ps1")) }

    $recordFile = Join-Path $harness "record.txt"
    $stdoutFile = Join-Path $harness "stdout.txt"
    $stderrFile = Join-Path $harness "stderr.txt"

    if ($null -eq $Stages) {
        $Stages = @{ Runner = $mockRunner; Validator = $mockValidator; Reviewer = $mockReviewer; Reviser = $mockReviser }
    }
    $all = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $scriptsCopy "specify.ps1"),
        "-Task", "Deterministic test task", "-Name", $SpecName,
        "-RunnerScript", $Stages.Runner, "-ValidatorScript", $Stages.Validator,
        "-ReviewerScript", $Stages.Reviewer, "-ReviserScript", $Stages.Reviser) + @($Arguments | Where-Object { $null -ne $_ })
    $commandLine = (@($all | ForEach-Object { ConvertTo-QuotedArgument $_ }) -join " ")

    $env:AI_HARNESS_TEST_RECORD_FILE = $recordFile
    $env:AI_HARNESS_TEST_SCENARIO = $Scenario
    try {
        $process = Start-Process -FilePath $powerShellExe -ArgumentList $commandLine -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $null = $process.Handle
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally {
        Remove-Item Env:\AI_HARNESS_TEST_RECORD_FILE -ErrorAction SilentlyContinue
        Remove-Item Env:\AI_HARNESS_TEST_SCENARIO -ErrorAction SilentlyContinue
    }

    $read = {
        param([string]$Path)
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return $latin1.GetString([System.IO.File]::ReadAllBytes($Path)) }
        return ""
    }
    $stdout = (& $read $stdoutFile).Replace($harness, "<HARNESS>")
    $stderr = (& $read $stderrFile).Replace($harness, "<HARNESS>")
    $escapedSpecs = (Join-Path $harness "specs").Replace('\', '\\')
    $record = (& $read $recordFile).Replace($escapedSpecs, "<OUT>").Replace($harness.Replace('\', '\\'), "<HARNESS>")

    Remove-Item -LiteralPath $harness -Recurse -Force -ErrorAction SilentlyContinue
    return @{ ExitCode = $exitCode; Stdout = (ConvertTo-CrLfText $stdout); Stderr = $stderr; Record = (ConvertTo-CrLfText $record) }
}

# Every line break as CRLF. Redirected Write-Host lines end in LF and success
# lines in CRLF, and git may rewrite the line breaks of a committed fixture
# (core.autocrlf), so stdout, records and fixtures are compared in this form.
function ConvertTo-CrLfText {
    param([string]$Text)
    return $Text.Replace("`r`n", "`n").Replace("`n", "`r`n")
}

# A calls fixture in the form of this checkout. The runner's task is a
# here-string, so its line breaks are those of the script file (CRLF here when
# recorded); a checkout with LF files gives "\n" in the record, in the old and
# the new code alike.
function Read-CallsFixture {
    param([string]$Name)
    $text = Read-FixtureText $Name
    if (-not [System.IO.File]::ReadAllText($workflowLibrary).Contains("`r`n")) { $text = $text.Replace('\r\n', '\n') }
    return $text
}

function Get-ScenarioName {
    param([hashtable]$Case)
    if ($Case.ContainsKey("SpecName")) { return [string]$Case.SpecName }
    return "demo"
}

function Get-ScenarioArguments {
    param([hashtable]$Case)
    return @($Case.Args)
}

# ---------------------------------------------------------------------------
# Record mode
# ---------------------------------------------------------------------------

if ($PSBoundParameters.ContainsKey("RecordFrom")) {
    if ([string]::IsNullOrWhiteSpace($RecordTo)) { throw "-RecordTo is required with -RecordFrom." }
    if (-not (Test-Path -LiteralPath $RecordFrom -PathType Leaf)) { throw "Not found: $RecordFrom" }
    [void][System.IO.Directory]::CreateDirectory($RecordTo)
    $problems = 0
    foreach ($case in $scenarios) {
        $run = Invoke-SpecifyCopy -Specify $RecordFrom -Scenario $case.Scenario -Arguments (Get-ScenarioArguments $case) -SpecName (Get-ScenarioName $case)
        $flag = ""
        if ($run.ExitCode -ne $case.Legacy) { $flag = " EXPECTED $($case.Legacy)"; $problems++ }
        if ($run.Stderr -ne "") { $flag += " STDERR"; $problems++ }
        [System.IO.File]::WriteAllBytes((Join-Path $RecordTo "specify-calls-$($case.Name).txt"), $latin1.GetBytes($run.Record))
        [System.IO.File]::WriteAllBytes((Join-Path $RecordTo "specify-output-$($case.Name).txt"), $latin1.GetBytes($run.Stdout))
        Write-Host ("{0,-28} exit {1}{2}" -f $case.Name, $run.ExitCode, $flag)
    }
    if ($problems -gt 0) { Write-Host "STATUS: FAIL"; exit 1 }
    Write-Host "STATUS: PASS"
    exit 0
}

# ---------------------------------------------------------------------------
# Test mode
# ---------------------------------------------------------------------------

$script:passed = 0
$script:failed = 0

function Write-CaseResult {
    param([string]$Name, [string[]]$Problems)

    $Problems = @($Problems | Where-Object { $null -ne $_ -and $_ -ne "" })
    if ($Problems.Count -eq 0) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
        $script:passed++
        return
    }
    Write-Host "[FAIL] $Name" -ForegroundColor Red
    foreach ($problem in $Problems) { Write-Host "       $problem" -ForegroundColor Red }
    $script:failed++
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)

    try {
        $problems = @(& $Body)
    }
    catch {
        $problems = @("case error: $($_.Exception.GetType().Name): $($_.Exception.Message)")
    }
    Write-CaseResult -Name $Name -Problems $problems
}

function Format-Value {
    param($Value)
    if ($null -eq $Value) { return "null" }
    return [string]$Value
}

function Read-FixtureText {
    param([string]$Name)
    $path = Join-Path $fixturesDirectory $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Fixture not found: $Name" }
    return (ConvertTo-CrLfText ($latin1.GetString([System.IO.File]::ReadAllBytes($path))))
}

# The stage events the recording hook saw, as "begin|id|kind|agent|attempt"
# and "end|id|status|exitCode|verdict|outputLeaf" lines.
$script:events = New-Object 'System.Collections.Generic.List[string]'
$recordingHook = {
    param([string]$EventName, [hashtable]$Data)
    if ($EventName -eq "stage_begin") {
        $script:events.Add("begin|$($Data.id)|$($Data.kind)|$(Format-Value $Data.agent)|$($Data.attempt)")
    }
    else {
        $leaf = if ($null -eq $Data.outputPath) { "null" } else { Split-Path -Leaf $Data.outputPath }
        $script:events.Add("end|$($Data.id)|$($Data.status)|$(Format-Value $Data.exitCode)|$(Format-Value $Data.verdict)|$leaf")
    }
}

# Calls Invoke-SpecifyWorkflow in this process with the scenario mocks and the
# recording hook. Host output is suppressed; the success stream is captured.
function Invoke-InProcessWorkflow {
    param(
        [string]$Scenario,
        [hashtable]$Extra = @{},
        $Hook = $recordingHook,
        $PresetExitCode = $null
    )

    $folder = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-harness-b2-ip-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
    [void][System.IO.Directory]::CreateDirectory($folder)
    $recordFile = Join-Path $folder "record.txt"
    $script:events.Clear()
    $result = @{}
    $arguments = @{
        RunnerScript = $mockRunner; ValidatorScript = $mockValidator; ReviewerScript = $mockReviewer; ReviserScript = $mockReviser
        Mode = "requirements"; Task = "Deterministic test task"; Name = "demo"
        OutputDirectory = (Join-Path $folder "specs"); Result = $result
    }
    if ($null -ne $Hook) { $arguments.Hook = $Hook }
    foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }

    $env:AI_HARNESS_TEST_RECORD_FILE = $recordFile
    $env:AI_HARNESS_TEST_SCENARIO = $Scenario
    try {
        if ($null -ne $PresetExitCode) { $global:LASTEXITCODE = $PresetExitCode }
        $output = @(Invoke-SpecifyWorkflow @arguments 6>$null)
    }
    finally {
        Remove-Item Env:\AI_HARNESS_TEST_RECORD_FILE -ErrorAction SilentlyContinue
        Remove-Item Env:\AI_HARNESS_TEST_SCENARIO -ErrorAction SilentlyContinue
    }
    $record = @()
    if (Test-Path -LiteralPath $recordFile -PathType Leaf) { $record = @([System.IO.File]::ReadAllLines($recordFile)) }
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    return @{ Result = $result; Output = @($output | ForEach-Object { [string]$_ }); Events = @($script:events); Record = $record }
}

function Compare-Lines {
    param([string]$What, [string[]]$Actual, [string[]]$Expected)
    if (($Actual -join "`n") -cne ($Expected -join "`n")) {
        return @("$What expected: " + ($Expected -join " ; "), "$What actual  : " + ($Actual -join " ; "))
    }
    return @()
}

function Compare-Result {
    param([hashtable]$Result, [string]$Outcome, $Category, [int]$Legacy, [int]$Cli, $Stage)
    $problems = @()
    if ($Result.outcome -cne $Outcome) { $problems += "outcome: expected $Outcome, got $(Format-Value $Result.outcome)" }
    if ((Format-Value $Result.category) -cne (Format-Value $Category)) { $problems += "category: expected $(Format-Value $Category), got $(Format-Value $Result.category)" }
    if ($Result.legacyExitCode -ne $Legacy) { $problems += "legacyExitCode: expected $Legacy, got $(Format-Value $Result.legacyExitCode)" }
    if ($Result.cliExitCode -ne $Cli) { $problems += "cliExitCode: expected $Cli, got $(Format-Value $Result.cliExitCode)" }
    if ((Format-Value $Result.stage) -cne (Format-Value $Stage)) { $problems += "stage: expected $(Format-Value $Stage), got $(Format-Value $Result.stage)" }
    return $problems
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "   HARNESS WORKFLOW TEST SUITE (B2)" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

. $workflowLibrary

# --- AC-302: legacy parameters ---------------------------------------------

Invoke-Case -Name "AC-302 parameters of the eight legacy scripts equal phase2-calibrated plus Profile on specify.ps1" -Body {
    $fixture = (Read-FixtureText "legacy-parameters.json") | ConvertFrom-Json
    $problems = @()
    foreach ($scriptName in $legacyScripts) {
        $expected = @($fixture.scripts.$scriptName | ForEach-Object { "$($_.name)|$($_.type)|$($_.mandatory.ToString().ToLowerInvariant())" })
        if ($scriptName -eq "specify.ps1") { $expected += "Profile|string|false" }
        $actual = @(Get-ScriptParameterLines -Text ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot $scriptName))))
        $problems += @(Compare-Lines -What $scriptName -Actual $actual -Expected $expected)
    }
    $problems
}

# --- AC-303 legacy half and B2 additions: frozen specify.ps1 behavior -------

foreach ($case in $scenarios) {
    Invoke-Case -Name "legacy specify.ps1 equals the phase2-calibrated fixture: $($case.Name) (exit $($case.Legacy))" -Body {
        $run = Invoke-SpecifyCopy -Specify $specifyScript -Library $workflowLibrary -Scenario $case.Scenario `
            -Arguments (Get-ScenarioArguments $case) -SpecName (Get-ScenarioName $case)
        $problems = @()
        if ($run.ExitCode -ne $case.Legacy) { $problems += "exit code: expected $($case.Legacy), got $($run.ExitCode)" }
        if ($run.Stdout -cne (Read-FixtureText "specify-output-$($case.Name).txt")) { $problems += "stdout differs from specify-output-$($case.Name).txt" }
        if ($run.Record -cne (Read-CallsFixture "specify-calls-$($case.Name).txt")) { $problems += "stage calls differ from specify-calls-$($case.Name).txt" }
        if ($run.Stderr -ne "") { $problems += "stderr is not empty" }
        $problems
    }
}

# --- AC-304: -Profile on specify.ps1 ----------------------------------------

Invoke-Case -Name "AC-304 -Profile bound: the three agents get -Profile and no -Model, output unchanged" -Body {
    $run = Invoke-SpecifyCopy -Specify $specifyScript -Library $workflowLibrary -Scenario "reviewer=fail,pass" -Arguments @("-Profile", "fixture-profile")
    $problems = @()
    if ($run.ExitCode -ne 0) { $problems += "exit code: expected 0, got $($run.ExitCode)" }
    $lines = @($run.Record -split "\r?\n" | Where-Object { $_ -ne "" })
    $agentLines = @($lines | Where-Object { -not $_.StartsWith("validator|", [System.StringComparison]::Ordinal) })
    if ($agentLines.Count -ne 4) { $problems += "expected 4 agent calls (runner, reviewer, reviser, reviewer), got $($agentLines.Count)" }
    foreach ($line in $agentLines) {
        if (-not $line.Contains("|Profile=fixture-profile")) { $problems += "no -Profile: $($line.Split('|')[0])" }
        if ($line.Contains("|Model=")) { $problems += "-Model passed: $($line.Split('|')[0])" }
    }
    foreach ($line in @($lines | Where-Object { $_.StartsWith("validator|", [System.StringComparison]::Ordinal) })) {
        if ($line.Contains("|Profile=")) { $problems += "the validator got -Profile" }
    }
    $withoutProfile = (($lines | ForEach-Object { $_.Replace("|Profile=fixture-profile", "") }) -join "`r`n") + "`r`n"
    if ($withoutProfile -cne (Read-CallsFixture "specify-calls-pass-after-revision.txt")) { $problems += "calls differ from the unbound run beyond -Profile" }
    if ($run.Stdout -cne (Read-FixtureText "specify-output-pass-after-revision.txt")) { $problems += "stdout differs from the unbound run" }
    $problems
}

Invoke-Case -Name "AC-304 -Profile unbound: no agent gets -Profile" -Body {
    $problems = @()
    foreach ($case in $scenarios) {
        $text = Read-FixtureText "specify-calls-$($case.Name).txt"
        if ($text.Contains("|Profile=")) { $problems += "fixture $($case.Name) has -Profile" }
    }
    $run = Invoke-SpecifyCopy -Specify $specifyScript -Library $workflowLibrary -Scenario "reviewer=fail,pass"
    if ($run.Record.Contains("|Profile=")) { $problems += "a stage got -Profile" }
    if ($run.ExitCode -ne 0) { $problems += "exit code: expected 0, got $($run.ExitCode)" }
    $problems
}

Invoke-Case -Name "AC-304 -Model with -Profile exits 2 before any stage call" -Body {
    $run = Invoke-SpecifyCopy -Specify $specifyScript -Library $workflowLibrary -Scenario "" -Arguments @("-Model", "m:1b", "-Profile", "fast")
    $problems = @()
    if ($run.ExitCode -ne 2) { $problems += "exit code: expected 2, got $($run.ExitCode)" }
    if ($run.Record -ne "") { $problems += "a stage was called" }
    $lines = @($run.Stdout -split "\r?\n" | Where-Object { $_ -ne "" })
    $problems += @(Compare-Lines -What "stdout" -Actual $lines -Expected @("=== Specification Workflow Failed ===", "ERROR: -Model and -Profile cannot be used together."))
    $problems
}

# --- AC-330: the stage contract, in process ---------------------------------

Invoke-Case -Name "AC-330 stage answers on the success stream pass through, and nothing else; outcome passed" -Body {
    $run = Invoke-InProcessWorkflow -Scenario "reviewer=pass"
    $problems = @(Compare-Lines -What "captured output" -Actual $run.Output -Expected @("ANSWER runner 1", "ANSWER validator 1", "ANSWER reviewer 1"))
    $problems += @(Compare-Result -Result $run.Result -Outcome "passed" -Category $null -Legacy 0 -Cli 0 -Stage "spec-review")
    $problems += @(Compare-Lines -What "events" -Actual $run.Events -Expected @(
            "begin|spec-generate|agent|spec|1", "end|spec-generate|succeeded|0|null|demo.md",
            "begin|spec-validate|deterministic|null|1", "end|spec-validate|succeeded|0|null|null",
            "begin|spec-review|agent|spec-reviewer|1", "end|spec-review|succeeded|0|PASS|demo.review.md"))
    if ($null -ne $run.Result.error) { $problems += "error is set" }
    $problems
}

Invoke-Case -Name "AC-330 LASTEXITCODE preset to 7: stages that set no code succeed, one stage_end each" -Body {
    $run = Invoke-InProcessWorkflow -Scenario "runner=noexit;validator=noexit;reviewer=pass" -PresetExitCode 7
    $problems = @(Compare-Result -Result $run.Result -Outcome "passed" -Category $null -Legacy 0 -Cli 0 -Stage "spec-review")
    $problems += @(Compare-Lines -What "stage_end events" -Actual @($run.Events | Where-Object { $_.StartsWith("end|") }) -Expected @(
            "end|spec-generate|succeeded|null|null|demo.md",
            "end|spec-validate|succeeded|null|null|null",
            "end|spec-review|succeeded|0|PASS|demo.review.md"))
    $problems
}

Invoke-Case -Name "AC-330 RN-8 null counts as 0 for the reviser and the revised validation" -Body {
    $run = Invoke-InProcessWorkflow -Scenario "reviewer=fail,pass;reviser=noexit;validator=ok,noexit" -PresetExitCode 7
    $problems = @(Compare-Result -Result $run.Result -Outcome "passed" -Category $null -Legacy 0 -Cli 0 -Stage "spec-review")
    $problems += @(Compare-Lines -What "stage_end events" -Actual @($run.Events | Where-Object { $_.StartsWith("end|") }) -Expected @(
            "end|spec-generate|succeeded|0|null|demo.md",
            "end|spec-validate|succeeded|0|null|null",
            "end|spec-review|succeeded|1|FAIL|demo.review.md",
            "end|spec-revise|succeeded|null|null|demo.revised-v1.md",
            "end|revised-validate|succeeded|null|null|null",
            "end|spec-review|succeeded|0|PASS|demo.revised-v1.review.md"))
    $problems
}

Invoke-Case -Name "AC-330 RN-8 exception: a reviewer that sets no code is unexpected (stage_failed, exit 2)" -Body {
    $run = Invoke-InProcessWorkflow -Scenario "reviewer=noexit" -PresetExitCode 0
    $problems = @(Compare-Result -Result $run.Result -Outcome "failed" -Category "stage_failed" -Legacy 2 -Cli 2 -Stage "spec-review")
    $ends = @($run.Events | Where-Object { $_.StartsWith("end|spec-review|") })
    $problems += @(Compare-Lines -What "spec-review stage_end" -Actual $ends -Expected @("end|spec-review|failed|null|null|demo.review.md"))
    if ($run.Result.message -cne "Stage 'spec-review' failed with exit code null.") { $problems += "message: $(Format-Value $run.Result.message)" }
    if ($null -ne $run.Result.error) { $problems += "error is set (it is not a throw)" }
    $problems
}

Invoke-Case -Name "AC-330 RN-8 exception through specify.ps1: exit 2 and the unexpected-code line" -Body {
    $run = Invoke-SpecifyCopy -Specify $specifyScript -Library $workflowLibrary -Scenario "reviewer=noexit"
    $problems = @()
    if ($run.ExitCode -ne 2) { $problems += "exit code: expected 2, got $($run.ExitCode)" }
    $lines = @($run.Stdout -split "\r?\n")
    if (-not ($lines -ccontains "Unexpected reviewer exit code: ")) { $problems += "missing line 'Unexpected reviewer exit code: '" }
    $problems
}

foreach ($throwCase in @(
        @{ Stage = "spec-generate"; Scenario = "runner=throw"; Leaf = "demo.md"; Ends = 1 },
        @{ Stage = "spec-validate"; Scenario = "validator=throw"; Leaf = "null"; Ends = 2 },
        @{ Stage = "spec-review"; Scenario = "reviewer=throw"; Leaf = "demo.review.md"; Ends = 3 },
        @{ Stage = "spec-revise"; Scenario = "reviewer=fail;reviser=throw"; Leaf = "demo.revised-v1.md"; Ends = 4 },
        @{ Stage = "revised-validate"; Scenario = "reviewer=fail;validator=ok,throw"; Leaf = "null"; Ends = 5 })) {
    Invoke-Case -Name "AC-330 a stage that throws is a failed stage: $($throwCase.Stage)" -Body {
        $run = Invoke-InProcessWorkflow -Scenario $throwCase.Scenario
        $problems = @(Compare-Result -Result $run.Result -Outcome "failed" -Category "stage_failed" -Legacy 2 -Cli 2 -Stage $throwCase.Stage)
        $ends = @($run.Events | Where-Object { $_.StartsWith("end|") })
        if ($ends.Count -ne $throwCase.Ends) { $problems += "expected $($throwCase.Ends) stage_end events, got $($ends.Count)" }
        $own = @($ends | Where-Object { $_.StartsWith("end|$($throwCase.Stage)|") })
        if ($own.Count -ne 1) { $problems += "expected one stage_end for $($throwCase.Stage), got $($own.Count)" }
        elseif ($own[-1] -cne "end|$($throwCase.Stage)|failed|null|null|$($throwCase.Leaf)") { $problems += "stage_end: $($own[-1])" }
        if ($null -eq $run.Result.error) { $problems += "error is not set" }
        elseif ($run.Result.error.Exception.Message -cne "mock $(@{ 'spec-generate' = 'runner'; 'spec-validate' = 'validator'; 'spec-review' = 'reviewer'; 'spec-revise' = 'reviser'; 'revised-validate' = 'validator' }[$throwCase.Stage]) failure") {
            $problems += "error message: $($run.Result.error.Exception.Message)"
        }
        if ($run.Result.errorSource -cne "stage") { $problems += "errorSource: $(Format-Value $run.Result.errorSource)" }
        $problems
    }
}

Invoke-Case -Name "AC-330 a stage that throws, through specify.ps1: exit 2 and the two failure lines of phase2-calibrated" -Body {
    $run = Invoke-SpecifyCopy -Specify $specifyScript -Library $workflowLibrary -Scenario "reviewer=throw"
    $problems = @()
    if ($run.ExitCode -ne 2) { $problems += "exit code: expected 2, got $($run.ExitCode)" }
    $actual = @($run.Stdout -split "\r?\n" | Where-Object { $_ -ne "" } | Select-Object -Last 2)
    $frozen = @((Read-FixtureText "specify-output-reviewer-throws.txt") -split "\r?\n" | Where-Object { $_ -ne "" } | Select-Object -Last 2)
    $problems += @(Compare-Lines -What "last two lines" -Actual $actual -Expected $frozen)
    $problems += @(Compare-Lines -What "frozen lines" -Actual $frozen -Expected @("=== Specification Workflow Failed ===", "ERROR: mock reviewer failure"))
    $problems
}

Invoke-Case -Name "AC-330 a hook that throws at stage_begin is internal_error and no stage runs" -Body {
    $throwingHook = { param([string]$EventName, [hashtable]$Data) throw "hook failure" }
    $run = Invoke-InProcessWorkflow -Scenario "reviewer=pass" -Hook $throwingHook
    $problems = @(Compare-Result -Result $run.Result -Outcome "failed" -Category "internal_error" -Legacy 2 -Cli 2 -Stage "spec-generate")
    if ($run.Record.Count -ne 0) { $problems += "a stage ran" }
    if ($run.Result.errorSource -cne "hook") { $problems += "errorSource: $(Format-Value $run.Result.errorSource)" }
    if ($null -eq $run.Result.error) { $problems += "error is not set" }
    $problems
}

Invoke-Case -Name "AC-330 a hook that throws at stage_end is internal_error and the workflow stops" -Body {
    $throwingHook = {
        param([string]$EventName, [hashtable]$Data)
        $script:events.Add("$EventName|$($Data.id)")
        if ($EventName -eq "stage_end" -and $Data.id -eq "spec-validate") { throw "hook failure" }
    }
    $run = Invoke-InProcessWorkflow -Scenario "reviewer=pass" -Hook $throwingHook
    $problems = @(Compare-Result -Result $run.Result -Outcome "failed" -Category "internal_error" -Legacy 2 -Cli 2 -Stage "spec-validate")
    $problems += @(Compare-Lines -What "stage calls" -Actual @($run.Record | ForEach-Object { $_.Split('|')[0] }) -Expected @("runner", "validator"))
    $problems
}

Invoke-Case -Name "Library: -Model with -Profile is invalid_arguments before any stage" -Body {
    $run = Invoke-InProcessWorkflow -Scenario "reviewer=pass" -Extra @{ Model = "m:1b"; Profile = "fast" }
    $problems = @(Compare-Result -Result $run.Result -Outcome "failed" -Category "invalid_arguments" -Legacy 2 -Cli 2 -Stage $null)
    if ($run.Events.Count -ne 0) { $problems += "a hook event was sent" }
    if ($run.Record.Count -ne 0) { $problems += "a stage ran" }
    $problems
}

Invoke-Case -Name "Library: -Profile and -ContextFile reach the three agent stages, not the validator" -Body {
    $run = Invoke-InProcessWorkflow -Scenario "reviewer=fail,pass" -Extra @{ Profile = "deep"; ContextFile = "C:\ctx.md" }
    $problems = @(Compare-Result -Result $run.Result -Outcome "passed" -Category $null -Legacy 0 -Cli 0 -Stage "spec-review")
    foreach ($line in $run.Record) {
        $isAgent = -not $line.StartsWith("validator|", [System.StringComparison]::Ordinal)
        if ($isAgent -ne $line.Contains("|ContextFile=C:\\ctx.md|")) { $problems += "ContextFile wrong for $($line.Split('|')[0])" }
        if ($isAgent -ne $line.Contains("|Profile=deep|")) { $problems += "Profile wrong for $($line.Split('|')[0])" }
    }
    $problems
}

# --- AC-330: stages without exit codes (real scan-repository.ps1, build-context.ps1)

$fileStageFolder = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-harness-b2-fs-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$fileStageRepo = Join-Path $fileStageFolder "repo"
[void][System.IO.Directory]::CreateDirectory($fileStageRepo)
[System.IO.File]::WriteAllText((Join-Path $fileStageRepo "readme.md"), "# Demo`r`n`r`nA small file.`r`n", (New-Object System.Text.UTF8Encoding($false)))
$scanScript = Join-Path $PSScriptRoot "scan-repository.ps1"
$contextScript = Join-Path $PSScriptRoot "build-context.ps1"
$manifestFile = Join-Path $fileStageFolder "repository-manifest.json"
$contextFile = Join-Path $fileStageFolder "context.md"

try {
    Invoke-Case -Name "AC-330 real scan-repository.ps1 succeeds with no exit code and a stale LASTEXITCODE" -Body {
        $state = @{}
        $global:LASTEXITCODE = 7
        $null = Invoke-HarnessFileStage -Id "scan" -Script $scanScript -Arguments @{ RootPath = $fileStageRepo; OutputFile = $manifestFile } `
            -OutputPath $manifestFile -State $state 6>$null
        $problems = @()
        if ($state.status -cne "succeeded") { $problems += "status: $(Format-Value $state.status) ($(Format-Value $state.message))" }
        if ($null -ne $state.exitCode) { $problems += "exitCode: $($state.exitCode)" }
        $problems
    }

    Invoke-Case -Name "AC-330 real build-context.ps1 succeeds with no exit code and a stale LASTEXITCODE" -Body {
        $state = @{}
        $global:LASTEXITCODE = 7
        $null = Invoke-HarnessFileStage -Id "context" -Script $contextScript `
            -Arguments @{ ManifestFile = $manifestFile; Include = @("readme.md"); OutputFile = $contextFile } `
            -OutputPath $contextFile -State $state 6>$null
        $problems = @()
        if ($state.status -cne "succeeded") { $problems += "status: $(Format-Value $state.status) ($(Format-Value $state.message))" }
        if ($null -ne $state.exitCode) { $problems += "exitCode: $($state.exitCode)" }
        $problems
    }

    Invoke-Case -Name "AC-330 real scan-repository.ps1 that throws is a failed stage" -Body {
        $state = @{}
        $fileEvents = New-Object 'System.Collections.Generic.List[string]'
        $hook = { param([string]$EventName, [hashtable]$Data) $fileEvents.Add("$EventName|$($Data.id)|$(Format-Value $Data.status)|$(Format-Value $Data.exitCode)") }
        $null = Invoke-HarnessFileStage -Id "scan" -Script $scanScript -Arguments @{ RootPath = (Join-Path $fileStageFolder "missing"); OutputFile = (Join-Path $fileStageFolder "m2.json") } `
            -OutputPath (Join-Path $fileStageFolder "m2.json") -Hook $hook -State $state 6>$null
        $problems = @()
        if ($state.status -cne "failed" -or -not $state.threw) { $problems += "status: $(Format-Value $state.status), threw: $($state.threw)" }
        if ($state.category -cne "stage_failed") { $problems += "category: $(Format-Value $state.category)" }
        $problems += @(Compare-Lines -What "events" -Actual @($fileEvents) -Expected @("stage_begin|scan|null|null", "stage_end|scan|failed|null"))
        $problems
    }

    Invoke-Case -Name "AC-330 real build-context.ps1 that throws is a failed stage" -Body {
        $state = @{}
        $null = Invoke-HarnessFileStage -Id "context" -Script $contextScript `
            -Arguments @{ ManifestFile = $manifestFile; Include = @("not-there.md"); OutputFile = (Join-Path $fileStageFolder "c2.md") } `
            -OutputPath (Join-Path $fileStageFolder "c2.md") -State $state 6>$null
        $problems = @()
        if ($state.status -cne "failed" -or -not $state.threw) { $problems += "status: $(Format-Value $state.status), threw: $($state.threw)" }
        $problems
    }

    Invoke-Case -Name "AC-330 real scan-repository.ps1 and build-context.ps1 fail when the expected output file is missing" -Body {
        $problems = @()
        $state = @{}
        $global:LASTEXITCODE = 0
        $null = Invoke-HarnessFileStage -Id "scan" -Script $scanScript -Arguments @{ RootPath = $fileStageRepo; OutputFile = (Join-Path $fileStageFolder "m3.json") } `
            -OutputPath (Join-Path $fileStageFolder "expected-scan.json") -State $state 6>$null
        if ($state.status -cne "failed" -or $state.threw) { $problems += "scan status: $(Format-Value $state.status), threw: $($state.threw)" }
        if ($state.message -cne "Stage 'scan' failed: output file missing or empty (exit code null).") { $problems += "scan message: $(Format-Value $state.message)" }
        $state = @{}
        $null = Invoke-HarnessFileStage -Id "context" -Script $contextScript `
            -Arguments @{ ManifestFile = $manifestFile; Include = @("readme.md"); OutputFile = (Join-Path $fileStageFolder "c3.md") } `
            -OutputPath (Join-Path $fileStageFolder "expected-context.md") -State $state 6>$null
        if ($state.status -cne "failed" -or $state.threw) { $problems += "context status: $(Format-Value $state.status), threw: $($state.threw)" }
        $problems
    }

    Invoke-Case -Name "AC-330 a file stage whose output file is empty fails" -Body {
        $emptyWriter = Join-Path $fileStageFolder "empty-writer.ps1"
        [System.IO.File]::WriteAllText($emptyWriter, "param([string]`$OutputFile)`r`n[System.IO.File]::WriteAllText(`$OutputFile, '')`r`n", (New-Object System.Text.UTF8Encoding($false)))
        $state = @{}
        $output = Join-Path $fileStageFolder "empty.txt"
        $null = Invoke-HarnessFileStage -Id "scan" -Script $emptyWriter -Arguments @{ OutputFile = $output } -OutputPath $output -State $state 6>$null
        $problems = @()
        if ($state.status -cne "failed") { $problems += "status: $(Format-Value $state.status)" }
        $problems
    }
}
finally {
    Remove-Item -LiteralPath $fileStageFolder -Recurse -Force -ErrorAction SilentlyContinue
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
