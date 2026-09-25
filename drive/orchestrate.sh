#!/usr/bin/env bash
# claude-conductor handoff driver
#
# Coordinates the Plan -> Worker -> Review loop across two separate Claude Code
# sessions (Claude Pro subscribion plans/reviews, DeepSeek API implements).
#
# The driver is a hand-off switchboard: it decides WHICH session should run and
# opens it in a fresh Terminal window; the human does the thinking in each one.

set -Eeuo pipefail

CONDUCTOR_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
CONDUCTOR_RUN_DIR="${CONDUCTOR_RUN_DIR:-$HOME/.claude-conductor}"
CONDUCTOR_MAX_ROUNDS="${CONDUCTOR_MAX_ROUNDS:-2}"
CONDUCTOR_POLL_INTERVAL="${CONDUCTOR_POLL_INTERVAL:-3}"
CONDUCTOR_NOTIFICATIONS="${CONDUCTOR_NOTIFICATIONS:-1}"
CONDUCTOR_PROJECT_DIR="${CONDUCTOR_PROJECT_DIR:-$PWD}"
CONDUCTOR_REVIEW_IN_BRAIN="${CONDUCTOR_REVIEW_IN_BRAIN:-0}"

PROJECT_DIR="$(cd "$CONDUCTOR_PROJECT_DIR" 2>/dev/null && pwd)" || die "not a directory: $CONDUCTOR_PROJECT_DIR"
STATE_DIR="$PROJECT_DIR/.conductor"
PHASE_FILE="$STATE_DIR/PHASE"
ROUND_FILE="$STATE_DIR/ROUND"
START_COMMIT_FILE="$STATE_DIR/WORKER_START_COMMIT"

mkdir -p "$STATE_DIR" "$CONDUCTOR_RUN_DIR"

# ---------------------------------------------------------------- helpers
die() { echo "error: $*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

phase()      { [[ -f "$PHASE_FILE" ]] && cat "$PHASE_FILE" || echo "none"; }
set_phase()  { printf '%s\n' "$1" > "$PHASE_FILE"; }
round()      { [[ -f "$ROUND_FILE" ]] && cat "$ROUND_FILE" || echo 0; }
set_round()  { printf '%s\n' "$1" > "$ROUND_FILE"; }

start_commit() { [[ -f "$START_COMMIT_FILE" ]] && cat "$START_COMMIT_FILE" || echo ""; }

require_git() {
  command -v git >/dev/null 2>&1 || die "git is required"
  git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 \
    || die "$PROJECT_DIR is not a git repository (claude-conductor needs git commits to detect handoffs)"
}

notify() {
  [[ "$CONDUCTOR_NOTIFICATIONS" == "0" ]] && return 0
  has osascript || return 0
  osascript -e "display notification \"$2\" with title \"claude-conductor: $1\"" >/dev/null 2>&1 || true
}

# require_claude : die clearly if the subscription CLI is missing
require_claude() {
  command -v claude >/dev/null 2>&1 \
    || die "'claude' not found on PATH — the orchestrator session needs Claude Code (Claude Pro subscription)"
  command -v claude
}

# spawn_terminal <label> <cmd...> : writes a self-launching .command and opens it
spawn_terminal() {
  local label="$1"; shift
  local f="$CONDUCTOR_RUN_DIR/conductor-$label-$(date +%Y%m%d-%H%M%S)-$RANDOM.command"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' "$(printf '%q ' cd "$PROJECT_DIR")"
    printf '%s\n' "$(printf '%q ' exec "$@")"
  } > "$f"
  chmod +x "$f"
  if has open; then
    open -a Terminal "$f" >/dev/null 2>&1 \
      || echo "spawn: cd $PROJECT_DIR && $(printf '%q ' exec "$@")"
  else
    echo "spawn: cd $PROJECT_DIR && $(printf '%q ' exec "$@")"
  fi
}

