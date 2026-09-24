# Graphify integration (knowledge-graph navigation)

Graphify maps a codebase into a queryable knowledge graph (code parsed locally
via tree-sitter AST — 0 API calls). Both agents in the claude-astra loop query
the graph instead of grepping + re-reading files, which is where the bulk of
their tokens go. Measured effect: ~82–90% less context per orientation question
(~2k tokens vs ~10–17k reading files).

## What was installed (per project)

| artifact | location | notes |
|---|---|---|
| Skill (orchestrator) | `~/.claude/skills/graphify/` | `/graphify` command + trigger in `~/.claude/CLAUDE.md` |
| Skill (worker) | `~/.claude-deepseek/skills/graphify/` | mirrored so the isolated worker config has it too |
| Graph | `<project>/graphify-out/` | `graph.json` (query), `GRAPH_REPORT.md` (orientation digest), `graph.html` (visual), `graphify-out/` is gitignored |
| Freshness | `<project>/.git/hooks/post-commit` | AST-only `graphify update .` after every commit; outputs gitignored so rebuilds never dirty the tree or disturb handoff commits |
| Worker guidance | `worker/CLAUDE.md` | read `GRAPH_REPORT.md` first; prefer `graphify query` over grep |

## Install on a new project

```bash
# 1. build the baseline graph (offline, code-only, $0)
graphify extract <project> --code-only
graphify cluster-only <project> --no-label     # offline; skip --no-label if you want LLM community names

# 2. install the repo .git/hooks/post-commit (copy from a configured repo)
# 3. append `graphify-out/` to the project .gitignore
```

## Using it in the loop
- `GRAPH_REPORT.md` is the first-read orientation for both planner and worker.
- `graphify query "how does X connect to Y?"` returns a scoped subgraph
  (default ~2k token budget).
- `graphify path A B` traces call/import hops; `graphify explain X` expands one
  node; `graphify god-nodes` lists architectural hubs.
- The graph is a MAP — agents still read the exact files/lines it points to
  before editing.

## Cost & privacy notes
- Code extraction is fully local (tree-sitter). Docs/PDFs/images need a
  semantic LLM pass — do NOT run it on the DeepSeek worker; only on the
  orchestrator (Pro) if you want docs in the graph, or use `--code-only`
  everywhere and keep it $0.
- A post-commit rebuild is AST-only and cheap; large monorepos can raise
  `--node-limit` / run `graphify update . --no-cluster` in CI instead.