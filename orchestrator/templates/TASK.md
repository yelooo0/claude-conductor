# Packet: <short verb phrase>

## Objective
_One sentence. The behaviour this packet must produce and why._

## Scope
- Files/directories the worker may touch.
- Modules/APIs they must use (import paths, function names, signatures).
- Explicitly out of scope (anything outside must be reported, not edited).

## Acceptance (Definition of Done)
The worker must run these and they must pass before handoff:
1. `command to run` — expected outcome
2. `test/lint command` — expected outcome
3. …

## Constraints
- Conventions to follow (e.g. "match the pattern in `src/foo.py`", "no new deps").
- Anything that must not change (e.g. "keep the public API stable").
- Edge cases the worker must handle.

## Success criteria for the reviewer
Without reading this packet, what must be verifiable from the diff + tests alone?

---
_Worker writes its provenance to `.conductor/EVIDENCE.md` and commits when done.
Reviewer reads the diff + evidence, runs acceptance checks, and writes `.conductor/REVIEW.md`
(numbered issues) or `APPROVED`.