worker_cmd() {
  spawn_terminal "worker" "$CONDUCTOR_HOME/worker/launch.sh" "$PROJECT_DIR"
}

# write_router_protocol : persist the ROUTER protocol to disk so the brain can
# re-read it after a /compact (compaction drops the seed's step-by-step detail).
write_router_protocol() {
  local DRIVER="$CONDUCTOR_HOME/drive/orchestrate.sh"
  cat > "$STATE_DIR/ROUTER_PROTOCOL.md" <<EOF
# claude-conductor ROUTER protocol — source of truth

You are claude-conductor ROUTER: the single Claude Pro session of a two-model loop.
A cheaper DeepSeek model (deepseek-v4-flash, the "worker") implements changes;
the coordinator ($DRIVER watch) drives handoffs by watching .conductor/ files and git commits.

PROTOCOL FOR EVERY USER MESSAGE:
1. If .conductor/REVIEW_REQUESTED exists -> REVIEW first (STEP R). Then handle any new task in that same message.
2. Else if phase (read .conductor/PHASE) is "working" or "review" -> a packet is in flight. Tell the user a worker session is running and to wait. Do NOT queue a second packet.
3. Otherwise the user is giving you a NEW TASK -> PLAN a packet (STEP P). Never implement it yourself.

STEP P (plan a packet for a new task):
- Explore the repo yourself; never ask the user to paste context.
- Derive ONE small, mechanically verifiable change. If too big or underspecified, write a packet whose Constraints section says how to split it, then ask the user to confirm - never guess.
- Follow the packet template in orchestrator/templates/TASK.md: Objective, Scope (exact files/imports/signatures), Acceptance commands with expected outcomes, Constraints, reviewer success criteria. Explicit out-of-scope. No ambiguity left to infer.
- FIRST clear the previous packet's state and set phase=plan: run: $DRIVER reroute "<one-line task title>". THEN write the new packet to .conductor/TASK.md. Order matters: reroute removes any stale TASK.md; write the new one only after so the coordinator hands off the fresh packet (never a stale previous packet).
- Tell the user the packet is queued and the cheap worker will implement it. Do NOT implement anything in this session.

STEP R (review - only when .conductor/REVIEW_REQUESTED exists):
- Read .conductor/TASK.md, .conductor/EVIDENCE.md, git diff (plus git status for untracked files).
- RUN the acceptance commands from TASK.md yourself, in the repo.
- rm -f .conductor/REVIEW_REQUESTED, then write .conductor/REVIEW.md. First line must be APPROVED or ISSUES (numbered, severity + file:line + concrete fix). APPROVED only if every acceptance check passes AND the diff genuinely implements the packet. Add a Notes section if scope drifted. Do NOT edit code yourself.

Never invent facts or edge cases. Never skip the acceptance checks. Keep ONE packet in flight at a time.
EOF
}

planner_seed() {
  local desc="${1:-}"
  local DRIVER="$CONDUCTOR_HOME/drive/orchestrate.sh"
  local seed
  seed="You are claude-conductor ROUTER — the single Claude Pro session of a two-model loop. A cheaper DeepSeek model (deepseek-v4-flash, the \"worker\") implements the changes; the coordinator ($DRIVER watch, already running in another window) drives handoffs by watching .conductor/ files and git commits.

Your complete protocol lives in .conductor/ROUTER_PROTOCOL.md. Read it now and follow it for every message. After any /compact, RE-READ .conductor/ROUTER_PROTOCOL.md before acting — compaction drops the detailed step-by-step rules, and the file is the source of truth. The two most commonly forgotten rules:
1. In STEP P, you MUST run '$DRIVER reroute \"<task>\"' FIRST (it resets phase=plan and clears stale TASK.md), and only THEN write the new .conductor/TASK.md. Skipping reroute leaves phase=approved and the worker never spawns.
2. Reviews happen only when .conductor/REVIEW_REQUESTED exists — if you are reviewing, write .conductor/REVIEW.md and rm .conductor/REVIEW_REQUESTED. Never touch code.

Never implement anything yourself. Never edit code. Keep ONE packet in flight at a time."
  [[ -n "$desc" ]] && seed="$seed

The user's requested task for this packet is:
$desc"
  spawn_terminal "planner" "$(require_claude)" "$seed"
}

