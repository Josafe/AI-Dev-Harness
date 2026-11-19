# Specification
## Goal
Fix the GitHub Actions dependency installation failure by resolving the inconsistency between package.json and package-lock.json.

## Context
- The workflow fails at `npm ci` due to package.json and package-lock.json being out of sync.
- Missing dependencies include:
  - `oxc-parser@0.159.0`
  - Multiple `@oxc-parser/binding-*@0.159.0` packages
  - `@oxc-project/types@0.159.0`

## Functional Requirements

### FR-001
**Source:** USER  
Investigate and identify the root cause of the package.json and package-lock.json inconsistency.

### FR-002
**Source:** USER  
Identify the minimal correction needed to resolve the inconsistency.

### FR-003
**Source:** USER  
Update package-lock.json to match package.json while preserving existing dependency versions unless a version change is necessary.

### FR-004
**Source:** USER  
Ensure that `npm ci` succeeds in the GitHub Actions Linux environment using Node.js 22.

## Non-Functional Requirements
### NFR-001
**Source:** USER  
The solution must not modify the GitHub Actions workflow or AWS configuration.

### NFR-002
**Source:** USER  
No deployment, staging, or commits should be performed as part of this task.

## Acceptance Criteria

### AC-001
**Source:** USER  
The updated package-lock.json must be consistent with package.json.

### AC-002
**Source:** USER  
Running `npm ci` in the GitHub Actions Linux environment with Node.js 22 must succeed without errors.

### AC-003
**Source:** USER  
The updated dependency configuration must not introduce new dependencies or version changes unless necessary to resolve the inconsistency.

## Edge Cases
None.

## Dependencies

### D-001
**Source:** USER  
Node.js 22 must be used in the GitHub Actions Linux environment.

### D-002
**Source:** USER  
The existing dependency versions must be preserved unless a version change is necessary to resolve the inconsistency.

## Open Questions
### OQ-001
**Source:** USER  
Should package.json be updated to resolve the inconsistency?

## Assumptions
None.

## Verification Commands
```bash
npm ci
```

## Expected Changes
- Update package-lock.json to match package.json.
- No changes to package.json unless necessary to resolve the inconsistency.