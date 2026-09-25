#!/usr/bin/env bash
# claude-conductor offline test suite. Spends no API credit, runs no model session.
# Fakes claude/open/osascript via a stub PATH so nothing real is spawned.
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
CONDUCTOR_HOME="$(cd .. && pwd)"

TMP="$(mktemp -d /tmp/conductor-tests.XXXXXX)"
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
export CONDUCTOR_PROJECT_DIR="$TMP/proj"
export CONDUCTOR_CONFIG_DIR="$TMP/config"
export CONDUCTOR_KEY_FILE="$TMP/config/conductor.env"
export CONDUCTOR_RUN_DIR="$TMP/run"
export CONDUCTOR_POLL_INTERVAL=0

# ---------------------------------------------------------------- syntax
echo "== syntax =="
for f in doctor.sh worker/setup.sh worker/launch.sh drive/orchestrate.sh; do
  check "bash -n $f" bash -n "$CONDUCTOR_HOME/$f"
done

# ---------------------------------------------------------------- setup
echo "== worker/setup.sh =="
mkdir -p "$TMP/proj"
git -C "$TMP/proj" init -q
git -C "$TMP/proj" config user.email t@t
git -C "$TMP/proj" config user.name t
touch "$TMP/proj/a.txt"
git -C "$TMP/proj" add -A && git -C "$TMP/proj" commit -qm init
DEEPSEEK_API_KEY=sk-test-123 bash "$CONDUCTOR_HOME/worker/setup.sh" >/dev/null 2>&1 \
  || bad "setup exit"
check "key file exists" test -f "$CONDUCTOR_CONFIG_DIR/conductor.env"
check "key perms 600" test "$(stat -f '%Lp' "$CONDUCTOR_CONFIG_DIR/conductor.env")" = 600
check "worker policy installed" test -f "$CONDUCTOR_CONFIG_DIR/CLAUDE.md"
grep -q 'sk-test-123' "$CONDUCTOR_CONFIG_DIR/conductor.env" && ok "key content" || bad "key content"

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
bash "$CONDUCTOR_HOME/worker/launch.sh" "$TMP/proj" >/dev/null 2>&1 || true
line() { grep -Fxq "${1}" "$STUB_LOG"; }
check "base url pinned"       line 'ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic'
check "auth token = deepseek" line 'ANTHROPIC_AUTH_TOKEN=sk-test-123'
check "subagent model pinned" line 'CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash'
check "haiku slot pinned"     line 'ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash'
check "isolated config dir"   line "CLAUDE_CONFIG_DIR=$CONDUCTOR_CONFIG_DIR"
grep -q '^CLAUDE_CODE_EFFORT_LEVEL=' "$STUB_LOG" && bad "effort level leaked" || ok "effort level cleared"
grep -q '^ANTHROPIC_API_KEY=' "$STUB_LOG" && bad "subscription key leaked" || ok "subscription key not set"

# ---------------------------------------------------------------- reroute + in-brain review
echo "== drive/orchestrate.sh reroute / in-brain =="
proj2="$TMP/reroute"
mkdir -p "$proj2/.conductor"
export CONDUCTOR_RUN_DIR="$TMP/run2"
mkdir -p "$CONDUCTOR_RUN_DIR"
git -C "$proj2" init -q
git -C "$proj2" config user.email t@t
git -C "$proj2" config user.name t
touch "$proj2/a.txt"
git -C "$proj2" add -A && git -C "$proj2" commit -qm init
printf 'APPROVED\n' > "$proj2/.conductor/REVIEW.md"

CONDUCTOR_PROJECT_DIR="$proj2" bash "$CONDUCTOR_HOME/drive/orchestrate.sh" reroute "task-reroute-1" >/dev/null 2>&1
check "reroute clears REVIEW.md"   test ! -f "$proj2/.conductor/REVIEW.md"
check "reroute clears TASK.md"     test ! -f "$proj2/.conductor/TASK.md"
check "reroute clears evidence"    test ! -f "$proj2/.conductor/EVIDENCE.md"
check "reroute sets phase=plan"    test "$(cat "$proj2/.conductor/PHASE")" = plan
check "reroute sets round=0"       test "$(cat "$proj2/.conductor/ROUND")" = 0
LC_ALL=C grep -q 'task-reroute-1' "$proj2/.conductor/DESC" && ok "reroute writes DESC" || bad "reroute writes DESC"

echo "TASK: reroute packet" > "$proj2/.conductor/TASK.md"
CONDUCTOR_PROJECT_DIR="$proj2" bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "reroute-1 -> working" test "$(cat "$proj2/.conductor/PHASE")" = working

