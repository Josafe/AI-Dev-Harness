<#
.SYNOPSIS
    Offline, in-process tests for Test-AgentContextBudget and
    Get-AgentRetryDelaySec of scripts\lib\agent-exec.ps1
    (Phase 2, WP-2B1; FR-209, FR-212, AC-206, AC-208 delay part).

.DESCRIPTION
    - No network, no Ollama, no child process, no sleeping: scripts\lib\config.ps1
      and scripts\lib\agent-exec.ps1 are dot-sourced and the two functions are
      called with literal values.
    - Every expected number is a literal worked out by hand (the working is in
      the comment above each table), never computed from the code under test.
    - Assertions never read localized text (NFR-202): only statuses, numbers,
      property names and the harness's own invalid_arguments: prefix.
    - Registries and executions are built in memory from literal JSON; the frozen
      Phase 1 baseline is read from tests\fixtures. Nothing is written to disk.
#>
param()

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$fixtures = Join-Path $root "tests\fixtures"
$configLibrary = Join-Path $PSScriptRoot "lib\config.ps1"
$engineLibrary = Join-Path $PSScriptRoot "lib\agent-exec.ps1"

foreach ($path in @($configLibrary, $engineLibrary, $fixtures)) {
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

function Assert-Throws {
    param([string]$What, [scriptblock]$Action, [string]$Prefix = "")

    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }

    if ($null -eq $message) { throw "$What : nothing was thrown" }
    if ($Prefix -and -not $message.StartsWith($Prefix, [System.StringComparison]::Ordinal)) {
        throw "$What : expected a message starting with '$Prefix', got '$message'"
    }
}

# A registry and an execution from literal parameters. $Window and $Reserved may
# be $null (the profile then has no such field). Ratio and CharsPerToken are
# written only when given, so the registry defaults apply otherwise.
function New-BudgetCase {
    param(
        $Window = 10000,
        $Reserved = 1000,
        $Ratio = $null,
        $CharsPerToken = $null,
        [string]$BudgetMode = ""
    )

    $profile = '"model": "test-model-a"'
    if ($null -ne $Window) { $profile += ', "contextWindow": ' + $Window }
    if ($null -ne $Reserved) { $profile += ', "reservedOutputTokens": ' + $Reserved }
    $defaults = '"profile": "alpha"'
    if ($null -ne $Ratio) { $defaults += ', "safetyMarginRatio": ' + $Ratio }
    if ($null -ne $CharsPerToken) { $defaults += ', "charsPerToken": ' + $CharsPerToken }
    if ($BudgetMode) { $defaults += ', "budgetMode": "' + $BudgetMode + '"' }
    $json = '{ "schemaVersion": 2, "defaults": { ' + $defaults + ' }, "profiles": { "alpha": { ' + $profile + ' } }, "agents": { "spec": { "profile": "alpha" } } }'
    $registry = ConvertTo-HarnessRegistry -Config ($json | ConvertFrom-Json)
    $execution = Resolve-HarnessExecution -Agent "spec" -Registry $registry
    return [pscustomobject]@{ Registry = $registry; Execution = $execution }
}

# $Chars characters split between system and prompt (the split must not matter).
function Invoke-Budget {
    param($Case, [int]$Chars, [int]$SystemChars = -1, $Parts = $null)

    if ($SystemChars -lt 0) { $SystemChars = [int][math]::Floor($Chars / 2) }
    $arguments = @{
        Execution = $Case.Execution
        Registry  = $Case.Registry
        System    = ('s' * $SystemChars)
        Prompt    = ('p' * ($Chars - $SystemChars))
    }
    if ($null -ne $Parts) { $arguments.Parts = $Parts }
    return Test-AgentContextBudget @arguments
}

function Assert-Budget {
    param([string]$What, $Result, [string]$Status, $Estimated, $Available, $Margin, $Over)

    Assert-Equal "$What status" $Status $Result.status
    Assert-Equal "$What estTokens" $Estimated $Result.estTokens
    Assert-Equal "$What available" $Available $Result.available
    Assert-Equal "$What margin" $Margin $Result.margin
    Assert-Equal "$What over" $Over $Result.over
}

