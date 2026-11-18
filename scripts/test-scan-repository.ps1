<#
.SYNOPSIS
    Regression suite for scripts\scan-repository.ps1.

.DESCRIPTION
    Pins the scanner's CURRENT behaviour against fixture repositories that are
    created in a temporary workspace outside the repository:

        %TEMP%\ai-harness-scanner-tests-<guid>\
            repos\main  repos\ordering  repos\empty  repos\single  repos\odd [x] name
            outside\target\outside-marker.txt   (junction target; inside the
                                                 workspace, outside every scanned root)
            outside\target-file.txt             (file symlink target)
            outputs\                            (all manifests are written here)

    Each test ends as exactly one of:
        PASS     the assertion held
        FAIL     the scanner behaved wrongly
        SKIPPED  the environment genuinely cannot create a needed capability
                 (the exact reason is recorded; a skip is never counted as a pass)
    A fixture/setup problem aborts the run with exit code 1.

    The last lines of output are machine readable:
        Passed: n | Failed: n | Skipped: n
        FAILED_TESTS: S07,S08          (or "none")
        SKIPPED_TESTS: S12 (reason)    (or "none")
        STATUS: PASS | FAIL

    Exit codes: 0 = no failures (skips allowed), 1 = at least one failure or abort.

    Safety: before the workspace is deleted recursively, every junction and
    symlink is removed first WITHOUT recursion and the link targets are verified
    to be intact (Windows PowerShell 5.1 can follow junctions when deleting
    recursively). The workspace path is also guarded to live directly under the
    temp directory with the expected name prefix.

.PARAMETER ScannerPath
    Scanner script to test. Defaults to scan-repository.ps1 next to this file.
    This is a test-only seam: it lets the suite run against modified temporary
    copies of the scanner (mutation testing). The scanner itself has no seam.
#>
param(
    [string]$ScannerPath = (Join-Path $PSScriptRoot "scan-repository.ps1")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ScannerPath -PathType Leaf)) {
    throw "Scanner under test not found: $ScannerPath"
}

$scannerFull = [System.IO.Path]::GetFullPath(
    (Resolve-Path -LiteralPath $ScannerPath).ProviderPath)

# Always test under Windows PowerShell 5.1, regardless of the host running the suite.
$powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
    throw "Windows PowerShell 5.1 not found: $powerShellExe"
}

$commandShell = $env:ComSpec
if ([string]::IsNullOrWhiteSpace($commandShell)) { $commandShell = "cmd.exe" }

# ---------------------------------------------------------------------------
# Fixture definition (expectations are literals on purpose)
# ---------------------------------------------------------------------------

# The scanner's directory exclusions (19 names, case-insensitive, any depth).
$excludedDirectoryNames = @(
    ".git", "node_modules", "vendor", "dist", "build", "coverage",
    ".next", ".nuxt", ".output", ".venv", "venv", "__pycache__",
    "bin", "obj", "logs", ".aws", ".ssh", ".kube", ".azure"
)

# Excluded file names, one or more per scanner pattern, including case variants.
$excludedFileNames = @(
    ".env", ".env.local", ".ENV.TEST",
    "server.pem", "private.key", "cert.p12", "cert.pfx", "putty.ppk", "UPPER.PEM",
    "id_rsa", "id_rsa.pub", "id_ed25519", "ID_ED25519.old",
    "old.bak", "snapshot.backup", "scratch.tmp", "edit.swp", "CASE.BAK",
    "credentials", "credentials.json", "secrets", "secrets.yml", "SECRETS.TXT",
    ".npmrc", ".pypirc", ".netrc"
)

# Built from char codes so this file stays pure ASCII.
$unicodeName = "caf" + [char]0x00E9 + ".txt"

# Files the scanner must list for repos\main (size = exact byte count written).
$includedFiles = @(
    @{ Path = "README.md";         Size = 11 },
    @{ Path = "src/app.ts";        Size = 22 },
    @{ Path = "src/lib/util.ts";   Size = 33 },
    @{ Path = "docs/guide.md";     Size = 44 },
    @{ Path = "builder/keep.md";   Size = 5 },
    @{ Path = "variants/keep.txt"; Size = 6 },
    @{ Path = "environment.md";    Size = 7 },
    @{ Path = "id_rsa_notes.md";   Size = 8 },
    @{ Path = "keyboard.md";       Size = 9 },
    @{ Path = ".editorconfig";     Size = 10 },
    @{ Path = $unicodeName;        Size = 13 },
    @{ Path = "empty.txt";         Size = 0 }
)
$expectedFileCount = 12
$expectedTotalBytes = 168    # 11+22+33+44+5+6+7+8+9+10+13+0

# Scanned directories in repos\main: root, src, src\lib, docs, builder, variants,
# emptydir. Excluded directories, the junction and everything inside them do not count.
$expectedDirectoryCount = 7

# ---------------------------------------------------------------------------
# Workspace paths
# ---------------------------------------------------------------------------

$tempBase = [System.IO.Path]::GetTempPath()
$workspace = Join-Path $tempBase ("ai-harness-scanner-tests-" + [guid]::NewGuid().ToString())

