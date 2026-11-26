<#
.SYNOPSIS
    Offline suite for the Phase 3 run manifest library (work package B1):
    scripts\lib\manifest.ps1 and scripts\lib\run-manifest.schema.json.

.DESCRIPTION
    FR-304 (run id, claim), FR-305 (atomic write, locked read, string sources), FR-306
    (schema subset and validator), FR-309 (derived status), AC-309, AC-329 and the
    writer-reader half of AC-308. No Ollama, no network, no Git; everything is written
    under a temporary folder that is removed at the end.

    The cases that need several processes (the claim race of AC-329, the writer and
    readers of AC-308) start child Windows PowerShell processes from scripts written
    into the temporary folder. Expected values are literals worked out from the spec
    (the XR-08 enum lists, the FR-308 category list, the FR-307 category mapping),
    never read from the schema file under test.
#>
param()

$ErrorActionPreference = "Stop"

$scriptsDirectory = $PSScriptRoot
$repositoryRoot = Split-Path -Parent $scriptsDirectory
$libraryPath = Join-Path $scriptsDirectory "lib\manifest.ps1"
$schemaPath = Join-Path $scriptsDirectory "lib\run-manifest.schema.json"
$engineLibraryPath = Join-Path $scriptsDirectory "lib\agent-exec.ps1"
$powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

foreach ($path in @($libraryPath, $schemaPath, $engineLibraryPath, $powerShellExe)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required path not found: $path" }
}

. $libraryPath

$script:passed = 0
$script:failed = 0
$originalRunIdVariable = $env:AI_HARNESS_RUN_ID
$env:AI_HARNESS_RUN_ID = $null

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-harness-manifest-" + [guid]::NewGuid().ToString())
[void][System.IO.Directory]::CreateDirectory($tempRoot)
$script:caseCounter = 0
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------------------
# Bookkeeping and assertions
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

