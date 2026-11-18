<#
.SYNOPSIS
    Parse-only syntax check for the project's PowerShell scripts.

.DESCRIPTION
    Parses every *.ps1 file found under the given paths with the PowerShell
    language parser and reports syntax errors with file, line and column.

    - Nothing is executed or dot-sourced.
    - Only files whose extension is exactly .ps1 are checked, so backups such
      as *.ps1.bak or *.ps1.bak-mode are ignored.
    - Files are read the way powershell.exe reads them (BOM detection, then the
      system default code page), which is what matters at run time.
    - Finding no .ps1 files at all is a failure, so a wrong path can never
      produce a vacuous pass.

    LIMITATION: this check only detects syntax errors. It cannot detect
    corruption that still parses, for example "param(" turned into "xparam(".
    Behavioural suites (such as test-scan-repository.ps1) cover that.

    Exit codes: 0 = no syntax errors, 1 = syntax errors, unreadable file,
    missing path, or no files found.

.PARAMETER Path
    Files or directories to check. Defaults to the scripts and tests
    directories of this repository, resolved relative to this script.
#>
param(
    [string[]]$Path = @(
        $PSScriptRoot,
        (Join-Path $PSScriptRoot "..\tests")
    )
)

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$repoPrefix = $repoRoot.TrimEnd('\') + '\'

$candidates = New-Object 'System.Collections.Generic.List[string]'

foreach ($entry in $Path) {
    if (Test-Path -LiteralPath $entry -PathType Leaf) {
        $candidates.Add((Resolve-Path -LiteralPath $entry).ProviderPath)
    }
    elseif (Test-Path -LiteralPath $entry -PathType Container) {
        $directory = (Resolve-Path -LiteralPath $entry).ProviderPath
        Get-ChildItem -LiteralPath $directory -Recurse -File -Force |
            Where-Object { $_.Extension -eq ".ps1" } |
            ForEach-Object { $candidates.Add($_.FullName) }
    }
    else {
        Write-Host "Path not found: $entry" -ForegroundColor Red
        Write-Host "STATUS: FAIL" -ForegroundColor Red
        exit 1
    }
}

$files = @($candidates | Sort-Object -Unique)

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "      POWERSHELL SYNTAX CHECK" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

if ($files.Count -eq 0) {
    Write-Host ""
    Write-Host "No .ps1 files found under the given paths." -ForegroundColor Red
    Write-Host "STATUS: FAIL" -ForegroundColor Red
    exit 1
}

$filesWithErrors = 0

foreach ($file in $files) {
    $display = $file
    if ($file.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $display = $file.Substring($repoPrefix.Length)
    }

    $problems = @()

    try {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $file, [ref]$tokens, [ref]$parseErrors)

        foreach ($parseError in @($parseErrors)) {
            $problems += "line $($parseError.Extent.StartLineNumber), " +
                "col $($parseError.Extent.StartColumnNumber): $($parseError.Message)"
        }
    }
    catch {
        $problems += "could not be parsed: $($_.Exception.Message)"
    }

    if ($problems.Count -eq 0) {
        Write-Host "OK    $display" -ForegroundColor Green
    }
    else {
        $filesWithErrors++
        Write-Host "FAIL  $display" -ForegroundColor Red
        foreach ($problem in $problems) {
            Write-Host "      $problem" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "Files checked           : $($files.Count)"
Write-Host "Files with syntax errors: $filesWithErrors"

if ($filesWithErrors -eq 0) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "STATUS: FAIL" -ForegroundColor Red
exit 1
