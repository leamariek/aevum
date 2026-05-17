#!/usr/bin/env python3
"""Stale gate verdict detector (added during upstream orchestrator hardening).

The block orchestrator runs this from its resume invariant before
re-entering a cluster after an exit-4 rotation. It reads the per-block
ledger, finds every pending ``gate*_result`` event (one not yet
consumed by a subsequent ``cluster_complete`` on the same cluster), and
verifies the branch HEAD at verdict-emit time still equals the branch
HEAD now. A mismatch means an autosave commit or operator edit landed
between verdict emission and resume; the verdict is stale and
replaying it would qualify the wrong tree.

Output: a single JSON object on stdout, shape::

    {"ok": true,  "checked": N}
    {"ok": false, "checked": N, "stale": [...]}

The script always exits 0; the JSON body is the result. Stale entries
each carry ``event``, ``cluster_id``, ``ts``, ``head_sha_at_emit``,
``actual``, and a ``reason`` of ``field_missing | branch_missing |
sha_mismatch``. The ``field_missing`` reason fires for verdicts
emitted before the head_sha_at_emit field was added (the field is
unconditionally additive but old ledgers will not carry it);
operators handle those by relaunching against a fresh ledger or by
accepting the abort and re-running the gate.

Invocation::

    python3 scripts/check-stale-gate-verdicts.py --block <BLOCK_ID>
        [--ledger <path>]

The ``--ledger`` override exists for tests; production callers pass
only ``--block`` and inherit the canonical
``logs/blocks/<BLOCK>/progress.jsonl`` path.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys

GATE_EVENTS = {"gate1_result", "gate2_result", "gate3a_result", "gate3b_result"}


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


def find_latest_block_start(events: list[dict]) -> int:
    for i in range(len(events) - 1, -1, -1):
        if events[i].get("event") == "block_start":
            return i
    return 0


def collect_pending_verdicts(events: list[dict]) -> list[dict]:
    """Return gate*_result events not yet consumed by a same-cluster cluster_complete."""
    start = find_latest_block_start(events)
    tail = events[start:]
    pending: list[dict] = []
    for i, ev in enumerate(tail):
        if ev.get("event") not in GATE_EVENTS:
            continue
        cluster_id = ev.get("cluster_id")
        consumed = False
        for later in tail[i + 1 :]:
            if (
                later.get("event") == "cluster_complete"
                and later.get("cluster_id") == cluster_id
            ):
                consumed = True
                break
        if not consumed:
            pending.append(ev)
    return pending


def current_branch_head(block_id: str, cluster_id: str | None) -> str | None:
    """Return the current HEAD of the relevant branch, or None if missing."""
    ref = (
        f"block/{block_id}/{cluster_id}"
        if cluster_id
        else f"block/{block_id}/integration"
    )
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--verify", ref],
            capture_output=True,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError:
        return None
    return out.stdout.strip()


def evaluate(events: list[dict], block_id: str) -> dict:
    pending = collect_pending_verdicts(events)
    stale: list[dict] = []
    for ev in pending:
        payload = ev.get("payload") or {}
        emitted = payload.get("head_sha_at_emit")
        cluster_id = ev.get("cluster_id")
        base = {
            "event": ev.get("event"),
            "cluster_id": cluster_id,
            "ts": ev.get("ts"),
            "head_sha_at_emit": emitted,
        }
        if not emitted:
            stale.append({**base, "actual": None, "reason": "field_missing"})
            continue
        actual = current_branch_head(block_id, cluster_id)
        if actual is None:
            stale.append({**base, "actual": None, "reason": "branch_missing"})
            continue
        if emitted != actual:
            stale.append({**base, "actual": actual, "reason": "sha_mismatch"})

    result: dict = {"ok": not stale, "checked": len(pending)}
    if stale:
        result["stale"] = stale
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--block", required=True, help="block ID (e.g. F1)")
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
    print(json.dumps(evaluate(events, args.block)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