function Assert-True {
    param($Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    if ($Expected -cne $Actual) { throw "$What : expected '$Expected', got '$Actual'" }
}

function Assert-Throws {
    param([string]$What, [scriptblock]$Action, [string]$Prefix)

    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    if ($null -eq $message) { throw "$What : nothing was thrown" }
    if (-not $message.StartsWith($Prefix, [System.StringComparison]::Ordinal)) { throw "$What : expected a message starting with '$Prefix', got '$message'" }
}

function New-CaseDirectory {
    $script:caseCounter++
    $path = Join-Path $tempRoot ("case" + $script:caseCounter)
    [void][System.IO.Directory]::CreateDirectory($path)
    return $path
}

function Get-RunEntryCount {
    param([string]$HarnessRoot)

    $runs = Join-Path $HarnessRoot "runs"
    if (-not (Test-Path -LiteralPath $runs)) { return 0 }
    return @(Get-ChildItem -LiteralPath $runs -Force).Count
}

# ---------------------------------------------------------------------------
# Child processes
# ---------------------------------------------------------------------------

function Start-ChildScript {
    param([string]$Directory, [string]$Name, [string]$Text, [string[]]$Arguments)

    $scriptPath = Join-Path $Directory $Name
    [System.IO.File]::WriteAllText($scriptPath, $Text, $utf8NoBom)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $powerShellExe
    $quoted = @($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '" ' + $quoted
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    return [pscustomobject]@{ Process = $process; Out = $outTask; Err = $errTask }
}

# Waits for a child; a child that runs past the timeout is killed and reported.
function Wait-Child {
    param($Child, [int]$TimeoutSec = 120)

    $finished = $Child.Process.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) { try { $Child.Process.Kill() } catch { } ; $Child.Process.WaitForExit() }
    return [pscustomobject]@{ TimedOut = (-not $finished); ExitCode = $Child.Process.ExitCode; Output = $Child.Out.Result; Error = $Child.Err.Result }
}

# ---------------------------------------------------------------------------
# Manifest builders (plain .NET strings only; the test follows FR-305)
# ---------------------------------------------------------------------------

$hashA = ("a" * 64)
$hashB = ("b" * 64)

function New-StageRecord {
    param([string]$Id, [string]$Kind = "agent", [string]$Agent = $null, [int]$Attempt = 1, [string]$Status = "succeeded", $Verdict = $null)

    return [ordered]@{
        id = $Id; kind = $Kind; agent = $(if ($Agent) { $Agent } else { $null }); attempt = $Attempt; status = $Status; reason = $null
        startedAtUtc = "2026-11-26T10:00:00.000Z"; durationMs = 120; exitCode = 0
        resolution = [ordered]@{ profile = "fast"; model = "m"; modelSource = "profile"; timeoutSec = 600 }
        budget = [ordered]@{ contextWindow = 16384; estimatedPromptTokens = 900; withinBudget = $true }
        callId = "11111111-2222-3333-4444-555555555555"; engineAttempts = 1; callDurationMs = 100
        warnings = @(); contextSha256 = $null; verdict = $Verdict
        output = [ordered]@{ path = "inputs\x.md"; sha256 = $hashA }
        error = $null
    }
}

# The one-revision specify shape of AC-305: succeeded, exit 0, six stages, three artifacts.
function New-SucceededManifest {
    return [ordered]@{
        schemaVersion = 1; runId = "20261126T100000Z-0123abcd"; workflow = "specify"; status = "succeeded"; exitCode = 0
        createdAtUtc = "2026-11-26T10:00:00.000Z"; startedAtUtc = "2026-11-26T10:00:00.100Z"; endedAtUtc = "2026-11-26T10:05:00.000Z"
        warnings = @("run_id_env_reused"); error = $null
        harness = [ordered]@{ root = "C:\harness"; gitCommit = $null; gitDirty = $null; registrySchemaVersion = 2; registrySha256 = $hashA; ollamaUrl = "http://127.0.0.1:11434" }
        target = [ordered]@{ root = "C:\target"; artifactDir = "C:\target\.ai-harness\specs" }
        process = [ordered]@{ pid = 4242; processStartUtc = "2026-11-26T09:59:59.500Z"; background = $false }
        request = [ordered]@{ name = "a"; mode = "documentation"; maxRevisions = 3; taskSha256 = $hashA; taskFile = "inputs\task.md"; include = @("src"); revision = $null; overrides = [ordered]@{ model = $null; profile = $null } }
        context = [ordered]@{ file = "inputs\context.txt"; sha256 = $hashB; chars = 100; files = @([ordered]@{ path = "src\a.ps1"; sha256 = $hashA; sizeBytes = 10 }) }
        stages = @(
            (New-StageRecord -Id "spec-generate" -Agent "spec")
            (New-StageRecord -Id "spec-validate" -Kind "deterministic")
            (New-StageRecord -Id "spec-review" -Agent "spec-reviewer" -Attempt 1 -Verdict "FAIL")
            (New-StageRecord -Id "spec-revise" -Agent "spec-reviser" -Attempt 1)
            (New-StageRecord -Id "revised-validate" -Kind "deterministic" -Attempt 1)
            (New-StageRecord -Id "spec-review" -Agent "spec-reviewer" -Attempt 2 -Verdict "PASS")
        )
        artifacts = @(
            [ordered]@{ role = "spec"; root = "target"; path = ".ai-harness\specs\a.md"; sha256 = $hashA; trust = "untrusted-draft" }
            [ordered]@{ role = "review"; root = "target"; path = ".ai-harness\specs\a.review.md"; sha256 = $hashB; trust = "untrusted-draft" }
            [ordered]@{ role = "context"; root = "run"; path = "inputs\context.txt"; sha256 = $hashB; trust = "deterministic-check" }
        )
        verification = @()
    }
}

function New-ErrorRecord {
    param([string]$Category = "stage_failed", $EngineCategory = $null)
    return [ordered]@{ category = $Category; engineCategory = $EngineCategory; message = "boom"; hint = $null; retryable = $null; httpStatus = $null }
}

# A running manifest (created before the first stage): exitCode null, one running stage.
function New-RunningManifest {
    $m = New-SucceededManifest
    $m.status = "running"; $m.exitCode = $null; $m.endedAtUtc = $null
    $running = New-StageRecord -Id "spec-generate" -Agent "spec" -Status "running"
    $running.exitCode = $null; $running.durationMs = $null; $running.output = $null
    $m.stages = @($running)
    $m.artifacts = @()
    return $m
}

function New-FailedManifest {
    $m = New-SucceededManifest
    $m.status = "failed"; $m.exitCode = 1
    $m.error = New-ErrorRecord -Category "validation_failed"
    $m.stages[1].status = "failed"
    return $m
}

# Errors of the validator for the object form and for its JSON text; both must agree.
function Get-ManifestErrors {
    param($Manifest, [string]$Schema = "")

    $arguments = @{ }
    if ($Schema.Length -gt 0) { $arguments.SchemaPath = $Schema }
    $fromObject = Test-HarnessManifest -Manifest $Manifest @arguments
    $text = ConvertTo-Json -InputObject $Manifest -Depth 10
    $fromText = Test-HarnessManifest -Manifest $text @arguments
    $parsed = ConvertFrom-Json -InputObject $text
    $fromParsed = Test-HarnessManifest -Manifest $parsed @arguments
    $a = (@($fromObject.errors) -join "|")
    if ($a -cne (@($fromText.errors) -join "|")) { throw "object form and JSON text disagree: '$a' versus '$(@($fromText.errors) -join '|')'" }
    if ($a -cne (@($fromParsed.errors) -join "|")) { throw "object form and parsed form disagree: '$a' versus '$(@($fromParsed.errors) -join '|')'" }
    if ($fromObject.valid -ne ($fromObject.errors.Count -eq 0)) { throw "valid does not match the error list" }
    return @($fromObject.errors)
}

function Assert-Valid {
    param([string]$What, $Manifest)
    $errors = @(Get-ManifestErrors -Manifest $Manifest)
    if ($errors.Count -ne 0) { throw "$What : expected valid, got: $($errors -join '; ')" }
}

# The fixture fails with exactly this "<path>: <code>" and nothing else.
function Assert-Fails {
    param([string]$What, $Manifest, [string]$Expected)
    $errors = @(Get-ManifestErrors -Manifest $Manifest)
    if ($errors.Count -ne 1 -or $errors[0] -cne $Expected) { throw "$What : expected exactly '$Expected', got: $($errors -join '; ')" }
}

# ---------------------------------------------------------------------------
# AC-329: run id grammar and claim (FR-304)
# ---------------------------------------------------------------------------

Test-Case "AC-329: invalid -RunId values exit invalid_arguments and add nothing under runs" {
    $harness = New-CaseDirectory
    $bad = @("abc`n", "abc`r", "CON", "con.x", "abc.", "-a", "a/b", "a\b", "..", ("a" * 65), "nul.txt", "a b", "", ".a", "Aux.tar.gz", "lpt1", "COM9", "abc?", ("a" + [char]0x00E9), "a`$b")
    foreach ($id in $bad) {
        $shown = ($id -replace "[^\x20-\x7e]", "?")
        Assert-True (-not (Test-HarnessRunId -Id $id)) "Test-HarnessRunId accepted '$shown'"
        Assert-Throws "claim of '$shown'" { New-HarnessRunClaim -HarnessRoot $harness -RunId $id -EnvRunId "" } "invalid_arguments:"
    }
    Assert-Equal 0 (Get-RunEntryCount -HarnessRoot $harness) "entries under runs after invalid ids"
}

Test-Case "AC-329: a 64-character id, a.b, A_b-1 and other grammar members are accepted" {
    $harness = New-CaseDirectory
    foreach ($id in @(("a" * 64), "a.b", "A_b-1", "COM0", "console", "con-x", "0", "a-", "a..b")) {
        Assert-True (Test-HarnessRunId -Id $id) "Test-HarnessRunId refused '$id'"
        $claim = New-HarnessRunClaim -HarnessRoot $harness -RunId $id -EnvRunId ""
        Assert-Equal $id $claim.RunId "claimed id"
        Assert-Equal "parameter" $claim.Source "source"
        Assert-Equal 0 $claim.Warnings.Count "warnings"
        Assert-True (Test-Path -LiteralPath (Join-Path $claim.RunPath ".claim")) "no .claim in $id"
    }
}

Test-Case "AC-329: an existing id is refused and its directory is left as it was" {
    $harness = New-CaseDirectory
    $first = New-HarnessRunClaim -HarnessRoot $harness -RunId "dup1" -EnvRunId ""
    $marker = Join-Path $first.RunPath "keep.txt"
    [System.IO.File]::WriteAllText($marker, "kept", $utf8NoBom)
    $before = @(Get-ChildItem -LiteralPath $first.RunPath -Force | ForEach-Object { $_.Name + ":" + $_.Length }) -join "|"
    Assert-Throws "second claim" { New-HarnessRunClaim -HarnessRoot $harness -RunId "dup1" -EnvRunId "" } "invalid_arguments:"
    Assert-Throws "second claim, other case" { New-HarnessRunClaim -HarnessRoot $harness -RunId "DUP1" -EnvRunId "" } "invalid_arguments:"
    $after = @(Get-ChildItem -LiteralPath $first.RunPath -Force | ForEach-Object { $_.Name + ":" + $_.Length }) -join "|"
    Assert-Equal $before $after "run directory content"
    Assert-Equal 1 (Get-RunEntryCount -HarnessRoot $harness) "entries under runs"
    Assert-True (-not (Request-HarnessRunClaim -HarnessRoot $harness -RunId "dup1")) "Request-HarnessRunClaim won an id twice"
}

Test-Case "AC-329: the claim file is created empty and the claim is a one-time right" {
    $harness = New-CaseDirectory
    Assert-True (Request-HarnessRunClaim -HarnessRoot $harness -RunId "one") "first request lost"
    Assert-True (-not (Request-HarnessRunClaim -HarnessRoot $harness -RunId "one")) "second request won"
    $claimFile = Get-Item -LiteralPath (Join-Path $harness "runs\one\.claim")
    Assert-Equal 0 $claimFile.Length ".claim length"
    Assert-Throws "relative root" { Request-HarnessRunClaim -HarnessRoot "relative\root" -RunId "x" } "internal_error:"
}

Test-Case "AC-329: four processes claiming the same 200 ids give exactly 200 winners" {
    $harness = New-CaseDirectory
    $racer = @'
param($LibPath, $Root, $StartTicks, $OutPath, $Count)
$ErrorActionPreference = "Stop"
. $LibPath
while ([DateTime]::UtcNow.Ticks -lt [long]$StartTicks) { [System.Threading.Thread]::Sleep(1) }
$won = New-Object 'System.Collections.Generic.List[string]'
for ($i = 1; $i -le [int]$Count; $i++) {
    $id = 'race-{0:D3}' -f $i
    if (Request-HarnessRunClaim -HarnessRoot $Root -RunId $id) { $won.Add($id) }
}
[System.IO.File]::WriteAllLines($OutPath, $won.ToArray())
'@
    $startTicks = [string]([datetime]::UtcNow.AddSeconds(5).Ticks)
    $children = @()
    for ($n = 1; $n -le 4; $n++) {
        $children += Start-ChildScript -Directory $harness -Name "racer$n.ps1" -Text $racer -Arguments @($libraryPath, $harness, $startTicks, (Join-Path $harness "won$n.txt"), "200")
    }
    $winners = New-Object 'System.Collections.Generic.List[string]'
    for ($n = 1; $n -le 4; $n++) {
        $result = Wait-Child -Child $children[$n - 1] -TimeoutSec 120
        Assert-True ((-not $result.TimedOut) -and $result.ExitCode -eq 0) "racer $n failed (exit $($result.ExitCode), timeout $($result.TimedOut)): $($result.Error)"
        foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $harness "won$n.txt"))) { if ($line.Length -gt 0) { $winners.Add($line) } }
    }
    Assert-Equal 200 $winners.Count "winner lines in total"
    $distinct = @($winners | Sort-Object -Unique).Count
    Assert-Equal 200 $distinct "distinct winners"
    Assert-Equal 200 (Get-RunEntryCount -HarnessRoot $harness) "claimed directories under runs"
}

