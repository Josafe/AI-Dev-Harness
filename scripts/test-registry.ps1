<#
.SYNOPSIS
    Offline, in-process tests for the configuration registry library
    (Phase 1, WP-1A): Get-HarnessRegistry, Resolve-HarnessExecution,
    Get-HarnessRegistryModels and the Resolve-HarnessModel wrapper.

.DESCRIPTION
    Covers AC-101, AC-102, AC-103, AC-105 (function part), AC-106 and AC-109
    (record part) of specs\harness-phase-1-config-registry.md.

    - No network, no Ollama, no child process: only scripts\lib\config.ps1 is
      dot-sourced.
    - Fixtures are read from tests\fixtures; everything written goes under a
      unique folder in TEMP, removed at the end.
    - AI_HARNESS_MODEL is set and restored by the suite itself.
    - Expected values come from the raw JSON of the fixtures or from literals
      of this file (synthetic names only), never from the code under test.
    - Assertions match only the harness's own wording (registry_invalid:,
      invalid_arguments:, warning codes, the rule 7 message, resolved values).
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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-harness-registry-tests-" + [guid]::NewGuid().ToString())
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
    param([string]$What, [scriptblock]$Action, [string]$Prefix, [string]$Contains = "")

    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }

    if ($null -eq $message) { throw "$What : nothing was thrown (expected '$Prefix')" }
    if (-not $message.StartsWith($Prefix, [System.StringComparison]::Ordinal)) {
        throw "$What : expected a message starting with '$Prefix', got '$message'"
    }
    if ($Contains -and $message.IndexOf($Contains, [System.StringComparison]::Ordinal) -lt 0) {
        throw "$What : expected the message to contain '$Contains', got '$message'"
    }
}

function Use-ModelVariable {
    param($Value, [scriptblock]$Action)

    $before = $env:AI_HARNESS_MODEL
    try {
        $env:AI_HARNESS_MODEL = $Value
        & $Action
    }
    finally { $env:AI_HARNESS_MODEL = $before }
}

