<#
.SYNOPSIS
    Offline suite for 'harness review', 'harness revise', 'harness status' and 'harness
    list' (Phase 3 work package B5): AC-334 and AC-315, with RN-12 (a FAIL review is exit
    1 review_failed; revise validates the output of the reviser).

.DESCRIPTION
    One temporary harness from the engine fake host (tests\lib\engine-fake-host.ps1, its
    four guards) with harness.ps1, validate-spec.ps1 and the manifest schema added. The
    CLI is run:
      - in process: Invoke-HarnessCli with mock stages (tests\mocks\scenario-*.ps1 of B2
        and tests\mocks\cli-*.ps1 of B4, which add telemetry records and manifest
        snapshots); Invoke-RestMethod is shadowed, so any request of an in-process case is a
        violation;
      - in a child process (powershell.exe -File): a driver that calls Invoke-HarnessCli
        with a mock reviewer that waits (the run is "running" while its process lives and
        "abandoned" after the test kills it), and harness.ps1 alone for status and list;
      - harness.ps1 with the real stage scripts inside the engine fake host (AC-334).
    No Ollama, no network. PATH is one empty folder (git is absent). Expected values are
    literals worked out from the spec, or hashes from Get-FileHash.
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
        (Join-Path $fixturesDirectory "invalid-spec.md"),
        (Join-Path $mocksDirectory "scenario-runner.ps1"),
        (Join-Path $mocksDirectory "scenario-validator.ps1"),
        (Join-Path $mocksDirectory "scenario-reviewer.ps1"),
        (Join-Path $mocksDirectory "scenario-reviser.ps1"),
        (Join-Path $mocksDirectory "cli-runner.ps1"),
        (Join-Path $mocksDirectory "cli-reviewer.ps1"),
        (Join-Path $mocksDirectory "cli-reviser.ps1"),
        (Join-Path $mocksDirectory "cli-reviewer-wait.ps1"),
        (Join-Path $mocksDirectory "cli-stage-extras.ps1"))) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required path not found: $path" }
}