reviewer_seed() {
  local seed
  seed='You are the claude-conductor reviewer/model, the final gate in a two-agent orchestration loop. Context: a DeepSeek worker (lower-cost model) implemented .conductor/TASK.md. Its changes are either committed on HEAD or sit as an uncommitted working-tree diff (verification packets forbid commits) — read the diff (git diff, plus git status for untracked files). Verify it yourself: read the diff, read .conductor/EVIDENCE.md, and RUN the acceptance commands from TASK.md (tests/lint/build) in the repo. Then write .conductor/REVIEW.md. First line must be APPROVED or ISSUES. APPROVED only if every acceptance check passes AND the diff genuinely implements the packet. ISSUES: numbered, one fix per issue, severity + file:line + the concrete expected fix; the worker fixes exactly those and nothing else. Do NOT edit code yourself. Finish with a Notes for Planner section on anything mis-scoped so the next packet is better. Keep it one batched review pass — no back-and-forth polling.'
  spawn_terminal "reviewer" "$(require_claude)" "$seed"
}

# review_handoff : decide whether review lands in the brain session (REVIEW_REQUESTED
# flag the ROUTER seed watches for) or in a fresh reviewer window.
review_handoff() {
  local why="$1"
  if [[ "$CONDUCTOR_REVIEW_IN_BRAIN" == "1" ]] || [[ -f "$STATE_DIR/MODE" && "$(cat "$STATE_DIR/MODE")" == "inbrain" ]]; then
    touch "$STATE_DIR/REVIEW_REQUESTED"
    set_phase review
    notify "Review" "Worker done ($why). Send any message in the BRAIN session to review this packet."
  else
    set_phase review
    notify "Reviewer" "$why. Switching back to Claude Pro review."
    reviewer_seed
  fi
}

# ---------------------------------------------------------------- transitions
record_start_commit() { git -C "$PROJECT_DIR" rev-parse HEAD > "$START_COMMIT_FILE"; }

