<#
.SYNOPSIS
    Single entry point for the AI-Dev-Harness regression suites.

.DESCRIPTION
    Discovers the standalone test suites (scripts\test-*.ps1), runs each one in
    its own Windows PowerShell 5.1 process, keeps going after failures, and
    prints a per-suite result and a final summary.

    DISCOVERY
      - Files directly in this directory, named test-*.ps1 (extension exactly
        .ps1, so *.bak backups are ignored). Not recursive: lib\, tests\ and
        anything not named test-*.ps1 is a helper and is never executed.
      - This script excludes itself. Reparse-point files are refused.
      - Order: the table's Order (default 50, live suites 90), then name.

    SUITE CONTRACT (a violation is a FAIL and the file is NOT executed)
      1. It parses.
      2. It has no mandatory parameters (it must run unattended).
      3. It contains an explicit exit statement.
      4. exit 0 = every assertion passed; any other exit code = failure.
      5. A suite that prints "SKIPPED_TESTS: <ids>" (or "Skipped: n", n > 0)
         reports assertions it could not verify; those are never counted as
         verified (result PASS WITH SKIPS).
      The verdict comes from the exit code. Output is only used to DOWNGRADE a
      PASS (exit 0 but the last "STATUS:" line is FAIL, or the last "Failed: n"
      has n > 0), never to upgrade a failure.

    RESULTS
      PASS             exit 0, nothing skipped, repository untouched
      PASS WITH SKIPS  exit 0, but the suite reports internally skipped tests
      FAIL             non-zero exit, timeout, contract violation, repository
                       modified by the suite, sandbox failure, unmet
                       precondition of a requested live suite, configuration error
      SKIPPED          not executed (NOT VERIFIED): live suite without
                       -IncludeLive, or a table entry with Skip

    ISOLATION
      - Isolation = 'sandbox' (table): the suite runs from a SHA-256 verified,
        byte-identical copy of scripts\ and tests\ in a temp sandbox, with
        TEMP/TMP redirected, so nothing it writes can reach the repository.
      - Repository tripwire (every executed suite): SHA-256 snapshot of the
        repository (excluding .git, not following reparse points) before and
        after the suite. Any added, removed or changed file fails the suite and
        its paths are reported. Nothing is ever restored, overwritten or
        deleted in the repository by this script.

    EXIT CODE
      0 only if there is no FAIL and at least one suite passed (PASS or
      PASS WITH SKIPS). Otherwise 1.

.PARAMETER IncludeLive
    Also run suites that require Ollama (table: Requires = 'ollama'). An unmet
    precondition is then a FAIL, never a skip.

.PARAMETER DefaultTimeoutSec
    Per-suite timeout when the table does not give one. On timeout the whole
    process tree is killed and the suite fails.

.PARAMETER ShowOutput
    Print the captured output of every suite, not only of failing ones.
#>
param(
    [switch]$IncludeLive,

    [ValidateRange(1, 86400)]
    [int]$DefaultTimeoutSec = 600,

    [switch]$ShowOutput
)

$ErrorActionPreference = "Stop"

$scriptsDirectory = $PSScriptRoot
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$selfPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($selfPath)) { $selfPath = $MyInvocation.MyCommand.Path }

# Suites always run under Windows PowerShell 5.1, whatever host launched this script.
$powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$taskKillExe = Join-Path $env:SystemRoot "System32\taskkill.exe"
if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
    throw "Windows PowerShell 5.1 not found: $powerShellExe"
}

$tempBase = [System.IO.Path]::GetTempPath()
$heartbeatSeconds = 60

# ---------------------------------------------------------------------------
# Explicit, justified per-suite settings. Suites not listed here run as plain
# offline suites with default settings.
#   Order      run order (default 50; live suites 90)
#   Requires   'ollama' = live suite: SKIPPED unless -IncludeLive
#   Model      literal model that must be installed for a requested live suite
#   ModelAgent agent whose model must be installed, resolved like that agent
#              resolves it (lib\config.ps1: AI_HARNESS_MODEL, agentModels,
#              defaultModel). A live entry has exactly one of Model or ModelAgent.
#   TimeoutSec per-suite timeout
#   Isolation  'sandbox' = run from a verified copy in a temp sandbox
#   Skip       justification: never executed, reported SKIPPED / NOT VERIFIED
#   Reason     mandatory justification for the entry
# ---------------------------------------------------------------------------
$suiteOverrides = @{
    "test-syntax.ps1" = @{
        Order  = 0
        Reason = "Cheap static gate; runs first."
    }
    "test-spec.ps1" = @{
        Isolation = "sandbox"
        Reason    = "Writes generated test-mock-* artifacts into <root>\specs (git-ignored and no longer tracked, but the repository tripwire would still flag them); runs from a verified byte-identical copy in a temp sandbox."
    }
    "test-mode-propagation.ps1" = @{
        Isolation = "sandbox"
        Reason    = "Runs specify.ps1 with recording mocks, which writes test-mock-mode-* artifacts into <root>\specs; runs from a verified byte-identical copy in a temp sandbox."
    }
    "test-spec-integration.ps1" = @{
        Requires   = "ollama"
        ModelAgent = "spec-reviewer"
        TimeoutSec = 3600
        Reason     = "Calls a real local model: slow, non-deterministic, needs Ollama and the spec-reviewer model resolved from the configuration, exactly as the reviewer resolves it."
    }
}
$allowedOverrideFields = @("Order", "Requires", "Model", "ModelAgent", "TimeoutSec", "Isolation", "Skip", "Reason")