echo "worker reroute work" >> "$proj2/a.txt"
git -C "$proj2" add -A && git -C "$proj2" commit -qm "claude-conductor: r1"
CONDUCTOR_PROJECT_DIR="$proj2" CONDUCTOR_REVIEW_IN_BRAIN=1 bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "in-brain review phase"    test "$(cat "$proj2/.conductor/PHASE")" = review
check "in-brain request flag"    test -f "$proj2/.conductor/REVIEW_REQUESTED"
grep -q 'reviewer/model' "$CONDUCTOR_RUN_DIR"/*.command && bad "in-brain must not open a fresh reviewer window" || ok "in-brain no fresh reviewer window"

printf 'APPROVED\nbrain reviewed\n' > "$proj2/.conductor/REVIEW.md"
rm -f "$proj2/.conductor/REVIEW_REQUESTED"
CONDUCTOR_PROJECT_DIR="$proj2" bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "in-brain review -> approved" test "$(cat "$proj2/.conductor/PHASE")" = approved

CONDUCTOR_PROJECT_DIR="$proj2" bash "$CONDUCTOR_HOME/drive/orchestrate.sh" reset >/dev/null 2>&1
check "reset clears MODE" test ! -f "$proj2/.conductor/MODE"

# ---------------------------------------------------------------- protocol persistence + self-heal
echo "== ROUTER_PROTOCOL write + approved self-heal =="
proj3="$TMP/proto"
mkdir -p "$proj3/.conductor"
export CONDUCTOR_RUN_DIR="$TMP/run3"
mkdir -p "$CONDUCTOR_RUN_DIR"
git -C "$proj3" init -q
git -C "$proj3" config user.email t@t
git -C "$proj3" config user.name t
touch "$proj3/a.txt"
git -C "$proj3" add -A && git -C "$proj3" commit -qm init
CONDUCTOR_PROJECT_DIR="$proj3" bash "$CONDUCTOR_HOME/drive/orchestrate.sh" reroute "proto-pkt" >/dev/null 2>&1
check "reroute writes ROUTER_PROTOCOL.md"  test -f "$proj3/.conductor/ROUTER_PROTOCOL.md"
grep -q 'reroute' "$proj3/.conductor/ROUTER_PROTOCOL.md" && ok "protocol mentions reroute" || bad "protocol mentions reroute"

printf 'APPROVED\nold\n' > "$proj3/.conductor/REVIEW.md"
printf 'approved\n'     > "$proj3/.conductor/PHASE"
sleep 1
printf 'TASK: new packet (newer)\n' > "$proj3/.conductor/TASK.md"
CONDUCTOR_PROJECT_DIR="$proj3" bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "approved + newer TASK -> plan (self-heal)" test "$(cat "$proj3/.conductor/PHASE")" = plan

# ---------------------------------------------------------------- up boot
echo "== drive/orchestrate.sh up =="
mkdir -p "$TMP/newproj"
: > "$STUB_LOG"
CONDUCTOR_PROJECT_DIR="$TMP/newproj" \
  bash "$CONDUCTOR_HOME/drive/orchestrate.sh" up "boot-task-xyz" >/dev/null 2>&1
check "up inits missing repo"     test -d "$TMP/newproj/.git"
check "up creates baseline HEAD"  git -C "$TMP/newproj" rev-parse --verify HEAD >/dev/null 2>&1
check "up ignores .conductor state"   grep -qx '.conductor/' "$TMP/newproj/.gitignore"
check "up sets phase=plan"        test "$(cat "$TMP/newproj/.conductor/PHASE")" = plan
check "up sets round=0"           test "$(cat "$TMP/newproj/.conductor/ROUND")" = 0
LC_ALL=C grep -q 'boot-task-xyz' "$CONDUCTOR_RUN_DIR"/*.command && ok "up passes task to planner" || bad "up passes task to planner"

echo "== drive/orchestrate.sh up (idle, no task) =="
idleproj="$TMP/idleproj"
mkdir -p "$idleproj"
export CONDUCTOR_RUN_DIR="$TMP/run-idle"
mkdir -p "$CONDUCTOR_RUN_DIR"
: > "$STUB_LOG"
CONDUCTOR_PROJECT_DIR="$idleproj" \
  bash "$CONDUCTOR_HOME/drive/orchestrate.sh" up >/dev/null 2>&1
check "idle up inits missing repo" test -d "$idleproj/.git"
check "idle up sets phase=plan"    test "$(cat "$idleproj/.conductor/PHASE")" = plan
check "idle up no TASK.md"         test ! -f "$idleproj/.conductor/TASK.md"
check "idle up no DESC"            test ! -f "$idleproj/.conductor/DESC"
check "idle up writes MODE"        test "$(cat "$idleproj/.conductor/MODE")" = inbrain
check "idle up opens planner"      grep -q 'ROUTER' "$CONDUCTOR_RUN_DIR"/*.command

# ---------------------------------------------------------------- driver loop
echo "== drive/orchestrate.sh loop =="
: > "$STUB_LOG"
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" start "task-abc123" >/dev/null 2>&1
check "phase=plan after start" test "$(cat "$TMP/proj/.conductor/PHASE")" = plan
check "round=0 after start"    test "$(cat "$TMP/proj/.conductor/ROUND")" = 0
LC_ALL=C grep -q 'task-abc123' "$CONDUCTOR_RUN_DIR"/*.command && ok "planner receives task description" || bad "planner receives task description"

bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "no TASK.md -> stay plan" test "$(cat "$TMP/proj/.conductor/PHASE")" = plan

echo "TASK: test packet" > "$TMP/proj/.conductor/TASK.md"
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "TASK.md -> working" test "$(cat "$TMP/proj/.conductor/PHASE")" = working

grep -q 'launch.sh' "$CONDUCTOR_RUN_DIR"/*.command && ok "worker session opened" || bad "worker session opened"

echo "worker work" >> "$TMP/proj/a.txt"
git -C "$TMP/proj" add -A && git -C "$TMP/proj" commit -qm "claude-conductor: round1"
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "commit -> review"      test "$(cat "$TMP/proj/.conductor/PHASE")" = review
grep -q 'reviewer/model' "$CONDUCTOR_RUN_DIR"/*.command && ok "reviewer opened" || bad "reviewer opened"

printf 'ISSUES\n1. high - a.txt:3 - fix it\n' > "$TMP/proj/.conductor/REVIEW.md"
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "issues -> working round1" test "$(cat "$TMP/proj/.conductor/PHASE")" = working
check "round incremented"        test "$(cat "$TMP/proj/.conductor/ROUND")" = 1

echo "worker work 2" >> "$TMP/proj/a.txt"
git -C "$TMP/proj" add -A && git -C "$TMP/proj" commit -qm "claude-conductor: round2"
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "round2 commit -> review" test "$(cat "$TMP/proj/.conductor/PHASE")" = review

printf 'APPROVED\n' > "$TMP/proj/.conductor/REVIEW.md"
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "APPROVED -> approved" test "$(cat "$TMP/proj/.conductor/PHASE")" = approved

# ---------------------------------------------------------------- escalation
: > "$STUB_LOG"
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" start "escalation test" >/dev/null 2>&1
echo "TASK: escal" > "$TMP/proj/.conductor/TASK.md"
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # -> working
git -C "$TMP/proj" add -A && git -C "$TMP/proj" commit -qm r3
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # -> review
printf 'ISSUES\nstill broken\n' > "$TMP/proj/.conductor/REVIEW.md"
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # -> working round1
git -C "$TMP/proj" add -A && git -C "$TMP/proj" commit -qm r4
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # -> review
printf 'ISSUES\nstill broken\n' > "$TMP/proj/.conductor/REVIEW.md"
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # round1+1=2 == MAX -> working
git -C "$TMP/proj" add -A && git -C "$TMP/proj" commit -qm r5
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # -> review
printf 'ISSUES\nstill broken\n' > "$TMP/proj/.conductor/REVIEW.md"
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # round2 -> exceeds MAX -> escalated
check "escalated after 2 rounds" test "$(cat "$TMP/proj/.conductor/PHASE")" = escalated

# ---------------------------------------------------------------- zero-change handoff
echo "== zero-change (verification packet) handoff =="
: > "$STUB_LOG"
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" start "verify zero-change" >/dev/null 2>&1
echo "TASK: verification only, no commits allowed" > "$TMP/proj/.conductor/TASK.md"
sleep 1
echo "accepted" > "$TMP/proj/.conductor/EVIDENCE.md"
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true
check "fresh evidence, no start -> review"     test "$(cat "$TMP/proj/.conductor/PHASE")" = review
grep -q 'reviewer/model' "$CONDUCTOR_RUN_DIR"/*.command && ok "manual worker -> reviewer opened" || bad "manual worker -> reviewer opened"

bash "$CONDUCTOR_HOME/drive/orchestrate.sh" start "zero-change round2" >/dev/null 2>&1
echo "TASK: verify again" > "$TMP/proj/.conductor/TASK.md"
sleep 1
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # no evidence yet -> working
check "no evidence -> working"                 test "$(cat "$TMP/proj/.conductor/PHASE")" = working
touch -t 202001010000 "$TMP/proj/.conductor/EVIDENCE.md"
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # stale evidence -> still working
check "stale evidence -> stays working"        test "$(cat "$TMP/proj/.conductor/PHASE")" = working
sleep 1                                        # ensure EVIDENCE mtime > WORKER_START_COMMIT (-nt is strict)
touch "$TMP/proj/.conductor/EVIDENCE.md"
bash "$CONDUCTOR_HOME/drive/orchestrate.sh" watch --once >/dev/null 2>&1 || true   # fresh evidence, head==start -> review
check "fresh evidence in working -> review"    test "$(cat "$TMP/proj/.conductor/PHASE")" = review

# ---------------------------------------------------------------- summary
echo
printf 'passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]