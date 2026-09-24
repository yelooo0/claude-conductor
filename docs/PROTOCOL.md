# claude-astra protocol

Planner (Claude Pro subscription) writes packets. DeepSeek worker implements them.
Reviewer (Claude Pro subscription) accepts or returns issues. Repeat, bounded.

## Loop

```
orchestrate.sh start "description"
        │  PHASE=plan                     opens a Claude Pro session (claude)
        ▼
planner writes .astra/TASK.md            ── worker should not read until handoff
        │  watch: TASK.md exists         ── (PHASE -> working)
        ▼
DeepSeek worker session            worker/launch.sh
        │  reads .astra/TASK.md (and .astra/REVIEW.md if present)
        │  implements, runs acceptance, commits, writes .astra/EVIDENCE.md
        ▼
watch: git HEAD changed            ── (PHASE -> review)
        │                            opens a fresh Claude Pro session
claude reviewer reads TASK.md + diff + EVIDENCE.md
        │  runs acceptance itself
        ▼
writes .astra/REVIEW.md
   ├─ APPROVED            ── PHASE=approved, packet done, next packet
   └─ ISSUES (§, location, fix) ─→ round +1 → worker (round 2 … <= MAX_ROUNDS=2)
                          └─ round > MAX ─→ PHASE=escalated, planner takes over packet
```

## State files (per project, under `.astra/`, git-ignored)

| file | purpose |
|---|---|
| `PHASE` | `plan` → `working` → `review` → `approved` / `escalated` |
| `ROUND` | worker round counter for the current packet |
| `WORKER_START_COMMIT` | HEAD at the moment the worker started (commit detection) |
| `TASK.md` | the packet spec (planner writes; worker consumes) |
| `REVIEW.md` | reviewer verdict + numbered issues, or `APPROVED` |
| `EVIDENCE.md` | worker: what changed, commands run, test output, out-of-scope notes |

Never commit `.astra/`. The driver recreates what it needs.

## Hand-off rules

1. **One packet at a time.** A packet is one logical, verifiable change. If you
   find yourself writing "also fix X", split it.
2. **The worker owns everything after dispatch.** No progress polling; the
   reviewer only sees the finished commit + evidence.
3. **Reviewer runs the acceptance checks itself**, on the worker’s commit. "It
   must have passed" is not evidence.
4. **Numbered, actionable issues.** Each issue = severity + `file:line` + the
   concrete fix. The worker fixes issues only — no new scope.
5. **Bounded loops.** `ASTRA_MAX_ROUNDS=2`. On exceed, phase → `escalated` and
   the planner finishes that packet on Claude Pro directly.
6. **Review in one batched pass.** The reviewer writes all issues in a single
   `REVIEW.md`; no back-and-forth polling.

## Model assignment (enforced by `launch.sh` / `orchestrate.sh`)

| role | engine | model | config |
|---|---|---|---|
| planner / reviewer | Claude Code, your Pro subscription | subscription default | normal `~/.claude` |
| worker | Claude Code, DeepSeek API | `deepseek-v4-flash` (override via `ASTRA_WORKER_MODEL`) | `~/.claude-deepseek` (isolated), `ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic` |

### Why a separate worker session instead of an in-session subagent?
Routing a subagent to a third-party API from inside Claude Code today means a
local relay/gateway that logs in with the subscription token — the pattern
Anthropic has been enforcing against (documented account bans since early
2026). The session handoff above uses only officially documented paths: DeepSeek
publishes its Anthropic-compatible endpoint, and the worker keeps its own API
key in an isolated config dir. Your subscription token never leaves the
official client.

### Known DeepSeek quirk
Claude Code ≥ 2.1.166 sends `thinking:{type:"disabled"}` together with a
reasoning effort for subagent requests, which DeepSeek rejects with a 400. The
worker session runs as a main agent (not a subagent) so the impact is limited;
`launch.sh` also clears `CLAUDE_CODE_EFFORT_LEVEL`. If you still see 400s, pin
Claude Code to a known-good version.

## Escalation policy
- Worker hits the round limit → planner finishes the packet (Claude Pro).
- Worker reports a blocker in `EVIDENCE.md` with no commit → planner decides:
  re-scope the packet or take it over.
- Hard, low-token work is never delegated (secrets, migrations, prod).