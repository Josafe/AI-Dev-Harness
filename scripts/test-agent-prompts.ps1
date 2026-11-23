<#
.SYNOPSIS
    Offline suite for the prompt builders of scripts\lib\agent-exec.ps1
    (Phase 2, WP-2A; FR-203, FR-208, AC-201 builder part).

.DESCRIPTION
    Goldens under tests\golden were captured once from the UNMODIFIED legacy
    scripts (their here-string statements located with the PowerShell parser
    and evaluated with the fixture inputs in tests\golden\inputs).
    Comparison rule (FR-203): CRLF -> LF on both sides, nothing else, ordinal.
    The suite sends no request, reads only the repository's test files and
    writes only under TEMP.
#>
$ErrorActionPreference = "Stop"

$script:passed = 0
$script:failed = 0

$libPath = Join-Path $PSScriptRoot "lib\agent-exec.ps1"
$goldenDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) "tests\golden"
$inputsDirectory = Join-Path $goldenDirectory "inputs"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$crlf = "`r`n"

function Write-Result {
    param([string]$Name, [string[]]$Problems = @())

    if ($Problems.Count -eq 0) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
        $script:passed++
        return
    }
    Write-Host "[FAIL] $Name" -ForegroundColor Red
    foreach ($problem in $Problems) { Write-Host "       $problem" -ForegroundColor Red }
    $script:failed++
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)

    $problems = @()
    try {
        $problems = @(& $Body)
    }
    catch {
        $problems = @("unexpected error: $($_.Exception.Message)")
    }
    Write-Result -Name $Name -Problems @($problems | Where-Object { $_ })
}

# FR-203 rule 2: CRLF -> LF and nothing else (no trim, no BOM strip; a lone CR stays).
function ConvertTo-NormalizedEol {
    param([string]$Text)
    return $Text.Replace("`r`n", "`n")
}

function Test-PromptEqual {
    param([string]$Actual, [string]$Expected)
    return [string]::Equals((ConvertTo-NormalizedEol $Actual), (ConvertTo-NormalizedEol $Expected), [System.StringComparison]::Ordinal)
}

function Read-Utf8 {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, $utf8)
}

function Get-Input {
    param([string]$Name)
    return Read-Utf8 (Join-Path $inputsDirectory $Name)
}

function Get-LineEndingCounts {
    param([string]$Text)
    $crlfCount = 0; $lfOnly = 0; $loneCr = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq [char]10) {
            if ($i -gt 0 -and $Text[$i - 1] -eq [char]13) { $crlfCount++ } else { $lfOnly++ }
        }
        elseif ($Text[$i] -eq [char]13 -and ($i + 1 -ge $Text.Length -or $Text[$i + 1] -ne [char]10)) { $loneCr++ }
    }
    return [pscustomobject]@{ Crlf = $crlfCount; LfOnly = $lfOnly; LoneCr = $loneCr }
}

