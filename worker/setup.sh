#!/usr/bin/env bash
# claude-conductor one-time worker setup
# Stores the DeepSeek API key (0600), creates the isolated Claude config dir,
# installs the worker policy, and sanity-checks the endpoint with no inference.

set -Eeuo pipefail

CONDUCTOR_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
CONDUCTOR_CONFIG_DIR="${CONDUCTOR_CONFIG_DIR:-$HOME/.claude-deepseek}"
CONDUCTOR_KEY_FILE="${CONDUCTOR_KEY_FILE:-$CONDUCTOR_CONFIG_DIR/conductor.env}"
CONDUCTOR_WORKER_MODEL="${CONDUCTOR_WORKER_MODEL:-deepseek-v4-flash}"

command -v claude >/dev/null 2>&1 || {
  echo "error: 'claude' not found on PATH. Install Claude Code first." >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || { echo "error: curl required" >&2; exit 1; }

mkdir -p "$CONDUCTOR_CONFIG_DIR"

# key: reuse existing, take env, else prompt silently
DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
if [[ -n "$DEEPSEEK_API_KEY" ]]; then
  :
elif [[ -f "$CONDUCTOR_KEY_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONDUCTOR_KEY_FILE"
fi
if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
  printf 'Paste your DeepSeek API key (sk-...): '
  read -r -s KEY
  echo
  [[ -n "${KEY:-}" ]] || { echo "error: empty key" >&2; exit 1; }
  DEEPSEEK_API_KEY="$KEY"
fi

umask 177
printf 'DEEPSEEK_API_KEY=%s\n' "$DEEPSEEK_API_KEY" > "$CONDUCTOR_KEY_FILE"
chmod 600 "$CONDUCTOR_KEY_FILE"

# install worker policy as the isolated config's global memory
install -m 600 "$CONDUCTOR_HOME/worker/CLAUDE.md" "$CONDUCTOR_CONFIG_DIR/CLAUDE.md"

echo "key stored : $CONDUCTOR_KEY_FILE (chmod 600)"
echo "worker cfg : $CONDUCTOR_CONFIG_DIR/CLAUDE.md"
echo "worker model: $CONDUCTOR_WORKER_MODEL"

# auth-only check (no inference, no cost); best-effort
if curl -fsS --max-time 15 "https://api.deepseek.com/user/balance" \
     -H "Authorization: Bearer $DEEPSEEK_API_KEY" >/dev/null 2>&1; then
  echo "endpoint   : OK (key accepted by DeepSeek)"
else
  echo "WARNING    : DeepSeek /user/balance refused the key (offline? revoked? network?)."
  echo "             launch.sh will still let you try — but fix the key first."
fi

echo
echo "Next: in any project run:  drive/orchestrate.sh start \"<task description>\""
echo "Then keep   :  drive/orchestrate.sh watch   running in a background terminal."