$paths = @{
    Workspace     = $workspace
    Main          = Join-Path $workspace "repos\main"
    Ordering      = Join-Path $workspace "repos\ordering"
    Empty         = Join-Path $workspace "repos\empty"
    Single        = Join-Path $workspace "repos\single"
    Odd           = Join-Path $workspace "repos\odd [x] name"
    Outputs       = Join-Path $workspace "outputs"
    OutsideTarget = Join-Path $workspace "outside\target"
    Marker        = Join-Path $workspace "outside\target\outside-marker.txt"
    OutsideFile   = Join-Path $workspace "outside\target-file.txt"
    Junction      = Join-Path $workspace "repos\main\linked-dir"
    Symlink       = Join-Path $workspace "repos\main\linked-file.txt"
}

$script:workspaceCreated = $false
$script:junctionInfo = [pscustomobject]@{ Created = $false; Reason = "not attempted" }
$script:symlinkInfo = [pscustomobject]@{ Created = $false; Reason = "not attempted" }
$script:mainScan = $null
$script:results = New-Object 'System.Collections.Generic.List[object]'
$script:skipToken = "__SKIP__:"
$script:aborted = $false

# ---------------------------------------------------------------------------
# Test framework
# ---------------------------------------------------------------------------

function Add-Result {
    param([string]$Id, [string]$Name, [string]$Outcome, [string]$Detail = "")

    $script:results.Add([pscustomobject]@{
        Id = $Id; Name = $Name; Outcome = $Outcome; Detail = $Detail
    })

    $color = switch ($Outcome) {
        "PASS"    { "Green" }
        "SKIPPED" { "Yellow" }
        default   { "Red" }
    }

    Write-Host "RESULT: $Outcome" -ForegroundColor $color
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        Write-Host "        $Detail" -ForegroundColor $color
    }
}

function Skip-Test {
    param([string]$Reason)
    throw ($script:skipToken + $Reason)
}

function Invoke-Test {
    param([string]$Id, [string]$Name, [scriptblock]$Body)

    Write-Host ""
    Write-Host "=== $Id - $Name ===" -ForegroundColor Cyan

    try {
        & $Body
    }
    catch {
        $message = $_.Exception.Message
        if ($message.StartsWith($script:skipToken)) {
            Add-Result $Id $Name "SKIPPED" $message.Substring($script:skipToken.Length)
        }
        else {
            Add-Result $Id $Name "FAIL" $message
        }
        return
    }

    Add-Result $Id $Name "PASS"
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    if ($Expected -ne $Actual) {
        throw "$What : expected '$Expected' but got '$Actual'"
    }
}

function Assert-SameSet {
    param([string[]]$Expected, [string[]]$Actual, [string]$What)

    $e = @($Expected)
    $a = @($Actual)
    $missing = @($e | Where-Object { $a -cnotcontains $_ })
    $extra = @($a | Where-Object { $e -cnotcontains $_ })

    if ($missing.Count -gt 0 -or $extra.Count -gt 0 -or $e.Count -ne $a.Count) {
        throw "$What : missing [$($missing -join ', ')] ; unexpected [$($extra -join ', ')] ; expected $($e.Count) entries, got $($a.Count)"
    }
}

# ---------------------------------------------------------------------------
# Scanner invocation helpers
# ---------------------------------------------------------------------------

function New-OutputPath {
    param([string]$Tag)
    return Join-Path $paths.Outputs ($Tag + ".json")
}

# Runs the scanner in-process with absolute paths. Never prompts: tests that
# need a missing mandatory parameter use the -File entry point instead.
function Invoke-Scanner {
    param([hashtable]$Arguments)

    $threw = $false
    $message = ""
    $output = @()

    try {
        $output = @(& $scannerFull @Arguments *>&1)
    }
    catch {
        $threw = $true
        $message = $_.Exception.Message
    }

    return [pscustomobject]@{
        Threw   = $threw
        Message = $message
        Output  = (($output | ForEach-Object { "$_" }) -join "`n")
    }
}

function Invoke-ScanAndRead {
    param([string]$Root, [string]$OutPath)

    $before = [datetime]::UtcNow
    $run = Invoke-Scanner @{ RootPath = $Root; OutputFile = $OutPath }
    $after = [datetime]::UtcNow

    $exists = Test-Path -LiteralPath $OutPath -PathType Leaf
    $bytes = $null
    $raw = $null
    $manifest = $null
    $parseError = ""

    if (-not $run.Threw -and $exists) {
        $bytes = [System.IO.File]::ReadAllBytes($OutPath)
        # The BOM is stripped here on purpose so that only the dedicated BOM
        # test (S18) is sensitive to it.
        $raw = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes).TrimStart([char]0xFEFF)
        try { $manifest = $raw | ConvertFrom-Json }
        catch { $parseError = $_.Exception.Message }
    }

    return [pscustomobject]@{
        Threw        = $run.Threw
        Message      = $run.Message
        Output       = $run.Output
        OutPath      = $OutPath
        OutputExists = $exists
        Bytes        = $bytes
        Raw          = $raw
        Manifest     = $manifest
        ParseError   = $parseError
        Before       = $before
        After        = $after
    }
}

function Assert-ScanOk {
    param($Scan)
    if ($Scan.Threw) { throw "Scanner failed unexpectedly: $($Scan.Message)" }
    if (-not $Scan.OutputExists) { throw "Scanner reported success but created no manifest: $($Scan.OutPath)" }
    if ($null -eq $Scan.Manifest) { throw "Manifest is not valid JSON: $($Scan.ParseError)" }
}

