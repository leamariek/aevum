#!/usr/bin/env bash
# worker-worktree-jail.sh, reject Write/Edit/NotebookEdit targets
# that fall outside the current git worktree, when the current
# worktree is a *linked* one (i.e., a worker subagent's worktree
# distinct from the main project worktree).
#
# Upstream production runs surfaced three worker-isolation leakage
# patterns under .claude/worktrees/agent-*:
#
#   - A parallel-task worker wrote partial work into the main worktree
#     (cwd default-of-cwd inheritance bug).
#   - A worker had its cwd reset mid-task and wrote outside its
#     assigned worktree.
#   - A worker's worktree was wiped by a filesystem hiccup (WSL2,
#     network volume eviction, etc.).
#
# This hook addresses the first two by enforcing the boundary at
# PreToolUse so the write never lands. The third (worktree wipe) is
# a recovery problem handled by the orchestrator side, not by this
# hook.
#
# Detection: read git rev-parse --show-toplevel from the hook's CWD
# (which is the calling agent's CWD because PreToolUse hooks
# inherit it). If the top-level differs from $CLAUDE_PROJECT_DIR,
# we are in a linked worktree and treat as worker context. Any
# Write/Edit/NotebookEdit target whose canonical path resolves
# outside that worktree is blocked.
#
# In main-worktree context (orchestrator or founder), the hook is a
# no-op.
#
# Self-test: run with --self-test to exercise four cases (worker
# in-bounds, worker leak, main-context, worker relative path).
#
# Exit codes:
#   0, allowed (or hook infra unable to reach a verdict; fail-open
#       like claude-dir-write.sh).
#   2, blocked; reason printed to stderr (the harness surfaces
#       stderr to the model so it can self-correct).

# --- self-test mode --------------------------------------------------
# Runs before set -e so individual case failures don't kill the run.

if [ "${1:-}" = "--self-test" ]; then
    if ! command -v git >/dev/null 2>&1; then
        echo "self-test skipped: git unavailable" >&2
        exit 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "self-test skipped: jq unavailable" >&2
        exit 0
    fi

    self="$(realpath "$0")"
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT

    proj="$tmpdir/proj"
    mkdir -p "$proj"
    (
        cd "$proj"
        git init -q
        git -c user.email=test@test -c user.name=test \
            commit -q --allow-empty -m init
    )

    worker="$proj/.claude/worktrees/agent-T01"
    mkdir -p "$proj/.claude/worktrees"
    ( cd "$proj" && git worktree add -q "$worker" -b agent-test ) >/dev/null 2>&1

    fail=0
    run_case() {
        local name="$1" cwd="$2" target="$3" expected="$4"
        local payload
        payload="$(printf '{"tool_input":{"file_path":"%s"}}' "$target")"
        local actual=0
        (
            cd "$cwd"
            export CLAUDE_PROJECT_DIR="$proj"
            printf '%s' "$payload" | "$self"
        ) >/dev/null 2>&1
        actual=$?
        if [ "$actual" = "$expected" ]; then
            printf 'PASS  %s (got %s)\n' "$name" "$actual"
        else
            printf 'FAIL  %s (expected %s, got %s)\n' \
                "$name" "$expected" "$actual"
            fail=1
        fi
    }

    run_case "worker in-bounds absolute"  "$worker"  "$worker/src/foo.py"   0
    run_case "worker leak to main"        "$worker"  "$proj/src/leak.py"    2
    run_case "worker leak to /etc"        "$worker"  "/etc/passwd-leak"     2
    run_case "main context any write"     "$proj"    "$proj/src/foo.py"     0
    run_case "worker relative in-bounds"  "$worker"  "src/foo.py"           0
    run_case "worker dotdot escape"       "$worker"  "../../src/leak.py"    2

    exit "$fail"
fi

# --- normal hook mode ------------------------------------------------

set -euo pipefail

# Operator escape hatch: ORCHESTRATOR_HOST=1 declares "this
# claude invocation IS the orchestrator host, regardless of which
# worktree it runs in". The default detection (toplevel != project_dir)
# treats any linked worktree as worker context and rejects writes
# outside the toplevel. That detection misfires when the operator
# launches the orchestrator from a linked worktree, or when the
# harness layer (e.g. EnterWorktree) drops the orchestrator into one
# by default. The orchestrator wrapper exports this var immediately
# before its `claude -p` invocation so the inner orchestrator context
# inherits the host treatment and other hooks (claude-dir-write,
# forbidden-patterns-live, plan-frontmatter) remain authoritative.
# A subagent's tool invocations do NOT inherit this var because
# Agent(isolation:"worktree") strips the parent environment.
if [ "${ORCHESTRATOR_HOST:-}" = "1" ]; then
    exit 0
fi

# Fail-open if jq is unavailable; matches claude-dir-write.sh.
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

payload="$(cat)"
target="$(printf '%s' "$payload" | jq -r '
    .tool_input.file_path
    // .tool_input.notebook_path
    // .tool_input.path
    // empty
' 2>/dev/null || true)"
[ -z "$target" ] && exit 0

proj="${CLAUDE_PROJECT_DIR:-}"
[ -z "$proj" ] && exit 0

# Are we in a git worktree at all? If not (e.g., scratch CWD), the
# concept of a "leak outside the worktree" does not apply; allow.
toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$toplevel" ] && exit 0

# Canonicalise both sides to dodge symlink and trailing-slash
# differences. realpath -m tolerates non-existent paths (Write
# creates new files).
toplevel_real="$(realpath -m "$toplevel" 2>/dev/null || printf '%s' "$toplevel")"
proj_real="$(realpath -m "$proj" 2>/dev/null || printf '%s' "$proj")"

# Main-worktree context: the orchestrator and founder live here.
# Boundary check is a no-op; other hooks (claude-dir-write,
# forbidden-patterns-live, plan-frontmatter) cover this branch.
if [ "$toplevel_real" = "$proj_real" ]; then
    exit 0
fi

# Worker context. Resolve the target against the agent's CWD.
case "$target" in
    /*) abs="$target" ;;
     *) abs="$PWD/$target" ;;
esac
abs_real="$(realpath -m "$abs" 2>/dev/null || printf '%s' "$abs")"

case "$abs_real" in
    "$toplevel_real" | "$toplevel_real"/* )
        exit 0
        ;;
esac

cat >&2 <<MSG
BLOCK: write would leak outside the worker worktree.

Target:    $target
Resolved:  $abs_real
Worktree:  $toplevel_real
Project:   $proj_real

Worker subagents are confined to their assigned worktree. Writes
to the main worktree or to other workers' worktrees are blocked
to prevent the cross-task leakage class of bug (worker writes
that bypass the merge gate, observed during upstream hardening).

If a write outside the worktree is genuinely required, the
orchestrator should issue it directly, not delegate to a worker.
MSG
exit 2
