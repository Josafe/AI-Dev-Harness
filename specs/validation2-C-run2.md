# Specification

## Goal

Create a command-line interface (CLI) tool that reads a CSV file and converts it to JSON format.

## Context

None

## Functional Requirements

### FR-001
**Source:** USER
The CLI accepts a path to an input CSV file as a command-line argument.

### FR-002
**Source:** USER
The CLI outputs the converted data in JSON format to standard output or to a specified output file when provided.

### FR-003
**Source:** USER
The CLI reads CSV content and produces JSON where each row becomes an object with column names as keys.

## Non-Functional Requirements

None

## Acceptance Criteria

### AC-001
**Source:** USER
Given a valid CSV file with headers, the CLI outputs valid JSON to standard output when no output file is specified.

### AC-002
**Source:** USER
Given an input CSV file path and an output file path as arguments, the CLI writes the JSON output to the specified file.

### AC-003
**Source:** USER
Given a CSV file with empty rows or missing values, the CLI outputs valid JSON representing the available data.

## Edge Cases

None

## Dependencies

None

## Open Questions

None

## Assumptions

None