# Loads a registry for a fixture; a failure is recorded as a failed test (not
# fatal), so that every later case reports its own result.
function Import-Registry {
    param([string]$Label, [string]$Path)

    try { return (Get-HarnessRegistry -ConfigPath $Path) }
    catch {
        $script:failed++
        Write-Host "[FAIL] load registry: $Label" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Get-RawJson {
    param([string]$Path)
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# "key=value" pairs of an options object, sorted, so key order never matters.
function Get-Pairs {
    param($Options)

    if ($null -eq $Options) { return "" }
    return (@($Options.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ";")
}

function Write-TempConfig {
    param([string]$Name, $Object)

    $path = Join-Path $tempRoot $Name
    $json = $Object | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Write-TempText {
    param([string]$Name, [string]$Text)

    $path = Join-Path $tempRoot $Name
    [System.IO.File]::WriteAllText($path, $Text, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

# Expected model of the golden table, computed from the raw v1 JSON only.
function Get-ExpectedModel {
    param($V1Raw, [string]$Agent, $ExplicitModel, $VariableValue)

    if ($null -ne $ExplicitModel) { return $ExplicitModel }
    if (-not [string]::IsNullOrWhiteSpace($VariableValue)) { return $VariableValue }
    if ($V1Raw.agentModels.PSObject.Properties[$Agent]) { return $V1Raw.agentModels.$Agent }
    return $V1Raw.defaultModel
}

$v1Path = Join-Path $fixtures "config-v1-current.json"
$v2Path = Join-Path $fixtures "config-v2-current.json"
$v1Raw = Get-RawJson $v1Path
$v2Raw = Get-RawJson $v2Path

$agentsUnderTest = @("spec", "spec-reviewer", "spec-reviser", "developer", "agent-without-entry")
$explicitName = "test-explicit-model"
$variableName = "test-variable-model"

try {
    # -----------------------------------------------------------------------
    # AC-101 Golden table: same model under v1 and its v2 translation
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-101 golden model resolution ===" -ForegroundColor Cyan

    $golden = @(
        @{ Label = "v1"; Path = $v1Path },
        @{ Label = "v2"; Path = $v2Path }
    )
    foreach ($entry in $golden) {
        $entry.Config = Get-HarnessConfig -ConfigPath $entry.Path
        $entry.Registry = Import-Registry $entry.Label $entry.Path
    }

    $cases = @(
        @{ Label = "no override"; Explicit = $null; Variable = $null },
        @{ Label = "-Model";      Explicit = $explicitName; Variable = $null },
        @{ Label = "variable";    Explicit = $null; Variable = $variableName },
        @{ Label = "both";        Explicit = $explicitName; Variable = $variableName }
    )

    foreach ($agent in $agentsUnderTest) {
        foreach ($case in $cases) {
            Test-Case "AC-101 $agent / $($case.Label)" {
                $expected = Get-ExpectedModel -V1Raw $v1Raw -Agent $agent -ExplicitModel $case.Explicit -VariableValue $case.Variable
                Use-ModelVariable $case.Variable {
                    foreach ($entry in $golden) {
                        $wrapperArguments = @{ Agent = $agent; ModelWasProvided = ($null -ne $case.Explicit); Config = $entry.Config }
                        if ($null -ne $case.Explicit) { $wrapperArguments.ExplicitModel = $case.Explicit }
                        Assert-Equal "$($entry.Label) Resolve-HarnessModel" $expected (Resolve-HarnessModel @wrapperArguments)

                        $executionArguments = @{ Agent = $agent; Registry = $entry.Registry }
                        if ($null -ne $case.Explicit) { $executionArguments.Model = $case.Explicit }
                        Assert-Equal "$($entry.Label) Resolve-HarnessExecution" $expected (Resolve-HarnessExecution @executionArguments).model
                    }
                }
            }
        }
    }

    Test-Case "AC-101 the golden fixtures differ in format (v1 has no schemaVersion, v2 has 2)" {
        Assert-True "v1 file has no schemaVersion" ($null -eq $v1Raw.PSObject.Properties["schemaVersion"])
        Assert-Equal "v2 file schemaVersion" 2 $v2Raw.schemaVersion
    }

    # -----------------------------------------------------------------------
    # AC-102 v1 conversion and normalization
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-102 v1 conversion and normalization ===" -ForegroundColor Cyan

    Test-Case "AC-102 v1 file is converted to a v2 registry" {
        $registry = ($golden | Where-Object { $_.Label -eq "v1" }).Registry
        Assert-Equal "schemaVersion" 2 $registry.schemaVersion

        $v1Models = @($v1Raw.agentModels.PSObject.Properties.Value + $v1Raw.defaultModel | Select-Object -Unique)
        Assert-Equal "profile count" $v1Models.Count @($registry.profiles.PSObject.Properties).Count
        foreach ($model in $v1Models) {
            $profile = $registry.profiles."legacy:$model"
            Assert-True "profile legacy:$model exists" ($null -ne $profile)
            Assert-Equal "profile legacy:$model model" $model $profile.model
        }
        foreach ($agentEntry in $v1Raw.agentModels.PSObject.Properties) {
            Assert-Equal "agent $($agentEntry.Name) profile" "legacy:$($agentEntry.Value)" $registry.agents.($agentEntry.Name).profile
        }
        Assert-Equal "defaults.profile" "legacy:$($v1Raw.defaultModel)" $registry.defaults.profile
        Assert-Equal "ollama.url" $v1Raw.ollamaUrl $registry.ollama.url
        Assert-Equal "defaults.timeoutSec" $v1Raw.timeoutSec $registry.defaults.timeoutSec
        Assert-Equal "defaults.stripThinking" $v1Raw.stripThinking $registry.defaults.stripThinking
        Assert-Equal "defaults.options" (Get-Pairs $v1Raw.options) (Get-Pairs $registry.defaults.options)
        Assert-True "contextWindow stays absent in v1 profiles" ($null -eq $registry.profiles."legacy:$($v1Raw.defaultModel)".contextWindow)
        Assert-Equal "warnings" 0 @($registry.warnings).Count
    }

    foreach ($agent in $agentsUnderTest) {
        Test-Case "AC-102 effective parameters equal under both fixtures: $agent" {
            $v1Record = Resolve-HarnessExecution -Agent $agent -Registry ($golden | Where-Object { $_.Label -eq "v1" }).Registry
            $v2Record = Resolve-HarnessExecution -Agent $agent -Registry ($golden | Where-Object { $_.Label -eq "v2" }).Registry
            Assert-Equal "timeoutSec v1 vs raw" $v1Raw.timeoutSec $v1Record.timeoutSec
            Assert-Equal "timeoutSec v1 vs v2" $v1Record.timeoutSec $v2Record.timeoutSec
            Assert-Equal "options v1 vs raw" (Get-Pairs $v1Raw.options) (Get-Pairs $v1Record.options)
            Assert-Equal "options v1 vs v2" (Get-Pairs $v1Record.options) (Get-Pairs $v2Record.options)
        }
    }

    Test-Case "AC-102 stripThinking and URL equal under both fixtures" {
        foreach ($entry in $golden) {
            Assert-Equal "$($entry.Label) stripThinking" $v1Raw.stripThinking $entry.Registry.defaults.stripThinking
            Assert-Equal "$($entry.Label) url" $v1Raw.ollamaUrl $entry.Registry.ollama.url
        }
    }

    Test-Case "AC-102 a minimal v1 file gets the defaults" {
        $registry = Get-HarnessRegistry -ConfigPath (Join-Path $fixtures "config-v1-minimal.json")
        Assert-Equal "defaults.timeoutSec" 600 $registry.defaults.timeoutSec
        Assert-Equal "defaults.stripThinking" "True" $registry.defaults.stripThinking
        Assert-Equal "ollama.url" "http://localhost:11434" $registry.ollama.url
        Assert-Equal "ollama.healthTimeoutSec" 15 $registry.ollama.healthTimeoutSec
        Assert-Equal "defaults.safetyMarginRatio" 0.1 $registry.defaults.safetyMarginRatio
        Assert-Equal "defaults.options" "" (Get-Pairs $registry.defaults.options)
        $record = Resolve-HarnessExecution -Agent "spec" -Registry $registry
        Assert-Equal "record options" "" (Get-Pairs $record.options)
        Assert-Equal "record timeoutSec" 600 $record.timeoutSec
    }

    Test-Case "AC-102 a missing file loads as an empty registry" {
        $registry = Get-HarnessRegistry -ConfigPath (Join-Path $tempRoot "does-not-exist.json")
        Assert-Equal "profile count" 0 @($registry.profiles.PSObject.Properties).Count
        Assert-Equal "agent count" 0 @($registry.agents.PSObject.Properties).Count
        Assert-Equal "defaults.timeoutSec" 600 $registry.defaults.timeoutSec
    }

    Test-Case "AC-102 an empty file and an empty object load as empty registries" {
        foreach ($text in @("", "{}")) {
            $path = Write-TempText "empty-case.json" $text
            $registry = Get-HarnessRegistry -ConfigPath $path
            Assert-Equal "profile count for '$text'" 0 @($registry.profiles.PSObject.Properties).Count
        }
    }

    Test-Case "AC-102 the wrapper works on an empty configuration only with AI_HARNESS_MODEL" {
        $empty = [pscustomobject]@{}
        Use-ModelVariable $variableName {
            Assert-Equal "with variable" $variableName (Resolve-HarnessModel -Agent "spec" -ModelWasProvided $false -Config $empty)
        }
        Use-ModelVariable $null {
            Assert-Throws "without variable" { Resolve-HarnessModel -Agent "spec" -ModelWasProvided $false -Config $empty } "No model configured."
            Assert-Throws "null config" { Resolve-HarnessModel -Agent "spec" -ModelWasProvided $false -Config $null } "No model configured."
            Assert-Throws "missing file" {
                Resolve-HarnessModel -Agent "spec" -ModelWasProvided $false -Config (Get-HarnessConfig -ConfigPath (Join-Path $tempRoot "does-not-exist.json"))
            } "No model configured."
        }
    }

    Test-Case "AC-102 v1 oddities keep today's resolution (blank agent entry, models differing only by case)" {
        $oddPath = Write-TempText "v1-odd.json" '{ "defaultModel": "test-model-a", "agentModels": { "blank": "", "upper": "Test-Model-X", "lower": "test-model-x" } }'
        $config = Get-HarnessConfig -ConfigPath $oddPath
        Use-ModelVariable $null {
            Assert-Equal "blank agent entry is returned, not replaced by the default" "" (Resolve-HarnessModel -Agent "blank" -ModelWasProvided $false -Config $config)
            Assert-Equal "upper-case model keeps its case" "Test-Model-X" (Resolve-HarnessModel -Agent "upper" -ModelWasProvided $false -Config $config)
            Assert-Equal "lower-case model keeps its case" "test-model-x" (Resolve-HarnessModel -Agent "lower" -ModelWasProvided $false -Config $config)
            Assert-Equal "default" "test-model-a" (Resolve-HarnessModel -Agent "other" -ModelWasProvided $false -Config $config)
        }
        $blankDefault = Get-HarnessConfig -ConfigPath (Write-TempText "v1-blank-default.json" '{ "defaultModel": "", "agentModels": { "spec": "test-model-a" } }')
        Use-ModelVariable $null {
            Assert-Throws "blank defaultModel" { Resolve-HarnessModel -Agent "other" -ModelWasProvided $false -Config $blankDefault } "No model configured."
        }
    }

    Test-Case "AC-102 the wrapper returns a blank explicit model unchanged and never touches the configuration" {
        Use-ModelVariable $variableName {
            Assert-Equal "blank" "" (Resolve-HarnessModel -Agent "spec" -ModelWasProvided $true -ExplicitModel "" -Config $null)
            Assert-Equal "explicit" $explicitName (Resolve-HarnessModel -Agent "spec" -ModelWasProvided $true -ExplicitModel $explicitName -Config $null)
        }
    }

    Test-Case "AC-102 the distinct profile models are listed in profile order" {
        $v2Registry = ($golden | Where-Object { $_.Label -eq "v2" }).Registry
        $v1Registry = ($golden | Where-Object { $_.Label -eq "v1" }).Registry
        $expectedV2 = @($v2Raw.profiles.PSObject.Properties | ForEach-Object { $_.Value.model } | Select-Object -Unique)
        Assert-Equal "v2 models" ($expectedV2 -join ",") ((Get-HarnessRegistryModels -Registry $v2Registry) -join ",")
        Assert-Equal "v2 profile order" "fast,deep" (($v2Registry.profiles.PSObject.Properties.Name) -join ",")
        $expectedV1 = @($v1Raw.agentModels.PSObject.Properties.Value + $v1Raw.defaultModel | Select-Object -Unique)
        Assert-Equal "v1 models" ($expectedV1 -join ",") ((Get-HarnessRegistryModels -Registry $v1Registry) -join ",")
        Assert-Equal "empty registry" 0 @(Get-HarnessRegistryModels -Registry (Get-HarnessRegistry -ConfigPath (Join-Path $tempRoot "does-not-exist.json"))).Count
    }

    # -----------------------------------------------------------------------
    # AC-103 Invalid v2 files are rejected; warnings are not errors
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-103 validation ===" -ForegroundColor Cyan

    $invalid = @(
        @{ File = "config-v2-invalid-schema.json";          Rule = "schemaVersion" },
        @{ File = "config-v2-invalid-no-model.json";        Rule = "profile_model" },
        @{ File = "config-v2-invalid-default-profile.json"; Rule = "defaults_profile" },
        @{ File = "config-v2-invalid-agent-profile.json";   Rule = "agent_profile" },
        @{ File = "config-v2-invalid-timeout-low.json";     Rule = "timeoutSec" },
        @{ File = "config-v2-invalid-timeout-high.json";    Rule = "timeoutSec" },
        @{ File = "config-v2-invalid-margin.json";          Rule = "context_margin" },
        @{ File = "config-v2-invalid-num-ctx.json";         Rule = "num_ctx" },
        @{ File = "config-v2-invalid-think.json";           Rule = "think" }
    )
    foreach ($case in $invalid) {
        Test-Case "AC-103 rejected: $($case.File)" {
            $path = Join-Path $fixtures $case.File
            Assert-Throws "loader" { Get-HarnessRegistry -ConfigPath $path } "registry_invalid: $($case.Rule)"
            Assert-Throws "wrapper" { Resolve-HarnessModel -Agent "spec" -ModelWasProvided $false -Config (Get-HarnessConfig -ConfigPath $path) } "registry_invalid: $($case.Rule)"
        }
    }

    Test-Case "AC-103 boundary values" {
        $base = { param($Profile, $Defaults)
            $o = [ordered]@{ schemaVersion = 2; profiles = [ordered]@{ alpha = $Profile } }
            if ($Defaults) { $o.defaults = $Defaults }
            return $o
        }
        foreach ($seconds in @(30, 14400)) {
            $path = Write-TempConfig "bound-timeout-$seconds.json" (& $base ([ordered]@{ model = "test-model-a"; timeoutSec = $seconds }))
            Assert-Equal "timeoutSec $seconds accepted" $seconds (Get-HarnessRegistry -ConfigPath $path).profiles.alpha.timeoutSec
        }
        $defaultTimeout = Write-TempConfig "bound-default-timeout.json" (& $base ([ordered]@{ model = "test-model-a" }) ([ordered]@{ timeoutSec = 29 }))
        Assert-Throws "defaults.timeoutSec 29" { Get-HarnessRegistry -ConfigPath $defaultTimeout } "registry_invalid: timeoutSec"

        $fits = Write-TempConfig "bound-margin-ok.json" (& $base ([ordered]@{ model = "test-model-a"; contextWindow = 10000; reservedOutputTokens = 8999 }))
        Assert-Equal "margin just fits" 8999 (Get-HarnessRegistry -ConfigPath $fits).profiles.alpha.reservedOutputTokens
        $tight = Write-TempConfig "bound-margin-bad.json" (& $base ([ordered]@{ model = "test-model-a"; contextWindow = 10000; reservedOutputTokens = 9000 }))
        Assert-Throws "margin equal to the window" { Get-HarnessRegistry -ConfigPath $tight } "registry_invalid: context_margin"

        $zero = Write-TempConfig "bound-reserved-zero.json" (& $base ([ordered]@{ model = "test-model-a"; reservedOutputTokens = 0 }))
        Assert-Throws "reservedOutputTokens 0" { Get-HarnessRegistry -ConfigPath $zero } "registry_invalid: reservedOutputTokens"
        $window = Write-TempConfig "bound-window-negative.json" (& $base ([ordered]@{ model = "test-model-a"; contextWindow = -1 }))
        Assert-Throws "contextWindow -1" { Get-HarnessRegistry -ConfigPath $window } "registry_invalid: contextWindow"

        $matching = Write-TempConfig "bound-num-ctx-ok.json" (& $base ([ordered]@{ model = "test-model-a"; contextWindow = 8192; options = [ordered]@{ num_ctx = 8192 } }) ([ordered]@{ options = [ordered]@{ num_ctx = 8192 } }))
        Assert-Equal "equal num_ctx accepted" 8192 (Resolve-HarnessExecution -Agent "x" -Registry (Get-HarnessRegistry -ConfigPath $matching) -Profile "alpha").options.num_ctx
        $inDefaults = Write-TempConfig "bound-num-ctx-defaults.json" (& $base ([ordered]@{ model = "test-model-a"; contextWindow = 8192 }) ([ordered]@{ options = [ordered]@{ num_ctx = 4096 } }))
        Assert-Throws "defaults.options.num_ctx differs" { Get-HarnessRegistry -ConfigPath $inDefaults } "registry_invalid: num_ctx"

        $blank = Write-TempConfig "bound-blank-model.json" (& $base ([ordered]@{ model = "   " }))
        Assert-Throws "blank model" { Get-HarnessRegistry -ConfigPath $blank } "registry_invalid: profile_model"
        $notObject = Write-TempText "bound-profiles-string.json" '{ "schemaVersion": 2, "profiles": "alpha" }'
        Assert-Throws "profiles is not an object" { Get-HarnessRegistry -ConfigPath $notObject } "registry_invalid: structure"
        $ratio = Write-TempConfig "bound-ratio.json" (& $base ([ordered]@{ model = "test-model-a" }) ([ordered]@{ safetyMarginRatio = "lots" }))
        Assert-Throws "safetyMarginRatio is not a number" { Get-HarnessRegistry -ConfigPath $ratio } "registry_invalid: safetyMarginRatio"
    }

    # The margin rule (FR-103): contextWindow > reservedOutputTokens + ceil(ratio x contextWindow).
    # Expected outcomes are literals worked out by hand, not computed from the code.
    #   ratio 0.5,  window 1000: margin 500    -> reserved 499 fits; 500 and 501 do not
    #   ratio 0.15, window 1000: margin 150    -> reserved 849 fits; 850 does not
    #   ratio 0.1,  window 8191: 819.1 -> 820  -> reserved 7370 fits; 7371 does not
    #     (rounding the margin down to 819 would accept 7371)
    $marginAccepted = @(
        @{ File = "config-v2-margin-half-ok.json";     Reserved = 499;  Note = "ratio 0.5, window 1000" },
        @{ File = "config-v2-margin-015-ok.json";      Reserved = 849;  Note = "ratio 0.15, window 1000" },
        @{ File = "config-v2-margin-fraction-ok.json"; Reserved = 7370; Note = "ratio 0.1, window 8191 (margin 819.1)" }
    )
    foreach ($case in $marginAccepted) {
        Test-Case "AC-103 margin accepted: $($case.Note), reserved $($case.Reserved)" {
            $path = Join-Path $fixtures $case.File
            Assert-Equal "loader" $case.Reserved (Get-HarnessRegistry -ConfigPath $path).profiles.alpha.reservedOutputTokens
            Assert-Equal "wrapper" "test-model-a" (Resolve-HarnessModel -Agent "spec" -ModelWasProvided $false -Config (Get-HarnessConfig -ConfigPath $path))
        }
    }

    $marginRejected = @(
        @{ File = "config-v2-invalid-margin-half-500.json";     Reserved = 500;  Note = "ratio 0.5, window 1000" },
        @{ File = "config-v2-invalid-margin-half-501.json";     Reserved = 501;  Note = "ratio 0.5, window 1000" },
        @{ File = "config-v2-invalid-margin-015-850.json";      Reserved = 850;  Note = "ratio 0.15, window 1000" },
        @{ File = "config-v2-invalid-margin-fraction-7371.json"; Reserved = 7371; Note = "ratio 0.1, window 8191 (margin 819.1)" }
    )
    foreach ($case in $marginRejected) {
        Test-Case "AC-103 margin rejected: $($case.Note), reserved $($case.Reserved)" {
            $path = Join-Path $fixtures $case.File
            Assert-Equal "fixture reserved value" $case.Reserved (Get-RawJson $path).profiles.alpha.reservedOutputTokens
            Assert-Throws "loader" { Get-HarnessRegistry -ConfigPath $path } "registry_invalid: context_margin"
            Assert-Throws "wrapper" { Resolve-HarnessModel -Agent "spec" -ModelWasProvided $false -Config (Get-HarnessConfig -ConfigPath $path) } "registry_invalid: context_margin"
        }
    }

    # ollama.healthTimeoutSec: an integer from 1 to 600; ollama.url: a non-blank string (FR-103).
    foreach ($case in @(
        @{ File = "config-v2-health-1.json";   Value = 1 },
        @{ File = "config-v2-health-600.json"; Value = 600 }
    )) {
        Test-Case "AC-114 healthTimeoutSec accepted: $($case.Value)" {
            $path = Join-Path $fixtures $case.File
            Assert-Equal "loader" $case.Value (Get-HarnessRegistry -ConfigPath $path).ollama.healthTimeoutSec
            Assert-Equal "wrapper" "test-model-a" (Resolve-HarnessModel -Agent "spec" -ModelWasProvided $false -Config (Get-HarnessConfig -ConfigPath $path))
        }
    }

    foreach ($case in @(
        @{ File = "config-v2-invalid-health-0.json";        Rule = "ollama.healthTimeoutSec" },
        @{ File = "config-v2-invalid-health-negative.json"; Rule = "ollama.healthTimeoutSec" },
        @{ File = "config-v2-invalid-health-601.json";      Rule = "ollama.healthTimeoutSec" },
        @{ File = "config-v2-invalid-health-text.json";     Rule = "ollama.healthTimeoutSec" },
        @{ File = "config-v2-invalid-health-fraction.json"; Rule = "ollama.healthTimeoutSec" },
        @{ File = "config-v2-invalid-url-blank.json";       Rule = "ollama.url" }
    )) {
        Test-Case "AC-114 rejected: $($case.File)" {
            $path = Join-Path $fixtures $case.File
            Assert-Throws "loader" { Get-HarnessRegistry -ConfigPath $path } "registry_invalid: $($case.Rule)"
            Assert-Throws "wrapper" { Resolve-HarnessModel -Agent "spec" -ModelWasProvided $false -Config (Get-HarnessConfig -ConfigPath $path) } "registry_invalid: $($case.Rule)"
        }
    }

    Test-Case "AC-114 a whitespace-only or non-string ollama.url is rejected" {
        foreach ($text in @('"   "', '5')) {
            $path = Write-TempText "url-odd.json" ('{ "schemaVersion": 2, "ollama": { "url": ' + $text + ' } }')
            Assert-Throws "url $text" { Get-HarnessRegistry -ConfigPath $path } "registry_invalid: ollama.url"
        }
    }

    Test-Case "AC-114 a v1 file without the field keeps the default 15 and still loads; v1 values are not validated" {
        Assert-Equal "v1 minimal" 15 (Get-HarnessRegistry -ConfigPath (Join-Path $fixtures "config-v1-minimal.json")).ollama.healthTimeoutSec
        Assert-Equal "v1 current" 15 (Get-HarnessRegistry -ConfigPath $v1Path).ollama.healthTimeoutSec
        $blankV1 = Write-TempText "v1-blank-url.json" '{ "ollamaUrl": "", "defaultModel": "test-model-a" }'
        Assert-Equal "v1 blank url loads" "" (Get-HarnessRegistry -ConfigPath $blankV1).ollama.url
    }

    Test-Case "AC-114 a v2 file without the field or without ollama keeps the defaults" {
        $noOllama = Write-TempText "v2-no-ollama.json" '{ "schemaVersion": 2 }'
        $registry = Get-HarnessRegistry -ConfigPath $noOllama
        Assert-Equal "healthTimeoutSec" 15 $registry.ollama.healthTimeoutSec
        Assert-Equal "url" "http://localhost:11434" $registry.ollama.url
        $urlOnly = Write-TempText "v2-url-only.json" '{ "schemaVersion": 2, "ollama": { "url": "http://localhost:11434" } }'
        Assert-Equal "healthTimeoutSec with url only" 15 (Get-HarnessRegistry -ConfigPath $urlOnly).ollama.healthTimeoutSec
    }

    Test-Case "AC-103 an explicit schemaVersion 1 or null is invalid, not v1" {
        foreach ($text in @("1", "null")) {
            $path = Write-TempText "schema-explicit.json" ('{ "schemaVersion": ' + $text + ', "defaultModel": "test-model-a" }')
            Assert-Throws "schemaVersion $text" { Get-HarnessRegistry -ConfigPath $path } "registry_invalid: schemaVersion"
        }
    }

    Test-Case "AC-103 a v1 file is not validated (timeoutSec 10 loads)" {
        $path = Join-Path $fixtures "config-v1-timeout-10.json"
        $registry = Get-HarnessRegistry -ConfigPath $path
        Assert-Equal "defaults.timeoutSec" 10 $registry.defaults.timeoutSec
        Assert-Equal "record timeoutSec" 10 (Resolve-HarnessExecution -Agent "spec" -Registry $registry).timeoutSec
    }

    Test-Case "AC-103 unknown keys and a non-loopback URL are warnings, not errors" {
        $registry = Get-HarnessRegistry -ConfigPath (Join-Path $fixtures "config-v2-warnings.json")
        $warnings = @($registry.warnings)
        Assert-True "unknown_key: present" (@($warnings | Where-Object { $_.StartsWith("unknown_key:", [System.StringComparison]::Ordinal) }).Count -ge 1)
        Assert-True "unknown_key names the profile key" ($warnings -contains "unknown_key:profiles.alpha.colour")
        Assert-True "unknown_key names the top-level key" ($warnings -contains "unknown_key:extraSection")
        Assert-True "non_loopback_ollama_url present" ($warnings -contains "non_loopback_ollama_url")
        Assert-Equal "the file still resolves" "test-model-a" (Resolve-HarnessExecution -Agent "spec" -Registry $registry).model
    }

    Test-Case "AC-103 loopback URLs raise no warning" {
        foreach ($url in @("http://localhost:11434", "http://127.0.0.1:11434", "http://[::1]:11434")) {
            $path = Write-TempText "loopback.json" ('{ "schemaVersion": 2, "ollama": { "url": "' + $url + '" } }')
            Assert-Equal "warnings for $url" 0 @((Get-HarnessRegistry -ConfigPath $path).warnings).Count
        }
    }

    Test-Case "AC-103 valid v2 fixtures raise no warning" {
        Assert-Equal "config-v2-current warnings" 0 @(($golden | Where-Object { $_.Label -eq "v2" }).Registry.warnings).Count
    }

    # -----------------------------------------------------------------------
    # AC-105 (function part) -Model with -Profile
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-105 -Model with -Profile ===" -ForegroundColor Cyan

    foreach ($entry in $golden) {
        Test-Case "AC-105 rejected under $($entry.Label)" {
            $registry = $entry.Registry
            $profileName = @($registry.profiles.PSObject.Properties)[0].Name
            Assert-Throws "both" { Resolve-HarnessExecution -Agent "spec" -Registry $registry -Model $explicitName -Profile $profileName } "invalid_arguments:"
            Assert-Throws "both, blank model" { Resolve-HarnessExecution -Agent "spec" -Registry $registry -Model "" -Profile $profileName } "invalid_arguments:"
            Assert-Throws "both, blank profile" { Resolve-HarnessExecution -Agent "spec" -Registry $registry -Model $explicitName -Profile "" } "invalid_arguments:"
            Use-ModelVariable $variableName {
                Assert-Throws "both with the variable set" { Resolve-HarnessExecution -Agent "spec" -Registry $registry -Model $explicitName -Profile $profileName } "invalid_arguments:"
            }
        }
    }

    # -----------------------------------------------------------------------
    # AC-106 Selection rules and resolved record
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-106 selection rules and record ===" -ForegroundColor Cyan

    # config-v2-current.json plus one extra profile that shares no model.
    $selectionObject = Get-RawJson $v2Path
    $selectionObject.profiles | Add-Member -NotePropertyName "extra" -NotePropertyValue ([pscustomobject]@{
        model = "test-model-extra"; contextWindow = 8192; timeoutSec = 120; reservedOutputTokens = 1024; think = $true
        options = [pscustomobject]@{ seed = 7 }
    })
    $selectionPath = Write-TempConfig "selection.json" $selectionObject
    $selection = Import-Registry "selection" $selectionPath

    $fastModel = $v2Raw.profiles.fast.model
    $deepModel = $v2Raw.profiles.deep.model
    $expectedFields = "agent,profile,model,modelSource,parametersFrom,contextWindow,timeoutSec,reservedOutputTokens,options,think,warnings"

    Test-Case "AC-106 order: agent profile, then default profile" {
        Use-ModelVariable $null {
            $agentRecord = Resolve-HarnessExecution -Agent "spec-reviewer" -Registry $selection
            Assert-Equal "agent source" "agent" $agentRecord.modelSource
            Assert-Equal "agent profile" "deep" $agentRecord.profile
            Assert-Equal "agent model" $deepModel $agentRecord.model
            $defaultRecord = Resolve-HarnessExecution -Agent "agent-without-entry" -Registry $selection
            Assert-Equal "default source" "default" $defaultRecord.modelSource
            Assert-Equal "default profile" "fast" $defaultRecord.profile
            Assert-Equal "default model" $fastModel $defaultRecord.model
        }
    }

    Test-Case "AC-106 order: AI_HARNESS_MODEL beats the agent profile" {
        Use-ModelVariable "test-model-extra" {
            $record = Resolve-HarnessExecution -Agent "spec-reviewer" -Registry $selection
            Assert-Equal "source" "env" $record.modelSource
            Assert-Equal "model" "test-model-extra" $record.model
            Assert-Equal "profile" "extra" $record.profile
            Assert-Equal "parametersFrom" "extra" $record.parametersFrom
            Assert-Equal "warnings" 0 @($record.warnings).Count
        }
        Use-ModelVariable "   " {
            Assert-Equal "a blank variable is ignored" "agent" (Resolve-HarnessExecution -Agent "spec-reviewer" -Registry $selection).modelSource
        }
    }

    Test-Case "AC-106 order: -Profile beats AI_HARNESS_MODEL" {
        Use-ModelVariable $variableName {
            $record = Resolve-HarnessExecution -Agent "spec-reviewer" -Registry $selection -Profile "extra"
            Assert-Equal "source" "explicit-profile" $record.modelSource
            Assert-Equal "model" "test-model-extra" $record.model
            Assert-Equal "profile" "extra" $record.profile
            Assert-Equal "parametersFrom" "extra" $record.parametersFrom
            Assert-Equal "contextWindow" 8192 $record.contextWindow
            Assert-Equal "timeoutSec" 120 $record.timeoutSec
            Assert-Equal "reservedOutputTokens" 1024 $record.reservedOutputTokens
            Assert-Equal "options" "num_ctx=8192;seed=7;temperature=0.2" (Get-Pairs $record.options)
            Assert-Equal "warnings" 0 @($record.warnings).Count
        }
    }

    Test-Case "AC-106 -Profile is looked up like a property (case-insensitive)" {
        Assert-Equal "profile name as stored" "extra" (Resolve-HarnessExecution -Agent "spec" -Registry $selection -Profile "EXTRA").profile
    }

    Test-Case "AC-106 an unknown -Profile is registry_invalid" {
        Assert-Throws "unknown" { Resolve-HarnessExecution -Agent "spec" -Registry $selection -Profile "no-such-profile" } "registry_invalid:"
        Assert-Throws "blank" { Resolve-HarnessExecution -Agent "spec" -Registry $selection -Profile "" } "registry_invalid:"
    }

    Test-Case "AC-106 -Model equal to the model of exactly one profile takes that profile's parameters" {
        Use-ModelVariable $variableName {
            $record = Resolve-HarnessExecution -Agent "spec-reviewer" -Registry $selection -Model $fastModel
            Assert-Equal "source" "explicit-model" $record.modelSource
            Assert-Equal "model" $fastModel $record.model
            Assert-Equal "profile" "fast" $record.profile
            Assert-Equal "parametersFrom" "fast" $record.parametersFrom
            Assert-Equal "reservedOutputTokens" 4096 $record.reservedOutputTokens
            Assert-Equal "warnings" 0 @($record.warnings).Count
        }
        $upper = Resolve-HarnessExecution -Agent "spec-reviewer" -Registry $selection -Model $fastModel.ToUpperInvariant()
        Assert-Equal "match ignores case" "fast" $upper.parametersFrom
        Assert-Equal "the model is kept as typed" $fastModel.ToUpperInvariant() $upper.model
    }

    Test-Case "AC-106 -Model with an unregistered name takes the agent's parameters and adds the warning" {
        $record = Resolve-HarnessExecution -Agent "spec-reviewer" -Registry $selection -Model "test-model-unregistered"
        Assert-Equal "source" "explicit-model" $record.modelSource
        Assert-Equal "model" "test-model-unregistered" $record.model
        Assert-Equal "parametersFrom" "deep" $record.parametersFrom
        Assert-Equal "profile" "" $record.profile
        Assert-Equal "reservedOutputTokens" $v2Raw.profiles.deep.reservedOutputTokens $record.reservedOutputTokens
        Assert-Equal "warnings" "unregistered_model_override" (@($record.warnings) -join ",")
        $noEntry = Resolve-HarnessExecution -Agent "agent-without-entry" -Registry $selection -Model "test-model-unregistered"
        Assert-Equal "an agent without entry falls back to the default profile" "fast" $noEntry.parametersFrom
    }

    Test-Case "AC-106 AI_HARNESS_MODEL with an unregistered name behaves like -Model" {
        Use-ModelVariable "test-model-unregistered" {
            $record = Resolve-HarnessExecution -Agent "spec" -Registry $selection
            Assert-Equal "source" "env" $record.modelSource
            Assert-Equal "parametersFrom" "fast" $record.parametersFrom
            Assert-Equal "warnings" "unregistered_model_override" (@($record.warnings) -join ",")
        }
    }

    Test-Case "AC-106 -Model matching two profiles uses the agent's profile with no warning" {
        $twin = Get-RawJson $v2Path
        $twin.profiles | Add-Member -NotePropertyName "deep-twin" -NotePropertyValue ([pscustomobject]@{ model = $deepModel; reservedOutputTokens = 1024 })
        $twinRegistry = Get-HarnessRegistry -ConfigPath (Write-TempConfig "twin.json" $twin)
        $record = Resolve-HarnessExecution -Agent "spec-reviser" -Registry $twinRegistry -Model $deepModel
        Assert-Equal "parametersFrom" "deep" $record.parametersFrom
        Assert-Equal "profile" "" $record.profile
        Assert-Equal "warnings" 0 @($record.warnings).Count
        $other = Resolve-HarnessExecution -Agent "spec" -Registry $twinRegistry -Model $deepModel
        Assert-Equal "another agent uses its own profile" "fast" $other.parametersFrom
    }

    Test-Case "AC-106 a blank -Model is passed through; the wrapper returns it unchanged" {
        Use-ModelVariable $variableName {
            Assert-Equal "execution" "" (Resolve-HarnessExecution -Agent "spec" -Registry $selection -Model "").model
            Assert-Equal "execution source" "explicit-model" (Resolve-HarnessExecution -Agent "spec" -Registry $selection -Model "").modelSource
            Assert-Equal "wrapper" "" (Resolve-HarnessModel -Agent "spec" -ModelWasProvided $true -ExplicitModel "" -Config (Get-HarnessConfig -ConfigPath $selectionPath))
        }
    }

    Test-Case "AC-106 the wrapper accepts a v2 configuration object" {
        $config = Get-HarnessConfig -ConfigPath $selectionPath
        Use-ModelVariable $null {
            Assert-Equal "agent" $deepModel (Resolve-HarnessModel -Agent "spec-reviewer" -ModelWasProvided $false -Config $config)
            Assert-Equal "default" $fastModel (Resolve-HarnessModel -Agent "agent-without-entry" -ModelWasProvided $false -Config $config)
        }
        Use-ModelVariable $variableName {
            Assert-Equal "variable" $variableName (Resolve-HarnessModel -Agent "spec-reviewer" -ModelWasProvided $false -Config $config)
        }
    }

    Test-Case "AC-106 the record has the fields of FR-104" {
        foreach ($call in @(
            { Resolve-HarnessExecution -Agent "spec" -Registry $selection },
            { Resolve-HarnessExecution -Agent "spec" -Registry $selection -Profile "extra" },
            { Resolve-HarnessExecution -Agent "spec" -Registry $selection -Model "test-model-unregistered" },
            { Resolve-HarnessExecution -Agent "spec" -Registry (Get-HarnessRegistry -ConfigPath (Join-Path $tempRoot "does-not-exist.json")) -Model "test-model-unregistered" }
        )) {
            Use-ModelVariable $null {
                Assert-Equal "fields" $expectedFields ((& $call).PSObject.Properties.Name -join ",")
            }
        }
    }

    Test-Case "AC-106 with no profile to take parameters from, the record uses the defaults" {
        $empty = Get-HarnessRegistry -ConfigPath (Join-Path $tempRoot "does-not-exist.json")
        $record = Resolve-HarnessExecution -Agent "spec" -Registry $empty -Model "test-model-unregistered"
        Assert-Equal "parametersFrom is empty" "" $record.parametersFrom
        Assert-Equal "timeoutSec is the default" 600 $record.timeoutSec
        Assert-Equal "think" "default" $record.think
        Assert-Equal "options" "" (Get-Pairs $record.options)
        Assert-True "contextWindow is absent" ($null -eq $record.contextWindow)
        Assert-True "reservedOutputTokens is absent" ($null -eq $record.reservedOutputTokens)
    }

    Test-Case "AC-106 no model configured is the existing message" {
        Use-ModelVariable $null {
            $empty = Get-HarnessRegistry -ConfigPath (Join-Path $tempRoot "does-not-exist.json")
            Assert-Throws "empty registry" { Resolve-HarnessExecution -Agent "spec" -Registry $empty } "No model configured. Use -Model, set AI_HARNESS_MODEL, or define defaultModel in .ai\config.json."
        }
    }

    # -----------------------------------------------------------------------
    # AC-109 (record part) think is stored
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-109 think in the record ===" -ForegroundColor Cyan

    Test-Case "AC-109 think is kept in the registry and the record" {
        $registry = Get-HarnessRegistry -ConfigPath (Join-Path $fixtures "config-v2-think.json")
        $expected = [ordered]@{ absent = "default"; on = "True"; off = "False"; named = "default" }
        foreach ($name in $expected.Keys) {
            $record = Resolve-HarnessExecution -Agent "spec" -Registry $registry -Profile $name
            Assert-Equal "record think for $name" $expected[$name] $record.think
            Assert-Equal "registry think for $name" $expected[$name] $registry.profiles.$name.think
        }
        Assert-True "on is a boolean" ((Resolve-HarnessExecution -Agent "spec" -Registry $registry -Profile "on").think -is [bool])
        Assert-True "off is a boolean" ((Resolve-HarnessExecution -Agent "spec" -Registry $registry -Profile "off").think -is [bool])
        Assert-True "named is the string default" ((Resolve-HarnessExecution -Agent "spec" -Registry $registry -Profile "named").think -is [string])
    }

    Test-Case "AC-109 a v1 file resolves with think default" {
        Assert-Equal "think" "default" (Resolve-HarnessExecution -Agent "spec" -Registry ($golden | Where-Object { $_.Label -eq "v1" }).Registry).think
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
