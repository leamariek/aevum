#!/usr/bin/env bash
# forbidden-patterns-live.sh -- PreToolUse hook for Write|Edit.
# Scans the content that is about to be written against the YAML pattern
# block in .claude/rules/forbidden-patterns.md. Critical hits introduced by
# this edit block the call (exit 2); warnings go to stderr and allow.
#
# Complements forbidden-patterns.sh (which runs at git commit). This file
# catches violations at edit time so bad text never lands on disk.
#
# Scan strategy:
#   Edit        -> scan new_string only (the text being inserted).
#   Write new   -> scan whole content.
#   Write over  -> scan only lines that differ from the current file content.
#
# Pre-existing violations in unchanged lines are not re-flagged.

set -u
CLAUDE_HOOK_PAYLOAD="$(cat)"
export CLAUDE_HOOK_PAYLOAD

python3 <<'PY'
# -*- coding: utf-8 -*-
import difflib
import fnmatch
import json
import os
import pathlib
import re
import sys

try:
    import yaml
except ImportError:
    sys.exit(0)

raw = os.environ.get("CLAUDE_HOOK_PAYLOAD", "")
try:
    p = json.loads(raw) if raw.strip() else {}
except Exception:
    sys.exit(0)

tool = p.get("tool_name", "")
if tool not in ("Write", "Edit"):
    sys.exit(0)

tool_input = p.get("tool_input", {})
path = str(tool_input.get("file_path", "")).replace("\\", "/")
if not path:
    sys.exit(0)

repo_root = os.environ.get("CLAUDE_PROJECT_DIR", "").rstrip("/")
if repo_root and path.startswith(repo_root + "/"):
    rel_path = path[len(repo_root) + 1:]
else:
    rel_path = path

rules_file = pathlib.Path(repo_root or ".") / ".claude" / "rules" / "forbidden-patterns.md"
if not rules_file.is_file():
    sys.exit(0)

text = rules_file.read_text(encoding="utf-8", errors="replace")
m = re.search(r"```yaml\s*\n(.*?)\n```", text, flags=re.S)
if not m:
    sys.exit(0)
try:
    doc = yaml.safe_load(m.group(1)) or {}
except Exception:
    sys.exit(0)

patterns = doc.get("patterns", [])
if not patterns:
    sys.exit(0)

TEST_GLOBS = [
    "**/*.test.*", "**/*.spec.*",
    "**/tests/**", "**/__tests__/**",
    "**/test_*.py",
]

def build_added_lines():
    if tool == "Edit":
        new_str = tool_input.get("new_string", "")
        return [(i + 1, line) for i, line in enumerate(new_str.splitlines())]
    # Write
    new_content = tool_input.get("content", "")
    new_lines = new_content.splitlines()
    abs_path = pathlib.Path(path)
    if not abs_path.is_absolute() and repo_root:
        abs_path = pathlib.Path(repo_root) / path
    if abs_path.exists():
        try:
            orig_lines = abs_path.read_text(encoding="utf-8", errors="replace").splitlines()
        except Exception:
            orig_lines = []
    else:
        orig_lines = []
    added = []
    sm = difflib.SequenceMatcher(a=orig_lines, b=new_lines, autojunk=False)
    for tag, _i1, _i2, j1, j2 in sm.get_opcodes():
        if tag in ("insert", "replace"):
            for offset in range(j1, j2):
                added.append((offset + 1, new_lines[offset]))
    return added

added_lines = build_added_lines()
if not added_lines:
    sys.exit(0)

def path_matches(p, globs):
    return any(fnmatch.fnmatch(p, g) for g in globs)

critical_hits = []
warning_hits = []

for rule in patterns:
    rid = rule.get("id", "<unnamed>")
    try:
        regex = re.compile(rule["regex"])
    except re.error as e:
        print(f"forbidden-patterns-live: skip {rid}: bad regex ({e})", file=sys.stderr)
        continue
    severity = rule.get("severity", "warning")
    incl = rule.get("paths") or ["**/*"]
    excl = rule.get("exclude") or []
    hint = rule.get("hint", "")

    if not path_matches(rel_path, incl):
        continue
    if path_matches(rel_path, excl):
        continue
    if path_matches(rel_path, TEST_GLOBS):
        continue

    for lineno, line in added_lines:
        if regex.search(line):
            bucket = critical_hits if severity == "critical" else warning_hits
            bucket.append((rid, rel_path, lineno, line.strip(), hint))

if warning_hits:
    print("forbidden-patterns-live: warnings (non-blocking):", file=sys.stderr)
    for rid, pp, ln, ll, hh in warning_hits[:20]:
        print(f"  [warn] {rid} {pp}:{ln}  {ll[:120]}", file=sys.stderr)
        if hh:
            print(f"         hint: {hh}", file=sys.stderr)

if critical_hits:
    print("forbidden-patterns-live: blocking -- critical pattern(s) in edit:", file=sys.stderr)
    for rid, pp, ln, ll, hh in critical_hits[:20]:
        print(f"  [block] {rid} {pp}:{ln}  {ll[:120]}", file=sys.stderr)
        if hh:
            print(f"          hint: {hh}", file=sys.stderr)
    sys.exit(2)

sys.exit(0)
PY
