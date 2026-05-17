# wrapper-event-filter.sh -- shared definition of "wrapper-only" ledger events.
#
# Both the inner block orchestrator (orchestrate-block.sh) and the outer
# loop wrapper (orchestrate-block-loop.sh) must skip the same set of
# events when they reason about inner-claude liveness or about the
# substantive terminal state of a rotation:
#
#   - Inner: the wedge detector counts NON-wrapper events to decide
#            whether claude has stalled.
#   - Loop:  on inner exit 0, the loop scans backwards for the most
#            recent NON-wrapper event to distinguish abort from sign-off
#            from rejection.
#
# Before this lib was introduced (upstream hardening) the two
# scripts each carried their own hardcoded set inside a Python
# heredoc.
# The sets had already drifted (loop missed wrapper_dry_run_complete and
# wrapper_wedge_detected; inner missed loop_start / loop_rotation /
# loop_terminated, which became wrong once both writers landed events
# in the same logs/blocks/<BLOCK>/progress.jsonl).
#
# Source this file from any orchestrator script that needs the set.
# It exports WRAPPER_EVENTS (newline-separated) so embedded
# python3 heredocs can read it via os.environ.

# shellcheck disable=SC2034  # consumed by python3 heredocs via env
WRAPPER_EVENTS=$(cat <<'EOF'
wrapper_start
wrapper_heartbeat
wrapper_shutdown
wrapper_exit
wrapper_dry_run_complete
wrapper_wedge_detected
abort_signal_detected
worktree_cleanup
rotation_triggered
preflight_start
preflight_ok
preflight_blocked
preflight_error
preflight_skipped
loop_start
loop_rotation
loop_terminated
EOF
)
export WRAPPER_EVENTS

# is_wrapper_event <event_name>
#   exit 0 -> the event is wrapper-only (skip when reasoning about
#             inner-claude liveness or substantive terminal state)
#   exit 1 -> the event is substantive (count it / treat as terminal)
is_wrapper_event() {
  local needle="${1:-}"
  [[ -z "$needle" ]] && return 1
  local line
  while IFS= read -r line; do
    [[ "$line" == "$needle" ]] && return 0
  done <<< "$WRAPPER_EVENTS"
  return 1
}
