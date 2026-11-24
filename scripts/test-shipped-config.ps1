<#
.SYNOPSIS
    Offline, in-process check of the SHIPPED .ai\config.json against the frozen
    Phase 1 baseline (Phase 2, FR-217, AC-215 "the migrated .ai/config.json").

.DESCRIPTION
    - Reads the real .ai\config.json (or, for mutation proofs only, the file
      given with -ConfigPath) and tests\fixtures\config-v2-phase1-baseline.json.
    - The expectations are literals of this file (the four values FR-217 adds)
      or come from the raw JSON of the frozen baseline, never from the code
      under test. This file contains no model name.
    - Every leaf of the shipped file must equal the baseline leaf at the same
      path, except for exactly the four added paths, which carry literal
      expectations. A changed, removed or extra key anywhere fails.
    - No budgetMode key may exist anywhere (OQ-201: the default stays warn; the
      mode is decided in WP-2E).
    - The registry must load with no warning, resolve every agent to the same
      execution record as the baseline, and a reviewer-sized stub prompt must
      get the mode "warn" through the registry. The status that
      Test-AgentContextBudget returns for the stub is printed as DATA only: a
      number that WP-2E will change is not asserted.
    - No network, no Ollama, no child process. Nothing is written anywhere.
#>
param(
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$baselinePath = Join-Path $root "tests\fixtures\config-v2-phase1-baseline.json"
$configLibrary = Join-Path $PSScriptRoot "lib\config.ps1"
$engineLibrary = Join-Path $PSScriptRoot "lib\agent-exec.ps1"

if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $root ".ai\config.json" }

