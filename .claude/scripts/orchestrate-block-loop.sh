#!/usr/bin/env bash
# orchestrate-block-loop.sh, auto-respawning outer loop for orchestrate-block.sh.
#
# The inner orchestrate-block.sh exits with code 4 when the inner
# claude emits SENTINEL::CONTEXT_LIMIT_REACHED or hits the wedge
# detector. orchestrate-block.sh documents in its header that the
# CALLER re-spawns; the wrapper itself does not. This loop IS the
# caller. It re-invokes the wrapper until the block reaches a
# terminal state (block finished, inner setup/code error, or
# MAX_ROTATIONS exhausted).
#
# Usage:
#   bash .claude/scripts/orchestrate-block-loop.sh <BLOCK_ID> [--dry-run | --skip-preflight]
#
# All extra args pass through to orchestrate-block.sh verbatim.
#
# Environment:
#   MAX_ROTATIONS   default 15. Cap on rotations per loop. A
#                       well-scoped block typically needs 2-6
#                       rotations; 15 is generous and prevents
#                       runaway loops.
#   ROTATION_GAP_S  default 5. Sleep between rotations to let any
#                       worker-worktree cleanup or lock release
#                       settle before the next inner invocation.
#
# Exit codes (passed through from the inner on terminal exit):
#   0    block finished cleanly (sign-off honoured or block_complete)
#   1    inner claude exited non-zero (terminal; loop does not retry)
#   2    inner setup error (terminal; loop does not retry)
#   100  MAX_ROTATIONS exhausted; loop abandons rather than spin
#   130  loop interrupted by SIGINT / SIGTERM (operator Ctrl-C)
#
# Ledger:
#   The loop writes its own events into the same per-block
#   progress.jsonl the inner uses, prefixed with "loop_*" so they are
#   distinguishable from orchestrator-internal events:
#     loop_start         when the loop first runs
#     loop_rotation      between successful rotations on exit 4
#     loop_terminated    on exit (block_finished | orchestrator_error
#                        | max_rotations_exceeded | interrupted)
#
# Lock:
#   The loop relies on the inner orchestrator's per-block lock
#   (logs/locks/block-<id>.lock). Two loop wrappers running for the
#   same block will fight at the inner-lock layer; the second one
#   blocks or fails fast. Operator discipline avoids this.

set -uo pipefail

BLOCK_ID="${1:-}"
if [[ -z "$BLOCK_ID" ]]; then
  echo "usage: $0 <BLOCK_ID> [--dry-run | --skip-preflight]" >&2
  exit 2
fi
shift

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

# shellcheck source=lib/wrapper-event-filter.sh
. "$REPO_ROOT/.claude/scripts/lib/wrapper-event-filter.sh"

MAX_ROTATIONS="${MAX_ROTATIONS:-15}"
GAP_S="${ROTATION_GAP_S:-5}"
LEDGER="logs/blocks/$BLOCK_ID/progress.jsonl"
INNER=".claude/scripts/orchestrate-block.sh"

if [[ ! -f "$INNER" ]]; then
  echo "ERROR: inner orchestrator not found at $INNER" >&2
  exit 2
fi

mkdir -p "$(dirname "$LEDGER")"

# Escape a string for safe inclusion as a JSON string value:
# backslash, double-quote. (Args are operator-controlled; this is
# enough to keep the JSON well-formed.)
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

ledger_event() {
  local event="$1"
  local payload="$2"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"schema":2,"ts":"%s","block_id":"%s","cluster_id":null,"task_id":null,"event":"%s","payload":%s}\n' \
    "$ts" "$BLOCK_ID" "$event" "$payload" >> "$LEDGER"
}

loop_pid="$$"
args_str=$(json_escape "$*")
ledger_event "loop_start" \
  "{\"loop_pid\":$loop_pid,\"max_rotations\":$MAX_ROTATIONS,\"gap_s\":$GAP_S,\"args\":\"$args_str\"}"

trap '
  ledger_event "loop_terminated" "{\"reason\":\"interrupted\",\"loop_pid\":'"$loop_pid"',\"rotations\":'"${rotation:-0}"'}"
  echo "[loop] interrupted by signal" >&2
  exit 130
