# AI Development Harness: shared agent execution library (Phase 2).
#
# WP-2A: prompt parts and the three legacy prompt builders (FR-201, FR-203, FR-208).
# Dot-sourcing this file defines functions and nothing else: it prints nothing,
# reads no file and sends no request.
#
# The builders concatenate strings. An input segment (agent file, contract,
# project instructions, context, task, mode, specification, review) appears in the
# output byte for byte, whatever its own line endings. Only the template text is
# written here, as lines joined with an explicit CRLF separator (OQ-211): the
# legacy scripts produce CRLF there on a standard checkout, and this file does not
# depend on its own line endings. Inputs are never passed to -f, Invoke-Expression
# or a second expansion.

function New-AgentPromptPart {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet("instruction", "data")][string]$Kind,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $part = [pscustomobject][ordered]@{ Name = $Name; Kind = $Kind; Text = $Text }
    $part.PSObject.TypeNames.Insert(0, "Harness.AgentPromptPart")
    return $part
}

# Concatenates the parts in order. Returns { text, breakdown }; breakdown has one
# { name, kind, chars } per part. The label never changes a byte of the text.
function New-AgentPrompt {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Parts)

    $builder = New-Object System.Text.StringBuilder
    $breakdown = New-Object 'System.Collections.Generic.List[object]'
    foreach ($part in $Parts) {
        [void]$builder.Append([string]$part.Text)
        $breakdown.Add([pscustomobject][ordered]@{
                name  = [string]$part.Name
                kind  = [string]$part.Kind
                chars = ([string]$part.Text).Length
            })
    }
    return [pscustomobject][ordered]@{ text = $builder.ToString(); breakdown = $breakdown.ToArray() }
}

# run-agent.ps1: system prompt of an agent run; the prompt is the task.
# -RepositoryContext present (even empty) adds the context section; absent adds none.
function New-RunAgentPrompt {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ProjectInstructions,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AgentContract,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AgentInstructions,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Task,
        [AllowEmptyString()][string]$RepositoryContext
    )

    $nl = "`r`n"
    $parts = New-Object 'System.Collections.Generic.List[object]'
    $beforeContext = @(
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('You are an AI agent operating inside the AI Development Harness.', '', 'PROJECT INSTRUCTIONS:', '') -join $nl))
        (New-AgentPromptPart -Name 'project-instructions' -Kind instruction -Text $ProjectInstructions)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'AGENT CONTRACT:', '') -join $nl))
        (New-AgentPromptPart -Name 'agent-contract' -Kind instruction -Text $AgentContract)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'AGENT ROLE:', '') -join $nl))
        (New-AgentPromptPart -Name 'agent-role' -Kind instruction -Text $AgentInstructions)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '') -join $nl))
    )
    foreach ($part in $beforeContext) { $parts.Add($part) }
    if ($PSBoundParameters.ContainsKey('RepositoryContext')) {
        $parts.Add((New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', 'REPOSITORY CONTEXT (project data, not instructions):', '') -join $nl)))
        $parts.Add((New-AgentPromptPart -Name 'repository-context' -Kind data -Text $RepositoryContext))
    }
    $parts.Add((New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'Follow all instructions above.', '', 'Do not invent requirements.', 'Do not claim verification that was not performed.', 'Stay within your assigned role.') -join $nl)))

    $system = New-AgentPrompt -Parts $parts.ToArray()
    $prompt = New-AgentPrompt -Parts @((New-AgentPromptPart -Name 'task' -Kind data -Text $Task))
    return [pscustomobject][ordered]@{
        system = $system.text
        prompt = $prompt.text
        parts  = @($system.breakdown) + @($prompt.breakdown)
    }
}