Test-Case "AC-329: AI_HARNESS_RUN_ID rule: invalid is ignored, free is used, an existing one gets -<4 hex>" {
    $harness = New-CaseDirectory
    $generated = '\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\z'

    foreach ($badEnv in @("a/b", "CON", "abc.", ("a" * 65), "a b")) {
        $claim = New-HarnessRunClaim -HarnessRoot $harness -EnvRunId $badEnv
        Assert-True ($claim.RunId -cmatch $generated) "generated id expected for env '$badEnv', got '$($claim.RunId)'"
        Assert-Equal "invalid_run_id_env" (@($claim.Warnings) -join ",") "warnings for env '$badEnv'"
        Assert-Equal "generated" $claim.Source "source"
    }

    $free = New-HarnessRunClaim -HarnessRoot $harness -EnvRunId "corr-1"
    Assert-Equal "corr-1" $free.RunId "free env id"
    Assert-Equal 0 $free.Warnings.Count "warnings of a free env id"
    Assert-Equal "environment" $free.Source "source"

    $again = New-HarnessRunClaim -HarnessRoot $harness -EnvRunId "corr-1"
    Assert-True ($again.RunId -cmatch '\Acorr-1-[0-9a-f]{4}\z') "expected corr-1-<4 hex>, got '$($again.RunId)'"
    Assert-Equal "run_id_env_reused" (@($again.Warnings) -join ",") "warnings of a reused env id"
    Assert-True (Test-Path -LiteralPath (Join-Path $again.RunPath ".claim")) "suffixed id has no .claim"
    Assert-True (Test-HarnessRunId -Id "corr-1") "sanity"

    $long = ("e" * 64)
    [void](New-HarnessRunClaim -HarnessRoot $harness -EnvRunId $long)
    $longAgain = New-HarnessRunClaim -HarnessRoot $harness -EnvRunId $long
    Assert-Equal 69 $longAgain.RunId.Length "length of a suffixed 64-character id"
    Assert-True ($longAgain.RunId -cmatch '\Ae{64}-[0-9a-f]{4}\z') "suffix shape of the long id"
    $manifestValid = New-SucceededManifest
    $manifestValid.runId = $longAgain.RunId
    Assert-Valid "a 69-character runId in a manifest" $manifestValid
}

Test-Case "AC-329: -RunId wins over the environment; a generated id is unique and shaped <UTC>-<8 hex>" {
    $harness = New-CaseDirectory
    $claim = New-HarnessRunClaim -HarnessRoot $harness -RunId "given-1" -EnvRunId "env-1"
    Assert-Equal "given-1" $claim.RunId "run id"
    Assert-Equal 0 $claim.Warnings.Count "warnings"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $harness "runs\env-1"))) "the environment id was claimed too"
    $ids = @()
    for ($n = 0; $n -lt 5; $n++) { $ids += (New-HarnessRunClaim -HarnessRoot $harness -EnvRunId "").RunId }
    Assert-Equal 5 @($ids | Sort-Object -Unique).Count "distinct generated ids"
    foreach ($id in $ids) { Assert-True (($id -cmatch '\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\z') -and (Test-HarnessRunId -Id $id)) "bad generated id '$id'" }
    $default = $env:AI_HARNESS_RUN_ID
    $env:AI_HARNESS_RUN_ID = "from-env-9"
    try { $viaDefault = New-HarnessRunClaim -HarnessRoot $harness } finally { $env:AI_HARNESS_RUN_ID = $default }
    Assert-Equal "from-env-9" $viaDefault.RunId "the default of -EnvRunId reads AI_HARNESS_RUN_ID"
}

Test-Case "FR-304: .gitignore lists the runs directory" {
    $lines = @([System.IO.File]::ReadAllLines((Join-Path $repositoryRoot ".gitignore")) | ForEach-Object { $_.Trim() })
    Assert-True (($lines -ccontains "/runs/") -or ($lines -ccontains "runs/")) ".gitignore has neither /runs/ nor runs/"
}

# ---------------------------------------------------------------------------
# AC-309: schema and validator (FR-306)
# ---------------------------------------------------------------------------

Test-Case "AC-309: valid fixtures pass (succeeded, running, failed, null in nullable fields)" {
    Assert-Valid "succeeded one-revision shape" (New-SucceededManifest)
    Assert-Valid "running shape" (New-RunningManifest)
    Assert-Valid "failed shape" (New-FailedManifest)
    $m = New-SucceededManifest
    $m.context = $null; $m.target.root = $null; $m.target.artifactDir = $null; $m.stages[0].agent = $null; $m.stages[0].output = $null; $m.request.taskSha256 = $null
    $m.extraTopLevelProperty = "unknown properties are allowed"; $m.stages[0].extra = 1
    Assert-Valid "nulls in nullable fields and unknown properties" $m
    $needs = New-SucceededManifest
    $needs.status = "needs_input"; $needs.exitCode = 3; $needs.error = New-ErrorRecord -Category "needs_human_input"
    Assert-Valid "needs_input" $needs
    $skipped = New-SucceededManifest
    $skipped.status = "failed"; $skipped.exitCode = 1; $skipped.error = New-ErrorRecord -Category "max_revisions_reached"
    $skipped.stages[5].status = "skipped"; $skipped.stages[5].reason = "dependency failed: spec-revise"; $skipped.stages[5].verdict = $null
    Assert-Valid "failed with a skipped stage" $skipped
    $retry = New-SucceededManifest
    $retry.stages[0].attempt = 2
    Assert-Valid "same id in another attempt" $retry
}

Test-Case "AC-309: a missing required key (top level, stage, artifact) is missing_required at its path" {
    foreach ($key in @("runId", "status", "exitCode", "warnings", "error", "harness", "stages", "artifacts", "verification")) {
        $m = New-SucceededManifest; $m.Remove($key)
        $expected = "`$.${key}: missing_required"
        $errors = @(Get-ManifestErrors -Manifest $m)
        Assert-True ($errors -ccontains $expected) "removing '$key': expected '$expected', got: $($errors -join '; ')"
    }
    $m = New-SucceededManifest; $m.stages[2].Remove("id")
    $errors = @(Get-ManifestErrors -Manifest $m)
    Assert-True ($errors -ccontains '$.stages[2].id: missing_required') "stage: $($errors -join '; ')"
    $m = New-SucceededManifest; $m.artifacts[1].Remove("sha256")
    Assert-Fails "artifact" $m '$.artifacts[1].sha256: missing_required'
    $m = New-SucceededManifest; $m.harness.Remove("root")
    Assert-Fails "nested object" $m '$.harness.root: missing_required'
    $m = New-SucceededManifest; $m.Remove("status"); $m.Status = "succeeded"
    $errors = @(Get-ManifestErrors -Manifest $m)
    Assert-True ($errors -ccontains '$.status: missing_required') "a key that differs in case counts as missing: $($errors -join '; ')"
}

