param(
    [string]$Model
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$reviewer = Join-Path $PSScriptRoot "review-spec.ps1"

# FR-013: without -Model the reviewer resolves its own model exactly as in
# production (AI_HARNESS_MODEL, agentModels.spec-reviewer, defaultModel), so
# -Model is passed on only when it was given. The model in use is printed.
$modelWasProvided = $PSBoundParameters.ContainsKey('Model')
. (Join-Path $PSScriptRoot "lib\config.ps1")
$resolvedModel = Resolve-HarnessModel `
    -Agent "spec-reviewer" `
    -ModelWasProvided $modelWasProvided `
    -ExplicitModel $Model `
    -Config (Get-HarnessConfig -ConfigPath (Join-Path $root ".ai\config.json"))
$reviewerModelArguments = @()
if ($modelWasProvided) {
    $reviewerModelArguments = @("-Model", $Model)
}

$validSpec = Join-Path $root "tests\fixtures\minimal-valid-spec.md"
$invalidSpec = Join-Path $root "tests\fixtures\semantic-invalid-spec.md"

$task = "Create a specification for a simple user registration feature with email and password."

$script:passed = 0
$script:failed = 0

if (-not (Test-Path $reviewer -PathType Leaf)) {
    throw "Specification reviewer not found: $reviewer"
}

foreach ($path in @($validSpec, $invalidSpec)) {
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Required specification fixture not found: $path"
    }
}

function Invoke-ReviewerTest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$SpecFile,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedExitCode
    )

    Write-Host ""
    Write-Host "=== INTEGRATION TEST: $Name ===" -ForegroundColor Cyan
    Write-Host "Model: $resolvedModel"
    Write-Host "Expected exit code: $ExpectedExitCode"

    try {
        $output = & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $reviewer `
            -Task $task `
            -SpecFile $SpecFile `
            @reviewerModelArguments 2>&1

        $actualExitCode = $LASTEXITCODE

        foreach ($line in $output) {
            Write-Host $line
        }
    }
    catch {
        Write-Host "Execution error: $($_.Exception.Message)" -ForegroundColor Red
        $actualExitCode = -1
    }

    if ($actualExitCode -eq $ExpectedExitCode) {
        Write-Host "RESULT: PASS" -ForegroundColor Green
        $script:passed++
    }
    else {
        Write-Host "RESULT: FAIL (exit code $actualExitCode)" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host " SPECIFICATION INTEGRATION TEST SUITE" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

Invoke-ReviewerTest `
    -Name "Valid specification passes semantic review" `
    -SpecFile $validSpec `
    -ExpectedExitCode 0

Invoke-ReviewerTest `
    -Name "Semantically invalid specification is rejected" `
    -SpecFile $invalidSpec `
    -ExpectedExitCode 1

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "          INTEGRATION SUMMARY" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Passed: $script:passed"
Write-Host "Failed: $script:failed"

if ($script:failed -eq 0) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "STATUS: FAIL" -ForegroundColor Red
exit 1