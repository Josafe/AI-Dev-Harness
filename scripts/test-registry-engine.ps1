<#
.SYNOPSIS
    Offline, in-process tests for the registry fields added by Phase 2 (WP-2B1):
    ollama.maxAttempts, ollama.retryBackoffSec, ollama.warmup,
    defaults.charsPerToken and defaults.budgetMode (FR-217, AC-215).

.DESCRIPTION
    - No network, no Ollama, no child process: only scripts\lib\config.ps1 is
      dot-sourced.
    - Fixtures are read from tests\fixtures; everything written goes under a
      unique folder in TEMP, removed at the end. Nothing is written to the
      repository.
    - Expected values are literals of this file (synthetic names) or come from
      the raw JSON of a fixture, never from the code under test.
    - Assertions match only the harness's own wording: the token
      "registry_invalid: <field>", warning codes and resolved values. No
      localized text is asserted (NFR-202).
    - The shipped .ai\config.json is neither read nor changed here; the frozen
      copy of its Phase 1 state (tests\fixtures\config-v2-phase1-baseline.json)
      is the subject of the "baseline" cases.
#>
param()

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$fixtures = Join-Path $root "tests\fixtures"
$library = Join-Path $PSScriptRoot "lib\config.ps1"

foreach ($path in @($library, $fixtures)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required path not found: $path" }
}

. $library

$script:passed = 0
$script:failed = 0

$originalModelVariable = $env:AI_HARNESS_MODEL
$env:AI_HARNESS_MODEL = $null
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-harness-registry-engine-tests-" + [guid]::NewGuid().ToString())
[void][System.IO.Directory]::CreateDirectory($tempRoot)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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

function Assert-Throws {
    param([string]$What, [scriptblock]$Action, [string]$Prefix)

    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }

    if ($null -eq $message) { throw "$What : nothing was thrown (expected '$Prefix')" }
    if (-not $message.StartsWith($Prefix, [System.StringComparison]::Ordinal)) {
        throw "$What : expected a message starting with '$Prefix', got '$message'"
    }
}

