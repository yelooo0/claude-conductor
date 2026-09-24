#!/usr/bin/env bash
# claude-astra offline test suite. Spends no API credit, runs no model session.
# Fakes claude/open/osascript via a stub PATH so nothing real is spawned.
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
ASTRA_HOME="$(cd .. && pwd)"

TMP="$(mktemp -d /tmp/astra-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { # check <name> <cmd...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}

# ---------------------------------------------------------------- stubs
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude-args=%s\n' "$*" >> "$STUB_LOG"
exit 0
EOF
cat > "$TMP/bin/open" <<'EOF'
#!/usr/bin/env bash
printf 'open=%s\n' "$*" >> "$STUB_LOG"
exit 0
EOF
cat > "$TMP/bin/osascript" <<'EOF'
#!/usr/bin/env bash
printf 'osascript=%s\n' "$1" >> "$STUB_LOG"
exit 0
EOF
chmod +x "$TMP"/bin/*

export PATH="$TMP/bin:$PATH"
export STUB_LOG="$TMP/stub.log"
export ASTRA_PROJECT_DIR="$TMP/proj"
export ASTRA_CONFIG_DIR="$TMP/config"
export ASTRA_KEY_FILE="$TMP/config/astra.env"
export ASTRA_RUN_DIR="$TMP/run"
export ASTRA_POLL_INTERVAL=0

# ---------------------------------------------------------------- syntax
echo "== syntax =="
for f in doctor.sh worker/setup.sh worker/launch.sh drive/orchestrate.sh; do
  check "bash -n $f" bash -n "$ASTRA_HOME/$f"
done

# ---------------------------------------------------------------- setup
echo "== worker/setup.sh =="
mkdir -p "$TMP/proj"
git -C "$TMP/proj" init -q
git -C "$TMP/proj" config user.email t@t
git -C "$TMP/proj" config user.name t
touch "$TMP/proj/a.txt"
git -C "$TMP/proj" add -A && git -C "$TMP/proj" commit -qm init
DEEPSEEK_API_KEY=sk-test-123 bash "$ASTRA_HOME/worker/setup.sh" >/dev/null 2>&1 \
  || bad "setup exit"
check "key file exists" test -f "$ASTRA_CONFIG_DIR/astra.env"
check "key perms 600" test "$(stat -f '%Lp' "$ASTRA_CONFIG_DIR/astra.env")" = 600
check "worker policy installed" test -f "$ASTRA_CONFIG_DIR/CLAUDE.md"
grep -q 'sk-test-123' "$ASTRA_CONFIG_DIR/astra.env" && ok "key content" || bad "key content"

# ---------------------------------------------------------------- launch isolation
echo "== worker/launch.sh env isolation =="
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
env | grep -E '^(ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_MODEL|ANTHROPIC_DEFAULT_HAIKU_MODEL|CLAUDE_CODE_SUBAGENT_MODEL|CLAUDE_CONFIG_DIR|CLAUDE_CODE_EFFORT_LEVEL|ANTHROPIC_API_KEY)=' >> "$STUB_LOG"
printf 'claude-args=%s\n' "$*" >> "$STUB_LOG"
exit 0
EOF
chmod +x "$TMP/bin/claude"

: > "$STUB_LOG"
bash "$ASTRA_HOME/worker/launch.sh" "$TMP/proj" >/dev/null 2>&1 || true
line() { grep -Fxq "${1}" "$STUB_LOG"; }
check "base url pinned"       line 'ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic'
check "auth token = deepseek" line 'ANTHROPIC_AUTH_TOKEN=sk-test-123'
check "subagent model pinned" line 'CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash'
check "haiku slot pinned"     line 'ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash'
check "isolated config dir"   line "CLAUDE_CONFIG_DIR=$ASTRA_CONFIG_DIR"
grep -q '^CLAUDE_CODE_EFFORT_LEVEL=' "$STUB_LOG" && bad "effort level leaked" || ok "effort level cleared"
grep -q '^ANTHROPIC_API_KEY=' "$STUB_LOG" && bad "subscription key leaked" || ok "subscription key not set"

# ---------------------------------------------------------------- driver loop
echo "== drive/orchestrate.sh loop =="
: > "$STUB_LOG"
bash "$ASTRA_HOME/drive/orchestrate.sh" start "test task" >/dev/null 2>&1
check "phase=plan after start" test "$(cat "$TMP/proj/.astra/PHASE")" = plan
check "round=0 after start"    test "$(cat "$TMP/proj/.astra/ROUND")" = 0

bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "no TASK.md -> stay plan" test "$(cat "$TMP/proj/.astra/PHASE")" = plan

echo "TASK: test packet" > "$TMP/proj/.astra/TASK.md"
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "TASK.md -> working" test "$(cat "$TMP/proj/.astra/PHASE")" = working

grep -q 'launch.sh' "$ASTRA_RUN_DIR"/*.command && ok "worker session opened" || bad "worker session opened"

echo "worker work" >> "$TMP/proj/a.txt"
git -C "$TMP/proj" add -A && git -C "$TMP/proj" commit -qm "claude-astra: round1"
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "commit -> review"      test "$(cat "$TMP/proj/.astra/PHASE")" = review
grep -q 'reviewer/model' "$ASTRA_RUN_DIR"/*.command && ok "reviewer opened" || bad "reviewer opened"

printf 'ISSUES\n1. high - a.txt:3 - fix it\n' > "$TMP/proj/.astra/REVIEW.md"
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "issues -> working round1" test "$(cat "$TMP/proj/.astra/PHASE")" = working
check "round incremented"        test "$(cat "$TMP/proj/.astra/ROUND")" = 1

echo "worker work 2" >> "$TMP/proj/a.txt"
git -C "$TMP/proj" add -A && git -C "$TMP/proj" commit -qm "claude-astra: round2"
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "round2 commit -> review" test "$(cat "$TMP/proj/.astra/PHASE")" = review

printf 'APPROVED\n' > "$TMP/proj/.astra/REVIEW.md"
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "APPROVED -> approved" test "$(cat "$TMP/proj/.astra/PHASE")" = approved

# ---------------------------------------------------------------- escalation
: > "$STUB_LOG"
bash "$ASTRA_HOME/drive/orchestrate.sh" start "escalation test" >/dev/null 2>&1
echo "TASK: escal" > "$TMP/proj/.astra/TASK.md"
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # -> working
git -C "$TMP/proj" add -A && git -C "$TMP/proj" commit -qm r3
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # -> review
printf 'ISSUES\nstill broken\n' > "$TMP/proj/.astra/REVIEW.md"
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # -> working round1
git -C "$TMP/proj" add -A && git -C "$TMP/proj" commit -qm r4
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # -> review
printf 'ISSUES\nstill broken\n' > "$TMP/proj/.astra/REVIEW.md"
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # round1+1=2 == MAX -> working
git -C "$TMP/proj" add -A && git -C "$TMP/proj" commit -qm r5
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # -> review
printf 'ISSUES\nstill broken\n' > "$TMP/proj/.astra/REVIEW.md"
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # round2 -> exceeds MAX -> escalated
check "escalated after 2 rounds" test "$(cat "$TMP/proj/.astra/PHASE")" = escalated

# ---------------------------------------------------------------- zero-change handoff
echo "== zero-change (verification packet) handoff =="
: > "$STUB_LOG"
bash "$ASTRA_HOME/drive/orchestrate.sh" start "verify zero-change" >/dev/null 2>&1
echo "TASK: verification only, no commits allowed" > "$TMP/proj/.astra/TASK.md"
sleep 1
echo "accepted" > "$TMP/proj/.astra/EVIDENCE.md"
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "fresh evidence, no start -> review"     test "$(cat "$TMP/proj/.astra/PHASE")" = review
grep -q 'reviewer/model' "$ASTRA_RUN_DIR"/*.command && ok "manual worker -> reviewer opened" || bad "manual worker -> reviewer opened"

bash "$ASTRA_HOME/drive/orchestrate.sh" start "zero-change round2" >/dev/null 2>&1
echo "TASK: verify again" > "$TMP/proj/.astra/TASK.md"
sleep 1
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # no evidence yet -> working
check "no evidence -> working"                 test "$(cat "$TMP/proj/.astra/PHASE")" = working
touch -t 202001010000 "$TMP/proj/.astra/EVIDENCE.md"
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # stale evidence -> still working
check "stale evidence -> stays working"        test "$(cat "$TMP/proj/.astra/PHASE")" = working
sleep 1                                        # ensure EVIDENCE mtime > WORKER_START_COMMIT (-nt is strict)
touch "$TMP/proj/.astra/EVIDENCE.md"
bash "$ASTRA_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # fresh evidence, head==start -> review
check "fresh evidence in working -> review"    test "$(cat "$TMP/proj/.astra/PHASE")" = review

# ---------------------------------------------------------------- summary
echo
printf 'passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]