#!/usr/bin/env bash
# claude-astra handoff driver
#
# Coordinates the Plan -> Worker -> Review loop across two separate Claude Code
# sessions (Claude Pro subscribion plans/reviews, DeepSeek API implements).
#
# The driver is a hand-off switchboard: it decides WHICH session should run and
# opens it in a fresh Terminal window; the human does the thinking in each one.

set -Eeuo pipefail

ASTRA_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
ASTRA_RUN_DIR="${ASTRA_RUN_DIR:-$HOME/.claude-astra}"
ASTRA_MAX_ROUNDS="${ASTRA_MAX_ROUNDS:-2}"
ASTRA_POLL_INTERVAL="${ASTRA_POLL_INTERVAL:-3}"
ASTRA_NOTIFICATIONS="${ASTRA_NOTIFICATIONS:-1}"
ASTRA_PROJECT_DIR="${ASTRA_PROJECT_DIR:-$PWD}"

PROJECT_DIR="$(cd "$ASTRA_PROJECT_DIR" 2>/dev/null && pwd)" || die "not a directory: $ASTRA_PROJECT_DIR"
STATE_DIR="$PROJECT_DIR/.astra"
PHASE_FILE="$STATE_DIR/PHASE"
ROUND_FILE="$STATE_DIR/ROUND"
START_COMMIT_FILE="$STATE_DIR/WORKER_START_COMMIT"

mkdir -p "$STATE_DIR" "$ASTRA_RUN_DIR"

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
    || die "$PROJECT_DIR is not a git repository (claude-astra needs git commits to detect handoffs)"
}

notify() {
  [[ "$ASTRA_NOTIFICATIONS" == "0" ]] && return 0
  has osascript || return 0
  osascript -e "display notification \"$2\" with title \"claude-astra: $1\"" >/dev/null 2>&1 || true
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
  local f="$ASTRA_RUN_DIR/astra-$label-$(date +%Y%m%d-%H%M%S)-$RANDOM.command"
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
  spawn_terminal "worker" "$ASTRA_HOME/worker/launch.sh" "$PROJECT_DIR"
}

planner_seed() {
  local desc="${1:-}"
  local seed
  seed='You are the claude-astra planner/model in a two-agent orchestration loop. Context: a smaller, cheaper model (DeepSeek deepseek-v4-flash via the DeepSeek API, running as the official Claude Code integration) is the WORKER that will implement what you write; a later pass of this Claude Pro session is the REVIEWER. Your job is planning only. Because the worker is a smaller model, write packets that are mechanically verifiable: exact files/imports to touch, exact acceptance commands and the expected outcome for each, explicit out-of-scope, no ambiguity left to infer. The worker system prompt forbids scope creep, planning and review. Write the packet to .astra/TASK.md using the packet template (Objective, Scope, Acceptance, Constraints, Definition of Done + reviewer success criteria). Keep it ONE small verifiable change; split larger features across multiple packets. Do NOT implement anything in this session. Do not ask the user to paste context; explore the repo yourself and derive the packet from the requested task. If the task is too big or underspecified, say so in .astra/TASK.md under Constraints and ask the user to split it.'
  [[ -n "$desc" ]] && seed="$seed

The user's requested task for this packet is:
$desc"
  spawn_terminal "planner" "$(require_claude)" "$seed"
}

reviewer_seed() {
  local seed
  seed='You are the claude-astra reviewer/model, the final gate in a two-agent orchestration loop. Context: a DeepSeek worker (lower-cost model) implemented .astra/TASK.md. Its changes are either committed on HEAD or sit as an uncommitted working-tree diff (verification packets forbid commits) — read the diff (git diff, plus git status for untracked files). Verify it yourself: read the diff, read .astra/EVIDENCE.md, and RUN the acceptance commands from TASK.md (tests/lint/build) in the repo. Then write .astra/REVIEW.md. First line must be APPROVED or ISSUES. APPROVED only if every acceptance check passes AND the diff genuinely implements the packet. ISSUES: numbered, one fix per issue, severity + file:line + the concrete expected fix; the worker fixes exactly those and nothing else. Do NOT edit code yourself. Finish with a Notes for Planner section on anything mis-scoped so the next packet is better. Keep it one batched review pass — no back-and-forth polling.'
  spawn_terminal "reviewer" "$(require_claude)" "$seed"
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
        set_phase review
        notify "Reviewer" "Worker delivered a zero-change packet (no commit). Reviewing now."
        reviewer_seed
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
          set_phase review
          notify "Reviewer" "Worker finished a zero-change packet (no commit). Reviewing working tree."
          reviewer_seed
        fi
        return 0
      fi
      set_phase review
      notify "Reviewer" "Worker committed. Switching back to Claude Pro review."
      reviewer_seed
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
      if (( r > ASTRA_MAX_ROUNDS )); then
        set_phase escalated
        notify "Escalated" "Worker failed ${ASTRA_MAX_ROUNDS} rounds. Planner takes over this packet."
        local seed='claude-astra: this packet exceeded the worker round limit. Take it over directly. Read .astra/TASK.md and .astra/REVIEW.md, then implement and finish it yourself using Claude Pro.'
        spawn_terminal "escalate" "$(require_claude)" "$seed"
      else
        rm -f "$STATE_DIR/REVIEW.md"
        set_phase working
        record_start_commit
        notify "Worker" "Review feedback round $r. Switching back to DeepSeek worker."
        worker_cmd
      fi
      ;;
    none|approved|escalated)
      return 0
      ;;
  esac
}

