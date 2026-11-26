<#
.SYNOPSIS
    Offline suite for 'harness specify' (Phase 3 work package B4): AC-303 (CLI half),
    AC-305, AC-307, AC-308 (checkpoints), AC-310, AC-311, AC-313, AC-321 (B4 part),
    AC-327, AC-328.

.DESCRIPTION
    One temporary harness from the engine fake host (tests\lib\engine-fake-host.ps1, its
    four guards) with harness.ps1, validate-spec.ps1 and the manifest schema added. Three
    ways to run the CLI:
      - in process: Invoke-HarnessCli with mock stages (tests\mocks\scenario-*.ps1 of B2,
        and tests\mocks\cli-*.ps1, which add telemetry records and manifest snapshots);
        Invoke-RestMethod is shadowed, so any request of an in-process case is a violation;
      - a child driver (powershell.exe -File) that calls Invoke-HarnessCli with mock stages
        (D-310), for the process id and the stdout protocol;
      - harness.ps1 with the real stage scripts inside the engine fake host (AC-321).
    No Ollama, no network. PATH is one empty folder (git is absent). Expected values are
    literals, fixtures recorded at phase2-calibrated (B2), or hashes from Get-FileHash.
#>
param()

$ErrorActionPreference = "Stop"

$scriptsDirectory = $PSScriptRoot
. (Join-Path $scriptsDirectory "..\tests\lib\engine-fake-host.ps1")

# In-process guard: no case of this suite may reach the network from the test process.
$script:restViolations = 0
function Invoke-RestMethod {
    $script:restViolations++
    throw "violation: Invoke-RestMethod was called by an in-process case"
}

$fixturesDirectory = Join-Path $root "tests\fixtures"
foreach ($path in @(
        (Join-Path $scriptsDirectory "harness.ps1"),
        (Join-Path $scriptsDirectory "lib\cli.ps1"),
        (Join-Path $scriptsDirectory "lib\workflow.ps1"),
        (Join-Path $scriptsDirectory "validate-spec.ps1"),
        (Join-Path $scriptsDirectory "lib\run-manifest.schema.json"),
        (Join-Path $fixturesDirectory "minimal-valid-spec.md"),
        (Join-Path $mocksDirectory "scenario-runner.ps1"),
        (Join-Path $mocksDirectory "scenario-validator.ps1"),
        (Join-Path $mocksDirectory "scenario-reviewer.ps1"),
        (Join-Path $mocksDirectory "scenario-reviser.ps1"),
        (Join-Path $mocksDirectory "cli-runner.ps1"),
        (Join-Path $mocksDirectory "cli-reviewer.ps1"),
        (Join-Path $mocksDirectory "cli-reviser.ps1"),
        (Join-Path $mocksDirectory "cli-stage-extras.ps1"))) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required path not found: $path" }
}

$originalPath = $env:Path
$testVariables = @("AI_HARNESS_TEST_RECORD_FILE", "AI_HARNESS_TEST_SCENARIO", "AI_HARNESS_TEST_HARNESS_ROOT", "AI_HARNESS_TEST_TELEMETRY_FILE", "AI_HARNESS_TEST_SNAPSHOT_DIR")

