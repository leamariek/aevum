#!/usr/bin/env bash
#
# gate1.sh, flock-protected Gate-1 invocation.
#
# =============================================================================
# SWAP-ME: this is the default Node / pnpm Gate-1 runner Aevum ships.
# Replace this script with one for your stack (Python / uv / cargo /
# whatever). The orchestrator's only contract is:
#   1. The script lives at .claude/scripts/gate1.sh (or the
#      orchestrator's gate1 path setting, if you make that
#      configurable in your fork).
#   2. Exit 0 means Gate 1 passed; exit 1 means failed; exit 2 means
#      setup error; exit 3 means lock acquisition failed.
#   3. scripts/quality-gate.py (or whatever you delegate to) writes
#      logs/gates/gate1.json atomically.
# See docs/swap-points.md for the full seam list.
# =============================================================================
#
# The orchestrator and any subagent that needs to run the Gate 1
# pipeline MUST call this helper; direct tool invocations from inside
# the block run risk colliding when two subagents land at gate
# boundaries simultaneously. The helper acquires an exclusive flock
# on logs/locks/gate1.lock before running scripts/quality-gate.py, so
# concurrent invocations are serialised. `flock` fd is released on
# script exit (kernel guarantee), which makes the lock crash-safe.
#
# Usage:
#   bash .claude/scripts/gate1.sh [--fast | --only <check> | --timeout <s> | --force]
#
# Arguments are passed through to scripts/quality-gate.py.
# --force is accepted but has no effect here (kept for orchestrator-side
# prompt compatibility; quality-gate.py ignores unknown flags).
#
# Exit codes: forwarded from quality-gate.py
#   0, gate passed
#   1, gate failed
#   2, setup error
#   3, lock acquisition failed (timeout)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK="$REPO_ROOT/logs/locks/gate1.lock"
PROGRESS_LEDGER=""
PHASE="${PHASE:-}"

# If PHASE is set, ledger into the matching progress.jsonl so
# the orchestrator sees gate1_lock_acquired/released events. If unset,
# the helper runs silently (tests, local dev).
if [ -n "$PHASE" ] && [ -d "$REPO_ROOT/logs/phase-$PHASE" ]; then
    PROGRESS_LEDGER="$REPO_ROOT/logs/phase-$PHASE/progress.jsonl"
fi

ledger() {
    [ -z "$PROGRESS_LEDGER" ] && return 0
    local event="$1"; shift
    local extra="${1:-}"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ -n "$extra" ]; then
        printf '{"ts":"%s","phase":%s,"session":null,"event":"%s",%s}\n' \
            "$ts" "$PHASE" "$event" "$extra" >> "$PROGRESS_LEDGER"
    else
        printf '{"ts":"%s","phase":%s,"session":null,"event":"%s"}\n' \
            "$ts" "$PHASE" "$event" >> "$PROGRESS_LEDGER"
    fi
}

mkdir -p "$(dirname "$LOCK")"

# Open the lock file as fd 9; flock holds it until the fd closes on exit.
exec 9>"$LOCK"

# Drop the current PID into the file purely as a diagnostic aid.
# flock itself does not read the file contents.
printf '%s\n' "$$" >&9

START=$(date +%s)

# Exclusive lock, wait indefinitely, quality-gate.py is bounded by its
# own per-check timeout so blocking here is acceptable.
if ! flock -x 9; then
    ledger "preflight_fail" "\"failed_check\":\"gate1_lock\",\"detail\":\"flock -x failed\",\"exit_code\":3"
    echo "ERROR: could not acquire gate1.lock (flock -x failed)" >&2
    exit 3
fi

ledger "gate1_lock_acquired" "\"pid\":$$"

release_and_log() {
    local rel=$(( $(date +%s) - START ))
    ledger "gate1_lock_released" "\"pid\":$$,\"duration_s\":$rel"
    # Truncate the diagnostic PID file so a later preflight PID-liveness
    # check does not mistake it for a held lock.
    : >"$LOCK" 2>/dev/null || true
}
trap release_and_log EXIT

PATH="$REPO_ROOT/node_modules/.bin:$PATH" python3 "$REPO_ROOT/scripts/quality-gate.py" "$@"
