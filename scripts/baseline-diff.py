#!/usr/bin/env python3
"""Gate-1 delta against a block baseline.

Two modes:
  --capture   fingerprint every error in logs/gates/raw/<latest>/ and write
              docs/blocks/<BLOCK>/baseline.json.
  --diff      fingerprint current raw gates and diff against the baseline;
              write logs/gates/gate1-delta.json with verdict in the fixed enum
              {delta_zero, delta_regression, fail}.

A fingerprint is the tuple (file_rel, rule_id, template_hash), where
template_hash is a SHA-256 (16-char slice) of the error message with all
numerics, hex addresses, and long hex tokens normalised to placeholders. An
error is a regression iff its fingerprint is absent from the baseline.

Supported tools, via the line formats they emit:
  mypy     <file>:<line>: error: <msg>  [<rule>]
  ruff     <file>:<line>:<col>: <RULE-CODE> <msg>
  tsc      <file>(<line>,<col>): error TS<NNNN>: <msg>
  eslint   <file>:<line>:<col>: <msg>  <rule>
  pytest   FAILED <file>::<test> - <exception>

Unparseable lines are dropped. Verdict `fail` is reserved for operational
errors (missing files, etc.), gate-pipeline failures themselves produce
delta_zero or delta_regression depending on the diff.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import sys
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
GATE1_RAW_ROOT = ROOT / "logs" / "gates" / "raw"
GATE1_OUT = ROOT / "logs" / "gates" / "gate1-delta.json"
BLOCKS_ROOT = ROOT / "docs" / "blocks"
SCHEMA_VERSION = 1

NUMERIC_RE = re.compile(r"\b\d+\b")
HEX_RE = re.compile(r"0x[0-9a-fA-F]+")
LONGHEX_RE = re.compile(r"\b[a-f0-9]{8,}\b")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
TURBO_PREFIX_RE = re.compile(r"^@[\w/-]+:\w+:\s*")

MYPY_RE = re.compile(r"^([^:]+):(\d+):(?:(\d+):)?\s*error:\s*(.+?)(?:\s*\[([\w-]+)\])?$")
RUFF_RE = re.compile(r"^([^:]+):(\d+):(\d+):?\s+([A-Z][A-Z0-9]{1,5})\s+(.+)$")
TSC_RE = re.compile(r"^([^()]+)\((\d+),(\d+)\):\s*error\s+(TS\d+):\s*(.+)$")
ESLINT_RE = re.compile(r"^\s*(\d+):(\d+)\s+(?:error|warning)\s+(.+?)\s+([@\w/-]+)\s*$")
PYTEST_RE = re.compile(r"^FAILED\s+([^:]+(?:::[\w\[\].-]+)+)\s*-\s*(.+)$")


def _strip_line(line: str) -> str:
    line = ANSI_RE.sub("", line)
    line = TURBO_PREFIX_RE.sub("", line)
    return line.rstrip()


def _template(text: str) -> str:
    """Normalise volatile numerics so the same error hashes identically."""
    text = HEX_RE.sub("<HEX>", text)
    text = LONGHEX_RE.sub("<HEX>", text)
    text = NUMERIC_RE.sub("<N>", text)
    return text.strip()


def _hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def _rel(path: str) -> str:
    p = pathlib.Path(path)
    try:
        return p.resolve().relative_to(ROOT).as_posix()
    except (ValueError, OSError):
        return p.as_posix()


def _raw_dir_label(raw_dir: pathlib.Path) -> str:
    try:
        return raw_dir.relative_to(ROOT).as_posix()
    except ValueError:
        return raw_dir.as_posix()


def _fp(file_rel: str, rule: str, msg: str) -> dict:
    return {
        "file": file_rel,
        "rule": rule,
        "tpl": _hash(_template(msg)),
        "msg_preview": msg[:160],
    }


def parse_line(line: str) -> dict | None:
    """Return a fingerprint dict if the line matches a known error format."""
    s = _strip_line(line)
    if not s:
        return None

    m = RUFF_RE.match(s)
    if m:
        return _fp(_rel(m.group(1)), f"ruff.{m.group(4)}", m.group(5))

    m = MYPY_RE.match(s)
    if m:
        rule = m.group(5) or "unknown"
        return _fp(_rel(m.group(1)), f"mypy.{rule}", m.group(4))

    m = TSC_RE.match(s)
    if m:
        return _fp(_rel(m.group(1)), f"tsc.{m.group(4)}", m.group(5))

    m = ESLINT_RE.match(s)
    if m:
        return _fp("<eslint>", f"eslint.{m.group(4)}", m.group(3))

    m = PYTEST_RE.match(s)
    if m:
        test_id = m.group(1)
        file_part = test_id.split("::", 1)[0]
        return _fp(_rel(file_part), "pytest.FAILED", m.group(2))

    return None


def parse_raw_dir(raw_dir: pathlib.Path) -> list[dict]:
    errors: list[dict] = []
    seen: set[tuple[str, str, str]] = set()
    for p in sorted(raw_dir.glob("*.txt")):
        try:
            text = p.read_text(errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            fp = parse_line(line)
            if fp is None:
                continue
            key = (fp["file"], fp["rule"], fp["tpl"])
            if key in seen:
                continue
            seen.add(key)
            errors.append(fp)
    return errors


def latest_raw_dir() -> pathlib.Path | None:
    if not GATE1_RAW_ROOT.exists():
        return None
    dated = [d for d in GATE1_RAW_ROOT.iterdir() if d.is_dir() and re.fullmatch(r"\d{8}T\d{6}Z", d.name)]
    if not dated:
        return None
    return max(dated, key=lambda d: d.name)


def _atomic_write(path: pathlib.Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n")
    os.replace(tmp, path)


def capture(block_id: str, raw_dir: pathlib.Path) -> int:
    errors = parse_raw_dir(raw_dir)
    out = BLOCKS_ROOT / block_id / "baseline.json"
    payload = {
        "schema": SCHEMA_VERSION,
        "block_id": block_id,
        "captured_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "raw_dir": _raw_dir_label(raw_dir),
        "error_count": len(errors),
        "errors": errors,
    }
    _atomic_write(out, payload)
    print(f"baseline: {len(errors)} error fingerprints -> {out.relative_to(ROOT)}")
    return 0


def diff(block_id: str, raw_dir: pathlib.Path) -> int:
    baseline_path = BLOCKS_ROOT / block_id / "baseline.json"
    if not baseline_path.exists():
        sys.stderr.write(f"ERROR: no baseline at {baseline_path.relative_to(ROOT)}\n")
        _atomic_write(GATE1_OUT, {
            "schema": SCHEMA_VERSION,
            "block_id": block_id,
            "verdict": "fail",
            "reason": "baseline_missing",
        })
        return 2

    baseline = json.loads(baseline_path.read_text())
    baseline_keys = {(e["file"], e["rule"], e["tpl"]) for e in baseline["errors"]}

    current = parse_raw_dir(raw_dir)
    current_keys = {(e["file"], e["rule"], e["tpl"]) for e in current}

    new_keys = current_keys - baseline_keys
    fixed_keys = baseline_keys - current_keys

    verdict = "delta_zero" if not new_keys else "delta_regression"

    new_errors = [e for e in current if (e["file"], e["rule"], e["tpl"]) in new_keys]

    result = {
        "schema": SCHEMA_VERSION,
        "block_id": block_id,
        "verdict": verdict,
        "baseline_count": len(baseline_keys),
        "current_count": len(current_keys),
        "new_count": len(new_keys),
        "fixed_count": len(fixed_keys),
        "baseline_path": baseline_path.relative_to(ROOT).as_posix(),
        "raw_dir": _raw_dir_label(raw_dir),
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "new_errors": new_errors,
    }
    _atomic_write(GATE1_OUT, result)

    print(f"verdict: {verdict}")
    print(f"baseline: {len(baseline_keys)}  current: {len(current_keys)}  new: {len(new_keys)}  fixed: {len(fixed_keys)}")
    if new_keys:
        for e in new_errors[:10]:
            print(f"  NEW {e['rule']:<20} {e['file']}  {e['msg_preview']}")
        if len(new_errors) > 10:
            print(f"  ... and {len(new_errors) - 10} more")
    return 0 if verdict == "delta_zero" else 1


def main() -> int:
    p = argparse.ArgumentParser(description="Gate-1 baseline capture and delta diff.")
    p.add_argument("--block", required=True, help="block id, e.g. B1")
    p.add_argument("--mode", choices=["capture", "diff"], required=True)
    p.add_argument("--raw-dir", help="override the gates/raw subdir (defaults to latest)")
    args = p.parse_args()

    if args.raw_dir:
        raw_dir = pathlib.Path(args.raw_dir)
        if not raw_dir.is_absolute():
            raw_dir = ROOT / raw_dir
    else:
        raw_dir = latest_raw_dir()
        if raw_dir is None:
            sys.stderr.write("ERROR: no gates/raw/<timestamp>/ directory found\n")
            return 2

    if not raw_dir.is_dir():
        sys.stderr.write(f"ERROR: raw dir missing: {raw_dir}\n")
        return 2

    if args.mode == "capture":
        return capture(args.block, raw_dir)
    return diff(args.block, raw_dir)


if __name__ == "__main__":
    sys.exit(main())