transition() {
  local current r round_ wanted
  current="$(phase)"

  case "$current" in
    plan)
      [[ -f "$STATE_DIR/TASK.md" ]] || return 0
      # If the worker was launched manually (worker/launch.sh) and already
      # finished a zero-change packet (e.g. a verification packet that forbids
      # commits), fresh EVIDENCE.md with no recorded start means the handoff
      # happened without us: skip the worker and go straight to review.
      if [[ -z "$(start_commit)" \
            && -f "$STATE_DIR/EVIDENCE.md" \
            && "$STATE_DIR/EVIDENCE.md" -nt "$STATE_DIR/TASK.md" ]]; then
        review_handoff "Worker delivered a zero-change packet (no commit)."
        return 0
      fi
      set_phase working
      record_start_commit
      notify "Worker" "Packet ready. Switching to DeepSeek worker."
      worker_cmd
      ;;
    working)
      require_git
      [[ -n "$(start_commit)" ]] || { set_phase plan; return 0; }
      local head
      head="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
      if [[ "$head" == "$(start_commit)" ]]; then
        # No new commit: the worker can still finish a packet without one
        # (verification packets forbid commits). EVIDENCE.md written after the
        # worker started is the zero-change completion signal.
        if [[ -f "$STATE_DIR/EVIDENCE.md" \
              && "$STATE_DIR/EVIDENCE.md" -nt "$START_COMMIT_FILE" ]]; then
          review_handoff "Worker finished a zero-change packet (no commit)."
        fi
        return 0
      fi
      review_handoff "Worker committed."
      ;;
    review)
      [[ -f "$STATE_DIR/REVIEW.md" ]] || return 0
      if grep -qiE '^[[:space:]]*approved' "$STATE_DIR/REVIEW.md"; then
        set_phase approved
        notify "Done" "Packet approved. Closing loop."
        return 0
      fi
      round_="$(round)"
      r=$((round_ + 1))
      set_round "$r"
      if (( r > CONDUCTOR_MAX_ROUNDS )); then
        set_phase escalated
        notify "Escalated" "Worker failed ${CONDUCTOR_MAX_ROUNDS} rounds. Planner takes over this packet."
        local seed='claude-conductor: this packet exceeded the worker round limit. Take it over directly. Read .conductor/TASK.md and .conductor/REVIEW.md, then implement and finish it yourself using Claude Pro.'
        spawn_terminal "escalate" "$(require_claude)" "$seed"
      else
        rm -f "$STATE_DIR/REVIEW.md"
        set_phase working
        record_start_commit
        notify "Worker" "Review feedback round $r. Switching back to DeepSeek worker."
        worker_cmd
      fi
      ;;
    none|escalated)
      return 0
      ;;
    approved)
      # Self-heal: if a TASK.md is NEWER than the approved REVIEW.md, the brain
      # wrote a new packet but forgot to reroute (common after /compact). Treat
      # it as a fresh plan-phase packet instead of silently idling.
      if [[ -f "$STATE_DIR/TASK.md" && -f "$STATE_DIR/REVIEW.md" \
            && "$STATE_DIR/TASK.md" -nt "$STATE_DIR/REVIEW.md" ]]; then
        set_phase plan
        notify "Plan" "Detected a new TASK.md after approval (brain likely forgot reroute). Back to plan."
      fi
      return 0
      ;;
  esac
}

# ---------------------------------------------------------------- commands
cmd_status() {
  printf 'project : %s\n' "$PROJECT_DIR"
  printf 'phase   : %s\n' "$(phase)"
  printf 'round   : %s/%s\n' "$(round)" "$CONDUCTOR_MAX_ROUNDS"
  local tsk="$STATE_DIR/TASK.md" rvw="$STATE_DIR/REVIEW.md"
  [[ -f "$tsk" ]] && printf 'task    : %s\n' "$(head -c 80 "$tsk")" || true
  [[ -f "$rvw" ]] && printf 'review  : present (%s)\n' "$(head -c 40 "$rvw")" || true
  [[ -f "$START_COMMIT_FILE" ]] && printf 'worker  : started at %s\n' "$(start_commit)" || true
  return 0
}

cmd_start() {
  local desc="$*"
  [[ -n "$desc" ]] || die "usage: orchestrate.sh start \"<task description>\""
  rm -f "$STATE_DIR/TASK.md" "$STATE_DIR/REVIEW.md" "$START_COMMIT_FILE" "$STATE_DIR/EVIDENCE.md" "$STATE_DIR/REVIEW_REQUESTED"
  set_round 0
  set_phase plan
  printf '%s\n' "$desc" > "$STATE_DIR/DESC"
  notify "Planner" "New packet requested. Claude Pro session opening to write TASK.md."
  planner_seed "$desc"
  echo "phase=plan. Planner window opened -> write .conductor/TASK.md, then run:  orchestrate.sh watch"
  echo "tip: use 'up' instead to auto-start the planner AND coordinator in one command."
}

