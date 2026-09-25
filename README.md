# claude-conductor

Plan with **Claude Pro** → build with **DeepSeek** (pay-per-token) → review
with **Claude Pro**. A two-model orchestration loop for coding, modelled on the
Codex-native *Astra Flash Orchestrator* but built on officially supported paths
for Claude.

No copy-paste, no in-session patching, no ToS-risk relays. Two separate Claude
Code sessions hand off through git and `.conductor/` files; `orchestrate.sh` opens
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

# 3. begin a packet in your project (from the project dir) — one command boots
#    everything: git-check + baseline, the Claude Pro planner window (the
#    "brain"), AND a background coordinator that opens worker/reviewer windows
#    and notifies you on each handoff. Nothing else to run:
/path/to/claude-conductor/drive/orchestrate.sh up "implement X per docs/plan.md"

#    Or boot idle and wait for your first prompt instead:
/path/to/claude-conductor/drive/orchestrate.sh up
```

`up` inits the folder as a git repo if needed (the loop hands off through git
commits), clears stale state, opens the planner, and starts the coordinator in
its own Terminal window. You just wait for macOS notifications and switch to
each session as prompted. `watch`/`start` still exist for manual control.

> **Always run `up` from a project folder, never from `~` or `/`.** `up` may
> create a git repo and a baseline commit of the folder — in your home
> directory that would try to sweep Photos/Mail/etc. into git. `up` refuses to
> run in `~` or `/` for this reason.

## Keep prompting the brain (router mode)

After `up`, the planner window is a **router**: every prompt you type there is
turned into a packet automatically and handed to the DeepSeek worker, and the
review comes back to the *same* brain window when the worker is done — you never
type another command. The brain session follows `orchestrator/templates/TASK.md`,
resets state via `orchestrate.sh reroute "<task>"`, and reviews via the
`.conductor/REVIEW_REQUESTED` handshake that `up` enables by default.

To see the flow in code: `docs/PROTOCOL.md`, and the seeds in
`drive/orchestrate.sh` (`planner_seed` / `review_handoff`).

`watch` detects each handoff and opens the next session in a fresh Terminal
window, plus a macOS notification saying *where to switch*. You do the thinking
in each window; you never copy-paste task text.

## Commands

```
up "<description>"      one command: git-check + planner (router) + coordinator
up                      boot idle — brain + coordinator wait for your first prompt
reroute "<description>" reset to plan from the brain session (no new window)
start "<description>"   begin a packet            (opens Claude Pro planner)
watch [--once]          coordinate handoffs        (opens worker/reviewer as needed)
status                  current phase + round
approve                 manually approve a packet
escalate                hand packet back to the planner
reset                   clear packet state
help                    full command + env reference
```

Driver env: `CONDUCTOR_PROJECT_DIR`, `CONDUCTOR_MAX_ROUNDS` (default 2),
`CONDUCTOR_POLL_INTERVAL` (default 3s), `CONDUCTOR_NOTIFICATIONS` (default 1).

## Bring your own worker model / endpoint

The worker tier is a *pluggable endpoint*, not a DeepSeek requirement. The
launcher keeps it useful by default (DeepSeek's Anthropic-compatible API), but
you can point the muscle tier at any Anthropic-compatible host — OpenRouter, a
self-hosted gateway, a free tier — by setting two env vars before `up`:

```bash
export CONDUCTOR_BASE_URL="https://openrouter.ai/api/v1"   # any Anthropic-compatible endpoint
export CONDUCTOR_WORKER_MODEL="model/provider/id"          # model name for every pinned slot
```

- `CONDUCTOR_BASE_URL` defaults to `https://api.deepseek.com/anthropic`
  (DeepSeek's official Anthropic-compatible endpoint). Override it to reroute
  the worker wholesale.
- `CONDUCTOR_WORKER_MODEL` defaults to `deepseek-v4-flash`. It is pinned to all
  five model slots (default opus/sonnet/haiku, `ANTHROPIC_MODEL`, and subagents)
  so nothing silently falls back to your subscription tier.
- DeepSeek is the default because it offers the best capability-per-dollar for
  agentic coding — not because it's structurally required. A free/cheaper
  endpoint works if its output quality clears the packet bar; if the worker
  can't pass acceptance checks, reviewer rework erases the savings.

See `docs/COST.md` for the cost model and current pricing.

## Docs

- `docs/PROTOCOL.md` — the handoff protocol, state files, routing table, escalation policy
- `docs/COST.md` — cost model, worker-tier choice, the prompt-caching lever
- `docs/GRAPHIFY.md` — knowledge-graph navigation (Graphify) integration: ~82–90% less context per orientation query
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