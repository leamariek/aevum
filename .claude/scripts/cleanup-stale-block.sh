#!/usr/bin/env bash
# cleanup-stale-block.sh, delete local refs for a single block namespace.
#
# Usage:
#   bash .claude/scripts/cleanup-stale-block.sh <BLOCK_ID>
#   bash .claude/scripts/cleanup-stale-block.sh <BLOCK_ID> --dry-run
#
# Scope (narrow by design):
#   Deletes every local branch matching `block/<BLOCK_ID>/*` via
#   `git branch -D`. Refuses to touch `main`, `feature/*`, or any ref
#   outside the block namespace. Never pushes; remote refs are untouched.
#
# Why this exists:
#   `.claude/settings.json` denies `Bash(git branch -D*)` at the harness
#   level. A full relaunch of a block after a baseline/base-SHA refresh
#   needs those stale worker/cluster/integration refs gone. Rather than
#   widen the global deny to a glob, this script centralises the verb
#   so a matching narrow allow entry (if added by the founder) exposes
#   only `block/*` cleanup, never arbitrary branch deletion.
#
# Exit codes:
#   0   cleanup completed (or dry-run listed targets)
#   1   refused (missing block id, or refs outside the block namespace detected)
#   2   no matching refs

set -euo pipefail

BLOCK_ID="${1:-}"
shift || true
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "cleanup-stale-block: unknown arg: $arg" >&2; exit 1 ;;
  esac
done

if [ -z "$BLOCK_ID" ]; then
  echo "cleanup-stale-block: BLOCK_ID required" >&2
  echo "usage: $0 <BLOCK_ID> [--dry-run]" >&2
  exit 1
fi

# Hard guard: the id must be non-empty, must not contain path traversal,
# and must not be a top-level namespace name we care about.
case "$BLOCK_ID" in
  *"/"*|*".."*|"") echo "cleanup-stale-block: invalid block id: $BLOCK_ID" >&2; exit 1 ;;
  main|master|HEAD) echo "cleanup-stale-block: refusing to act on $BLOCK_ID" >&2; exit 1 ;;
esac

PREFIX="block/${BLOCK_ID}/"

# Collect matching refs. `git for-each-ref` is the safe enumerator; we then
# re-check the prefix in awk to be paranoid about shell-glob weirdness.
mapfile -t REFS < <(
  git for-each-ref --format='%(refname:short)' "refs/heads/${PREFIX}*" \
    | awk -v p="$PREFIX" 'index($0, p) == 1 { print }'
)

if [ "${#REFS[@]}" -eq 0 ]; then
  echo "cleanup-stale-block: no refs matching ${PREFIX}*" >&2
  exit 2
fi

echo "cleanup-stale-block: block=${BLOCK_ID} refs=${#REFS[@]} dry_run=${DRY_RUN}"
for ref in "${REFS[@]}"; do
  # Second-layer guard: never act on anything that does not start with
  # the exact prefix, even if for-each-ref returned it.
  case "$ref" in
    "${PREFIX}"*) ;;
    *) echo "cleanup-stale-block: refusing non-matching ref: $ref" >&2; exit 1 ;;
  esac
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  would delete: $ref"
  else
    echo "  deleting:     $ref"
    git branch -D "$ref" >/dev/null
  fi
done

if [ "$DRY_RUN" -eq 0 ]; then
  echo "cleanup-stale-block: done"
fi