$script:results = New-Object 'System.Collections.Generic.List[object]'
$script:runTemp = $null

# ---------------------------------------------------------------------------
# Result bookkeeping
# ---------------------------------------------------------------------------

function Add-SuiteResult {
    param(
        [string]$Name,
        [string]$Result,
        [string]$Detail = "",
        [bool]$Executed = $false,
        $ExitCode = $null,
        [double]$Seconds = 0,
        [string]$InternalSkips = "",
        [string]$Tripwire = "",
        [string]$Sandbox = ""
    )

    $script:results.Add([pscustomobject]@{
        Name          = $Name
        Result        = $Result
        Detail        = $Detail
        Executed      = $Executed
        ExitCode      = $ExitCode
        Seconds       = $Seconds
        InternalSkips = $InternalSkips
        Tripwire      = $Tripwire
        Sandbox       = $Sandbox
    })

    $color = switch ($Result) {
        "PASS"            { "Green" }
        "PASS WITH SKIPS" { "Yellow" }
        "SKIPPED"         { "Yellow" }
        default           { "Red" }
    }

    $line = "[{0}] {1}" -f $Result, $Name
    if ($Executed) {
        $line += ("  ({0:N1} s, exit {1})" -f $Seconds, $(if ($null -eq $ExitCode) { "-" } else { $ExitCode }))
    }
    Write-Host $line -ForegroundColor $color
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { Write-Host "    $Detail" -ForegroundColor $color }
    if (-not [string]::IsNullOrWhiteSpace($InternalSkips)) {
        Write-Host "    internal skips (NOT verified): $InternalSkips" -ForegroundColor Yellow
    }
    if (-not [string]::IsNullOrWhiteSpace($Sandbox)) { Write-Host "    sandbox : $Sandbox" }
    if (-not [string]::IsNullOrWhiteSpace($Tripwire)) { Write-Host "    tripwire: $Tripwire" }
}

function Write-CapturedOutput {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { Write-Host "    (no output captured)"; return }
    Write-Host "    ----- suite output -----"
    foreach ($line in ($Text -split "\r?\n")) { Write-Host "    | $line" }
    Write-Host "    ----- end of suite output -----"
}

# ---------------------------------------------------------------------------
# Static contract checks (parse only; nothing is executed)
# ---------------------------------------------------------------------------

function Get-ContractViolations {
    param([string]$Path)

    $violations = @()
    $tokens = $null
    $parseErrors = $null

    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    }
    catch {
        return @("could not be parsed: $($_.Exception.Message)")
    }

    if (@($parseErrors).Count -gt 0) {
        foreach ($parseError in @($parseErrors | Select-Object -First 3)) {
            $violations += "syntax error at line $($parseError.Extent.StartLineNumber): $($parseError.Message)"
        }
        return $violations
    }

    if ($null -ne $ast.ParamBlock) {
        foreach ($parameter in $ast.ParamBlock.Parameters) {
            foreach ($attribute in $parameter.Attributes) {
                if ($attribute.GetType().Name -ne "AttributeAst") { continue }
                if ($attribute.TypeName.Name -ne "Parameter") { continue }
                foreach ($named in $attribute.NamedArguments) {
                    if ($named.ArgumentName -eq "Mandatory" -and
                        ($named.ExpressionOmitted -or $named.Argument.Extent.Text -eq '$true')) {
                        $violations += "has mandatory parameter -$($parameter.Name.VariablePath.UserPath) (a suite must run without arguments)"
                    }
                }
            }
        }
    }

    $exits = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ExitStatementAst]
    }, $true))
    if ($exits.Count -eq 0) {
        $violations += "contains no explicit exit statement (it cannot report its outcome by exit code)"
    }

    return $violations
}

