param()

$ErrorActionPreference = "Stop"

$builder = Join-Path $PSScriptRoot "build-context.ps1"

if (-not (Test-Path $builder -PathType Leaf)) {
    throw "Context Builder not found: $builder"
}

$script:passed = 0
$script:failed = 0

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "ai-harness-context-tests-" + [guid]::NewGuid().ToString()
)

$repoRoot = Join-Path $tempRoot "repo"
$outputDirectory = Join-Path $tempRoot "output"
$manifestPath = Join-Path $tempRoot "manifest.json"

New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $repoRoot "src") -Force | Out-Null

function Invoke-BuilderTest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [int]$ExpectedExitCode = 0,

        [string]$ExpectedText = ""
    )

    Write-Host ""
    Write-Host "=== TEST: $Name ===" -ForegroundColor Cyan

    $builderParameters = @{}
    $output = @()
    $actualExitCode = 0
    $outputPath = $null

    try {
        # Reconstruct named parameters.
        # Include receives all values until the next parameter.

        $i = 0

        while ($i -lt $Arguments.Length) {

            $parameterName = $Arguments[$i].TrimStart("-")
            $i++

            $values = @()

            while (
                $i -lt $Arguments.Length -and
                -not $Arguments[$i].StartsWith("-")
            ) {
                $values += $Arguments[$i]
                $i++
            }

            if ($parameterName -eq "Include") {
                $builderParameters[$parameterName] = [string[]]$values
            }
            else {
                if ($values.Count -ne 1) {
                    throw "Invalid test argument for parameter: $parameterName"
                }

                $builderParameters[$parameterName] = $values[0]
            }
        }

        if ($builderParameters.ContainsKey("OutputFile")) {
            $outputPath = $builderParameters["OutputFile"]
        }

        & $builder @builderParameters
    }
    catch {
        $actualExitCode = 1
        $output += $_.Exception.Message
        Write-Host $_.Exception.Message -ForegroundColor Yellow
    }

    $success = ($actualExitCode -eq $ExpectedExitCode)

    if ($success -and -not [string]::IsNullOrWhiteSpace($ExpectedText)) {
        $combinedOutput = $output -join "`n"

        if ($combinedOutput -notmatch [regex]::Escape($ExpectedText)) {
            $success = $false
            Write-Host "Expected message not found: $ExpectedText" -ForegroundColor Red
        }
    }

    if ($success -and $outputPath) {
        $fileExists = Test-Path -LiteralPath $outputPath -PathType Leaf

        if ($ExpectedExitCode -eq 0 -and -not $fileExists) {
            $success = $false
            Write-Host "Expected output file was not created." -ForegroundColor Red
        }

        if ($ExpectedExitCode -ne 0 -and $fileExists) {
            $success = $false
            Write-Host "Output file was created despite the expected failure." -ForegroundColor Red
        }
    }

    if ($success) {
        Write-Host "RESULT: PASS" -ForegroundColor Green
        $script:passed++
    }
    else {
        Write-Host "Expected exit code: $ExpectedExitCode | Actual: $actualExitCode" -ForegroundColor Red
        Write-Host "RESULT: FAIL" -ForegroundColor Red
        $script:failed++
    }
}
function Assert-FileContains {
    param(
        [string]$Name,
        [string]$Path,
        [string]$ExpectedContent
    )

    Write-Host ""
    Write-Host "=== ASSERT: $Name ===" -ForegroundColor Cyan

    if (
        (Test-Path -LiteralPath $Path -PathType Leaf) -and
        ((Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Contains($ExpectedContent))
    ) {
        Write-Host "RESULT: PASS" -ForegroundColor Green
        $script:passed++
    }
    else {
        Write-Host "RESULT: FAIL" -ForegroundColor Red
        $script:failed++
    }
}

try {

    # 1. Create fixture repository

    Set-Content -LiteralPath (Join-Path $repoRoot "README.md") `
        -Value "README_MARKER" -Encoding UTF8

    Set-Content -LiteralPath (Join-Path $repoRoot "src\app.ts") `
        -Value "APP_MARKER" -Encoding UTF8

    Set-Content -LiteralPath (Join-Path $repoRoot ".env") `
        -Value "SECRET=value" -Encoding UTF8

    Set-Content -LiteralPath (Join-Path $repoRoot "credentials.json") `
        -Value '{"password":"secret"}' -Encoding UTF8

    Set-Content -LiteralPath (Join-Path $repoRoot "large.md") `
        -Value ("X" * 500) -Encoding UTF8

    Set-Content -LiteralPath (Join-Path $repoRoot "unsupported.exe") `
        -Value "NOT_TEXT" -Encoding UTF8

    Set-Content -LiteralPath (Join-Path $repoRoot "binary.txt") `
        -Value "placeholder" -Encoding UTF8

    [System.IO.File]::WriteAllBytes(
        (Join-Path $repoRoot "binary.txt"),
        [byte[]]@(65, 0, 66)
    )

    # 2. Create controlled manifest.
    # Sensitive and unsupported files are deliberately included here
    # to test the Context Builder's own validation independently.

    $entries = @(
        "README.md",
        "src/app.ts",
        ".env",
        "credentials.json",
        "large.md",
        "unsupported.exe",
        "binary.txt",
        "missing.md"
    ) | ForEach-Object {
        [pscustomobject]@{
            relativePath = $_
            name = [System.IO.Path]::GetFileName($_)
            extension = [System.IO.Path]::GetExtension($_)
            sizeBytes = 100
        }
    }

    $manifest = [pscustomobject]@{
        schemaVersion = 1
        rootPath = $repoRoot
        scannedAtUtc = [DateTime]::UtcNow.ToString("o")
        summary = [pscustomobject]@{
            totalFiles = $entries.Count
        }
        files = @($entries)
    }

    $manifest |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8

    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "       CONTEXT BUILDER TEST SUITE" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan

    # 3. Successful generation

    $singleOutput = Join-Path $outputDirectory "single.txt"

    Invoke-BuilderTest `
        -Name "Generate context with one file" `
        -Arguments @(
            "-ManifestFile", $manifestPath,
            "-Include", "README.md",
            "-OutputFile", $singleOutput
        )

    Assert-FileContains `
        -Name "Single-file content is preserved" `
        -Path $singleOutput `
        -ExpectedContent "README_MARKER"

    $multipleOutput = Join-Path $outputDirectory "multiple.txt"

    Invoke-BuilderTest `
        -Name "Generate context with multiple files" `
        -Arguments @(
            "-ManifestFile", $manifestPath,
            "-Include", "README.md", "src/app.ts",
            "-OutputFile", $multipleOutput
        )

    Assert-FileContains `
        -Name "Multiple-file context contains both files" `
        -Path $multipleOutput `
        -ExpectedContent "APP_MARKER"

    # 4. Path and file validation

    Invoke-BuilderTest `
        -Name "Reject Windows drive-qualified path" `
        -ExpectedExitCode 1 `
        -ExpectedText "Absolute or drive-qualified paths" `
        -Arguments @(
            "-ManifestFile", $manifestPath,
            "-Include", "C:\outside.md",
            "-OutputFile", (Join-Path $outputDirectory "drive-path.txt")
        )

    Invoke-BuilderTest `
        -Name "Reject rooted path" `
        -ExpectedExitCode 1 `
        -ExpectedText "Rooted paths are not allowed" `
        -Arguments @(
            "-ManifestFile", $manifestPath,
            "-Include", "/outside.md",
            "-OutputFile", (Join-Path $outputDirectory "rooted-path.txt")
        )
    Invoke-BuilderTest `
        -Name "Reject parent-directory traversal" `
        -ExpectedExitCode 1 `
        -ExpectedText "Parent-directory traversal" `
        -Arguments @(
            "-ManifestFile", $manifestPath,
            "-Include", "../outside.md",
            "-OutputFile", (Join-Path $outputDirectory "traversal.txt")
        )

    Invoke-BuilderTest `
        -Name "Reject .env directly" `
        -ExpectedExitCode 1 `
        -ExpectedText "Sensitive or excluded file" `
        -Arguments @(
            "-ManifestFile", $manifestPath,
            "-Include", ".env",
            "-OutputFile", (Join-Path $outputDirectory "env.txt")
        )

    Invoke-BuilderTest `
        -Name "Reject credentials.json directly" `
        -ExpectedExitCode 1 `
        -ExpectedText "Sensitive or excluded file" `
        -Arguments @(
            "-ManifestFile", $manifestPath,
            "-Include", "credentials.json",
            "-OutputFile", (Join-Path $outputDirectory "credentials.txt")
        )

    Invoke-BuilderTest `
        -Name "Reject unsupported extension" `
        -ExpectedExitCode 1 `
        -ExpectedText "Unsupported or non-text file type" `
        -Arguments @(
            "-ManifestFile", $manifestPath,
            "-Include", "unsupported.exe",
            "-OutputFile", (Join-Path $outputDirectory "unsupported.txt")
        )

    Invoke-BuilderTest `
        -Name "Reject binary content inside a text extension" `
        -ExpectedExitCode 1 `
        -ExpectedText "Binary content detected" `
        -Arguments @(
            "-ManifestFile", $manifestPath,
            "-Include", "binary.txt",
            "-OutputFile", (Join-Path $outputDirectory "binary.txt")
        )

    Invoke-BuilderTest `
        -Name "Reject file exceeding MaxFileBytes" `
        -ExpectedExitCode 1 `
        -ExpectedText "exceeds MaxFileBytes" `
        -Arguments @(
            "-ManifestFile", $manifestPath,
            "-Include", "README.md",
            "-OutputFile", (Join-Path $outputDirectory "max-file.txt"),
            "-MaxFileBytes", "1"
        )

    Invoke-BuilderTest `
        -Name "Reject context exceeding MaxTotalChars" `
        -ExpectedExitCode 1 `
        -ExpectedText "Context exceeds MaxTotalChars" `
        -Arguments @(
            "-ManifestFile", $manifestPath,
            "-Include", "README.md", "src/app.ts",
            "-OutputFile", (Join-Path $outputDirectory "max-total.txt"),
            "-MaxTotalChars", "100"
        )

    Invoke-BuilderTest `
        -Name "Reject file missing from disk" `
        -ExpectedExitCode 1 `
        -ExpectedText "Selected file no longer exists" `
        -Arguments @(
            "-ManifestFile", $manifestPath,
            "-Include", "missing.md",
            "-OutputFile", (Join-Path $outputDirectory "missing.txt")
        )

    Invoke-BuilderTest `
        -Name "Reject missing manifest" `
        -ExpectedExitCode 1 `
        -ExpectedText "Manifest file not found" `
        -Arguments @(
            "-ManifestFile", (Join-Path $tempRoot "nonexistent.json"),
            "-Include", "README.md",
            "-OutputFile", (Join-Path $outputDirectory "no-manifest.txt")
        )

}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "              TEST SUMMARY" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Passed: $script:passed"
Write-Host "Failed: $script:failed"

if ($script:failed -eq 0) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "STATUS: FAIL" -ForegroundColor Red
exit 1
