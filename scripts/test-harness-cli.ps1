<#
.SYNOPSIS
    Offline suite for the Phase 3 CLI (work package B3): scripts\harness.ps1 and
    scripts\lib\cli.ps1. AC-301 (dispatch and argument validation), AC-312 (unsupported
    stages), AC-314 (config, stages, -Json) and AC-333 (doctor and the load check, CLI half).

.DESCRIPTION
    Two parts, one fake host (tests\lib\engine-fake-host.ps1, FR-315, with the /api/version
    route added in B3):
      - in-process: the parser, the value rules and the dispatch of Invoke-HarnessCli with
        recording handlers and mock stages; the cmdlet Invoke-RestMethod is shadowed so that
        any request of an in-process case is a violation;
      - child-process: harness.ps1 as powershell.exe -File, alone (argument errors, stubs)
        or inside the engine fake host (doctor, config, unsupported stages).
    No Ollama, no network. The suite empties PATH (one folder of its own) so that git,
    nvidia-smi and ollama are absent unless a case puts a fake .cmd there: no case depends
    on the machine having them. Expected values are literals worked out from the spec.
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

foreach ($path in @(
        (Join-Path $scriptsDirectory "harness.ps1"),
        (Join-Path $scriptsDirectory "lib\cli.ps1"),
        (Join-Path $scriptsDirectory "validate-spec.ps1"),
        (Join-Path $scriptsDirectory "lib\run-manifest.schema.json"),
        (Join-Path $root "tests\fixtures\config-v2-current.json"),
        (Join-Path $root "tests\fixtures\minimal-valid-spec.md"),
        (Join-Path $root "tests\fixtures\invalid-spec.md"),
        (Join-Path $root "tests\fixtures\documentation-none-spec.md"))) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required path not found: $path" }
}

$originalPath = $env:Path
$originalLocation = (Get-Location).Path
$originalProcessDirectory = [System.Environment]::CurrentDirectory

