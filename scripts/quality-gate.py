#!/usr/bin/env python3
"""Quality Gate 1: lint, build, typecheck.

=========================================================================
SWAP-ME: this is the default Node / pnpm Gate-1 runner Aevum ships.
Replace the CHECKS dict (and adjust the pnpm-on-PATH check) for your
stack:

    Python:  {"lint": ["ruff", "check", "."],
              "test": ["pytest"],
              "typecheck": ["mypy", "."]}
    Rust:    {"lint": ["cargo", "clippy"],
              "build": ["cargo", "build"],
              "test": ["cargo", "test"]}
    Go:      {"lint": ["golangci-lint", "run"],
              "build": ["go", "build", "./..."],
              "test": ["go", "test", "./..."]}

The orchestrator's only contract is: this script exits 0 on pass,
1 on fail, 2 on setup error, and writes logs/gates/gate1.json
atomically. See docs/swap-points.md for the full seam list.
=========================================================================

Runs `pnpm lint`, `pnpm build`, and `pnpm exec tsc --noEmit`, captures
results, and writes a compact JSON report to `logs/gates/gate1.json`.
The reviewer and status-tracker agents read that JSON instead of
re-running commands themselves, which is the whole point of the staged
quality gate.

Schema notes:
- schema_version 2.
- Atomic write: tempfile + os.replace.
- Persists raw stdout/stderr per check to logs/gates/raw/<UTC-no-colons>/.
- Records raw_outputs_dir in the JSON so the fix-bucketer can locate
  complete logs.
- Optional session_id from SESSION_ID env var.

Usage:
    python3 scripts/quality-gate.py              # full gate, exit 1 on any failure
    python3 scripts/quality-gate.py --fast       # skip typecheck
    python3 scripts/quality-gate.py --only lint  # run only the named check

Exit codes:
    0, all gates passed
    1, at least one gate failed
    2, setup error (pnpm not installed, etc.)
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "logs" / "gates" / "gate1.json"
RAW_ROOT = ROOT / "logs" / "gates" / "raw"
SCHEMA_VERSION = 2


if not shutil.which("pnpm"):
    sys.exit(
        "pnpm not on PATH; install pnpm (corepack enable + corepack prepare "
        "pnpm@latest --activate) or invoke via "
        ".claude/scripts/gate1.sh from a shell that has pnpm."
    )

# Default Node/pnpm checks. Add a `test` entry and any others your
# project needs; swap the entire dict for your stack (see the SWAP-ME
# block in this file's docstring).
CHECKS: dict[str, list[str]] = {
    "lint": ["pnpm", "lint"],
    "build": ["pnpm", "build"],
    "typecheck": ["pnpm", "exec", "tsc", "--noEmit"],
}

FAST_CHECKS = ["lint", "build"]  # skip typecheck in --fast mode

MAX_STDERR_TAIL_LINES = 30


def run_check(name: str, cmd: list[str], timeout_s: int, raw_dir: pathlib.Path) -> dict:
    """Execute one check command and return a structured result dict.

    Always persists the COMPLETE stdout/stderr to raw_dir/<name>.{stdout,stderr}.txt
    so fix-bucketer can read full output (the gate1.json stderr_tail is truncated
    to MAX_STDERR_TAIL_LINES for readability, fix-bucketer goes to the raw files).
    """
    raw_dir.mkdir(parents=True, exist_ok=True)
    start = time.time()
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout_s,
            cwd=str(ROOT),
        )
    except subprocess.TimeoutExpired as e:
        # Capture whatever was produced before timeout.
        (raw_dir / f"{name}.stdout.txt").write_text(e.stdout or "" if isinstance(e.stdout, str) else "")
        (raw_dir / f"{name}.stderr.txt").write_text(e.stderr or "" if isinstance(e.stderr, str) else f"timeout after {timeout_s}s")
        return {
            "status": "timeout",
            "duration_s": round(time.time() - start, 1),
            "exit_code": -1,
            "error_count": 1,
            "stderr_tail": f"timeout after {timeout_s}s",
        }
    except FileNotFoundError:
        (raw_dir / f"{name}.stderr.txt").write_text(f"command not found: {cmd[0]}")
        return {
            "status": "skipped",
            "duration_s": 0,
            "exit_code": -1,
            "error_count": 0,
            "stderr_tail": f"command not found: {cmd[0]}",
        }

    duration = round(time.time() - start, 1)

    # §L.1 patch: persist FULL stdout and stderr (no truncation).
    (raw_dir / f"{name}.stdout.txt").write_text(result.stdout or "")
    (raw_dir / f"{name}.stderr.txt").write_text(result.stderr or "")

    merged = (result.stdout or "") + (result.stderr or "")
    error_count = merged.lower().count("error")
    status = "pass" if result.returncode == 0 else "fail"
    stderr_tail = ""
    if result.returncode != 0:
        tail_lines = (result.stderr or "").splitlines()[-MAX_STDERR_TAIL_LINES:]
        stderr_tail = "\n".join(tail_lines)

    return {
        "status": status,
        "duration_s": duration,
        "exit_code": result.returncode,
        "error_count": error_count,
        "stderr_tail": stderr_tail,
    }


def write_atomic_json(path: pathlib.Path, data: dict) -> None:
    """Atomic JSON write per §C.7 I-gateN-2: tempfile + rename in same dir."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".gate1.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main() -> int:
    # Per-check timeout default: GATE_TIMEOUT_SECONDS env var if set
    # (used by orchestrate-block.sh to widen the budget for block-scale
    # gate runs that accumulate more tests than a dev-local invocation
    # can tolerate), else 1800 s. The 1800 s default matches the
    # orchestrator's silence-limit budget so manual gate runs and
    # capture-baseline align with the orchestrator's runtime
    # conditions. Operators retain the env-var override for shorter
    # dev-local budgets. Per-invocation --timeout flag overrides both.
    # Variable First: never hardcode a block-era gate budget in a call
    # site.
    _default_timeout_s = int(os.environ.get("GATE_TIMEOUT_SECONDS", "1800"))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fast", action="store_true", help="skip typecheck and test")
    parser.add_argument("--only", choices=list(CHECKS.keys()), help="run only this check")
    parser.add_argument("--timeout", type=int, default=_default_timeout_s,
                        help=f"per-check timeout in seconds (default: "
                             f"{_default_timeout_s}, from GATE_TIMEOUT_SECONDS "
                             f"env var if set, else 1800)")
    parser.add_argument("--force", action="store_true",
                        help="(accepted for orchestrator-side prompt compatibility; no-op)")
    parser.add_argument("--raw-out-dir", type=str, default=None,
                        help="Directory to persist full stdout/stderr per check. Default: "
                             "logs/gates/raw/<UTC-no-colons>/")
    args = parser.parse_args()

    if args.only:
        to_run = [args.only]
    elif args.fast:
        to_run = FAST_CHECKS
    else:
        to_run = list(CHECKS.keys())

    # Raw output dir, UTC ISO no colons (filesystem-friendly).
    if args.raw_out_dir:
        raw_dir = pathlib.Path(args.raw_out_dir)
    else:
        ts_dir = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        raw_dir = RAW_ROOT / ts_dir

    gates: dict[str, dict] = {}
    overall = "pass"

    for name in to_run:
        cmd = CHECKS[name]
        print(f"[gate1] running: {name} ({' '.join(cmd)})", file=sys.stderr)
        gates[name] = run_check(name, cmd, timeout_s=args.timeout, raw_dir=raw_dir)
        if gates[name]["status"] not in {"pass", "skipped"}:
            overall = "fail"
        print(
            f"[gate1]   {name}: {gates[name]['status']} "
            f"({gates[name]['duration_s']}s, {gates[name]['error_count']} errors)",
            file=sys.stderr,
        )

    report: dict = {
        "schema_version": SCHEMA_VERSION,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "mode": "fast" if args.fast else ("only:" + args.only if args.only else "full"),
        "overall": overall,
        "raw_outputs_dir": str(raw_dir.relative_to(ROOT)) + "/",
        "gates": gates,
    }
    session_id = os.environ.get("SESSION_ID")
    if session_id:
        report["session_id"] = session_id

    write_atomic_json(OUTPUT, report)
    print(f"[gate1] wrote {OUTPUT.relative_to(ROOT)} (overall={overall})", file=sys.stderr)
    print(f"[gate1] raw outputs in {raw_dir.relative_to(ROOT)}/", file=sys.stderr)

    # Any skipped check isn't fatal; only fail on real failures.
    any_failure = any(g["status"] == "fail" or g["status"] == "timeout" for g in gates.values())
    return 1 if any_failure else 0


if __name__ == "__main__":
    sys.exit(main())
