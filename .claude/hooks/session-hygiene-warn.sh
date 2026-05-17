#!/usr/bin/env bash
# SessionStart hook: non-blocking working-tree drift warning.
#
# A working tree with more than 30 entries in `git status --short` is a
# signal the operator should review (likely stale untracked files, an
# in-flight rebase, or pre-commit debris). This hook surfaces the signal
# once per session so the operator does not have to remember to check.
# It never blocks session start.
#
# Exit code 0 always. Output (if any) goes to stderr.

set -u

# Resolve project root; CLAUDE_PROJECT_DIR is provided by the harness.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Skip silently if we are not inside a git worktree.
if ! git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

count=$(git -C "$PROJECT_DIR" status --short 2>/dev/null | wc -l | tr -d ' ')

threshold=30

if [ "${count:-0}" -gt "$threshold" ]; then
  printf '[hygiene] working tree has %s entries (threshold %s). Review git status before the next long session.\n' \
    "$count" "$threshold" >&2
fi

exit 0