try {
    Initialize-EngineSuite

    # The temporary harness gets the CLI and what it calls.
    Copy-Item -LiteralPath (Join-Path $scriptsDirectory "harness.ps1") -Destination (Join-Path $harnessRoot "scripts\harness.ps1")
    Copy-Item -LiteralPath (Join-Path $scriptsDirectory "validate-spec.ps1") -Destination (Join-Path $harnessRoot "scripts\validate-spec.ps1")
    Copy-Item -LiteralPath (Join-Path $scriptsDirectory "lib\run-manifest.schema.json") -Destination (Join-Path $harnessRoot "scripts\lib\run-manifest.schema.json")
    $harnessScript = Join-Path $harnessRoot "scripts\harness.ps1"

    # PATH: one empty folder (git, nvidia-smi and ollama are absent).
    $binDirectory = Join-Path $tempRoot "bin"
    [void][System.IO.Directory]::CreateDirectory($binDirectory)
    $env:Path = $binDirectory

    . (Join-Path $harnessRoot "scripts\lib\cli.ps1")

    # -----------------------------------------------------------------------
    # Fixtures: targets, spec files, a task file
    # -----------------------------------------------------------------------

    $targetDir = Join-Path $tempRoot "target"
    $emptyTarget = Join-Path $tempRoot "target-empty"
    $fileTarget = Join-Path $tempRoot "a-file.txt"
    $junctionDir = Join-Path $tempRoot "junction"
    $taskFilePath = Join-Path $tempRoot "task.txt"
    $specFixtures = Join-Path $tempRoot "spec-fixtures"
    foreach ($directory in @($targetDir, $emptyTarget, $specFixtures, (Join-Path $targetDir ".ai-harness\specs"))) { [void][System.IO.Directory]::CreateDirectory($directory) }
    [System.IO.File]::WriteAllText($fileTarget, "x", $utf8NoBom)
    [System.IO.File]::WriteAllText($taskFilePath, "A task from a file.", $utf8NoBom)
    foreach ($name in @("feature.md", "feature.review.md", "feature.revised-v1.md")) {
        [System.IO.File]::WriteAllText((Join-Path $targetDir ".ai-harness\specs\$name"), "# Specification", $utf8NoBom)
    }
    foreach ($name in @("minimal-valid-spec.md", "invalid-spec.md", "documentation-none-spec.md")) {
        Copy-Item -LiteralPath (Join-Path $root "tests\fixtures\$name") -Destination (Join-Path $specFixtures $name)
    }
    $emptySpec = Join-Path $specFixtures "empty-spec.md"
    [System.IO.File]::WriteAllText($emptySpec, "", $utf8NoBom)
    [void](New-Item -ItemType Junction -Path $junctionDir -Target $targetDir)

    $configFixtureText = Read-Utf8 (Join-Path $root "tests\fixtures\config-v2-current.json")
    # AC-107 forbids model-name literals under scripts\: the two model names of the fixture
    # are read from the fixture file itself (the input of the cases, not the code under
    # test); every other expected value in the tables below is a literal.
    $fixtureProfiles = ($configFixtureText | ConvertFrom-Json).profiles
    $fastModel = [string]$fixtureProfiles.fast.model
    $deepModel = [string]$fixtureProfiles.deep.model

    # -----------------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------------

    function Set-TempConfig {
        param([string]$Text)
        [System.IO.File]::WriteAllText($harnessConfig, $Text, $utf8NoBom)
    }

    function Clear-Runs {
        $runs = Join-Path $harnessRoot "runs"
        if (Test-Path -LiteralPath $runs) { Remove-Item -LiteralPath $runs -Recurse -Force }
    }

    function Assert-NoRuns {
        $runs = Join-Path $harnessRoot "runs"
        if (Test-Path -LiteralPath $runs) {
            $entries = @(Get-ChildItem -LiteralPath $runs -Force)
            if ($entries.Count -gt 0) { throw "runs\ is not empty: $($entries.Name -join ', ')" }
        }
    }

    # harness.ps1 as a child process, alone (no fake host). Returns { ExitCode, Lines }.
    function Invoke-Harness {
        param([string[]]$Arguments = @())

        $ErrorActionPreference = "Continue"
        try {
            $raw = @(& $powerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harnessScript @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = "Stop" }
        $lines = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ ExitCode = $exitCode; Lines = $lines }
    }

    # harness.ps1 inside the engine fake host. Returns the run of Invoke-Case.
    function Invoke-HarnessCase {
        param([string]$Name, [string]$ConfigText, [string[]]$Arguments, [object[]]$TagsSteps = @(), [object[]]$VersionSteps = @(), [object[]]$GenerateSteps = @(), [switch]$RepeatLastGenerate)

        Clear-Runs
        $splat = @{ Name = $Name; ConfigText = $ConfigText; Script = "harness.ps1"; ArgumentList = $Arguments; TagsSteps = $TagsSteps; VersionSteps = $VersionSteps; GenerateSteps = $GenerateSteps; TypedExceptions = $true }
        if ($RepeatLastGenerate) { $splat.RepeatLastGenerate = $true }
        return (Invoke-Case @splat)
    }

    # The lines the harness printed, without the fake host banner.
    function Get-HarnessOutput {
        param($Run)
        return @($Run.Lines | Where-Object { -not $_.StartsWith("FAKE-HOST:", [System.StringComparison]::Ordinal) })
    }

    function Get-JsonOutput {
        param($Run)
        $lines = @(Get-HarnessOutput $Run)
        if ($lines.Count -ne 1) { throw "expected exactly one output line, got $($lines.Count): $($lines -join ' | ')" }
        return ($lines[0] | ConvertFrom-Json)
    }

    function Get-RouteUris {
        param($Run)
        return @($Run.Calls | ForEach-Object { $_.uri } | Sort-Object -Unique)
    }

    # A recording handler: replaces every handler of the dispatch table for a case.
    $script:handlerCalls = @()
    function Invoke-TestRecorder {
        param($Command, $Options, $Context)
        $script:handlerCalls += [pscustomobject]@{ Command = $Command; Options = $Options; Context = $Context }
        $Context.ExitCode = 0
    }
    $realHandlers = @{}
    foreach ($key in $script:HarnessCliHandlers.Keys) { $realHandlers[$key] = $script:HarnessCliHandlers[$key] }
    function Use-RecordingHandlers {
        $script:handlerCalls = @()
        foreach ($key in @($realHandlers.Keys)) { $script:HarnessCliHandlers[$key] = "Invoke-TestRecorder" }
    }
    function Use-RealHandlers {
        foreach ($key in @($realHandlers.Keys)) { $script:HarnessCliHandlers[$key] = $realHandlers[$key] }
    }

    function Invoke-InProcess {
        param([string[]]$Arguments)

        $parsed = ConvertFrom-HarnessCliArguments -Arguments $Arguments
        if (-not $parsed.ok) { return [pscustomobject]@{ Parsed = $parsed; ExitCode = 2; Lines = @("ERROR: invalid_arguments: " + $parsed.message) } }
        $result = @{}
        $lines = @(Invoke-HarnessCli -Command $parsed.command -Options $parsed.options -Result $result)
        return [pscustomobject]@{ Parsed = $parsed; ExitCode = $result.exitCode; Lines = $lines }
    }

    # -----------------------------------------------------------------------
    # AC-301: the literal table, the AST of harness.ps1
    # -----------------------------------------------------------------------

    # A literal copy of the FR-302 table: command, required, one of, optional.
    $literalTable = [ordered]@{
        "specify"      = @{ Required = @("TargetPath", "Name"); OneOf = @("Task", "TaskFile"); Optional = @("Mode", "Include", "Model", "Profile", "RunId", "Overwrite", "LoadCheck") }
        "review"       = @{ Required = @("TargetPath", "Name"); OneOf = @("Task", "TaskFile"); Optional = @("Revision", "Mode", "Model", "Profile", "RunId", "Overwrite") }
        "revise"       = @{ Required = @("TargetPath", "Name", "Revision"); OneOf = @("Task", "TaskFile"); Optional = @("Mode", "Model", "Profile", "RunId", "Overwrite") }
        "scan"         = @{ Required = @("TargetPath"); OneOf = @(); Optional = @("RunId") }
        "context"      = @{ Required = @("TargetPath", "Include"); OneOf = @(); Optional = @("RunId") }
        "validate"     = @{ Required = @("SpecFile"); OneOf = @(); Optional = @("Mode") }
        "status"       = @{ Required = @("RunId"); OneOf = @(); Optional = @("Json") }
        "list"         = @{ Required = @(); OneOf = @(); Optional = @("Last", "Json") }
        "stages"       = @{ Required = @(); OneOf = @(); Optional = @("Json") }
        "config"       = @{ Required = @(); OneOf = @(); Optional = @("Agent", "Model", "Profile", "Json") }
        "doctor"       = @{ Required = @(); OneOf = @(); Optional = @("Json", "LoadCheck") }
        "architecture" = @{ Required = @(); OneOf = @(); Optional = @("TargetPath", "RunId") }
        "plan"         = @{ Required = @(); OneOf = @(); Optional = @("TargetPath", "RunId") }
        "qa"           = @{ Required = @(); OneOf = @(); Optional = @("TargetPath", "RunId") }
        "code-review"  = @{ Required = @(); OneOf = @(); Optional = @("TargetPath", "RunId") }
        "develop"      = @{ Required = @(); OneOf = @(); Optional = @("TargetPath", "RunId") }
    }
    $switchNames = @("Json", "Overwrite", "LoadCheck")
    $samples = @{
        TargetPath = $targetDir; Name = "feature"; Task = "Do the thing."; TaskFile = $taskFilePath; Mode = "baseline"; Include = "a.md,b.md"
        Model = "some-model:1"; Profile = "fast"; RunId = "run-1"; Revision = "1"; SpecFile = (Join-Path $specFixtures "minimal-valid-spec.md"); Last = "5"; Agent = "spec"
    }

    # The argument list of a command with the named options (a switch has no value).
    function New-ArgumentList {
        param([string]$Command, [string[]]$Names)
        $list = @($Command)
        foreach ($name in $Names) {
            $list += "-$name"
            if ($switchNames -cnotcontains $name) { $list += [string]$samples[$name] }
        }
        return $list
    }

    function Get-RequiredNames {
        param($Rule)
        return @($Rule.Required) + @($Rule.OneOf[0..0] | Where-Object { $_ })
    }

    Test-Case "AC-301 harness.ps1 has no param block, [CmdletBinding()], [Parameter()] or validation attribute (AST)" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($harnessScript, [ref]$tokens, [ref]$errors)
        Assert-Equal "parse errors" 0 @($errors).Count
        Assert-True "no param block" ($null -eq $ast.ParamBlock)
        $attributes = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AttributeAst] }, $true))
        Assert-Equal "attributes in harness.ps1" 0 $attributes.Count
        $parameters = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true))
        Assert-Equal "parameters in harness.ps1" 0 $parameters.Count
    }

    Test-Case "AC-301 the table in lib\cli.ps1 equals the literal FR-302 table (commands, required, one of, optional)" {
        Assert-Equal "command count" $literalTable.Count $script:HarnessCliCommands.Count
        foreach ($command in $literalTable.Keys) {
            Assert-True "command $command is in the table" ($script:HarnessCliCommands.Contains($command))
            $expected = $literalTable[$command]
            $actual = $script:HarnessCliCommands[$command]
            Assert-Equal "$command required" (@($expected.Required) -join ",") (@($actual.Required) -join ",")
            Assert-Equal "$command one of" (@($expected.OneOf) -join ",") (@($actual.OneOf) -join ",")
            Assert-Equal "$command optional" (@($expected.Optional) -join ",") (@($actual.Optional) -join ",")
        }
    }

    foreach ($command in $literalTable.Keys) {
        $rule = $literalTable[$command]
        $variants = @(, (Get-RequiredNames $rule))
        if ($rule.OneOf.Count -gt 0) { $variants += , (@($rule.Required) + @($rule.OneOf[1])) }
        $variantIndex = 0
        foreach ($required in $variants) {
            $variantIndex++
            Test-Case "AC-301 '$command' with its required options ($($required -join ' ')) reaches its handler" {
                Use-RecordingHandlers
                try {
                    $run = Invoke-InProcess -Arguments (New-ArgumentList $command $required)
                    Assert-Equal "parsed ok" "True" $run.Parsed.ok
                    Assert-Equal "exit code" 0 $run.ExitCode
                    Assert-Equal "handler calls" 1 @($script:handlerCalls).Count
                    Assert-Equal "handler command" $command $script:handlerCalls[0].Command
                    Assert-Equal "output lines" 0 $run.Lines.Count
                }
                finally { Use-RealHandlers }
            }
        }
        foreach ($optional in $rule.Optional) {
            Test-Case "AC-301 '$command' accepts the optional -$optional" {
                Use-RecordingHandlers
                try {
                    $run = Invoke-InProcess -Arguments (New-ArgumentList $command (@(Get-RequiredNames $rule) + @($optional)))
                    Assert-Equal "exit code" 0 $run.ExitCode
                    Assert-Equal "handler calls" 1 @($script:handlerCalls).Count
                    $options = $script:handlerCalls[0].Options
                    Assert-True "the option arrived" $options.Contains($optional)
                    if ($switchNames -ccontains $optional) { Assert-Equal "switch value" "True" $options[$optional] }
                    elseif ($optional -ceq "Revision") { Assert-Equal "revision" 1 $options[$optional] }
                    elseif ($optional -ceq "Last") { Assert-Equal "last" 5 $options[$optional] }
                    elseif ($optional -cin @("TargetPath", "TaskFile", "SpecFile")) { Assert-Equal "$optional is absolute" $samples[$optional] $options[$optional] }
                    else { Assert-Equal "$optional value" $samples[$optional] $options[$optional] }
                }
                finally { Use-RealHandlers }
            }
        }
    }

    Test-Case "AC-301 normalized options: Mode defaults to requirements, Revision to 0 for review; names match case-insensitively" {
        Use-RecordingHandlers
        try {
            $run = Invoke-InProcess -Arguments @("REVIEW", "-targetpath", $targetDir, "-NAME", "feature", "-Task", "t")
            Assert-Equal "exit code" 0 $run.ExitCode
            $options = $script:handlerCalls[0].Options
            Assert-Equal "command" "review" $script:handlerCalls[0].Command
            Assert-Equal "mode" "requirements" $options["Mode"]
            Assert-Equal "revision" 0 $options["Revision"]
            Assert-Equal "revision type" "System.Int32" $options["Revision"].GetType().FullName
            Assert-Equal "name key" "TargetPath,Name,Task,Mode,Revision" (@($options.Keys) -join ",")
        }
        finally { Use-RealHandlers }
    }

    Test-Case "AC-301 an option takes the next element whatever it starts with (-Task -Json is a task, not a switch)" {
        $parsed = ConvertFrom-HarnessCliArguments -Arguments @("specify", "-TargetPath", $targetDir, "-Name", "feature", "-Task", "-Json")
        Assert-Equal "ok" "True" $parsed.ok
        Assert-Equal "task" "-Json" $parsed.options["Task"]
        Assert-True "no Json switch" (-not $parsed.options.Contains("Json"))
    }

    Test-Case "AC-301 -Include is one comma-separated string (D-306)" {
        Use-RecordingHandlers
        try {
            $run = Invoke-InProcess -Arguments @("context", "-TargetPath", $targetDir, "-Include", "a.md,b.md")
            Assert-Equal "exit code" 0 $run.ExitCode
            Assert-Equal "include" "a.md,b.md" $script:handlerCalls[0].Options["Include"]
        }
        finally { Use-RealHandlers }
    }

    Test-Case "AC-301 an empty option value and a non-switch value of a switch are argument errors (in process)" {
        foreach ($options in @(@{ TargetPath = "" }, @{ TargetPath = "   " })) {
            $lines = @(Invoke-HarnessCli -Command "scan" -Options $options -Result ($r = @{}))
            Assert-Equal "exit" 2 $r.exitCode
            Assert-True "first line" ($lines[0].StartsWith("ERROR: invalid_arguments:", [System.StringComparison]::Ordinal))
        }
        $lines = @(Invoke-HarnessCli -Command "stages" -Options @{ Json = "yes" } -Result ($r = @{}))
        Assert-Equal "exit" 2 $r.exitCode
        Assert-True "first line" ($lines[0].StartsWith("ERROR: invalid_arguments:", [System.StringComparison]::Ordinal))
    }

    Test-Case "AC-301 -StageScripts rejects an unknown key (in process)" {
        $lines = @(Invoke-HarnessCli -Command "stages" -Options @{} -StageScripts @{ bogus = "x.ps1" } -Result ($r = @{}))
        Assert-Equal "exit" 2 $r.exitCode
        Assert-True "first line" ($lines[0].StartsWith("ERROR: invalid_arguments:", [System.StringComparison]::Ordinal))
    }

    # -----------------------------------------------------------------------
    # AC-301: the argument errors (child process: exit 2, first line, runs\ empty)
    # -----------------------------------------------------------------------

    $specifyBase = @("specify", "-TargetPath", $targetDir, "-Name", "feature", "-Task", "Do the thing.")
    $reviewBase = @("review", "-TargetPath", $targetDir, "-Name", "feature", "-Task", "Do the thing.")
    $errorCases = [ordered]@{
        "no command"                                   = @()
        "an option instead of a command"               = @("-TargetPath", $targetDir)
        "an unknown command"                           = @("frobnicate")
        "an unknown option"                            = $specifyBase + @("-Bogus", "1")
        "-Targ (an incomplete name)"                   = @("specify", "-Targ", $targetDir, "-Name", "feature", "-Task", "t")
        "an option of another command (scan -Name)"    = @("scan", "-TargetPath", $targetDir, "-Name", "x")
        "an option of another command (stages -Last)"  = @("stages", "-Last", "3")
        "an option of another command (specify -Revision)" = $specifyBase + @("-Revision", "1")
        "an option without a value (scan)"             = @("scan", "-TargetPath")
        "an option without a value (the last -Task)"   = @("specify", "-TargetPath", $targetDir, "-Name", "feature", "-Task")
        "a duplicated option"                          = @("scan", "-TargetPath", $targetDir, "-TargetPath", $targetDir)
        "a duplicated switch"                          = @("stages", "-Json", "-Json")
        "a leftover positional (-Include a.md b.md)"   = @("context", "-TargetPath", $targetDir, "-Include", "a.md", "b.md")
        "a leftover positional (stages x)"             = @("stages", "x")
        "-Model with -Profile (specify)"               = $specifyBase + @("-Model", "m:1", "-Profile", "fast")
        "-Model with -Profile (config)"                = @("config", "-Model", "m:1", "-Profile", "fast")
        "both -Task and -TaskFile"                     = $specifyBase + @("-TaskFile", $taskFilePath)
        "-TaskFile that does not exist"                = @("specify", "-TargetPath", $targetDir, "-Name", "feature", "-TaskFile", (Join-Path $tempRoot "no-such-task.txt"))
        "-Mode Requirements (upper case)"              = $specifyBase + @("-Mode", "Requirements")
        "-Mode of validate not one of three"           = @("validate", "-SpecFile", (Join-Path $specFixtures "minimal-valid-spec.md"), "-Mode", "strict")
        "-Revision abc"                                = $reviewBase + @("-Revision", "abc")
        "-Revision -1"                                 = $reviewBase + @("-Revision", "-1")
        "revise -Revision 0"                           = @("revise", "-TargetPath", $targetDir, "-Name", "feature", "-Task", "t", "-Revision", "0")
        "-Last 0"                                      = @("list", "-Last", "0")
        "-Last abc"                                    = @("list", "-Last", "abc")
        "-Name that ends in .review"                   = @("specify", "-TargetPath", $targetDir, "-Name", "feature.review", "-Task", "t")
        "-Name with .revised-v2"                       = @("specify", "-TargetPath", $targetDir, "-Name", "feature.revised-v2", "-Task", "t")
        "-Name with .revised-v2. inside"               = @("specify", "-TargetPath", $targetDir, "-Name", "feature.revised-v2.x", "-Task", "t")
        "-Name that ends in a dot"                     = @("specify", "-TargetPath", $targetDir, "-Name", "feature.", "-Task", "t")
        "-Name with a device name"                     = @("specify", "-TargetPath", $targetDir, "-Name", "con.x", "-Task", "t")
        "-Name that starts with a dot"                 = @("specify", "-TargetPath", $targetDir, "-Name", ".feature", "-Task", "t")
        "-RunId with a device name"                    = @("scan", "-TargetPath", $targetDir, "-RunId", "nul")
        "-RunId with a separator"                      = @("scan", "-TargetPath", $targetDir, "-RunId", "a\b")
        "-RunId of status that is not an id"           = @("status", "-RunId", "..")
        "-TargetPath that does not exist"              = @("scan", "-TargetPath", (Join-Path $tempRoot "no-such-folder"))
        "-TargetPath that is a file"                   = @("scan", "-TargetPath", $fileTarget)
        "-TargetPath that is a junction"               = @("scan", "-TargetPath", $junctionDir)
        "-TargetPath equal to the harness root"        = @("scan", "-TargetPath", $harnessRoot)
        "-TargetPath that contains the harness root"   = @("scan", "-TargetPath", $tempRoot)
        "a missing input spec for review"              = @("review", "-TargetPath", $emptyTarget, "-Name", "feature", "-Task", "t")
        "a missing review file for revise"             = @("revise", "-TargetPath", $targetDir, "-Name", "feature", "-Task", "t", "-Revision", "2")
        "validate -SpecFile that does not exist"       = @("validate", "-SpecFile", (Join-Path $specFixtures "no-such-spec.md"))
        "an unsupported command with -Name"            = @("develop", "-Name", "x")
        "-Json: status without -RunId"                 = @("status", "-Json")
        "-Json: list -Last 0"                          = @("list", "-Json", "-Last", "0")
        "-Json: stages with an unknown option"         = @("stages", "-Json", "-Foo")
        "-Json: config -Model with -Profile"           = @("config", "-Json", "-Model", "a", "-Profile", "b")
        "-Json: doctor with a leftover positional"     = @("doctor", "-Json", "x")
    }
    foreach ($label in $errorCases.Keys) {
        Test-Case "AC-301 argument error: $label -> exit 2, one ERROR: invalid_arguments: line, runs\ empty" {
            Clear-Runs
            $run = Invoke-Harness -Arguments $errorCases[$label]
            Assert-Equal "exit code" 2 $run.ExitCode
            Assert-Equal "output lines" 1 $run.Lines.Count
            Assert-True "first line starts with ERROR: invalid_arguments: ($($run.Lines[0]))" ($run.Lines[0].StartsWith("ERROR: invalid_arguments:", [System.StringComparison]::Ordinal))
            Assert-NoRuns
        }
    }

    # B4 implemented 'specify' (scripts\test-harness-e2e.ps1 covers it) and B5 review, revise, status, list (scripts\test-harness-review-status.ps1); the stubs that remain:
    foreach ($case in @(
            @{ Label = "scan"; Args = (New-ArgumentList "scan" @("TargetPath")) },
            @{ Label = "context"; Args = (New-ArgumentList "context" @("TargetPath", "Include")) })) {
        Test-Case "AC-301 a valid '$($case.Label)' reaches its handler in harness.ps1 (a stub until B8): exit 2, internal_error, no run" {
            Clear-Runs
            $run = Invoke-Harness -Arguments $case.Args
            Assert-Equal "exit code" 2 $run.ExitCode
            Assert-Equal "output lines" 1 $run.Lines.Count
            Assert-True "stub line ($($run.Lines[0]))" ($run.Lines[0].StartsWith("ERROR: internal_error:", [System.StringComparison]::Ordinal) -and $run.Lines[0].Contains("not implemented"))
            Assert-NoRuns
        }
    }

    Test-Case "AC-301 the same error line comes out of the in-process entry (Invoke-HarnessCli) for a bad option set" {
        $lines = @(Invoke-HarnessCli -Command "scan" -Options @{ Name = "x"; TargetPath = $targetDir } -Result ($r = @{}))
        Assert-Equal "exit" 2 $r.exitCode
        Assert-Equal "lines" 1 $lines.Count
        Assert-True "first line" ($lines[0].StartsWith("ERROR: invalid_arguments:", [System.StringComparison]::Ordinal))
        $lines = @(Invoke-HarnessCli -Command "" -Options @{} -Result ($r = @{}))
        Assert-Equal "exit (no command)" 2 $r.exitCode
        Assert-True "first line (no command)" ($lines[0].StartsWith("ERROR: invalid_arguments:", [System.StringComparison]::Ordinal))
        Assert-NoRuns
    }

    Test-Case "AC-301 a relative -TargetPath resolves against the PowerShell location, and C:\x and C:\x\ give one path" {
        Use-RecordingHandlers
        try {
            Set-Location -LiteralPath $tempRoot
            [System.Environment]::CurrentDirectory = $env:SystemRoot
            $run = Invoke-InProcess -Arguments @("scan", "-TargetPath", "target")
            Assert-Equal "exit (relative)" 0 $run.ExitCode
            Assert-Equal "relative target" $targetDir $script:handlerCalls[0].Options["TargetPath"]
            $run = Invoke-InProcess -Arguments @("scan", "-TargetPath", ".\target\")
            Assert-Equal "relative with a trailing separator" $targetDir $script:handlerCalls[1].Options["TargetPath"]
            $run = Invoke-InProcess -Arguments @("scan", "-TargetPath", $targetDir)
            $run = Invoke-InProcess -Arguments @("scan", "-TargetPath", ($targetDir + "\"))
            Assert-Equal "absolute" $targetDir $script:handlerCalls[2].Options["TargetPath"]
            Assert-Equal "absolute with a trailing separator" $targetDir $script:handlerCalls[3].Options["TargetPath"]
        }
        finally {
            Set-Location -LiteralPath $originalLocation
            [System.Environment]::CurrentDirectory = $originalProcessDirectory
            Use-RealHandlers
        }
    }

    Test-Case "AC-301 a short (8.3) -TargetPath is expanded to the long path" {
        $longDirectory = Join-Path $tempRoot "A Long Folder Name For Short Names"
        [void][System.IO.Directory]::CreateDirectory($longDirectory)
        $shortPath = $null
        try { $shortPath = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($longDirectory).ShortPath } catch { $shortPath = $null }
        if ([string]::IsNullOrEmpty($shortPath) -or $shortPath -ceq $longDirectory) {
            Write-Host "       [NOTE] 8.3 names are not available on this volume: the expansion was not exercised" -ForegroundColor Yellow
            return
        }
        Use-RecordingHandlers
        try {
            $run = Invoke-InProcess -Arguments @("scan", "-TargetPath", $shortPath)
            Assert-Equal "exit" 0 $run.ExitCode
            Assert-Equal "expanded" $longDirectory $script:handlerCalls[0].Options["TargetPath"]
        }
        finally { Use-RealHandlers }
    }

    Test-Case "AC-301 review and revise with their input files present reach the handler with absolute paths" {
        Use-RecordingHandlers
        try {
            $run = Invoke-InProcess -Arguments @("review", "-TargetPath", $targetDir, "-Name", "feature", "-Task", "t", "-Revision", "1")
            Assert-Equal "review exit" 0 $run.ExitCode
            $run = Invoke-InProcess -Arguments @("revise", "-TargetPath", $targetDir, "-Name", "feature", "-Task", "t", "-Revision", "1")
            Assert-Equal "revise exit" 0 $run.ExitCode
            Assert-Equal "handler calls" 2 @($script:handlerCalls).Count
        }
        finally { Use-RealHandlers }
    }

    # -----------------------------------------------------------------------
    # stages, validate (in process, real handlers)
    # -----------------------------------------------------------------------

    Test-Case "AC-312 stages -Json lists the five unsupported commands as supported false and the six others as true" {
        $run = Invoke-InProcess -Arguments @("stages", "-Json")
        Assert-Equal "exit" 0 $run.ExitCode
        Assert-Equal "one line" 1 $run.Lines.Count
        $document = $run.Lines[0] | ConvertFrom-Json
        $expected = [ordered]@{ specify = $true; review = $true; revise = $true; scan = $true; context = $true; validate = $true; architecture = $false; plan = $false; qa = $false; "code-review" = $false; develop = $false }
        Assert-Equal "entries" $expected.Count @($document.stages).Count
        foreach ($entry in @($document.stages)) {
            Assert-True "$($entry.name) is expected" ($expected.Contains($entry.name))
            Assert-Equal "$($entry.name) supported" $expected[$entry.name] $entry.supported
        }
        $develop = @($document.stages | Where-Object { $_.name -ceq "develop" })[0]
        Assert-Equal "develop reason" "planned_phase_5" $develop.reason
        $plan = @($document.stages | Where-Object { $_.name -ceq "plan" })[0]
        Assert-Equal "plan reason" "no_local_agent" $plan.reason
        $specify = @($document.stages | Where-Object { $_.name -ceq "specify" })[0]
        Assert-Equal "specify agent" "spec" $specify.agent
        Assert-True "specify reason is null" ($null -eq $specify.reason)
    }

    Test-Case "AC-314 stages in text mode prints one line per command, exit 0" {
        $run = Invoke-InProcess -Arguments @("stages")
        Assert-Equal "exit" 0 $run.ExitCode
        Assert-Equal "lines" 11 $run.Lines.Count
    }

    $validatorLog = Join-Path $tempRoot "validator-calls.txt"
    $mockValidator = Join-Path $tempRoot "mock-validator.ps1"
    [System.IO.File]::WriteAllText($mockValidator, @'
param([string]$SpecFile, [string]$Mode)
[System.IO.File]::AppendAllText($env:HARNESS_TEST_VALIDATOR_LOG, "$SpecFile|$Mode`n")
$code = $env:HARNESS_TEST_VALIDATOR_CODE
if ($code -eq "throw") { throw "mock validator throws" }
if ($code -eq "none") { return }
exit ([int]$code)
'@, $utf8NoBom)

    foreach ($case in @(
            @{ Fixture = "minimal-valid-spec.md"; Mode = "requirements"; Exit = 0 },
            @{ Fixture = "invalid-spec.md"; Mode = "requirements"; Exit = 1 },
            @{ Fixture = "documentation-none-spec.md"; Mode = "requirements"; Exit = 3 },
            @{ Fixture = "documentation-none-spec.md"; Mode = "documentation"; Exit = 0 },
            @{ Fixture = "empty-spec.md"; Mode = "requirements"; Exit = 2 })) {
        Test-Case "FR-301 validate passes the validator's exit code through: $($case.Fixture) in $($case.Mode) gives $($case.Exit)" {
            $run = Invoke-InProcess -Arguments @("validate", "-SpecFile", (Join-Path $specFixtures $case.Fixture), "-Mode", $case.Mode)
            Assert-Equal "exit" $case.Exit $run.ExitCode
            Assert-NoRuns
            if ($case.Exit -eq 2) { Assert-True "stage_failed line" ($run.Lines.Count -eq 1 -and $run.Lines[0].StartsWith("ERROR: stage_failed:", [System.StringComparison]::Ordinal)) }
        }
    }

    foreach ($case in @(@{ Code = "none"; Exit = 0 }, @{ Code = "0"; Exit = 0 }, @{ Code = "1"; Exit = 1 }, @{ Code = "3"; Exit = 3 }, @{ Code = "7"; Exit = 2 }, @{ Code = "throw"; Exit = 2 })) {
        Test-Case "FR-301 validate with a mock validator ending $($case.Code): exit $($case.Exit); the call carries the absolute file and the mode" {
            $env:HARNESS_TEST_VALIDATOR_LOG = $validatorLog
            $env:HARNESS_TEST_VALIDATOR_CODE = $case.Code
            if (Test-Path -LiteralPath $validatorLog) { Remove-Item -LiteralPath $validatorLog -Force }
            try {
                $specPath = Join-Path $specFixtures "minimal-valid-spec.md"
                $result = @{}
                $lines = @(Invoke-HarnessCli -Command "validate" -Options ([ordered]@{ SpecFile = $specPath; Mode = "baseline" }) -StageScripts @{ validator = $mockValidator } -Result $result)
                Assert-Equal "exit" $case.Exit $result.exitCode
                Assert-Equal "validator call" "$specPath|baseline" ([System.IO.File]::ReadAllText($validatorLog).Trim())
                if ($case.Exit -eq 2) { Assert-True "stage_failed line" ($lines.Count -eq 1 -and $lines[0].StartsWith("ERROR: stage_failed:", [System.StringComparison]::Ordinal)) }
            }
            finally {
                Remove-Item Env:\HARNESS_TEST_VALIDATOR_LOG -ErrorAction SilentlyContinue
                Remove-Item Env:\HARNESS_TEST_VALIDATOR_CODE -ErrorAction SilentlyContinue
            }
        }
    }

    Test-Case "FR-301 validate through harness.ps1 as a process: the real validator, exit codes 0 and 1, no run" {
        Clear-Runs
        $run = Invoke-Harness -Arguments @("validate", "-SpecFile", (Join-Path $specFixtures "minimal-valid-spec.md"))
        Assert-Equal "pass exit" 0 $run.ExitCode
        $run = Invoke-Harness -Arguments @("validate", "-SpecFile", (Join-Path $specFixtures "invalid-spec.md"))
        Assert-Equal "fail exit" 1 $run.ExitCode
        Assert-NoRuns
    }

    # -----------------------------------------------------------------------
    # AC-312: the five unsupported stages
    # -----------------------------------------------------------------------

    foreach ($stage in @("architecture", "plan", "qa", "code-review", "develop")) {
        Test-Case "AC-312 '$stage' exits 4 with one unsupported stage, a failed valid manifest, the protocol lines, no request" {
            $run = Invoke-HarnessCase -Name "unsupported-$stage" -ConfigText (New-V2Config) -Arguments @($stage)
            Assert-Guards $run
            Assert-Equal "exit code" 4 $run.ExitCode
            Assert-Equal "requests" 0 $run.Calls.Count
            Assert-Equal "telemetry" 0 $run.Telemetry.Count
            $lines = @(Get-HarnessOutput $run)
            Assert-Equal "output lines" 3 $lines.Count
            Assert-True "RUN_ID first ($($lines[0]))" ($lines[0] -cmatch '\ARUN_ID: [A-Za-z0-9][A-Za-z0-9._-]*\z')
            $message = "No local agent implements '$stage'; perform it in Claude Code or manually."
            Assert-Equal "error line" "ERROR: unsupported_stage: $message" $lines[1]
            Assert-True "MANIFEST last" ($lines[2].StartsWith("MANIFEST: ", [System.StringComparison]::Ordinal))
            $manifestPath = $lines[2].Substring("MANIFEST: ".Length)
            Assert-True "absolute path" ([System.IO.Path]::IsPathRooted($manifestPath))
            Assert-True "manifest exists" (Test-Path -LiteralPath $manifestPath -PathType Leaf)
            $runId = $lines[0].Substring("RUN_ID: ".Length)
            Assert-Equal "manifest location" (Join-Path (Join-Path $harnessRoot "runs") "$runId\manifest.json") $manifestPath
            $text = Read-HarnessTextFile -Path $manifestPath
            $check = Test-HarnessManifest -Manifest $text
            Assert-True "the manifest validates: $($check.errors -join '; ')" $check.valid
            $manifest = $text | ConvertFrom-Json
            Assert-Equal "runId" $runId $manifest.runId
            Assert-Equal "workflow" $stage $manifest.workflow
            Assert-Equal "status" "failed" $manifest.status
            Assert-Equal "exitCode" 4 $manifest.exitCode
            Assert-Equal "error category" "unsupported_stage" $manifest.error.category
            Assert-Equal "error message" $message $manifest.error.message
            Assert-Equal "stage count" 1 @($manifest.stages).Count
            Assert-Equal "stage id" $stage $manifest.stages[0].id
            Assert-Equal "stage kind" "unsupported" $manifest.stages[0].kind
            Assert-Equal "stage status" "unsupported" $manifest.stages[0].status
            Assert-Equal "stage error" "unsupported_stage" $manifest.stages[0].error.category
            Assert-Equal "claim file kept" $true (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $manifestPath) ".claim"))
        }
    }

    Test-Case "AC-312 develop with -TargetPath and -RunId: the id and the target are recorded; the same id again is invalid_arguments and creates nothing new" {
        $run = Invoke-HarnessCase -Name "unsupported-develop-given" -ConfigText (New-V2Config) -Arguments @("develop", "-TargetPath", $targetDir, "-RunId", "given-run-1")
        Assert-Guards $run
        Assert-Equal "exit" 4 $run.ExitCode
        $lines = @(Get-HarnessOutput $run)
        Assert-Equal "RUN_ID line" "RUN_ID: given-run-1" $lines[0]
        $manifest = (Read-HarnessTextFile -Path (Join-Path $harnessRoot "runs\given-run-1\manifest.json")) | ConvertFrom-Json
        Assert-Equal "target root" $targetDir $manifest.target.root
        Assert-Equal "manifest runId" "given-run-1" $manifest.runId
        $before = (Get-HarnessFileSha256 -Path (Join-Path $harnessRoot "runs\given-run-1\manifest.json"))
        $again = Invoke-Case -Name "unsupported-develop-again" -ConfigText (New-V2Config) -Script "harness.ps1" -ArgumentList @("develop", "-RunId", "given-run-1") -TypedExceptions
        Assert-Equal "exit (taken id)" 2 $again.ExitCode
        $againLines = @(Get-HarnessOutput $again)
        Assert-Equal "lines (taken id)" 1 $againLines.Count
        Assert-True "error line (taken id)" ($againLines[0].StartsWith("ERROR: invalid_arguments:", [System.StringComparison]::Ordinal))
        Assert-Equal "manifest untouched" $before (Get-HarnessFileSha256 -Path (Join-Path $harnessRoot "runs\given-run-1\manifest.json"))
        Assert-Equal "run directories" 1 @(Get-ChildItem -LiteralPath (Join-Path $harnessRoot "runs") -Force).Count
    }

    Test-Case "AC-312 no stage script is called for an unsupported command (mock stages, in process)" {
        Set-TempConfig (New-V2Config)
        Clear-Runs
        $marker = Join-Path $tempRoot "stage-called.txt"
        if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
        $mock = Join-Path $tempRoot "mock-stage.ps1"
        [System.IO.File]::WriteAllText($mock, 'param() [System.IO.File]::AppendAllText($env:HARNESS_TEST_STAGE_MARKER, "called`n")', $utf8NoBom)
        $env:HARNESS_TEST_STAGE_MARKER = $marker
        try {
            $mocks = @{ runner = $mock; validator = $mock; reviewer = $mock; reviser = $mock; scan = $mock; context = $mock }
            foreach ($stage in @("architecture", "plan", "qa", "code-review", "develop")) {
                $result = @{}
                $lines = @(Invoke-HarnessCli -Command $stage -Options @{} -StageScripts $mocks -Result $result)
                Assert-Equal "$stage exit" 4 $result.exitCode
                Assert-Equal "$stage lines" 3 $lines.Count
            }
            Assert-True "no stage script ran" (-not (Test-Path -LiteralPath $marker))
        }
        finally { Remove-Item Env:\HARNESS_TEST_STAGE_MARKER -ErrorAction SilentlyContinue }
        Assert-Equal "rest violations" 0 $script:restViolations
    }

    # -----------------------------------------------------------------------
    # AC-314: config
    # -----------------------------------------------------------------------

    # config-v2-current.json agent files in the temporary harness: developer, spec,
    # spec-reviewer, spec-reviser (sorted). The configuration under test is the fixture
    # byte for byte, with its real URL: the process cannot reach the fake host, which is
    # the point (config sends no request); the in-process guard counts violations.
    $fixtureExpected = [ordered]@{
        "developer"     = @{ profile = "deep"; model = $deepModel; source = "agent"; timeout = 900; window = 16384 }
        "spec"          = @{ profile = "fast"; model = $fastModel; source = "agent"; timeout = 900; window = 16384 }
        "spec-reviewer" = @{ profile = "deep"; model = $deepModel; source = "agent"; timeout = 900; window = 16384 }
        "spec-reviser"  = @{ profile = "deep"; model = $deepModel; source = "agent"; timeout = 900; window = 16384 }
    }

    function Assert-ConfigTable {
        param($Document, $Expected)

        $agents = @($Document.agents)
        Assert-Equal "agent count" $Expected.Count $agents.Count
        Assert-Equal "agent order" (@($Expected.Keys) -join ",") (@($agents | ForEach-Object { $_.agent }) -join ",")
        foreach ($agent in $agents) {
            $row = $Expected[$agent.agent]
            Assert-Equal "$($agent.agent) profile" $row.profile $agent.profile
            Assert-Equal "$($agent.agent) model" $row.model $agent.model
            Assert-Equal "$($agent.agent) modelSource" $row.source $agent.modelSource
            Assert-Equal "$($agent.agent) timeoutSec" $row.timeout $agent.timeoutSec
            Assert-Equal "$($agent.agent) contextWindow" $row.window $agent.contextWindow
        }
    }

    Test-Case "AC-314 config -Json on config-v2-current.json: per agent profile, model, modelSource, timeoutSec and contextWindow of a literal table; one parsable line; no request (in process)" {
        Set-TempConfig $configFixtureText
        $before = $script:restViolations
        $run = Invoke-InProcess -Arguments @("config", "-Json")
        Assert-Equal "exit" 0 $run.ExitCode
        Assert-Equal "one line" 1 $run.Lines.Count
        Assert-ConfigTable ($run.Lines[0] | ConvertFrom-Json) $fixtureExpected
        Assert-Equal "requests" $before $script:restViolations
    }

    Test-Case "AC-314 config -Json -Profile fast and -Profile deep on the fixture" {
        Set-TempConfig $configFixtureText
        $fast = [ordered]@{}
        $deep = [ordered]@{}
        foreach ($agent in $fixtureExpected.Keys) {
            $fast[$agent] = @{ profile = "fast"; model = $fastModel; source = "explicit-profile"; timeout = 900; window = 16384 }
            $deep[$agent] = @{ profile = "deep"; model = $deepModel; source = "explicit-profile"; timeout = 900; window = 16384 }
        }
        Assert-ConfigTable ((Invoke-InProcess -Arguments @("config", "-Json", "-Profile", "fast")).Lines[0] | ConvertFrom-Json) $fast
        Assert-ConfigTable ((Invoke-InProcess -Arguments @("config", "-Json", "-Profile", "deep")).Lines[0] | ConvertFrom-Json) $deep
    }

    Test-Case "AC-314 config -Json -Model of a registered model gives its profile; an unregistered model keeps the agent's parameters and warns" {
        Set-TempConfig $configFixtureText
        $registered = [ordered]@{}
        foreach ($agent in $fixtureExpected.Keys) { $registered[$agent] = @{ profile = "fast"; model = $fastModel; source = "explicit-model"; timeout = 900; window = 16384 } }
        Assert-ConfigTable ((Invoke-InProcess -Arguments @("config", "-Json", "-Model", $fastModel)).Lines[0] | ConvertFrom-Json) $registered
        $document = (Invoke-InProcess -Arguments @("config", "-Json", "-Model", "unlisted:1")).Lines[0] | ConvertFrom-Json
        foreach ($agent in @($document.agents)) {
            Assert-Equal "$($agent.agent) model" "unlisted:1" $agent.model
            Assert-Equal "$($agent.agent) source" "explicit-model" $agent.modelSource
            Assert-Equal "$($agent.agent) warning" "unregistered_model_override" (@($agent.warnings) -join ",")
            Assert-Equal "$($agent.agent) parametersFrom" $fixtureExpected[$agent.agent].profile $agent.parametersFrom
        }
    }

    Test-Case "AC-314 config -Json with AI_HARNESS_MODEL: modelSource env, and -Profile overrides it" {
        Set-TempConfig $configFixtureText
        $env:AI_HARNESS_MODEL = $fastModel
        try {
            $fromEnv = [ordered]@{}
            foreach ($agent in $fixtureExpected.Keys) { $fromEnv[$agent] = @{ profile = "fast"; model = $fastModel; source = "env"; timeout = 900; window = 16384 } }
            Assert-ConfigTable ((Invoke-InProcess -Arguments @("config", "-Json")).Lines[0] | ConvertFrom-Json) $fromEnv
            $profiled = [ordered]@{}
            foreach ($agent in $fixtureExpected.Keys) { $profiled[$agent] = @{ profile = "deep"; model = $deepModel; source = "explicit-profile"; timeout = 900; window = 16384 } }
            Assert-ConfigTable ((Invoke-InProcess -Arguments @("config", "-Json", "-Profile", "deep")).Lines[0] | ConvertFrom-Json) $profiled
        }
        finally { $env:AI_HARNESS_MODEL = $null }
    }

    # A configuration whose numbers differ per profile, so a wrong profile shows.
    $distinctConfig = New-V2Config
    $distinctExpected = [ordered]@{}
    foreach ($agent in @("developer", "spec", "spec-reviewer", "spec-reviser")) { $distinctExpected[$agent] = @{ profile = "alpha"; model = "test-model-alpha"; source = "agent"; timeout = 222; window = 8192 } }

    Test-Case "AC-314 config -Json in the fake host (no request recorded) on a configuration with distinct numbers; -Profile beta and -Model" {
        $run = Invoke-HarnessCase -Name "config-default" -ConfigText $distinctConfig -Arguments @("config", "-Json")
        Assert-Guards $run
        Assert-Equal "exit" 0 $run.ExitCode
        Assert-Equal "requests" 0 $run.Calls.Count
        Assert-ConfigTable (Get-JsonOutput $run) $distinctExpected

        $run = Invoke-HarnessCase -Name "config-profile" -ConfigText $distinctConfig -Arguments @("config", "-Json", "-Profile", "beta")
        Assert-Guards $run
        Assert-Equal "requests (profile)" 0 $run.Calls.Count
        $document = Get-JsonOutput $run
        foreach ($agent in @($document.agents)) {
            Assert-Equal "$($agent.agent) profile" "beta" $agent.profile
            Assert-Equal "$($agent.agent) model" "test-model-beta" $agent.model
            Assert-Equal "$($agent.agent) timeoutSec" 333 $agent.timeoutSec
            Assert-True "$($agent.agent) contextWindow is null" ($null -eq $agent.contextWindow)
        }

        $run = Invoke-HarnessCase -Name "config-model" -ConfigText $distinctConfig -Arguments @("config", "-Json", "-Model", "test-model-beta")
        Assert-Guards $run
        Assert-Equal "requests (model)" 0 $run.Calls.Count
        foreach ($agent in @((Get-JsonOutput $run).agents)) {
            Assert-Equal "$($agent.agent) source" "explicit-model" $agent.modelSource
            Assert-Equal "$($agent.agent) parametersFrom" "beta" $agent.parametersFrom
            Assert-Equal "$($agent.agent) timeoutSec" 333 $agent.timeoutSec
        }
    }

    Test-Case "AC-314 config -Agent spec restricts to one agent; an unknown agent is invalid_arguments; text mode has one line per agent" {
        Set-TempConfig $configFixtureText
        $document = (Invoke-InProcess -Arguments @("config", "-Json", "-Agent", "spec")).Lines[0] | ConvertFrom-Json
        Assert-Equal "agents" 1 @($document.agents).Count
        Assert-Equal "agent" "spec" $document.agents[0].agent
        $run = Invoke-InProcess -Arguments @("config", "-Json", "-Agent", "nobody")
        Assert-Equal "unknown agent exit" 2 $run.ExitCode
        Assert-Equal "unknown agent lines" 1 $run.Lines.Count
        Assert-True "unknown agent line" ($run.Lines[0].StartsWith("ERROR: invalid_arguments:", [System.StringComparison]::Ordinal))
        $text = Invoke-InProcess -Arguments @("config")
        Assert-Equal "text exit" 0 $text.ExitCode
        Assert-Equal "text lines" 4 $text.Lines.Count
    }

    Test-Case "AC-314 a failing config -Json prints one ERROR: registry_invalid: line (never JSON) and exits 2" {
        Set-TempConfig $v2Invalid
        $run = Invoke-InProcess -Arguments @("config", "-Json")
        Assert-Equal "exit" 2 $run.ExitCode
        Assert-Equal "lines" 1 $run.Lines.Count
        Assert-True "error line" ($run.Lines[0].StartsWith("ERROR: registry_invalid:", [System.StringComparison]::Ordinal))
        Set-TempConfig $configFixtureText
        $run = Invoke-InProcess -Arguments @("config", "-Json", "-Profile", "nonexistent")
        Assert-Equal "unknown profile exit" 2 $run.ExitCode
        Assert-True "unknown profile line" ($run.Lines.Count -eq 1 -and $run.Lines[0].StartsWith("ERROR: registry_invalid:", [System.StringComparison]::Ordinal))
        Remove-Item -LiteralPath $harnessConfig -Force
        $run = Invoke-InProcess -Arguments @("config", "-Json")
        Assert-Equal "missing config exit" 2 $run.ExitCode
        Assert-True "missing config line" ($run.Lines.Count -eq 1 -and $run.Lines[0].StartsWith("ERROR: registry_invalid:", [System.StringComparison]::Ordinal))
        Set-TempConfig $configFixtureText
        Assert-Equal "rest violations" 0 $script:restViolations
    }

    # -----------------------------------------------------------------------
    # AC-333: doctor, the load check, the nvidia-smi parser
    # -----------------------------------------------------------------------

    $tagsBoth = @((New-Step "ok" @{ models = @("test-model-alpha", "test-model-beta") }))
    $versionOk = @((New-Step "ok" @{ version = "0.9.9" }))

    # Files of the temporary harness except the configuration the case writes: path -> hash.
    function Get-HarnessSnapshot {
        $map = [ordered]@{}
        foreach ($file in @(Get-ChildItem -LiteralPath $harnessRoot -Recurse -File -Force | Sort-Object FullName)) {
            if ($file.FullName -ceq $harnessConfig) { continue }
            $map[$file.FullName] = Get-HarnessFileSha256 -Path $file.FullName
        }
        return $map
    }

    Test-Case "AC-333 doctor -Json: every model listed and a version answered gives exit 0 and the version; only /api/tags and /api/version are seen; nothing written, no telemetry" {
        Clear-Runs
        $before = Get-HarnessSnapshot
        $run = Invoke-HarnessCase -Name "doctor-ok" -ConfigText (New-V2Config) -Arguments @("doctor", "-Json") -TagsSteps $tagsBoth -VersionSteps $versionOk
        Assert-Guards $run
        Assert-Equal "exit" 0 $run.ExitCode
        $document = Get-JsonOutput $run
        Assert-Equal "exitCode member" 0 $document.exitCode
        Assert-Equal "version" "0.9.9" $document.ollama.version
        Assert-Equal "reachable" "True" $document.ollama.reachable
        Assert-Equal "url" $fakeUrl $document.ollama.url
        Assert-Equal "models" "test-model-alpha,test-model-beta" (@($document.models | ForEach-Object { $_.model }) -join ",")
        Assert-Equal "installed" "True,True" (@($document.models | ForEach-Object { $_.installed }) -join ",")
        Assert-Equal "findings" 0 @($document.findings).Count
        Assert-True "vramFreeMiB is null without nvidia-smi" ($null -eq $document.vramFreeMiB)
        Assert-True "ollama ps is null without ollama" ($null -eq $document.ollama.ps)
        Assert-Equal "registry schemaVersion" 2 $document.registry.schemaVersion
        Assert-Equal "routes" "$fakeUrl/api/tags,$fakeUrl/api/version" ((Get-RouteUris $run) -join ",")
        Assert-Equal "tags requests" 1 @(Get-Route $run "tags").Count
        Assert-Equal "generate requests" 0 @(Get-Route $run "generate").Count
        Assert-Equal "telemetry records" 0 $run.Telemetry.Count
        Assert-True "no logs directory" (-not (Test-Path -LiteralPath $harnessLogs))
        Assert-True "no runs directory" (-not (Test-Path -LiteralPath (Join-Path $harnessRoot "runs")))
        $after = Get-HarnessSnapshot
        Assert-Equal "files before and after" (($before.Keys | ForEach-Object { "$_=$($before[$_])" }) -join "`n") (($after.Keys | ForEach-Object { "$_=$($after[$_])" }) -join "`n")
    }

    Test-Case "AC-333 doctor in text mode: version, models and the result line" {
        $run = Invoke-HarnessCase -Name "doctor-text" -ConfigText (New-V2Config) -Arguments @("doctor") -TagsSteps $tagsBoth -VersionSteps $versionOk
        Assert-Guards $run
        Assert-Equal "exit" 0 $run.ExitCode
        Assert-Line $run "version 0.9.9"
        Assert-Line $run "Model: test-model-alpha installed"
        Assert-Line $run "Model: test-model-beta installed"
        Assert-Line $run "VRAM free: unavailable"
        Assert-ExactLine $run "Result: OK (exit 0)"
    }

    Test-Case "AC-333 doctor -Json: one model missing gives exit 1 and the finding model_not_installed" {
        $run = Invoke-HarnessCase -Name "doctor-missing" -ConfigText (New-V2Config) -Arguments @("doctor", "-Json") -TagsSteps @((New-Step "ok" @{ models = @("test-model-alpha") })) -VersionSteps $versionOk
        Assert-Guards $run
        Assert-Equal "exit" 1 $run.ExitCode
        $document = Get-JsonOutput $run
        Assert-Equal "exitCode member" 1 $document.exitCode
        Assert-Equal "installed" "True,False" (@($document.models | ForEach-Object { $_.installed }) -join ",")
        $codes = @($document.findings | ForEach-Object { $_.code })
        Assert-Equal "findings" "model_not_installed" ($codes -join ",")
        Assert-Equal "finding model" "test-model-beta" $document.findings[0].model
        Assert-Equal "finding severity" "error" $document.findings[0].severity
        Assert-Equal "generate requests" 0 @(Get-Route $run "generate").Count
        Assert-Equal "telemetry records" 0 $run.Telemetry.Count
    }

    Test-Case "AC-333 doctor: connection refused gives exit 2 and one ERROR: ollama_unreachable: line, with -Json and without" {
        $refused = @((New-Step "status" @{ webStatus = "ConnectFailure" }))
        foreach ($mode in @(@("doctor", "-Json"), @("doctor"))) {
            $run = Invoke-HarnessCase -Name "doctor-refused-$($mode.Count)" -ConfigText (New-V2Config) -Arguments $mode -TagsSteps $refused -VersionSteps $refused
            Assert-Guards $run
            Assert-Equal "exit ($($mode -join ' '))" 2 $run.ExitCode
            $lines = @(Get-HarnessOutput $run)
            Assert-Equal "lines ($($mode -join ' '))" 1 $lines.Count
            Assert-True "error line ($($lines[0]))" ($lines[0].StartsWith("ERROR: ollama_unreachable:", [System.StringComparison]::Ordinal))
            Assert-Equal "generate requests" 0 @(Get-Route $run "generate").Count
            Assert-Equal "telemetry records" 0 $run.Telemetry.Count
        }
    }

    Test-Case "AC-333 doctor: an invalid registry gives exit 2 and one ERROR: registry_invalid: line, and no request" {
        $run = Invoke-HarnessCase -Name "doctor-invalid-registry" -ConfigText $v2Invalid -Arguments @("doctor", "-Json")
        Assert-Guards $run
        Assert-Equal "exit" 2 $run.ExitCode
        $lines = @(Get-HarnessOutput $run)
        Assert-Equal "lines" 1 $lines.Count
        Assert-True "error line ($($lines[0]))" ($lines[0].StartsWith("ERROR: registry_invalid:", [System.StringComparison]::Ordinal))
        Assert-Equal "requests" 0 $run.Calls.Count
    }

    Test-Case "AC-333 doctor: no /api/version gives exit 0 and the informational finding ollama_version_unavailable (a 404 does too)" {
        foreach ($variant in @(
                @{ Label = "no-step"; Steps = @() },
                @{ Label = "http-404"; Steps = @((New-Step "http" @{ status = 404; body = '{"error":"not found"}' })) })) {
            $run = Invoke-HarnessCase -Name "doctor-noversion-$($variant.Label)" -ConfigText (New-V2Config) -Arguments @("doctor", "-Json") -TagsSteps $tagsBoth -VersionSteps $variant.Steps
            Assert-Guards $run
            Assert-Equal "exit ($($variant.Label))" 0 $run.ExitCode
            $document = Get-JsonOutput $run
            Assert-True "version is null" ($null -eq $document.ollama.version)
            Assert-Equal "reachable (tags answered)" "True" $document.ollama.reachable
            Assert-Equal "findings" "ollama_version_unavailable" (@($document.findings | ForEach-Object { $_.code }) -join ",")
            Assert-Equal "severity" "info" $document.findings[0].severity
            Assert-Equal "routes" "$fakeUrl/api/tags,$fakeUrl/api/version" ((Get-RouteUris $run) -join ",")
        }
    }

    # The load check: two profiles, three agents, two distinct (model, options) pairs.
    $loadConfig = @"
{
  "schemaVersion": 2,
  "ollama": { "url": "$fakeUrl", "healthTimeoutSec": 7, "maxAttempts": 2, "retryBackoffSec": 0, "warmup": false },
  "defaults": { "profile": "alpha", "options": { "temperature": 0.2 }, "timeoutSec": 111, "stripThinking": true },
  "profiles": {
    "alpha": { "model": "test-model-alpha", "contextWindow": 8192, "timeoutSec": 222, "reservedOutputTokens": 1024, "think": true },
    "gamma": { "model": "test-model-gamma", "contextWindow": 4096, "timeoutSec": 333, "reservedOutputTokens": 512, "think": true, "options": { "seed": 5 } }
  },
  "agents": {
    "spec": { "profile": "alpha" },
    "developer": { "profile": "alpha" },
    "spec-reviewer": { "profile": "gamma" },
    "spec-reviser": { "profile": "alpha" }
  }
}
"@
    $tagsLoad = @((New-Step "ok" @{ models = @("test-model-alpha", "test-model-gamma") }))

    Test-Case "AC-333 doctor -LoadCheck: one request per distinct (model, options) pair, a body of model, options (num_ctx = contextWindow) and stream only, the profile's timeout, success gives loaded true, exit 0" {
        $run = Invoke-HarnessCase -Name "doctor-load-ok" -ConfigText $loadConfig -Arguments @("doctor", "-Json", "-LoadCheck") -TagsSteps $tagsLoad -VersionSteps $versionOk -GenerateSteps @((New-Step "ok" @{ response = ""; doneReason = "load" })) -RepeatLastGenerate
        Assert-Guards $run
        Assert-Equal "exit" 0 $run.ExitCode
        $generate = @(Get-Route $run "generate")
        Assert-Equal "generate requests (3 agents, 2 pairs)" 2 $generate.Count
        Assert-Equal "models" "test-model-alpha,test-model-gamma" (@($generate | ForEach-Object { $_.model }) -join ",")
        foreach ($call in $generate) {
            Assert-Equal "members" "model,options,stream" $call.members
            Assert-Equal "has a prompt" "False" $call.hasPrompt
            Assert-Equal "has think" "False" $call.hasThink
            Assert-Equal "stream" "False" $call.streamValue
            Assert-Equal "stream is a boolean" "True" $call.streamIsBool
        }
        Assert-Equal "alpha options" "num_ctx=8192;temperature=0.2" $generate[0].optionsPairs
        Assert-Equal "gamma options" "num_ctx=4096;seed=5;temperature=0.2" $generate[1].optionsPairs
        Assert-Equal "alpha timeout" 222 $generate[0].timeoutSec
        Assert-Equal "gamma timeout" 333 $generate[1].timeoutSec
        $document = Get-JsonOutput $run
        Assert-Equal "findings" 0 @($document.findings).Count
        $alpha = @($document.models | Where-Object { $_.model -ceq "test-model-alpha" })[0]
        Assert-Equal "alpha load checks" 1 @($alpha.loadChecks).Count
        Assert-Equal "alpha agents" "spec,spec-reviser" (@($alpha.loadChecks[0].agents) -join ",")
        Assert-Equal "alpha loaded" "True" $alpha.loadChecks[0].loaded
        Assert-Equal "alpha numCtx" 8192 $alpha.loadChecks[0].numCtx
        Assert-Equal "telemetry records" 0 $run.Telemetry.Count
        Assert-True "no logs directory" (-not (Test-Path -LiteralPath $harnessLogs))
    }

    Test-Case "AC-333 doctor -LoadCheck: a 500 CUDA error gives exit 1, the finding model_load_failed, one attempt per pair, httpStatus absent and a fixed message" {
        $cuda = New-Step "http" @{ status = 500; body = '{"error":"CUDA error: out of memory"}' }
        $run = Invoke-HarnessCase -Name "doctor-load-cuda" -ConfigText $loadConfig -Arguments @("doctor", "-Json", "-LoadCheck") -TagsSteps $tagsLoad -VersionSteps $versionOk -GenerateSteps @($cuda) -RepeatLastGenerate
        Assert-Guards $run
        Assert-Equal "exit" 1 $run.ExitCode
        Assert-Equal "generate requests (one attempt per pair)" 2 @(Get-Route $run "generate").Count
        $document = Get-JsonOutput $run
        Assert-Equal "exitCode member" 1 $document.exitCode
        Assert-Equal "finding codes" "model_load_failed,model_load_failed" (@($document.findings | ForEach-Object { $_.code }) -join ",")
        $finding = $document.findings[0]
        Assert-Equal "message" "The model load check failed with the category 'model_load_failed'. The model could not be loaded by the Ollama server. Retrying at once does not help. Restarting the Ollama server has not cleared this fault; rebooting the machine does." $finding.message
        Assert-True "no httpStatus member" ($null -eq $finding.PSObject.Properties["httpStatus"])
        Assert-Equal "load check category" "model_load_failed" $document.models[0].loadChecks[0].category
        Assert-Equal "load check loaded" "False" $document.models[0].loadChecks[0].loaded
        Assert-Equal "telemetry records" 0 $run.Telemetry.Count
    }

    Test-Case "AC-333 doctor -LoadCheck: a 500 without a load marker is http_5xx, still one attempt per pair" {
        $plain = New-Step "http" @{ status = 500; body = '{"error":"internal server error"}' }
        $run = Invoke-HarnessCase -Name "doctor-load-5xx" -ConfigText $loadConfig -Arguments @("doctor", "-Json", "-LoadCheck") -TagsSteps $tagsLoad -VersionSteps $versionOk -GenerateSteps @($plain) -RepeatLastGenerate
        Assert-Guards $run
        Assert-Equal "exit" 1 $run.ExitCode
        Assert-Equal "generate requests" 2 @(Get-Route $run "generate").Count
        Assert-Equal "finding codes" "http_5xx,http_5xx" (@((Get-JsonOutput $run).findings | ForEach-Object { $_.code }) -join ",")
    }

    Test-Case "AC-333 doctor -LoadCheck skips a model that is not installed (it already has the model_not_installed finding)" {
        $run = Invoke-HarnessCase -Name "doctor-load-missing" -ConfigText $loadConfig -Arguments @("doctor", "-Json", "-LoadCheck") -TagsSteps @((New-Step "ok" @{ models = @("test-model-alpha") })) -VersionSteps $versionOk -GenerateSteps @((New-Step "ok" @{ response = "" })) -RepeatLastGenerate
        Assert-Guards $run
        Assert-Equal "exit" 1 $run.ExitCode
        $generate = @(Get-Route $run "generate")
        Assert-Equal "generate requests" 1 $generate.Count
        Assert-Equal "model" "test-model-alpha" $generate[0].model
        Assert-Equal "finding codes" "model_not_installed" (@((Get-JsonOutput $run).findings | ForEach-Object { $_.code }) -join ",")
    }

    Test-Case "AC-333 doctor without -LoadCheck sends no /api/generate; text mode shows the failed load check" {
        $run = Invoke-HarnessCase -Name "doctor-load-text" -ConfigText $loadConfig -Arguments @("doctor", "-LoadCheck") -TagsSteps $tagsLoad -VersionSteps $versionOk -GenerateSteps @((New-Step "http" @{ status = 503; body = '{"error":"CUDA error: out of memory"}' })) -RepeatLastGenerate
        Assert-Guards $run
        Assert-Equal "exit" 1 $run.ExitCode
        Assert-Line $run "FAILED model_load_failed"
        Assert-ExactLine $run "Result: FAIL (exit 1)"
        $plain = Invoke-HarnessCase -Name "doctor-no-loadcheck" -ConfigText $loadConfig -Arguments @("doctor", "-Json") -TagsSteps $tagsLoad -VersionSteps $versionOk
        Assert-Guards $plain
        Assert-Equal "exit (no -LoadCheck)" 0 $plain.ExitCode
        Assert-Equal "generate requests (no -LoadCheck)" 0 @(Get-Route $plain "generate").Count
    }

    Test-Case "AC-333 the nvidia-smi parser: 11924 gives 11924; N/A, empty, null and '11924 MiB' give null; only the first line counts" {
        Assert-Equal "11924" 11924 (ConvertFrom-HarnessNvidiaSmiOutput -Text "11924")
        Assert-Equal "11924 and a newline" 11924 (ConvertFrom-HarnessNvidiaSmiOutput -Text "11924`r`n")
        Assert-Equal "two GPUs" 11924 (ConvertFrom-HarnessNvidiaSmiOutput -Text "11924`r`n8000`r`n")
        Assert-True "N/A" ($null -eq (ConvertFrom-HarnessNvidiaSmiOutput -Text "N/A"))
        Assert-True "empty" ($null -eq (ConvertFrom-HarnessNvidiaSmiOutput -Text ""))
        Assert-True "null" ($null -eq (ConvertFrom-HarnessNvidiaSmiOutput -Text $null))
        Assert-True "with the unit" ($null -eq (ConvertFrom-HarnessNvidiaSmiOutput -Text "11924 MiB"))
        Assert-True "N/A first" ($null -eq (ConvertFrom-HarnessNvidiaSmiOutput -Text "N/A`r`n11924"))
    }

    Test-Case "AC-333 vramFreeMiB is null when nvidia-smi is absent, and a fake nvidia-smi answering 11924 gives 11924 through the real process helper" {
        Assert-True "absent" ($null -eq (Get-HarnessVramFreeMiB))
        $fake = Join-Path $binDirectory "nvidia-smi.cmd"
        [System.IO.File]::WriteAllText($fake, "@echo off`r`necho 11924`r`n", $utf8NoBom)
        try {
            Assert-Equal "present" 11924 (Get-HarnessVramFreeMiB)
            $run = Invoke-HarnessCase -Name "doctor-vram" -ConfigText (New-V2Config) -Arguments @("doctor", "-Json") -TagsSteps $tagsBoth -VersionSteps $versionOk
            Assert-Guards $run
            Assert-Equal "doctor vramFreeMiB" 11924 (Get-JsonOutput $run).vramFreeMiB
            [System.IO.File]::WriteAllText($fake, "@echo off`r`necho N/A`r`n", $utf8NoBom)
            Assert-True "N/A answer" ($null -eq (Get-HarnessVramFreeMiB))
            [System.IO.File]::WriteAllText($fake, "@echo off`r`necho 11924`r`nexit /b 3`r`n", $utf8NoBom)
            Assert-True "failing nvidia-smi" ($null -eq (Get-HarnessVramFreeMiB))
        }
        finally { Remove-Item -LiteralPath $fake -Force -ErrorAction SilentlyContinue }
        Assert-True "absent again" ($null -eq (Get-HarnessVramFreeMiB))
    }

    Test-Case "AC-333 the process helper stops a process that runs longer than its limit (5 s in doctor; 1 s here) and reports it" {
        $slow = Join-Path $binDirectory "slow-tool.cmd"
        [System.IO.File]::WriteAllText($slow, "@echo off`r`n`"%SystemRoot%\System32\ping.exe`" -n 6 127.0.0.1 >nul`r`necho 1`r`n", $utf8NoBom)
        try {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-HarnessCliProcess -FilePath $slow -Arguments "" -TimeoutSec 1
            $watch.Stop()
            Assert-Equal "started" "True" $result.started
            Assert-Equal "timed out" "True" $result.timedOut
            Assert-True "returned within 4 s ($($watch.ElapsedMilliseconds) ms)" ($watch.ElapsedMilliseconds -lt 4000)
            $missing = Invoke-HarnessCliProcess -FilePath (Join-Path $binDirectory "no-such-tool.exe") -Arguments "" -TimeoutSec 1
            Assert-Equal "a missing program does not throw and is not started" "False" $missing.started
        }
        finally { Remove-Item -LiteralPath $slow -Force -ErrorAction SilentlyContinue }
    }

    Test-Case "AC-333 doctor reports the lines of 'ollama ps' without a finding (a fake ollama), and null when ollama is absent or fails" {
        $fake = Join-Path $binDirectory "ollama.cmd"
        [System.IO.File]::WriteAllText($fake, "@echo off`r`necho NAME        SIZE     PROCESSOR    UNTIL`r`necho test-model-alpha    5.6 GB    100%% GPU    4 minutes from now`r`n", $utf8NoBom)
        try {
            $run = Invoke-HarnessCase -Name "doctor-ps" -ConfigText (New-V2Config) -Arguments @("doctor", "-Json") -TagsSteps $tagsBoth -VersionSteps $versionOk
            Assert-Guards $run
            Assert-Equal "exit" 0 $run.ExitCode
            $document = Get-JsonOutput $run
            Assert-Equal "ps lines" 2 @($document.ollama.ps).Count
            Assert-True "ps content" ($document.ollama.ps[1].Contains("100% GPU"))
            Assert-Equal "findings" 0 @($document.findings).Count
            $text = Invoke-HarnessCase -Name "doctor-ps-text" -ConfigText (New-V2Config) -Arguments @("doctor") -TagsSteps $tagsBoth -VersionSteps $versionOk
            Assert-Line $text "ollama ps:"
            Assert-Line $text "100% GPU"
            [System.IO.File]::WriteAllText($fake, "@echo off`r`nexit /b 1`r`n", $utf8NoBom)
            Assert-True "a failing ollama ps" ($null -eq (Get-HarnessOllamaPs))
        }
        finally { Remove-Item -LiteralPath $fake -Force -ErrorAction SilentlyContinue }
        Assert-True "ollama absent" ($null -eq (Get-HarnessOllamaPs))
    }

    Test-Case "AC-333 the load-check error has fixed wording from the category and the hint, and a null httpStatus (gate finding 13)" {
        $load = [pscustomobject]@{ loaded = $false; category = "timeout"; hint = "The model did not answer in time."; durationMs = 5 }
        $error = Get-HarnessLoadCheckError -LoadResult $load
        Assert-Equal "category" "timeout" $error.category
        Assert-Equal "message" "The model load check failed with the category 'timeout'. The model did not answer in time." $error.message
        Assert-Equal "hint" "The model did not answer in time." $error.hint
        Assert-True "httpStatus is null" ($null -eq $error.httpStatus)
    }

    Test-Case "AC-301 in-process cases never reached the network (Invoke-RestMethod shadow)" {
        Assert-Equal "violations" 0 $script:restViolations
    }
}
finally {
    $env:Path = $originalPath
    Set-Location -LiteralPath $originalLocation
    [System.Environment]::CurrentDirectory = $originalProcessDirectory
    Remove-Item Env:\HARNESS_TEST_VALIDATOR_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\HARNESS_TEST_VALIDATOR_CODE -ErrorAction SilentlyContinue
    Remove-Item Env:\HARNESS_TEST_STAGE_MARKER -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $junctionDir) { [System.IO.Directory]::Delete($junctionDir) }
    Restore-EngineSuite
}

Write-EngineSuiteSummary
if ($script:failed -eq 0) { exit 0 }
exit 1