try {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "   AGENT BUDGET AND RETRY DELAY" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan

    # -----------------------------------------------------------------------
    # AC-206 the limit: window 10000, ratio 0.1, reserved 1000, charsPerToken 4
    #   S = ceil(0.1 x 10000) = 1000, available = 10000 - 1000 - 1000 = 8000
    #   E = ceil(chars / 4):  32000 -> 8000 (met exactly: ok)
    #                         32001 -> ceil(8000.25) = 8001 (exceeded by 1)
    #                         31997 -> ceil(7999.25) = 8000 (ok)
    #                         31996 -> 7999 (ok), 40000 -> 10000 (over 2000)
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-206 the limit ===" -ForegroundColor Cyan

    $limit = New-BudgetCase -Window 10000 -Reserved 1000 -Ratio 0.1 -CharsPerToken 4

    Test-Case "AC-206 E = 8000 meets the limit exactly: ok, over 0" {
        Assert-Budget "32000 chars" (Invoke-Budget $limit 32000) "ok" 8000 8000 1000 0
    }
    Test-Case "AC-206 E = 8001 is exceeded by exactly 1" {
        Assert-Budget "32001 chars" (Invoke-Budget $limit 32001) "exceeded" 8001 8000 1000 1
    }
    Test-Case "AC-206 a fraction rounds E up: 31997 chars is E 8000 (ok), 31996 is E 7999 (ok)" {
        Assert-Budget "31997 chars" (Invoke-Budget $limit 31997) "ok" 8000 8000 1000 0
        Assert-Budget "31996 chars" (Invoke-Budget $limit 31996) "ok" 7999 8000 1000 0
    }
    Test-Case "AC-206 a far larger prompt: 40000 chars is E 10000, over 2000" {
        Assert-Budget "40000 chars" (Invoke-Budget $limit 40000) "exceeded" 10000 8000 1000 2000
    }
    Test-Case "AC-206 the split between system and prompt does not matter, only the sum" {
        foreach ($split in @(0, 1, 16000, 32000)) {
            Assert-Budget "split $split of 32000" (Invoke-Budget $limit 32000 $split) "ok" 8000 8000 1000 0
            Assert-Budget "split $split of 32001" (Invoke-Budget $limit 32001 $split) "exceeded" 8001 8000 1000 1
        }
    }
    Test-Case "AC-206 empty system and prompt: E 0, ok" {
        Assert-Budget "empty" (Invoke-Budget $limit 0) "ok" 0 8000 1000 0
    }

    # -----------------------------------------------------------------------
    # AC-206 margin is the ceiling: window 8191, ratio 0.1, reserved 1000, cpt 1
    #   0.1 x 8191 = 819.1 -> S = 820 (floor or round would give 819)
    #   available = 8191 - 1000 - 820 = 6371; E = chars
    #   6371 -> ok; 6372 -> exceeded by 1 (with S 819 the limit would be 6372)
    # -----------------------------------------------------------------------
    Test-Case "AC-206 ratio 0.1 with window 8191 gives margin 820 (ceiling): 6371 ok, 6372 exceeded" {
        $case = New-BudgetCase -Window 8191 -Reserved 1000 -Ratio 0.1 -CharsPerToken 1
        Assert-Budget "6371 chars" (Invoke-Budget $case 6371) "ok" 6371 6371 820 0
        Assert-Budget "6372 chars" (Invoke-Budget $case 6372) "exceeded" 6372 6371 820 1
    }

    # -----------------------------------------------------------------------
    # AC-206 a non-default ratio: window 1000, ratio 0.5, reserved 100, cpt 1
    #   S = 500, available = 1000 - 100 - 500 = 400 (the default ratio 0.1
    #   would give S 100 and available 800)
    # -----------------------------------------------------------------------
    Test-Case "AC-206 ratio 0.5 with window 1000: margin 500, available 400; 400 ok, 401 exceeded" {
        $case = New-BudgetCase -Window 1000 -Reserved 100 -Ratio 0.5 -CharsPerToken 1
        Assert-Budget "400 chars" (Invoke-Budget $case 400) "ok" 400 400 500 0
        Assert-Budget "401 chars" (Invoke-Budget $case 401) "exceeded" 401 400 500 1
    }

    # -----------------------------------------------------------------------
    # AC-206 a non-default charsPerToken: window 10000, ratio 0.1, reserved 1000
    #   (available 8000), charsPerToken 2.5
    #   E = ceil(chars / 2.5): 20000 -> 8000 (ok); 20001 -> ceil(8000.4) = 8001
    #   (exceeded; rounding would give 8000); 7 chars -> ceil(2.8) = 3;
    #   6 chars -> ceil(2.4) = 3 (round and floor give 2); 5 -> 2; 1 -> 1
    # -----------------------------------------------------------------------
    $slim = New-BudgetCase -Window 10000 -Reserved 1000 -Ratio 0.1 -CharsPerToken 2.5

    Test-Case "AC-206 charsPerToken 2.5: 20000 chars is E 8000 (ok), 20001 is E 8001 (exceeded)" {
        Assert-Budget "20000 chars" (Invoke-Budget $slim 20000) "ok" 8000 8000 1000 0
        Assert-Budget "20001 chars" (Invoke-Budget $slim 20001) "exceeded" 8001 8000 1000 1
    }
    Test-Case "AC-206 charsPerToken 2.5: 7 chars is 3 tokens, 6 chars is 3, 5 chars is 2, 1 char is 1" {
        Assert-Equal "7 chars" 3 (Invoke-Budget $slim 7).estTokens
        Assert-Equal "6 chars" 3 (Invoke-Budget $slim 6).estTokens
        Assert-Equal "5 chars" 2 (Invoke-Budget $slim 5).estTokens
        Assert-Equal "1 char" 1 (Invoke-Budget $slim 1).estTokens
    }
    Test-Case "AC-206 the same 20000 characters are E 5000 at charsPerToken 4, E 8000 at 2.5" {
        Assert-Equal "cpt 4" 5000 (Invoke-Budget $limit 20000).estTokens
        Assert-Equal "cpt 2.5" 8000 (Invoke-Budget $slim 20000).estTokens
    }

    # -----------------------------------------------------------------------
    # AC-206 the registry defaults flow through: window 10000, reserved 1000, no
    # ratio and no charsPerToken -> ratio 0.1 (S 1000, available 8000), 3.5 chars
    # per token: 28000 -> 8000 (ok); 28001 -> ceil(8000.2857) = 8001; 7 -> 2
    # -----------------------------------------------------------------------
    Test-Case "AC-206 defaults (ratio 0.1, charsPerToken 3.5): 28000 chars ok at E 8000, 28001 exceeded at E 8001" {
        $case = New-BudgetCase -Window 10000 -Reserved 1000
        Assert-Budget "28000 chars" (Invoke-Budget $case 28000) "ok" 8000 8000 1000 0
        Assert-Budget "28001 chars" (Invoke-Budget $case 28001) "exceeded" 8001 8000 1000 1
        Assert-Equal "7 chars" 2 (Invoke-Budget $case 7).estTokens
    }

    # -----------------------------------------------------------------------
    # AC-206 skipped: nothing is checked and nothing is reported
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-206 skipped, modes, shape ===" -ForegroundColor Cyan

    foreach ($case in @(
        @{ Label = "no contextWindow";                   Window = $null;  Reserved = 1000 },
        @{ Label = "no reservedOutputTokens";            Window = 10000;  Reserved = $null },
        @{ Label = "neither contextWindow nor reserved"; Window = $null;  Reserved = $null }
    )) {
        Test-Case "AC-206 skipped: $($case.Label), even for a 1,000,000-character prompt" {
            $budgetCase = New-BudgetCase -Window $case.Window -Reserved $case.Reserved -Ratio 0.1 -CharsPerToken 4
            $result = Invoke-Budget $budgetCase 1000000
            Assert-Equal "status" "skipped" $result.status
            foreach ($name in @("estTokens", "available", "margin", "over")) {
                Assert-True "$name is not reported" ($null -eq $result.$name)
            }
            Assert-Equal "sections" 0 @($result.sections).Count
        }
    }

    Test-Case "AC-206 skipped: a v1 configuration (no window, no reserved)" {
        $registry = Get-HarnessRegistry -ConfigPath (Join-Path $fixtures "config-v1-current.json")
        $execution = Resolve-HarnessExecution -Agent "spec" -Registry $registry
        $result = Test-AgentContextBudget -Execution $execution -Registry $registry -System ("x" * 500000) -Prompt "y"
        Assert-Equal "status" "skipped" $result.status
    }

    Test-Case "AC-206 enforce and warn give the same record (the mode is the caller's decision)" {
        $enforce = New-BudgetCase -Window 10000 -Reserved 1000 -Ratio 0.1 -CharsPerToken 4 -BudgetMode "enforce"
        $warn = New-BudgetCase -Window 10000 -Reserved 1000 -Ratio 0.1 -CharsPerToken 4 -BudgetMode "warn"
        Assert-Equal "enforce mode value" "enforce" $enforce.Registry.defaults.budgetMode
        Assert-Equal "warn mode value" "warn" $warn.Registry.defaults.budgetMode
        foreach ($chars in @(32000, 32001)) {
            $a = Invoke-Budget $enforce $chars
            $b = Invoke-Budget $warn $chars
            Assert-Equal "record at $chars" (($a | ConvertTo-Json -Depth 5 -Compress)) (($b | ConvertTo-Json -Depth 5 -Compress))
        }
        Assert-Equal "enforce 32001 is still reported as exceeded" "exceeded" (Invoke-Budget $enforce 32001).status
    }

    Test-Case "AC-206 the record has exactly the FR-209 fields, in order, and integers for the numbers" {
        $result = Invoke-Budget $limit 32001
        Assert-Equal "fields" "status,contextWindow,reserved,margin,estTokens,available,over,sections" (($result.PSObject.Properties.Name) -join ",")
        Assert-Equal "contextWindow" 10000 $result.contextWindow
        Assert-Equal "reserved" 1000 $result.reserved
        foreach ($name in @("contextWindow", "reserved", "margin", "estTokens", "available", "over")) {
            Assert-True "$name is an integer" ($result.$name -is [long])
        }
        $skipped = Invoke-Budget (New-BudgetCase -Window $null -Reserved $null) 10
        Assert-Equal "skipped fields" "status,contextWindow,reserved,margin,estTokens,available,over,sections" (($skipped.PSObject.Properties.Name) -join ",")
    }

    Test-Case "AC-206 a mandatory parameter that is missing, or a record that is not a registry or execution, is a programmer error" {
        Assert-Throws "no -Prompt" { Test-AgentContextBudget -Execution $limit.Execution -Registry $limit.Registry -System "a" }
        Assert-Throws "execution without the budget members" { Test-AgentContextBudget -Execution ([pscustomobject]@{ model = "m" }) -Registry $limit.Registry -System "a" -Prompt "b" } "invalid_arguments:"
        Assert-Throws "registry without defaults" { Test-AgentContextBudget -Execution $limit.Execution -Registry ([pscustomobject]@{}) -System "a" -Prompt "b" } "invalid_arguments:"
    }

    # -----------------------------------------------------------------------
    # AC-206 the frozen Phase 1 baseline (window 16384, reserved 8192 for the
    # reviewer, ratio 0.1, default charsPerToken 3.5)
    #   S = ceil(1638.4) = 1639, available = 16384 - 8192 - 1639 = 6553
    #   25564 characters (the measured fixed text of the reviewer, spec Context
    #   table) / 3.5 = 7304 exactly -> over 7304 - 6553 = 751
    # The mode of that registry is warn, so the engine proceeds (WP-2C) and warns.
    # -----------------------------------------------------------------------
    Test-Case "AC-206 baseline reviewer: 25564 characters are E 7304 against 6553 available (over 751) and the mode is warn" {
        $registry = Get-HarnessRegistry -ConfigPath (Join-Path $fixtures "config-v2-phase1-baseline.json")
        $execution = Resolve-HarnessExecution -Agent "spec-reviewer" -Registry $registry
        $result = Test-AgentContextBudget -Execution $execution -Registry $registry -System ("s" * 25000) -Prompt ("p" * 564)
        Assert-Budget "baseline reviewer" $result "exceeded" 7304 6553 1639 751
        Assert-Equal "contextWindow" 16384 $result.contextWindow
        Assert-Equal "reserved" 8192 $result.reserved
        Assert-Equal "budgetMode" "warn" $registry.defaults.budgetMode
    }

    Test-Case "AC-206 baseline spec agent: window 16384, reserved 4096, so 10649 available; 37271 chars is E 10649 (ok), 37272 is E 10650" {
        # S 1639; available 16384 - 4096 - 1639 = 10649; 10649 x 3.5 = 37271.5,
        # so 37271 chars -> ceil(10648.857) = 10649 (ok) and 37272 -> 10649.14 -> 10650.
        $registry = Get-HarnessRegistry -ConfigPath (Join-Path $fixtures "config-v2-phase1-baseline.json")
        $execution = Resolve-HarnessExecution -Agent "spec" -Registry $registry
        $a = Test-AgentContextBudget -Execution $execution -Registry $registry -System ("s" * 37271) -Prompt ""
        $b = Test-AgentContextBudget -Execution $execution -Registry $registry -System ("s" * 37272) -Prompt ""
        Assert-Budget "37271" $a "ok" 10649 10649 1639 0
        Assert-Budget "37272" $b "exceeded" 10650 10649 1639 1
    }

    # -----------------------------------------------------------------------
    # FR-209 sections: per part, name, kind, characters and estimated tokens
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== FR-209 sections ===" -ForegroundColor Cyan

    # charsPerToken 4: 4 chars -> 1 token, 10 chars -> ceil(2.5) = 3, 1 char -> 1,
    # 0 chars -> 0, 9 chars -> ceil(2.25) = 3.
    $parts = @(
        (New-AgentPromptPart -Name "template" -Kind instruction -Text "abcd"),
        (New-AgentPromptPart -Name "task" -Kind data -Text "abcdefghij"),
        (New-AgentPromptPart -Name "empty" -Kind data -Text ""),
        (New-AgentPromptPart -Name "nine" -Kind instruction -Text "123456789"),
        (New-AgentPromptPart -Name "one" -Kind data -Text "x")
    )
    $expectedSections = @(
        @{ Name = "template"; Kind = "instruction"; Chars = 4;  Tokens = 1 },
        @{ Name = "task";     Kind = "data";        Chars = 10; Tokens = 3 },
        @{ Name = "empty";    Kind = "data";        Chars = 0;  Tokens = 0 },
        @{ Name = "nine";     Kind = "instruction"; Chars = 9;  Tokens = 3 },
        @{ Name = "one";      Kind = "data";        Chars = 1;  Tokens = 1 }
    )

    Test-Case "FR-209 sections from parts (Name, Kind, Text): characters and estimated tokens per part, in order" {
        $result = Invoke-Budget $limit 24 -Parts $parts
        $sections = @($result.sections)
        Assert-Equal "section count" 5 $sections.Count
        for ($i = 0; $i -lt 5; $i++) {
            Assert-Equal "section $i name" $expectedSections[$i].Name $sections[$i].name
            Assert-Equal "section $i kind" $expectedSections[$i].Kind $sections[$i].kind
            Assert-Equal "section $i chars" $expectedSections[$i].Chars $sections[$i].chars
            Assert-Equal "section $i estTokens" $expectedSections[$i].Tokens $sections[$i].estTokens
        }
        Assert-Equal "section fields" "name,kind,chars,estTokens" (($sections[0].PSObject.Properties.Name) -join ",")
    }

    Test-Case "FR-209 sections from the breakdown of New-AgentPrompt (name, kind, chars) equal those from the parts" {
        $built = New-AgentPrompt -Parts $parts
        $fromBreakdown = @((Invoke-Budget $limit 24 -Parts $built.breakdown).sections)
        $fromParts = @((Invoke-Budget $limit 24 -Parts $parts).sections)
        Assert-Equal "count" 5 $fromBreakdown.Count
        Assert-Equal "same sections" (($fromParts | ConvertTo-Json -Depth 4 -Compress)) (($fromBreakdown | ConvertTo-Json -Depth 4 -Compress))
    }

    Test-Case "FR-209 sections from a builder: input segments show their literal length and the sections cover the whole prompt" {
        $built = New-SpecReviewPrompt -ProjectInstructions "12345" -AgentContract "abcdefgh" -AgentInstructions "xy" -Mode "mixed" -Task "task text" -Specification "the spec"
        $result = Test-AgentContextBudget -Execution $limit.Execution -Registry $limit.Registry -System $built.system -Prompt $built.prompt -Parts $built.parts
        $byName = @{}
        foreach ($section in @($result.sections)) { if (-not $byName.ContainsKey($section.name)) { $byName[$section.name] = $section } }
        Assert-Equal "project-instructions chars" 5 $byName["project-instructions"].chars
        Assert-Equal "agent-contract chars" 8 $byName["agent-contract"].chars
        Assert-Equal "agent-role chars" 2 $byName["agent-role"].chars
        Assert-Equal "mode chars" 5 $byName["mode"].chars
        Assert-Equal "task chars" 9 $byName["task"].chars
        Assert-Equal "specification chars" 8 $byName["specification"].chars
        Assert-Equal "agent-contract kind" "instruction" $byName["agent-contract"].kind
        Assert-Equal "task kind" "data" $byName["task"].kind
        Assert-Equal "specification est tokens at 4 chars/token" 2 $byName["specification"].estTokens
        $sum = 0
        foreach ($section in @($result.sections)) { $sum += $section.chars }
        Assert-Equal "sections cover system plus prompt" ($built.system.Length + $built.prompt.Length) $sum
        Assert-Equal "estTokens uses the whole prompt" ([math]::Ceiling(($built.system.Length + $built.prompt.Length) / 4)) $result.estTokens
    }

    Test-Case "FR-209 without -Parts, or with an empty list, sections is empty" {
        Assert-Equal "no parts" 0 @((Invoke-Budget $limit 100).sections).Count
        Assert-Equal "empty parts" 0 @((Invoke-Budget $limit 100 -Parts @()).sections).Count
    }

    Test-Case "FR-209 the budget never truncates: the arguments are unchanged and the record holds no prompt text" {
        $system = "s" * 60000
        $prompt = "p" * 60000
        $result = Test-AgentContextBudget -Execution $limit.Execution -Registry $limit.Registry -System $system -Prompt $prompt
        Assert-Equal "system length" 60000 $system.Length
        Assert-Equal "prompt length" 60000 $prompt.Length
        Assert-Equal "estimate for 120000 chars at 4" 30000 $result.estTokens
        Assert-True "the record has no text member" ($null -eq $result.PSObject.Properties["text"] -and $null -eq $result.PSObject.Properties["system"] -and $null -eq $result.PSObject.Properties["prompt"])
    }

    # -----------------------------------------------------------------------
    # FR-212 Get-AgentRetryDelaySec: BackoffSec x 2^(k-1), capped at 60
    #   base 5:  k=1..6 -> 5, 10, 20, 40, 80 -> 60, 160 -> 60
    #   base 7:  7, 14, 28, 56, 112 -> 60
    #   base 1:  1, 2, 4, 8, 16, 32, 64 -> 60
    #   base 30: 30, 60, 120 -> 60;  base 60: 60 at every attempt; base 0: 0
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== FR-212 Get-AgentRetryDelaySec ===" -ForegroundColor Cyan

    foreach ($case in @(
        @{ Base = 5;  Expected = @(5, 10, 20, 40, 60, 60) },
        @{ Base = 7;  Expected = @(7, 14, 28, 56, 60, 60) },
        @{ Base = 1;  Expected = @(1, 2, 4, 8, 16, 32, 60, 60) },
        @{ Base = 30; Expected = @(30, 60, 60) },
        @{ Base = 60; Expected = @(60, 60, 60) },
        @{ Base = 0;  Expected = @(0, 0, 0, 0, 0, 0) }
    )) {
        Test-Case "FR-212 base $($case.Base): $($case.Expected -join ', ')" {
            $actual = @()
            for ($attempt = 1; $attempt -le $case.Expected.Count; $attempt++) {
                $actual += (Get-AgentRetryDelaySec -Attempt $attempt -BackoffSec $case.Base)
            }
            Assert-Equal "delays" ($case.Expected -join ",") ($actual -join ",")
        }
    }

    Test-Case "FR-212 the wait before the 2nd attempt of the default (base 5, attempt 1) is 5 s; with the registry maximum of 5 attempts the waits are 5, 10, 20, 40" {
        $waits = @(1, 2, 3, 4 | ForEach-Object { Get-AgentRetryDelaySec -Attempt $_ -BackoffSec 5 })
        Assert-Equal "waits" "5,10,20,40" ($waits -join ",")
    }

    Test-Case "FR-212 the cap holds for any attempt, however large, and for a base above 60 (invalid in the registry, still capped)" {
        Assert-Equal "attempt 1000" 60 (Get-AgentRetryDelaySec -Attempt 1000 -BackoffSec 5)
        Assert-Equal "attempt max int" 60 (Get-AgentRetryDelaySec -Attempt ([int]::MaxValue) -BackoffSec 1)
        Assert-Equal "base 100" 60 (Get-AgentRetryDelaySec -Attempt 1 -BackoffSec 100)
        Assert-Equal "base max int" 60 (Get-AgentRetryDelaySec -Attempt 3 -BackoffSec ([int]::MaxValue))
        Assert-Equal "base 0, huge attempt" 0 (Get-AgentRetryDelaySec -Attempt ([int]::MaxValue) -BackoffSec 0)
    }

    Test-Case "FR-212 the result is an integer and no delay exceeds 60 in a sweep of 1..20 attempts and bases 0..60" {
        $worst = 0
        foreach ($base in 0, 1, 2, 3, 5, 10, 17, 30, 59, 60) {
            foreach ($attempt in 1..20) {
                $delay = Get-AgentRetryDelaySec -Attempt $attempt -BackoffSec $base
                if ($delay -isnot [int]) { throw "base $base attempt $attempt : not an integer" }
                if ($delay -gt $worst) { $worst = $delay }
            }
        }
        Assert-Equal "largest delay" 60 $worst
    }

    Test-Case "FR-212 an attempt below 1 or a negative base is a programmer error" {
        Assert-Throws "attempt 0" { Get-AgentRetryDelaySec -Attempt 0 -BackoffSec 5 }
        Assert-Throws "attempt -1" { Get-AgentRetryDelaySec -Attempt -1 -BackoffSec 5 }
        Assert-Throws "base -1" { Get-AgentRetryDelaySec -Attempt 1 -BackoffSec -1 }
        Assert-Throws "no parameters" { Get-AgentRetryDelaySec }
    }

    Test-Case "FR-212 it never sleeps: the worst case (base 60, attempt 5) returns in well under a second and the body has no sleep or I/O command" {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $delay = Get-AgentRetryDelaySec -Attempt 5 -BackoffSec 60
        $stopwatch.Stop()
        Assert-Equal "delay" 60 $delay
        Assert-True "returned in under 1000 ms ($($stopwatch.ElapsedMilliseconds) ms)" ($stopwatch.ElapsedMilliseconds -lt 1000)
    }

    # -----------------------------------------------------------------------
    # Static scan of the two functions (side-effect free, no hidden constants)
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== static scan ===" -ForegroundColor Cyan

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($engineLibrary, [ref]$tokens, [ref]$errors)
    $functionAsts = @{}
    foreach ($function in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $functionAsts[$function.Name] = $function
    }

    foreach ($functionName in @("Test-AgentContextBudget", "Get-AgentRetryDelaySec")) {
        Test-Case "static: $functionName exists and calls no sleep, network, file, process or output command" {
            Assert-True "$functionName is defined" ($functionAsts.ContainsKey($functionName))
            $forbidden = @("Start-Sleep", "sleep", "Invoke-RestMethod", "Invoke-WebRequest", "Invoke-Expression", "iex", "Start-Process", "Stop-Process",
                "Get-Content", "Set-Content", "Add-Content", "Out-File", "Write-Host", "Write-Output", "Write-Warning", "Write-Error", "Get-Date")
            foreach ($command in $functionAsts[$functionName].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $commandName = [string]$command.GetCommandName()
                if ($forbidden -contains $commandName) { throw "$functionName calls $commandName" }
            }
            $text = $functionAsts[$functionName].Extent.Text
            foreach ($literal in @("[datetime]", "[System.Threading", "Env:", "`$env:", "`$script:", "`$global:")) {
                if ($text.IndexOf($literal, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "$functionName uses $literal" }
            }
        }
    }

    Test-Case "static: the budget uses [decimal] and [math]::Ceiling and does not shorten any text" {
        $text = $functionAsts["Test-AgentContextBudget"].Extent.Text
        Assert-True "uses [math]::Ceiling" ($text.Contains("[math]::Ceiling"))
        Assert-True "uses [decimal]" ($text.Contains("[decimal]"))
        foreach ($member in @(".Substring(", ".Remove(", ".Trim(", ".TrimEnd(", ".Truncate(")) {
            Assert-True "no $member" (-not $text.Contains($member))
        }
    }

    Test-Case "static: Get-AgentRetryDelaySec does not read the registry or any state (every value is a parameter)" {
        $text = $functionAsts["Get-AgentRetryDelaySec"].Extent.Text
        foreach ($literal in @("Registry", "Get-HarnessRegistry", "Get-Variable", "Get-ConfigValue")) {
            Assert-True "no $literal" (-not $text.Contains($literal))
        }
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