# ---------------------------------------------------------------- commands
cmd_status() {
  printf 'project : %s\n' "$PROJECT_DIR"
  printf 'phase   : %s\n' "$(phase)"
  printf 'round   : %s/%s\n' "$(round)" "$ASTRA_MAX_ROUNDS"
  local tsk="$STATE_DIR/TASK.md" rvw="$STATE_DIR/REVIEW.md"
  [[ -f "$tsk" ]] && printf 'task    : %s\n' "$(head -c 80 "$tsk")" || true
  [[ -f "$rvw" ]] && printf 'review  : present (%s)\n' "$(head -c 40 "$rvw")" || true
  [[ -f "$START_COMMIT_FILE" ]] && printf 'worker  : started at %s\n' "$(start_commit)" || true
  return 0
}

cmd_start() {
  local desc="$*"
  [[ -n "$desc" ]] || die "usage: orchestrate.sh start \"<task description>\""
  rm -f "$STATE_DIR/TASK.md" "$STATE_DIR/REVIEW.md" "$START_COMMIT_FILE" "$STATE_DIR/EVIDENCE.md"
  set_round 0
  set_phase plan
  printf '%s\n' "$desc" > "$STATE_DIR/DESC"
  notify "Planner" "New packet requested. Claude Pro session opening to write TASK.md."
  planner_seed "$desc"
  echo "phase=plan. Planner window opened -> write .astra/TASK.md, then run:  orchestrate.sh watch"
}

cmd_watch() {
  local once=0
  [[ "${1:-}" == "--once" ]] && once=1
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
      approved)  echo "packet approved. run: orchestrate.sh start \"<next packet>\""; [[ "$once" == 1 ]] && return 0 ;;
      escalated) echo "packet escalated to planner. begin next packet when done.";        [[ "$once" == 1 ]] && return 0 ;;
      none)      echo "no active packet. run: orchestrate.sh start \"<task>\"";           [[ "$once" == 1 ]] && return 0 ;;
    esac
    [[ "$once" == 1 ]] && break
    sleep "$ASTRA_POLL_INTERVAL"
  done
  cmd_status
}

cmd_approve() {
  printf 'APPROVED\nmanual approve\n' > "$STATE_DIR/REVIEW.md"
  set_phase approved
  echo "marked approved."
}

cmd_reset() {
  rm -f "$STATE_DIR/TASK.md" "$STATE_DIR/REVIEW.md" "$STATE_DIR/WORKER_START_COMMIT" "$STATE_DIR/DESC"
  set_round 0
  set_phase none
  echo "state reset."
}

cmd_help() {
  cat <<'EOF'
claude-astra handoff driver

USAGE:
  orchestrate.sh start "<task description>"   begin a packet (opens planner)
  orchestrate.sh watch [--once]               watch for handoffs and open sessions
  orchestrate.sh status                       show current phase / round
  orchestrate.sh approve                      approve the current packet manually
  orchestrate.sh escalate                    mark current packet escalated
  orchestrate.sh reset                        clear handoff state

ENV:
  ASTRA_PROJECT_DIR   project to work in (default: current dir)
  ASTRA_MAX_ROUNDS    worker rounds before escalation (default: 2)
  ASTRA_POLL_INTERVAL seconds between checks (default: 3)
  ASTRA_NOTIFICATIONS 0 to disable macOS notifications (default: 1)
EOF
}

# ---------------------------------------------------------------- dispatch
cmd="${1:-help}"; shift || true
case "$cmd" in
  start)    cmd_start "$@" ;;
  watch)    cmd_watch "${1:-}" ;;
  status)   cmd_status ;;
  approve)  cmd_approve ;;
  escalate) set_phase escalated; set_round "$ASTRA_MAX_ROUNDS"; cmd_status ;;
  reset)    cmd_reset ;;
  help|-h|--help) cmd_help ;;
  *)        die "unknown command: $cmd (try: help)" ;;
esac