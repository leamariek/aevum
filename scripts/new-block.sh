#!/usr/bin/env bash
# new-block.sh, scaffold a paired block.yaml + plan.md.
#
# Every Aevum block ships with two artefacts:
#   1. docs/blocks/<BLOCK_ID>/block.yaml   the orchestrator-executable
#                                          structured plan (clusters,
#                                          tasks, acceptance criteria).
#   2. docs/plans/<YYYY-MM-DD>_block-<BLOCK_ID>.md  the narrative plan
#                                          (context, goals, reasoning,
#                                          links). Lifecycle per
#                                          .claude/rules/plan-metadata.md
#                                          and .claude/rules/doc-lifecycle.md.
#
# This script creates both from the templates under .claude/templates/,
# substituting identity fields. Operator stages and commits when ready.
#
# Usage:
#   bash scripts/new-block.sh <BLOCK_ID> "<Title>" <owner>
#   bash scripts/new-block.sh --plan-only <BLOCK_ID> "<Title>" <owner>
#
# Examples:
#   bash scripts/new-block.sh B1 "Payments refactor" leamariek
#   bash scripts/new-block.sh AUTH-MIGRATION "Move session tokens to JWT" ops
#   bash scripts/new-block.sh --plan-only EXAMPLE "Minimal no-op smoke" leamariek
#
# Modes:
#   default     create both block.yaml and the paired plan.md.
#   --plan-only create only the plan.md (for back-filling an existing block
#               that ships without a paired narrative plan).
#
# Exit codes:
#   0   file(s) written
#   1   usage error
#   2   target already exists (refuses to overwrite)
#   3   template missing or unreadable

set -euo pipefail

PLAN_ONLY=0
if [[ "${1:-}" == "--plan-only" ]]; then
  PLAN_ONLY=1
  shift
fi

BLOCK_ID="${1:-}"
TITLE="${2:-}"
OWNER="${3:-}"

if [[ -z "$BLOCK_ID" || -z "$TITLE" || -z "$OWNER" ]]; then
  cat >&2 <<EOF
usage: $0 [--plan-only] <BLOCK_ID> "<Title>" <owner>

  BLOCK_ID    short slug (e.g. B1, payments-refactor). Must match
              docs/blocks/ naming. Required unique.
  Title       human title, kept inside quotes.
  owner       founder name or agent slug for the plan's frontmatter.

  --plan-only Skip block.yaml creation; create only the plan.md
              (for back-filling an existing block).

EOF
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

BLOCK_DIR="docs/blocks/$BLOCK_ID"
BLOCK_YAML="$BLOCK_DIR/block.yaml"
DATE_STAMP="$(date -u +%Y-%m-%d)"
# Plan id is kebab-case; lowercase the block id and prefix with block-.
PLAN_ID="block-$(printf '%s' "$BLOCK_ID" | tr '[:upper:]' '[:lower:]')"
PLAN_PATH="docs/plans/${DATE_STAMP}_${PLAN_ID}.md"
TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

BLOCK_TEMPLATE=".claude/templates/block.yaml"
PLAN_TEMPLATE=".claude/templates/plan.md"

if [[ ! -r "$BLOCK_TEMPLATE" || ! -r "$PLAN_TEMPLATE" ]]; then
  echo "ERROR: templates missing under .claude/templates/" >&2
  exit 3
fi

if [[ $PLAN_ONLY -eq 0 && -e "$BLOCK_YAML" ]]; then
  echo "ERROR: $BLOCK_YAML already exists; refusing to overwrite" >&2
  echo "       (use --plan-only to back-fill the paired plan without touching block.yaml)" >&2
  exit 2
fi

if [[ -e "$PLAN_PATH" ]]; then
  echo "ERROR: $PLAN_PATH already exists; refusing to overwrite" >&2
  exit 2
fi

mkdir -p "docs/plans"

if [[ $PLAN_ONLY -eq 0 ]]; then
  mkdir -p "$BLOCK_DIR"
  # block.yaml: substitute <BLOCK_ID> and <Human Title>.
  sed -e "s|<BLOCK_ID>|$BLOCK_ID|g" \
      -e "s|<Human Title>|$TITLE|g" \
      "$BLOCK_TEMPLATE" > "$BLOCK_YAML"
fi

# plan.md: substitute frontmatter fields plus body placeholders.
sed -e "s|<kebab-case-slug>|$PLAN_ID|g" \
    -e "s|<Short Human Title>|$TITLE|g" \
    -e "0,/^created: .*/s||created: $TS_NOW|" \
    -e "0,/^updated: .*/s||updated: $TS_NOW|" \
    -e "s|<name-or-agent-id>|$OWNER|g" \
    -e "s|<Plan Title>|$TITLE|g" \
    "$PLAN_TEMPLATE" > "$PLAN_PATH"

# Append a block-reference section to the plan body so the pairing
# is self-documenting and grep-discoverable.
cat >> "$PLAN_PATH" <<EOF

## Block reference

This plan pairs with the orchestrator block at
\`docs/blocks/$BLOCK_ID/block.yaml\`. The block is the
orchestrator-executable structured plan; this document is the
narrative one (context, reasoning, acceptance rationale, post-mortem).

- Block ID: \`$BLOCK_ID\`
- Created: $TS_NOW
EOF

if [[ $PLAN_ONLY -eq 0 ]]; then
  echo ">> created $BLOCK_YAML"
fi
echo ">> created $PLAN_PATH"
echo ""
echo "Next steps:"
if [[ $PLAN_ONLY -eq 0 ]]; then
  echo "  1. Edit $BLOCK_YAML: set base_sha, clusters, tasks, acceptance."
  echo "  2. Edit $PLAN_PATH: fill Context, Goals, and the remaining sections."
  echo "  3. Activate: flip status: draft -> active in block.yaml, fill activated_at + activated_by."
  echo "  4. Capture baseline: bash scripts/capture-baseline.sh $BLOCK_ID"
  echo "  5. Commit both files together as the activation commit, plus baseline.json."
  echo "  6. Run preflight: python3 scripts/block-preflight.py $BLOCK_ID"
  echo "  7. Dispatch: bash .claude/scripts/orchestrate-block-loop.sh $BLOCK_ID"
else
  echo "  1. Edit $PLAN_PATH: fill Context, Goals, and the remaining sections."
  echo "  2. Stage and commit alongside any next edit to the paired block."
fi
