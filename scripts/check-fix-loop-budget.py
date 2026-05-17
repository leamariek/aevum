#!/usr/bin/env python3
"""Fix-loop budget accountant (added during upstream orchestrator hardening).

The block orchestrator's fix loop iterates against gate failures until
the gates go green. Two iteration kinds need to be counted separately:

* ``substantive``: the gate failed for a real reason (gate1 delta
  regression, gate2 / gate3a fail verdict, gate3 CHANGES_REQUESTED).
  The iteration produces real worker output and counts against the
  per-cluster milestone budget (iter 3 warning, iter 5 pause, iter
  10 / 20 milestones).
* ``fragmentation_recovery``: a gate agent fragmented mid-run and
  emitted ``verdict: pending`` (the stub-state contract). The
  orchestrator re-dispatches the agent. These retries are unbounded
  because they reflect Anthropic-side flakiness, not block-side
  problems; counting them against the substantive budget would have
  every fragmentation storm exhaust the founder's pause-trigger
  before the actual block work has had a chance to land. F4 burned
  3 of its 5 fix iterations on fragmentation alone (per
  ``_ORCHESTRATOR_ANALYSIS.md`` §10.1).

This helper reads the per-block ledger, scopes counting to the most
recent ``cluster_start{cluster_id: <CLUSTER>}`` event for the named
cluster, and reports counts per kind. It also fires the
``storm_alarm`` flag when fragmentation_recovery exceeds 10 in a
single cluster, the threshold from the plan: at that point the
workaround has itself become the failure mode and the orchestrator
must abort with ``reason: fragmentation_storm``.

Output: a single JSON object on stdout, shape::

    {"block_id": "...",
     "cluster_id": "...",
     "substantive": N,
     "fragmentation_recovery": M,
     "storm_alarm": bool}

The ``storm_alarm`` flag is true iff ``fragmentation_recovery > 10``.
The script always exits 0; the JSON body is the result.

Invocation::

    python3 scripts/check-fix-loop-budget.py --block <BLOCK_ID> \\
        --cluster <CLUSTER_ID> [--ledger <path>]
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

STORM_THRESHOLD = 10  # fragmentation_recovery > this => storm_alarm=true


def read_ledger(path: pathlib.Path) -> list[dict]:
    if not path.exists():
        return []
    out: list[dict] = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def find_latest_cluster_start_index(events: list[dict], cluster_id: str) -> int:
    """Return the index of the most recent cluster_start for cluster_id, or -1."""
    for i in range(len(events) - 1, -1, -1):
        ev = events[i]
        if (
            ev.get("event") == "cluster_start"
            and ev.get("cluster_id") == cluster_id
        ):
            return i
    return -1


def cluster_already_complete(
    events: list[dict], cluster_id: str, since: int,
) -> bool:
    """True if a cluster_complete for cluster_id appears at/after `since`."""
    for ev in events[since:]:
        if (
            ev.get("event") == "cluster_complete"
            and ev.get("cluster_id") == cluster_id
        ):
            return True
    return False


def evaluate(
    events: list[dict], block_id: str, cluster_id: str,
) -> dict:
    start = find_latest_cluster_start_index(events, cluster_id)
    substantive = 0
    fragmentation = 0
    if start >= 0 and not cluster_already_complete(events, cluster_id, start):
        for ev in events[start + 1 :]:
            if ev.get("event") != "cluster_fix_loop_iteration":
                continue
            if ev.get("cluster_id") != cluster_id:
                continue
            kind = (ev.get("payload") or {}).get("iter_kind", "substantive")
            if kind == "fragmentation_recovery":
                fragmentation += 1
            else:
                # Default to substantive for events that predate the
                # iter_kind field. Conservative because the cap was
                # substantive-only in spirit before the field existed;
                # treating legacy events as substantive matches operator
                # expectations on resume across the upgrade.
                substantive += 1
    return {
        "block_id": block_id,
        "cluster_id": cluster_id,
        "substantive": substantive,
        "fragmentation_recovery": fragmentation,
        "storm_alarm": fragmentation > STORM_THRESHOLD,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--block", required=True, help="block ID (e.g. F1)")
    parser.add_argument(
        "--cluster", required=True, help="cluster ID (e.g. cl-01)",
    )
    parser.add_argument(
        "--ledger",
        default=None,
        help="override ledger path (default: logs/blocks/<BLOCK>/progress.jsonl)",
    )
    args = parser.parse_args(argv)

    ledger_path = pathlib.Path(
        args.ledger or f"logs/blocks/{args.block}/progress.jsonl"
    )
    events = read_ledger(ledger_path)
    print(json.dumps(evaluate(events, args.block, args.cluster)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
