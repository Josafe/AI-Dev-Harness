param(
    [string]$Agent,
    [string]$Task,
    [string]$Model,
    [string]$OutputFile
)

# Writes a documentation-mode specification equivalent to
# tests/fixtures/documentation-none-spec.md: descriptive Context, and None for
# Functional Requirements, Non-Functional Requirements, Acceptance Criteria and
# the other optional sections (AC-011).

$spec = @"
# Specification

## Goal

Describe the existing command-line tool for maintainers.

## Context

The tool reads a configuration file and prints a report. This document describes its current behavior; no new functionality is requested.

## Functional Requirements

None

## Non-Functional Requirements

None

## Acceptance Criteria

None

## Edge Cases

None

## Dependencies

None

## Open Questions

None

## Assumptions

None
"@

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutputFile, $spec, $utf8NoBom)

exit 0
