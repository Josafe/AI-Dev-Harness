param(
    [string]$Agent,
    [string]$Task,
    [string]$Model,
    [string]$OutputFile
)

# Records the mode from the task's "SPECIFICATION MODE (AUTHORITATIVE):" line
# as "runner|<mode>", then writes a valid specification (FR-017).

$recordFile = $env:AI_HARNESS_TEST_RECORD_FILE
if ([string]::IsNullOrWhiteSpace($recordFile)) {
    Write-Host "AI_HARNESS_TEST_RECORD_FILE is not set."
    exit 1
}

$mode = "(not found)"
$match = [regex]::Match([string]$Task, '(?m)^SPECIFICATION MODE \(AUTHORITATIVE\):[ \t]*\r?\n[ \t]*(\S+)')
if ($match.Success) {
    $mode = $match.Groups[1].Value
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::AppendAllText($recordFile, "runner|$mode`r`n", $utf8NoBom)

$spec = @"
# Specification

## Goal

Test specification.

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

exit 0