cmd_watch() {
  local once=0 not_none=1
  [[ "${1:-}" == "--once" ]] && once=1
  echo $$ > "$STATE_DIR/WATCHER_PID"
  trap 'rm -f "$STATE_DIR/WATCHER_PID"' EXIT
  if [[ "$(phase)" == "plan" ]]; then
    echo "watching from phase=plan (waiting for TASK.md) ..."
  else
    echo "watching from phase=$(phase) ..."
  fi
  while :; do
    transition
    local p
    p="$(phase)"
    case "$p" in
      approved)  echo "packet approved. run: orchestrate.sh up \"<next packet>\""; [[ "$once" == 1 ]] && return 0 ;;
      escalated) echo "packet escalated to planner. begin next packet when done.";        [[ "$once" == 1 ]] && return 0 ;;
      none)      if [[ "$not_none" == 1 ]]; then
                   echo "no active packet. run: orchestrate.sh up \"<task>\""
                   not_none=0
                 fi
                 [[ "$once" == 1 ]] && return 0 ;;
      *)         not_none=1 ;;
    esac
    [[ "$once" == 1 ]] && break
    sleep "$CONDUCTOR_POLL_INTERVAL"
  done
  cmd_status
}

cmd_approve() {
  printf 'APPROVED\nmanual approve\n' > "$STATE_DIR/REVIEW.md"
  set_phase approved
  echo "marked approved."
}

cmd_reroute() {
  local desc="$*"
  [[ -n "$desc" ]] || die "usage: orchestrate.sh reroute \"<task description>\""

  case "$(phase)" in
    working|review)
      die "a packet is in flight (phase=$(phase)). Let the current loop finish before rerouting."
      ;;
  esac

  rm -f "$STATE_DIR/TASK.md" "$STATE_DIR/REVIEW.md" "$STATE_DIR/WORKER_START_COMMIT" "$STATE_DIR/EVIDENCE.md" "$STATE_DIR/REVIEW_REQUESTED"
  set_round 0
  set_phase plan
  write_router_protocol
  printf '%s\n' "$desc" > "$STATE_DIR/DESC"
  notify "Planner" "New packet via brain session. Waiting for TASK.md."
  echo "phase=plan. Brain session should now write .conductor/TASK.md."
  echo "coordinator (watch) is already running - it will hand off to the worker automatically."
}

cmd_reset() {
  rm -f "$STATE_DIR/TASK.md" "$STATE_DIR/REVIEW.md" "$STATE_DIR/WORKER_START_COMMIT" "$STATE_DIR/DESC" "$STATE_DIR/EVIDENCE.md" "$STATE_DIR/REVIEW_REQUESTED" "$STATE_DIR/MODE"
  set_round 0
  set_phase none
  echo "state reset."
}