Test-Case "AC-309: a wrong type is wrong_type at its path; null is valid in a nullable field and invalid in another" {
    $m = New-SucceededManifest; $m.exitCode = "0"
    Assert-Fails "exitCode string" $m '$.exitCode: wrong_type'
    $m = New-SucceededManifest; $m.warnings = "x"
    Assert-Fails "warnings string" $m '$.warnings: wrong_type'
    $m = New-SucceededManifest; $m.warnings = @("a", 1)
    Assert-Fails "warnings item" $m '$.warnings[1]: wrong_type'
    $m = New-SucceededManifest; $m.stages[1].attempt = 1.5
    Assert-Fails "attempt fraction" $m '$.stages[1].attempt: wrong_type'
    $m = New-SucceededManifest; $m.process.pid = "12"
    Assert-Fails "pid string" $m '$.process.pid: wrong_type'
    $m = New-SucceededManifest; $m.process.background = "false"
    Assert-Fails "background string" $m '$.process.background: wrong_type'
    $m = New-SucceededManifest; $m.harness = "x"
    Assert-Fails "harness string" $m '$.harness: wrong_type'
    $m = New-SucceededManifest; $m.stages = [ordered]@{ id = "x" }
    Assert-Fails "stages object" $m '$.stages: wrong_type'
    $m = New-SucceededManifest; $m.stages[0].attempt = 2.0
    Assert-Valid "an integral number is an integer" $m

    $m = New-RunningManifest; $m.endedAtUtc = $null; $m.stages[0].agent = $null
    Assert-Valid "null in nullable fields" $m
    $m = New-SucceededManifest; $m.workflow = $null
    Assert-Fails "null workflow" $m '$.workflow: wrong_type'
    $m = New-SucceededManifest; $m.stages[0].id = $null
    Assert-Fails "null stage id" $m '$.stages[0].id: wrong_type'
    $m = New-SucceededManifest; $m.process.background = $null
    Assert-Fails "null background" $m '$.process.background: wrong_type'
    $m = New-SucceededManifest; $m.schemaVersion = $null
    Assert-Fails "null schemaVersion" $m '$.schemaVersion: wrong_type'
}

Test-Case "AC-309: an unknown or wrong-case enum value is not_in_enum at its path" {
    $m = New-SucceededManifest; $m.status = "unknown"; $m.exitCode = $null
    $errors = @(Get-ManifestErrors -Manifest $m)
    Assert-Equal '$.status: not_in_enum' ($errors -join "|") "run status unknown"
    $m = New-SucceededManifest; $m.stages[3].status = "paused"
    Assert-Fails "stage status paused" $m '$.stages[3].status: not_in_enum'
    $m = New-FailedManifest; $m.status = "Failed"
    Assert-Fails "Failed (case)" $m '$.status: not_in_enum'
    $m = New-SucceededManifest; $m.stages[0].status = "Succeeded"
    Assert-Fails "stage Succeeded (case)" $m '$.stages[0].status: not_in_enum'
    $m = New-SucceededManifest; $m.artifacts[0].trust = "trusted"
    Assert-Fails "trust" $m '$.artifacts[0].trust: not_in_enum'
    $m = New-SucceededManifest; $m.artifacts[0].root = "Target"
    Assert-Fails "artifact root (case)" $m '$.artifacts[0].root: not_in_enum'
    $m = New-SucceededManifest; $m.stages[0].kind = "model"
    Assert-Fails "kind" $m '$.stages[0].kind: not_in_enum'
    $m = New-SucceededManifest; $m.stages[2].verdict = "pass"
    Assert-Fails "verdict (case)" $m '$.stages[2].verdict: not_in_enum'
    $m = New-FailedManifest; $m.error.category = "http_5xx"
    Assert-Fails "an engine category in error.category" $m '$.error.category: not_in_enum'
    $m = New-FailedManifest; $m.error.engineCategory = "http_error"
    Assert-Fails "a CLI category in error.engineCategory" $m '$.error.engineCategory: not_in_enum'
    $m = New-FailedManifest; $m.stages[1].error = New-ErrorRecord -Category "nope"
    Assert-Fails "stage error category" $m '$.stages[1].error.category: not_in_enum'
    $m = New-FailedManifest; $m.stages[1].error = New-ErrorRecord -Category "http_error" -EngineCategory "model_load_failed"
    Assert-Valid "stage error with an engine category" $m
}

Test-Case "AC-309: a bad sha256, pattern or number is pattern_mismatch or below_minimum" {
    $m = New-SucceededManifest; $m.artifacts[0].sha256 = ("A" * 64)
    Assert-Fails "uppercase hex" $m '$.artifacts[0].sha256: pattern_mismatch'
    $m = New-SucceededManifest; $m.artifacts[0].sha256 = ("a" * 63)
    Assert-Fails "63 characters" $m '$.artifacts[0].sha256: pattern_mismatch'
    $m = New-SucceededManifest; $m.artifacts[0].sha256 = (("a" * 64) + "`n")
    Assert-Fails "trailing newline" $m '$.artifacts[0].sha256: pattern_mismatch'
    $m = New-SucceededManifest; $m.request.taskSha256 = "xyz"
    Assert-Fails "taskSha256" $m '$.request.taskSha256: pattern_mismatch'
    $m = New-SucceededManifest; $m.stages[0].output.sha256 = "zz"
    Assert-Fails "output sha256" $m '$.stages[0].output.sha256: pattern_mismatch'
    $m = New-SucceededManifest; $m.createdAtUtc = "2026-11-26 10:00:00"
    Assert-Fails "timestamp" $m '$.createdAtUtc: pattern_mismatch'
    $m = New-SucceededManifest; $m.runId = "abc."
    Assert-Fails "runId grammar" $m '$.runId: pattern_mismatch'
    $m = New-SucceededManifest; $m.runId = ("a" * 70)
    Assert-Fails "runId of 70 characters" $m '$.runId: pattern_mismatch'
    $m = New-SucceededManifest; $m.stages[0].attempt = 0
    Assert-Fails "attempt 0" $m '$.stages[0].attempt: below_minimum'
    $m = New-FailedManifest; $m.exitCode = -1
    Assert-Fails "exitCode -1" $m '$.exitCode: below_minimum'
    $m = New-SucceededManifest; $m.stages[0].durationMs = -5
    Assert-Fails "durationMs -5" $m '$.stages[0].durationMs: below_minimum'
}

Test-Case "AC-309: schemaVersion 2 is unsupported_schema_version" {
    $m = New-SucceededManifest; $m.schemaVersion = 2
    Assert-Fails "schemaVersion 2" $m '$.schemaVersion: unsupported_schema_version'
    $m = New-SucceededManifest; $m.schemaVersion = 0
    Assert-Fails "schemaVersion 0" $m '$.schemaVersion: unsupported_schema_version'
}