foreach ($path in @($configLibrary, $engineLibrary, $baselinePath, $ConfigPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required path not found: $path" }
}

. $configLibrary
. $engineLibrary

$script:passed = 0
$script:failed = 0

$originalModelVariable = $env:AI_HARNESS_MODEL
$env:AI_HARNESS_MODEL = $null

function Test-Case {
    param([string]$Name, [scriptblock]$Body)

    try {
        & $Body
        $script:passed++
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    catch {
        $script:failed++
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Equal {
    param([string]$What, $Expected, $Actual)

    if (-not ("$Expected" -ceq "$Actual")) {
        throw "$What : expected '$Expected', got '$Actual'"
    }
}

function Assert-True {
    param([string]$What, $Condition)

    if (-not $Condition) { throw "$What : condition is false" }
}

function Get-RawJson {
    param([string]$Path)
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# Every leaf of a parsed JSON tree as "path" -> "Type:value". Empty objects and
# arrays count as leaves, so adding or removing one is seen. Ordinal keys.
function Get-JsonLeaves {
    param($Node, [string]$Path, $Leaves)

    if ($null -eq $Node) {
        $Leaves[$Path] = "null:"
    }
    elseif ($Node -is [System.Management.Automation.PSCustomObject]) {
        $members = @($Node.PSObject.Properties)
        if ($members.Count -eq 0) { $Leaves[$Path] = "emptyobject:" }
        foreach ($member in $members) {
            Get-JsonLeaves -Node $member.Value -Path "$Path.$($member.Name)" -Leaves $Leaves
        }
    }
    elseif ($Node -is [System.Array]) {
        if ($Node.Count -eq 0) { $Leaves[$Path] = "emptyarray:" }
        for ($i = 0; $i -lt $Node.Count; $i++) {
            Get-JsonLeaves -Node $Node[$i] -Path "$Path[$i]" -Leaves $Leaves
        }
    }
    else {
        $Leaves[$Path] = $Node.GetType().Name + ":" + [string]$Node
    }
}

function Get-LeafMap {
    param($Raw)

    $leaves = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
    Get-JsonLeaves -Node $Raw -Path "" -Leaves $leaves
    return $leaves
}

function Get-Leaf {
    param($Leaves, [string]$Path)

    if ($Leaves.ContainsKey($Path)) { return $Leaves[$Path] }
    return "<absent>"
}

# FR-217: the only paths the update may add, with their literal values.
$addedPaths = @(".ollama.maxAttempts", ".ollama.retryBackoffSec", ".ollama.warmup", ".defaults.charsPerToken")

try {
    $shippedRaw = Get-RawJson $ConfigPath
    $baselineRaw = Get-RawJson $baselinePath
    $shippedLeaves = Get-LeafMap $shippedRaw
    $baselineLeaves = Get-LeafMap $baselineRaw

    Write-Host ""
    Write-Host "=== AC-215 shipped configuration: $ConfigPath ===" -ForegroundColor Cyan

    Test-Case "AC-215 shipped: the baseline has none of the four added paths (the expectations rest on it)" {
        foreach ($p in $addedPaths) {
            Assert-True "$p absent from the baseline" (-not $baselineLeaves.ContainsKey($p))
        }
        Assert-True "baseline has no budgetMode" (-not (@($baselineLeaves.Keys | Where-Object { $_ -match '(^|\.)budgetMode(\.|\[|$)' }).Count))
    }

    Test-Case "AC-215 shipped: ollama.maxAttempts 2, retryBackoffSec 5, warmup false, defaults.charsPerToken 3.5 (value and JSON type)" {
        Assert-Equal "maxAttempts" "Int32:2" (Get-Leaf $shippedLeaves ".ollama.maxAttempts")
        Assert-Equal "retryBackoffSec" "Int32:5" (Get-Leaf $shippedLeaves ".ollama.retryBackoffSec")
        Assert-Equal "warmup" "Boolean:False" (Get-Leaf $shippedLeaves ".ollama.warmup")
        # A JSON number: Decimal in Windows PowerShell 5.1, Double in PowerShell 7; never a string.
        $charsPerToken = $shippedRaw.defaults.charsPerToken
        Assert-True "charsPerToken is a JSON number" (($charsPerToken -is [decimal]) -or ($charsPerToken -is [double]))
        Assert-True "charsPerToken is 3.5" ([decimal]$charsPerToken -eq [decimal]3.5)
        Assert-True "warmup is the JSON boolean" ($shippedRaw.ollama.warmup -is [bool])
    }

    Test-Case "AC-215 shipped: no budgetMode key anywhere (the default warn applies, OQ-201)" {
        $found = @($shippedLeaves.Keys | Where-Object { $_ -match '(^|\.)budgetMode(\.|\[|$)' })
        Assert-Equal "budgetMode paths" 0 $found.Count
    }

    Test-Case "AC-215 shipped: every other leaf is identical to the baseline, nothing added, nothing removed" {
        $removedOrChanged = @()
        foreach ($key in $baselineLeaves.Keys) {
            if (-not $shippedLeaves.ContainsKey($key)) { $removedOrChanged += "missing $key" }
            elseif (-not ($shippedLeaves[$key] -ceq $baselineLeaves[$key])) {
                $removedOrChanged += "changed $key ($($baselineLeaves[$key]) -> $($shippedLeaves[$key]))"
            }
        }
        Assert-Equal "removed or changed" "" ($removedOrChanged -join "; ")

        $extra = @($shippedLeaves.Keys | Where-Object { -not $baselineLeaves.ContainsKey($_) } | Sort-Object)
        Assert-Equal "added paths" (($addedPaths | Sort-Object) -join ",") ($extra -join ",")
    }

    Test-Case "AC-215 shipped: the registry loads with no warning (no unknown_key) and carries the four values" {
        $registry = Get-HarnessRegistry -ConfigPath $ConfigPath
        Assert-Equal "warnings" 0 @($registry.warnings).Count
        Assert-Equal "maxAttempts" 2 $registry.ollama.maxAttempts
        Assert-Equal "retryBackoffSec" 5 $registry.ollama.retryBackoffSec
        Assert-True "warmup is the boolean false" (($registry.ollama.warmup -is [bool]) -and ($registry.ollama.warmup -eq $false))
        Assert-Equal "charsPerToken" 3.5 $registry.defaults.charsPerToken
        Assert-Equal "budgetMode" "warn" $registry.defaults.budgetMode
    }

    Test-Case "AC-215 shipped: every agent resolves to the same execution record as the baseline (model, timeout, options, think, window)" {
        $shippedRegistry = Get-HarnessRegistry -ConfigPath $ConfigPath
        $baselineRegistry = Get-HarnessRegistry -ConfigPath $baselinePath
        $agents = @($baselineRaw.agents.PSObject.Properties.Name)
        Assert-Equal "agent names" ($agents -join ",") (@($shippedRaw.agents.PSObject.Properties.Name) -join ",")
        Assert-True "four agents" ($agents.Count -eq 4)
        foreach ($agent in $agents) {
            $expected = Resolve-HarnessExecution -Agent $agent -Registry $baselineRegistry
            $actual = Resolve-HarnessExecution -Agent $agent -Registry $shippedRegistry
            Assert-Equal "$agent record" ($expected | ConvertTo-Json -Depth 10 -Compress) ($actual | ConvertTo-Json -Depth 10 -Compress)
            Assert-Equal "$agent model" $expected.model $actual.model
            Assert-Equal "$agent timeoutSec" $expected.timeoutSec $actual.timeoutSec
            Assert-Equal "$agent think" $expected.think $actual.think
            Assert-Equal "$agent contextWindow" $expected.contextWindow $actual.contextWindow
            Assert-Equal "$agent options" ($expected.options | ConvertTo-Json -Depth 10 -Compress) ($actual.options | ConvertTo-Json -Depth 10 -Compress)
        }
    }

    Test-Case "AC-215 shipped: a reviewer-sized stub prompt gets the mode warn (status recorded as data, not asserted)" {
        $registry = Get-HarnessRegistry -ConfigPath $ConfigPath
        $record = Resolve-HarnessExecution -Agent "spec-reviewer" -Registry $registry
        # About 25,600 characters is roughly the fixed text of the reviewer at charsPerToken 3.5.
        $budget = Test-AgentContextBudget -Execution $record -Registry $registry -System ("x" * 20000) -Prompt ("y" * 5638)
        Assert-Equal "mode" "warn" $registry.defaults.budgetMode
        Assert-True "the budget result has a status" (-not [string]::IsNullOrEmpty([string]$budget.status))
        Write-Host "    DATA: reviewer-sized stub: status=$($budget.status) estTokens=$($budget.estTokens) available=$($budget.available) over=$($budget.over) mode=$($registry.defaults.budgetMode)"
    }
}
finally {
    $env:AI_HARNESS_MODEL = $originalModelVariable
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
