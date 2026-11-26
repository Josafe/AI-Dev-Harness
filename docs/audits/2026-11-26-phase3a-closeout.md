# Phase 3A close-out (documentation only)

## Summary

- Changed: `specs/harness-phase-2-shared-engine.md` (one note, two Deferred Items rows). No script, test or config change.
- Closed DF-203 (wrappers deleted by Phase 3 package A2, commit `0d4a199`).
- Closed DF-202 (telemetry lock by Phase 3 package A1, commit `42af7cb`, FR-311). The brief said A2 for both; DF-202 was in fact fixed by A1, so it is recorded that way.
- Added a "Phase 3 note (FR-314)" after the wrappers paragraph of FR-202: the two functions, their nine AC-216 cases and the AC-218 `Write-Host` exemption no longer exist; FR-202, AC-216, AC-218 are superseded for those two functions only.
- Nothing from FR-314 was left undone. Its code parts were done by A2 (AC-322).

## Verification

- `scripts\validate-spec.ps1 -SpecFile specs/harness-phase-2-shared-engine.md`: PASS.
- Added text is ASCII only. No other script was run.

## Not touched / for the owner

- The stale comment at `test-engine-callsites.ps1:691` (A2 report) needs a code edit; not done here.
- Other Phase 3 spec notes (README, NFR-202) are outside this task.