Test-Case "AC-309: the invariants (terminal exit code and end time, succeeded, error, duplicates, artifact paths)" {
    $m = New-SucceededManifest; $m.exitCode = $null
    Assert-Fails "succeeded with null exitCode" $m '$.exitCode: invariant_terminal_exit_code'
    $m = New-FailedManifest; $m.exitCode = $null
    Assert-Fails "failed with null exitCode" $m '$.exitCode: invariant_terminal_exit_code'
    $m = New-FailedManifest; $m.exitCode = 5
    Assert-Fails "failed with exitCode 5" $m '$.exitCode: invariant_terminal_exit_code'
    $m = New-SucceededManifest; $m.endedAtUtc = $null
    Assert-Fails "terminal without endedAtUtc" $m '$.endedAtUtc: invariant_terminal_ended_at'
    $m = New-SucceededManifest; $m.exitCode = 1
    Assert-Fails "succeeded with exitCode 1" $m '$.exitCode: invariant_succeeded_exit_code'
    $m = New-SucceededManifest; $m.stages[4].status = "failed"
    Assert-Fails "succeeded with a failed stage" $m '$.stages[4].status: invariant_succeeded_failed_stage'
    $m = New-FailedManifest; $m.error = $null
    Assert-Fails "failed without error" $m '$.error: invariant_error_required'
    $m = New-SucceededManifest; $m.status = "needs_input"; $m.exitCode = 3; $m.error = $null
    Assert-Fails "needs_input without error" $m '$.error: invariant_error_required'
    $m = New-SucceededManifest; $m.stages[2].id = "spec-validate"
    Assert-Fails "duplicate (id, attempt)" $m '$.stages[2]: invariant_duplicate_stage'
    foreach ($bad in @("C:\x\a.md", "c:a.md", "/etc/a.md", "\a.md", "\\server\share\a.md", "..\a.md", "a/../b.md", "a\..", "..")) {
        $m = New-SucceededManifest; $m.artifacts[0].path = $bad
        Assert-Fails "artifact path '$bad'" $m '$.artifacts[0].path: invariant_artifact_path'
    }
    foreach ($good in @(".ai-harness\specs\a.md", "inputs/task.md", "a..b", "...x", "a.b\c")) {
        $m = New-SucceededManifest; $m.artifacts[0].path = $good
        Assert-Valid "artifact path '$good'" $m
    }
    $m = New-RunningManifest
    Assert-Valid "running run without exitCode and end time" $m
    $m = New-RunningManifest; $m.status = "queued"
    Assert-Valid "queued run" $m
}

Test-Case "AC-309: text that is not a JSON object is wrong_type at the root" {
    foreach ($text in @("not json at all", "[1,2]", "5", "null", "")) {
        $result = Test-HarnessManifest -Manifest $text
        Assert-True (-not $result.valid) "'$text' was valid"
        Assert-Equal '$: wrong_type' ($result.errors -join "|") "errors for '$text'"
    }
    $result = Test-HarnessManifest -Manifest $null
    Assert-Equal '$: wrong_type' ($result.errors -join "|") "errors for null"
}

Test-Case "AC-309: the enum lists of the schema equal the literal XR-08 and FR-308 lists (D-312)" {
    $schema = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($schemaPath))
    $runStatuses = @("queued", "running", "succeeded", "failed", "needs_input", "cancelled", "abandoned")
    $stageStatuses = @("pending", "running", "succeeded", "failed", "skipped", "unsupported", "cancelled")
    $trusts = @("untrusted-draft", "deterministic-check", "verified-by-command")
    $categories = @("invalid_arguments", "registry_invalid", "agent_not_found", "ollama_unreachable", "model_not_installed", "model_load_failed", "context_budget_exceeded", "context_invalid", "timeout", "http_error", "empty_output", "invalid_output_format", "validation_failed", "review_failed", "max_revisions_reached", "needs_human_input", "unsupported_stage", "artifact_exists", "artifact_in_use", "stage_failed", "internal_error", "cancelled", "abandoned")
    $engineCategories = @("http_5xx", "http_4xx", "timeout", "transport_unreachable", "transport_reset", "transport_other", "context_budget_exceeded", "thinking_budget_exhausted", "empty_response", "format_invalid", "model_not_installed", "model_load_failed")
    Assert-Equal 7 $runStatuses.Count "run statuses"
    Assert-Equal 7 $stageStatuses.Count "stage statuses"
    Assert-Equal 3 $trusts.Count "trust values"
    Assert-Equal 23 $categories.Count "categories (21 written plus cancelled and abandoned reserved)"
    Assert-Equal 12 $engineCategories.Count "engine categories"
    $stageSchema = $schema.properties.stages.items.properties
    Assert-Equal ($runStatuses -join ",") (@($schema.properties.status.enum) -join ",") "run status enum"
    Assert-Equal ($stageStatuses -join ",") (@($stageSchema.status.enum) -join ",") "stage status enum"
    Assert-Equal ($trusts -join ",") (@($schema.properties.artifacts.items.properties.trust.enum) -join ",") "trust enum"
    Assert-Equal ($categories -join ",") (@($schema.properties.error.properties.category.enum) -join ",") "error.category enum"
    Assert-Equal ($categories -join ",") (@($stageSchema.error.properties.category.enum) -join ",") "stage error.category enum"
    Assert-Equal ($engineCategories -join ",") (@($schema.properties.error.properties.engineCategory.enum) -join ",") "error.engineCategory enum"
    Assert-Equal ($engineCategories -join ",") (@($stageSchema.error.properties.engineCategory.enum) -join ",") "stage engineCategory enum"
    Assert-Equal "agent,deterministic,unsupported" (@($stageSchema.kind.enum) -join ",") "kind enum"
    Assert-Equal "PASS,FAIL" (@($stageSchema.verdict.enum) -join ",") "verdict enum"
    Assert-Equal "target,run" (@($schema.properties.artifacts.items.properties.root.enum) -join ",") "artifact root enum"
}

Test-Case "AC-309: engineCategory equals the hints table of the engine, and the FR-307 mapping stays inside the category enum" {
    $schema = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($schemaPath))
    $source = [System.IO.File]::ReadAllText($engineLibraryPath)
    $block = [regex]::Match($source, '\$hints = \[ordered\]@\{(.*?)\r?\n    \}', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    Assert-True $block.Success "the hints table of Get-AgentErrorCategory was not found"
    $engineKeys = @([regex]::Matches($block.Groups[1].Value, "(?m)^\s+'([a-z0-9_]+)'\s+=\s+'") | ForEach-Object { $_.Groups[1].Value })
    Assert-Equal 12 $engineKeys.Count "keys of the hints table"
    Assert-Equal ($engineKeys -join ",") (@($schema.properties.error.properties.engineCategory.enum) -join ",") "engineCategory enum versus the hints table"
    $mapping = [ordered]@{
        transport_unreachable = "ollama_unreachable"; http_4xx = "http_error"; http_5xx = "http_error"; transport_reset = "http_error"; transport_other = "http_error"
        empty_response = "empty_output"; thinking_budget_exhausted = "empty_output"; format_invalid = "invalid_output_format"
        timeout = "timeout"; context_budget_exceeded = "context_budget_exceeded"; model_not_installed = "model_not_installed"; model_load_failed = "model_load_failed"
    }
    Assert-Equal 12 $mapping.Count "FR-307 mapping entries"
    foreach ($engine in $engineKeys) {
        Assert-True ($mapping.Contains($engine)) "engine category '$engine' has no FR-307 mapping"
        Assert-True (@($schema.properties.error.properties.category.enum) -ccontains $mapping[$engine]) "mapped category '$($mapping[$engine])' of '$engine' is not in the category enum"
    }
}

