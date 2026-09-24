#!/usr/bin/env bash
# claude-astra worker launcher
# Starts an isolated Claude Code session fully routed to DeepSeek's
# Anthropic-compatible endpoint. Never touches your subscription config.

set -Eeuo pipefail

ASTRA_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
ASTRA_CONFIG_DIR="${ASTRA_CONFIG_DIR:-$HOME/.claude-deepseek}"
ASTRA_KEY_FILE="${ASTRA_KEY_FILE:-$ASTRA_CONFIG_DIR/astra.env}"
ASTRA_WORKER_MODEL="${ASTRA_WORKER_MODEL:-deepseek-v4-flash}"

if ! command -v claude >/dev/null 2>&1; then
  echo "error: 'claude' not found on PATH. Install Claude Code first." >&2
  exit 1
fi

PROJECT_DIR="${1:-$PWD}"
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" || {
  echo "error: not a directory: $1" >&2
  exit 1
}

if [[ ! -f "$ASTRA_KEY_FILE" ]]; then
  echo "error: no DeepSeek key found at $ASTRA_KEY_FILE" >&2
  echo "run:  $ASTRA_HOME/worker/setup.sh" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ASTRA_KEY_FILE"
if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
  echo "error: $ASTRA_KEY_FILE must define DEEPSEEK_API_KEY" >&2
  exit 1
fi

TASK_PATH="$PROJECT_DIR/.astra/TASK.md"
if [[ -f "$TASK_PATH" ]]; then
  BOOT="Start by reading .astra/TASK.md in this project, then implement the packet exactly. Follow the claude-astra worker policy you were given at startup."
else
  BOOT="No .astra/TASK.md found. Inspect the project, summarize its state, and wait for instructions."
fi

# --- model + provider pinning (all slots, so nothing silently hits another tier)
export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
export ANTHROPIC_AUTH_TOKEN="$DEEPSEEK_API_KEY"
export ANTHROPIC_MODEL="$ASTRA_WORKER_MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$ASTRA_WORKER_MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$ASTRA_WORKER_MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$ASTRA_WORKER_MODEL"
export CLAUDE_CODE_SUBAGENT_MODEL="$ASTRA_WORKER_MODEL"

# --- isolate from any subscription config + neutralise the known 400 bug
unset ANTHROPIC_API_KEY CLAUDE_CODE_EFFORT_LEVEL ANTHROPIC_CUSTOM_MODEL_OPTION
export CLAUDE_CONFIG_DIR="$ASTRA_CONFIG_DIR"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

cd "$PROJECT_DIR"
echo "---------------- claude-astra worker ----------------"
echo "provider : DeepSeek (Anthropic-compatible)"
echo "model    : $ASTRA_WORKER_MODEL (all slots pinned)"
echo "config   : $CLAUDE_CONFIG_DIR (isolated, subscription untouched)"
echo "project  : $PROJECT_DIR"
echo "-----------------------------------------------------"

exec claude "$BOOT"