function Get-ManifestPaths {
    param($Scan)
    return @($Scan.Manifest.files |
        Where-Object { $null -ne $_ } |
        ForEach-Object { [string]$_.relativePath })
}

# Baseline scan of repos\main, computed once and shared by the read-only tests.
function Get-MainScan {
    if ($null -eq $script:mainScan) {
        $script:mainScan = Invoke-ScanAndRead $paths.Main (New-OutputPath "main-baseline")
    }
    return $script:mainScan
}

function Assert-ScanFails {
    param($Run, [string]$Fragment, [string]$OutPath)

    Assert-True $Run.Threw "Scanner was expected to fail but succeeded."
    Assert-True ($Run.Message.IndexOf($Fragment, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) `
        "Expected an error containing '$Fragment' but got: $($Run.Message)"
    if ($OutPath) {
        Assert-True (-not (Test-Path -LiteralPath $OutPath)) `
            "An output file was created despite the failure: $OutPath"
    }
}

# Runs the scanner through the real -File entry point in a child Windows
# PowerShell, with stdin closed (so a prompt cannot hang) and a timeout.
function Invoke-ScannerProcess {
    param([string[]]$Arguments, [int]$TimeoutSec = 120)

    $parts = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass")
    foreach ($argument in $Arguments) {
        if ($argument -match '^-[A-Za-z]+$') {
            $parts += $argument
        }
        else {
            if ($argument.EndsWith("\")) { throw "Test helper does not support a trailing backslash: $argument" }
            $parts += ('"' + $argument + '"')
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellExe
    $startInfo.Arguments = ($parts -join " ")
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            try { $process.Kill() } catch { }
            return [pscustomobject]@{ TimedOut = $true; ExitCode = $null; Stdout = ""; Stderr = "" }
        }

        $process.WaitForExit()
        return [pscustomobject]@{
            TimedOut = $false
            ExitCode = $process.ExitCode
            Stdout   = $stdoutTask.Result
            Stderr   = $stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

# Native commands write to stderr; with $ErrorActionPreference = Stop that
# would throw on the first line under Windows PowerShell 5.1.
function Invoke-NativeCapture {
    param([string]$File, [string[]]$ArgumentList)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = @(& $File @ArgumentList 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    return [pscustomobject]@{
        ExitCode = $code
        Output   = (($lines -join " ") -replace "\s+", " ").Trim()
    }
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

function New-TestDirectory {
    param([string]$Path)
    [void][System.IO.Directory]::CreateDirectory($Path)
}

function New-TestFile {
    param([string]$Root, [string]$RelativePath, [int]$Size = 1)

    $full = Join-Path $Root ($RelativePath.Replace("/", "\"))
    New-TestDirectory (Split-Path -Parent $full)

    $bytes = New-Object byte[] $Size
    for ($i = 0; $i -lt $Size; $i++) { $bytes[$i] = 120 }   # 'x'
    [System.IO.File]::WriteAllBytes($full, $bytes)
    return $full
}

function Test-ReparsePoint {
    param([string]$Path)
    try { $attributes = [System.IO.File]::GetAttributes($Path) } catch { return $false }
    return (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Remove-LinkRemnant {
    param([string]$Path)
    # Only removes something that exists but is NOT a link (a failed creation attempt).
    if ((Test-Path -LiteralPath $Path) -and -not (Test-ReparsePoint $Path)) {
        try {
            if ([System.IO.Directory]::Exists($Path)) { [System.IO.Directory]::Delete($Path) }
            else { [System.IO.File]::Delete($Path) }
        }
        catch { }
    }
}

function New-TestJunction {
    param([string]$LinkPath, [string]$TargetPath)

    $attempts = @()

    try {
        [void](New-Item -ItemType Junction -Path $LinkPath -Value $TargetPath -ErrorAction Stop)
    }
    catch {
        $attempts += "New-Item -ItemType Junction failed: $($_.Exception.Message)"
    }

    if (-not (Test-ReparsePoint $LinkPath)) {
        if (Test-Path -LiteralPath $LinkPath) {
            $attempts += "New-Item produced a path without the ReparsePoint attribute"
            Remove-LinkRemnant $LinkPath
        }

        $result = Invoke-NativeCapture $commandShell @("/c", "mklink", "/J", $LinkPath, $TargetPath)
        if ($result.ExitCode -ne 0) {
            $attempts += "mklink /J failed (exit $($result.ExitCode)): $($result.Output)"
        }
    }

    if (Test-ReparsePoint $LinkPath) {
        return [pscustomobject]@{ Created = $true; Reason = "" }
    }

    if (Test-Path -LiteralPath $LinkPath) {
        $attempts += "mklink /J produced a path without the ReparsePoint attribute"
        Remove-LinkRemnant $LinkPath
    }
    return [pscustomobject]@{ Created = $false; Reason = ($attempts -join " | ") }
}

function New-TestFileSymlink {
    param([string]$LinkPath, [string]$TargetPath)

    $result = Invoke-NativeCapture $commandShell @("/c", "mklink", $LinkPath, $TargetPath)

    if ($result.ExitCode -eq 0 -and (Test-ReparsePoint $LinkPath)) {
        return [pscustomobject]@{ Created = $true; Reason = "" }
    }

    $reason = "mklink (file symlink) exit $($result.ExitCode): $($result.Output)"
    if ($result.ExitCode -eq 0) { $reason += " (link exists but lacks the ReparsePoint attribute)" }
    Remove-LinkRemnant $LinkPath
    return [pscustomobject]@{ Created = $false; Reason = $reason }
}

function Initialize-Fixtures {
    New-TestDirectory $paths.Workspace
    $script:workspaceCreated = $true

    foreach ($directory in @($paths.Outputs, $paths.OutsideTarget, $paths.Empty)) {
        New-TestDirectory $directory
    }

    # Outside-the-repo link targets (inside the workspace, outside every scanned root).
    [void](New-TestFile (Split-Path -Parent $paths.Marker) "outside-marker.txt" 3)
    [void](New-TestFile (Split-Path -Parent $paths.OutsideFile) "target-file.txt" 3)

    # --- repos\main ---------------------------------------------------------
    New-TestDirectory $paths.Main

    foreach ($file in $includedFiles) {
        $full = New-TestFile $paths.Main $file.Path $file.Size
        if ($file.Path -eq ".editorconfig") {
            [System.IO.File]::SetAttributes($full, [System.IO.FileAttributes]::Hidden)
            if (([System.IO.File]::GetAttributes($full) -band [System.IO.FileAttributes]::Hidden) -eq 0) {
                throw "Could not mark fixture file as hidden: $full"
            }
        }
    }

    # Excluded directories at the root and nested (src\<name>).
    foreach ($name in $excludedDirectoryNames) {
        [void](New-TestFile $paths.Main "$name/inner.txt" 4)
        [void](New-TestFile $paths.Main "src/$name/inner.txt" 4)
    }

    # Case variants of excluded directory names.
    foreach ($name in @("Node_Modules", "DIST", ".GIT", "Obj")) {
        [void](New-TestFile $paths.Main "variants/$name/inner.txt" 4)
    }

    # Excluded files at the root and nested (src\lib).
    foreach ($name in $excludedFileNames) {
        [void](New-TestFile $paths.Main $name 4)
        [void](New-TestFile $paths.Main "src/lib/$name" 4)
    }

    New-TestDirectory (Join-Path $paths.Main "emptydir")

    # --- other fixtures -----------------------------------------------------
    [void](New-TestFile $paths.Ordering "m.md" 1)
    [void](New-TestFile $paths.Ordering "z.md" 1)
    [void](New-TestFile $paths.Ordering "a/one.md" 1)
    [void](New-TestFile $paths.Ordering "q/r/two.md" 1)

    [void](New-TestFile $paths.Single "only.md" 4)

    [void](New-TestFile $paths.Odd "top.md" 2)
    [void](New-TestFile $paths.Odd "sub dir/a b.txt" 3)

    # --- capability probes: real creation attempts, verified by attribute ---
    $script:junctionInfo = New-TestJunction $paths.Junction $paths.OutsideTarget
    $script:symlinkInfo = New-TestFileSymlink $paths.Symlink $paths.OutsideFile

    Write-Host "Workspace : $($paths.Workspace)"
    Write-Host "Scanner   : $scannerFull"
    if ($script:junctionInfo.Created) { Write-Host "Junction  : created" }
    else { Write-Host "Junction  : NOT created - $($script:junctionInfo.Reason)" -ForegroundColor Yellow }
    if ($script:symlinkInfo.Created) { Write-Host "Symlink   : created" }
    else { Write-Host "Symlink   : NOT created - $($script:symlinkInfo.Reason)" -ForegroundColor Yellow }
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

function Remove-TestWorkspace {
    if (-not $script:workspaceCreated) { return }

    # 1. Remove links first, without recursion.
    $linkProblems = @()
    foreach ($link in @($paths.Junction, $paths.Symlink)) {
        if ($null -ne (Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue)) {
            try {
                if (Test-ReparsePoint $link) {
                    if ([System.IO.Directory]::Exists($link)) { [System.IO.Directory]::Delete($link) }
                    else { [System.IO.File]::Delete($link) }
                }
            }
            catch { $linkProblems += "$link : $($_.Exception.Message)" }
        }
    }

    # 2. The link targets must have survived the link removal.
    $anyLink = $script:junctionInfo.Created -or $script:symlinkInfo.Created
    Write-Host ""
    Write-Host "=== CLN1 - Removing links did not touch their targets ===" -ForegroundColor Cyan
    if (-not $anyLink) {
        Add-Result "CLN1" "link targets intact" "SKIPPED" "no junction or symlink was created"
    }
    else {
        $missing = @()
        if ($script:junctionInfo.Created -and -not (Test-Path -LiteralPath $paths.Marker)) { $missing += $paths.Marker }
        if ($script:symlinkInfo.Created -and -not (Test-Path -LiteralPath $paths.OutsideFile)) { $missing += $paths.OutsideFile }
        if ($linkProblems.Count -gt 0) { $missing += "link removal errors: " + ($linkProblems -join "; ") }

        if ($missing.Count -eq 0) { Add-Result "CLN1" "link targets intact" "PASS" }
        else { Add-Result "CLN1" "link targets intact" "FAIL" ($missing -join " | ") }
    }

    # 3. Guarded recursive deletion of the workspace.
    Write-Host ""
    Write-Host "=== CLN2 - Workspace removed ===" -ForegroundColor Cyan

    $full = [System.IO.Path]::GetFullPath($paths.Workspace).TrimEnd('\')
    $tempFull = [System.IO.Path]::GetFullPath($tempBase).TrimEnd('\')
    $parent = Split-Path -Parent $full
    $leaf = Split-Path -Leaf $full

    $guardOk = ($parent -ieq $tempFull) -and ($leaf -like "ai-harness-scanner-tests-*")
    if (-not $guardOk) {
        Add-Result "CLN2" "workspace removed" "FAIL" "Refusing to delete unexpected path: $full"
        return
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
            break
        }
        catch {
            if ($attempt -eq 2) { Write-Host "Cleanup error: $($_.Exception.Message)" -ForegroundColor Yellow }
            else { Start-Sleep -Milliseconds 500 }
        }
    }

    if (Test-Path -LiteralPath $full) {
        Add-Result "CLN2" "workspace removed" "FAIL" "Leftover directory: $full"
    }
    else {
        Add-Result "CLN2" "workspace removed" "PASS"
    }
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "      SCANNER REGRESSION SUITE" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

try {
    try {
        Initialize-Fixtures
    }
    catch {
        $script:aborted = $true
        Write-Host ""
        Write-Host "SETUP ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }

    if (-not $script:aborted) {

        Invoke-Test "S01" "Parameter contract: RootPath and OutputFile are mandatory parameters" {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $scannerFull, [ref]$tokens, [ref]$parseErrors)

            Assert-True (@($parseErrors).Count -eq 0) "Scanner has syntax errors."
            Assert-True ($null -ne $ast.ParamBlock) "Scanner has no param block (its first statement is not 'param(')."

            foreach ($name in @("RootPath", "OutputFile")) {
                $declared = @($ast.ParamBlock.Parameters |
                    Where-Object { $_.Name.VariablePath.UserPath -eq $name })
                Assert-True ($declared.Count -eq 1) "Parameter -$name is not declared."

                $mandatory = $false
                foreach ($attribute in $declared[0].Attributes) {
                    if ($attribute.TypeName.Name -eq "Parameter") {
                        foreach ($named in $attribute.NamedArguments) {
                            if ($named.ArgumentName -eq "Mandatory" -and
                                ($named.ExpressionOmitted -or $named.Argument.Extent.Text -eq '$true')) {
                                $mandatory = $true
                            }
                        }
                    }
                }
                Assert-True $mandatory "Parameter -$name is not Mandatory."
            }
        }

        Invoke-Test "S02" "Valid repository: scan succeeds, manifest is valid JSON, inventory is exactly the expected files" {
            $scan = Get-MainScan
            Assert-ScanOk $scan
            Assert-SameSet @($includedFiles | ForEach-Object { $_.Path }) (Get-ManifestPaths $scan) "Manifest inventory"
        }

        Invoke-Test "S03" "Manifest schema: version, rootPath, scannedAtUtc, summary and entry fields" {
            $scan = Get-MainScan
            Assert-ScanOk $scan
            $m = $scan.Manifest

            Assert-Equal 1 $m.schemaVersion "schemaVersion"

            $expectedRoot = [System.IO.Path]::GetFullPath($paths.Main)
            Assert-True ([string]::Equals([string]$m.rootPath, $expectedRoot, [System.StringComparison]::OrdinalIgnoreCase)) `
                "rootPath : expected '$expectedRoot' but got '$($m.rootPath)'"

            if ($m.scannedAtUtc -is [datetime]) {
                $stamp = $m.scannedAtUtc.ToUniversalTime()
            }
            else {
                $text = [string]$m.scannedAtUtc
                Assert-True ($text -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$') `
                    "scannedAtUtc is not an ISO 8601 UTC timestamp: '$text'"
                $stamp = [datetime]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind)
            }
            Assert-True ($stamp -ge $scan.Before.AddSeconds(-1) -and $stamp -le $scan.After.AddSeconds(1)) `
                "scannedAtUtc $stamp is outside the scan window $($scan.Before) .. $($scan.After)"

            $summaryNames = @($m.summary.PSObject.Properties | ForEach-Object { $_.Name })
            foreach ($key in @("directoriesScanned", "filesScanned", "totalSizeBytes")) {
                Assert-True ($summaryNames -contains $key) "summary.$key is missing."
            }

            $entries = @($m.files | Where-Object { $null -ne $_ })
            Assert-True ($entries.Count -gt 0) "Manifest has no file entries."
            foreach ($entry in $entries) {
                $entryNames = @($entry.PSObject.Properties | ForEach-Object { $_.Name })
                foreach ($key in @("relativePath", "name", "extension", "sizeBytes")) {
                    Assert-True ($entryNames -contains $key) "Entry '$($entry.relativePath)' lacks '$key'."
                }
            }
        }

        Invoke-Test "S04" "Nested entries: forward-slash relativePath, name, extension and exact sizeBytes" {
            $scan = Get-MainScan
            Assert-ScanOk $scan
            $entries = @($scan.Manifest.files | Where-Object { $null -ne $_ })

            foreach ($relative in (Get-ManifestPaths $scan)) {
                Assert-True (-not $relative.Contains("\")) "relativePath contains a backslash: $relative"
            }

            $nested = @($entries | Where-Object { $_.relativePath -ceq "src/lib/util.ts" })
            Assert-True ($nested.Count -eq 1) "Entry 'src/lib/util.ts' not found exactly once."
            Assert-Equal "util.ts" $nested[0].name "name of src/lib/util.ts"
            Assert-Equal ".ts" $nested[0].extension "extension of src/lib/util.ts"
            Assert-Equal 33 $nested[0].sizeBytes "sizeBytes of src/lib/util.ts"

            $readme = @($entries | Where-Object { $_.relativePath -ceq "README.md" })
            Assert-True ($readme.Count -eq 1) "Entry 'README.md' not found exactly once."
            Assert-Equal ".md" $readme[0].extension "extension of README.md"
            Assert-Equal 11 $readme[0].sizeBytes "sizeBytes of README.md"
        }

        Invoke-Test "S05" "Ordering: files are sorted by relativePath (structure does not depend on enumeration order)" {
            $scan = Invoke-ScanAndRead $paths.Ordering (New-OutputPath "S05")
            Assert-ScanOk $scan

            # Without sorting, the root-level files (m.md, z.md) are always recorded
            # before any file in a subdirectory, so the first entry could never be
            # a/one.md. Reversed sorting yields the exact inverse.
            $expected = @("a/one.md", "m.md", "q/r/two.md", "z.md")
            $actual = @(Get-ManifestPaths $scan)

            Assert-Equal $expected.Count $actual.Count "number of entries"
            for ($i = 0; $i -lt $expected.Count; $i++) {
                Assert-True ($expected[$i] -ceq $actual[$i]) `
                    "Position $($i + 1): expected '$($expected[$i])' but got '$($actual[$i])'. Full order: $($actual -join ', ')"
            }
        }

        Invoke-Test "S06" "Determinism: two scans of the same repository produce identical file lists" {
            $first = Invoke-ScanAndRead $paths.Main (New-OutputPath "S06a")
            $second = Invoke-ScanAndRead $paths.Main (New-OutputPath "S06b")
            Assert-ScanOk $first
            Assert-ScanOk $second

            $a = ($first.Manifest.files | ConvertTo-Json -Depth 5 -Compress)
            $b = ($second.Manifest.files | ConvertTo-Json -Depth 5 -Compress)
            Assert-True ($a -ceq $b) "The two scans produced different 'files' content."
        }

        Invoke-Test "S07" "All 19 excluded directory names are skipped at the root and when nested" {
            Assert-Equal 19 $excludedDirectoryNames.Count "number of excluded directory names under test"

            $scan = Get-MainScan
            Assert-ScanOk $scan
            $listed = Get-ManifestPaths $scan
            Assert-True ($listed -ccontains "src/app.ts") "Positive control failed: src/app.ts is not listed."

            $leaks = @()
            foreach ($name in $excludedDirectoryNames) {
                foreach ($relative in $listed) {
                    if ($relative.StartsWith("$name/", [System.StringComparison]::OrdinalIgnoreCase) -or
                        $relative.IndexOf("/$name/", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $leaks += "$name -> $relative"
                    }
                }
            }
            Assert-True ($leaks.Count -eq 0) "Excluded directories leaked into the manifest: $($leaks -join '; ')"
        }

        Invoke-Test "S08" "Directory exclusion is case-insensitive and exact-name only" {
            $scan = Get-MainScan
            Assert-ScanOk $scan
            $listed = Get-ManifestPaths $scan

            $leaks = @($listed | Where-Object { $_ -like "variants/*/inner.txt" })
            Assert-True ($leaks.Count -eq 0) "Case variants of excluded directories leaked: $($leaks -join '; ')"
            Assert-True ($listed -ccontains "variants/keep.txt") "variants/keep.txt should be listed."
            Assert-True ($listed -ccontains "builder/keep.md") "'builder' must not be excluded just because it resembles 'build'."
        }

        Invoke-Test "S09" "Sensitive file-name patterns are excluded (root and nested, including case variants)" {
            $scan = Get-MainScan
            Assert-ScanOk $scan
            $names = @($scan.Manifest.files | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.name })

            $leaks = @()
            foreach ($excluded in $excludedFileNames) {
                if ($names -contains $excluded) { $leaks += $excluded }
            }
            Assert-True ($leaks.Count -eq 0) "Excluded file names leaked into the manifest: $($leaks -join ', ')"
        }

        Invoke-Test "S10" "Exclusion patterns are anchored: look-alike names are still listed" {
            $scan = Get-MainScan
            Assert-ScanOk $scan
            $listed = Get-ManifestPaths $scan

            foreach ($expected in @("environment.md", "keyboard.md", "id_rsa_notes.md", "README.md")) {
                Assert-True ($listed -ccontains $expected) "'$expected' should be listed but is missing."
            }
        }

        Invoke-Test "S11" "Directory junction is not followed and not listed" {
            if (-not $script:junctionInfo.Created) {
                Skip-Test "junction could not be created: $($script:junctionInfo.Reason)"
            }
            Assert-True (Test-ReparsePoint $paths.Junction) "Fixture junction lost its ReparsePoint attribute."

            $scan = Get-MainScan
            Assert-ScanOk $scan
            $listed = Get-ManifestPaths $scan

            $leaks = @($listed | Where-Object { $_ -like "linked-dir*" -or $_ -like "*outside-marker*" })
            Assert-True ($leaks.Count -eq 0) "Junction contents leaked into the manifest: $($leaks -join '; ')"
        }

        Invoke-Test "S12" "File symlink is not listed" {
            if (-not $script:symlinkInfo.Created) {
                Skip-Test "file symlink could not be created: $($script:symlinkInfo.Reason)"
            }
            Assert-True (Test-ReparsePoint $paths.Symlink) "Fixture symlink lost its ReparsePoint attribute."

            $scan = Get-MainScan
            Assert-ScanOk $scan
            $listed = Get-ManifestPaths $scan

            Assert-True (-not ($listed -ccontains "linked-file.txt")) "The file symlink 'linked-file.txt' was listed."
        }

        Invoke-Test "S13" "The output file is never listed in its own manifest (first run and re-run)" {
            $inRoot = Join-Path $paths.Main "manifest-out.json"
            try {
                $first = Invoke-ScanAndRead $paths.Main $inRoot
                Assert-ScanOk $first
                Assert-True (-not ((Get-ManifestPaths $first) -ccontains "manifest-out.json")) `
                    "First run listed its own output file."

                $second = Invoke-ScanAndRead $paths.Main $inRoot
                Assert-ScanOk $second
                Assert-SameSet @($includedFiles | ForEach-Object { $_.Path }) (Get-ManifestPaths $second) `
                    "Inventory of the re-run over an existing manifest"
            }
            finally {
                Remove-Item -LiteralPath $inRoot -Force -ErrorAction SilentlyContinue
            }
        }

        Invoke-Test "S14" "Hidden files and zero-byte files are included" {
            $scan = Get-MainScan
            Assert-ScanOk $scan
            $entries = @($scan.Manifest.files | Where-Object { $null -ne $_ })

            $hidden = @($entries | Where-Object { $_.relativePath -ceq ".editorconfig" })
            Assert-True ($hidden.Count -eq 1) "Hidden file '.editorconfig' is missing."
            Assert-Equal 10 $hidden[0].sizeBytes "sizeBytes of .editorconfig"

            $empty = @($entries | Where-Object { $_.relativePath -ceq "empty.txt" })
            Assert-True ($empty.Count -eq 1) "Zero-byte file 'empty.txt' is missing."
            Assert-Equal 0 $empty[0].sizeBytes "sizeBytes of empty.txt"
        }

        Invoke-Test "S15" "Summary arithmetic: filesScanned, totalSizeBytes and directoriesScanned" {
            $scan = Get-MainScan
            Assert-ScanOk $scan
            $summary = $scan.Manifest.summary
            $entries = @($scan.Manifest.files | Where-Object { $null -ne $_ })

            Assert-Equal $expectedFileCount $summary.filesScanned "summary.filesScanned"
            Assert-Equal $entries.Count $summary.filesScanned "summary.filesScanned vs number of entries"
            Assert-Equal $expectedTotalBytes $summary.totalSizeBytes "summary.totalSizeBytes"

            $sum = 0
            foreach ($entry in $entries) { $sum += [long]$entry.sizeBytes }
            Assert-Equal $sum $summary.totalSizeBytes "summary.totalSizeBytes vs sum of entry sizes"

            Assert-Equal $expectedDirectoryCount $summary.directoriesScanned "summary.directoriesScanned"
        }

        Invoke-Test "S16" "Empty repository: 'files' is serialized as an empty JSON array" {
            $scan = Invoke-ScanAndRead $paths.Empty (New-OutputPath "S16")
            Assert-ScanOk $scan

            Assert-True ($scan.Raw -match '"files"\s*:\s*\[\s*\]') "Raw JSON does not contain an empty 'files' array."
            Assert-Equal 0 $scan.Manifest.summary.filesScanned "summary.filesScanned"
            Assert-Equal 0 $scan.Manifest.summary.totalSizeBytes "summary.totalSizeBytes"
            Assert-Equal 1 $scan.Manifest.summary.directoriesScanned "summary.directoriesScanned (the root itself)"
        }

        Invoke-Test "S17" "Single-file repository: 'files' is still serialized as a JSON array" {
            $scan = Invoke-ScanAndRead $paths.Single (New-OutputPath "S17")
            Assert-ScanOk $scan

            Assert-True ($scan.Raw -match '"files"\s*:\s*\[') "Raw JSON does not serialize 'files' as an array."
            $listed = @(Get-ManifestPaths $scan)
            Assert-Equal 1 $listed.Count "number of entries"
            Assert-Equal "only.md" $listed[0] "the single entry"
        }

        Invoke-Test "S18" "Manifest is UTF-8 without BOM and non-ASCII names round-trip" {
            $scan = Get-MainScan
            Assert-ScanOk $scan
            $bytes = $scan.Bytes

            Assert-True ($bytes.Length -ge 3) "Manifest is unexpectedly short."
            Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) `
                "Manifest starts with a UTF-8 BOM."

            $hasUtf8Sequence = $false
            for ($i = 0; $i -lt ($bytes.Length - 1); $i++) {
                if ($bytes[$i] -eq 0xC3 -and $bytes[$i + 1] -eq 0xA9) { $hasUtf8Sequence = $true; break }
            }
            Assert-True $hasUtf8Sequence "The UTF-8 byte sequence for the accented file name was not found."

            Assert-True ((Get-ManifestPaths $scan) -ccontains $unicodeName) `
                "The non-ASCII file name did not round-trip through the manifest."
        }

        Invoke-Test "S19" "Root path with spaces and brackets, with and without a trailing backslash" {
            $expected = @("sub dir/a b.txt", "top.md")

            $plain = Invoke-ScanAndRead $paths.Odd (New-OutputPath "S19a")
            Assert-ScanOk $plain
            Assert-SameSet $expected (Get-ManifestPaths $plain) "Inventory (plain root)"

            $trailing = Invoke-ScanAndRead ($paths.Odd + "\") (New-OutputPath "S19b")
            Assert-ScanOk $trailing
            Assert-SameSet $expected (Get-ManifestPaths $trailing) "Inventory (root with trailing backslash)"
        }

        Invoke-Test "S20" "Failure: missing repository root" {
            $out = New-OutputPath "S20"
            $run = Invoke-Scanner @{ RootPath = (Join-Path $paths.Workspace "no-such-repo"); OutputFile = $out }
            Assert-ScanFails $run "Repository directory not found" $out
        }

        Invoke-Test "S21" "Failure: repository root is a file" {
            $out = New-OutputPath "S21"
            $run = Invoke-Scanner @{ RootPath = (Join-Path $paths.Main "README.md"); OutputFile = $out }
            Assert-ScanFails $run "Repository directory not found" $out
        }

        Invoke-Test "S22" "Failure: output directory does not exist (and is not created)" {
            $missingDirectory = Join-Path $paths.Workspace "no-such-output-dir"
            $out = Join-Path $missingDirectory "out.json"
            $run = Invoke-Scanner @{ RootPath = $paths.Main; OutputFile = $out }
            Assert-ScanFails $run "Output directory does not exist" $out
            Assert-True (-not (Test-Path -LiteralPath $missingDirectory)) "The scanner created the missing output directory."
        }

        Invoke-Test "S23" "Failure: empty -RootPath or -OutputFile is rejected by parameter validation" {
            $before = @(Get-ChildItem -LiteralPath $paths.Outputs -Force).Count

            $out = New-OutputPath "S23a"
            $emptyRoot = Invoke-Scanner @{ RootPath = ""; OutputFile = $out }
            Assert-ScanFails $emptyRoot "RootPath" $out

            $emptyOutput = Invoke-Scanner @{ RootPath = $paths.Main; OutputFile = "" }
            Assert-ScanFails $emptyOutput "OutputFile" $null

            $after = @(Get-ChildItem -LiteralPath $paths.Outputs -Force).Count
            Assert-Equal $before $after "number of files in the outputs directory"
        }

        Invoke-Test "S24" "-File entry point: exit codes for success, invalid root and missing mandatory parameter" {
            $okOut = New-OutputPath "S24a"
            $ok = Invoke-ScannerProcess @("-File", $scannerFull, "-RootPath", $paths.Main, "-OutputFile", $okOut)
            Assert-True (-not $ok.TimedOut) "Success case timed out."
            Assert-True ($ok.ExitCode -eq 0) "Success case: expected exit code 0 but got $($ok.ExitCode). stderr: $($ok.Stderr.Trim())"
            Assert-True (Test-Path -LiteralPath $okOut -PathType Leaf) "Success case created no manifest."

            $badOut = New-OutputPath "S24b"
            $bad = Invoke-ScannerProcess @("-File", $scannerFull, "-RootPath", (Join-Path $paths.Workspace "no-such-repo"), "-OutputFile", $badOut)
            Assert-True (-not $bad.TimedOut) "Invalid-root case timed out."
            Assert-True ($bad.ExitCode -ne 0) "Invalid-root case: expected a non-zero exit code but got 0."
            Assert-True (-not (Test-Path -LiteralPath $badOut)) "Invalid-root case created a manifest."

            $missing = Invoke-ScannerProcess @("-File", $scannerFull, "-RootPath", $paths.Main)
            Assert-True (-not $missing.TimedOut) "Missing-parameter case hung or timed out (it must fail fast under -NonInteractive)."
            Assert-True ($missing.ExitCode -ne 0) "Missing-parameter case: expected a non-zero exit code but got 0."
        }
    }
}
catch {
    $script:aborted = $true
    Write-Host ""
    Write-Host "UNEXPECTED ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    try { Remove-TestWorkspace }
    catch {
        $script:aborted = $true
        Write-Host "CLEANUP ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$passedList = @($script:results | Where-Object { $_.Outcome -eq "PASS" })
$failedList = @($script:results | Where-Object { $_.Outcome -eq "FAIL" })
$skippedList = @($script:results | Where-Object { $_.Outcome -eq "SKIPPED" })

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "              TEST SUMMARY" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Passed: $($passedList.Count) | Failed: $($failedList.Count) | Skipped: $($skippedList.Count)"

if ($failedList.Count -gt 0) {
    Write-Host "FAILED_TESTS: $((@($failedList | ForEach-Object { $_.Id })) -join ',')"
}
else {
    Write-Host "FAILED_TESTS: none"
}

if ($skippedList.Count -gt 0) {
    $skipText = @($skippedList | ForEach-Object { "$($_.Id) ($(($_.Detail -replace '\s+', ' ').Trim()))" }) -join "; "
    Write-Host "SKIPPED_TESTS: $skipText"
}
else {
    Write-Host "SKIPPED_TESTS: none"
}

if ($script:aborted) {
    Write-Host "ABORTED: setup, unexpected or cleanup error (see above)" -ForegroundColor Red
}

if ($failedList.Count -eq 0 -and -not $script:aborted) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "STATUS: FAIL" -ForegroundColor Red
exit 1
