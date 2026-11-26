# Shared specify workflow and stage contract (Phase 3 B2; FR-303, FR-308, D-311).
#
# Dot-sourcing this file defines functions only: no variable, no output, no
# I/O. Windows PowerShell 5.1. Used by the legacy front end scripts\specify.ps1
# and, from B4, by lib\cli.ps1 (harness specify, review, revise, scan, context).
#
# STAGE CONTRACT (FR-303)
#   - A stage script is called as a statement (& $Script @Arguments) inside
#     Invoke-HarnessStage; its success-stream output passes through to the
#     caller. Results never travel in the pipeline: they are written into
#     hashtables the caller passes (-State, -Result).
#   - $global:LASTEXITCODE is set to $null before each stage. After the stage,
#     $null counts as 0 (RN-8), except for the reviewer, where $null is an
#     unexpected exit code (Get-HarnessStageExitCode -NullIsUnexpected).
#   - A stage that throws is a failed stage: stage_end gets exit code $null,
#     the workflow stops, and the caught ErrorRecord is returned in
#     -Result.error. The legacy front end rethrows it, so its trap prints and
#     exits 2 as before.
#   - Stages without exit codes (scan-repository.ps1, build-context.ps1) use
#     Invoke-HarnessFileStage: success is "no throw, and the output file exists
#     and is not empty"; the exit code is reported as $null.
#   - The hook is a script block called as
#       & $Hook -EventName <stage_begin|stage_end> -Data <hashtable>
#     stage_begin Data: id, kind, agent, attempt
#     stage_end   Data: id, status, exitCode, outputPath, verdict, reason
#     Its output is discarded; a hook that throws is internal_error and stops
#     the workflow (-Result.errorSource 'hook').
#
# -Result OF Invoke-SpecifyWorkflow (every key is always set)
#   outcome         'passed', 'failed' or 'needs_input'
#   category        $null on success, else an FR-308 category
#   stage           id of the stage that decided the outcome, or $null
#   legacyExitCode  exit code of specify.ps1 (0, 1, 2, 3)
#   cliExitCode     exit code of harness specify (0, 1, 2, 3)
#   message         fixed wording for the CLI ERROR line, or $null
#   error           the ErrorRecord of a throw (stage, hook, workflow), or $null
#   errorSource     'stage', 'hook', 'workflow' or $null
#   specFile        last specification path the workflow worked on, or $null
#   reviewFile      last review path, or $null
#   revisions       number of revisions started (0 to 3)
#
# Stage ids (FR-305): spec-generate, spec-validate, spec-review, spec-revise,
# revised-validate. attempt is 1, except the round k (spec-review) and the
# revision k (spec-revise, revised-validate).

# A failed or decided outcome: fills every key of -Result.
function Set-HarnessWorkflowResult {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Result,
        [Parameter(Mandatory = $true)][string]$Outcome,
        $Category = $null,
        $Stage = $null,
        [Parameter(Mandatory = $true)][int]$LegacyExitCode,
        [Parameter(Mandatory = $true)][int]$CliExitCode,
        $Message = $null,
        $ErrorRecord = $null,
        $ErrorSource = $null
    )

    $Result.outcome = $Outcome
    $Result.category = $Category
    $Result.stage = $Stage
    $Result.legacyExitCode = $LegacyExitCode
    $Result.cliExitCode = $CliExitCode
    $Result.message = $Message
    $Result.error = $ErrorRecord
    $Result.errorSource = $ErrorSource
}

# An ErrorRecord for a refusal the workflow raises itself (no throw needed).
function New-HarnessWorkflowErrorRecord {
    param([Parameter(Mandatory = $true)][string]$Message)

    $exception = New-Object System.Management.Automation.RuntimeException -ArgumentList $Message
    return New-Object System.Management.Automation.ErrorRecord -ArgumentList $exception, "HarnessWorkflow", ([System.Management.Automation.ErrorCategory]::InvalidArgument), $null
}

# RN-8: an exit code of $null counts as 0, except where -NullIsUnexpected is
# given (the reviewer), where it stays $null and is an unexpected code.
function Get-HarnessStageExitCode {
    param(
        $ExitCode,
        [switch]$NullIsUnexpected
    )

    if ($null -eq $ExitCode -and -not $NullIsUnexpected) { return 0 }
    return $ExitCode
}

