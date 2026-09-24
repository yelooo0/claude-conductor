# claude-astra

Plan with **Claude Pro** → build with **DeepSeek** (pay-per-token) → review
with **Claude Pro**. A two-model orchestration loop for coding, modelled on the
Codex-native *Astra Flash Orchestrator* but built on officially supported paths
for Claude.

No copy-paste, no in-session patching, no ToS-risk relays. Two separate Claude
Code sessions hand off through git and `.astra/` files; `orchestrate.sh` opens
the right session in a new Terminal window each step and notifies you which one
needs you.

## What you get

```
planner (Claude Pro) ──writes TASK.md──▶ DeepSeek worker ──commits+EVIDENCE──▶ reviewer (Claude Pro)
   ▲                                                                            │
   └─────────────── ISSUES in REVIEW.md (≤ 2 rounds, then escalate) ◀──────────┘
```

## Requirements

- Claude Code (`claude` CLI) signed in with your **Claude Pro/Max** subscription
- A **DeepSeek API key** (worker runs on their pay-per-token Anthropic-compatible API)
- macOS with **Terminal.app** (used to open handoff sessions)
- Bash, git, curl

## Quickstart

```bash
# 1. one-time setup: stores your DeepSeek key (0600), creates isolated ~/.claude-deepseek,
#    pin installs the worker policy, verifies the endpoint (auth-only, no inference)
./worker/setup.sh

# 2. sanity check (no inference)
./doctor.sh

# 3. begin a packet in your project (from the project dir):
/path/to/claude-astra/drive/orchestrate.sh start "implement X per docs/plan.md"

# 4. keep watching in a background terminal:
/path/to/claude-astra/drive/orchestrate.sh watch
```

`watch` detects each handoff and opens the next session in a fresh Terminal
window, plus a macOS notification saying *where to switch*. You do the thinking
in each window; you never copy-paste task text.

## Commands

```
start "<description>"   begin a packet            (opens Claude Pro planner)
watch [--once]          coordinate handoffs        (opens worker/reviewer as needed)
status                  current phase + round
approve                 manually approve a packet
escalate                hand packet back to the planner
reset                   clear packet state
help                    full command + env reference
```

Driver env: `ASTRA_PROJECT_DIR`, `ASTRA_MAX_ROUNDS` (default 2),
`ASTRA_POLL_INTERVAL` (default 3s), `ASTRA_NOTIFICATIONS` (default 1).

## Docs

- `docs/PROTOCOL.md` — the handoff protocol, state files, routing table, escalation policy
- `docs/COST.md` — cost model, worker-tier choice, the prompt-caching lever
- `doctor.sh` — offline prerequisite checks (spends nothing)

## Layout

```
driv/orchestrate.sh     handoff state machine + Terminal-window coordinator
worker/launch.sh        isolated DeepSeek worker session (all model slots pinned)
worker/setup.sh         one-time key + isolated config setup
worker/CLAUDE.md        worker policy (installed into ~/.claude-deepseek/CLAUDE.md)
orchestrator/templates/ packet (TASK.md) + review (REVIEW.md) formats
tests/                  offline, inference-free tests (bash -n, isolation, loop)
```

## Honest caveats

- The worker must be at least `deepseek-v4-flash` quality to save money; a
  worker too weak for the packet converts savings into reviewer rework.
- Best for mechanical, verifiable work inside existing conventions — not pure
  greenfield design. See `docs/COST.md`.
- Uses only official paths: the DeepSeek Anthropic-compatible endpoint and
  Claude Code's own config isolation. Your subscription token never leaves the
  official client.

## License

MIT