# A live entry (Requires = 'ollama') needs exactly one of Model or ModelAgent,
# as a non-blank string. Uses only the table, never .ai\config.json.
function Get-LiveEntryProblem {
    param([hashtable]$Entry)

    $fields = @(@("Model", "ModelAgent") | Where-Object { $Entry.ContainsKey($_) })
    if ($fields.Count -ne 1) {
        return "Requires = 'ollama' needs exactly one of Model or ModelAgent"
    }
    $value = $Entry[$fields[0]]
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
        return "$($fields[0]) must be a non-blank string"
    }
    return ""
}

function Get-OverrideProblems {
    param([string[]]$DiscoveredNames)

    $problems = @()
    foreach ($key in $suiteOverrides.Keys) {
        $entry = $suiteOverrides[$key]

        if ($DiscoveredNames -notcontains $key) {
            $problems += "table entry '$key' matches no discovered suite (renamed or removed?)"
        }
        foreach ($field in $entry.Keys) {
            if ($allowedOverrideFields -notcontains $field) { $problems += "table entry '$key' has unknown field '$field'" }
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.Reason)) { $problems += "table entry '$key' has no Reason" }
        if ($entry.ContainsKey("Requires")) {
            if ($entry.Requires -ne "ollama") { $problems += "table entry '$key': Requires must be 'ollama'" }
            else {
                $liveProblem = Get-LiveEntryProblem -Entry $entry
                if ($liveProblem) { $problems += "table entry '$key': $liveProblem" }
            }
        }
        if ($entry.ContainsKey("Isolation") -and $entry.Isolation -ne "sandbox") { $problems += "table entry '$key': Isolation must be 'sandbox'" }
        if ($entry.ContainsKey("Skip") -and [string]::IsNullOrWhiteSpace([string]$entry.Skip)) { $problems += "table entry '$key': Skip needs a justification" }
        if ($entry.ContainsKey("Order") -and $entry.Order -isnot [int]) { $problems += "table entry '$key': Order must be an integer" }
        if ($entry.ContainsKey("TimeoutSec") -and ($entry.TimeoutSec -isnot [int] -or $entry.TimeoutSec -lt 1)) { $problems += "table entry '$key': TimeoutSec must be a positive integer" }
    }
    return $problems
}

# ---------------------------------------------------------------------------
# Output cross-checks (can only downgrade a PASS)
# ---------------------------------------------------------------------------

function Get-OutputContradiction {
    param([string]$Output)

    $status = [regex]::Matches($Output, '(?m)^\s*STATUS:[ \t]*([A-Za-z]+)')
    if ($status.Count -gt 0 -and $status[$status.Count - 1].Groups[1].Value -ceq "FAIL") {
        return "exit code 0 but the suite's last STATUS line is FAIL"
    }

    $failed = [regex]::Matches($Output, '(?m)(?:^|\|[ \t]*)Failed:[ \t]*(\d+)')
    if ($failed.Count -gt 0 -and [int]$failed[$failed.Count - 1].Groups[1].Value -gt 0) {
        return "exit code 0 but the suite reports 'Failed: $($failed[$failed.Count - 1].Groups[1].Value)'"
    }
    return ""
}

function Get-InternalSkips {
    param([string]$Output)

    $listed = [regex]::Matches($Output, '(?m)^SKIPPED_TESTS:[ \t]*(.+?)[ \t\r]*$')
    if ($listed.Count -gt 0) {
        $value = $listed[$listed.Count - 1].Groups[1].Value.Trim()
        if ($value -ceq "none") { return "" }
        return $value
    }

    $counted = [regex]::Matches($Output, '(?m)(?:^|\|[ \t]*)Skipped:[ \t]*([1-9]\d*)')
    if ($counted.Count -gt 0) {
        return "$($counted[$counted.Count - 1].Groups[1].Value) skipped (ids not reported by the suite)"
    }
    return ""
}

# ---------------------------------------------------------------------------
# Repository tripwire
# ---------------------------------------------------------------------------