function Invoke-Builder {
    param([string]$Kind, [string]$Mode, [bool]$WithContext, [hashtable]$In)

    switch ($Kind) {
        "run" {
            $arguments = @{ ProjectInstructions = $In.pi; AgentContract = $In.ac; AgentInstructions = $In.role; Task = $In.task }
            if ($WithContext) { $arguments.RepositoryContext = $In.ctx }
            return New-RunAgentPrompt @arguments
        }
        "review" {
            return New-SpecReviewPrompt -ProjectInstructions $In.pi -AgentContract $In.ac -AgentInstructions $In.role `
                -Mode $Mode -Task $In.task -Specification $In.spec
        }
        "revise" {
            return New-SpecRevisePrompt -ProjectInstructions $In.pi -AgentContract $In.ac -AgentInstructions $In.role `
                -Mode $Mode -Task $In.task -Specification $In.spec -Review $In.review
        }
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-prompts-" + [guid]::NewGuid().ToString("N"))

try {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "   AGENT PROMPT BUILDERS (OFFLINE)" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""

    foreach ($required in @($libPath, $goldenDirectory, $inputsDirectory)) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Required path not found: $required" }
    }

    # ----- Library hygiene (FR-201, NFR-203) -----------------------------------

    Test-Case "FR-201 dot-sourcing prints nothing and defines exactly the library functions" {
        $result = & {
            $before = @(Get-ChildItem Function:\ | ForEach-Object { $_.Name })
            $output = @(. { . $libPath } *>&1)
            $afterNames = @()
            # Define in this scope to see the names, then report.
            . $libPath
            $after = @(Get-ChildItem Function:\ | ForEach-Object { $_.Name })
            [pscustomobject]@{ Output = $output; New = @($after | Where-Object { $before -notcontains $_ } | Sort-Object) }
        }
        $expected = @("Get-AgentErrorCategory", "Get-AgentRetryDelaySec", "New-AgentPrompt", "New-AgentPromptPart", "New-RunAgentPrompt", "New-SpecRevisePrompt", "New-SpecReviewPrompt", "Test-AgentContextBudget") | Sort-Object
        if ($result.Output.Count -ne 0) { "dot-sourcing produced output: $($result.Output -join '|')" }
        if (($result.New -join ",") -cne ($expected -join ",")) { "functions defined: $($result.New -join ', ')" }
    }

    # The functions stay defined for the rest of the suite.
    . $libPath

    Test-Case "NFR-203 static scan: no HTTP route, process control, file access, output, format operator or second expansion" {
        $problems = @()
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($libPath, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { return "parse errors: $($errors.Count)" }
        $forbiddenCommands = @("Invoke-Expression", "iex", "Invoke-RestMethod", "irm", "Invoke-WebRequest", "iwr", "curl", "wget",
            "Start-Process", "Start-BitsTransfer", "Stop-Process", "Get-Content", "Set-Content", "Add-Content", "Out-File",
            "Write-Host", "Write-Output", "Write-Warning", "Write-Error", "New-Object System.Net.WebClient")
        foreach ($command in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = [string]$command.GetCommandName()
            if ($forbiddenCommands -contains $name) { $problems += "forbidden command: $name" }
        }
        $formatOperators = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and $n.Operator -eq [System.Management.Automation.Language.TokenKind]::Format }, $true))
        if ($formatOperators.Count -gt 0) { $problems += "the -f operator is used ($($formatOperators.Count))" }
        foreach ($member in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
            $memberName = [string]$member.Member.Extent.Text
            if (@("ExpandString", "Format", "Invoke", "InvokeScript", "Create") -contains $memberName) { $problems += "forbidden member call: $memberName" }
        }
        $text = Read-Utf8 $libPath
        foreach ($literal in @("HttpWebRequest", "WebClient", "HttpClient", "System.Net", "Invoke-RestMethod", "Invoke-WebRequest", "ExpandString")) {
            if ($text.IndexOf($literal, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $problems += "forbidden text: $literal" }
        }
        return $problems
    }

    # ----- Parts and concatenation (FR-208) ------------------------------------

    Test-Case "FR-208 New-AgentPromptPart and New-AgentPrompt: literal concatenation and breakdown" {
        $problems = @()
        $a = New-AgentPromptPart -Name "one" -Kind instruction -Text "ab"
        $b = New-AgentPromptPart -Name "two" -Kind data -Text ""
        $c = New-AgentPromptPart -Name "three" -Kind data -Text "cde"
        $prompt = New-AgentPrompt -Parts @($a, $b, $c)
        if ($prompt.text -cne "abcde") { $problems += "text: '$($prompt.text)'" }
        $expected = @("one|instruction|2", "two|data|0", "three|data|3")
        $actual = @($prompt.breakdown | ForEach-Object { "$($_.name)|$($_.kind)|$($_.chars)" })
        if (($actual -join ";") -cne ($expected -join ";")) { $problems += "breakdown: $($actual -join ';')" }
        $threw = $false
        try { [void](New-AgentPromptPart -Name "x" -Kind "other" -Text "t") } catch { $threw = $true }
        if (-not $threw) { $problems += "a Kind other than instruction or data was accepted" }
        $empty = New-AgentPrompt -Parts @()
        if ($empty.text -cne "") { $problems += "no parts: expected an empty text" }
        return $problems
    }

    # ----- Goldens (AC-201 builder part, FR-203 rules 1, 2, 4, 5) ---------------

    $inputs = @{
        pi = (Get-Input "project-instructions.txt"); ac = (Get-Input "agent-contract.txt")
        roleA = (Get-Input "role-a.txt"); roleB = (Get-Input "role-b.txt")
        ctx = (Get-Input "repo-context.txt"); task = (Get-Input "task.txt")
        spec = (Get-Input "spec.txt"); review = (Get-Input "review.txt")
    }

    Test-Case "FR-203 fixtures keep their bytes (golden .gitattributes and literal line-ending counts)" {
        $problems = @()
        $attributes = Join-Path $goldenDirectory ".gitattributes"
        if (-not (Test-Path -LiteralPath $attributes -PathType Leaf)) { $problems += "tests\golden\.gitattributes is missing" }
        elseif ((Read-Utf8 $attributes).Trim() -cne "* -text") { $problems += "tests\golden\.gitattributes must contain '* -text'" }
        $expectedCounts = [ordered]@{
            "project-instructions.txt" = @(5, 0, 0); "agent-contract.txt" = @(0, 4, 0); "role-a.txt" = @(4, 3, 0)
            "role-b.txt" = @(0, 3, 0); "repo-context.txt" = @(3, 3, 0); "task.txt" = @(0, 0, 0)
            "spec.txt" = @(5, 0, 0); "review.txt" = @(0, 6, 0)
        }
        foreach ($name in $expectedCounts.Keys) {
            $counts = Get-LineEndingCounts (Get-Input $name)
            $expected = $expectedCounts[$name]
            if ($counts.Crlf -ne $expected[0] -or $counts.LfOnly -ne $expected[1] -or $counts.LoneCr -ne $expected[2]) {
                $problems += "$name : CRLF/LF-only/lone CR are $($counts.Crlf)/$($counts.LfOnly)/$($counts.LoneCr), expected $($expected -join '/')"
            }
        }
        return $problems
    }

    $cases = @(
        @{ Name = "run-nocontext-role-a"; Kind = "run"; Mode = ""; Ctx = $false; Role = "roleA" },
        @{ Name = "run-context-role-a"; Kind = "run"; Mode = ""; Ctx = $true; Role = "roleA" },
        @{ Name = "run-nocontext-role-b"; Kind = "run"; Mode = ""; Ctx = $false; Role = "roleB" },
        @{ Name = "run-context-role-b"; Kind = "run"; Mode = ""; Ctx = $true; Role = "roleB" }
    )
    foreach ($mode in @("requirements", "baseline", "documentation")) {
        $cases += @{ Name = "review-$mode"; Kind = "review"; Mode = $mode; Ctx = $false; Role = "roleA" }
        $cases += @{ Name = "revise-$mode"; Kind = "revise"; Mode = $mode; Ctx = $false; Role = "roleB" }
    }

    Test-Case "AC-201 the golden files are exactly the expected 10 cases (system and prompt)" {
        $expected = @($cases | ForEach-Object { "$($_.Name).system.txt"; "$($_.Name).prompt.txt" } | Sort-Object)
        $actual = @(Get-ChildItem -LiteralPath $goldenDirectory -File | Where-Object { $_.Name -like "*.system.txt" -or $_.Name -like "*.prompt.txt" } | ForEach-Object { $_.Name } | Sort-Object)
        if (($actual -join ",") -cne ($expected -join ",")) { "golden files: $($actual -join ', ')" }
    }

    foreach ($case in $cases) {
        Test-Case "AC-201 golden $($case.Name): system and prompt equal the legacy output (CRLF -> LF comparison)" {
            $problems = @()
            $in = @{ pi = $inputs.pi; ac = $inputs.ac; role = $inputs[$case.Role]; ctx = $inputs.ctx; task = $inputs.task; spec = $inputs.spec; review = $inputs.review }
            $built = Invoke-Builder -Kind $case.Kind -Mode $case.Mode -WithContext $case.Ctx -In $in
            $goldenSystem = Read-Utf8 (Join-Path $goldenDirectory "$($case.Name).system.txt")
            $goldenPrompt = Read-Utf8 (Join-Path $goldenDirectory "$($case.Name).prompt.txt")
            if (-not (Test-PromptEqual $built.system $goldenSystem)) { $problems += "system differs from the golden (lengths $($built.system.Length) and $($goldenSystem.Length))" }
            if (-not (Test-PromptEqual $built.prompt $goldenPrompt)) { $problems += "prompt differs from the golden" }
            # The goldens were captured on CRLF scripts: the template separators are CRLF in them.
            if ($goldenSystem.IndexOf("`r`n", [System.StringComparison]::Ordinal) -lt 0) { $problems += "the golden has lost its CRLF template separators" }
            return $problems
        }
    }

    Test-Case "AC-201 oracle: the comparison fails on a planted difference and ignores only CRLF versus LF" {
        $problems = @()
        $reference = "alpha`r`nbeta`ngamma {0} `$x`r`n"
        if (-not (Test-PromptEqual $reference ($reference.Replace("`r`n", "`n")))) { $problems += "CRLF versus LF must compare equal" }
        $mutations = [ordered]@{
            "one character changed"     = $reference.Replace("beta", "bita")
            "trailing space added"      = $reference.Replace("alpha", "alpha ")
            "final newline dropped"     = $reference.TrimEnd("`r", "`n")
            "leading newline added"     = "`n" + $reference
            "lone CR instead of CRLF"   = $reference.Replace("alpha`r`n", "alpha`r")
            "case changed"              = $reference.Replace("gamma", "Gamma")
            "input trimmed"             = $reference.Trim()
            "blank line pair dropped"   = $reference.Replace("beta`n", "beta")
        }
        foreach ($name in $mutations.Keys) {
            if (Test-PromptEqual $mutations[$name] $reference) { $problems += "a planted difference was accepted: $name" }
        }
        return $problems
    }

    # ----- Pass-through (FR-203 rule 3) ------------------------------------------

    Test-Case "FR-203 pass-through: every input appears unchanged and in order for CRLF, LF and mixed inputs; total length is exact" {
        $problems = @()
        $styles = [ordered]@{
            "CRLF"  = { param($s) $s.Replace("|", "`r`n") }
            "LF"    = { param($s) $s.Replace("|", "`n") }
            "mixed" = { param($s) $s.Replace("|", "`r`n").Replace("#", "`n") }
        }
        foreach ($styleName in $styles.Keys) {
            $make = $styles[$styleName]
            # Raw material has leading/trailing breaks and blank-line pairs; none may be trimmed.
            $pi = & $make "|PI first|# PI second||PI third|"
            $ac = & $make "AC one#AC two|"
            $role = & $make "  ROLE (indent)|#ROLE two|"
            $ctx = & $make "CTX|# {0} `$(Get-Date)|"
            $task = & $make "TASK |#TASK `"@ two"
            $spec = & $make "|SPEC# spec two|"
            $review = & $make "REVIEW|#|review two"
            $mode = "requirements"

            $run = New-RunAgentPrompt -ProjectInstructions $pi -AgentContract $ac -AgentInstructions $role -Task $task -RepositoryContext $ctx
            $review1 = New-SpecReviewPrompt -ProjectInstructions $pi -AgentContract $ac -AgentInstructions $role -Mode $mode -Task $task -Specification $spec
            $revise = New-SpecRevisePrompt -ProjectInstructions $pi -AgentContract $ac -AgentInstructions $role -Mode $mode -Task $task -Specification $spec -Review $review
            $checks = @(
                @{ Label = "run"; Text = $run.system; Inputs = @($pi, $ac, $role, $ctx); Template = 336 },
                @{ Label = "review"; Text = $review1.system; Inputs = @($pi, $ac, $role, $mode, $task, $spec); Template = 701 },
                @{ Label = "revise"; Text = $revise.system; Inputs = @($pi, $ac, $role, $mode, $task, $spec, $review); Template = 2684 }
            )
            foreach ($check in $checks) {
                $position = 0
                $total = 0
                foreach ($value in $check.Inputs) {
                    $found = $check.Text.IndexOf($value, $position, [System.StringComparison]::Ordinal)
                    if ($found -lt 0) { $problems += "$styleName $($check.Label): an input was changed or is out of order: '$($value.Substring(0, [Math]::Min(12, $value.Length)) -replace "`r", '\r' -replace "`n", '\n')'" ; break }
                    $position = $found + $value.Length
                    $total += $value.Length
                }
                # Literal template lengths measured on the legacy scripts: 280 + 56 (context), 701, 2684.
                if ($check.Text.Length -ne ($check.Template + $total)) {
                    $problems += "$styleName $($check.Label): length $($check.Text.Length), expected $($check.Template + $total)"
                }
            }
            if ($run.prompt -cne $task) { $problems += "$styleName run: the prompt must be the task, unchanged" }
        }
        return $problems
    }

    Test-Case "FR-203 literal template sizes without context: run-agent 280 characters" {
        $built = New-RunAgentPrompt -ProjectInstructions "" -AgentContract "" -AgentInstructions "" -Task ""
        if ($built.system.Length -ne 280) { "template length is $($built.system.Length), expected 280" }
    }

    # ----- OQ-211: template separators are CRLF -----------------------------------

    Test-Case "OQ-211 the template separators are CRLF whatever the line endings of the library file" {
        $problems = @()
        $tempLib = Join-Path $tempRoot "lib"
        [void][System.IO.Directory]::CreateDirectory($tempLib)
        $source = Read-Utf8 $libPath
        $lfOnly = $source.Replace("`r`n", "`n")
        $crlfOnly = $lfOnly.Replace("`n", "`r`n")
        $variants = [ordered]@{ "LF-only" = $lfOnly; "CRLF-only" = $crlfOnly }
        $inputsEmpty = @{ ProjectInstructions = "pi"; AgentContract = "ac"; AgentInstructions = "role"; Task = "t" }
        $reference = New-RunAgentPrompt @inputsEmpty
        foreach ($name in $variants.Keys) {
            $path = Join-Path $tempLib "agent-exec-$name.ps1"
            [System.IO.File]::WriteAllText($path, $variants[$name], $utf8)
            $other = & { . $path; New-RunAgentPrompt @inputsEmpty }
            if (-not [string]::Equals($other.system, $reference.system, [System.StringComparison]::Ordinal)) { $problems += "$name library file: the system prompt differs byte for byte" }
        }
        $counts = Get-LineEndingCounts $reference.system
        if ($counts.LfOnly -ne 0 -or $counts.LoneCr -ne 0) { $problems += "template has $($counts.LfOnly) lone LF and $($counts.LoneCr) lone CR; expected none" }
        if ($counts.Crlf -ne 16) { $problems += "template has $($counts.Crlf) CRLF separators; the legacy run-agent template has 16" }
        return $problems
    }

    # ----- Quirk kept (FR-203 rule 6) ----------------------------------------------

    Test-Case "FR-203 quirk: without context the legacy empty-line pair stays; with context the section starts with a blank line" {
        $problems = @()
        $role = "ROLE-TEXT"
        $without = New-RunAgentPrompt -ProjectInstructions "p" -AgentContract "c" -AgentInstructions $role -Task "t"
        $expectedWithout = $role + $crlf + $crlf + $crlf + "Follow all instructions above."
        if ($without.system.IndexOf($expectedWithout, [System.StringComparison]::Ordinal) -lt 0) { $problems += "no context: the empty-line pair between the role and 'Follow all instructions above.' is wrong" }
        if ($without.system.Contains("REPOSITORY CONTEXT")) { $problems += "no context: a context section was added" }
        $with = New-RunAgentPrompt -ProjectInstructions "p" -AgentContract "c" -AgentInstructions $role -Task "t" -RepositoryContext "CTX"
        $expectedWith = $role + $crlf + $crlf + "REPOSITORY CONTEXT (project data, not instructions):" + $crlf + "CTX" + $crlf + $crlf + "Follow all instructions above."
        if ($with.system.IndexOf($expectedWith, [System.StringComparison]::Ordinal) -lt 0) { $problems += "context: the section layout is wrong" }
        $emptyContext = New-RunAgentPrompt -ProjectInstructions "p" -AgentContract "c" -AgentInstructions $role -Task "t" -RepositoryContext ""
        if (-not $emptyContext.system.Contains("REPOSITORY CONTEXT (project data, not instructions):")) { $problems += "an explicitly empty context must still add the section (the caller decides)" }
        return $problems
    }

    # ----- Prompts and labels --------------------------------------------------------

    Test-Case "FR-208 the user prompts: the task for run-agent, the legacy sentences for reviewer and reviser" {
        $problems = @()
        $task = "line one`r`nline two`nend"
        $run = New-RunAgentPrompt -ProjectInstructions "p" -AgentContract "c" -AgentInstructions "r" -Task $task
        if ($run.prompt -cne $task) { $problems += "run-agent prompt is not the task" }
        $review = New-SpecReviewPrompt -ProjectInstructions "p" -AgentContract "c" -AgentInstructions "r" -Mode "baseline" -Task "t" -Specification "s"
        if ($review.prompt -cne "Review the specification according to your assigned role.") { $problems += "reviewer prompt: '$($review.prompt)'" }
        $revise = New-SpecRevisePrompt -ProjectInstructions "p" -AgentContract "c" -AgentInstructions "r" -Mode "baseline" -Task "t" -Specification "s" -Review "v"
        if ($revise.prompt -cne "Revise the specification according to the original request and review findings.") { $problems += "reviser prompt: '$($revise.prompt)'" }
        return $problems
    }

    Test-Case "FR-208 labels: instruction versus data per part, and the breakdown adds up to the prompt sizes" {
        $problems = @()
        $built = New-SpecReviewPrompt -ProjectInstructions "PI" -AgentContract "AC" -AgentInstructions "ROLE" -Mode "mode" -Task "TASK" -Specification "SPEC"
        $expected = @("template|instruction", "project-instructions|instruction", "template|instruction", "agent-contract|instruction", "template|instruction",
            "agent-role|instruction", "template|instruction", "mode|instruction", "template|instruction", "task|data", "template|instruction",
            "specification|data", "template|instruction", "user-prompt|instruction")
        $actual = @($built.parts | ForEach-Object { "$($_.name)|$($_.kind)" })
        if (($actual -join ";") -cne ($expected -join ";")) { $problems += "review parts: $($actual -join ';')" }
        $sum = 0; foreach ($part in $built.parts) { $sum += $part.chars }
        if ($sum -ne ($built.system.Length + $built.prompt.Length)) { $problems += "breakdown sums to $sum, expected $($built.system.Length + $built.prompt.Length)" }
        $run = New-RunAgentPrompt -ProjectInstructions "PI" -AgentContract "AC" -AgentInstructions "ROLE" -Task "TASK" -RepositoryContext "CTX"
        $kinds = @{}; foreach ($part in $run.parts) { if ($part.name -cne "template") { $kinds[$part.name] = $part.kind } }
        if ($kinds["repository-context"] -cne "data" -or $kinds["task"] -cne "data") { $problems += "run-agent: context and task must be data" }
        if ($kinds["agent-role"] -cne "instruction" -or $kinds["agent-contract"] -cne "instruction" -or $kinds["project-instructions"] -cne "instruction") { $problems += "run-agent: role, contract and project instructions must be instruction" }
        $revise = New-SpecRevisePrompt -ProjectInstructions "PI" -AgentContract "AC" -AgentInstructions "ROLE" -Mode "m" -Task "T" -Specification "S" -Review "R"
        $reviseData = @($revise.parts | Where-Object { $_.kind -ceq "data" } | ForEach-Object { $_.name })
        if (($reviseData -join ",") -cne "task,specification,review") { $problems += "reviser data parts: $($reviseData -join ',')" }
        return $problems
    }

    Test-Case "FR-203 inputs that look like format strings or expansions stay literal" {
        $problems = @()
        $hostile = '{0} {1:N2} $env:USERNAME $(Get-Date) ${env:COMPUTERNAME} `n `$x @" "@ %USERNAME%'
        $built = New-SpecReviewPrompt -ProjectInstructions $hostile -AgentContract $hostile -AgentInstructions $hostile -Mode $hostile -Task $hostile -Specification $hostile
        $occurrences = ([regex]::Matches($built.system, [regex]::Escape($hostile))).Count
        if ($occurrences -ne 6) { $problems += "expected the hostile text 6 times, found $occurrences" }
        if ($built.system.Contains($env:USERNAME + " ") -and $hostile.Contains($env:USERNAME)) { $problems += "an expansion happened" }
        return $problems
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Passed: $script:passed"
Write-Host "Failed: $script:failed"
Write-Host "SKIPPED_TESTS: none"

if ($script:failed -eq 0 -and $script:passed -gt 0) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "STATUS: FAIL" -ForegroundColor Red
exit 1
