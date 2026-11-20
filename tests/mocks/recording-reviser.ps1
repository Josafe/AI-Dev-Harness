param(
    [Parameter(Mandatory = $true)]
    [string]$Task,

    [Parameter(Mandatory = $true)]
    [string]$SpecFile,

    [Parameter(Mandatory = $true)]
    [string]$ReviewFile,
    [string]$Mode,

    [string]$Model,

    [string]$OutputFile
)

# Records -Mode as "reviser|<mode>" ("(not passed)" when omitted), then writes
# a valid specification (FR-017).

$recordFile = $env:AI_HARNESS_TEST_RECORD_FILE
if ([string]::IsNullOrWhiteSpace($recordFile)) {
    Write-Host "AI_HARNESS_TEST_RECORD_FILE is not set."
    exit 1
}

$received = if ($PSBoundParameters.ContainsKey("Mode")) { $Mode } else { "(not passed)" }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::AppendAllText($recordFile, "reviser|$received`r`n", $utf8NoBom)

$spec = @"
# Specification

## Goal

Revised test specification.

## Context

None

## Functional Requirements

### FR-001

**Source:** USER

A user can perform the requested action.

## Non-Functional Requirements

None

## Acceptance Criteria

### AC-001

**Source:** USER

A user can complete the requested action.

## Edge Cases

None

## Dependencies

None

## Open Questions

None

## Assumptions

None
"@

[System.IO.File]::WriteAllText($OutputFile, $spec, $utf8NoBom)

Write-Host ""
Write-Host "=== MOCK REVISER (RECORDING) ===" -ForegroundColor DarkCyan
Write-Host "Revision generated: $OutputFile"

exit 0