function Get-RawJson {
    param([string]$Path)
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-TempText {
    param([string]$Name, [string]$Text)

    $path = Join-Path $tempRoot $Name
    [System.IO.File]::WriteAllText($path, $Text, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

# A v2 file with one profile, the engine fields given as raw JSON fragments.
function Write-EngineConfig {
    param([string]$Ollama = "", [string]$Defaults = "")

    $ollamaText = '"healthTimeoutSec": 15'
    if ($Ollama) { $ollamaText += ", $Ollama" }
    $defaultsText = ""
    if ($Defaults) { $defaultsText = '"defaults": { ' + $Defaults + ' }, ' }
    return Write-TempText "engine-case.json" ('{ "schemaVersion": 2, "ollama": { ' + $ollamaText + ' }, ' + $defaultsText + '"profiles": { "alpha": { "model": "test-model-a" } }, "agents": { "spec": { "profile": "alpha" } } }')
}

# Loader and Resolve-HarnessModel wrapper both reject with the token.
function Assert-RejectedBoth {
    param([string]$What, [string]$Path, [string]$Field)

    $token = "registry_invalid: $Field"
    Assert-Throws "$What loader" { Get-HarnessRegistry -ConfigPath $Path } $token
    Assert-Throws "$What wrapper" { Resolve-HarnessModel -Agent "spec" -ModelWasProvided $false -Config (Get-HarnessConfig -ConfigPath $Path) } $token
}

function Assert-EngineDefaults {
    param([string]$What, $Registry)

    Assert-Equal "$What maxAttempts" 2 $Registry.ollama.maxAttempts
    Assert-Equal "$What retryBackoffSec" 5 $Registry.ollama.retryBackoffSec
    Assert-True "$What warmup is the boolean false" (($Registry.ollama.warmup -is [bool]) -and ($Registry.ollama.warmup -eq $false))
    Assert-Equal "$What charsPerToken" 3.5 $Registry.defaults.charsPerToken
    Assert-Equal "$What budgetMode" "warn" $Registry.defaults.budgetMode
    $engineWarnings = @($Registry.warnings | Where-Object { $_ -like "unknown_key:*" })
    Assert-Equal "$What unknown_key warnings" 0 $engineWarnings.Count
}

try {
    # -----------------------------------------------------------------------
    # AC-215 accepted boundaries (loader and wrapper), literal expectations
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-215 accepted values ===" -ForegroundColor Cyan

    $accepted = @(
        @{ File = "config-v2-engine-attempts-1.json";   Read = { param($r) $r.ollama.maxAttempts };     Expected = 1;         Note = "maxAttempts 1" },
        @{ File = "config-v2-engine-attempts-5.json";   Read = { param($r) $r.ollama.maxAttempts };     Expected = 5;         Note = "maxAttempts 5" },
        @{ File = "config-v2-engine-backoff-0.json";    Read = { param($r) $r.ollama.retryBackoffSec }; Expected = 0;         Note = "retryBackoffSec 0" },
        @{ File = "config-v2-engine-backoff-60.json";   Read = { param($r) $r.ollama.retryBackoffSec }; Expected = 60;        Note = "retryBackoffSec 60" },
        @{ File = "config-v2-engine-chars-0-1.json";    Read = { param($r) $r.defaults.charsPerToken }; Expected = 0.1;       Note = "charsPerToken 0.1" },
        @{ File = "config-v2-engine-chars-10.json";     Read = { param($r) $r.defaults.charsPerToken }; Expected = 10;        Note = "charsPerToken 10" },
        @{ File = "config-v2-engine-warmup-true.json";  Read = { param($r) $r.ollama.warmup };          Expected = "True";    Note = "warmup true" },
        @{ File = "config-v2-engine-budget-enforce.json"; Read = { param($r) $r.defaults.budgetMode }; Expected = "enforce"; Note = "budgetMode enforce" },
        @{ File = "config-v2-engine-budget-warn.json";  Read = { param($r) $r.defaults.budgetMode };   Expected = "warn";    Note = "budgetMode warn" }
    )
    foreach ($case in $accepted) {
        Test-Case "AC-215 accepted: $($case.Note), no warning" {
            $path = Join-Path $fixtures $case.File
            $registry = Get-HarnessRegistry -ConfigPath $path
            Assert-Equal "loader value" $case.Expected (& $case.Read $registry)
            Assert-Equal "warnings" 0 @($registry.warnings).Count
            Assert-Equal "wrapper" "test-model-a" (Resolve-HarnessModel -Agent "spec" -ModelWasProvided $false -Config (Get-HarnessConfig -ConfigPath $path))
        }
    }

    Test-Case "AC-215 all five fields set together are all read, none warns" {
        $registry = Get-HarnessRegistry -ConfigPath (Join-Path $fixtures "config-v2-engine-all-set.json")
        Assert-Equal "maxAttempts" 3 $registry.ollama.maxAttempts
        Assert-Equal "retryBackoffSec" 7 $registry.ollama.retryBackoffSec
        Assert-Equal "warmup" "True" $registry.ollama.warmup
        Assert-Equal "charsPerToken" 4.5 $registry.defaults.charsPerToken
        Assert-Equal "budgetMode" "enforce" $registry.defaults.budgetMode
        Assert-Equal "warnings" 0 @($registry.warnings).Count
    }

    # -----------------------------------------------------------------------
    # AC-215 rejected boundaries (loader and wrapper)
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-215 rejected values ===" -ForegroundColor Cyan

    $rejected = @(
        @{ File = "config-v2-engine-invalid-attempts-0.json";        Field = "ollama.maxAttempts" },
        @{ File = "config-v2-engine-invalid-attempts-6.json";        Field = "ollama.maxAttempts" },
        @{ File = "config-v2-engine-invalid-attempts-fraction.json"; Field = "ollama.maxAttempts" },
        @{ File = "config-v2-engine-invalid-attempts-text.json";     Field = "ollama.maxAttempts" },
        @{ File = "config-v2-engine-invalid-backoff-negative.json";  Field = "ollama.retryBackoffSec" },
        @{ File = "config-v2-engine-invalid-backoff-61.json";        Field = "ollama.retryBackoffSec" },
        @{ File = "config-v2-engine-invalid-warmup-text.json";       Field = "ollama.warmup" },
        @{ File = "config-v2-engine-invalid-chars-0.json";           Field = "defaults.charsPerToken" },
        @{ File = "config-v2-engine-invalid-chars-10-1.json";        Field = "defaults.charsPerToken" },
        @{ File = "config-v2-engine-invalid-chars-text.json";        Field = "defaults.charsPerToken" },
        @{ File = "config-v2-engine-invalid-budget-off.json";        Field = "defaults.budgetMode" }
    )
    foreach ($case in $rejected) {
        Test-Case "AC-215 rejected: $($case.File)" {
            Assert-RejectedBoth $case.File (Join-Path $fixtures $case.File) $case.Field
        }
    }

    # Values that no fixture file holds, written to TEMP. Every value is an
    # exact literal chosen at a boundary or as a wrong type.
    $generated = @(
        @{ Field = "ollama.maxAttempts";      Slot = "Ollama";   Json = '"maxAttempts": -1' },
        @{ Field = "ollama.maxAttempts";      Slot = "Ollama";   Json = '"maxAttempts": 10000000000' },
        @{ Field = "ollama.maxAttempts";      Slot = "Ollama";   Json = '"maxAttempts": true' },
        @{ Field = "ollama.retryBackoffSec";  Slot = "Ollama";   Json = '"retryBackoffSec": 60.5' },
        @{ Field = "ollama.retryBackoffSec";  Slot = "Ollama";   Json = '"retryBackoffSec": "5"' },
        @{ Field = "ollama.retryBackoffSec";  Slot = "Ollama";   Json = '"retryBackoffSec": false' },
        @{ Field = "ollama.warmup";           Slot = "Ollama";   Json = '"warmup": 1' },
        @{ Field = "ollama.warmup";           Slot = "Ollama";   Json = '"warmup": 0' },
        @{ Field = "ollama.warmup";           Slot = "Ollama";   Json = '"warmup": "true"' },
        @{ Field = "defaults.charsPerToken";  Slot = "Defaults"; Json = '"charsPerToken": -3.5' },
        @{ Field = "defaults.charsPerToken";  Slot = "Defaults"; Json = '"charsPerToken": 11' },
        @{ Field = "defaults.charsPerToken";  Slot = "Defaults"; Json = '"charsPerToken": true' },
        @{ Field = "defaults.budgetMode";     Slot = "Defaults"; Json = '"budgetMode": "WARN"' },
        @{ Field = "defaults.budgetMode";     Slot = "Defaults"; Json = '"budgetMode": "Enforce"' },
        @{ Field = "defaults.budgetMode";     Slot = "Defaults"; Json = '"budgetMode": ""' },
        @{ Field = "defaults.budgetMode";     Slot = "Defaults"; Json = '"budgetMode": true' },
        @{ Field = "defaults.budgetMode";     Slot = "Defaults"; Json = '"budgetMode": 1' }
    )
    foreach ($case in $generated) {
        Test-Case "AC-215 rejected (generated): $($case.Json)" {
            $arguments = @{}
            $arguments[$case.Slot] = $case.Json
            Assert-RejectedBoth $case.Json (Write-EngineConfig @arguments) $case.Field
        }
    }

    Test-Case "AC-215 boundary table: only the integers 1 to 5 are valid maxAttempts" {
        $expected = [ordered]@{ "0" = $false; "1" = $true; "2" = $true; "3" = $true; "4" = $true; "5" = $true; "6" = $false }
        foreach ($entry in $expected.GetEnumerator()) {
            $path = Write-EngineConfig -Ollama ('"maxAttempts": ' + $entry.Key)
            $loaded = $true
            try { [void](Get-HarnessRegistry -ConfigPath $path) } catch { $loaded = $false }
            Assert-Equal "maxAttempts $($entry.Key) accepted" $entry.Value $loaded
        }
    }

    Test-Case "AC-215 boundary table: only the integers 0 to 60 are valid retryBackoffSec" {
        $expected = [ordered]@{ "-1" = $false; "0" = $true; "1" = $true; "59" = $true; "60" = $true; "61" = $false }
        foreach ($entry in $expected.GetEnumerator()) {
            $path = Write-EngineConfig -Ollama ('"retryBackoffSec": ' + $entry.Key)
            $loaded = $true
            try { [void](Get-HarnessRegistry -ConfigPath $path) } catch { $loaded = $false }
            Assert-Equal "retryBackoffSec $($entry.Key) accepted" $entry.Value $loaded
        }
    }

    Test-Case "AC-215 boundary table: charsPerToken is greater than 0 and at most 10" {
        $expected = [ordered]@{ "0" = $false; "0.0" = $false; "0.01" = $true; "0.1" = $true; "2.5" = $true; "3.5" = $true; "9.99" = $true; "10" = $true; "10.0" = $true; "10.01" = $false; "10.1" = $false }
        foreach ($entry in $expected.GetEnumerator()) {
            $path = Write-EngineConfig -Defaults ('"charsPerToken": ' + $entry.Key)
            $loaded = $true
            try { [void](Get-HarnessRegistry -ConfigPath $path) } catch { $loaded = $false }
            Assert-Equal "charsPerToken $($entry.Key) accepted" $entry.Value $loaded
        }
    }

    Test-Case "AC-215 the first violated rule is the one named when two fields are invalid" {
        $path = Write-EngineConfig -Ollama '"maxAttempts": 0, "retryBackoffSec": 61' -Defaults '"charsPerToken": 0, "budgetMode": "off"'
        Assert-Throws "two bad fields" { Get-HarnessRegistry -ConfigPath $path } "registry_invalid: ollama.maxAttempts"
    }

    Test-Case "AC-215 JSON null is treated as absent (the default applies, like the Phase 1 fields)" {
        $path = Write-EngineConfig -Ollama '"maxAttempts": null, "retryBackoffSec": null, "warmup": null' -Defaults '"charsPerToken": null, "budgetMode": null'
        Assert-EngineDefaults "null" (Get-HarnessRegistry -ConfigPath $path)
    }

    # -----------------------------------------------------------------------
    # AC-215 compatibility: v1 files and v2 files without the fields
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-215 defaults and compatibility ===" -ForegroundColor Cyan

    foreach ($case in @(
        @{ Label = "v1 current";                      Path = (Join-Path $fixtures "config-v1-current.json") },
        @{ Label = "v1 minimal";                      Path = (Join-Path $fixtures "config-v1-minimal.json") },
        @{ Label = "v1 with timeoutSec 10";           Path = (Join-Path $fixtures "config-v1-timeout-10.json") },
        @{ Label = "v2 current";                      Path = (Join-Path $fixtures "config-v2-current.json") },
        @{ Label = "v2 without any engine field";     Path = (Join-Path $fixtures "config-v2-engine-none.json") },
        @{ Label = "v2 with only a schemaVersion";    Path = (Write-TempText "v2-bare.json" '{ "schemaVersion": 2 }') },
        @{ Label = "no file at all";                  Path = (Join-Path $tempRoot "does-not-exist.json") }
    )) {
        Test-Case "AC-215 defaults: $($case.Label) loads with 2 / 5 / false / 3.5 / warn and no warning" {
            Assert-EngineDefaults $case.Label (Get-HarnessRegistry -ConfigPath $case.Path)
        }
    }

    Test-Case "AC-215 defaults: a file with ollama and defaults objects but none of the engine keys" {
        $path = Write-TempText "v2-partial.json" '{ "schemaVersion": 2, "ollama": { "url": "http://localhost:11434" }, "defaults": { "stripThinking": false } }'
        Assert-EngineDefaults "partial" (Get-HarnessRegistry -ConfigPath $path)
    }

    Test-Case "AC-215 defaults: a v1 file is not validated, so its values cannot trip the new rules" {
        $path = Write-TempText "v1-odd.json" '{ "defaultModel": "test-model-a", "maxAttempts": 99, "budgetMode": "off", "charsPerToken": 0 }'
        Assert-EngineDefaults "v1 odd" (Get-HarnessRegistry -ConfigPath $path)
    }

    Test-Case "AC-215 the engine keys are known: the same keys in the wrong section are unknown" {
        $path = Write-TempText "misplaced.json" '{ "schemaVersion": 2, "ollama": { "charsPerToken": 3.5 }, "defaults": { "maxAttempts": 2 } }'
        $warnings = @((Get-HarnessRegistry -ConfigPath $path).warnings)
        Assert-True "ollama.charsPerToken is unknown" ($warnings -contains "unknown_key:ollama.charsPerToken")
        Assert-True "defaults.maxAttempts is unknown" ($warnings -contains "unknown_key:defaults.maxAttempts")
    }

    Test-Case "AC-215 an unrelated unknown key still warns next to the new keys" {
        $path = Write-TempText "unknown-next.json" '{ "schemaVersion": 2, "ollama": { "maxAttempts": 2, "colour": "red" } }'
        $warnings = @((Get-HarnessRegistry -ConfigPath $path).warnings)
        Assert-Equal "warning count" 1 $warnings.Count
        Assert-True "names the unknown key" ($warnings -contains "unknown_key:ollama.colour")
    }

    Test-Case "AC-215 an already normalized registry is returned as it is (the new fields survive)" {
        $registry = Get-HarnessRegistry -ConfigPath (Join-Path $fixtures "config-v2-engine-all-set.json")
        $again = ConvertTo-HarnessRegistry -Config $registry
        Assert-Equal "maxAttempts" 3 $again.ollama.maxAttempts
        Assert-Equal "budgetMode" "enforce" $again.defaults.budgetMode
    }

    Test-Case "AC-215 the normalized registry has the engine members in ollama and defaults" {
        $registry = Get-HarnessRegistry -ConfigPath (Join-Path $fixtures "config-v2-engine-none.json")
        Assert-Equal "ollama members" "url,healthTimeoutSec,maxAttempts,retryBackoffSec,warmup" (($registry.ollama.PSObject.Properties.Name) -join ",")
        Assert-Equal "defaults members" "profile,options,timeoutSec,safetyMarginRatio,stripThinking,charsPerToken,budgetMode" (($registry.defaults.PSObject.Properties.Name) -join ",")
    }

    # -----------------------------------------------------------------------
    # AC-215 the frozen Phase 1 baseline resolves to the defaults, unchanged
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-215 frozen baseline (config-v2-phase1-baseline.json) ===" -ForegroundColor Cyan

    $baselinePath = Join-Path $fixtures "config-v2-phase1-baseline.json"
    $baselineRaw = Get-RawJson $baselinePath

    Test-Case "AC-215 baseline: the frozen file has none of the new keys (the expectations below rest on it)" {
        foreach ($name in @("maxAttempts", "retryBackoffSec", "warmup")) {
            Assert-True "ollama.$name absent" ($null -eq $baselineRaw.ollama.PSObject.Properties[$name])
        }
        foreach ($name in @("charsPerToken", "budgetMode")) {
            Assert-True "defaults.$name absent" ($null -eq $baselineRaw.defaults.PSObject.Properties[$name])
        }
    }

    Test-Case "AC-215 baseline: loads with the engine defaults, budgetMode warn, no warning" {
        $registry = Get-HarnessRegistry -ConfigPath $baselinePath
        Assert-EngineDefaults "baseline" $registry
        Assert-Equal "warnings" 0 @($registry.warnings).Count
        Assert-Equal "wrapper" $baselineRaw.profiles.deep.model (Resolve-HarnessModel -Agent "spec-reviser" -ModelWasProvided $false -Config (Get-HarnessConfig -ConfigPath $baselinePath))
    }

    Test-Case "AC-215 baseline: every agent resolves to the raw JSON's model, timeout, think, window and options" {
        $registry = Get-HarnessRegistry -ConfigPath $baselinePath
        foreach ($agent in $baselineRaw.agents.PSObject.Properties) {
            $profileRaw = $baselineRaw.profiles.($agent.Value.profile)
            $record = Resolve-HarnessExecution -Agent $agent.Name -Registry $registry
            Assert-Equal "$($agent.Name) model" $profileRaw.model $record.model
            Assert-Equal "$($agent.Name) timeoutSec" $profileRaw.timeoutSec $record.timeoutSec
            Assert-Equal "$($agent.Name) think" $profileRaw.think $record.think
            Assert-Equal "$($agent.Name) contextWindow" $profileRaw.contextWindow $record.contextWindow
            Assert-Equal "$($agent.Name) reservedOutputTokens" $profileRaw.reservedOutputTokens $record.reservedOutputTokens
            Assert-Equal "$($agent.Name) num_ctx" $profileRaw.contextWindow $record.options.num_ctx
            $expectedTemperature = $baselineRaw.defaults.options.temperature
            if ($null -ne $profileRaw.options -and $null -ne $profileRaw.options.PSObject.Properties["temperature"]) { $expectedTemperature = $profileRaw.options.temperature }
            Assert-Equal "$($agent.Name) temperature" $expectedTemperature $record.options.temperature
        }
    }

    Test-Case "AC-215 baseline: the execution record keeps exactly its eleven Phase 1 fields (the engine fields live on the registry)" {
        $registry = Get-HarnessRegistry -ConfigPath $baselinePath
        $record = Resolve-HarnessExecution -Agent "spec-reviewer" -Registry $registry
        Assert-Equal "fields" "agent,profile,model,modelSource,parametersFrom,contextWindow,timeoutSec,reservedOutputTokens,options,think,warnings" (($record.PSObject.Properties.Name) -join ",")
    }

    Test-Case "AC-215 the engine values reach the registry that callers pass to the engine, through wrapper and loader alike" {
        $config = Get-HarnessConfig -ConfigPath (Join-Path $fixtures "config-v2-engine-all-set.json")
        $registry = ConvertTo-HarnessRegistry -Config $config
        Assert-Equal "maxAttempts" 3 $registry.ollama.maxAttempts
        Assert-Equal "retryBackoffSec" 7 $registry.ollama.retryBackoffSec
        Assert-Equal "charsPerToken" 4.5 $registry.defaults.charsPerToken
        Assert-Equal "profile window" 10000 $registry.profiles.alpha.contextWindow
    }
}
finally {
    $env:AI_HARNESS_MODEL = $originalModelVariable
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