# Returns a dictionary: relative path -> fingerprint. .git at the repository
# root is excluded; reparse points are recorded but never followed.
function Get-RepoSnapshot {
    param([string]$Root)

    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $rootInfo = New-Object System.IO.DirectoryInfo -ArgumentList $Root
    $rootTrimmed = $rootInfo.FullName.TrimEnd('\')
    $prefix = $rootTrimmed + '\'
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push($rootInfo)
    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        while ($stack.Count -gt 0) {
            $directory = $stack.Pop()
            $isRoot = ($directory.FullName.TrimEnd('\') -ieq $rootTrimmed)

            try { $children = @($directory.EnumerateFileSystemInfos()) }
            catch {
                $key = $directory.FullName.Substring([math]::Min($prefix.Length, $directory.FullName.Length)).Replace('\', '/')
                $map[$key] = "dir|unreadable"
                continue
            }

            foreach ($child in $children) {
                $relative = $child.FullName.Substring($prefix.Length).Replace('\', '/')
                $isDirectory = (($child.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
                $isLink = (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

                if ($isDirectory -and $isRoot -and $child.Name -ieq ".git") { continue }
                if ($isLink) { $map[$relative] = "reparse"; continue }
                if ($isDirectory) {
                    $map[$relative] = "dir"
                    $stack.Push([System.IO.DirectoryInfo]$child)
                    continue
                }

                try {
                    $stream = [System.IO.File]::Open($child.FullName,
                        [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    try {
                        $hash = [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace("-", "")
                        $length = ([System.IO.FileInfo]$child).Length
                    }
                    finally { $stream.Dispose() }
                    $map[$relative] = "file|$length|$hash"
                }
                catch { $map[$relative] = "file|unreadable" }
            }
        }
    }
    finally { $sha.Dispose() }

    return ,$map
}

function Compare-RepoSnapshot {
    param($Before, $After)

    $added = @(); $removed = @(); $changed = @()
    foreach ($key in $After.Keys) {
        if (-not $Before.ContainsKey($key)) { $added += $key }
        elseif ($Before[$key] -cne $After[$key]) { $changed += $key }
    }
    foreach ($key in $Before.Keys) {
        if (-not $After.ContainsKey($key)) { $removed += $key }
    }

    return [pscustomobject]@{
        Added   = $added
        Removed = $removed
        Changed = $changed
        Any     = (($added.Count + $removed.Count + $changed.Count) -gt 0)
    }
}

function Format-PathList {
    param([string[]]$Items)
    $shown = @($Items | Select-Object -First 10)
    $text = $shown -join ", "
    if ($Items.Count -gt 10) { $text += " (+$($Items.Count - 10) more)" }
    return $text
}

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------

function Get-FileSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { return [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace("-", "") }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

function Get-RunTempRoot {
    if ($null -eq $script:runTemp) {
        $script:runTemp = Join-Path $tempBase ("ai-harness-test-all-" + [guid]::NewGuid().ToString())
        [void][System.IO.Directory]::CreateDirectory($script:runTemp)
    }
    return $script:runTemp
}

# Copies scripts\ and tests\ (read-only on the repository, links skipped) into
# a temp sandbox and verifies every copied file by SHA-256. Throws on any problem.
function New-VerifiedSandbox {
    param([string]$SuiteFileName)

    $sandboxRoot = Join-Path (Get-RunTempRoot) ("sandbox-" + [System.IO.Path]::GetFileNameWithoutExtension($SuiteFileName))
    $tmp = Join-Path $sandboxRoot "tmp"
    [void][System.IO.Directory]::CreateDirectory($tmp)

    $pairs = New-Object 'System.Collections.Generic.List[object]'

    foreach ($name in @("scripts", "tests")) {
        $sourceRoot = Join-Path $repoRoot $name
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { continue }

        $stack = New-Object 'System.Collections.Generic.Stack[object]'
        $stack.Push(@($sourceRoot, (Join-Path $sandboxRoot $name)))

        while ($stack.Count -gt 0) {
            $item = $stack.Pop()
            [void][System.IO.Directory]::CreateDirectory($item[1])

            foreach ($child in (New-Object System.IO.DirectoryInfo -ArgumentList $item[0]).EnumerateFileSystemInfos()) {
                if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $target = Join-Path $item[1] $child.Name
                if (($child.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                    $stack.Push(@($child.FullName, $target))
                }
                else {
                    [System.IO.File]::Copy($child.FullName, $target, $false)
                    $pairs.Add(@($child.FullName, $target))
                }
            }
        }
    }

    if ($pairs.Count -eq 0) { throw "sandbox verification failed: nothing was copied" }

    foreach ($pair in $pairs) {
        if ((Get-FileSha256 $pair[0]) -cne (Get-FileSha256 $pair[1])) {
            throw "sandbox verification failed: copy differs from source: $($pair[0])"
        }
    }

    $suiteCopy = Join-Path $sandboxRoot ("scripts\" + $SuiteFileName)
    $suiteSource = Join-Path $repoRoot ("scripts\" + $SuiteFileName)
    if (-not (Test-Path -LiteralPath $suiteCopy -PathType Leaf) -or
        (Get-FileSha256 $suiteCopy) -cne (Get-FileSha256 $suiteSource)) {
        throw "sandbox verification failed: the suite copy is not byte-identical to $suiteSource"
    }

    return [pscustomobject]@{
        Root      = $sandboxRoot
        Tmp       = $tmp
        FileCount = $pairs.Count
        SuiteCopy = $suiteCopy
        Sha256    = (Get-FileSha256 $suiteCopy)
    }
}

# Deletes the run's temp tree (sandboxes). Links are removed first without
# recursion; the path must sit directly under the temp folder with our prefix.
function Remove-RunTemp {
    if ($null -eq $script:runTemp) { return "" }

    $full = [System.IO.Path]::GetFullPath($script:runTemp).TrimEnd('\')
    $parent = Split-Path -Parent $full
    $leaf = Split-Path -Leaf $full
    if (-not (($parent -ieq [System.IO.Path]::GetFullPath($tempBase).TrimEnd('\')) -and ($leaf -like "ai-harness-test-all-*"))) {
        return "refusing to delete unexpected path: $full"
    }
    if (-not (Test-Path -LiteralPath $full)) { return "" }

    $links = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push((New-Object System.IO.DirectoryInfo -ArgumentList $full))
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        foreach ($child in $directory.EnumerateFileSystemInfos()) {
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $links.Add($child.FullName) }
            elseif (($child.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) { $stack.Push([System.IO.DirectoryInfo]$child) }
        }
    }
    foreach ($link in $links) {
        try {
            if ([System.IO.Directory]::Exists($link)) { [System.IO.Directory]::Delete($link) }
            else { [System.IO.File]::Delete($link) }
        }
        catch { }
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try { Remove-Item -LiteralPath $full -Recurse -Force; break }
        catch { if ($attempt -eq 1) { Start-Sleep -Milliseconds 500 } }
    }

    if (Test-Path -LiteralPath $full) { return "could not remove temp directory: $full" }
    return ""
}

# ---------------------------------------------------------------------------
# Process execution
# ---------------------------------------------------------------------------

function Invoke-SuiteProcess {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [int]$TimeoutSec,
        [string]$WorkingDirectory,
        [hashtable]$EnvironmentVariables
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellExe
    $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($key in $EnvironmentVariables.Keys) {
        $startInfo.EnvironmentVariables[$key] = [string]$EnvironmentVariables[$key]
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $timedOut = $false
    $exitCode = $null
    $output = ""

    try {
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $finished = $false
        while ($true) {
            $remaining = ($TimeoutSec * 1000) - $stopwatch.ElapsedMilliseconds
            if ($remaining -le 0) { break }
            $slice = [int][math]::Min($heartbeatSeconds * 1000, $remaining)
            if ($process.WaitForExit($slice)) { $finished = $true; break }
            Write-Host ("    ... still running: {0} ({1:N0} s)" -f $Name, $stopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        }

        if (-not $finished) {
            $timedOut = $true
            $previous = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try { [void](& $taskKillExe /PID $process.Id /T /F 2>&1) } finally { $ErrorActionPreference = $previous }
            [void]$process.WaitForExit(10000)
        }
        else {
            $process.WaitForExit()
            $exitCode = $process.ExitCode
        }

        $out = ""
        $err = ""
        if ($stdoutTask.Wait(10000)) { $out = $stdoutTask.Result } else { $out = "(stdout not fully captured)" }
        if ($stderrTask.Wait(10000)) { $err = $stderrTask.Result } else { $err = "(stderr not fully captured)" }
        $output = $out
        if (-not [string]::IsNullOrWhiteSpace($err)) { $output += "`n--- stderr ---`n" + $err }
    }
    finally {
        $stopwatch.Stop()
        $process.Dispose()
    }

    return [pscustomobject]@{
        TimedOut = $timedOut
        ExitCode = $exitCode
        Output   = $output
        Seconds  = $stopwatch.Elapsed.TotalSeconds
    }
}

# Returns $null when the live precondition is met, otherwise the reason it is not.
function Test-OllamaPrecondition {
    param([string]$Model)

    $url = "http://localhost:11434"
    $configPath = Join-Path $repoRoot ".ai\config.json"
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $config = [System.IO.File]::ReadAllText($configPath, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
            if ($config.PSObject.Properties["ollamaUrl"] -and -not [string]::IsNullOrWhiteSpace([string]$config.ollamaUrl)) {
                $url = ([string]$config.ollamaUrl).TrimEnd('/')
            }
        }
        catch { return "could not read .ai\config.json: $($_.Exception.Message)" }
    }

    try { $tags = Invoke-RestMethod -Uri "$url/api/tags" -Method Get -TimeoutSec 5 }
    catch { return "Ollama is not reachable at $url ($($_.Exception.Message))" }

    $installed = @($tags.models | ForEach-Object { $_.name })
    if (-not [string]::IsNullOrWhiteSpace($Model) -and ($installed -notcontains $Model)) {
        return "model '$Model' is not installed at $url"
    }
    return $null
}

# Resolves the model of a live entry's ModelAgent on a best-effort basis, with
# the agent's own chain (lib\config.ps1: AI_HARNESS_MODEL, agentModels,
# defaultModel). Never throws: a failure is returned as a reason. Sends nothing.
function Resolve-LiveSuiteModel {
    param([string]$Agent)

    try {
        $libPath = Join-Path $scriptsDirectory "lib\config.ps1"
        if (-not (Test-Path -LiteralPath $libPath -PathType Leaf)) { throw "lib\config.ps1 not found: $libPath" }
        . $libPath
        $config = Get-HarnessConfig -ConfigPath (Join-Path $repoRoot ".ai\config.json")
        $model = "$(Resolve-HarnessModel -Agent $Agent -ModelWasProvided $false -Config $config)".Trim()
        if ([string]::IsNullOrWhiteSpace($model)) { throw "the resolved model is empty" }
        return [pscustomobject]@{ Model = $model; Problem = "" }
    }
    catch {
        return [pscustomobject]@{ Model = ""; Problem = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------
# One suite
# ---------------------------------------------------------------------------

function Invoke-Suite {
    param($Suite)

    $override = $Suite.Override
    $has = { param($field) ($null -ne $override) -and $override.ContainsKey($field) }

    # 1. Static contract (applies even to suites that will not be executed).
    $violations = @(Get-ContractViolations -Path $Suite.Path)
    if ($violations.Count -gt 0) {
        Add-SuiteResult $Suite.Name "FAIL" ("contract violation, NOT executed: " + ($violations -join "; "))
        return
    }
    if ((([System.IO.File]::GetAttributes($Suite.Path)) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Add-SuiteResult $Suite.Name "FAIL" "contract violation, NOT executed: the suite file is a reparse point"
        return
    }

    # 2. Explicit exclusions and live suites.
    if (& $has "Skip") {
        Add-SuiteResult $Suite.Name "SKIPPED" "NOT VERIFIED (not executed): $($override.Skip)"
        return
    }
    if (& $has "Requires") {
        # An invalid live entry is never executed and its precondition never runs.
        $entryProblem = Get-LiveEntryProblem -Entry $override
        if ($entryProblem) {
            if ($IncludeLive) {
                Add-SuiteResult $Suite.Name "FAIL" "invalid table entry, NOT executed: $entryProblem"
            }
            else {
                Add-SuiteResult $Suite.Name "SKIPPED" "NOT VERIFIED (not executed): invalid table entry: $entryProblem"
            }
            return
        }

        # Best-effort model resolution (FR-014). Offline it only names the model;
        # with -IncludeLive a failure is a FAIL and no request is sent.
        $liveModel = [string]$override.Model
        $modelText = "model '$liveModel'"
        if (& $has "ModelAgent") {
            $resolution = Resolve-LiveSuiteModel -Agent $override.ModelAgent
            if ($resolution.Problem) {
                $resolutionFailure = "model could not be resolved (agent '$($override.ModelAgent)'): $($resolution.Problem)"
                if ($IncludeLive) {
                    Add-SuiteResult $Suite.Name "FAIL" "precondition not met, NOT executed: $resolutionFailure"
                }
                else {
                    Add-SuiteResult $Suite.Name "SKIPPED" "NOT VERIFIED (not executed): $resolutionFailure; use -IncludeLive. $($override.Reason)"
                }
                return
            }
            $liveModel = $resolution.Model
            $modelText = "model '$liveModel' (agent '$($override.ModelAgent)')"
        }

        if (-not $IncludeLive) {
            Add-SuiteResult $Suite.Name "SKIPPED" "NOT VERIFIED (not executed): requires Ollama and $modelText; use -IncludeLive. $($override.Reason)"
            return
        }
        $unmet = Test-OllamaPrecondition -Model $liveModel
        if ($unmet) {
            Add-SuiteResult $Suite.Name "FAIL" "precondition not met, NOT executed: $unmet ($modelText)"
            return
        }
    }

    # 3. Execution, with sandbox and tripwire.
    $timeout = $DefaultTimeoutSec
    if (& $has "TimeoutSec") { $timeout = [int]$override.TimeoutSec }

    $scriptToRun = $Suite.Path
    $workingDirectory = $repoRoot
    $environment = @{}
    $sandboxText = ""

    if ((& $has "Isolation") -and $override.Isolation -eq "sandbox") {
        try { $sandbox = New-VerifiedSandbox -SuiteFileName $Suite.Name }
        catch {
            Add-SuiteResult $Suite.Name "FAIL" "NOT executed: $($_.Exception.Message)"
            return
        }
        $scriptToRun = $sandbox.SuiteCopy
        $workingDirectory = $sandbox.Root
        $environment = @{ TEMP = $sandbox.Tmp; TMP = $sandbox.Tmp }
        $sandboxText = "$($sandbox.FileCount) files copied, every SHA-256 verified; suite copy byte-identical (SHA-256 $($sandbox.Sha256)); TEMP/TMP redirected"
    }

    $before = Get-RepoSnapshot -Root $repoRoot
    $run = Invoke-SuiteProcess -Name $Suite.Name -ScriptPath $scriptToRun -TimeoutSec $timeout `
        -WorkingDirectory $workingDirectory -EnvironmentVariables $environment
    $after = Get-RepoSnapshot -Root $repoRoot
    $diff = Compare-RepoSnapshot -Before $before -After $after

    $tripwireText = "clean ($($before.Count) entries before, $($after.Count) after)"
    $problems = @()

    if ($diff.Any) {
        $parts = @()
        if ($diff.Added.Count -gt 0) { $parts += "added: " + (Format-PathList $diff.Added) }
        if ($diff.Removed.Count -gt 0) { $parts += "removed: " + (Format-PathList $diff.Removed) }
        if ($diff.Changed.Count -gt 0) { $parts += "changed: " + (Format-PathList $diff.Changed) }
        $tripwireText = "VIOLATION - " + ($parts -join "; ")
        $problems += "modified the repository (" + ($parts -join "; ") + "); nothing was restored. If you edited files during the run, re-run with the tree idle"
    }

    $skips = ""
    if ($run.TimedOut) {
        $problems = @("timed out after $timeout s (process tree killed)") + $problems
    }
    elseif ($run.ExitCode -ne 0) {
        $problems = @("exit code $($run.ExitCode)") + $problems
    }
    else {
        $contradiction = Get-OutputContradiction -Output $run.Output
        if ($contradiction) { $problems = @($contradiction) + $problems }
        $skips = Get-InternalSkips -Output $run.Output
    }

    if ($problems.Count -gt 0) {
        Add-SuiteResult $Suite.Name "FAIL" ($problems -join " | ") $true $run.ExitCode $run.Seconds "" $tripwireText $sandboxText
        Write-CapturedOutput $run.Output
        return
    }

    $result = "PASS"
    if ($skips) { $result = "PASS WITH SKIPS" }
    Add-SuiteResult $Suite.Name $result "" $true $run.ExitCode $run.Seconds $skips $tripwireText $sandboxText

    if ($ShowOutput) {
        Write-CapturedOutput $run.Output
    }
    else {
        $tail = @(($run.Output -split "\r?\n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 5)
        foreach ($line in $tail) { Write-Host "    | $line" -ForegroundColor DarkGray }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "            TEST-ALL RUNNER" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Suites directory : $scriptsDirectory"
Write-Host "Repository root  : $repoRoot"
Write-Host "Live suites      : $(if ($IncludeLive) { 'INCLUDED (-IncludeLive)' } else { 'not included (use -IncludeLive)' })"

$suites = New-Object 'System.Collections.Generic.List[object]'
$discoveredCount = 0

try {
    $candidates = @(Get-ChildItem -LiteralPath $scriptsDirectory -File -Force |
        Where-Object {
            $_.Name -like "test-*.ps1" -and
            $_.Extension -eq ".ps1" -and
            -not [string]::Equals($_.FullName, $selfPath, [System.StringComparison]::OrdinalIgnoreCase)
        })
    $discoveredCount = $candidates.Count

    foreach ($file in $candidates) {
        $override = $suiteOverrides[$file.Name]
        $order = 50
        if ($null -ne $override -and $override.ContainsKey("Requires")) { $order = 90 }
        if ($null -ne $override -and $override.ContainsKey("Order") -and $override.Order -is [int]) { $order = $override.Order }

        $suites.Add([pscustomobject]@{
            Name     = $file.Name
            Path     = $file.FullName
            Override = $override
            Order    = $order
        })
    }

    $suites.Sort([System.Comparison[object]]{
        param($a, $b)
        if ($a.Order -ne $b.Order) { return $a.Order.CompareTo($b.Order) }
        return [string]::Compare($a.Name, $b.Name, [System.StringComparison]::OrdinalIgnoreCase)
    })

    Write-Host "Suites discovered: $discoveredCount"
    foreach ($suite in $suites) { Write-Host "  - $($suite.Name)" }

    # Configuration problems and an empty discovery are failures, not silent passes.
    Write-Host ""
    foreach ($problem in @(Get-OverrideProblems -DiscoveredNames @($candidates | ForEach-Object { $_.Name }))) {
        Add-SuiteResult "test-all configuration" "FAIL" $problem
    }
    if ($discoveredCount -eq 0) {
        Add-SuiteResult "test-all discovery" "FAIL" "no test suites (test-*.ps1) found in $scriptsDirectory"
    }

    $index = 0
    foreach ($suite in $suites) {
        $index++
        Write-Host ""
        Write-Host "=== [$index/$($suites.Count)] $($suite.Name) ===" -ForegroundColor Cyan
        try { Invoke-Suite -Suite $suite }
        catch { Add-SuiteResult $suite.Name "FAIL" "test-all internal error: $($_.Exception.Message)" }
    }
}
catch {
    Add-SuiteResult "test-all internal error" "FAIL" $_.Exception.Message
}
finally {
    $cleanupProblem = Remove-RunTemp
    if ($cleanupProblem) { Add-SuiteResult "test-all cleanup" "FAIL" $cleanupProblem }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$passList = @($script:results | Where-Object { $_.Result -eq "PASS" })
$skipPassList = @($script:results | Where-Object { $_.Result -eq "PASS WITH SKIPS" })
$failList = @($script:results | Where-Object { $_.Result -eq "FAIL" })
$skippedList = @($script:results | Where-Object { $_.Result -eq "SKIPPED" })
$executedCount = @($script:results | Where-Object { $_.Executed }).Count

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "          TEST-ALL SUMMARY" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

foreach ($result in $script:results) {
    $color = switch ($result.Result) {
        "PASS"            { "Green" }
        "PASS WITH SKIPS" { "Yellow" }
        "SKIPPED"         { "Yellow" }
        default           { "Red" }
    }
    $tail = ""
    if ($result.Executed) { $tail = ("  {0:N1} s  exit {1}" -f $result.Seconds, $result.ExitCode) }
    Write-Host ("{0,-16} {1}{2}" -f ("[" + $result.Result + "]"), $result.Name, $tail) -ForegroundColor $color
}

Write-Host ""
Write-Host ("VERIFIED THIS RUN (executed) : {0} suites -> {1} PASS, {2} PASS WITH SKIPS, {3} FAIL" -f `
    $executedCount, $passList.Count, $skipPassList.Count, @($script:results | Where-Object { $_.Executed -and $_.Result -eq "FAIL" }).Count)

if ($skippedList.Count -gt 0) {
    Write-Host ("NOT VERIFIED (not executed)  : {0} suites" -f $skippedList.Count) -ForegroundColor Yellow
    foreach ($result in $skippedList) { Write-Host "    - $($result.Name): $($result.Detail)" -ForegroundColor Yellow }
}
else {
    Write-Host "NOT VERIFIED (not executed)  : 0 suites"
}

if ($skipPassList.Count -gt 0) {
    Write-Host "INTERNALLY SKIPPED ASSERTIONS (NOT verified):" -ForegroundColor Yellow
    foreach ($result in $skipPassList) { Write-Host "    - $($result.Name): $($result.InternalSkips)" -ForegroundColor Yellow }
}

Write-Host ""
Write-Host ("Suites discovered: {0} | Executed: {1} | Passed: {2} | Passed with skips: {3} | Failed: {4} | Skipped: {5}" -f `
    $discoveredCount, $executedCount, $passList.Count, $skipPassList.Count, $failList.Count, $skippedList.Count)

if ($failList.Count -gt 0) { Write-Host "FAILED_SUITES: $((@($failList | ForEach-Object { $_.Name })) -join ', ')" }
else { Write-Host "FAILED_SUITES: none" }

if ($skippedList.Count -gt 0) { Write-Host "SKIPPED_SUITES: $((@($skippedList | ForEach-Object { $_.Name })) -join ', ')" }
else { Write-Host "SKIPPED_SUITES: none" }

$verified = $passList.Count + $skipPassList.Count
if ($failList.Count -eq 0 -and $verified -ge 1) {
    if ($skipPassList.Count -gt 0 -or $skippedList.Count -gt 0) {
        Write-Host "STATUS: PASS WITH SKIPS" -ForegroundColor Yellow
    }
    else {
        Write-Host "STATUS: PASS" -ForegroundColor Green
    }
    exit 0
}

if ($failList.Count -eq 0) {
    Write-Host "No suite was verified in this run (nothing passed)." -ForegroundColor Red
}
Write-Host "STATUS: FAIL" -ForegroundColor Red
exit 1
