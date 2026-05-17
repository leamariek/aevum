#!/usr/bin/env bash
# claude-dir-write.sh, reject Write/Edit under .claude/ for paths
# not on the allow-list in .claude/rules/runtime-vs-config.md.
#
# Runs at PreToolUse for Write|Edit|NotebookEdit. Reads the target
# path from the hook's stdin JSON (tool_input.file_path), normalises
# it to a repo-relative form, and exits non-zero with an explanation
# if the path is under .claude/ but not on the allow-list.
#
# Exit codes:
#   0 , path is allowed (or outside .claude/).
#   2 , blocked (printed to stderr; the harness surfaces stderr to
#        the model so it can self-correct).

set -euo pipefail

# Read tool_input from stdin. If jq is unavailable or the payload is
# malformed, exit 0 (fail-open for hook infrastructure bugs; the
# commit-policy hook and config-validator still catch the important
# cases).
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

payload="$(cat)"
path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)"
[ -z "$path" ] && exit 0

# Normalise: strip $CLAUDE_PROJECT_DIR prefix if present; tolerate absolute
# paths from the harness.
proj="${CLAUDE_PROJECT_DIR:-}"
rel="$path"
if [ -n "$proj" ]; then
    case "$path" in
        "$proj"/*) rel="${path#"$proj"/}" ;;
    esac
fi

# Only act on paths under .claude/.
case "$rel" in
    .claude/*) ;;
    */.claude/*)
        # Path has .claude/ somewhere mid-string. Two sub-cases:
        #  - Project worktree (e.g. .claude/worktrees/agent-xxx/.claude/state.yaml)
        #    -> still in scope; normalise to the .claude/ suffix.
        #  - User home (~/.claude/plans/...) where plan-mode parks drafts
        #    -> out of scope; only the project's .claude/ has the runtime
        #    allow-list contract.
        if [ -n "$proj" ] && [ "${path#"$proj"/}" != "$path" ]; then
            rel=".claude/${rel##*/.claude/}"
        else
            exit 0
        fi
        ;;
    *)
        exit 0
        ;;
esac

sub="${rel#.claude/}"

# Allow-list: directories (anything under them is fine).
case "$sub" in
    rules/*|agents/*|hooks/*|scripts/*|skills/*|templates/*|prompts/*|commands/*|worktrees/*)
        exit 0
        ;;
esac

# Allow-list: specific top-level files.
case "$sub" in
    settings.json|settings.local.json|state.yaml|scheduled_tasks.lock|mcp.json|.gitignore|CLAUDE.md)
        exit 0
        ;;
esac

cat >&2 <<MSG
BLOCK: $rel is runtime, not config.

.claude/ holds committed configuration only. Runtime artefacts live
under logs/ (gate JSONs, metrics, gap reports, locks, ledgers).

See .claude/rules/runtime-vs-config.md for the allow-list and where
each artefact type belongs.
MSG
exit 2