Test-Case "AC-309: changing one enum value in a temporary schema copy changes the verdict for the same manifest" {
    $copyDirectory = New-CaseDirectory
    $manifest = New-RunningManifest
    $manifest.status = "queued"
    $manifest.stages[0].status = "pending"
    $manifest.artifacts = @([ordered]@{ role = "spec"; root = "run"; path = "a.md"; sha256 = $hashA; trust = "untrusted-draft" })
    Assert-Valid "the same manifest with the real schema" $manifest
    $original = [System.IO.File]::ReadAllText($schemaPath)
    $edits = @(
        @{ From = '"queued", "running"'; To = '"queuedX", "running"'; Expect = '$.status: not_in_enum' }
        @{ From = '"pending", "running"'; To = '"pendingX", "running"'; Expect = '$.stages[0].status: not_in_enum' }
        @{ From = '"untrusted-draft", "deterministic-check"'; To = '"untrusted-draftX", "deterministic-check"'; Expect = '$.artifacts[0].trust: not_in_enum' }
    )
    $index = 0
    foreach ($edit in $edits) {
        $index++
        Assert-Equal 1 ([regex]::Matches($original, [regex]::Escape($edit.From)).Count) "occurrences of $($edit.From)"
        $copy = Join-Path $copyDirectory "schema$index.json"
        [System.IO.File]::WriteAllText($copy, $original.Replace($edit.From, $edit.To), $utf8NoBom)
        $errors = @(Get-ManifestErrors -Manifest $manifest -Schema $copy)
        Assert-Equal $edit.Expect ($errors -join "|") "verdict with the edited copy $index"
    }
    # The default schema is the one beside the library; a missing explicit path is an error.
    Assert-Throws "missing schema file" { Test-HarnessManifest -Manifest $manifest -SchemaPath (Join-Path $copyDirectory "nope.json") } ""
}

# ---------------------------------------------------------------------------
# AC-308 writer-reader half: atomic write, locked read, string sources (FR-305)
# ---------------------------------------------------------------------------

Test-Case "AC-308: the manifest is UTF-8 without BOM, JSON, valid, and a rewrite replaces it with no temp left" {
    $directory = New-CaseDirectory
    $path = Join-Path $directory "manifest.json"
    $m = New-SucceededManifest
    $m.request.name = "caf" + [char]0x00E9 + " " + [char]0x4E2D
    Write-HarnessManifest -Path $path -Manifest $m
    $bytes = [System.IO.File]::ReadAllBytes($path)
    Assert-True ($bytes.Length -gt 100) "manifest too small"
    Assert-True ($bytes[0] -eq 0x7B) "the first byte is not '{' (a BOM?): $($bytes[0])"
    $first = Read-HarnessManifest -Path $path
    Assert-Equal $m.request.name $first.request.name "non-ASCII round trip"
    $verdict = Test-HarnessManifest -Manifest (Read-HarnessManifestText -Path $path)
    Assert-True $verdict.valid "written manifest is invalid: $($verdict.errors -join '; ')"
    $m.status = "failed"; $m.exitCode = 2; $m.error = New-ErrorRecord
    Write-HarnessManifest -Path $path -Manifest $m
    Assert-Equal "failed" (Read-HarnessManifest -Path $path).status "status after the rewrite"
    Assert-Equal 1 @(Get-ChildItem -LiteralPath $directory -Force).Count "files in the run folder after two writes"
    [System.IO.File]::WriteAllBytes($path, ([byte[]](0xEF, 0xBB, 0xBF) + $utf8NoBom.GetBytes('{"a":1}')))
    Assert-Equal 1 (Read-HarnessManifest -Path $path).a "a BOM is dropped by the reader"
}

Test-Case "AC-308: a locked manifest is retried and then fails cleanly; a missing one is retried and is manifest_invalid" {
    $directory = New-CaseDirectory
    $path = Join-Path $directory "manifest.json"
    $m = New-SucceededManifest
    Write-HarnessManifest -Path $path -Manifest $m
    # A reader that does not share Delete blocks File.Replace: the writer retries, then throws, and leaves no temp.
    $blocker = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        Assert-Throws "write against a blocked manifest" { Write-HarnessManifest -Path $path -Manifest $m -Retries 5 -DelayMs 30 } "internal_error:"
        Assert-True ($watch.ElapsedMilliseconds -ge 100) "the writer did not wait between its attempts ($($watch.ElapsedMilliseconds) ms)"
    }
    finally { $blocker.Dispose() }
    Assert-Equal 1 @(Get-ChildItem -LiteralPath $directory -Force).Count "files after a failed write"
    Write-HarnessManifest -Path $path -Manifest $m
    # An exclusive lock on the manifest: the reader retries, then fails with manifest_invalid.
    $exclusive = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        Assert-Throws "read of an exclusively locked manifest" { Read-HarnessManifest -Path $path -Retries 5 -DelayMs 30 } "manifest_invalid:"
        Assert-True ($watch.ElapsedMilliseconds -ge 100) "the reader did not retry ($($watch.ElapsedMilliseconds) ms)"
    }
    finally { $exclusive.Dispose() }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Assert-Throws "read of a missing manifest" { Read-HarnessManifest -Path (Join-Path $directory "missing.json") -Retries 5 -DelayMs 30 } "manifest_invalid:"
    Assert-True ($watch.ElapsedMilliseconds -ge 100) "a missing file was not retried ($($watch.ElapsedMilliseconds) ms)"
    [System.IO.File]::WriteAllText($path, "{ not json", $utf8NoBom)
    Assert-Throws "read of broken JSON" { Read-HarnessManifest -Path $path } "manifest_invalid:"
}