$originalPath = $env:Path
$testVariables = @("AI_HARNESS_TEST_RECORD_FILE", "AI_HARNESS_TEST_SCENARIO", "AI_HARNESS_TEST_HARNESS_ROOT", "AI_HARNESS_TEST_TELEMETRY_FILE", "AI_HARNESS_TEST_SNAPSHOT_DIR", "AI_HARNESS_TEST_EVENT_FILE")

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
    $invalidSpecText = Read-Utf8 (Join-Path $fixturesDirectory "invalid-spec.md")

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
    $waitStages = @{
        runner    = $cliStages.runner
        validator = $cliStages.validator
        reviewer  = (Join-Path $mocksDirectory "cli-reviewer-wait.ps1")
        reviser   = $cliStages.reviser
    }

    $script:allManifests = New-Object 'System.Collections.Generic.List[string]'
    $script:caseIndex = 0

    # -----------------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------------

    # The files of a specification family, by file name, as the cases of review and revise
    # find them. Revision 1 and 2 files exist so that review -Revision 1 or 2 and revise
    # -Revision 1 or 2 have their inputs; a case removes the file its command writes.
    $familyTexts = [ordered]@{
        "demo.md"                    = $validSpecText
        "demo.review.md"             = "# Specification Review`r`n`r`n## Status`r`n`r`nFAIL`r`n`r`nOLD demo.review.md`r`n"
        "demo.revised-v1.md"         = $validSpecText + "`r`nOLD demo.revised-v1.md`r`n"
        "demo.revised-v1.review.md"  = "# Specification Review`r`n`r`n## Status`r`n`r`nFAIL`r`n`r`nOLD demo.revised-v1.review.md`r`n"
        "demo.revised-v2.md"         = $validSpecText + "`r`nOLD demo.revised-v2.md`r`n"
        "demo.revised-v2.review.md"  = "# Specification Review`r`n`r`n## Status`r`n`r`nFAIL`r`n`r`nOLD demo.revised-v2.review.md`r`n"
        "other.md"                   = "# Other specification`r`n"
    }

    # The file a command writes (FR-319), by literal rule.
    function Get-OutputName {
        param([string]$Command, [int]$Revision)
        if ($Command -ceq "revise") { return "demo.revised-v$Revision.md" }
        if ($Revision -eq 0) { return "demo.review.md" }
        return "demo.revised-v$Revision.review.md"
    }

    # A target with the family above; -Keep lists the output the case wants to exist.
    function New-Target {
        param([string[]]$Remove = @())
        $script:caseIndex++
        $path = Join-Path $tempRoot ("targets\t" + $script:caseIndex)
        $directory = Join-Path $path ".ai-harness\specs"
        [void][System.IO.Directory]::CreateDirectory($directory)
        foreach ($fileName in $familyTexts.Keys) {
            if ($Remove -contains $fileName) { continue }
            [System.IO.File]::WriteAllText((Join-Path $directory $fileName), $familyTexts[$fileName], $utf8NoBom)
        }
        return $path
    }

    function Get-SpecDirectory { param([string]$Target) return (Join-Path $Target ".ai-harness\specs") }

    function Get-Sha {
        param([string]$Path)
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    # file name -> SHA-256 of every file of a folder (recursive, relative names).
    function Get-Listing {
        param([string]$Directory)
        $result = [ordered]@{}
        if (-not (Test-Path -LiteralPath $Directory)) { return $result }
        foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Recurse -Force -File | Sort-Object FullName)) {
            $result[$file.FullName.Substring($Directory.Length).TrimStart('\').ToLowerInvariant()] = Get-Sha $file.FullName
        }
        return $result
    }

    function Format-Listing {
        param($Listing)
        $keys = [string[]]@($Listing.Keys)
        [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
        return (@($keys | ForEach-Object { "$_=$($Listing[$_])" }) -join ";")
    }

    function Get-RunCount {
        if (-not (Test-Path -LiteralPath $runsDirectory)) { return 0 }
        return @(Get-ChildItem -LiteralPath $runsDirectory -Directory -Force).Count
    }

    function Read-RecordLines {
        if (-not (Test-Path -LiteralPath $recordFile -PathType Leaf)) { return @() }
        return @([System.IO.File]::ReadAllLines($recordFile) | Where-Object { $_ -ne "" })
    }

    # The recorded arguments of a mock call: "<stage>|Key=value|..." -> hashtable.
    function ConvertFrom-RecordLine {
        param([string]$Line)
        $parts = $Line.Split('|')
        $table = @{ _stage = $parts[0] }
        for ($i = 1; $i -lt $parts.Count; $i++) {
            $index = $parts[$i].IndexOf('=')
            $table[$parts[$i].Substring(0, $index)] = $parts[$i].Substring($index + 1).Replace('\\', '\')
        }
        return $table
    }

    function Get-RecordsOf {
        param($Run, [string]$Stage)
        return @($Run.Record | Where-Object { $_.StartsWith("$Stage|", [System.StringComparison]::Ordinal) } | ForEach-Object { ConvertFrom-RecordLine $_ })
    }

    function Same-Path {
        param([string]$Expected, [string]$Actual)
        Assert-Equal "path" $Expected.ToLowerInvariant() $Actual.ToLowerInvariant()
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

    # review or revise in process. Returns { ExitCode, Lines, Record, Target, SpecDirectory,
    # Snapshots, ManifestPath, ManifestText, Manifest, RunId, Before }. Before is the listing
    # of the specification folder before the command. The output file of the command is
    # removed from the target unless -KeepOutput.
    function Invoke-Cmd {
        param(
            [Parameter(Mandatory = $true)][string]$Command,
            [hashtable]$Options = @{},
            [string]$Scenario = "",
            $Telemetry = $null,
            [switch]$Snapshots,
            $Stages = $null,
            [string]$Target = "",
            [switch]$KeepOutput
        )
        $revision = 0
        if ($Command -ceq "revise") { $revision = 1 }
        if ($Options.ContainsKey("Revision")) { $revision = [int]$Options["Revision"] }
        if ($Target -eq "") {
            $remove = @()
            if (-not $KeepOutput) { $remove = @(Get-OutputName $Command $revision) }
            $Target = New-Target -Remove $remove
        }
        if ($null -eq $Stages) { $Stages = $cliStages }
        $snapshotDir = ""
        if ($Snapshots) { $snapshotDir = Join-Path $tempRoot ("snapshots\s" + $script:caseIndex + "-" + [guid]::NewGuid().ToString("N").Substring(0, 6)) }
        Set-StageEnvironment -Scenario $Scenario -Telemetry $Telemetry -SnapshotDir $snapshotDir

        $merged = [ordered]@{ TargetPath = $Target; Name = "demo"; Task = $task }
        if ($Command -ceq "revise") { $merged["Revision"] = 1 }
        foreach ($key in $Options.Keys) {
            if ($null -eq $Options[$key]) { if ($merged.Contains($key)) { $merged.Remove($key) } }
            else { $merged[$key] = $Options[$key] }
        }
        $before = Get-Listing (Get-SpecDirectory $Target)
        $result = @{}
        $lines = @(Invoke-HarnessCli -Command $Command -Options $merged -StageScripts $Stages -Result $result 6>$null)
        $run = [pscustomobject]@{ ExitCode = $result.exitCode; Lines = @($lines | ForEach-Object { [string]$_ }); Record = @(Read-RecordLines); Target = $Target; SpecDirectory = (Get-SpecDirectory $Target); Snapshots = $snapshotDir; Before = $before }
        Add-ManifestFields $run
        if ($snapshotDir -ne "" -and (Test-Path -LiteralPath $snapshotDir)) {
            foreach ($file in @(Get-ChildItem -LiteralPath $snapshotDir -Filter "*.json" -File)) { $script:allManifests.Add([System.IO.File]::ReadAllText($file.FullName)) }
        }
        return $run
    }

    function Assert-ValidManifest {
        param($Run)
        if ($null -eq $Run.ManifestText) { throw "no manifest was printed or found" }
        $check = Test-HarnessManifest -Manifest $Run.ManifestText
        if (-not $check.valid) { throw "manifest invalid: $(@($check.errors) -join '; ')" }
    }

    # RUN_ID first, MANIFEST last (absolute, existing), and for a nonzero exit exactly one
    # ERROR line with the category, just before MANIFEST; the manifest holds the exit code.
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
        if ($ExitCode -eq 0) { Assert-Equal "ERROR lines" 0 @($lines | Where-Object { $_.StartsWith("ERROR: ", [System.StringComparison]::Ordinal) }).Count }
        else {
            Assert-Equal "ERROR <category> lines" 1 @($lines | Where-Object { $_.StartsWith("ERROR: $($Category): ", [System.StringComparison]::Ordinal) }).Count
            Assert-True "ERROR just before MANIFEST ($($lines[$lines.Count - 2]))" ($lines[$lines.Count - 2].StartsWith("ERROR: $($Category): ", [System.StringComparison]::Ordinal))
        }
        Assert-ValidManifest $Run
        Assert-Equal "manifest exitCode" $ExitCode $Run.Manifest.exitCode
        Assert-Equal "manifest runId" $lines[0].Substring(8) $Run.Manifest.runId
        if ($ExitCode -ne 0) { Assert-Equal "manifest error category" $Category $Run.Manifest.error.category }
    }

    # An argument error: exit 2, one ERROR: invalid_arguments line, no run created.
    function Assert-ArgumentError {
        param($Run, [int]$RunsBefore)
        Assert-Equal "exit" 2 $Run.ExitCode
        Assert-Equal "lines" 1 $Run.Lines.Count
        Assert-True "ERROR: invalid_arguments:" ($Run.Lines[0].StartsWith("ERROR: invalid_arguments:", [System.StringComparison]::Ordinal))
        Assert-Equal "runs" $RunsBefore (Get-RunCount)
        Assert-Equal "stage calls" 0 $Run.Record.Count
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

    # The files of the specification folder after the command equal those before, except
    # the ones named in -Added (new) and -Changed (rewritten).
    function Assert-OnlyThese {
        param($Run, [string[]]$Added = @(), [string[]]$Changed = @())
        $after = Get-Listing $Run.SpecDirectory
        $expected = [ordered]@{}
        foreach ($key in $Run.Before.Keys) { $expected[$key] = $Run.Before[$key] }
        foreach ($name in $Added) { $expected[$name.ToLowerInvariant()] = $after[$name.ToLowerInvariant()] }
        foreach ($name in $Changed) { $expected[$name.ToLowerInvariant()] = $after[$name.ToLowerInvariant()] }
        foreach ($name in $Added) { Assert-True "new file $name exists" ($after.Contains($name.ToLowerInvariant())); Assert-True "new file $name was absent" (-not $Run.Before.Contains($name.ToLowerInvariant())) }
        foreach ($name in $Changed) { Assert-True "file $name was rewritten" ($Run.Before[$name.ToLowerInvariant()] -cne $after[$name.ToLowerInvariant()]) }
        Assert-Equal "specification folder" (Format-Listing $expected) (Format-Listing $after)
    }

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

    # status and list in process. Returns { ExitCode, Lines }.
    function Invoke-Reader {
        param([string]$Command, [hashtable]$Options = @{})
        $result = @{}
        $lines = @(Invoke-HarnessCli -Command $Command -Options $Options -Result $result 6>$null)
        return [pscustomobject]@{ ExitCode = $result.exitCode; Lines = @($lines | ForEach-Object { [string]$_ }) }
    }

    # -----------------------------------------------------------------------
    # AC-334 review: the files, the manifest, the outcome table, RN-12
    # -----------------------------------------------------------------------

    Test-Case "AC-334 review -Revision 0 on an existing demo.md: PASS writes demo.review.md and exits 0; one stage spec-review attempt 1; request.revision 0; the reviewer got the files of FR-319" {
        $run = Invoke-Cmd "review" -Scenario "reviewer=pass"
        Assert-Protocol $run 0
        Assert-OnlyThese $run -Added @("demo.review.md")
        Assert-Equal "run status" "succeeded" $run.Manifest.status
        Assert-Equal "workflow" "review" $run.Manifest.workflow
        Assert-Equal "stages" "spec-review/1/succeeded" (Get-StageSummary $run.Manifest)
        $stage = Get-Stage $run.Manifest "spec-review"
        Assert-Equal "verdict" "PASS" $stage.verdict
        Assert-Equal "kind" "agent" $stage.kind
        Assert-Equal "agent" "spec-reviewer" $stage.agent
        Assert-Equal "exitCode of the stage" 0 $stage.exitCode
        Assert-Equal "request.revision" 0 $run.Manifest.request.revision
        Assert-Equal "request.name" "demo" $run.Manifest.request.name
        Assert-Equal "request.mode" "requirements" $run.Manifest.request.mode
        Assert-Equal "artifacts" 1 @($run.Manifest.artifacts).Count
        Assert-Equal "artifact role" "review" $run.Manifest.artifacts[0].role
        Assert-Equal "artifact path" ".ai-harness\specs\demo.review.md" $run.Manifest.artifacts[0].path
        Assert-Equal "artifact trust" "untrusted-draft" $run.Manifest.artifacts[0].trust
        Assert-ArtifactHashes $run
        Assert-Equal "stage output sha256" (Get-Sha (Join-Path $run.SpecDirectory "demo.review.md")) $stage.output.sha256
        $calls = @(Get-RecordsOf $run "reviewer")
        Assert-Equal "reviewer calls" 1 $calls.Count
        Assert-Equal "total calls" 1 $run.Record.Count
        Same-Path (Join-Path $run.SpecDirectory "demo.md") $calls[0].SpecFile
        Same-Path (Join-Path $run.SpecDirectory "demo.review.md") $calls[0].OutputFile
        Assert-Equal "Mode" "requirements" $calls[0].Mode
        Assert-Equal "Task" $task $calls[0].Task
        Assert-True "no Model, Profile or ContextFile" (-not $calls[0].ContainsKey("Model") -and -not $calls[0].ContainsKey("Profile") -and -not $calls[0].ContainsKey("ContextFile"))
    }

    Test-Case "AC-334 RN-12 review with a FAIL verdict: exit 1, ERROR: review_failed, run failed, one stage succeeded with verdict FAIL, the review file kept, no revision planned" {
        $run = Invoke-Cmd "review" -Scenario "reviewer=fail"
        Assert-Protocol $run 1 "review_failed"
        Assert-OnlyThese $run -Added @("demo.review.md")
        Assert-Equal "run status" "failed" $run.Manifest.status
        Assert-Equal "stages" "spec-review/1/succeeded" (Get-StageSummary $run.Manifest)
        Assert-Equal "verdict" "FAIL" (Get-Stage $run.Manifest "spec-review").verdict
        Assert-Equal "stage error" "" ([string](Get-Stage $run.Manifest "spec-review").error)
        Assert-Equal "reviewer calls" 1 @(Get-RecordsOf $run "reviewer").Count
        Assert-Equal "reviser calls" 0 @(Get-RecordsOf $run "reviser").Count
        Assert-Equal "validator calls" 0 @(Get-RecordsOf $run "validator").Count
        Assert-Equal "artifact role" "review" $run.Manifest.artifacts[0].role
        Assert-ArtifactHashes $run
    }

    Test-Case "AC-334 review -Revision 1 reads demo.revised-v1.md and writes only demo.revised-v1.review.md; the stage is the round 2" {
        $run = Invoke-Cmd "review" -Options @{ Revision = 1 } -Scenario "reviewer=pass"
        Assert-Protocol $run 0
        Assert-OnlyThese $run -Added @("demo.revised-v1.review.md")
        Assert-Equal "stages" "spec-review/2/succeeded" (Get-StageSummary $run.Manifest)
        Assert-Equal "request.revision" 1 $run.Manifest.request.revision
        $calls = @(Get-RecordsOf $run "reviewer")
        Same-Path (Join-Path $run.SpecDirectory "demo.revised-v1.md") $calls[0].SpecFile
        Same-Path (Join-Path $run.SpecDirectory "demo.revised-v1.review.md") $calls[0].OutputFile
        Assert-Equal "artifact path" ".ai-harness\specs\demo.revised-v1.review.md" $run.Manifest.artifacts[0].path
    }

    Test-Case "AC-334 review -Revision 2 reads demo.revised-v2.md and writes only demo.revised-v2.review.md; the stage is the round 3" {
        $run = Invoke-Cmd "review" -Options @{ Revision = 2 } -Scenario "reviewer=fail"
        Assert-Protocol $run 1 "review_failed"
        Assert-OnlyThese $run -Added @("demo.revised-v2.review.md")
        Assert-Equal "stages" "spec-review/3/succeeded" (Get-StageSummary $run.Manifest)
        Assert-Equal "request.revision" 2 $run.Manifest.request.revision
        $calls = @(Get-RecordsOf $run "reviewer")
        Same-Path (Join-Path $run.SpecDirectory "demo.revised-v2.md") $calls[0].SpecFile
    }

    $reviewRows = @(
        @{ Label = "reviewer exit 2"; Scenario = "reviewer=exit2"; StageExit = 2 },
        @{ Label = "reviewer exit 5"; Scenario = "reviewer=exit5"; StageExit = 5 },
        @{ Label = "reviewer exit 1 with no review file"; Scenario = "reviewer=exit1"; StageExit = 1 },
        @{ Label = "reviewer exit 0 with no review file"; Scenario = "reviewer=nooutput"; StageExit = 0 },
        @{ Label = "reviewer ends with no exit code"; Scenario = "reviewer=noexit"; StageExit = $null },
        @{ Label = "reviewer throws"; Scenario = "reviewer=throw"; StageExit = $null })
    foreach ($row in $reviewRows) {
        Test-Case "AC-334 outcome table: $($row.Label) -> exit 2 stage_failed, stage failed, no verdict" {
            $run = Invoke-Cmd "review" -Scenario $row.Scenario
            Assert-Protocol $run 2 "stage_failed"
            Assert-Equal "run status" "failed" $run.Manifest.status
            $stage = Get-Stage $run.Manifest "spec-review"
            Assert-Equal "stage status" "failed" $stage.status
            Assert-Equal "stage error category" "stage_failed" $stage.error.category
            Assert-Equal "verdict" "" ([string]$stage.verdict)
            Assert-Equal "stage exit code" ([string]$row.StageExit) ([string]$stage.exitCode)
            Assert-Equal "reviewer calls" 1 @(Get-RecordsOf $run "reviewer").Count
        }
    }

    Test-Case "AC-334 FR-307 reviewer exit 2 with a telemetry record of a 500: exit 2 http_error, engineCategory http_5xx, httpStatus 500, retryable" {
        $plan = @{ reviewer1 = @(@{ callId = "call-r1"; attempts = 2; status = "error"; errorCategory = "http_5xx"; httpStatus = 500; error = "internal server error" }) }
        $run = Invoke-Cmd "review" -Scenario "reviewer=exit2" -Telemetry $plan
        Assert-Protocol $run 2 "http_error"
        $stage = Get-Stage $run.Manifest "spec-review"
        Assert-Equal "callId" "call-r1" $stage.callId
        Assert-Equal "engineAttempts" 2 $stage.engineAttempts
        Assert-Equal "engineCategory" "http_5xx" $stage.error.engineCategory
        Assert-Equal "httpStatus" 500 $stage.error.httpStatus
        Assert-Equal "retryable" "True" $stage.error.retryable
        Assert-Equal "run error engineCategory" "http_5xx" $run.Manifest.error.engineCategory
    }

    Test-Case "AC-334 FR-307 a PASS review: callId, engineAttempts and resolution come from the one telemetry record whose run_id is the runId" {
        $plan = @{ reviewer1 = @(@{ callId = "call-r2"; attempts = 1; profile = "alpha"; modelSource = "agent"; model = "test-model-alpha"; timeoutSec = 222; contextWindow = 8192; estPromptTokens = 100 }) }
        $run = Invoke-Cmd "review" -Scenario "reviewer=pass" -Telemetry $plan
        Assert-Protocol $run 0
        $stage = Get-Stage $run.Manifest "spec-review"
        Assert-Equal "callId" "call-r2" $stage.callId
        Assert-Equal "model" "test-model-alpha" $stage.resolution.model
        Assert-Equal "contextWindow" 8192 $stage.budget.contextWindow
        $records = @(Read-TelemetryRecords $run.Manifest.runId)
        Assert-Equal "records with the run id" 1 $records.Count
        Assert-Equal "record call_id" "call-r2" $records[0].call_id
    }

    Test-Case "AC-334 -Model, -Profile and -Mode reach the reviewer and are recorded in request.overrides and request.mode" {
        $run = Invoke-Cmd "review" -Options @{ Model = "unlisted:1"; Mode = "baseline" } -Scenario "reviewer=pass"
        Assert-Protocol $run 0
        $call = @(Get-RecordsOf $run "reviewer")[0]
        Assert-Equal "Model" "unlisted:1" $call.Model
        Assert-Equal "Mode" "baseline" $call.Mode
        Assert-True "no Profile" (-not $call.ContainsKey("Profile"))
        Assert-Equal "overrides.model" "unlisted:1" $run.Manifest.request.overrides.model
        Assert-Equal "request.mode" "baseline" $run.Manifest.request.mode
        $other = Invoke-Cmd "review" -Options @{ Profile = "beta" } -Scenario "reviewer=pass"
        Assert-Protocol $other 0
        $otherCall = @(Get-RecordsOf $other "reviewer")[0]
        Assert-Equal "Profile" "beta" $otherCall.Profile
        Assert-True "no Model" (-not $otherCall.ContainsKey("Model"))
        Assert-Equal "overrides.profile" "beta" $other.Manifest.request.overrides.profile
    }

    Test-Case "AC-334 -TaskFile: inputs\task.md holds the task, request.taskFile is the absolute path, the task text is in no other file of the run" {
        $taskFile = Join-Path $tempRoot "review-task.txt"
        $marker = "B5-TASK-MARKER-" + [guid]::NewGuid().ToString("N")
        [System.IO.File]::WriteAllText($taskFile, "A task from a file. $marker", $utf8NoBom)
        $run = Invoke-Cmd "review" -Options @{ Task = $null; TaskFile = $taskFile } -Scenario "reviewer=pass"
        Assert-Protocol $run 0
        $runPath = Join-Path $runsDirectory $run.Manifest.runId
        Assert-Equal "task.md" "A task from a file. $marker" ([System.IO.File]::ReadAllText((Join-Path $runPath "inputs\task.md")))
        Assert-Equal "taskSha256" (Get-Sha (Join-Path $runPath "inputs\task.md")) $run.Manifest.request.taskSha256
        Same-Path $taskFile $run.Manifest.request.taskFile
        foreach ($file in @(Get-ChildItem -LiteralPath $runPath -Recurse -Force -File)) {
            if ($file.FullName -ceq (Join-Path $runPath "inputs\task.md")) { continue }
            Assert-True "no marker in $($file.Name)" (-not [System.IO.File]::ReadAllText($file.FullName).Contains($marker))
        }
        Assert-Equal "reviewer saw the task" "A task from a file. $marker" (@(Get-RecordsOf $run "reviewer")[0].Task)
    }

    Test-Case "AC-334 the stage sees AI_HARNESS_RUN_ID equal to the runId and the caller's value is restored after the run" {
        $env:AI_HARNESS_RUN_ID = "caller-value-b5"
        try {
            $run = Invoke-Cmd "review" -Scenario "reviewer=pass" -Snapshots
            Assert-Protocol $run 0
            Assert-Equal "id the stage saw" $run.Manifest.runId ([System.IO.File]::ReadAllText((Join-Path $run.Snapshots "reviewer1.runid")))
            Assert-Equal "restored" "caller-value-b5" $env:AI_HARNESS_RUN_ID
            $failed = Invoke-Cmd "review" -Scenario "reviewer=exit2"
            Assert-Equal "restored after a failure" "caller-value-b5" $env:AI_HARNESS_RUN_ID
        }
        finally { $env:AI_HARNESS_RUN_ID = $null }
    }

    Test-Case "AC-334 FR-308 checkpoints: the manifest the stage sees while it runs is valid, running, with the stage running; no .tmp file is left" {
        $run = Invoke-Cmd "review" -Scenario "reviewer=pass" -Snapshots
        Assert-Protocol $run 0
        $snapshot = [System.IO.File]::ReadAllText((Join-Path $run.Snapshots "reviewer1.json")) | ConvertFrom-Json
        $check = Test-HarnessManifest -Manifest ([System.IO.File]::ReadAllText((Join-Path $run.Snapshots "reviewer1.json")))
        Assert-True "snapshot valid ($(@($check.errors) -join '; '))" $check.valid
        Assert-Equal "snapshot run status" "running" $snapshot.status
        Assert-Equal "snapshot stage status" "running" $snapshot.stages[0].status
        Assert-Equal "snapshot exitCode" "" ([string]$snapshot.exitCode)
        $runPath = Join-Path $runsDirectory $run.Manifest.runId
        Assert-Equal "leftover temp files" 0 @(Get-ChildItem -LiteralPath $runPath -Recurse -Force -File | Where-Object { $_.Name -like "*.tmp" }).Count
    }

    Test-Case "AC-334 a given -RunId is the run id; the run directory holds .claim, manifest.json and inputs\task.md" {
        $run = Invoke-Cmd "review" -Options @{ RunId = "b5-given-id" } -Scenario "reviewer=pass"
        Assert-Protocol $run 0
        Assert-Equal "runId" "b5-given-id" $run.Manifest.runId
        $runPath = Join-Path $runsDirectory "b5-given-id"
        Assert-True ".claim" (Test-Path -LiteralPath (Join-Path $runPath ".claim"))
        Assert-True "inputs\task.md" (Test-Path -LiteralPath (Join-Path $runPath "inputs\task.md"))
    }

    # -----------------------------------------------------------------------
    # AC-334 review: artifact_exists, -Overwrite, argument errors, checks before the stage
    # -----------------------------------------------------------------------

    Test-Case "AC-334 review: an existing demo.review.md is artifact_exists (exit 2, manifest written, stage skipped), bytes kept, no stage call" {
        $run = Invoke-Cmd "review" -Scenario "reviewer=pass" -KeepOutput
        Assert-Protocol $run 2 "artifact_exists"
        Assert-OnlyThese $run
        Assert-Equal "run status" "failed" $run.Manifest.status
        Assert-Equal "stage status" "skipped" (Get-Stage $run.Manifest "spec-review").status
        Assert-Equal "stage reason" "not reached: artifact_exists" (Get-Stage $run.Manifest "spec-review").reason
        Assert-Equal "stage calls" 0 $run.Record.Count
        Assert-Equal "artifacts" 0 @($run.Manifest.artifacts).Count
    }

    Test-Case "AC-334 review -Revision 1: an existing demo.revised-v1.review.md is artifact_exists; demo.review.md existing is not in the way" {
        $run = Invoke-Cmd "review" -Options @{ Revision = 1 } -Scenario "reviewer=pass" -KeepOutput
        Assert-Protocol $run 2 "artifact_exists"
        Assert-OnlyThese $run
        $other = Invoke-Cmd "review" -Options @{ Revision = 1 } -Scenario "reviewer=pass"
        Assert-Protocol $other 0
    }

    Test-Case "AC-334 review -Overwrite moves that file alone to runs\<id>\replaced\ (same bytes, role replaced) and writes the new review" {
        $target = New-Target
        $old = Get-Sha (Join-Path (Get-SpecDirectory $target) "demo.review.md")
        $oldText = [System.IO.File]::ReadAllText((Join-Path (Get-SpecDirectory $target) "demo.review.md"))
        $run = Invoke-Cmd "review" -Options @{ Overwrite = $true } -Scenario "reviewer=pass" -Target $target
        Assert-Protocol $run 0
        $runPath = Join-Path $runsDirectory $run.Manifest.runId
        Assert-Equal "replaced bytes" $old (Get-Sha (Join-Path $runPath "replaced\demo.review.md"))
        Assert-Equal "replaced files" 1 @(Get-ChildItem -LiteralPath (Join-Path $runPath "replaced") -File).Count
        $replaced = @($run.Manifest.artifacts | Where-Object { $_.role -ceq "replaced" })
        Assert-Equal "replaced artifacts" 1 $replaced.Count
        Assert-Equal "replaced path" "replaced\demo.review.md" $replaced[0].path
        Assert-Equal "replaced root" "run" $replaced[0].root
        Assert-Equal "replaced sha256" $old $replaced[0].sha256
        Assert-True "the new review is not the old one" (-not ([System.IO.File]::ReadAllText((Join-Path (Get-SpecDirectory $target) "demo.review.md")) -ceq $oldText))
        foreach ($name in @("demo.md", "demo.revised-v1.md", "demo.revised-v1.review.md", "demo.revised-v2.md", "other.md")) {
            Assert-Equal "$name unchanged" (Get-Sha (Join-Path (Get-SpecDirectory $target) $name)) $run.Before[$name.ToLowerInvariant()]
        }
        $review = @($run.Manifest.artifacts | Where-Object { $_.role -ceq "review" })
        Assert-Equal "review artifact" 1 $review.Count
        Assert-ArtifactHashes $run
    }

    Test-Case "AC-334 review: a missing demo.md is invalid_arguments before any run exists" {
        $target = New-Target -Remove @("demo.md", "demo.review.md")
        $before = Get-RunCount
        $run = Invoke-Cmd "review" -Scenario "reviewer=pass" -Target $target
        Assert-ArgumentError $run $before
    }

    Test-Case "AC-334 review -Revision 1: a missing demo.revised-v1.md is invalid_arguments before any run exists" {
        $target = New-Target -Remove @("demo.revised-v1.md", "demo.revised-v1.review.md")
        $before = Get-RunCount
        $run = Invoke-Cmd "review" -Options @{ Revision = 1 } -Scenario "reviewer=pass" -Target $target
        Assert-ArgumentError $run $before
    }

    Test-Case "AC-334 review: .ai-harness as a junction is invalid_arguments, no run" {
        $real = New-Target -Remove @("demo.review.md")
        $target = Join-Path $tempRoot ("targets\junction" + $script:caseIndex)
        [void][System.IO.Directory]::CreateDirectory($target)
        [void](New-Item -ItemType Junction -Path (Join-Path $target ".ai-harness") -Target (Join-Path $real ".ai-harness"))
        $before = Get-RunCount
        $run = Invoke-Cmd "review" -Scenario "reviewer=pass" -Target $target
        Assert-ArgumentError $run $before
        Assert-True "the junction target is untouched" (-not (Test-Path -LiteralPath (Join-Path $real ".ai-harness\specs\demo.review.md")))
        [System.IO.Directory]::Delete((Join-Path $target ".ai-harness"))
    }

    Test-Case "AC-334 review: an invalid registry is registry_invalid before the stage (skipped, not reached), an unknown -Profile too" {
        $badConfig = "{ ""schemaVersion"": 3, ""ollama"": { ""url"": ""$fakeUrl"" } }"
        [System.IO.File]::WriteAllText($harnessConfig, $badConfig, $utf8NoBom)
        try {
            $run = Invoke-Cmd "review" -Scenario "reviewer=pass"
            Assert-Protocol $run 2 "registry_invalid"
            Assert-Equal "stage reason" "not reached: registry_invalid" (Get-Stage $run.Manifest "spec-review").reason
            Assert-Equal "stage calls" 0 $run.Record.Count
        }
        finally { [System.IO.File]::WriteAllText($harnessConfig, $baseConfig, $utf8NoBom) }
        $unknown = Invoke-Cmd "review" -Options @{ Profile = "no-such-profile" } -Scenario "reviewer=pass"
        Assert-Protocol $unknown 2 "registry_invalid"
        Assert-Equal "stage calls" 0 $unknown.Record.Count
    }

    Test-Case "AC-334 review: a missing agent file is agent_not_found before the stage; revise checks spec-reviser, not spec-reviewer" {
        $agents = Join-Path $harnessRoot ".ai\agents"
        $reviewerFile = Join-Path $agents "spec-reviewer.md"
        $keep = Join-Path $tempRoot "spec-reviewer.md.keep"
        Move-Item -LiteralPath $reviewerFile -Destination $keep
        try {
            $run = Invoke-Cmd "review" -Scenario "reviewer=pass"
            Assert-Protocol $run 2 "agent_not_found"
            Assert-Equal "stage reason" "not reached: agent_not_found" (Get-Stage $run.Manifest "spec-review").reason
            Assert-Equal "stage calls" 0 $run.Record.Count
            $revise = Invoke-Cmd "revise" -Scenario "reviser=ok"
            Assert-Protocol $revise 0
        }
        finally { Move-Item -LiteralPath $keep -Destination $reviewerFile }
    }

    # -----------------------------------------------------------------------
    # AC-334 revise: the files, revised-validate, the outcome table, RN-12
    # -----------------------------------------------------------------------

    Test-Case "AC-334 revise -Revision 1 reads demo.md and demo.review.md, writes demo.revised-v1.md, validates it and exits 0; stages spec-revise and revised-validate attempt 1" {
        $run = Invoke-Cmd "revise" -Scenario "reviser=ok;validator=ok"
        Assert-Protocol $run 0
        Assert-OnlyThese $run -Added @("demo.revised-v1.md")
        Assert-Equal "run status" "succeeded" $run.Manifest.status
        Assert-Equal "workflow" "revise" $run.Manifest.workflow
        Assert-Equal "stages" "spec-revise/1/succeeded revised-validate/1/succeeded" (Get-StageSummary $run.Manifest)
        Assert-Equal "request.revision" 1 $run.Manifest.request.revision
        $reviser = @(Get-RecordsOf $run "reviser")
        Assert-Equal "reviser calls" 1 $reviser.Count
        Same-Path (Join-Path $run.SpecDirectory "demo.md") $reviser[0].SpecFile
        Same-Path (Join-Path $run.SpecDirectory "demo.review.md") $reviser[0].ReviewFile
        Same-Path (Join-Path $run.SpecDirectory "demo.revised-v1.md") $reviser[0].OutputFile
        Assert-Equal "Mode" "requirements" $reviser[0].Mode
        Assert-Equal "Task" $task $reviser[0].Task
        $validator = @(Get-RecordsOf $run "validator")
        Assert-Equal "validator calls" 1 $validator.Count
        Same-Path (Join-Path $run.SpecDirectory "demo.revised-v1.md") $validator[0].SpecFile
        Assert-Equal "validator Mode" "requirements" $validator[0].Mode
        Assert-Equal "total calls" 2 $run.Record.Count
        $validate = Get-Stage $run.Manifest "revised-validate"
        Assert-Equal "validate kind" "deterministic" $validate.kind
        Assert-Equal "validate exit" 0 $validate.exitCode
        Assert-Equal "artifacts" 1 @($run.Manifest.artifacts).Count
        Assert-Equal "artifact role" "revised-spec" $run.Manifest.artifacts[0].role
        Assert-Equal "artifact path" ".ai-harness\specs\demo.revised-v1.md" $run.Manifest.artifacts[0].path
        Assert-ArtifactHashes $run
    }

    Test-Case "AC-334 revise -Revision 2 reads demo.revised-v1.md and demo.revised-v1.review.md, writes only demo.revised-v2.md; both stages are attempt 2" {
        $run = Invoke-Cmd "revise" -Options @{ Revision = 2 } -Scenario "reviser=ok;validator=ok"
        Assert-Protocol $run 0
        Assert-OnlyThese $run -Added @("demo.revised-v2.md")
        Assert-Equal "stages" "spec-revise/2/succeeded revised-validate/2/succeeded" (Get-StageSummary $run.Manifest)
        Assert-Equal "request.revision" 2 $run.Manifest.request.revision
        $reviser = @(Get-RecordsOf $run "reviser")
        Same-Path (Join-Path $run.SpecDirectory "demo.revised-v1.md") $reviser[0].SpecFile
        Same-Path (Join-Path $run.SpecDirectory "demo.revised-v1.review.md") $reviser[0].ReviewFile
        Same-Path (Join-Path $run.SpecDirectory "demo.revised-v2.md") $reviser[0].OutputFile
    }

    Test-Case "AC-334 RN-12 revise validates its output: validator exit 1 -> exit 1 validation_failed, revised-validate failed, spec-revise succeeded, the revised file kept" {
        $run = Invoke-Cmd "revise" -Scenario "reviser=ok;validator=exit1"
        Assert-Protocol $run 1 "validation_failed"
        Assert-OnlyThese $run -Added @("demo.revised-v1.md")
        Assert-Equal "run status" "failed" $run.Manifest.status
        Assert-Equal "stages" "spec-revise/1/succeeded revised-validate/1/failed" (Get-StageSummary $run.Manifest)
        Assert-Equal "validate error" "validation_failed" (Get-Stage $run.Manifest "revised-validate").error.category
        Assert-Equal "validate exit" 1 (Get-Stage $run.Manifest "revised-validate").exitCode
        Assert-Equal "validator calls" 1 @(Get-RecordsOf $run "validator").Count
        Assert-ArtifactHashes $run
    }

    Test-Case "AC-334 RN-12 revise: validator exit 3 is also validation_failed (exit 1)" {
        $run = Invoke-Cmd "revise" -Scenario "reviser=ok;validator=exit3"
        Assert-Protocol $run 1 "validation_failed"
        Assert-Equal "validate exit" 3 (Get-Stage $run.Manifest "revised-validate").exitCode
    }

    foreach ($row in @(
            @{ Label = "validator exit 2"; Scenario = "reviser=ok;validator=exit2" },
            @{ Label = "validator exit 5"; Scenario = "reviser=ok;validator=exit5" },
            @{ Label = "validator throws"; Scenario = "reviser=ok;validator=throw" })) {
        Test-Case "AC-334 outcome table: revise with $($row.Label) -> exit 2 stage_failed on revised-validate" {
            $run = Invoke-Cmd "revise" -Scenario $row.Scenario
            Assert-Protocol $run 2 "stage_failed"
            Assert-Equal "stages" "spec-revise/1/succeeded revised-validate/1/failed" (Get-StageSummary $run.Manifest)
            Assert-Equal "validate error" "stage_failed" (Get-Stage $run.Manifest "revised-validate").error.category
        }
    }

    foreach ($row in @(
            @{ Label = "reviser exit 2"; Scenario = "reviser=exit2" },
            @{ Label = "reviser exit 5"; Scenario = "reviser=exit5" },
            @{ Label = "reviser exit 0 with no output file"; Scenario = "reviser=nooutput" },
            @{ Label = "reviser exit 0 with an empty output file"; Scenario = "reviser=empty" },
            @{ Label = "reviser throws"; Scenario = "reviser=throw" })) {
        Test-Case "AC-334 outcome table: revise with $($row.Label) -> exit 2 stage_failed on spec-revise, revised-validate skipped, the validator not called" {
            $run = Invoke-Cmd "revise" -Scenario $row.Scenario
            Assert-Protocol $run 2 "stage_failed"
            Assert-Equal "stages" "spec-revise/1/failed revised-validate/1/skipped" (Get-StageSummary $run.Manifest)
            Assert-Equal "skip reason" "dependency failed: spec-revise" (Get-Stage $run.Manifest "revised-validate").reason
            Assert-Equal "validator calls" 0 @(Get-RecordsOf $run "validator").Count
        }
    }

    Test-Case "AC-334 FR-307 reviser throwing after a 500 record: exit 2 http_error with engineCategory http_5xx on spec-revise, not internal_error" {
        $plan = @{ reviser1 = @(@{ callId = "call-v1"; attempts = 2; status = "error"; errorCategory = "http_5xx"; httpStatus = 500; error = "internal server error" }) }
        $run = Invoke-Cmd "revise" -Scenario "reviser=throw" -Telemetry $plan
        Assert-Protocol $run 2 "http_error"
        $stage = Get-Stage $run.Manifest "spec-revise"
        Assert-Equal "engineCategory" "http_5xx" $stage.error.engineCategory
        Assert-Equal "callId" "call-v1" $stage.callId
    }

    Test-Case "AC-334 revise: an existing demo.revised-v1.md is artifact_exists (stages skipped, bytes kept); the review file demo.revised-v1.review.md is not an output" {
        $run = Invoke-Cmd "revise" -Scenario "reviser=ok" -KeepOutput
        Assert-Protocol $run 2 "artifact_exists"
        Assert-OnlyThese $run
        Assert-Equal "stages" "spec-revise/1/skipped revised-validate/1/skipped" (Get-StageSummary $run.Manifest)
        Assert-Equal "stage calls" 0 $run.Record.Count
    }

    Test-Case "AC-334 revise -Overwrite moves demo.revised-v1.md alone to runs\<id>\replaced\ (same bytes); demo.revised-v1.review.md and the others stay" {
        $target = New-Target
        $old = Get-Sha (Join-Path (Get-SpecDirectory $target) "demo.revised-v1.md")
        $run = Invoke-Cmd "revise" -Options @{ Overwrite = $true } -Scenario "reviser=ok;validator=ok" -Target $target
        Assert-Protocol $run 0
        $runPath = Join-Path $runsDirectory $run.Manifest.runId
        Assert-Equal "replaced bytes" $old (Get-Sha (Join-Path $runPath "replaced\demo.revised-v1.md"))
        Assert-Equal "replaced files" 1 @(Get-ChildItem -LiteralPath (Join-Path $runPath "replaced") -File).Count
        Assert-Equal "replaced artifacts" 1 @($run.Manifest.artifacts | Where-Object { $_.role -ceq "replaced" }).Count
        Assert-Equal "revised-spec artifacts" 1 @($run.Manifest.artifacts | Where-Object { $_.role -ceq "revised-spec" }).Count
        foreach ($name in @("demo.md", "demo.review.md", "demo.revised-v1.review.md", "demo.revised-v2.md", "demo.revised-v2.review.md", "other.md")) {
            Assert-Equal "$name unchanged" (Get-Sha (Join-Path (Get-SpecDirectory $target) $name)) $run.Before[$name.ToLowerInvariant()]
        }
        Assert-True "the new revision is not the old one" ((Get-Sha (Join-Path (Get-SpecDirectory $target) "demo.revised-v1.md")) -cne $old)
        Assert-ArtifactHashes $run
    }

    Test-Case "AC-334 revise: a missing demo.review.md (or missing demo.revised-v1.review.md for -Revision 2) is invalid_arguments before any run" {
        $target = New-Target -Remove @("demo.review.md", "demo.revised-v1.md")
        $before = Get-RunCount
        $run = Invoke-Cmd "revise" -Scenario "reviser=ok" -Target $target
        Assert-ArgumentError $run $before
        $second = New-Target -Remove @("demo.revised-v1.review.md", "demo.revised-v2.md")
        $run2 = Invoke-Cmd "revise" -Options @{ Revision = 2 } -Scenario "reviser=ok" -Target $second
        Assert-ArgumentError $run2 $before
    }

    Test-Case "AC-334 revise: -Revision is required and at least 1 (argument errors before any run)" {
        $before = Get-RunCount
        $target = New-Target
        $missing = Invoke-Cmd "revise" -Options @{ Revision = $null } -Scenario "reviser=ok" -Target $target
        Assert-ArgumentError $missing $before
        $zero = Invoke-Cmd "revise" -Options @{ Revision = 0 } -Scenario "reviser=ok" -Target $target
        Assert-ArgumentError $zero $before
    }

    Test-Case "AC-334 revise: -Model and -Profile reach the reviser, never the validator; the validator gets -Mode" {
        $run = Invoke-Cmd "revise" -Options @{ Model = "unlisted:2"; Mode = "baseline" } -Scenario "reviser=ok;validator=ok"
        Assert-Protocol $run 0
        $reviser = @(Get-RecordsOf $run "reviser")[0]
        Assert-Equal "reviser Model" "unlisted:2" $reviser.Model
        Assert-Equal "reviser Mode" "baseline" $reviser.Mode
        $validator = @(Get-RecordsOf $run "validator")[0]
        Assert-True "validator has no Model" (-not $validator.ContainsKey("Model"))
        Assert-Equal "validator Mode" "baseline" $validator.Mode
        Assert-Equal "overrides.model" "unlisted:2" $run.Manifest.request.overrides.model
    }

    # -----------------------------------------------------------------------
    # AC-334 on the fake host with the real scripts
    # -----------------------------------------------------------------------

    $tagsOk = New-Step "ok" @{ models = @("test-model-alpha") }

    function Invoke-RealCase {
        param([string]$Name, [string[]]$Arguments, [object[]]$GenerateSteps, [string]$Target)
        $case = Invoke-Case -Name $Name -ConfigText $baseConfig -Script "harness.ps1" -ArgumentList $Arguments `
            -TagsSteps @($tagsOk, $tagsOk) -GenerateSteps $GenerateSteps -TypedExceptions
        Assert-Guards $case
        Assert-True "only fake routes" (@($case.Calls | Where-Object { -not ([string]$_.uri).StartsWith("http://127.0.0.1:9/", [System.StringComparison]::Ordinal) }).Count -eq 0)
        $run = [pscustomobject]@{ ExitCode = $case.ExitCode; Lines = @($case.Lines | Where-Object { -not $_.StartsWith("FAKE-HOST:", [System.StringComparison]::Ordinal) }); Target = $Target; SpecDirectory = (Get-SpecDirectory $Target); Case = $case }
        Add-ManifestFields $run
        return $run
    }

    Test-Case "AC-334 real scripts: review -Revision 0 with a PASS answer exits 0 and writes demo.review.md; the telemetry run_id and call_id equal the manifest" {
        $target = New-Target -Remove @("demo.review.md")
        $run = Invoke-RealCase "b5-review-pass" @("review", "-TargetPath", $target, "-Name", "demo", "-Task", $task) @((& $okReply $reviewPass)) $target
        Assert-Protocol $run 0
        Assert-Equal "review file" $reviewPass (Read-Utf8 (Join-Path $run.SpecDirectory "demo.review.md"))
        Assert-Equal "stages" "spec-review/1/succeeded" (Get-StageSummary $run.Manifest)
        $records = @($run.Case.Telemetry)
        Assert-Equal "telemetry records" 1 $records.Count
        Assert-Equal "telemetry run_id" $run.Manifest.runId $records[0].run_id
        Assert-Equal "callId" $records[0].call_id (Get-Stage $run.Manifest "spec-review").callId
        Assert-Equal "agent" "spec-reviewer" $records[0].agent
        Assert-ArtifactHashes $run
    }

    Test-Case "AC-334 RN-12 real scripts: review with a FAIL answer exits 1 review_failed; the review file is written" {
        $target = New-Target -Remove @("demo.review.md")
        $run = Invoke-RealCase "b5-review-fail" @("review", "-TargetPath", $target, "-Name", "demo", "-Task", $task) @((& $okReply $reviewFail)) $target
        Assert-Protocol $run 1 "review_failed"
        Assert-Equal "review file" $reviewFail (Read-Utf8 (Join-Path $run.SpecDirectory "demo.review.md"))
        Assert-Equal "verdict" "FAIL" (Get-Stage $run.Manifest "spec-review").verdict
        Assert-Equal "run status" "failed" $run.Manifest.status
    }

    Test-Case "AC-334 real scripts: review -Revision 1 reads demo.revised-v1.md and writes demo.revised-v1.review.md (attempt 2)" {
        $target = New-Target -Remove @("demo.revised-v1.review.md")
        $run = Invoke-RealCase "b5-review-rev1" @("review", "-TargetPath", $target, "-Name", "demo", "-Revision", "1", "-Task", $task) @((& $okReply $reviewPass)) $target
        Assert-Protocol $run 0
        Assert-Equal "stages" "spec-review/2/succeeded" (Get-StageSummary $run.Manifest)
        Assert-Equal "review file" $reviewPass (Read-Utf8 (Join-Path $run.SpecDirectory "demo.revised-v1.review.md"))
        Assert-Equal "request.revision" 1 $run.Manifest.request.revision
    }

    Test-Case "AC-334 real scripts: revise -Revision 1 with a valid answer writes demo.revised-v1.md, validate-spec.ps1 passes it, exit 0" {
        $target = New-Target -Remove @("demo.revised-v1.md")
        $run = Invoke-RealCase "b5-revise-ok" @("revise", "-TargetPath", $target, "-Name", "demo", "-Revision", "1", "-Task", $task) @((& $okReply $validSpecText)) $target
        Assert-Protocol $run 0
        Assert-Equal "stages" "spec-revise/1/succeeded revised-validate/1/succeeded" (Get-StageSummary $run.Manifest)
        Assert-Equal "revised file" $validSpecText (Read-Utf8 (Join-Path $run.SpecDirectory "demo.revised-v1.md"))
        $records = @($run.Case.Telemetry)
        Assert-Equal "telemetry records" 1 $records.Count
        Assert-Equal "agent" "spec-reviser" $records[0].agent
        Assert-Equal "callId" $records[0].call_id (Get-Stage $run.Manifest "spec-revise").callId
        Assert-ArtifactHashes $run
    }

    Test-Case "AC-334 RN-12 real scripts: revise with an answer that fails validate-spec.ps1 exits 1 validation_failed; the revised file is kept" {
        $target = New-Target -Remove @("demo.revised-v1.md")
        $run = Invoke-RealCase "b5-revise-invalid" @("revise", "-TargetPath", $target, "-Name", "demo", "-Revision", "1", "-Task", $task) @((& $okReply $invalidSpecText)) $target
        Assert-Protocol $run 1 "validation_failed"
        Assert-Equal "stages" "spec-revise/1/succeeded revised-validate/1/failed" (Get-StageSummary $run.Manifest)
        Assert-Equal "revised file kept" $invalidSpecText (Read-Utf8 (Join-Path $run.SpecDirectory "demo.revised-v1.md"))
    }

    Test-Case "AC-334 real scripts: revise -Revision 2 reads revision 1 and its review, refuses an existing demo.revised-v2.md (artifact_exists), then -Overwrite moves it" {
        $target = New-Target
        $refused = Invoke-RealCase "b5-revise-exists" @("revise", "-TargetPath", $target, "-Name", "demo", "-Revision", "2", "-Task", $task) @() $target
        Assert-Protocol $refused 2 "artifact_exists"
        Assert-Equal "no request" 0 @($refused.Case.Calls).Count
        $old = Get-Sha (Join-Path (Get-SpecDirectory $target) "demo.revised-v2.md")
        $run = Invoke-RealCase "b5-revise-overwrite" @("revise", "-TargetPath", $target, "-Name", "demo", "-Revision", "2", "-Overwrite", "-Task", $task) @((& $okReply $validSpecText)) $target
        Assert-Protocol $run 0
        Assert-Equal "replaced bytes" $old (Get-Sha (Join-Path (Join-Path $runsDirectory $run.Manifest.runId) "replaced\demo.revised-v2.md"))
        Assert-Equal "new file" $validSpecText (Read-Utf8 (Join-Path (Get-SpecDirectory $target) "demo.revised-v2.md"))
        Assert-Equal "stages" "spec-revise/2/succeeded revised-validate/2/succeeded" (Get-StageSummary $run.Manifest)
    }

    # -----------------------------------------------------------------------
    # AC-315: status, list, derived status
    # -----------------------------------------------------------------------

    function New-ManifestRun {
        param([string]$RunId, [string]$Text, [int]$DelayMs = 0)
        $directory = Join-Path $runsDirectory $RunId
        [void][System.IO.Directory]::CreateDirectory($directory)
        [System.IO.File]::WriteAllText((Join-Path $directory "manifest.json"), $Text, $utf8NoBom)
        if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    }

    # A finished review run through the CLI, with a given run id.
    function New-FinishedRun {
        param([string]$RunId, [string]$Scenario = "reviewer=pass")
        $run = Invoke-Cmd "review" -Options @{ RunId = $RunId } -Scenario $Scenario
        return $run
    }

    # The manifest text of a finished run with edited fields.
    function Get-EditedManifestText {
        param($Run, [string]$RunId, [string]$Status, $ProcessId, [string]$StartUtc, [string]$CreatedAtUtc = "")
        $copy = $Run.ManifestText | ConvertFrom-Json
        $copy.runId = $RunId
        $copy.status = $Status
        $copy.process.pid = [int]$ProcessId
        $copy.process.processStartUtc = $StartUtc
        if ($CreatedAtUtc -ne "") { $copy.createdAtUtc = $CreatedAtUtc }
        return (ConvertTo-Json -InputObject $copy -Depth 10)
    }

    Test-Case "AC-315 status of a finished run shows the recorded status (recordedStatus equals status), exit code, stages, warnings, error and the manifest path (-Json: one parsable line)" {
        $run = New-FinishedRun "b5-fin-ok"
        $json = Invoke-Reader "status" @{ RunId = "b5-fin-ok"; Json = $true }
        Assert-Equal "exit" 0 $json.ExitCode
        Assert-Equal "lines" 1 $json.Lines.Count
        $doc = $json.Lines[0] | ConvertFrom-Json
        Assert-Equal "runId" "b5-fin-ok" $doc.runId
        Assert-Equal "workflow" "review" $doc.workflow
        Assert-Equal "recordedStatus" "succeeded" $doc.recordedStatus
        Assert-Equal "status" "succeeded" $doc.status
        Assert-Equal "exitCode" 0 $doc.exitCode
        Assert-Equal "stages" 1 @($doc.stages).Count
        Assert-Equal "stage id" "spec-review" $doc.stages[0].id
        Assert-Equal "stage status" "succeeded" $doc.stages[0].status
        Assert-Equal "warnings (no telemetry record in the mock run)" "telemetry_record_missing" (@($doc.warnings) -join ",")
        Assert-Equal "error" "" ([string]$doc.error)
        Same-Path $run.ManifestPath $doc.manifestPath
        $failed = New-FinishedRun "b5-fin-fail" "reviewer=fail"
        $failedDoc = (Invoke-Reader "status" @{ RunId = "b5-fin-fail"; Json = $true }).Lines[0] | ConvertFrom-Json
        Assert-Equal "failed status" "failed" $failedDoc.status
        Assert-Equal "failed exitCode" 1 $failedDoc.exitCode
        Assert-Equal "failed error category" "review_failed" $failedDoc.error.category
    }

    Test-Case "AC-315 status in text form prints runId, workflow, recordedStatus, status, exitCode, each stage, the error and the manifest path" {
        $run = New-FinishedRun "b5-text" "reviewer=fail"
        $text = Invoke-Reader "status" @{ RunId = "b5-text" }
        Assert-Equal "exit" 0 $text.ExitCode
        Assert-True "runId" ($text.Lines -ccontains "runId: b5-text")
        Assert-True "workflow" ($text.Lines -ccontains "workflow: review")
        Assert-True "recordedStatus" ($text.Lines -ccontains "recordedStatus: failed")
        Assert-True "status" ($text.Lines -ccontains "status: failed")
        Assert-True "exitCode" ($text.Lines -ccontains "exitCode: 1")
        Assert-True "stage" ($text.Lines -ccontains "stage: spec-review (attempt 1): succeeded")
        Assert-True "error" (@($text.Lines | Where-Object { $_.StartsWith("error: review_failed: ", [System.StringComparison]::Ordinal) }).Count -eq 1)
        Assert-Equal "manifest line" ("manifest: " + $run.ManifestPath).ToLowerInvariant() (@($text.Lines | Where-Object { $_.StartsWith("manifest: ", [System.StringComparison]::Ordinal) })[0]).ToLowerInvariant()
    }

    Test-Case "AC-315 a running run (the stage waits on an event file) is running while its process lives and abandoned after the test kills it; recordedStatus stays running" {
        $target = New-Target -Remove @("demo.review.md")
        $eventFile = Join-Path $tempRoot "wait-event.txt"
        if (Test-Path -LiteralPath $eventFile) { Remove-Item -LiteralPath $eventFile -Force }
        $env:AI_HARNESS_TEST_EVENT_FILE = $eventFile
        Set-StageEnvironment -Scenario ""
        $optionsFile = Join-Path $tempRoot "wait-options.json"
        $stagesFile = Join-Path $tempRoot "wait-stages.json"
        $stdoutFile = Join-Path $tempRoot "wait-stdout.txt"
        $stderrFile = Join-Path $tempRoot "wait-stderr.txt"
        [System.IO.File]::WriteAllText($optionsFile, (ConvertTo-Json -InputObject ([ordered]@{ TargetPath = $target; Name = "demo"; Task = $task; RunId = "b5-waiting" })), $utf8NoBom)
        [System.IO.File]::WriteAllText($stagesFile, (ConvertTo-Json -InputObject $waitStages), $utf8NoBom)
        $driver = Join-Path $tempRoot "wait-driver.ps1"
        [System.IO.File]::WriteAllText($driver, @'
param([string]$HarnessRoot, [string]$OptionsFile, [string]$StagesFile)
$ErrorActionPreference = "Stop"
. (Join-Path $HarnessRoot "scripts\lib\cli.ps1")
$options = [ordered]@{}
foreach ($p in ([System.IO.File]::ReadAllText($OptionsFile) | ConvertFrom-Json).PSObject.Properties) { $options[$p.Name] = [string]$p.Value }
$stages = @{}
foreach ($p in ([System.IO.File]::ReadAllText($StagesFile) | ConvertFrom-Json).PSObject.Properties) { $stages[$p.Name] = [string]$p.Value }
$result = @{ exitCode = 2 }
Invoke-HarnessCli -Command "review" -Options $options -StageScripts $stages -Result $result
exit ([int]$result.exitCode)
'@, $utf8NoBom)
        $argumentText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $driver + '" -HarnessRoot "' + $harnessRoot + '" -OptionsFile "' + $optionsFile + '" -StagesFile "' + $stagesFile + '"'
        $process = Start-Process -FilePath $powerShellExe -ArgumentList $argumentText -NoNewWindow -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $null = $process.Handle
        try {
            $deadline = [datetime]::UtcNow.AddSeconds(90)
            while (-not (Test-Path -LiteralPath $eventFile) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
            Assert-True "the stage reached its handshake" (Test-Path -LiteralPath $eventFile)

            $alive = (Invoke-Reader "status" @{ RunId = "b5-waiting"; Json = $true }).Lines[0] | ConvertFrom-Json
            Assert-Equal "recordedStatus while alive" "running" $alive.recordedStatus
            Assert-Equal "status while alive" "running" $alive.status
            Assert-Equal "stage while alive" "running" $alive.stages[0].status
            $manifest = Read-HarnessManifest -Path (Join-Path $runsDirectory "b5-waiting\manifest.json")
            Assert-Equal "pid of the manifest" $process.Id $manifest.process.pid
            $listed = @(((Invoke-Reader "list" @{ Json = $true }).Lines[0] | ConvertFrom-Json).runs | Where-Object { $_.runId -ceq "b5-waiting" })
            Assert-Equal "list shows running" "running" $listed[0].status

            $process.Kill()
            $process.WaitForExit()
        }
        finally {
            if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            Remove-Item Env:\AI_HARNESS_TEST_EVENT_FILE -ErrorAction SilentlyContinue
        }
        $dead = (Invoke-Reader "status" @{ RunId = "b5-waiting"; Json = $true }).Lines[0] | ConvertFrom-Json
        Assert-Equal "recordedStatus after the kill" "running" $dead.recordedStatus
        Assert-Equal "status after the kill" "abandoned" $dead.status
        $text = Invoke-Reader "status" @{ RunId = "b5-waiting" }
        Assert-True "text: abandoned" ($text.Lines -ccontains "status: abandoned")
        Assert-True "text: recordedStatus" ($text.Lines -ccontains "recordedStatus: running")
        $listedAfter = @(((Invoke-Reader "list" @{ Json = $true }).Lines[0] | ConvertFrom-Json).runs | Where-Object { $_.runId -ceq "b5-waiting" })
        Assert-Equal "list shows abandoned" "abandoned" $listedAfter[0].status
    }

    Test-Case "AC-315 a manifest edited to this process's pid with a processStartUtc over 2 s off, or to a pid that does not exist, is abandoned; the exact own start time is running" {
        $run = New-FinishedRun "b5-edit-base"
        $self = [System.Diagnostics.Process]::GetCurrentProcess()
        $ownStart = $self.StartTime.ToUniversalTime()
        $self.Dispose()
        $unusedPid = 0
        foreach ($candidate in 4000000, 3999990, 3999980) {
            if (-not (Get-HarnessProcessInfo -ProcessId $candidate).Exists) { $unusedPid = $candidate; break }
        }
        Assert-True "a pid that does not exist" ($unusedPid -gt 0)
        New-ManifestRun "b5-edit-late" (Get-EditedManifestText $run "b5-edit-late" "running" $PID (Get-HarnessUtcTimestamp -At $ownStart.AddSeconds(10)))
        New-ManifestRun "b5-edit-early" (Get-EditedManifestText $run "b5-edit-early" "running" $PID (Get-HarnessUtcTimestamp -At $ownStart.AddSeconds(-10)))
        New-ManifestRun "b5-edit-nopid" (Get-EditedManifestText $run "b5-edit-nopid" "running" $unusedPid (Get-HarnessUtcTimestamp -At $ownStart))
        New-ManifestRun "b5-edit-exact" (Get-EditedManifestText $run "b5-edit-exact" "running" $PID (Get-HarnessUtcTimestamp -At $ownStart))
        New-ManifestRun "b5-edit-close" (Get-EditedManifestText $run "b5-edit-close" "running" $PID (Get-HarnessUtcTimestamp -At $ownStart.AddSeconds(1)))
        $expected = [ordered]@{ "b5-edit-late" = "abandoned"; "b5-edit-early" = "abandoned"; "b5-edit-nopid" = "abandoned"; "b5-edit-exact" = "running"; "b5-edit-close" = "running" }
        foreach ($id in $expected.Keys) {
            $doc = (Invoke-Reader "status" @{ RunId = $id; Json = $true }).Lines[0] | ConvertFrom-Json
            Assert-Equal "$id recordedStatus" "running" $doc.recordedStatus
            Assert-Equal "$id status" $expected[$id] $doc.status
        }
        $finished = (Invoke-Reader "status" @{ RunId = "b5-edit-base"; Json = $true }).Lines[0] | ConvertFrom-Json
        Assert-Equal "a finished run shows its recorded status" "succeeded" $finished.status
    }

    Test-Case "AC-315 list -Last 2 returns the two newest runs in order (newest first); -Last above the count returns all; list without -Last returns every run" {
        $run = New-FinishedRun "b5-seed"
        $base = [datetime]::UtcNow.AddHours(1)
        $order = @("b5-list-a", "b5-list-b", "b5-list-c", "b5-list-d")
        for ($i = 0; $i -lt $order.Count; $i++) {
            New-ManifestRun $order[$i] (Get-EditedManifestText $run $order[$i] "succeeded" $PID (Get-HarnessUtcTimestamp) (Get-HarnessUtcTimestamp -At $base.AddMinutes($i)))
        }
        $two = (Invoke-Reader "list" @{ Last = 2; Json = $true }).Lines
        Assert-Equal "one line" 1 $two.Count
        $doc = $two[0] | ConvertFrom-Json
        Assert-Equal "runs" "b5-list-d,b5-list-c" (@($doc.runs | ForEach-Object { $_.runId }) -join ",")
        Assert-Equal "status" "succeeded" $doc.runs[0].status
        Assert-Equal "workflow" "review" $doc.runs[0].workflow
        $all = ((Invoke-Reader "list" @{ Json = $true }).Lines[0] | ConvertFrom-Json).runs
        Assert-Equal "newest four" "b5-list-d,b5-list-c,b5-list-b,b5-list-a" (@($all | Select-Object -First 4 | ForEach-Object { $_.runId }) -join ",")
        Assert-Equal "all runs" (Get-RunCount) @($all).Count
        $many = ((Invoke-Reader "list" @{ Last = 500; Json = $true }).Lines[0] | ConvertFrom-Json).runs
        Assert-Equal "-Last above the count" (Get-RunCount) @($many).Count
        $text = Invoke-Reader "list" @{ Last = 2 }
        Assert-Equal "text lines" 2 $text.Lines.Count
        Assert-True "first text line is the newest" ($text.Lines[0].StartsWith("b5-list-d ", [System.StringComparison]::Ordinal))
        Assert-True "text carries status and workflow" ($text.Lines[0].Contains("succeeded") -and $text.Lines[0].Contains("review"))
    }

    Test-Case "AC-315 a corrupt manifest (not JSON, or JSON that is not a manifest, or no manifest.json) is listed unreadable and status exits 2 manifest_invalid" {
        New-ManifestRun "b5-corrupt-text" "this is { not json"
        New-ManifestRun "b5-corrupt-shape" "{ ""schemaVersion"": 1 }"
        [void][System.IO.Directory]::CreateDirectory((Join-Path $runsDirectory "b5-corrupt-empty"))
        $runs = ((Invoke-Reader "list" @{ Json = $true }).Lines[0] | ConvertFrom-Json).runs
        foreach ($id in @("b5-corrupt-text", "b5-corrupt-shape", "b5-corrupt-empty")) {
            $entry = @($runs | Where-Object { $_.runId -ceq $id })
            Assert-Equal "$id listed once" 1 $entry.Count
            Assert-Equal "$id status" "unreadable" $entry[0].status
            $status = Invoke-Reader "status" @{ RunId = $id }
            Assert-Equal "$id status exit" 2 $status.ExitCode
            Assert-Equal "$id lines" 1 $status.Lines.Count
            Assert-True "$id ERROR: manifest_invalid ($($status.Lines[0]))" ($status.Lines[0].StartsWith("ERROR: manifest_invalid: ", [System.StringComparison]::Ordinal))
            $jsonStatus = Invoke-Reader "status" @{ RunId = $id; Json = $true }
            Assert-Equal "$id -Json exit" 2 $jsonStatus.ExitCode
            Assert-Equal "$id -Json lines" 1 $jsonStatus.Lines.Count
            Assert-True "$id -Json prints ERROR, not JSON" ($jsonStatus.Lines[0].StartsWith("ERROR: manifest_invalid: ", [System.StringComparison]::Ordinal))
        }
        $text = Invoke-Reader "list"
        Assert-True "text list shows unreadable" (@($text.Lines | Where-Object { $_.StartsWith("b5-corrupt-text ", [System.StringComparison]::Ordinal) -and $_.Contains("unreadable") }).Count -eq 1)
        Assert-Equal "list exit" 0 $text.ExitCode
    }

    Test-Case "AC-315 status of an unknown run is invalid_arguments (exit 2, one ERROR line, also with -Json)" {
        foreach ($json in @($false, $true)) {
            $options = @{ RunId = "b5-no-such-run" }
            if ($json) { $options.Json = $true }
            $run = Invoke-Reader "status" $options
            Assert-Equal "exit" 2 $run.ExitCode
            Assert-Equal "lines" 1 $run.Lines.Count
            Assert-True "ERROR: invalid_arguments ($($run.Lines[0]))" ($run.Lines[0].StartsWith("ERROR: invalid_arguments: ", [System.StringComparison]::Ordinal))
        }
        Assert-True "the unknown run was not created" (-not (Test-Path -LiteralPath (Join-Path $runsDirectory "b5-no-such-run")))
    }

    Test-Case "AC-315 status and list write nothing: the SHA-256 listing of runs\ is the same before and after both commands, in both forms" {
        $before = Get-Listing $runsDirectory
        $directoriesBefore = (@(Get-ChildItem -LiteralPath $runsDirectory -Directory -Force | ForEach-Object { $_.Name } | Sort-Object) -join ",")
        Assert-True "there are runs" ($before.Count -gt 10)
        $null = Invoke-Reader "status" @{ RunId = "b5-fin-ok" }
        $null = Invoke-Reader "status" @{ RunId = "b5-fin-ok"; Json = $true }
        $null = Invoke-Reader "status" @{ RunId = "b5-waiting"; Json = $true }
        $null = Invoke-Reader "status" @{ RunId = "b5-corrupt-text" }
        $null = Invoke-Reader "status" @{ RunId = "b5-no-such-run" }
        $null = Invoke-Reader "list"
        $null = Invoke-Reader "list" @{ Last = 3; Json = $true }
        $null = Invoke-Harness @("status", "-RunId", "b5-fin-ok")
        $null = Invoke-Harness @("list", "-Last", "2")
        Assert-Equal "runs\ listing" (Format-Listing $before) (Format-Listing (Get-Listing $runsDirectory))
        Assert-Equal "run directories" $directoriesBefore (@(Get-ChildItem -LiteralPath $runsDirectory -Directory -Force | ForEach-Object { $_.Name } | Sort-Object) -join ",")
    }

    Test-Case "AC-315 harness.ps1 as a child process: status -Json and list -Json print one parsable line each, status of an unknown run exits 2" {
        $status = Invoke-Harness @("status", "-RunId", "b5-fin-ok", "-Json")
        Assert-Equal "status exit" 0 $status.ExitCode
        Assert-Equal "status lines" 1 $status.Lines.Count
        Assert-Equal "status runId" "b5-fin-ok" ($status.Lines[0] | ConvertFrom-Json).runId
        $list = Invoke-Harness @("list", "-Last", "1", "-Json")
        Assert-Equal "list exit" 0 $list.ExitCode
        Assert-Equal "list lines" 1 $list.Lines.Count
        Assert-Equal "list runs" 1 @(($list.Lines[0] | ConvertFrom-Json).runs).Count
        $unknown = Invoke-Harness @("status", "-RunId", "b5-no-such-run", "-Json")
        Assert-Equal "unknown exit" 2 $unknown.ExitCode
        Assert-Equal "unknown lines" 1 $unknown.Lines.Count
        Assert-True "unknown ERROR" ($unknown.Lines[0].StartsWith("ERROR: invalid_arguments: ", [System.StringComparison]::Ordinal))
    }

    Test-Case "AC-315 list on a harness without runs\ exits 0 with an empty list (text: no line; -Json: runs is an empty array)" {
        $moved = Join-Path $tempRoot "runs-moved"
        Move-Item -LiteralPath $runsDirectory -Destination $moved
        try {
            $text = Invoke-Reader "list"
            Assert-Equal "text exit" 0 $text.ExitCode
            Assert-Equal "text lines" 0 $text.Lines.Count
            $json = Invoke-Reader "list" @{ Json = $true }
            Assert-Equal "json exit" 0 $json.ExitCode
            Assert-Equal "json" '{"runs":[]}' $json.Lines[0]
        }
        finally { Move-Item -LiteralPath $moved -Destination $runsDirectory }
    }

    # -----------------------------------------------------------------------
    # Value sets and the in-process guard
    # -----------------------------------------------------------------------

    Test-Case "AC-307 every run, stage and trust value in every manifest and checkpoint of this suite is in the set the CLI writes" {
        $runStates = @("running", "succeeded", "failed", "needs_input")
        $stageStates = @("pending", "running", "succeeded", "failed", "skipped", "unsupported")
        $trusts = @("untrusted-draft", "deterministic-check")
        Assert-True "manifests seen ($($script:allManifests.Count))" ($script:allManifests.Count -ge 40)
        foreach ($text in $script:allManifests) {
            $m = $text | ConvertFrom-Json
            Assert-True "run status '$($m.status)'" ($runStates -ccontains [string]$m.status)
            foreach ($stage in @($m.stages)) { Assert-True "stage status '$($stage.status)'" ($stageStates -ccontains [string]$stage.status) }
            foreach ($artifact in @($m.artifacts)) { Assert-True "trust '$($artifact.trust)'" ($trusts -ccontains [string]$artifact.trust) }
        }
    }

    Test-Case "B5 in-process cases never reached the network (Invoke-RestMethod shadow)" {
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