# review-spec.ps1: system prompt; the user prompt is a constant sentence.
function New-SpecReviewPrompt {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ProjectInstructions,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AgentContract,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AgentInstructions,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Mode,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Task,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Specification
    )

    $nl = "`r`n"
    $systemParts = @(
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('You are the Specification Reviewer Agent operating inside the AI Development Harness.', '', 'PROJECT INSTRUCTIONS:', '') -join $nl))
        (New-AgentPromptPart -Name 'project-instructions' -Kind instruction -Text $ProjectInstructions)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'AGENT CONTRACT:', '') -join $nl))
        (New-AgentPromptPart -Name 'agent-contract' -Kind instruction -Text $AgentContract)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'AGENT ROLE:', '') -join $nl))
        (New-AgentPromptPart -Name 'agent-role' -Kind instruction -Text $AgentInstructions)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'IMPORTANT REVIEW INPUT:', '', 'SPECIFICATION MODE (AUTHORITATIVE):', '') -join $nl))
        (New-AgentPromptPart -Name 'mode' -Kind instruction -Text $Mode)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'ORIGINAL USER REQUEST:', '') -join $nl))
        (New-AgentPromptPart -Name 'task' -Kind data -Text $Task)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'GENERATED SPECIFICATION:', '') -join $nl))
        (New-AgentPromptPart -Name 'specification' -Kind data -Text $Specification)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'Review the generated specification against the original user request.', '', 'Do not modify the specification.', '', 'Do not implement code.', '', 'Do not invent additional requirements.', '', 'Identify unsupported or misclassified requirements.', '', 'Pay particular attention to requirements incorrectly marked as Source: USER.', '', 'Follow the reviewer output format exactly.', '', 'Do not claim PASS without actually reviewing the specification.') -join $nl))
    )

    $system = New-AgentPrompt -Parts $systemParts
    $prompt = New-AgentPrompt -Parts @((New-AgentPromptPart -Name 'user-prompt' -Kind instruction -Text 'Review the specification according to your assigned role.'))
    return [pscustomobject][ordered]@{
        system = $system.text
        prompt = $prompt.text
        parts  = @($system.breakdown) + @($prompt.breakdown)
    }
}

# revise-spec.ps1: system prompt; the user prompt is a constant sentence.
function New-SpecRevisePrompt {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ProjectInstructions,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AgentContract,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AgentInstructions,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Mode,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Task,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Specification,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Review
    )

    $nl = "`r`n"
    $systemParts = @(
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('You are the Specification Reviser Agent operating inside the AI Development Harness.', '', 'PROJECT INSTRUCTIONS:', '') -join $nl))
        (New-AgentPromptPart -Name 'project-instructions' -Kind instruction -Text $ProjectInstructions)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'AGENT CONTRACT:', '') -join $nl))
        (New-AgentPromptPart -Name 'agent-contract' -Kind instruction -Text $AgentContract)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'AGENT ROLE:', '') -join $nl))
        (New-AgentPromptPart -Name 'agent-role' -Kind instruction -Text $AgentInstructions)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'SPECIFICATION MODE (AUTHORITATIVE):', '') -join $nl))
        (New-AgentPromptPart -Name 'mode' -Kind instruction -Text $Mode)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'ORIGINAL USER REQUEST:', '') -join $nl))
        (New-AgentPromptPart -Name 'task' -Kind data -Text $Task)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'CURRENT SPECIFICATION:', '') -join $nl))
        (New-AgentPromptPart -Name 'specification' -Kind data -Text $Specification)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'SPECIFICATION REVIEW:', '') -join $nl))
        (New-AgentPromptPart -Name 'review' -Kind data -Text $Review)
        (New-AgentPromptPart -Name 'template' -Kind instruction -Text (('', '', 'Revise the specification according to the reviewer findings.', '', 'This is a MINIMAL REVISION, not a rewrite. Your task is ONLY to remove or', 'correct unsupported content identified by the reviewer. It is NOT to make the', 'specification more complete.', '', 'Rules, in order:', '', '1. Start from the CURRENT SPECIFICATION.', '2. Preserve every requirement directly supported by the ORIGINAL USER REQUEST.', '3. Remove or correct every unsupported item identified by the REVIEW.', '4. Do not replace removed items with new ones.', '5. Do not invent requirements, edge cases, open questions, assumptions,', '   dependencies, security or validation rules, UI behavior, error handling,', '   implementation details, architecture decisions, or facts about the', '   existing system. Use only context supported by the supplied input.', '6. Apply the acceptance-criteria rules for the authoritative specification mode:', '   - requirements: retain or revise criteria only when supported by', '     requested behavior. Do not force criteria when none are supported', '     or necessary.', '   - baseline: include criteria only for behavior explicitly authorized', '     for preservation. Do not turn unrelated implementation details', '     into criteria.', '   - documentation: do not create acceptance criteria to verify', '     descriptive implementation facts. Use None when no independent', '     requirement needs acceptance criteria.', '   - mixed requests: criteria may cover explicit requested changes and', '     explicitly authorized preservation only.', '7. Every requirement must have a Source of USER, PROJECT, FACT or ASSUMPTION.', '', 'The output MUST contain exactly these headings, in this order:', '', '# Specification', '## Goal', '## Context', '## Functional Requirements', '## Non-Functional Requirements', '## Acceptance Criteria', '## Edge Cases', '## Dependencies', '## Open Questions', '## Assumptions', '', 'If a section has no supported content, write exactly: None', '', 'Before answering, verify that all 10 headings are present and that nothing', 'unsupported or new was introduced.', '', 'Verify that Functional Requirements, Non-Functional Requirements and', 'Acceptance Criteria contain only entries justified by the authoritative', 'specification mode and supplied evidence.', '', 'Do not require FR-XXX, NFR-XXX or AC-XXX entries when the selected mode and', 'available evidence do not support them. Write None for empty sections.', '', 'Return ONLY the complete revised specification.') -join $nl))
    )

    $system = New-AgentPrompt -Parts $systemParts
    $prompt = New-AgentPrompt -Parts @((New-AgentPromptPart -Name 'user-prompt' -Kind instruction -Text 'Revise the specification according to the original request and review findings.'))
    return [pscustomobject][ordered]@{
        system = $system.text
        prompt = $prompt.text
        parts  = @($system.breakdown) + @($prompt.breakdown)
    }
}

