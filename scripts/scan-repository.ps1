param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RootPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputFile
)

$ErrorActionPreference = "Stop"

# 1. Resolve and validate paths
if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
    throw "Repository directory not found: $RootPath"
}

$rootFullPath = (Resolve-Path -LiteralPath $RootPath).Path
$rootFullPath = [System.IO.Path]::GetFullPath($rootFullPath)
$rootPrefix = $rootFullPath.TrimEnd('\') + '\'

$outputFullPath = [System.IO.Path]::GetFullPath($OutputFile)
$outputDirectory = Split-Path -Parent $outputFullPath

if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "Output directory does not exist: $outputDirectory"
}

# 2. Exclusion policies
$excludedDirectories = @(
    ".git",
    "node_modules",
    "vendor",
    "dist",
    "build",
    "coverage",
    ".next",
    ".nuxt",
    ".output",
    ".venv",
    "venv",
    "__pycache__",
    "bin",
    "obj",
    "logs",
    ".aws",
    ".ssh",
    ".kube",
    ".azure"
)

$excludedFilePatterns = @(
    '(?i)^\.env(?:$|\.)',
    '(?i).*\.(?:pem|key|p12|pfx|ppk)$',
    '(?i)^(?:id_rsa|id_ed25519)(?:\.|$)',
    '(?i).*\.(?:bak|backup|tmp|swp)$',
    '(?i)^(?:credentials|secrets)(?:\..*)?$',
    '(?i)^\.(?:npmrc|pypirc|netrc)$'
)

# 3. Traverse repository without following reparse points
$directoryStack = New-Object 'System.Collections.Generic.Stack[string]'
$directoryStack.Push($rootFullPath)

$files = New-Object 'System.Collections.Generic.List[object]'
$directoriesScanned = 0
$totalSizeBytes = [long]0

Write-Host ""
Write-Host "=== Repository Scanner ===" -ForegroundColor Cyan
Write-Host "Root: $rootFullPath"
Write-Host ""

while ($directoryStack.Count -gt 0) {
    $currentDirectory = $directoryStack.Pop()
    $directoriesScanned++

    $items = Get-ChildItem -LiteralPath $currentDirectory -Force -ErrorAction Stop

    foreach ($item in $items) {

        # Skip symbolic links, junctions and other reparse points
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            continue
        }

        if ($item.PSIsContainer) {

            if ($excludedDirectories -contains $item.Name) {
                continue
            }

            $directoryStack.Push($item.FullName)
            continue
        }

        $itemFullPath = [System.IO.Path]::GetFullPath($item.FullName)

        # Avoid including the manifest in its own inventory
        if ([string]::Equals(
            $itemFullPath,
            $outputFullPath,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            continue
        }

        $excluded = $false

        foreach ($pattern in $excludedFilePatterns) {
            if ([regex]::IsMatch($item.Name, $pattern)) {
                $excluded = $true
                break
            }
        }

        if ($excluded) {
            continue
        }

        $relativePath = $itemFullPath.Substring($rootPrefix.Length)
        $relativePath = $relativePath.Replace('\', '/')

        $extension = [System.IO.Path]::GetExtension($item.Name)

        $files.Add([pscustomobject]@{
            relativePath = $relativePath
            name         = $item.Name
            extension    = $extension
            sizeBytes    = [long]$item.Length
        })

        $totalSizeBytes += [long]$item.Length
    }
}

# 4. Sort inventory for consistent output
$sortedFiles = @($files | Sort-Object -Property relativePath)

# 5. Build manifest
$manifest = [pscustomobject]@{
    schemaVersion = 1
    rootPath = $rootFullPath
    scannedAtUtc = [DateTime]::UtcNow.ToString("o")
    summary = [pscustomobject]@{
        directoriesScanned = $directoriesScanned
        filesScanned = $sortedFiles.Count
        totalSizeBytes = $totalSizeBytes
    }
    files = $sortedFiles
}

# 6. Export JSON as UTF-8 without BOM
$json = $manifest | ConvertTo-Json -Depth 6

$encoding = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllText(
    $outputFullPath,
    $json,
    $encoding
)

# 7. Report
Write-Host "STATUS: PASS" -ForegroundColor Green
Write-Host "Directories scanned: $directoriesScanned"
Write-Host "Files inventoried: $($sortedFiles.Count)"
Write-Host "Total size: $totalSizeBytes bytes"
Write-Host "Manifest: $outputFullPath"