' INT TERM

rotation=0
while (( rotation < MAX_ROTATIONS )); do
  rotation=$(( rotation + 1 ))
  echo "==============================================================" >&2
  echo "[loop] rotation $rotation/$MAX_ROTATIONS for block $BLOCK_ID" >&2
  echo "[loop]   bash $INNER $BLOCK_ID $*" >&2
  echo "==============================================================" >&2

  set +e
  bash "$INNER" "$BLOCK_ID" "$@"
  EXIT=$?
  set -e

  case $EXIT in
    0)
      # Inner's exit-code contract: "0 = block finished (signed off /
      # rejected / aborted cleanly)". All three land as exit 0, so we
      # peek the ledger to tell them apart. Aborts are recoverable after
      # operator intervention; treating them as "finished cleanly"
      # silently drops the block (observed 2026-04-24T12:13Z on F5a
      # with reason=dirty_resume_worktree).
      #
      # Heuristic: the most recent non-wrapper / non-heartbeat event is
      # the substantive terminal state.
      LAST_INFO=$(LEDGER_PATH="$LEDGER" WRAPPER_EVENTS="$WRAPPER_EVENTS" python3 - <<'PY' 2>/dev/null || true
import json, os
path = os.environ.get("LEDGER_PATH", "")
internal = {e for e in os.environ.get("WRAPPER_EVENTS","").split("\n") if e}
event = ""
reason = ""
try:
    with open(path) as f:
        lines = f.readlines()
    for line in reversed(lines):
        try:
            e = json.loads(line)
        except Exception:
            continue
        ev = e.get("event","")
        if ev in internal:
            continue
        event = ev
        reason = e.get("payload",{}).get("reason","")
        break
except Exception:
    pass
print(event + "|" + reason)
PY
)
      EVENT="${LAST_INFO%%|*}"
      REASON="${LAST_INFO#*|}"

      if [[ "$EVENT" == "block_abort" ]]; then
        ledger_event "loop_terminated" \
          "{\"reason\":\"block_aborted\",\"loop_pid\":$loop_pid,\"rotations\":$rotation,\"abort_reason\":\"$(json_escape "$REASON")\"}"
        echo "==============================================================" >&2
        echo "[loop] block $BLOCK_ID ABORTED" >&2
        echo "[loop]   abort reason: $REASON" >&2
        echo "[loop]   rotations   : $rotation" >&2
        echo "[loop] operator intervention required before relaunch" >&2
        echo "[loop] see the latest block_abort entry in $LEDGER" >&2
        echo "==============================================================" >&2
        exit 101
      fi

      ledger_event "loop_terminated" \
        "{\"reason\":\"block_finished\",\"loop_pid\":$loop_pid,\"rotations\":$rotation,\"final_exit\":0,\"last_terminal_event\":\"$EVENT\"}"
      echo "[loop] block $BLOCK_ID finished cleanly after $rotation rotation(s) (last terminal: ${EVENT:-unknown})" >&2
      exit 0
      ;;
    4)
      ledger_event "loop_rotation" \
        "{\"loop_pid\":$loop_pid,\"rotation\":$rotation,\"sleep_s\":$GAP_S}"
      echo "[loop] inner exited 4 (rotation requested); sleeping ${GAP_S}s then re-invoking" >&2
      sleep "$GAP_S"
      ;;
    *)
      ledger_event "loop_terminated" \
        "{\"reason\":\"orchestrator_error\",\"loop_pid\":$loop_pid,\"rotations\":$rotation,\"final_exit\":$EXIT}"
      echo "[loop] inner exited $EXIT (terminal); not rotating" >&2
      exit "$EXIT"
      ;;
  esac
done

ledger_event "loop_terminated" \
  "{\"reason\":\"max_rotations_exceeded\",\"loop_pid\":$loop_pid,\"rotations\":$rotation}"
echo "[loop] hit MAX_ROTATIONS cap of $MAX_ROTATIONS without terminal exit; aborting" >&2
exit 100