Test-Case "AC-308: a writer rewrites 200 times while readers read in a loop; every read parses and validates" {
    $directory = New-CaseDirectory
    $path = Join-Path $directory "manifest.json"
    $template = New-RunningManifest
    $template.warnings = @("iteration-0")
    $list = New-Object 'System.Collections.Generic.List[object]'
    for ($n = 0; $n -lt 40; $n++) { $list.Add([ordered]@{ role = "spec"; root = "run"; path = "files\item$n.md"; sha256 = $hashA; trust = "untrusted-draft" }) }
    $template.artifacts = @($list.ToArray())
    Write-HarnessManifest -Path $path -Manifest $template

    $writerText = @'
param($LibPath, $ManifestPath, $StartTicks, $Iterations, $DonePath, $ResultPath)
$ErrorActionPreference = "Stop"
. $LibPath
while ([DateTime]::UtcNow.Ticks -lt [long]$StartTicks) { [System.Threading.Thread]::Sleep(1) }
$failures = 0
$firstError = ""
$writes = 0
for ($i = 1; $i -le [int]$Iterations; $i++) {
    try {
        $m = ConvertFrom-Json -InputObject (Read-HarnessTextFile -Path $ManifestPath)
        $m.warnings = @("iteration-$i")
        Write-HarnessManifest -Path $ManifestPath -Manifest $m
        $writes++
    }
    catch { $failures++; if ($firstError.Length -eq 0) { $firstError = $_.Exception.Message } }
}
[System.IO.File]::WriteAllText($ResultPath, ('{"writes":' + $writes + ',"failures":' + $failures + ',"firstError":"' + $firstError.Replace('"', "'").Replace('\', '/') + '"}'))
[System.IO.File]::WriteAllText($DonePath, "done")
'@
    $readerText = @'
param($LibPath, $ManifestPath, $StartTicks, $DonePath, $ResultPath, $Validate)
$ErrorActionPreference = "Stop"
. $LibPath
while ([DateTime]::UtcNow.Ticks -lt [long]$StartTicks) { [System.Threading.Thread]::Sleep(1) }
$reads = 0
$bad = 0
$exhausted = 0
$firstError = ""
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$finished = $false
while (-not $finished) {
    $finished = [System.IO.File]::Exists($DonePath)
    try {
        $text = Read-HarnessManifestText -Path $ManifestPath
        $object = ConvertFrom-Json -InputObject $text
        if ($Validate -eq "1") {
            $verdict = Test-HarnessManifest -Manifest $object
            if (-not $verdict.valid) { throw ("invalid: " + ($verdict.errors -join "; ")) }
        }
        [void]$seen.Add([string]$object.warnings[0])
    }
    catch {
        $message = $_.Exception.Message
        if ($message.StartsWith("manifest_invalid: cannot read", [System.StringComparison]::Ordinal)) { $exhausted++ }
        $bad++
        if ($firstError.Length -eq 0) { $firstError = $message }
    }
    $reads++
}
[System.IO.File]::WriteAllText($ResultPath, ('{"reads":' + $reads + ',"bad":' + $bad + ',"exhausted":' + $exhausted + ',"distinct":' + $seen.Count + ',"firstError":"' + $firstError.Replace('"', "'").Replace('\', '/') + '"}'))
'@
    $startTicks = [string]([datetime]::UtcNow.AddSeconds(5).Ticks)
    $done = Join-Path $directory "writer.done"
    $writer = Start-ChildScript -Directory $directory -Name "writer.ps1" -Text $writerText -Arguments @($libraryPath, $path, $startTicks, "200", $done, (Join-Path $directory "writer.json"))
    $readerOne = Start-ChildScript -Directory $directory -Name "reader1.ps1" -Text $readerText -Arguments @($libraryPath, $path, $startTicks, $done, (Join-Path $directory "reader1.json"), "1")
    $readerTwo = Start-ChildScript -Directory $directory -Name "reader2.ps1" -Text $readerText -Arguments @($libraryPath, $path, $startTicks, $done, (Join-Path $directory "reader2.json"), "0")
    $w = Wait-Child -Child $writer -TimeoutSec 240
    Assert-True ((-not $w.TimedOut) -and $w.ExitCode -eq 0) "writer process failed (exit $($w.ExitCode), timeout $($w.TimedOut)): $($w.Error)"
    $r1 = Wait-Child -Child $readerOne -TimeoutSec 60
    $r2 = Wait-Child -Child $readerTwo -TimeoutSec 60
    Assert-True ((-not $r1.TimedOut) -and $r1.ExitCode -eq 0) "reader 1 failed (exit $($r1.ExitCode)): $($r1.Error)"
    Assert-True ((-not $r2.TimedOut) -and $r2.ExitCode -eq 0) "reader 2 failed (exit $($r2.ExitCode)): $($r2.Error)"

    $writerResult = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Join-Path $directory "writer.json")))
    Assert-Equal 200 $writerResult.writes "writes"
    Assert-Equal 0 $writerResult.failures "writer failures ($($writerResult.firstError))"
    foreach ($name in @("reader1", "reader2")) {
        $result = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Join-Path $directory "$name.json")))
        Assert-Equal 0 $result.bad "$name unreadable, partial or invalid reads ($($result.firstError))"
        Assert-Equal 0 $result.exhausted "$name reads that ran out of retries"
        Assert-True ($result.reads -ge 10) "$name made only $($result.reads) reads"
        Assert-True ($result.distinct -ge 2) "$name saw only $($result.distinct) distinct iteration(s): the reads did not overlap the writes"
        Write-Host ("       {0}: {1} reads, {2} distinct iterations" -f $name, $result.reads, $result.distinct)
    }
    Assert-Equal "iteration-200" (Read-HarnessManifest -Path $path).warnings[0] "the final manifest"
    $leftovers = @(Get-ChildItem -LiteralPath $directory -Force | Where-Object { $_.Name -like "*.tmp" })
    Assert-Equal 0 $leftovers.Count "temp files left behind"
}

Test-Case "AC-308: a manifest built from a 200 KB task file is written in under 5 s (.NET strings)" {
    $directory = New-CaseDirectory
    $taskPath = Join-Path $directory "task.md"
    $builder = New-Object System.Text.StringBuilder
    for ($n = 0; $n -lt 3000; $n++) { [void]$builder.Append("line $n of the task text, long enough to make a large file........`r`n") }
    [System.IO.File]::WriteAllText($taskPath, $builder.ToString(), $utf8NoBom)
    Assert-True ((Get-Item -LiteralPath $taskPath).Length -ge 200000) "the task file is smaller than 200 KB"

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $text = Read-HarnessTextFile -Path $taskPath
    $m = New-RunningManifest
    $m.request.name = "task"
    $m.request.taskSha256 = Get-HarnessFileSha256 -Path $taskPath
    $m.request.taskFile = "inputs\task.md"
    $m.warnings = @($text)
    $path = Join-Path $directory "manifest.json"
    Write-HarnessManifest -Path $path -Manifest $m
    $elapsed = $watch.ElapsedMilliseconds
    Assert-True ($elapsed -lt 5000) "writing a manifest with a 200 KB .NET string took $elapsed ms"
    Assert-Equal (Get-HarnessTextSha256 -Text $text) $m.request.taskSha256 "text hash equals file hash (UTF-8, no BOM)"
    Assert-Equal $text.Length (Read-HarnessManifest -Path $path).warnings[0].Length "the 200 KB string survives the round trip"
    Write-Host "       200 KB manifest written in $elapsed ms"
}

Test-Case "AC-308: a Get-Content string hangs a bare ConvertTo-Json (the hazard) and the writer guards against it" {
    $directory = New-CaseDirectory
    $taskPath = Join-Path $directory "task.md"
    $builder = New-Object System.Text.StringBuilder
    for ($n = 0; $n -lt 3000; $n++) { [void]$builder.Append("line $n of the task text, long enough to make a large file........`r`n") }
    [System.IO.File]::WriteAllText($taskPath, $builder.ToString(), $utf8NoBom)

    $naive = @'
param($TaskPath)
$text = Get-Content -LiteralPath $TaskPath -Raw -Encoding UTF8
$json = ConvertTo-Json -InputObject ([ordered]@{ t = $text }) -Depth 10
'@
    $child = Start-ChildScript -Directory $directory -Name "naive.ps1" -Text $naive -Arguments @($taskPath)
    $naiveResult = Wait-Child -Child $child -TimeoutSec 3
    Assert-True $naiveResult.TimedOut "a bare ConvertTo-Json of a 200 KB Get-Content string finished in 3 s: the hazard FR-305 names did not show"

    $guarded = @'
param($LibPath, $TaskPath, $OutPath)
$ErrorActionPreference = "Stop"
. $LibPath
$text = Get-Content -LiteralPath $TaskPath -Raw -Encoding UTF8
$watch = [System.Diagnostics.Stopwatch]::StartNew()
Write-HarnessManifest -Path $OutPath -Manifest ([ordered]@{ t = $text; list = @($text.Substring(0, 10)) })
Write-Output ("elapsed " + $watch.ElapsedMilliseconds)
'@
    $outPath = Join-Path $directory "guarded.json"
    $child = Start-ChildScript -Directory $directory -Name "guarded.ps1" -Text $guarded -Arguments @($libraryPath, $taskPath, $outPath)
    $guardedResult = Wait-Child -Child $child -TimeoutSec 60
    Assert-True ((-not $guardedResult.TimedOut) -and $guardedResult.ExitCode -eq 0) "the writer did not cope with a Get-Content string: $($guardedResult.Error)"
    Assert-True ($guardedResult.Output -match "elapsed (\d+)") "no timing line: $($guardedResult.Output)"
    Assert-True ([int]$Matches[1] -lt 5000) "the guarded write took $($Matches[1]) ms"
}