# True when the path is an existing file with at least one byte.
function Test-HarnessStageOutput {
    param($Path)

    if ([string]::IsNullOrEmpty([string]$Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return ((Get-Item -LiteralPath $Path).Length -gt 0)
}

# Calls the hook, if any. A throw sets State.hookFailed and State.hookError.
function Invoke-HarnessStageHook {
    param(
        $Hook,
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)][hashtable]$Data,
        [Parameter(Mandatory = $true)][hashtable]$State
    )

    if ($null -eq $Hook) { return }
    try {
        $null = & $Hook -EventName $EventName -Data $Data
    }
    catch {
        $State.hookFailed = $true
        $State.hookError = $_
        $State.hookEvent = $EventName
    }
}

# Runs one stage under the contract: stage_begin, $global:LASTEXITCODE reset,
# the call as a statement (its success output passes through), the throw
# caught. Fills -State: id, kind, agent, attempt, threw, stageError, exitCode
# (raw $global:LASTEXITCODE, $null after a throw), hookFailed, hookError,
# hookEvent. The caller decides the status and calls Complete-HarnessStage.
function Invoke-HarnessStage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Kind,
        $Agent = $null,
        [int]$Attempt = 1,
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][hashtable]$Arguments,
        $Hook = $null,
        [Parameter(Mandatory = $true)][hashtable]$State
    )

    $State.id = $Id
    $State.kind = $Kind
    $State.agent = $Agent
    $State.attempt = $Attempt
    $State.threw = $false
    $State.stageError = $null
    $State.exitCode = $null
    $State.hookFailed = $false
    $State.hookError = $null
    $State.hookEvent = $null

    Invoke-HarnessStageHook -Hook $Hook -EventName "stage_begin" -State $State `
        -Data @{ id = $Id; kind = $Kind; agent = $Agent; attempt = $Attempt }
    if ($State.hookFailed) { return }

    $global:LASTEXITCODE = $null
    try {
        & $Script @Arguments
        $State.exitCode = $global:LASTEXITCODE
    }
    catch {
        $State.threw = $true
        $State.stageError = $_
        $State.exitCode = $null
    }
}

# Sends stage_end and records the decision in -State: status ('succeeded' or
# 'failed'), outputPath, verdict ('PASS', 'FAIL' or $null), reason.
function Complete-HarnessStage {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Status,
        $OutputPath = $null,
        $Verdict = $null,
        $Reason = $null,
        $Hook = $null
    )

    $State.status = $Status
    $State.outputPath = $OutputPath
    $State.verdict = $Verdict
    $State.reason = $Reason
    $exitCode = if ($State.threw) { $null } else { $State.exitCode }

    Invoke-HarnessStageHook -Hook $Hook -EventName "stage_end" -State $State -Data @{
        id         = $State.id
        status     = $Status
        exitCode   = $exitCode
        outputPath = $OutputPath
        verdict    = $Verdict
        reason     = $Reason
    }
}

# A stage without an exit code (scan-repository.ps1, build-context.ps1):
# success is no throw and a non-empty -OutputPath; the exit code, stale or
# not, is ignored and reported as $null. Fills -State like Invoke-HarnessStage
# plus status, reason, outputPath and, on failure, category 'stage_failed' and
# message. The caller checks State.hookFailed (internal_error).
function Invoke-HarnessFileStage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][hashtable]$Arguments,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        $Hook = $null,
        [Parameter(Mandatory = $true)][hashtable]$State
    )

    $State.category = $null
    $State.message = $null
    Invoke-HarnessStage -Id $Id -Kind "deterministic" -Script $Script -Arguments $Arguments -Hook $Hook -State $State
    if ($State.hookFailed) { return }
    $State.exitCode = $null

    if ($State.threw) {
        $State.category = "stage_failed"
        $State.message = "Stage '$Id' failed: it threw an exception (exit code null)."
        Complete-HarnessStage -State $State -Status "failed" -OutputPath $OutputPath -Reason $State.message -Hook $Hook
        return
    }
    if (-not (Test-HarnessStageOutput $OutputPath)) {
        $State.category = "stage_failed"
        $State.message = "Stage '$Id' failed: output file missing or empty (exit code null)."
        Complete-HarnessStage -State $State -Status "failed" -OutputPath $OutputPath -Reason $State.message -Hook $Hook
        return
    }
    Complete-HarnessStage -State $State -Status "succeeded" -OutputPath $OutputPath -Hook $Hook
}

# Ends the workflow after a stage that threw or a hook that threw. Returns
# $true when it did (the caller returns), $false otherwise.
function Test-HarnessStageAborted {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][hashtable]$Result,
        $OutputPath = $null,
        $Hook = $null
    )

    if (-not $State.hookFailed -and $State.threw) {
        $message = "Stage '$($State.id)' failed: it threw an exception (exit code null)."
        Complete-HarnessStage -State $State -Status "failed" -OutputPath $OutputPath -Reason $message -Hook $Hook
        if (-not $State.hookFailed) {
            Set-HarnessWorkflowResult -Result $Result -Outcome "failed" -Category "stage_failed" -Stage $State.id `
                -LegacyExitCode 2 -CliExitCode 2 -Message $message -ErrorRecord $State.stageError -ErrorSource "stage"
            return $true
        }
    }
    if ($State.hookFailed) {
        Set-HarnessWorkflowResult -Result $Result -Outcome "failed" -Category "internal_error" -Stage $State.id `
            -LegacyExitCode 2 -CliExitCode 2 -Message "The stage hook failed at $($State.hookEvent) of stage '$($State.id)'." `
            -ErrorRecord $State.hookError -ErrorSource "hook"
        return $true
    }
    return $false
}