cmd_up() {
  local desc="$*"
  # Safety: never auto-init a repo over the home directory (or /) — `up` commits
  # a baseline and would sweep the whole home folder into a new git repo.
  if [[ "$PROJECT_DIR" == "$HOME" || "$PROJECT_DIR" == "/" ]]; then
    die "refusing to run in $PROJECT_DIR. cd into a project folder first."
  fi
  if [[ -n "$desc" ]]; then
    # With a task: start a fresh packet (same reset semantics as `start`).
    # Without one: keep the project idle — the brain waits for your first prompt
    # and the coordinator idles until a packet appears.
    [[ "$(phase)" == "working" ]] && die "a packet is in flight (phase=working). Let it finish or reset first."
  else
    [[ "$(phase)" == "working" || "$(phase)" == "review" ]] \
      && die "a packet is in flight (phase=$(phase)). Let it finish or reset before rebooting."
  fi

  # 1. Boot: the loop hands off through git commits, so the project must be a
  #    repo with a commit before anything runs. Initialize + baseline if needed.
  local initialized=0
  if ! git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$PROJECT_DIR" init -q
    initialized=1
  fi
  require_git
  if ! git -C "$PROJECT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$PROJECT_DIR" config user.email >/dev/null 2>&1 \
      || git -C "$PROJECT_DIR" config user.email conductor@local
    git -C "$PROJECT_DIR" config user.name  >/dev/null 2>&1 \
      || git -C "$PROJECT_DIR" config user.name claude-conductor
    if ! grep -qx '.conductor/' "$PROJECT_DIR/.gitignore" 2>/dev/null; then
      printf '\n# claude-conductor handoff state\n.conductor/\n' >> "$PROJECT_DIR/.gitignore"
    fi
    git -C "$PROJECT_DIR" add -A
    git -C "$PROJECT_DIR" commit -q --allow-empty -m "claude-conductor: baseline commit"
    [[ "$initialized" == 1 ]] && echo "boot: git repo initialized + baseline commit created"
  fi

  # 2. Persist brain-review mode (this project reviews back in the ROUTER session).
  printf '%s\n' "inbrain" > "$STATE_DIR/MODE"
  write_router_protocol

  # 3. Open the brain if no session is planning yet. Only start a packet when a
  #    task was given; otherwise idle at plan phase, waiting for the brain.
  if [[ -n "$desc" ]]; then
    cmd_start "$desc"
  else
    if [[ "$(phase)" != "plan" ]]; then
      rm -f "$STATE_DIR/TASK.md" "$STATE_DIR/REVIEW.md" "$START_COMMIT_FILE" "$STATE_DIR/EVIDENCE.md" "$STATE_DIR/REVIEW_REQUESTED"
      set_round 0
      set_phase plan
      notify "Planner" "Idle boot complete. Prompt the brain whenever ready."
      planner_seed ""
      echo "idle boot done. Brain window opened, waiting for your first prompt."
    else
      echo "brain already planning. Give it a task (e.g. orchestrate.sh up \"do X\") or reset."
    fi
  fi

  # 4. Attach a coordinator in its own window unless one is already watching.
  local wp="$STATE_DIR/WATCHER_PID" alive=0
  if [[ -f "$wp" ]] && kill -0 "$(cat "$wp")" 2>/dev/null; then
    alive=1
  fi
  if [[ "$alive" == 1 ]]; then
    echo "coordinator already running (pid $(cat "$wp"))."
  else
    spawn_terminal "watch" env CONDUCTOR_PROJECT_DIR="$PROJECT_DIR" CONDUCTOR_REVIEW_IN_BRAIN=1 \
      "$CONDUCTOR_HOME/drive/orchestrate.sh" "watch"
    echo "coordinator window opened - it will drive worker/reviewer handoffs and notify you."
  fi
}

cmd_help() {
  cat <<'EOF'
claude-conductor handoff driver

USAGE:
  orchestrate.sh up "<task description>"      BOOT with a task (planner + coordinator)
  orchestrate.sh up                           BOOT idle (brain + coordinator, waits for a prompt)
  orchestrate.sh start "<task description>"   begin a packet (opens planner)
  orchestrate.sh reroute "<task description>" reset to plan from the brain session (no new window)
  orchestrate.sh watch [--once]               watch for handoffs and open sessions
  orchestrate.sh status                       show current phase / round
  orchestrate.sh approve                      approve the current packet manually
  orchestrate.sh escalate                    mark current packet escalated
  orchestrate.sh reset                        clear handoff state

ENV:
  CONDUCTOR_PROJECT_DIR   project to work in (default: current dir)
  CONDUCTOR_MAX_ROUNDS    worker rounds before escalation (default: 2)
  CONDUCTOR_POLL_INTERVAL seconds between checks (default: 3)
  CONDUCTOR_NOTIFICATIONS 0 to disable macOS notifications (default: 1)
EOF
}

# ---------------------------------------------------------------- dispatch
cmd="${1:-help}"; shift || true
case "$cmd" in
  up)       cmd_up "$@" ;;
  start)    cmd_start "$@" ;;
  reroute)  cmd_reroute "$@" ;;
  watch)    cmd_watch "${1:-}" ;;
  status)   cmd_status ;;
  approve)  cmd_approve ;;
  escalate) set_phase escalated; set_round "$CONDUCTOR_MAX_ROUNDS"; cmd_status ;;
  reset)    cmd_reset ;;
  help|-h|--help) cmd_help ;;
  *)        die "unknown command: $cmd (try: help)" ;;
esac