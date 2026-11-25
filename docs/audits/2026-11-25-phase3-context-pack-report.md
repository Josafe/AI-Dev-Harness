# Phase 3 context pack and probe patch: report

## Executive summary

- Two commits on branch `claude/phase3-context-cf1882` (from master `9d76746`): `351410b` adds `docs/phase3-context.md`; `59e5509` patches the spec with the owner's probes. Nothing pushed, tagged, amended or reset. No script, test or config changed; only `scripts\validate-spec.ps1` was run (STATUS PASS, ASCII only).
- Pack: 8,098 bytes (7.9 KiB), ASCII; sections 1 to 6 as requested, with a package table (A1-A4, B1-B9) giving ids, spec line ranges, exit check and S/O model.
- Spec: 68,436 -> 69,612 bytes (+1,176, limit 1,500; blob size, LF). Ids, `Verifies:`/`Source:` lines and the traceability matrix are untouched (no id added or removed). Line numbers moved by up to 8 after FR-316 (pack ranges are for this tree).
- Spec edits: FR-316 gets a "Probe" paragraph (the three lorem-ipsum windows, `num_ctx/2 + 2` in 3 of 3 plus the WP-2E case 16,384 -> 8,194, so 4 of 4; rule 7 holds in all; RECOMMENDATION of `n == floor(num_ctx/2) + 2`, Ollama-version dependent, lorem ipsum only; no prompt-cache effect seen). Reconciled with WP-2E: the probe's healthy 5.2-5.4 chars/token sit inside 3.93-5.43. OQ-317 gets the model-switch measurements and the RECOMMENDATION. "Not Verified" no longer says "other windows" without scope. RN-3 and every requirement outcome unchanged; OQ-322 untouched.
- The "Facts" in the pack were read from `agent-exec.ps1`, `config.ps1`, `telemetry.ps1` and `.ai/config.json`, not run.

## Also changed (outside the brief, minimal)

- `docs/audits/2026-11-26-phase3-spec-rev2-notes.md`, row RN-1: "One observed truncation only" replaced by the probe evidence (the brief named RN-1). Committed with the spec patch.
- OQ-317 and OQ-318 shared one line in the spec; my insert split them (no text lost).

## Sections I was unsure about

- B4 read list: its ACs are scattered; I gave ranges, not a minimal set. B7 and B9 share AC-302 and AC-306 "in part" with other packages.
- A4 / B3 split of FR-318: I gave the whole FR-318 L216-222 to both (library half in A4, command in B3).
- Wrapper driver "about 335-375" is the spec's own approximation; not re-grepped (A2 must).
- Pack says one `test-all` per package; the gate (L584) and AC-324 (L450) still say twice, which is deliberate for the gate.

## Inconsistencies found in the spec (not fixed)

- (fixed, see below) FR-318 did not mention `ollama ps`; the RECOMMENDATION "doctor reports `ollama ps`" is not backed by a requirement (stated as such).

## Not done

- No `test-all` run (not allowed).

## Fixes applied (third commit, on request of the review session)

L575 now asks for one final `test-all` per package (gate L584 and AC-324 L450 keep "twice"); OQ-320 has one definition; the notes "Not verified" line cites the probes (4096, 8192) and WP-2E 16,384; FR-304 double comma removed; FR-207 stays as the `keep_alive` citation and no `FR-212` remains in the spec, notes or pack; FR-318 now says `doctor` reports `ollama ps` read-only (AC-333 not changed, no new id). Sizes (LF): pack 8,098 -> 8,094 bytes; spec 69,612 -> 69,662 (+1,226 over the original 68,436). validate-spec PASS.