try {
    Initialize-EngineSuite

    Copy-Item -LiteralPath (Join-Path $scriptsDirectory "harness.ps1") -Destination (Join-Path $harnessRoot "scripts\harness.ps1")
    Copy-Item -LiteralPath (Join-Path $scriptsDirectory "validate-spec.ps1") -Destination (Join-Path $harnessRoot "scripts\validate-spec.ps1")
    Copy-Item -LiteralPath (Join-Path $scriptsDirectory "lib\run-manifest.schema.json") -Destination (Join-Path $harnessRoot "scripts\lib\run-manifest.schema.json")
    $harnessScript = Join-Path $harnessRoot "scripts\harness.ps1"

    $binDirectory = Join-Path $tempRoot "bin"
    [void][System.IO.Directory]::CreateDirectory($binDirectory)
    $env:Path = $binDirectory

    . (Join-Path $harnessRoot "scripts\lib\cli.ps1")

    $baseConfig = New-V2Config
    [System.IO.File]::WriteAllText($harnessConfig, $baseConfig, $utf8NoBom)
    $env:AI_HARNESS_TEST_HARNESS_ROOT = $harnessRoot

    $runsDirectory = Join-Path $harnessRoot "runs"
    $recordFile = Join-Path $tempRoot "record.txt"
    $telemetryPlanFile = Join-Path $tempRoot "telemetry-plan.json"
    $task = "Deterministic test task"
    $validSpecText = Read-Utf8 (Join-Path $fixturesDirectory "minimal-valid-spec.md")

    $scenarioStages = @{
        runner    = (Join-Path $mocksDirectory "scenario-runner.ps1")
        validator = (Join-Path $mocksDirectory "scenario-validator.ps1")
        reviewer  = (Join-Path $mocksDirectory "scenario-reviewer.ps1")
        reviser   = (Join-Path $mocksDirectory "scenario-reviser.ps1")
    }
    $cliStages = @{
        runner    = (Join-Path $mocksDirectory "cli-runner.ps1")
        validator = (Join-Path $mocksDirectory "scenario-validator.ps1")
        reviewer  = (Join-Path $mocksDirectory "cli-reviewer.ps1")
        reviser   = (Join-Path $mocksDirectory "cli-reviser.ps1")
    }

    # Every manifest text the suite sees (finals and snapshots), for the AC-307 value sets.
    $script:allManifests = New-Object 'System.Collections.Generic.List[string]'
    $script:caseIndex = 0

    # -----------------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------------

    function New-Target {
        $script:caseIndex++
        $path = Join-Path $tempRoot ("targets\t" + $script:caseIndex)
        [void][System.IO.Directory]::CreateDirectory($path)
        return $path
    }

    function Get-SpecDirectory { param([string]$Target) return (Join-Path $Target ".ai-harness\specs") }

    function Get-Sha {
        param([string]$Path)
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    function Get-RunCount {
        if (-not (Test-Path -LiteralPath $runsDirectory)) { return 0 }
        return @(Get-ChildItem -LiteralPath $runsDirectory -Directory -Force).Count
    }

    function Read-RecordLines {
        if (-not (Test-Path -LiteralPath $recordFile -PathType Leaf)) { return @() }
        return @([System.IO.File]::ReadAllLines($recordFile) | Where-Object { $_ -ne "" })
    }

    function Set-StageEnvironment {
        param([string]$Scenario = "", $Telemetry = $null, [string]$SnapshotDir = "")
        if (Test-Path -LiteralPath $recordFile) { Remove-Item -LiteralPath $recordFile -Force }
        $env:AI_HARNESS_TEST_RECORD_FILE = $recordFile
        $env:AI_HARNESS_TEST_SCENARIO = $Scenario
        if ($null -ne $Telemetry) {
            [System.IO.File]::WriteAllText($telemetryPlanFile, (ConvertTo-Json -InputObject $Telemetry -Depth 6), $utf8NoBom)
            $env:AI_HARNESS_TEST_TELEMETRY_FILE = $telemetryPlanFile
        }
        else { Remove-Item Env:\AI_HARNESS_TEST_TELEMETRY_FILE -ErrorAction SilentlyContinue }
        if ($SnapshotDir -ne "") { $env:AI_HARNESS_TEST_SNAPSHOT_DIR = $SnapshotDir }
        else { Remove-Item Env:\AI_HARNESS_TEST_SNAPSHOT_DIR -ErrorAction SilentlyContinue }
    }

    function New-SpecifyOptions {
        param([string]$Target, [hashtable]$Options = @{})
        $result = [ordered]@{ TargetPath = $Target; Name = "demo"; Task = $task }
        foreach ($key in $Options.Keys) {
            if ($null -eq $Options[$key]) { if ($result.Contains($key)) { $result.Remove($key) } }
            else { $result[$key] = $Options[$key] }
        }
        return $result
    }

    # Reads the manifest a run printed (MANIFEST: line) and keeps its text for AC-307.
    function Add-ManifestFields {
        param($Run)
        $Run | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $null
        $Run | Add-Member -NotePropertyName ManifestText -NotePropertyValue $null
        $Run | Add-Member -NotePropertyName Manifest -NotePropertyValue $null
        $Run | Add-Member -NotePropertyName RunId -NotePropertyValue $null
        $lines = @($Run.Lines)
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].StartsWith("MANIFEST: ", [System.StringComparison]::Ordinal)) {
            $Run.ManifestPath = $lines[$lines.Count - 1].Substring(10)
            if ([System.IO.File]::Exists($Run.ManifestPath)) {
                $Run.ManifestText = [System.IO.File]::ReadAllText($Run.ManifestPath)
                $Run.Manifest = $Run.ManifestText | ConvertFrom-Json
                $script:allManifests.Add($Run.ManifestText)
            }
        }
        $first = @($lines | Where-Object { $_.StartsWith("RUN_ID: ", [System.StringComparison]::Ordinal) })
        if ($first.Count -gt 0) { $Run.RunId = $first[0].Substring(8) }
    }

    # specify in process. Returns { ExitCode, Lines, Record, Target, SpecDirectory, Snapshots,
    # ManifestPath, ManifestText, Manifest, RunId }.
    function Invoke-Specify {
        param([hashtable]$Options = @{}, [string]$Scenario = "", $Telemetry = $null, [switch]$Snapshots, $Stages = $null, [string]$Target = "")
        if ($Target -eq "") { $Target = New-Target }
        if ($null -eq $Stages) { $Stages = $cliStages }
        $snapshotDir = ""
        if ($Snapshots) { $snapshotDir = Join-Path $tempRoot ("snapshots\s" + $script:caseIndex + "-" + [guid]::NewGuid().ToString("N").Substring(0, 6)) }
        Set-StageEnvironment -Scenario $Scenario -Telemetry $Telemetry -SnapshotDir $snapshotDir
        $result = @{}
        $lines = @(Invoke-HarnessCli -Command "specify" -Options (New-SpecifyOptions -Target $Target -Options $Options) -StageScripts $Stages -Result $result 6>$null)
        $run = [pscustomobject]@{ ExitCode = $result.exitCode; Lines = @($lines | ForEach-Object { [string]$_ }); Record = @(Read-RecordLines); Target = $Target; SpecDirectory = (Get-SpecDirectory $Target); Snapshots = $snapshotDir }
        Add-ManifestFields $run
        if ($snapshotDir -ne "" -and (Test-Path -LiteralPath $snapshotDir)) {
            foreach ($file in @(Get-ChildItem -LiteralPath $snapshotDir -Filter "*.json" -File)) { $script:allManifests.Add([System.IO.File]::ReadAllText($file.FullName)) }
        }
        return $run
    }

    # The child driver: powershell.exe -File driver.ps1, which calls Invoke-HarnessCli with
    # mock stages (D-310). Returns the run plus Pid and StartUtc of the child.
    $driverScript = Join-Path $tempRoot "driver.ps1"
    [System.IO.File]::WriteAllText($driverScript, @'
param([string]$HarnessRoot, [string]$OptionsFile, [string]$StagesFile)
$ErrorActionPreference = "Stop"
. (Join-Path $HarnessRoot "scripts\lib\cli.ps1")
$options = [ordered]@{}
foreach ($p in ([System.IO.File]::ReadAllText($OptionsFile) | ConvertFrom-Json).PSObject.Properties) {
    if ($p.Value -is [bool]) { $options[$p.Name] = [bool]$p.Value } else { $options[$p.Name] = [string]$p.Value }
}
$stages = @{}
foreach ($p in ([System.IO.File]::ReadAllText($StagesFile) | ConvertFrom-Json).PSObject.Properties) { $stages[$p.Name] = [string]$p.Value }
$result = @{ exitCode = 2 }
Invoke-HarnessCli -Command "specify" -Options $options -StageScripts $stages -Result $result
exit ([int]$result.exitCode)
'@, $utf8NoBom)

    function Invoke-Driver {
        param([hashtable]$Options = @{}, [string]$Scenario = "", $Stages = $null)
        $target = New-Target
        if ($null -eq $Stages) { $Stages = $scenarioStages }
        Set-StageEnvironment -Scenario $Scenario
        $optionsFile = Join-Path $tempRoot "driver-options.json"
        $stagesFile = Join-Path $tempRoot "driver-stages.json"
        $stdoutFile = Join-Path $tempRoot "driver-stdout.txt"
        $stderrFile = Join-Path $tempRoot "driver-stderr.txt"
        [System.IO.File]::WriteAllText($optionsFile, (ConvertTo-Json -InputObject (New-SpecifyOptions -Target $target -Options $Options)), $utf8NoBom)
        [System.IO.File]::WriteAllText($stagesFile, (ConvertTo-Json -InputObject $Stages), $utf8NoBom)
        $argumentText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $driverScript + '" -HarnessRoot "' + $harnessRoot + '" -OptionsFile "' + $optionsFile + '" -StagesFile "' + $stagesFile + '"'
        $process = Start-Process -FilePath $powerShellExe -ArgumentList $argumentText -NoNewWindow -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $null = $process.Handle
        $startUtc = $process.StartTime.ToUniversalTime()
        $process.WaitForExit()
        $run = [pscustomobject]@{
            ExitCode = $process.ExitCode
            Lines    = @([System.IO.File]::ReadAllLines($stdoutFile) | Where-Object { $_ -ne "" })
            Pid      = $process.Id
            StartUtc = $startUtc
            Target   = $target
            Record   = @(Read-RecordLines)
        }
        Add-ManifestFields $run
        return $run
    }

    # harness.ps1 alone as a child process (no fake host). Returns { ExitCode, Lines }.
    function Invoke-Harness {
        param([string[]]$Arguments = @())
        $ErrorActionPreference = "Continue"
        try {
            $raw = @(& $powerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harnessScript @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = "Stop" }
        return [pscustomobject]@{ ExitCode = $exitCode; Lines = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) }
    }

    function Assert-ValidManifest {
        param($Run)
        if ($null -eq $Run.ManifestText) { throw "no manifest was printed or found" }
        $check = Test-HarnessManifest -Manifest $Run.ManifestText
        if (-not $check.valid) { throw "manifest invalid: $(@($check.errors) -join '; ')" }
    }

    # RUN_ID first, MANIFEST last (absolute, existing), and for a nonzero exit exactly one
    # ERROR line, just before MANIFEST, with the category; the manifest holds the exit code.
    function Assert-Protocol {
        param($Run, [int]$ExitCode, [string]$Category = "")
        $lines = @($Run.Lines)
        Assert-Equal "exit code" $ExitCode $Run.ExitCode
        Assert-True "first line is RUN_ID: ($($lines[0]))" ($lines[0].StartsWith("RUN_ID: ", [System.StringComparison]::Ordinal))
        $last = $lines[$lines.Count - 1]
        Assert-True "last line is MANIFEST: ($last)" ($last.StartsWith("MANIFEST: ", [System.StringComparison]::Ordinal))
        Assert-True "the manifest path is absolute" ([System.IO.Path]::IsPathRooted($last.Substring(10)))
        Assert-True "the manifest exists" ([System.IO.File]::Exists($last.Substring(10)))
        Assert-Equal "manifest path" ((Join-Path $runsDirectory ($lines[0].Substring(8) + "\manifest.json")).ToLowerInvariant()) $last.Substring(10).ToLowerInvariant()
        # A real stage script may print its own "ERROR: ..." text; the protocol line is the
        # one with the run's category token.
        if ($ExitCode -eq 0) { Assert-Equal "ERROR lines" 0 @($lines | Where-Object { $_.StartsWith("ERROR: ", [System.StringComparison]::Ordinal) }).Count }
        else {
            Assert-Equal "ERROR <category> lines" 1 @($lines | Where-Object { $_.StartsWith("ERROR: $($Category): ", [System.StringComparison]::Ordinal) }).Count
            Assert-True "ERROR just before MANIFEST ($($lines[$lines.Count - 2]))" ($lines[$lines.Count - 2].StartsWith("ERROR: $($Category): ", [System.StringComparison]::Ordinal))
        }
        Assert-ValidManifest $Run
        Assert-Equal "manifest exitCode" $ExitCode $Run.Manifest.exitCode
        Assert-Equal "manifest runId" $lines[0].Substring(8) $Run.Manifest.runId
    }

    function Get-Stage {
        param($Manifest, [string]$Id, [int]$Attempt = 1)
        $found = @($Manifest.stages | Where-Object { $_.id -ceq $Id -and [int]$_.attempt -eq $Attempt })
        if ($found.Count -ne 1) { throw "stage $Id/$Attempt found $($found.Count) times" }
        return $found[0]
    }

    function Get-StageSummary {
        param($Manifest)
        return (@($Manifest.stages | ForEach-Object { "$($_.id)/$($_.attempt)/$($_.status)" }) -join " ")
    }

    # The stages before the failing one succeeded, the failing one is failed, every later
    # planned stage is skipped with "dependency failed: <id>".
    function Assert-FailureShape {
        param($Manifest, [string]$FailedId, [int]$FailedAttempt = 1)
        $stages = @($Manifest.stages)
        $index = -1
        for ($i = 0; $i -lt $stages.Count; $i++) { if ($stages[$i].id -ceq $FailedId -and [int]$stages[$i].attempt -eq $FailedAttempt) { $index = $i } }
        Assert-True "the failing stage $FailedId/$FailedAttempt is in the manifest" ($index -ge 0)
        Assert-Equal "status of $FailedId" "failed" $stages[$index].status
        for ($i = 0; $i -lt $index; $i++) { Assert-Equal "earlier stage $($stages[$i].id)/$($stages[$i].attempt)" "succeeded" $stages[$i].status }
        for ($i = $index + 1; $i -lt $stages.Count; $i++) {
            Assert-Equal "later stage $($stages[$i].id)/$($stages[$i].attempt)" "skipped" $stages[$i].status
            Assert-Equal "reason of $($stages[$i].id)/$($stages[$i].attempt)" "dependency failed: $FailedId" $stages[$i].reason
        }
    }

    # Every artifact of the target exists with the hash the manifest records.
    function Assert-ArtifactHashes {
        param($Run)
        foreach ($artifact in @($Run.Manifest.artifacts)) {
            $base = if ($artifact.root -ceq "target") { $Run.Target } else { Join-Path $runsDirectory $Run.Manifest.runId }
            $path = Join-Path $base $artifact.path
            Assert-True "artifact $($artifact.path) exists" ([System.IO.File]::Exists($path))
            Assert-Equal "artifact $($artifact.path) sha256" (Get-Sha $path) $artifact.sha256
        }
    }

    function Read-TelemetryRecords {
        param([string]$RunId)
        $jsonl = Join-Path $harnessLogs "model-calls.jsonl"
        if (-not (Test-Path -LiteralPath $jsonl)) { return @() }
        return @([System.IO.File]::ReadAllLines($jsonl) | Where-Object { $_.Trim() -ne "" } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.run_id -ceq $RunId })
    }

    function Read-CallsFixture {
        param([string]$Name)
        $text = [System.IO.File]::ReadAllText((Join-Path $fixturesDirectory "specify-calls-$Name.txt"))
        if (-not [System.IO.File]::ReadAllText((Join-Path $harnessRoot "scripts\lib\workflow.ps1")).Contains("`r`n")) { $text = $text.Replace('\r\n', '\n') }
        return $text.Replace("`r`n", "`n").Replace("`n", "`r`n")
    }

    # -----------------------------------------------------------------------
    # AC-303 (CLI half): the 13 scenarios with the B2 mocks; calls equal the fixtures
    # recorded from phase2-calibrated, CLI exit codes 0 0 1 3 1 2 2 2 1 2 2 2 2
    # -----------------------------------------------------------------------

    $ac303 = @(
        @{ Name = "pass-first-review";         Scenario = "reviewer=pass";                    Exit = 0; Category = "" },
        @{ Name = "pass-after-revision";       Scenario = "reviewer=fail,pass";               Exit = 0; Category = "" },
        @{ Name = "fail-after-3-revisions";    Scenario = "reviewer=fail";                    Exit = 1; Category = "max_revisions_reached" },
        @{ Name = "first-validation-exit-3";   Scenario = "validator=exit3";                  Exit = 3; Category = "needs_human_input" },
        @{ Name = "first-validation-exit-1";   Scenario = "validator=exit1";                  Exit = 1; Category = "validation_failed" },
        @{ Name = "runner-exit-2";             Scenario = "runner=exit2";                     Exit = 2; Category = "stage_failed" },
        @{ Name = "reviewer-exit-2";           Scenario = "reviewer=exit2";                   Exit = 2; Category = "stage_failed" },
        @{ Name = "reviser-exit-2";            Scenario = "reviewer=fail;reviser=exit2";      Exit = 2; Category = "stage_failed" },
        @{ Name = "revised-validation-exit-1"; Scenario = "reviewer=fail;validator=ok,exit1"; Exit = 1; Category = "validation_failed" },
        @{ Name = "reviewer-exit-5";           Scenario = "reviewer=exit5";                   Exit = 2; Category = "stage_failed" },
        @{ Name = "runner-no-output";          Scenario = "runner=nooutput";                  Exit = 2; Category = "stage_failed" },
        @{ Name = "reviewer-throws";           Scenario = "reviewer=throw";                   Exit = 2; Category = "stage_failed" },
        @{ Name = "first-validation-exit-2";   Scenario = "validator=exit2";                  Exit = 2; Category = "stage_failed" }
    )
    foreach ($case in $ac303) {
        Test-Case "AC-303 CLI '$($case.Name)': stage calls equal specify-calls-$($case.Name).txt, exit $($case.Exit) $($case.Category)" {
            $run = Invoke-Specify -Scenario $case.Scenario -Stages $scenarioStages
            $escaped = $run.SpecDirectory.Replace('\', '\\')
            $actual = ([System.IO.File]::ReadAllText($recordFile)).Replace($escaped, "<OUT>").Replace("`r`n", "`n").Replace("`n", "`r`n")
            Assert-Equal "recorded calls" (Read-CallsFixture $case.Name) $actual
            Assert-Protocol $run $case.Exit $case.Category
            if ($case.Exit -eq 0) { Assert-Equal "status" "succeeded" $run.Manifest.status; Assert-True "no error" ($null -eq $run.Manifest.error) }
            else { Assert-Equal "category" $case.Category $run.Manifest.error.category }
            if ($case.Exit -eq 3) { Assert-Equal "status" "needs_input" $run.Manifest.status }
        }
    }

    # -----------------------------------------------------------------------
    # AC-305: run id, layout, artifact locations, AI_HARNESS_RUN_ID set and restored
    # -----------------------------------------------------------------------

    Test-Case "AC-305 a generated id; one revision leaves exactly the four spec files and .claim, manifest.json, inputs\task.md; the stages saw the id; AI_HARNESS_RUN_ID unset again" {
        Remove-Item Env:\AI_HARNESS_RUN_ID -ErrorAction SilentlyContinue
        $run = Invoke-Specify -Scenario "reviewer=fail,pass" -Snapshots
        Assert-Protocol $run 0
        Assert-True "generated id ($($run.RunId))" ($run.RunId -cmatch '^\d{8}T\d{6}Z-[0-9a-f]{8}$')
        $specFiles = @(Get-ChildItem -LiteralPath $run.SpecDirectory -Force | ForEach-Object { $_.Name } | Sort-Object)
        Assert-Equal "spec files" "demo.md|demo.review.md|demo.revised-v1.md|demo.revised-v1.review.md" ($specFiles -join "|")
        Assert-Equal "target entries" ".ai-harness" (@(Get-ChildItem -LiteralPath $run.Target -Force | ForEach-Object { $_.Name }) -join "|")
        $runPath = Join-Path $runsDirectory $run.RunId
        $runFiles = @(Get-ChildItem -LiteralPath $runPath -Recurse -Force -File | ForEach-Object { $_.FullName.Substring($runPath.Length + 1) } | Sort-Object)
        Assert-Equal "run files" ".claim|inputs\task.md|manifest.json" ($runFiles -join "|")
        $expectedTask = Join-Path $tempRoot "expected-task.txt"
        [System.IO.File]::WriteAllText($expectedTask, $task, $utf8NoBom)
        Assert-Equal "task.md bytes" (Get-Sha $expectedTask) (Get-Sha (Join-Path $runPath "inputs\task.md"))
        foreach ($call in @("runner1", "reviewer1", "reviser1", "reviewer2")) {
            Assert-Equal "AI_HARNESS_RUN_ID seen by $call" $run.RunId ([System.IO.File]::ReadAllText((Join-Path $run.Snapshots "$call.runid")))
        }
        Assert-True "AI_HARNESS_RUN_ID unset after the run" ($null -eq $env:AI_HARNESS_RUN_ID)
    }

    Test-Case "AC-305 a valid -RunId is used; an outer AI_HARNESS_RUN_ID is replaced for the stages and restored after success and after a failure" {
        $env:AI_HARNESS_RUN_ID = "outer-correlation-7"
        try {
            $run = Invoke-Specify -Options @{ RunId = "b4-given-run.1" } -Scenario "reviewer=pass" -Snapshots
            Assert-Protocol $run 0
            Assert-Equal "run id" "b4-given-run.1" $run.RunId
            Assert-Equal "manifest runId" "b4-given-run.1" $run.Manifest.runId
            Assert-Equal "id seen by the runner" "b4-given-run.1" ([System.IO.File]::ReadAllText((Join-Path $run.Snapshots "runner1.runid")))
            Assert-Equal "AI_HARNESS_RUN_ID restored (success)" "outer-correlation-7" $env:AI_HARNESS_RUN_ID
            $failed = Invoke-Specify -Options @{ RunId = "b4-given-run.2" } -Scenario "runner=throw"
            Assert-Protocol $failed 2 "stage_failed"
            Assert-Equal "AI_HARNESS_RUN_ID restored (failure)" "outer-correlation-7" $env:AI_HARNESS_RUN_ID
        }
        finally { Remove-Item Env:\AI_HARNESS_RUN_ID -ErrorAction SilentlyContinue }
    }

    Test-Case "AC-305 AI_HARNESS_RUN_ID as the id: used when free; when taken, the stages see the suffixed id, run_id_env_reused is recorded, the outer value is restored" {
        $env:AI_HARNESS_RUN_ID = "b4-correlation-a"
        try {
            $first = Invoke-Specify -Scenario "reviewer=pass"
            Assert-Equal "first id" "b4-correlation-a" $first.RunId
            $second = Invoke-Specify -Scenario "reviewer=pass" -Snapshots
            Assert-True "suffixed id ($($second.RunId))" ($second.RunId -cmatch '^b4-correlation-a-[0-9a-f]{4}$')
            Assert-True "run_id_env_reused" (@($second.Manifest.warnings) -ccontains "run_id_env_reused")
            Assert-Equal "id seen by the runner" $second.RunId ([System.IO.File]::ReadAllText((Join-Path $second.Snapshots "runner1.runid")))
            Assert-Equal "AI_HARNESS_RUN_ID restored" "b4-correlation-a" $env:AI_HARNESS_RUN_ID
        }
        finally { Remove-Item Env:\AI_HARNESS_RUN_ID -ErrorAction SilentlyContinue }
    }

    Test-Case "AC-305 .gitignore ignores the run folders (line runs/, written /runs/ by B1)" {
        $lines = @([System.IO.File]::ReadAllLines((Join-Path $root ".gitignore")) | ForEach-Object { $_.Trim() })
        Assert-True "runs/ or /runs/" (($lines -ccontains "runs/") -or ($lines -ccontains "/runs/"))
    }

    # -----------------------------------------------------------------------
    # AC-307: manifest of a successful run (child process for the pid)
    # -----------------------------------------------------------------------

    Test-Case "AC-307 the one-revision manifest: valid, succeeded, six stages, hashes, trust, empty verification, pid and start of the child, task and registry hashes" {
        $run = Invoke-Driver -Scenario "reviewer=fail,pass"
        Assert-Protocol $run 0
        $m = $run.Manifest
        Assert-Equal "status" "succeeded" $m.status
        Assert-Equal "stages" "spec-generate/1/succeeded spec-validate/1/succeeded spec-review/1/succeeded spec-revise/1/succeeded revised-validate/1/succeeded spec-review/2/succeeded" (Get-StageSummary $m)
        Assert-Equal "verdict round 1" "FAIL" (Get-Stage $m "spec-review" 1).verdict
        Assert-Equal "verdict round 2" "PASS" (Get-Stage $m "spec-review" 2).verdict
        foreach ($stage in @($m.stages)) {
            if ($null -ne $stage.output) { Assert-Equal "output sha256 of $($stage.id)/$($stage.attempt)" (Get-Sha $stage.output.path) $stage.output.sha256 }
        }
        Assert-Equal "artifacts" 4 @($m.artifacts).Count
        foreach ($artifact in @($m.artifacts)) { Assert-Equal "trust of $($artifact.path)" "untrusted-draft" $artifact.trust; Assert-Equal "root" "target" $artifact.root }
        Assert-ArtifactHashes $run
        Assert-Equal "verification" 0 @($m.verification).Count
        Assert-Equal "pid" $run.Pid $m.process.pid
        $recordedStart = [datetime]::Parse($m.process.processStartUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]([System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal))
        Assert-True "processStartUtc within 2 s of the child start" ([math]::Abs(($recordedStart - $run.StartUtc).TotalSeconds) -le 2)
        Assert-Equal "background" "False" $m.process.background
        $expectedTask = Join-Path $tempRoot "expected-task.txt"
        [System.IO.File]::WriteAllText($expectedTask, $task, $utf8NoBom)
        Assert-Equal "taskSha256" (Get-Sha $expectedTask) $m.request.taskSha256
        Assert-Equal "registrySha256" (Get-Sha $harnessConfig) $m.harness.registrySha256
        Assert-Equal "request name" "demo" $m.request.name
        Assert-Equal "request mode" "requirements" $m.request.mode
        Assert-Equal "maxRevisions" 3 $m.request.maxRevisions
        Assert-Equal "workflow" "specify" $m.workflow
        Assert-Equal "target root" $run.Target.ToLowerInvariant() ([string]$m.target.root).ToLowerInvariant()
    }

    # -----------------------------------------------------------------------
    # AC-308: checkpoints (a mock stage reads the manifest while it runs)
    # -----------------------------------------------------------------------

    Test-Case "AC-308 a stage reading manifest.json while it runs sees running, exitCode null, itself running and the earlier stages finished; every checkpoint validates; no temp file remains" {
        $run = Invoke-Specify -Scenario "reviewer=fail,pass" -Snapshots
        Assert-Protocol $run 0
        $expected = [ordered]@{
            runner1   = "spec-generate/1/running spec-validate/1/pending spec-review/1/pending"
            reviewer1 = "spec-generate/1/succeeded spec-validate/1/succeeded spec-review/1/running"
            reviser1  = "spec-generate/1/succeeded spec-validate/1/succeeded spec-review/1/succeeded spec-revise/1/running revised-validate/1/pending spec-review/2/pending"
            reviewer2 = "spec-generate/1/succeeded spec-validate/1/succeeded spec-review/1/succeeded spec-revise/1/succeeded revised-validate/1/succeeded spec-review/2/running"
        }
        foreach ($call in $expected.Keys) {
            $text = [System.IO.File]::ReadAllText((Join-Path $run.Snapshots "$call.json"))
            $check = Test-HarnessManifest -Manifest $text
            Assert-True "snapshot $call validates ($(@($check.errors) -join '; '))" $check.valid
            $snapshot = $text | ConvertFrom-Json
            Assert-Equal "run status seen by $call" "running" $snapshot.status
            Assert-True "exitCode null seen by $call" ($null -eq $snapshot.exitCode)
            Assert-Equal "stages seen by $call" $expected[$call] (Get-StageSummary $snapshot)
            $current = @($snapshot.stages | Where-Object { $_.status -ceq "running" })[0]
            Assert-True "the running stage has a start time" ($null -ne $current.startedAtUtc)
        }
        $leftovers = @(Get-ChildItem -LiteralPath (Join-Path $runsDirectory $run.RunId) -Recurse -Force -Filter "*.tmp")
        Assert-Equal "temp files" 0 $leftovers.Count
    }

    Test-Case "AC-308 a 200 KB task file: the first manifest is written in under 5 s (no task text in it), taskSha256 is the file hash" {
        $big = Join-Path $tempRoot "task-200k.txt"
        [System.IO.File]::WriteAllText($big, ("Line of a long task. " * 10000), $utf8NoBom)
        $run = Invoke-Specify -Options @{ Task = $null; TaskFile = $big } -Scenario "reviewer=pass" -Stages $scenarioStages
        Assert-Protocol $run 0
        $created = [datetime]::Parse($run.Manifest.createdAtUtc, [System.Globalization.CultureInfo]::InvariantCulture)
        $firstStage = [datetime]::Parse((Get-Stage $run.Manifest "spec-generate").startedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture)
        Assert-True "manifest build and first write under 5 s ($(($firstStage - $created).TotalSeconds) s)" (($firstStage - $created).TotalSeconds -lt 5)
        Assert-Equal "taskSha256" (Get-Sha $big) $run.Manifest.request.taskSha256
        Assert-Equal "taskFile" $big.ToLowerInvariant() ([string]$run.Manifest.request.taskFile).ToLowerInvariant()
        Assert-True "no task text in the manifest" (-not $run.ManifestText.Contains("Line of a long task."))
    }

    # -----------------------------------------------------------------------
    # AC-310: telemetry correlation
    # -----------------------------------------------------------------------

    Test-Case "AC-310 each agent stage carries its record: callId, engineAttempts 2, warnings, callDurationMs, resolution, budget (withinBudget false with budget_exceeded)" {
        $plan = @{
            runner1   = @(@{ callId = "call-runner-1"; attempts = 2; warnings = @("budget_exceeded"); profile = "alpha"; modelSource = "agent"; timeoutSec = 222; contextWindow = 8192; estPromptTokens = 9000 })
            reviewer1 = @(@{ callId = "call-reviewer-1"; attempts = 1; profile = "beta"; modelSource = "registry"; model = "test-model-beta"; timeoutSec = 333; contextWindow = 4096; estPromptTokens = 100 })
        }
        $run = Invoke-Specify -Scenario "reviewer=pass" -Telemetry $plan
        Assert-Protocol $run 0
        $records = @(Read-TelemetryRecords $run.RunId)
        Assert-Equal "records of the run" 2 $records.Count
        $generate = Get-Stage $run.Manifest "spec-generate"
        Assert-Equal "callId" "call-runner-1" $generate.callId
        Assert-Equal "engineAttempts" 2 $generate.engineAttempts
        Assert-Equal "callDurationMs" $records[0].duration_ms $generate.callDurationMs
        Assert-True "warnings has budget_exceeded" (@($generate.warnings) -ccontains "budget_exceeded")
        Assert-Equal "resolution profile" "alpha" $generate.resolution.profile
        Assert-Equal "resolution model" "test-model-alpha" $generate.resolution.model
        Assert-Equal "resolution modelSource" "agent" $generate.resolution.modelSource
        Assert-Equal "resolution timeoutSec" 222 $generate.resolution.timeoutSec
        Assert-Equal "budget contextWindow" 8192 $generate.budget.contextWindow
        Assert-Equal "budget estimatedPromptTokens" 9000 $generate.budget.estimatedPromptTokens
        Assert-Equal "withinBudget" "False" $generate.budget.withinBudget
        $review = Get-Stage $run.Manifest "spec-review"
        Assert-Equal "review callId" "call-reviewer-1" $review.callId
        Assert-Equal "review model" "test-model-beta" $review.resolution.model
        Assert-Equal "review withinBudget" "True" $review.budget.withinBudget
        Assert-Equal "review callDurationMs" $records[1].duration_ms $review.callDurationMs
        Assert-True "run warnings has budget_exceeded" (@($run.Manifest.warnings) -ccontains "budget_exceeded")
        Assert-True "telemetry run_id equals runId" (@($records | Where-Object { $_.run_id -cne $run.Manifest.runId }).Count -eq 0)
    }

    Test-Case "AC-310 on failure the stage carries error.engineCategory and error.httpStatus; error.message is the telemetry error column" {
        $plan = @{ runner1 = @(@{ callId = "call-fail-1"; status = "error"; attempts = 2; errorCategory = "http_5xx"; httpStatus = 503; error = "server said no" }) }
        $run = Invoke-Specify -Scenario "runner=exit2" -Telemetry $plan
        Assert-Protocol $run 2 "http_error"
        $record = @(Read-TelemetryRecords $run.RunId)[0]
        $stage = Get-Stage $run.Manifest "spec-generate"
        Assert-Equal "engineCategory" "http_5xx" $stage.error.engineCategory
        Assert-Equal "httpStatus" 503 $stage.error.httpStatus
        Assert-Equal "category" "http_error" $stage.error.category
        Assert-Equal "retryable" "True" $stage.error.retryable
        Assert-Equal "message" $record.error $stage.error.message
        Assert-Equal "run error" "http_error" $run.Manifest.error.category
        Assert-Equal "run httpStatus" 503 $run.Manifest.error.httpStatus
    }

    # The literal FR-307 table.
    $categoryTable = [ordered]@{
        "http_5xx"                  = "http_error"
        "http_4xx"                  = "http_error"
        "timeout"                   = "timeout"
        "transport_unreachable"     = "ollama_unreachable"
        "transport_reset"           = "http_error"
        "transport_other"           = "http_error"
        "context_budget_exceeded"   = "context_budget_exceeded"
        "thinking_budget_exhausted" = "empty_output"
        "empty_response"            = "empty_output"
        "format_invalid"            = "invalid_output_format"
        "model_not_installed"       = "model_not_installed"
        "model_load_failed"         = "model_load_failed"
    }
    foreach ($engineCategory in $categoryTable.Keys) {
        Test-Case "AC-310/AC-311 runner exit 2 with a record of '$engineCategory': exit 2 '$($categoryTable[$engineCategory])', later stages skipped" {
            $plan = @{ runner1 = @(@{ callId = "call-$engineCategory"; status = "error"; errorCategory = $engineCategory; error = "detail" }) }
            $run = Invoke-Specify -Scenario "runner=exit2" -Telemetry $plan
            Assert-Protocol $run 2 $categoryTable[$engineCategory]
            Assert-Equal "run category" $categoryTable[$engineCategory] $run.Manifest.error.category
            Assert-Equal "engineCategory" $engineCategory $run.Manifest.error.engineCategory
            Assert-Equal "retryable" ([string]($engineCategory -ceq "http_5xx" -or $engineCategory -ceq "transport_reset")) ([string]$run.Manifest.error.retryable)
            Assert-FailureShape $run.Manifest "spec-generate"
            if ($engineCategory -ceq "model_load_failed") {
                Assert-True "hint: restarting" ([string]$run.Manifest.error.hint).Contains("Restarting the Ollama server")
                Assert-True "hint: rebooting" ([string]$run.Manifest.error.hint).Contains("rebooting the machine")
            }
        }
    }

    Test-Case "AC-310 no record: callId null and telemetry_record_missing in stage and run; run warnings have no duplicates" {
        $run = Invoke-Specify -Scenario "reviewer=fail,pass"
        Assert-Protocol $run 0
        foreach ($stage in @($run.Manifest.stages | Where-Object { $_.kind -ceq "agent" })) {
            Assert-True "callId null on $($stage.id)/$($stage.attempt)" ($null -eq $stage.callId)
            Assert-True "telemetry_record_missing on $($stage.id)/$($stage.attempt)" (@($stage.warnings) -ccontains "telemetry_record_missing")
        }
        $warnings = @($run.Manifest.warnings)
        Assert-Equal "telemetry_record_missing once in the run" 1 @($warnings | Where-Object { $_ -ceq "telemetry_record_missing" }).Count
        Assert-Equal "run warnings distinct" $warnings.Count @($warnings | Sort-Object -Unique).Count
    }

    Test-Case "AC-310 two records: the last wins and telemetry_multiple_records is added; a record of another run_id is ignored" {
        $plan = @{
            runner1   = @(@{ callId = "first-of-two"; attempts = 1 }, @{ callId = "second-of-two"; attempts = 3 })
            reviewer1 = @(@{ callId = "foreign-call"; runId = "someone-else-run" }, @{ callId = "own-call" })
        }
        $run = Invoke-Specify -Scenario "reviewer=pass" -Telemetry $plan
        Assert-Protocol $run 0
        $generate = Get-Stage $run.Manifest "spec-generate"
        Assert-Equal "last record wins" "second-of-two" $generate.callId
        Assert-Equal "engineAttempts of the last" 3 $generate.engineAttempts
        Assert-True "telemetry_multiple_records" (@($generate.warnings) -ccontains "telemetry_multiple_records")
        $review = Get-Stage $run.Manifest "spec-review"
        Assert-Equal "own record" "own-call" $review.callId
        Assert-True "no multiple warning (the foreign record is ignored)" (-not (@($review.warnings) -ccontains "telemetry_multiple_records"))
        $onlyForeign = Invoke-Specify -Scenario "reviewer=pass" -Telemetry @{ runner1 = @(@{ callId = "foreign-only"; runId = "someone-else-run" }) }
        $alone = Get-Stage $onlyForeign.Manifest "spec-generate"
        Assert-True "only a foreign record: callId null" ($null -eq $alone.callId)
        Assert-True "only a foreign record: telemetry_record_missing" (@($alone.warnings) -ccontains "telemetry_record_missing")
    }

    Test-Case "AC-310 a JSONL with a leading BOM is read; the first line of model-calls.csv is the frozen 31-column header" {
        if (Test-Path -LiteralPath $harnessLogs) { Remove-Item -LiteralPath $harnessLogs -Recurse -Force }
        $run = Invoke-Specify -Scenario "reviewer=pass" -Telemetry @{ runner1 = @(@{ callId = "after-bom" }) }
        Assert-Protocol $run 0
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $harnessLogs "model-calls.jsonl"))
        Assert-True "the JSONL starts with a BOM" ($bytes.Length -gt 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Assert-Equal "callId read from offset 0" "after-bom" (Get-Stage $run.Manifest "spec-generate").callId
        $columns = @("timestamp_utc", "run_id", "agent", "model", "status", "started_at_utc", "duration_ms", "total_duration_ns",
            "load_duration_ns", "prompt_eval_count", "prompt_eval_duration_ns", "eval_count", "eval_duration_ns", "error",
            "schema_version", "call_id", "profile", "model_source", "transport", "model_called", "attempts", "error_category",
            "http_status", "done_reason", "thinking_chars", "think_sent", "timeout_sec", "context_window", "prompt_chars", "est_prompt_tokens", "warnings")
        $header = @([System.IO.File]::ReadAllLines((Join-Path $harnessLogs "model-calls.csv")))[0].TrimStart([char]0xFEFF)
        Assert-Equal "CSV header" ('"' + ($columns -join '","') + '"') $header
    }

    # -----------------------------------------------------------------------
    # AC-311: failure matrix (the rows the AC-303 and category cases do not cover)
    # -----------------------------------------------------------------------

    $matrix = @(
        @{ Label = "reviewer exit 2 with a record of format_invalid"; Scenario = "reviewer=exit2"; Plan = @{ reviewer1 = @(@{ status = "error"; errorCategory = "format_invalid"; error = "no status line" }) }; Exit = 2; Category = "invalid_output_format"; Stage = "spec-review"; Attempt = 1 },
        @{ Label = "runner exit 2 with no record"; Scenario = "runner=exit2"; Plan = $null; Exit = 2; Category = "stage_failed"; Stage = "spec-generate"; Attempt = 1 },
        @{ Label = "reviser throws with a record of http_5xx"; Scenario = "reviewer=fail;reviser=throw"; Plan = @{ reviser1 = @(@{ status = "error"; errorCategory = "http_5xx"; httpStatus = 500; error = "boom" }) }; Exit = 2; Category = "http_error"; Stage = "spec-revise"; Attempt = 1 },
        @{ Label = "reviser throws with no record"; Scenario = "reviewer=fail;reviser=throw"; Plan = $null; Exit = 2; Category = "stage_failed"; Stage = "spec-revise"; Attempt = 1 },
        @{ Label = "reviser exit 2 with a record of model_not_installed"; Scenario = "reviewer=fail;reviser=exit2"; Plan = @{ reviser1 = @(@{ status = "error"; errorCategory = "model_not_installed" }) }; Exit = 2; Category = "model_not_installed"; Stage = "spec-revise"; Attempt = 1 },
        @{ Label = "runner throws with a record of timeout"; Scenario = "runner=throw"; Plan = @{ runner1 = @(@{ status = "error"; errorCategory = "timeout" }) }; Exit = 2; Category = "timeout"; Stage = "spec-generate"; Attempt = 1 },
        @{ Label = "runner ends well without output (a record of empty_response does not count)"; Scenario = "runner=nooutput"; Plan = @{ runner1 = @(@{ status = "error"; errorCategory = "empty_response" }) }; Exit = 2; Category = "stage_failed"; Stage = "spec-generate"; Attempt = 1 },
        @{ Label = "reviewer throws (a record of http_5xx does not count)"; Scenario = "reviewer=throw"; Plan = @{ reviewer1 = @(@{ status = "error"; errorCategory = "http_5xx" }) }; Exit = 2; Category = "stage_failed"; Stage = "spec-review"; Attempt = 1 },
        @{ Label = "reviewer exit 5 (a record does not count)"; Scenario = "reviewer=exit5"; Plan = @{ reviewer1 = @(@{ status = "error"; errorCategory = "timeout" }) }; Exit = 2; Category = "stage_failed"; Stage = "spec-review"; Attempt = 1 },
        @{ Label = "reviewer exit 0 without a review file"; Scenario = "reviewer=nooutput"; Plan = $null; Exit = 2; Category = "stage_failed"; Stage = "spec-review"; Attempt = 1 },
        @{ Label = "first validation exit 3"; Scenario = "validator=exit3"; Plan = $null; Exit = 3; Category = "needs_human_input"; Stage = "spec-validate"; Attempt = 1 },
        @{ Label = "first validation exit 1"; Scenario = "validator=exit1"; Plan = $null; Exit = 1; Category = "validation_failed"; Stage = "spec-validate"; Attempt = 1 },
        @{ Label = "first validation throws"; Scenario = "validator=throw"; Plan = $null; Exit = 2; Category = "stage_failed"; Stage = "spec-validate"; Attempt = 1 },
        @{ Label = "revised validation exit 3"; Scenario = "reviewer=fail;validator=ok,exit3"; Plan = $null; Exit = 1; Category = "validation_failed"; Stage = "revised-validate"; Attempt = 1 },
        @{ Label = "revised validation exit 2"; Scenario = "reviewer=fail;validator=ok,exit2"; Plan = $null; Exit = 2; Category = "stage_failed"; Stage = "revised-validate"; Attempt = 1 },
        @{ Label = "revised validation throws"; Scenario = "reviewer=fail;validator=ok,throw"; Plan = $null; Exit = 2; Category = "stage_failed"; Stage = "revised-validate"; Attempt = 1 },
        @{ Label = "second review exit 2 after one revision"; Scenario = "reviewer=fail,exit2"; Plan = $null; Exit = 2; Category = "stage_failed"; Stage = "spec-review"; Attempt = 2 }
    )
    foreach ($row in $matrix) {
        Test-Case "AC-311 $($row.Label): exit $($row.Exit) $($row.Category), failing stage failed, later stages skipped, earlier artifacts kept" {
            $run = Invoke-Specify -Scenario $row.Scenario -Telemetry $row.Plan
            Assert-Protocol $run $row.Exit $row.Category
            Assert-Equal "run category" $row.Category $run.Manifest.error.category
            Assert-FailureShape $run.Manifest $row.Stage $row.Attempt
            Assert-Equal "stage error category" $row.Category (Get-Stage $run.Manifest $row.Stage $row.Attempt).error.category
            $expectedStatus = if ($row.Exit -eq 3) { "needs_input" } else { "failed" }
            Assert-Equal "run status" $expectedStatus $run.Manifest.status
            Assert-ArtifactHashes $run
            if ($row.Stage -cne "spec-generate") { Assert-True "the generated spec is kept and listed" (@($run.Manifest.artifacts | Where-Object { $_.path -ceq ".ai-harness\specs\demo.md" }).Count -eq 1) }
        }
    }

    Test-Case "AC-311 FAIL after revision 3: exit 1 max_revisions_reached, the last review succeeded with verdict FAIL, nothing skipped" {
        $run = Invoke-Specify -Scenario "reviewer=fail"
        Assert-Protocol $run 1 "max_revisions_reached"
        $last = Get-Stage $run.Manifest "spec-review" 4
        Assert-Equal "last review" "succeeded" $last.status
        Assert-Equal "verdict" "FAIL" $last.verdict
        Assert-Equal "stages" 12 @($run.Manifest.stages).Count
        Assert-Equal "skipped" 0 @($run.Manifest.stages | Where-Object { $_.status -ceq "skipped" }).Count
        Assert-Equal "run status" "failed" $run.Manifest.status
    }

    Test-Case "AC-311 missing .ai\agents\spec.md: exit 2 agent_not_found, no stage ran, planned stages skipped 'not reached: agent_not_found'" {
        $agentFile = Join-Path $harnessRoot ".ai\agents\spec.md"
        $aside = Join-Path $tempRoot "spec.md.aside"
        [System.IO.File]::Move($agentFile, $aside)
        try { $run = Invoke-Specify -Scenario "reviewer=pass" }
        finally { [System.IO.File]::Move($aside, $agentFile) }
        Assert-Protocol $run 2 "agent_not_found"
        Assert-Equal "stage calls" 0 $run.Record.Count
        Assert-Equal "stages" "spec-generate/1/skipped spec-validate/1/skipped spec-review/1/skipped" (Get-StageSummary $run.Manifest)
        foreach ($stage in @($run.Manifest.stages)) { Assert-Equal "reason" "not reached: agent_not_found" $stage.reason }
        Assert-True "no artifact folder" (-not (Test-Path -LiteralPath $run.SpecDirectory))
    }

    Test-Case "AC-311 an invalid registry: exit 2 registry_invalid, no stage ran, planned stages skipped 'not reached: registry_invalid'" {
        [System.IO.File]::WriteAllText($harnessConfig, $v2Invalid, $utf8NoBom)
        try { $run = Invoke-Specify -Scenario "reviewer=pass" }
        finally { [System.IO.File]::WriteAllText($harnessConfig, $baseConfig, $utf8NoBom) }
        Assert-Protocol $run 2 "registry_invalid"
        Assert-Equal "stage calls" 0 $run.Record.Count
        foreach ($stage in @($run.Manifest.stages)) { Assert-Equal "status" "skipped" $stage.status; Assert-Equal "reason" "not reached: registry_invalid" $stage.reason }
    }

    Test-Case "AC-311 an unknown -Profile is registry_invalid before any stage" {
        $run = Invoke-Specify -Options @{ Profile = "no-such-profile" } -Scenario "reviewer=pass"
        Assert-Protocol $run 2 "registry_invalid"
        Assert-Equal "stage calls" 0 $run.Record.Count
    }

    Test-Case "AC-311 specify -LoadCheck (fake host) failing as model_load_failed: exit 2, one load request, no artifact written, later stages skipped" {
        $target = New-Target
        $cuda = New-Step "http" @{ status = 500; body = '{"error":"CUDA error: out of memory"}' }
        $case = Invoke-Case -Name "load-check-fails" -ConfigText $baseConfig -Script "harness.ps1" -ArgumentList @("specify", "-TargetPath", $target, "-Name", "demo", "-Task", $task, "-LoadCheck") -GenerateSteps @($cuda) -TypedExceptions
        Assert-Guards $case
        $run = [pscustomobject]@{ ExitCode = $case.ExitCode; Lines = @($case.Lines | Where-Object { -not $_.StartsWith("FAKE-HOST:", [System.StringComparison]::Ordinal) }); Target = $target }
        Add-ManifestFields $run
        Assert-Protocol $run 2 "model_load_failed"
        Assert-Equal "requests" 1 @(Get-Route $case "generate").Count
        Assert-Equal "no other route" 1 $case.Calls.Count
        $stage = Get-Stage $run.Manifest "load-check"
        Assert-Equal "load-check status" "failed" $stage.status
        Assert-Equal "engineCategory" "model_load_failed" $stage.error.engineCategory
        Assert-Equal "retryable" "False" $stage.error.retryable
        Assert-True "httpStatus null" ($null -eq $stage.error.httpStatus)
        Assert-True "hint: restarting" ([string]$stage.error.hint).Contains("Restarting the Ollama server")
        Assert-FailureShape $run.Manifest "load-check"
        Assert-True "no artifact written" (-not (Test-Path -LiteralPath (Get-SpecDirectory $target)))
        Assert-Equal "artifacts" 0 @($run.Manifest.artifacts).Count
    }

    # -----------------------------------------------------------------------
    # AC-313: output protocol (child processes)
    # -----------------------------------------------------------------------

    foreach ($row in @(
            @{ Label = "success"; Scenario = "reviewer=pass"; Exit = 0; Category = "" },
            @{ Label = "exit 1"; Scenario = "validator=exit1"; Exit = 1; Category = "validation_failed" },
            @{ Label = "exit 2"; Scenario = "runner=exit2"; Exit = 2; Category = "stage_failed" },
            @{ Label = "exit 3"; Scenario = "validator=exit3"; Exit = 3; Category = "needs_human_input" })) {
        Test-Case "AC-313 child process, $($row.Label): RUN_ID first, MANIFEST last, ERROR just before it, manifest valid with the exit code" {
            $run = Invoke-Driver -Scenario $row.Scenario
            Assert-Protocol $run $row.Exit $row.Category
        }
    }

    Test-Case "AC-313 child process, exit 4 (harness.ps1 develop): the same protocol" {
        $before = Get-RunCount
        $run = Invoke-Harness -Arguments @("develop")
        Add-ManifestFields $run
        Assert-Protocol $run 4 "unsupported_stage"
        Assert-Equal "one run" ($before + 1) (Get-RunCount)
    }

    Test-Case "AC-313 a bad -RunId: one ERROR: invalid_arguments: line, exit 2, nothing new under runs\" {
        $before = Get-RunCount
        $run = Invoke-Harness -Arguments @("specify", "-TargetPath", (New-Target), "-Name", "demo", "-Task", $task, "-RunId", "bad id")
        Assert-Equal "exit" 2 $run.ExitCode
        Assert-Equal "lines" 1 $run.Lines.Count
        Assert-True "ERROR: invalid_arguments:" ($run.Lines[0].StartsWith("ERROR: invalid_arguments:", [System.StringComparison]::Ordinal))
        Assert-Equal "runs" $before (Get-RunCount)
    }

    Test-Case "AC-313 a taken -RunId: invalid_arguments before RUN_ID; the existing manifest keeps its bytes" {
        $first = Invoke-Specify -Options @{ RunId = "b4-taken-id" } -Scenario "reviewer=pass"
        $sha = Get-Sha $first.ManifestPath
        $second = Invoke-Specify -Options @{ RunId = "b4-taken-id" } -Scenario "reviewer=pass"
        Assert-Equal "exit" 2 $second.ExitCode
        Assert-Equal "lines" 1 $second.Lines.Count
        Assert-True "ERROR: invalid_arguments:" ($second.Lines[0].StartsWith("ERROR: invalid_arguments:", [System.StringComparison]::Ordinal))
        Assert-Equal "stage calls" 0 $second.Record.Count
        Assert-Equal "manifest unchanged" $sha (Get-Sha $first.ManifestPath)
    }

    Test-Case "AC-313 in process the last line of the success stream is MANIFEST: for every outcome" {
        foreach ($scenario in @("reviewer=pass", "reviewer=fail", "runner=exit2", "validator=exit3", "validator=exit1")) {
            $run = Invoke-Specify -Scenario $scenario -Stages $scenarioStages
            $last = $run.Lines[$run.Lines.Count - 1]
            Assert-True "last line for $scenario ($last)" ($last.StartsWith("MANIFEST: ", [System.StringComparison]::Ordinal))
            Assert-Equal "RUN_ID first for $scenario" "RUN_ID: $($run.Manifest.runId)" $run.Lines[0]
        }
    }

    # -----------------------------------------------------------------------
    # AC-321 (B4 part): real scripts in the engine fake host; AC-327 on the same run
    # -----------------------------------------------------------------------

    $tagsOk = New-Step "ok" @{ models = @("test-model-alpha") }
    $marker = "B4-TASK-MARKER-" + [guid]::NewGuid().ToString("N")
    $markerTask = "Specify a user registration form. $marker"

    Test-Case "AC-321 harness specify with the real scripts (spec, validation, FAIL review, revision, PASS): stage callId, resolution, engineAttempts equal the one record per agent stage; telemetry run_id is the runId; AC-327 the task marker is only in inputs\task.md" {
        $target = New-Target
        $case = Invoke-Case -Name "e2e-success" -ConfigText $baseConfig -Script "harness.ps1" -ArgumentList @("specify", "-TargetPath", $target, "-Name", "feature", "-Task", $markerTask) `
            -TagsSteps @($tagsOk, $tagsOk, $tagsOk, $tagsOk) -GenerateSteps @((& $okReply $validSpecText), (& $okReply $reviewFail), (& $okReply $validSpecText), (& $okReply $reviewPass)) -TypedExceptions
        Assert-Guards $case
        Assert-True "only fake routes" (@($case.Calls | Where-Object { -not ([string]$_.uri).StartsWith("http://127.0.0.1:9/", [System.StringComparison]::Ordinal) }).Count -eq 0)
        $run = [pscustomobject]@{ ExitCode = $case.ExitCode; Lines = @($case.Lines | Where-Object { -not $_.StartsWith("FAKE-HOST:", [System.StringComparison]::Ordinal) }); Target = $target }
        Add-ManifestFields $run
        Assert-Protocol $run 0
        Assert-Equal "stages" "spec-generate/1/succeeded spec-validate/1/succeeded spec-review/1/succeeded spec-revise/1/succeeded revised-validate/1/succeeded spec-review/2/succeeded" (Get-StageSummary $run.Manifest)
        $records = @($case.Telemetry)
        Assert-Equal "telemetry records" 4 $records.Count
        foreach ($record in $records) { Assert-Equal "telemetry run_id" $run.Manifest.runId $record.run_id }
        $agentStages = @($run.Manifest.stages | Where-Object { $_.kind -ceq "agent" })
        Assert-Equal "agent stages" 4 $agentStages.Count
        for ($i = 0; $i -lt 4; $i++) {
            $stage = $agentStages[$i]
            Assert-Equal "agent of record $i" $stage.agent $records[$i].agent
            Assert-Equal "callId of $($stage.id)/$($stage.attempt)" $records[$i].call_id $stage.callId
            Assert-Equal "engineAttempts of $($stage.id)/$($stage.attempt)" $records[$i].attempts $stage.engineAttempts
            Assert-Equal "model of $($stage.id)/$($stage.attempt)" $records[$i].model $stage.resolution.model
            Assert-Equal "profile of $($stage.id)/$($stage.attempt)" $records[$i].profile $stage.resolution.profile
            Assert-Equal "modelSource of $($stage.id)/$($stage.attempt)" $records[$i].model_source $stage.resolution.modelSource
            Assert-Equal "timeoutSec of $($stage.id)/$($stage.attempt)" $records[$i].timeout_sec $stage.resolution.timeoutSec
        }
        Assert-ArtifactHashes $run

        # AC-327: the marker is in inputs\task.md and nowhere else under runs\<id>\ or in the
        # telemetry lines this run wrote.
        $runPath = Join-Path $runsDirectory $run.Manifest.runId
        Assert-True "marker in task.md" ([System.IO.File]::ReadAllText((Join-Path $runPath "inputs\task.md")).Contains($marker))
        foreach ($file in @(Get-ChildItem -LiteralPath $runPath -Recurse -Force -File)) {
            if ($file.FullName -ceq (Join-Path $runPath "inputs\task.md")) { continue }
            Assert-True "no marker in $($file.Name)" (-not [System.IO.File]::ReadAllText($file.FullName).Contains($marker))
        }
        foreach ($log in @("model-calls.jsonl", "model-calls.csv")) {
            $path = Join-Path $harnessLogs $log
            Assert-True "$log exists" (Test-Path -LiteralPath $path)
            Assert-True "no marker in $log" (-not [System.IO.File]::ReadAllText($path).Contains($marker))
        }
    }

    Test-Case "AC-321 a 500 on the reviewer: exit 2 http_error, engineCategory http_5xx, stage spec-review failed" {
        $target = New-Target
        $http500 = New-Step "http" @{ status = 500; body = '{"error":"internal server error"}' }
        $case = Invoke-Case -Name "e2e-reviewer-500" -ConfigText $baseConfig -Script "harness.ps1" -ArgumentList @("specify", "-TargetPath", $target, "-Name", "feature", "-Task", $task) `
            -TagsSteps @($tagsOk, $tagsOk) -GenerateSteps @((& $okReply $validSpecText), $http500, $http500) -TypedExceptions
        Assert-Guards $case
        $run = [pscustomobject]@{ ExitCode = $case.ExitCode; Lines = @($case.Lines | Where-Object { -not $_.StartsWith("FAKE-HOST:", [System.StringComparison]::Ordinal) }); Target = $target }
        Add-ManifestFields $run
        Assert-Protocol $run 2 "http_error"
        $stage = Get-Stage $run.Manifest "spec-review"
        Assert-Equal "status" "failed" $stage.status
        Assert-Equal "engineCategory" "http_5xx" $stage.error.engineCategory
        Assert-Equal "httpStatus" 500 $stage.error.httpStatus
        Assert-Equal "engineAttempts" 2 $stage.engineAttempts
        Assert-FailureShape $run.Manifest "spec-review"
    }

    Test-Case "AC-321 a 500 on the reviser (which throws): exit 2 http_error, stage spec-revise failed, not internal_error" {
        $target = New-Target
        $http500 = New-Step "http" @{ status = 500; body = '{"error":"internal server error"}' }
        $case = Invoke-Case -Name "e2e-reviser-500" -ConfigText $baseConfig -Script "harness.ps1" -ArgumentList @("specify", "-TargetPath", $target, "-Name", "feature", "-Task", $task) `
            -TagsSteps @($tagsOk, $tagsOk, $tagsOk) -GenerateSteps @((& $okReply $validSpecText), (& $okReply $reviewFail), $http500, $http500) -TypedExceptions
        Assert-Guards $case
        $run = [pscustomobject]@{ ExitCode = $case.ExitCode; Lines = @($case.Lines | Where-Object { -not $_.StartsWith("FAKE-HOST:", [System.StringComparison]::Ordinal) }); Target = $target }
        Add-ManifestFields $run
        Assert-Protocol $run 2 "http_error"
        $stage = Get-Stage $run.Manifest "spec-revise"
        Assert-Equal "status" "failed" $stage.status
        Assert-Equal "category" "http_error" $stage.error.category
        Assert-Equal "engineCategory" "http_5xx" $run.Manifest.error.engineCategory
        Assert-FailureShape $run.Manifest "spec-revise"
    }

    Test-Case "AC-321 a 500 with a CUDA error body on the runner: exit 2 model_load_failed after one attempt" {
        $target = New-Target
        $cuda = New-Step "http" @{ status = 500; body = '{"error":"CUDA error: an illegal memory access was encountered"}' }
        $case = Invoke-Case -Name "e2e-runner-cuda" -ConfigText $baseConfig -Script "harness.ps1" -ArgumentList @("specify", "-TargetPath", $target, "-Name", "feature", "-Task", $task) `
            -TagsSteps @($tagsOk) -GenerateSteps @($cuda) -TypedExceptions
        Assert-Guards $case
        $run = [pscustomobject]@{ ExitCode = $case.ExitCode; Lines = @($case.Lines | Where-Object { -not $_.StartsWith("FAKE-HOST:", [System.StringComparison]::Ordinal) }); Target = $target }
        Add-ManifestFields $run
        Assert-Protocol $run 2 "model_load_failed"
        Assert-Equal "one generate request" 1 @(Get-Route $case "generate").Count
        $stage = Get-Stage $run.Manifest "spec-generate"
        Assert-Equal "engineCategory" "model_load_failed" $stage.error.engineCategory
        Assert-Equal "retryable" "False" $stage.error.retryable
        Assert-FailureShape $run.Manifest "spec-generate"
    }

    Test-Case "AC-321 a reviewer answer with prompt_eval_count 1: prompt_truncation_detected in stage and run warnings, the WARNING line is printed, the outcome is unchanged" {
        $target = New-Target
        $cut = New-Step "ok" @{ response = $reviewPass; doneReason = "stop"; promptEvalCount = 1 }
        $case = Invoke-Case -Name "e2e-truncation" -ConfigText $baseConfig -Script "harness.ps1" -ArgumentList @("specify", "-TargetPath", $target, "-Name", "feature", "-Task", $task) `
            -TagsSteps @($tagsOk, $tagsOk) -GenerateSteps @((& $okReply $validSpecText), $cut) -TypedExceptions
        Assert-Guards $case
        $run = [pscustomobject]@{ ExitCode = $case.ExitCode; Lines = @($case.Lines | Where-Object { -not $_.StartsWith("FAKE-HOST:", [System.StringComparison]::Ordinal) }); Target = $target }
        Add-ManifestFields $run
        Assert-Protocol $run 0
        Assert-True "stage warning" (@((Get-Stage $run.Manifest "spec-review").warnings) -ccontains "prompt_truncation_detected")
        Assert-True "run warning" (@($run.Manifest.warnings) -ccontains "prompt_truncation_detected")
        Assert-True "no truncation on spec-generate" (-not (@((Get-Stage $run.Manifest "spec-generate").warnings) -ccontains "prompt_truncation_detected"))
        Assert-ExactLine $case "WARNING: prompt_truncation_detected: spec-review"
    }

    # -----------------------------------------------------------------------
    # AC-328: names, overwrite, path safety
    # -----------------------------------------------------------------------

    foreach ($badName in @("a.review", "a.revised-v1", "a.revised-v12.x", "a.", "CON", "nul.txt", ".a", "a b", "a`n")) {
        $shown = $badName.Replace("`n", "<LF>")
        Test-Case "AC-328 -Name '$shown' exits 2 invalid_arguments before any run" {
            $before = Get-RunCount
            $run = Invoke-Specify -Options @{ Name = $badName } -Scenario "reviewer=pass"
            Assert-Equal "exit" 2 $run.ExitCode
            Assert-Equal "lines" 1 $run.Lines.Count
            Assert-True "ERROR: invalid_arguments:" ($run.Lines[0].StartsWith("ERROR: invalid_arguments:", [System.StringComparison]::Ordinal))
            Assert-Equal "runs" $before (Get-RunCount)
            Assert-Equal "stage calls" 0 $run.Record.Count
        }
    }

    foreach ($goodName in @("a.revised-vx", "a.b-c_d", "review")) {
        Test-Case "AC-328 -Name '$goodName' is accepted and written as $goodName.md" {
            $run = Invoke-Specify -Options @{ Name = $goodName } -Scenario "reviewer=pass" -Stages $scenarioStages
            Assert-Protocol $run 0
            Assert-True "spec file" ([System.IO.File]::Exists((Join-Path $run.SpecDirectory "$goodName.md")))
        }
    }

    foreach ($leaf in @("demo.md", "demo.review.md", "demo.revised-v1.md", "demo.revised-v2.review.md", "DEMO.Review.MD")) {
        Test-Case "AC-328 with '$leaf' present: exit 2 artifact_exists, no stage ran, the file keeps its SHA-256, the manifest is valid" {
            $target = New-Target
            $specs = Get-SpecDirectory $target
            [void][System.IO.Directory]::CreateDirectory($specs)
            $existing = Join-Path $specs $leaf
            [System.IO.File]::WriteAllText($existing, "old $leaf", $utf8NoBom)
            $sha = Get-Sha $existing
            $run = Invoke-Specify -Target $target -Scenario "reviewer=pass"
            Assert-Protocol $run 2 "artifact_exists"
            Assert-Equal "stage calls" 0 $run.Record.Count
            Assert-Equal "sha256 kept" $sha (Get-Sha $existing)
            Assert-Equal "files in specs" $leaf (@(Get-ChildItem -LiteralPath $specs -Force | ForEach-Object { $_.Name }) -join "|")
            foreach ($stage in @($run.Manifest.stages)) { Assert-Equal "reason" "not reached: artifact_exists" $stage.reason }
            Assert-Equal "artifacts" 0 @($run.Manifest.artifacts).Count
            Assert-True "no replaced folder" (-not (Test-Path -LiteralPath (Join-Path (Join-Path $runsDirectory $run.RunId) "replaced")))
        }
    }

    Test-Case "AC-328 another name's files do not count (demo2.md, demox.review.md, demo.b.md, demo.revised-vx.md)" {
        $target = New-Target
        $specs = Get-SpecDirectory $target
        [void][System.IO.Directory]::CreateDirectory($specs)
        $others = @("demo2.md", "demox.review.md", "demo.b.md", "demo.revised-vx.md")
        $hashes = @{}
        foreach ($leaf in $others) { [System.IO.File]::WriteAllText((Join-Path $specs $leaf), "other $leaf", $utf8NoBom); $hashes[$leaf] = Get-Sha (Join-Path $specs $leaf) }
        $run = Invoke-Specify -Target $target -Scenario "reviewer=pass" -Stages $scenarioStages
        Assert-Protocol $run 0
        foreach ($leaf in $others) { Assert-Equal "$leaf kept" $hashes[$leaf] (Get-Sha (Join-Path $specs $leaf)) }
    }

    Test-Case "AC-328 -Overwrite moves the whole family to runs\<id>\replaced\ with the same bytes, lists it as replaced, and the run writes the four files" {
        $target = New-Target
        $specs = Get-SpecDirectory $target
        [void][System.IO.Directory]::CreateDirectory($specs)
        $family = @("demo.md", "demo.review.md", "demo.revised-v1.md", "demo.revised-v2.review.md")
        $hashes = @{}
        foreach ($leaf in $family + @("other.md")) { [System.IO.File]::WriteAllText((Join-Path $specs $leaf), "old $leaf", $utf8NoBom); $hashes[$leaf] = Get-Sha (Join-Path $specs $leaf) }
        $run = Invoke-Specify -Target $target -Options @{ Overwrite = $true } -Scenario "reviewer=fail,pass" -Stages $scenarioStages
        Assert-Protocol $run 0
        $replaced = Join-Path (Join-Path $runsDirectory $run.RunId) "replaced"
        Assert-Equal "replaced files" (($family | Sort-Object) -join "|") (@(Get-ChildItem -LiteralPath $replaced -Force | ForEach-Object { $_.Name } | Sort-Object) -join "|")
        foreach ($leaf in $family) { Assert-Equal "bytes of $leaf" $hashes[$leaf] (Get-Sha (Join-Path $replaced $leaf)) }
        $listed = @($run.Manifest.artifacts | Where-Object { $_.role -ceq "replaced" })
        Assert-Equal "replaced artifacts" 4 $listed.Count
        foreach ($artifact in $listed) {
            Assert-Equal "root" "run" $artifact.root
            Assert-Equal "sha of $($artifact.path)" $hashes[$artifact.path.Substring(9)] $artifact.sha256
        }
        Assert-Equal "specs now" "demo.md|demo.review.md|demo.revised-v1.md|demo.revised-v1.review.md|other.md" (@(Get-ChildItem -LiteralPath $specs -Force | ForEach-Object { $_.Name } | Sort-Object) -join "|")
        Assert-Equal "other.md kept" $hashes["other.md"] (Get-Sha (Join-Path $specs "other.md"))
        Assert-ArtifactHashes $run
    }

    foreach ($level in @(".ai-harness", ".ai-harness\specs")) {
        Test-Case "AC-328 a junction as '$level' exits 2 invalid_arguments; nothing is written through it and no run exists" {
            $target = New-Target
            $outside = Join-Path $tempRoot ("outside-" + $script:caseIndex)
            [void][System.IO.Directory]::CreateDirectory($outside)
            if ($level -ceq ".ai-harness\specs") { [void][System.IO.Directory]::CreateDirectory((Join-Path $target ".ai-harness")) }
            $junction = Join-Path $target $level
            [void](New-Item -ItemType Junction -Path $junction -Target $outside)
            try {
                $before = Get-RunCount
                $run = Invoke-Specify -Target $target -Scenario "reviewer=pass"
                Assert-Equal "exit" 2 $run.ExitCode
                Assert-Equal "lines" 1 $run.Lines.Count
                Assert-True "ERROR: invalid_arguments:" ($run.Lines[0].StartsWith("ERROR: invalid_arguments:", [System.StringComparison]::Ordinal))
                Assert-Equal "nothing written through the junction" 0 @(Get-ChildItem -LiteralPath $outside -Force -Recurse).Count
                Assert-Equal "runs" $before (Get-RunCount)
            }
            finally { [System.IO.Directory]::Delete($junction) }
        }
    }

    # -----------------------------------------------------------------------
    # Value sets, -Include, the in-process guard
    # -----------------------------------------------------------------------

    Test-Case "B4 -Include is refused before the claim (B8 implements it): one ERROR line, exit 2, no run" {
        $before = Get-RunCount
        $run = Invoke-Specify -Options @{ Include = "a.md" } -Scenario "reviewer=pass"
        Assert-Equal "exit" 2 $run.ExitCode
        Assert-Equal "lines" 1 $run.Lines.Count
        Assert-True "ERROR line" ($run.Lines[0].StartsWith("ERROR: ", [System.StringComparison]::Ordinal))
        Assert-Equal "runs" $before (Get-RunCount)
    }

    Test-Case "AC-307 every run, stage and trust value in every manifest and checkpoint of this suite is in the set the CLI writes" {
        $runStates = @("running", "succeeded", "failed", "needs_input")
        $stageStates = @("pending", "running", "succeeded", "failed", "skipped", "unsupported")
        $trusts = @("untrusted-draft", "deterministic-check")
        Assert-True "manifests seen ($($script:allManifests.Count))" ($script:allManifests.Count -ge 50)
        foreach ($text in $script:allManifests) {
            $m = $text | ConvertFrom-Json
            Assert-True "run status '$($m.status)'" ($runStates -ccontains [string]$m.status)
            foreach ($stage in @($m.stages)) { Assert-True "stage status '$($stage.status)'" ($stageStates -ccontains [string]$stage.status) }
            foreach ($artifact in @($m.artifacts)) { Assert-True "trust '$($artifact.trust)'" ($trusts -ccontains [string]$artifact.trust) }
        }
    }

    Test-Case "B4 in-process cases never reached the network (Invoke-RestMethod shadow)" {
        Assert-Equal "violations" 0 $script:restViolations
    }
}
finally {
    $env:Path = $originalPath
    foreach ($name in $testVariables) { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
    Restore-EngineSuite
}

Write-EngineSuiteSummary
if ($script:failed -eq 0) { exit 0 }
exit 1
