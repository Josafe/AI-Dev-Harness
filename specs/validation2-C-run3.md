# Specification

## Goal
Create a command-line interface (CLI) tool that converts CSV files to JSON format.

## Context
None

## Functional Requirements

### FR-001
**Source:** USER
The CLI tool must accept a CSV file path as input and output the corresponding JSON representation to standard output.

### FR-002
**Source:** USER
The CLI tool must support specifying an optional output file path for writing the JSON result instead of printing to stdout.

## Non-Functional Requirements
None

## Acceptance Criteria

### AC-001
**Source:** USER
Given a valid CSV file, when the CLI is executed with the input file path, then it outputs valid JSON to standard output.

### AC-002
**Source:** USER
Given a valid CSV file and an optional output file path argument, when the CLI is executed, then it writes the JSON result to the specified output file instead of stdout.

### AC-003
**Source:** USER
Given an invalid or non-existent input CSV file, when the CLI is executed, then it reports an error indicating the file cannot be read.

## Edge Cases
None

## Dependencies
None

## Open Questions
None

## Assumptions
None