# WP-2B1: context budget (FR-209, XR-03). Pure arithmetic, never changes a prompt.
#   C = contextWindow, R = reservedOutputTokens, S = ceil(safetyMarginRatio x C),
#   E = ceil((len(system) + len(prompt)) / charsPerToken).
# The budget holds when E + R + S <= C. All arithmetic is [decimal] with
# [math]::Ceiling (Phase 1 hardening F-01). status is ok, exceeded or skipped;
# skipped (no contextWindow or no reservedOutputTokens, every v1 configuration)
# reports nothing. enforce and warn are not distinguished here: the mode is read
# by the caller (Invoke-AgentModel). -Parts takes parts (Name, Kind, Text) or
# breakdown entries (name, kind, chars), as New-AgentPrompt and the builders return them.
function Test-AgentContextBudget {
    param(
        [Parameter(Mandatory = $true)]$Execution,
        [Parameter(Mandatory = $true)]$Registry,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$System,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prompt,
        [AllowNull()][object[]]$Parts
    )

    foreach ($member in @('contextWindow', 'reservedOutputTokens')) {
        if ($null -eq $Execution -or $null -eq $Execution.PSObject.Properties[$member]) {
            throw "invalid_arguments: -Execution must be a record of Resolve-HarnessExecution (no '$member')."
        }
    }
    if ($null -eq $Registry -or $null -eq $Registry.defaults -or
        $null -eq $Registry.defaults.PSObject.Properties['safetyMarginRatio'] -or
        $null -eq $Registry.defaults.PSObject.Properties['charsPerToken']) {
        throw "invalid_arguments: -Registry must be a normalized registry (defaults.safetyMarginRatio and defaults.charsPerToken)."
    }

    $window = $Execution.contextWindow
    $reserved = $Execution.reservedOutputTokens
    if ($null -eq $window -or $null -eq $reserved) {
        return [pscustomobject][ordered]@{
            status        = 'skipped'
            contextWindow = $null
            reserved      = $null
            margin        = $null
            estTokens     = $null
            available     = $null
            over          = $null
            sections      = @()
        }
    }

    $charsPerToken = [decimal]$Registry.defaults.charsPerToken
    $c = [decimal]$window
    $r = [decimal]$reserved
    $s = [math]::Ceiling([decimal]$Registry.defaults.safetyMarginRatio * $c)
    $e = [math]::Ceiling([decimal]($System.Length + $Prompt.Length) / $charsPerToken)
    $available = $c - $r - $s

    $status = 'exceeded'
    if ($e + $r + $s -le $c) { $status = 'ok' }
    $over = [decimal]0
    if ($e -gt $available) { $over = $e - $available }

    $sections = New-Object 'System.Collections.Generic.List[object]'
    foreach ($part in @($Parts)) {
        if ($null -eq $part) { continue }
        $chars = 0
        if ($null -ne $part.PSObject.Properties['chars']) { $chars = [long]$part.chars }
        elseif ($null -ne $part.PSObject.Properties['Text']) { $chars = ([string]$part.Text).Length }
        $sections.Add([pscustomobject][ordered]@{
                name      = [string]$part.Name
                kind      = [string]$part.Kind
                chars     = [long]$chars
                estTokens = [long][math]::Ceiling([decimal]$chars / $charsPerToken)
            })
    }

    return [pscustomobject][ordered]@{
        status        = $status
        contextWindow = [long]$c
        reserved      = [long]$r
        margin        = [long]$s
        estTokens     = [long]$e
        available     = [long]$available
        over          = [long]$over
        sections      = $sections.ToArray()
    }
}

