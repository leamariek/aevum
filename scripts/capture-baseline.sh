#!/usr/bin/env bash
# capture-baseline.sh, snapshot Gate-1 errors for a block.
#
# Usage:
#   bash scripts/capture-baseline.sh <BLOCK_ID>
#
# Runs the full Gate-1 pipeline via pnpm-locked-gate.sh --force, then
# fingerprints the raw outputs into docs/blocks/<BLOCK_ID>/baseline.json.
# Call once when a block opens, and again only after a debt-paydown cluster
# whose commit subject is "chore(block-<ID>): baseline refresh after
# cluster-<CL>".
#
# Exit codes:
#   0, baseline captured
#   1, gate pipeline setup error
#   2, baseline write failed
set -euo pipefail

BLOCK_ID="${1:-}"
if [[ -z "$BLOCK_ID" ]]; then
  echo "usage: $0 <BLOCK_ID>" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo ">> running Gate-1 pipeline to capture baseline for block $BLOCK_ID"
# We do not care about the exit code here, baseline captures whatever errors
# exist at block-open time, green or red.
bash .claude/scripts/pnpm-locked-gate.sh --force || true

echo ">> fingerprinting raw outputs"
python3 scripts/baseline-diff.py --block "$BLOCK_ID" --mode capture

BASELINE="docs/blocks/$BLOCK_ID/baseline.json"
if [[ ! -f "$BASELINE" ]]; then
  echo "ERROR: baseline not written at $BASELINE" >&2
  exit 2
fi

COUNT=$(python3 -c "import json,sys; print(json.load(open('$BASELINE'))['error_count'])")
SHA=$(git rev-parse HEAD)
echo ">> baseline captured: $COUNT error fingerprints at commit $SHA"
echo ">> $BASELINE"