Test-Case "FR-305: helpers return plain strings, lowercase hex and fixed-format timestamps" {
    $directory = New-CaseDirectory
    $file = Join-Path $directory "t.txt"
    [System.IO.File]::WriteAllBytes($file, ([byte[]](0xEF, 0xBB, 0xBF) + $utf8NoBom.GetBytes("abc")))
    Assert-Equal "abc" (Read-HarnessTextFile -Path $file) "BOM dropped"
    Assert-Equal "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" (Get-HarnessTextSha256 -Text "abc") "SHA-256 of abc"
    $emptyFile = Join-Path $directory "empty.txt"
    [System.IO.File]::WriteAllBytes($emptyFile, (New-Object byte[] 0))
    Assert-Equal (Get-HarnessTextSha256 -Text "") (Get-HarnessFileSha256 -Path $emptyFile) "empty file and empty text"
    $hashFromFile = Get-HarnessFileSha256 -Path $file
    Assert-Equal ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()) $hashFromFile "file hash equals Get-FileHash"
    Assert-Equal "2026-11-26T10:00:00.123Z" (Get-HarnessUtcTimestamp -At ([datetime]::SpecifyKind([datetime]"2026-11-26T10:00:00.123", [System.DateTimeKind]::Utc))) "timestamp"
    Assert-True ((Get-HarnessUtcTimestamp) -cmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\z') "current timestamp shape"
}

# ---------------------------------------------------------------------------
# FR-309: derived status
# ---------------------------------------------------------------------------

function New-StatusManifest {
    param([string]$Status, $ProcessId, $StartText)
    $m = New-RunningManifest
    $m.status = $Status
    $m.process.pid = $ProcessId
    $m.process.processStartUtc = $StartText
    return $m
}

Test-Case "FR-309: a recorded running is running for a live pid with the recorded start time" {
    $self = [System.Diagnostics.Process]::GetCurrentProcess()
    $startText = Get-HarnessUtcTimestamp -At $self.StartTime
    $status = Get-HarnessRunStatus -Manifest (New-StatusManifest -Status "running" -ProcessId $self.Id -StartText $startText)
    Assert-Equal "running" $status.status "derived status"
    Assert-Equal "running" $status.recordedStatus "recorded status"
    Assert-True (-not $status.livenessUnverified) "liveness_unverified without a reason"
    $fromJson = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject (New-StatusManifest -Status "running" -ProcessId $self.Id -StartText $startText) -Depth 10)
    Assert-Equal "running" (Get-HarnessRunStatus -Manifest $fromJson).status "derived status of a parsed manifest"
}

Test-Case "FR-309: the start time may differ by 2 s, not more" {
    $self = [System.Diagnostics.Process]::GetCurrentProcess()
    foreach ($case in @(@{ Offset = 1.5; Expect = "running" }, @{ Offset = -1.5; Expect = "running" }, @{ Offset = 2.6; Expect = "abandoned" }, @{ Offset = -2.6; Expect = "abandoned" }, @{ Offset = 3600; Expect = "abandoned" })) {
        $startText = Get-HarnessUtcTimestamp -At $self.StartTime.AddSeconds($case.Offset)
        $status = Get-HarnessRunStatus -Manifest (New-StatusManifest -Status "running" -ProcessId $self.Id -StartText $startText)
        Assert-Equal $case.Expect $status.status "derived status for an offset of $($case.Offset) s"
    }
}

Test-Case "FR-309: a recorded running whose process is gone is abandoned; a live child is running until it is killed" {
    $child = Start-Process -FilePath (Join-Path $env:SystemRoot "System32\ping.exe") -ArgumentList "-n", "60", "127.0.0.1" -WindowStyle Hidden -PassThru
    try {
        $startText = Get-HarnessUtcTimestamp -At $child.StartTime
        $manifest = New-StatusManifest -Status "running" -ProcessId $child.Id -StartText $startText
        Assert-Equal "running" (Get-HarnessRunStatus -Manifest $manifest).status "live child"
        $child.Kill()
        [void]$child.WaitForExit(10000)
        $status = Get-HarnessRunStatus -Manifest $manifest
        Assert-Equal "abandoned" $status.status "killed child"
        Assert-Equal "running" $status.recordedStatus "recorded status stays"
    }
    finally { if (-not $child.HasExited) { $child.Kill() } ; $child.Dispose() }
    Assert-Equal "abandoned" (Get-HarnessRunStatus -Manifest (New-StatusManifest -Status "running" -ProcessId 0 -StartText $null)).status "pid 0"
    Assert-Equal "abandoned" (Get-HarnessRunStatus -Manifest (New-StatusManifest -Status "running" -ProcessId 2147483000 -StartText "2026-11-26T10:00:00.000Z")).status "a pid that cannot exist"
}

Test-Case "FR-309: every other recorded status is the derived status, even with a dead pid" {
    foreach ($recorded in @("queued", "succeeded", "failed", "needs_input", "cancelled", "abandoned")) {
        $status = Get-HarnessRunStatus -Manifest (New-StatusManifest -Status $recorded -ProcessId 2147483000 -StartText "2026-01-01T00:00:00.000Z")
        Assert-Equal $recorded $status.status "derived status of a recorded $recorded run"
        Assert-True (-not $status.livenessUnverified) "liveness flag for $recorded"
    }
}

Test-Case "FR-309: an unreadable start time keeps the run running with livenessUnverified; a missing pid still abandons" {
    $self = [System.Diagnostics.Process]::GetCurrentProcess()
    $manifest = New-StatusManifest -Status "running" -ProcessId $self.Id -StartText "2026-11-26T10:00:00.000Z"
    & {
        function Get-HarnessProcessInfo { param([int]$ProcessId) return [pscustomobject]@{ Exists = $true; StartUtc = $null } }
        $status = Get-HarnessRunStatus -Manifest $manifest
        Assert-Equal "running" $status.status "derived status with an unreadable start time"
        Assert-True $status.livenessUnverified "livenessUnverified"
    }
    & {
        function Get-HarnessProcessInfo { param([int]$ProcessId) return [pscustomobject]@{ Exists = $false; StartUtc = $null } }
        Assert-Equal "abandoned" (Get-HarnessRunStatus -Manifest $manifest).status "derived status of a missing pid"
    }
    $noStart = New-StatusManifest -Status "running" -ProcessId $self.Id -StartText $null
    $status = Get-HarnessRunStatus -Manifest $noStart
    Assert-Equal "running" $status.status "a manifest without processStartUtc and a live pid"
    Assert-True $status.livenessUnverified "livenessUnverified without processStartUtc"
}

# ---------------------------------------------------------------------------
# Cleanup and summary
# ---------------------------------------------------------------------------

$env:AI_HARNESS_RUN_ID = $originalRunIdVariable
try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop }
catch { Write-Host "Could not remove the temporary folder $tempRoot : $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "              TEST SUMMARY" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Passed: $script:passed"
Write-Host "Failed: $script:failed"
Write-Host ""

if ($script:failed -eq 0 -and $script:passed -gt 0) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "STATUS: FAIL" -ForegroundColor Red
exit 1