# Records a stage_end and fills -Result for a failure decided from an exit
# code or a missing output. Returns nothing; the caller returns after it.
function Stop-HarnessWorkflowStage {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][hashtable]$Result,
        [Parameter(Mandatory = $true)][string]$Outcome,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][int]$LegacyExitCode,
        [Parameter(Mandatory = $true)][int]$CliExitCode,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Status = "failed",
        $OutputPath = $null,
        $Verdict = $null,
        $Hook = $null
    )

    Complete-HarnessStage -State $State -Status $Status -OutputPath $OutputPath -Verdict $Verdict -Reason $Message -Hook $Hook
    if ($State.hookFailed) {
        $null = Test-HarnessStageAborted -State $State -Result $Result
        return
    }
    Set-HarnessWorkflowResult -Result $Result -Outcome $Outcome -Category $Category -Stage $State.id `
        -LegacyExitCode $LegacyExitCode -CliExitCode $CliExitCode -Message $Message
}

function Format-HarnessExitCode {
    param($ExitCode)
    if ($null -eq $ExitCode) { return "null" }
    return [string]$ExitCode
}

# The specify workflow (FR-303): generate, validate, then up to 1 + 3 review
# rounds with a revision and a validation between them. Prints the console
# lines specify.ps1 printed at phase2-calibrated, never calls exit, and fills
# -Result (see the header). -Model and -Profile are passed to the three agent
# stages only when bound, -ContextFile likewise (reviewer and reviser accept it
# from B7); -Model with -Profile is refused before any stage.
function Invoke-SpecifyWorkflow {
    param(
        [Parameter(Mandatory = $true)][string]$RunnerScript,
        [Parameter(Mandatory = $true)][string]$ValidatorScript,
        [Parameter(Mandatory = $true)][string]$ReviewerScript,
        [Parameter(Mandatory = $true)][string]$ReviserScript,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Task,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [string]$Model,
        [string]$Profile,
        [string]$ContextFile,
        [scriptblock]$Hook,
        [Parameter(Mandatory = $true)][hashtable]$Result
    )

    $ErrorActionPreference = "Stop"

    Set-HarnessWorkflowResult -Result $Result -Outcome "failed" -Category "internal_error" `
        -LegacyExitCode 2 -CliExitCode 2 -Message "The workflow did not finish."
    $Result.specFile = $null
    $Result.reviewFile = $null
    $Result.revisions = 0

    try {
        if ($PSBoundParameters.ContainsKey("Model") -and $PSBoundParameters.ContainsKey("Profile")) {
            $message = "-Model and -Profile cannot be used together."
            Set-HarnessWorkflowResult -Result $Result -Outcome "failed" -Category "invalid_arguments" `
                -LegacyExitCode 2 -CliExitCode 2 -Message $message `
                -ErrorRecord (New-HarnessWorkflowErrorRecord $message) -ErrorSource "workflow"
            return
        }
        # Case-insensitive, like the ValidateSet of specify.ps1; the CLI parser is exact (FR-302).
        if (@("requirements", "baseline", "documentation") -notcontains $Mode) {
            $message = "Invalid mode: $Mode"
            Set-HarnessWorkflowResult -Result $Result -Outcome "failed" -Category "invalid_arguments" `
                -LegacyExitCode 2 -CliExitCode 2 -Message $message `
                -ErrorRecord (New-HarnessWorkflowErrorRecord $message) -ErrorSource "workflow"
            return
        }
        if ($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') {
            $message = "Invalid specification name: $Name"
            Set-HarnessWorkflowResult -Result $Result -Outcome "failed" -Category "invalid_arguments" `
                -LegacyExitCode 2 -CliExitCode 2 -Message $message `
                -ErrorRecord (New-HarnessWorkflowErrorRecord $message) -ErrorSource "workflow"
            return
        }

        $specDirectory = $OutputDirectory
        $specFile = Join-Path $specDirectory "$Name.md"
        $reviewFile = Join-Path $specDirectory "$Name.review.md"
        $runner = $RunnerScript
        $validator = $ValidatorScript
        $reviewer = $ReviewerScript
        $reviser = $ReviserScript
        $maxRevisions = 3

        $modelArgs = @{}
        if ($PSBoundParameters.ContainsKey("Model")) {
            $modelArgs.Model = $Model
        }
        if ($PSBoundParameters.ContainsKey("Profile")) {
            $modelArgs.Profile = $Profile
        }
        if ($PSBoundParameters.ContainsKey("ContextFile")) {
            $modelArgs.ContextFile = $ContextFile
        }
        $modelLabel = if ($PSBoundParameters.ContainsKey("Model")) { $Model } else { "(resolved per agent from config)" }

        if (-not (Test-Path $runner)) {
            throw "Agent runner not found: $runner"
        }

        if (-not (Test-Path $validator)) {
            throw "Specification validator not found: $validator"
        }

        if (-not (Test-Path $reviewer)) {
            throw "Specification reviewer not found: $reviewer"
        }

        if (-not (Test-Path $reviser)) {
            throw "Specification reviser not found: $reviser"
        }

        if (-not (Test-Path $specDirectory)) {
            New-Item -ItemType Directory -Path $specDirectory -Force | Out-Null
        }

        # Pass -Mode only to a validator that declares it (FR-008). Get-Command only
        # parses the script. If the check fails, the validator is called as before
        # (FR-019) and the run continues; any later failure happens as it does today.
        $validatorArgs = @{}
        $validatorModeCheck = "declared"
        $validatorModeReason = ""
        try {
            $validatorParameters = (Get-Command -Name $validator -CommandType ExternalScript -ErrorAction Stop).Parameters
            if ($null -eq $validatorParameters) {
                $validatorModeCheck = "not confirmed"
                $validatorModeReason = "no parameter metadata"
            }
            elseif ($validatorParameters.ContainsKey("Mode")) {
                $validatorArgs.Mode = $Mode
            }
            else {
                $validatorModeCheck = "not declared"
            }
        }
        catch {
            $validatorModeCheck = "not confirmed"
            $validatorModeReason = $_.Exception.GetType().Name
        }

        $validationSummary = "PASS"
        if ($Mode -eq "documentation" -and $validatorModeCheck -ne "declared") {
            $validationSummary = "PASS (validator called without -Mode; documentation-mode rules NOT applied)"
        }

        Write-Host ""
        Write-Host "=== Specification Workflow ===" -ForegroundColor Cyan
        Write-Host "Name  : $Name"
        Write-Host "Model : $modelLabel"
        Write-Host "Mode  : $Mode"

        $workflowTask = @"
SPECIFICATION MODE (AUTHORITATIVE):
$Mode

ORIGINAL USER REQUEST:
$Task
"@
        Write-Host ""

        if ($Mode -eq "documentation" -and $validatorModeCheck -eq "not declared") {
            Write-Host "WARNING: Validator '$validator' does not declare a -Mode parameter. It is called without -Mode, so documentation-mode validation rules are NOT applied; the validator's own default rules are used instead." -ForegroundColor Yellow
            Write-Host ""
        }
        elseif ($Mode -eq "documentation" -and $validatorModeCheck -eq "not confirmed") {
            Write-Host "WARNING: Could not read the parameters of validator '$validator' ($validatorModeReason), so support for -Mode could not be confirmed. It is called without -Mode, so documentation-mode validation rules are NOT applied; the validator's own default rules are used instead." -ForegroundColor Yellow
            Write-Host ""
        }

        # ------------------------------------------------------------
        # Step 1 - Generate specification
        # ------------------------------------------------------------

        Write-Host "Step 1 - Generating specification..." -ForegroundColor Yellow
        Write-Host ""

        $Result.specFile = $specFile
        Remove-Item $specFile -Force -ErrorAction SilentlyContinue
        $state = @{}
        $runnerArgs = @{ Agent = "spec"; Task = $workflowTask }
        foreach ($key in $modelArgs.Keys) { $runnerArgs[$key] = $modelArgs[$key] }
        $runnerArgs.OutputFile = $specFile
        Invoke-HarnessStage -Id "spec-generate" -Kind "agent" -Agent "spec" -Attempt 1 `
            -Script $runner -Arguments $runnerArgs -Hook $Hook -State $state
        if (Test-HarnessStageAborted -State $state -Result $Result -OutputPath $specFile -Hook $Hook) { return }

        $runnerExitCode = Get-HarnessStageExitCode $state.exitCode
        if ($runnerExitCode -ne 0) {
            Write-Host ""
            Write-Host "=== Specification Workflow Failed ===" -ForegroundColor Red
            Write-Host "Specification agent failed." -ForegroundColor Red
            Stop-HarnessWorkflowStage -State $state -Result $Result -Outcome "failed" -Category "stage_failed" `
                -LegacyExitCode 2 -CliExitCode 2 -OutputPath $specFile -Hook $Hook `
                -Message "Stage 'spec-generate' failed with exit code $(Format-HarnessExitCode $runnerExitCode)."
            return
        }


        if (
            -not (Test-Path $specFile -PathType Leaf) -or
            (Get-Item $specFile).Length -eq 0
        ) {
            Write-Host ""
            Write-Host "=== Specification Workflow Failed ===" -ForegroundColor Red
            Write-Host "Specification file is missing or empty: $specFile" -ForegroundColor Red
            Stop-HarnessWorkflowStage -State $state -Result $Result -Outcome "failed" -Category "stage_failed" `
                -LegacyExitCode 2 -CliExitCode 2 -OutputPath $specFile -Hook $Hook `
                -Message "Stage 'spec-generate' failed: exit code 0, output file missing or empty."
            return
        }
        Complete-HarnessStage -State $state -Status "succeeded" -OutputPath $specFile -Hook $Hook
        if (Test-HarnessStageAborted -State $state -Result $Result) { return }


        # ------------------------------------------------------------
        # Step 2 - Initial structural validation
        # ------------------------------------------------------------

        Write-Host ""
        Write-Host "Step 2 - Validating specification structure..." -ForegroundColor Yellow
        Write-Host ""

        $state = @{}
        $stageArgs = @{ SpecFile = $specFile }
        foreach ($key in $validatorArgs.Keys) { $stageArgs[$key] = $validatorArgs[$key] }
        Invoke-HarnessStage -Id "spec-validate" -Kind "deterministic" -Attempt 1 `
            -Script $validator -Arguments $stageArgs -Hook $Hook -State $state
        if (Test-HarnessStageAborted -State $state -Result $Result -Hook $Hook) { return }
        $validatorExitCode = Get-HarnessStageExitCode $state.exitCode

        if ($validatorExitCode -eq 3) {
            Write-Host ""
            Write-Host "=== Specification Needs Human Input ===" -ForegroundColor Yellow
            Write-Host "The task does not contain enough information to specify."
            Write-Host "See Open Questions in: $specFile"
            Stop-HarnessWorkflowStage -State $state -Result $Result -Outcome "needs_input" -Category "needs_human_input" `
                -LegacyExitCode 3 -CliExitCode 3 -Hook $Hook `
                -Message "Stage 'spec-validate' needs human input (exit code 3): see Open Questions in the specification."
            return
        }

        if ($validatorExitCode -ne 0) {
            Write-Host ""
            Write-Host "=== Specification Workflow Failed ===" -ForegroundColor Red
            Write-Host "Generated specification failed structural validation." -ForegroundColor Red
            Write-Host "File: $specFile"
            if ($validatorExitCode -eq 1) {
                Stop-HarnessWorkflowStage -State $state -Result $Result -Outcome "failed" -Category "validation_failed" `
                    -LegacyExitCode 2 -CliExitCode 1 -Hook $Hook `
                    -Message "Stage 'spec-validate' failed structural validation (exit code 1)."
            }
            else {
                Stop-HarnessWorkflowStage -State $state -Result $Result -Outcome "failed" -Category "stage_failed" `
                    -LegacyExitCode 2 -CliExitCode 2 -Hook $Hook `
                    -Message "Stage 'spec-validate' failed with exit code $(Format-HarnessExitCode $validatorExitCode)."
            }
            return
        }
        Complete-HarnessStage -State $state -Status "succeeded" -Hook $Hook
        if (Test-HarnessStageAborted -State $state -Result $Result) { return }

        # ------------------------------------------------------------
        # Step 3+ - Review / revision loop
        # ------------------------------------------------------------

        $currentSpecFile = $specFile

        for ($revision = 0; $revision -le $maxRevisions; $revision++) {

            $reviewIteration = $revision + 1

            if ($revision -eq 0) {
                $currentReviewFile = $reviewFile
            }
            else {
                $currentReviewFile = Join-Path `
                    $specDirectory `
                    "$Name.revised-v$revision.review.md"
            }

            Write-Host ""
            Write-Host "Review iteration $reviewIteration" -ForegroundColor Cyan
            Write-Host "Specification: $currentSpecFile"
            Write-Host ""

            # --------------------------------------------------------
            # Semantic review
            # --------------------------------------------------------

            Write-Host "Reviewing specification semantics..." -ForegroundColor Yellow
            Write-Host ""

            Remove-Item $currentReviewFile -Force -ErrorAction SilentlyContinue
            $Result.reviewFile = $currentReviewFile

            $state = @{}
            $stageArgs = @{ Mode = $Mode; Task = $Task; SpecFile = $currentSpecFile }
            foreach ($key in $modelArgs.Keys) { $stageArgs[$key] = $modelArgs[$key] }
            $stageArgs.OutputFile = $currentReviewFile
            Invoke-HarnessStage -Id "spec-review" -Kind "agent" -Agent "spec-reviewer" -Attempt $reviewIteration `
                -Script $reviewer -Arguments $stageArgs -Hook $Hook -State $state
            if (Test-HarnessStageAborted -State $state -Result $Result -OutputPath $currentReviewFile -Hook $Hook) { return }

            # RN-8 exception: a reviewer that sets no exit code is unexpected.
            $reviewExitCode = Get-HarnessStageExitCode $state.exitCode -NullIsUnexpected

            # Validate reviewer exit code contract.

            if ($reviewExitCode -notin @(0, 1, 2)) {
                Write-Host ""
                Write-Host "=== Specification Workflow Failed ===" -ForegroundColor Red
                Write-Host "Unexpected reviewer exit code: $reviewExitCode" -ForegroundColor Red
                Stop-HarnessWorkflowStage -State $state -Result $Result -Outcome "failed" -Category "stage_failed" `
                    -LegacyExitCode 2 -CliExitCode 2 -OutputPath $currentReviewFile -Hook $Hook `
                    -Message "Stage 'spec-review' failed with exit code $(Format-HarnessExitCode $reviewExitCode)."
                return
            }

            # Exit code 2 is an execution error and is handled below.
            # PASS/FAIL results must have a non-empty review artifact.

            if ($reviewExitCode -ne 2) {
                if (
                    -not (Test-Path $currentReviewFile -PathType Leaf) -or
                    (Get-Item $currentReviewFile).Length -eq 0
                ) {
                    Write-Host ""
                    Write-Host "=== Specification Workflow Failed ===" -ForegroundColor Red
                    Write-Host "Reviewer report is missing or empty: $currentReviewFile" -ForegroundColor Red
                    Stop-HarnessWorkflowStage -State $state -Result $Result -Outcome "failed" -Category "stage_failed" `
                        -LegacyExitCode 2 -CliExitCode 2 -OutputPath $currentReviewFile -Hook $Hook `
                        -Message "Stage 'spec-review' failed: exit code $reviewExitCode, output file missing or empty."
                    return
                }
            }


            if ($reviewExitCode -eq 0) {

                Write-Host ""
                Write-Host "=== Specification Workflow Complete ===" -ForegroundColor Green
                Write-Host ""
                Write-Host "Specification: $currentSpecFile"
                Write-Host "Validation   : $validationSummary"
                Write-Host "Review       : PASS"
                Write-Host "Review File  : $currentReviewFile"
                Write-Host "Revisions    : $revision"
                Write-Host ""

                $Result.specFile = $currentSpecFile
                Complete-HarnessStage -State $state -Status "succeeded" -OutputPath $currentReviewFile -Verdict "PASS" -Hook $Hook
                if (Test-HarnessStageAborted -State $state -Result $Result) { return }
                Set-HarnessWorkflowResult -Result $Result -Outcome "passed" -Stage "spec-review" -LegacyExitCode 0 -CliExitCode 0
                return
            }

            if ($reviewExitCode -eq 2) {
                Write-Host ""
                Write-Host "=== Specification Workflow Failed ===" -ForegroundColor Red
                Write-Host "Specification reviewer encountered an execution error." -ForegroundColor Red
                Write-Host "Specification: $currentSpecFile"
                Write-Host "Review       : $currentReviewFile"
                Stop-HarnessWorkflowStage -State $state -Result $Result -Outcome "failed" -Category "stage_failed" `
                    -LegacyExitCode 2 -CliExitCode 2 -OutputPath $currentReviewFile -Hook $Hook `
                    -Message "Stage 'spec-review' failed with exit code 2."
                return
            }
            # --------------------------------------------------------
            # Reviewer failed
            # --------------------------------------------------------

            if ($revision -eq $maxRevisions) {
                Write-Host ""
                Write-Host "=== Specification Workflow Failed ===" -ForegroundColor Red
                Write-Host "Maximum revision attempts reached ($maxRevisions)." -ForegroundColor Red
                Write-Host ""
                Write-Host "Specification: $currentSpecFile"
                Write-Host "Review       : $currentReviewFile"
                Write-Host ""

                Stop-HarnessWorkflowStage -State $state -Result $Result -Outcome "failed" -Category "max_revisions_reached" `
                    -LegacyExitCode 1 -CliExitCode 1 -Status "succeeded" -OutputPath $currentReviewFile -Verdict "FAIL" -Hook $Hook `
                    -Message "Maximum revision attempts reached ($maxRevisions)."
                return
            }
            Complete-HarnessStage -State $state -Status "succeeded" -OutputPath $currentReviewFile -Verdict "FAIL" -Hook $Hook
            if (Test-HarnessStageAborted -State $state -Result $Result) { return }

            # --------------------------------------------------------
            # Revision
            # --------------------------------------------------------

            $nextRevision = $revision + 1

            $nextSpecFile = Join-Path `
                $specDirectory `
                "$Name.revised-v$nextRevision.md"

            Write-Host ""
            Write-Host "Semantic review failed." -ForegroundColor Red
            Write-Host "Starting revision $nextRevision/$maxRevisions..." -ForegroundColor Yellow
            Write-Host ""

            Remove-Item $nextSpecFile -Force -ErrorAction SilentlyContinue
            $Result.revisions = $nextRevision
            $state = @{}
            $stageArgs = @{ Mode = $Mode; Task = $Task; SpecFile = $currentSpecFile; ReviewFile = $currentReviewFile }
            foreach ($key in $modelArgs.Keys) { $stageArgs[$key] = $modelArgs[$key] }
            $stageArgs.OutputFile = $nextSpecFile
            Invoke-HarnessStage -Id "spec-revise" -Kind "agent" -Agent "spec-reviser" -Attempt $nextRevision `
                -Script $reviser -Arguments $stageArgs -Hook $Hook -State $state
            if (Test-HarnessStageAborted -State $state -Result $Result -OutputPath $nextSpecFile -Hook $Hook) { return }
            $reviserExitCode = Get-HarnessStageExitCode $state.exitCode

            if ($reviserExitCode -ne 0) {
                Write-Host ""
                Write-Host "=== Specification Workflow Failed ===" -ForegroundColor Red
                Write-Host "Specification reviser failed." -ForegroundColor Red
                Write-Host "Review: $currentReviewFile"
                Stop-HarnessWorkflowStage -State $state -Result $Result -Outcome "failed" -Category "stage_failed" `
                    -LegacyExitCode 2 -CliExitCode 2 -OutputPath $nextSpecFile -Hook $Hook `
                    -Message "Stage 'spec-revise' failed with exit code $(Format-HarnessExitCode $reviserExitCode)."
                return
            }

            if (
                -not (Test-Path $nextSpecFile -PathType Leaf) -or
                (Get-Item $nextSpecFile).Length -eq 0
            ) {
                Write-Host ""
                Write-Host "=== Specification Workflow Failed ===" -ForegroundColor Red
                Write-Host "Revised specification is missing or empty." -ForegroundColor Red
                Write-Host "Expected: $nextSpecFile"
                Stop-HarnessWorkflowStage -State $state -Result $Result -Outcome "failed" -Category "stage_failed" `
                    -LegacyExitCode 2 -CliExitCode 2 -OutputPath $nextSpecFile -Hook $Hook `
                    -Message "Stage 'spec-revise' failed: exit code 0, output file missing or empty."
                return
            }
            Complete-HarnessStage -State $state -Status "succeeded" -OutputPath $nextSpecFile -Hook $Hook
            if (Test-HarnessStageAborted -State $state -Result $Result) { return }
            $Result.specFile = $nextSpecFile

            # --------------------------------------------------------
            # Structural validation of revised specification
            # --------------------------------------------------------

            Write-Host ""
            Write-Host "Validating revised specification structure..." -ForegroundColor Yellow
            Write-Host ""

            $state = @{}
            $stageArgs = @{ SpecFile = $nextSpecFile }
            foreach ($key in $validatorArgs.Keys) { $stageArgs[$key] = $validatorArgs[$key] }
            Invoke-HarnessStage -Id "revised-validate" -Kind "deterministic" -Attempt $nextRevision `
                -Script $validator -Arguments $stageArgs -Hook $Hook -State $state
            if (Test-HarnessStageAborted -State $state -Result $Result -Hook $Hook) { return }
            $revisedExitCode = Get-HarnessStageExitCode $state.exitCode

            if ($revisedExitCode -ne 0) {
                Write-Host ""
                Write-Host "=== Specification Workflow Failed ===" -ForegroundColor Red
                Write-Host "Revised specification failed structural validation." -ForegroundColor Red
                Write-Host "File: $nextSpecFile"
                if ($revisedExitCode -eq 1 -or $revisedExitCode -eq 3) {
                    Stop-HarnessWorkflowStage -State $state -Result $Result -Outcome "failed" -Category "validation_failed" `
                        -LegacyExitCode 2 -CliExitCode 1 -Hook $Hook `
                        -Message "Stage 'revised-validate' failed structural validation (exit code $revisedExitCode)."
                }
                else {
                    Stop-HarnessWorkflowStage -State $state -Result $Result -Outcome "failed" -Category "stage_failed" `
                        -LegacyExitCode 2 -CliExitCode 2 -Hook $Hook `
                        -Message "Stage 'revised-validate' failed with exit code $(Format-HarnessExitCode $revisedExitCode)."
                }
                return
            }
            Complete-HarnessStage -State $state -Status "succeeded" -Hook $Hook
            if (Test-HarnessStageAborted -State $state -Result $Result) { return }

            $currentSpecFile = $nextSpecFile
        }

        # Not reachable: the last round always ends above (legacy "exit 1").
        Set-HarnessWorkflowResult -Result $Result -Outcome "failed" -Category "max_revisions_reached" `
            -LegacyExitCode 1 -CliExitCode 1 -Message "Maximum revision attempts reached ($maxRevisions)."
    }
    catch {
        Set-HarnessWorkflowResult -Result $Result -Outcome "failed" -Category "internal_error" -Stage $Result.stage `
            -LegacyExitCode 2 -CliExitCode 2 -Message "The workflow failed outside a stage." `
            -ErrorRecord $_ -ErrorSource "workflow"
    }
}