# WP-2B1: seconds to wait before attempt k + 1 (FR-212): BackoffSec x 2^(k-1),
# capped at 60. Pure: the values are arguments, nothing is read and nothing sleeps.
function Get-AgentRetryDelaySec {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, [int]::MaxValue)][int]$Attempt,
        [Parameter(Mandatory = $true)][ValidateRange(0, [int]::MaxValue)][int]$BackoffSec
    )

    $delay = [long]$BackoffSec
    for ($step = 1; $step -lt $Attempt -and $delay -gt 0 -and $delay -lt 60; $step++) {
        $delay = $delay * 2
    }
    if ($delay -gt 60) { $delay = 60 }
    return [int]$delay
}

# WP-2B2: error categories (FR-211, NFR-202). Pure: it reads no file and sends
# nothing. Rows are checked top to bottom, the first match wins, so an HTTP status
# beats a webStatus. The category comes only from HttpStatus, Failure.exceptionType
# and Failure.webStatus, never from message text. The Ollama JSON body is read only
# to build detail, which never decides anything.
#   -Failure/-HttpStatus  classify a transport failure record (FR-204);
#   -Category             the fixed record of a category named by the engine
#                         (context_budget_exceeded, thinking_budget_exhausted,
#                         empty_response, format_invalid, model_not_installed, or
#                         any other category), so every hint has one home.
# Returns { category, retryable, hint, detail }; retryable is true for http_5xx
# and transport_reset only. detail is Ollama's JSON "error" string (at most 500
# characters) when there is one, else the exception type name and webStatus.
function Get-AgentErrorCategory {
    [CmdletBinding(DefaultParameterSetName = 'ByFailure')]
    param(
        [Parameter(ParameterSetName = 'ByFailure')][AllowNull()]$Failure = $null,
        [Parameter(ParameterSetName = 'ByFailure')][AllowNull()]$HttpStatus = $null,
        [Parameter(Mandatory = $true, ParameterSetName = 'ByName')][AllowEmptyString()][string]$Category
    )

    $hints = [ordered]@{
        'http_5xx'                  = 'The Ollama server failed on every attempt. If the Ollama log shows a GPU or CUDA initialization error, restarting the Ollama server usually clears it.'
        'http_4xx'                  = 'Ollama rejected the request. Check the model name, the options and the think setting of the profile against what the model supports.'
        'timeout'                   = 'The server did not answer within timeoutSec of the profile. Check that the model fits in memory, or raise timeoutSec.'
        'transport_unreachable'     = 'Ollama could not be reached. Check that the Ollama server is running and that ollamaUrl is correct.'
        'transport_reset'           = 'The connection to Ollama was dropped on every attempt. If the Ollama log shows a GPU or CUDA initialization error, restarting the Ollama server usually clears it.'
        'transport_other'           = 'The request failed for a reason the harness does not classify. See the detail and the Ollama server log.'
        'context_budget_exceeded'   = 'The prompt does not fit the context budget of the profile. Shorten the input, or raise the context window of the profile.'
        'thinking_budget_exhausted' = 'The model spent its output budget on reasoning and returned no answer. Raise options.num_predict or the context window of the profile, or change its think setting.'
        'empty_response'            = 'The model returned an empty answer. Try again, or use a shorter input.'
        'format_invalid'            = 'The answer did not have the expected format. The raw text was kept.'
        'model_not_installed'       = 'The model is not installed on the Ollama server. Pull it with ollama pull, or choose another profile.'
    }

    if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        if (@($hints.Keys) -cnotcontains $Category) {
            throw "invalid_arguments: unknown error category '$Category'."
        }
        $retryableByName = ($Category -ceq 'http_5xx' -or $Category -ceq 'transport_reset')
        return [pscustomobject][ordered]@{
            category  = $Category
            retryable = $retryableByName
            hint      = [string]$hints[$Category]
            detail    = ''
        }
    }

    $exceptionType = $null
    $webStatus = $null
    $body = $null
    if ($null -ne $Failure) {
        if ($null -ne $Failure.PSObject.Properties['exceptionType']) { $exceptionType = $Failure.exceptionType }
        if ($null -ne $Failure.PSObject.Properties['webStatus']) { $webStatus = $Failure.webStatus }
        if ($null -ne $Failure.PSObject.Properties['body']) { $body = $Failure.body }
    }
    $exceptionType = if ($null -eq $exceptionType) { '' } else { [string]$exceptionType }
    $webStatus = if ($null -eq $webStatus) { '' } else { [string]$webStatus }

    $hasStatus = $false
    $status = 0
    if ($null -ne $HttpStatus -and "$HttpStatus" -ne '') {
        $hasStatus = $true
        $parsed = 0
        if ([int]::TryParse("$HttpStatus", [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            $status = $parsed
        }
        else {
            $status = -1
        }
    }

    $name = 'transport_other'
    if ($hasStatus -and $status -ge 500 -and $status -le 599) { $name = 'http_5xx' }
    elseif ($hasStatus -and $status -ge 400 -and $status -le 499) { $name = 'http_4xx' }
    elseif ($hasStatus) { $name = 'transport_other' }
    elseif ($webStatus -ceq 'Timeout' -or $exceptionType -ceq 'System.TimeoutException') { $name = 'timeout' }
    elseif (@('ConnectFailure', 'NameResolutionFailure', 'ProxyNameResolutionFailure') -ccontains $webStatus) { $name = 'transport_unreachable' }
    elseif (@('ConnectionClosed', 'ReceiveFailure', 'SendFailure', 'KeepAliveFailure', 'PipelineFailure') -ccontains $webStatus -or
        $exceptionType -ceq 'System.IO.IOException' -or $exceptionType -ceq 'System.Net.Sockets.SocketException') { $name = 'transport_reset' }

    # detail: Ollama's JSON error string when there is one, else type and webStatus.
    # It is display data; nothing above or below reads it to decide.
    $detail = $null
    if ($body -is [string] -and $body.Length -gt 0) {
        try {
            $json = $body | ConvertFrom-Json
            if ($null -ne $json -and $null -ne $json.PSObject.Properties['error'] -and $json.error -is [string] -and $json.error.Length -gt 0) {
                $detail = [string]$json.error
            }
        }
        catch { $detail = $null }
    }
    if ($null -eq $detail) {
        $parts = @()
        if ($exceptionType.Length -gt 0) { $parts += $exceptionType }
        if ($webStatus.Length -gt 0) { $parts += $webStatus }
        if ($parts.Count -eq 0) { $parts += 'unknown' }
        $detail = ($parts -join ' ')
    }
    if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) }

    return [pscustomobject][ordered]@{
        category  = $name
        retryable = ($name -ceq 'http_5xx' -or $name -ceq 'transport_reset')
        hint      = [string]$hints[$name]
        detail    = $detail
    }
}