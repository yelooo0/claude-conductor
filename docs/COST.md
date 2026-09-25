# Cost model

Two billing surfaces: your **Claude Pro subscription** (flat) and the **DeepSeek
API** (pay-per-token) the worker runs on. The whole point: push token volume to
DeepSeek and keep the subscription for planning + review only.

## Why the split wins

Rough per-1M-token prices for a DeepSeek worker tier — the difference vs a
frontier API/subscription model-equivalent is the leverage:

| stream | DeepSeek worker tier | frontier API-equivalent |
|---|---|---|
| input (uncached) | ~$0.15–0.30 | ~$10 |
| input (cached) | ~$0.003–0.006 | ~$1 |
| output | ~$0.60–1.20 | ~$50 |

A public clone of this idea measured ~$0.26–0.34 spent on the worker per 1,000
implementation+test lines vs ~$11.32 doing the same loop on the frontier model —
roughly a 97–98% drop in *inference* cost, with the subscription carrying only
the bounded plan + review passes.

## What the subscription is used for
- Plan: 1 session per packet → writes `TASK.md`
- Review: 1 session per worker round → runs acceptance, writes `REVIEW.md`
- Escalation: only when the worker fails its round limit

Each of these is a small, bounded transcript. Keeping it bounded is the whole
discipline of the protocol: **the worker self-iterates, so the subscription
never sees mid-work noise.**

## Worker-tier choice
- `deepseek-v4-flash` — default. Advertised as the coding/agentic tier; the
  general recommendation and ~1/3 the output price of `-pro`.
- `deepseek-v4-pro` — for long, mostly-single-thread reasoning chains where you
  expect the worker tier to blow the packet. Set `CONDUCTOR_WORKER_MODEL`.

## Caching lever (the biggest user-controlled saving)
DeepSeek auto-caches request prefixes. The worker is instructed to keep its
task text and key context **byte-identical across a session** so every turn
after the first hits the cached-input price (~50–100× cheaper). Don't wrap
`TASK.md` text in new boilerplate each turn — reuse it verbatim.
`worker/CLAUDE.md` already says this; enforce it manually if you see input
prices creeping back up.

## Subscription-quota budget norms
- Per packet: 1 plan prompt + 1 review prompt (+ possibly 2nd review prompt).
- Per 10 packets: ~10 plans + ~10–20 reviews, all bounded, vs the worker doing
  the thousands of token-heavy turns in between.
- That is the point of the loop: your Pro plan's rate limits effectively stop
  being the bottleneck.

## Warning signs to watch
- **Reviewer redoing chunks** (`REVIEW.md` says ~"rewrote the whole thing").
  That means packets are too big or the worker tier is wrong. Re-scope.
- **Worker missing acceptance repeatedly.** Raise `CONDUCTOR_MAX_ROUNDS`? No —
  escalate and re-plan instead. The loop should *converge or escalate*.
- **Input spend rising without more code.** Verify prompt-cache reuse
  (DeepSeek console shows cache-hit tokens).

## The add-on that defeats the whole model
If the work is 90% *design* (greenfield architecture, novel algorithms), the
packet writer is effectively doing the work and the worker is just typing — the
reviewer will pay for the design twice. Use the loop for mechanical,
verifiable, *existing-convention* work. That is its prime territory.