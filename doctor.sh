#!/usr/bin/env bash
# claude-astra doctor : verify local setup without spending any API credit.
set -Eeuo pipefail

ASTRA_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ASTRA_CONFIG_DIR="${ASTRA_CONFIG_DIR:-$HOME/.claude-deepseek}"
ASTRA_KEY_FILE="${ASTRA_KEY_FILE:-$ASTRA_CONFIG_DIR/astra.env}"
WORKER_MODEL="${ASTRA_WORKER_MODEL:-deepseek-v4-flash}"

ok=0; bad=0
pass() { ok=$((ok+1)); printf '  ✔ %s\n' "$1"; }
fail() { bad=$((bad+1)); printf '  ✘ %s\n' "$1"; }

echo "[1/6] Claude CLI (orchestrator = your Claude Pro subscription)"
if command -v claude >/dev/null 2>&1; then
  pass "claude found: $(command -v claude)"
  ver="$(claude --version 2>/dev/null || true)"
  echo "  version: ${ver:-unknown}"
  if [[ "$ver" =~ ^2\.1\.(16[6-9]|1[7-9][0-9]) ]]; then
    echo "  NOTE: Claude Code >=2.1.166 has a known 400 bug against DeepSeek subagent"
    echo "        requests. launcher.sh mitigates it; pin to a known-good CLI version"
    echo "        (npm i -g @anthropic-ai/claude-code@<known-good>) if you hit 400s."
  fi
else
  fail "claude not on PATH — install Claude Code and sign in with your Pro plan"
fi

echo "[2/6] DeepSeek worker key"
if [[ -f "$ASTRA_KEY_FILE" ]]; then
  mode="$(stat -f '%Lp' "$ASTRA_KEY_FILE" 2>/dev/null || ls -l "$ASTRA_KEY_FILE" | awk '{print $1}')"
  if [[ "$mode" != "600" && "$mode" != "-rw-------" ]]; then
    fail "astra.env permissions are $mode (want 600): chmod 600 \"$ASTRA_KEY_FILE\""
  else
    pass "key file permissions ok ($mode)"
  fi
  # shellcheck disable=SC1090
  source "$ASTRA_KEY_FILE"
  [[ -n "${DEEPSEEK_API_KEY:-}" ]] && pass "DEEPSEEK_API_KEY set" || fail "astra.env has no DEEPSEEK_API_KEY"
else
  fail "no key at $ASTRA_KEY_FILE — run worker/setup.sh"
fi

echo "[3/6] Worker isolation"
if [[ "$ASTRA_CONFIG_DIR" == "$HOME/.claude" ]]; then
  fail "ASTRA_CONFIG_DIR collides with your subscription config ($ASTRA_CONFIG_DIR)"
else
  pass "isolated config dir: $ASTRA_CONFIG_DIR"
fi
if [[ -f "$ASTRA_CONFIG_DIR/CLAUDE.md" ]]; then
  pass "worker policy installed at $ASTRA_CONFIG_DIR/CLAUDE.md"
else
  fail "worker policy missing — run worker/setup.sh"
fi

echo "[4/6] DeepSeek endpoint (no inference)"
if command -v curl >/dev/null 2>&1 && [[ -n "${DEEPSEEK_API_KEY:-}" ]]; then
  if curl -fsS --max-time 15 "https://api.deepseek.com/user/balance" \
       -H "Authorization: Bearer $DEEPSEEK_API_KEY" >/dev/null 2>&1; then
    pass "endpoint reachable, key accepted"
  else
    fail "endpoint/key not accepted (offline? revoked?)"
  fi
else
  fail "curl missing or no key to test"
fi

echo "[5/6] git (required by the handoff driver)"
if command -v git >/dev/null 2>&1; then pass "git found"; else fail "git missing"; fi

echo "[6/6] target project"
PROJECT_DIR="${ASTRA_PROJECT_DIR:-$PWD}"
if [[ -d "$PROJECT_DIR" ]]; then
  pass "project dir exists: $PROJECT_DIR"
  git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && pass "project is a git repo" || fail "project is NOT a git repo (driver needs this)"
else
  fail "project dir missing: $PROJECT_DIR"
fi

echo
printf 'result: %d ok, %d problems\n' "$ok" "$bad"
[[ "$bad" -eq 0 ]]