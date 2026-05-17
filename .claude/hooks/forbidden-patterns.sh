#!/usr/bin/env bash
# forbidden-patterns.sh, PreToolUse hook for Bash "git commit …".
# Scans `git diff --cached` for patterns defined in
# .claude/rules/forbidden-patterns.md (YAML block). Critical → block (exit 2);
# Warning → stderr note + allow (exit 0).
#
# Test files (*.test.*, *.spec.*, test_*.py, **/tests/**) are globally exempt.

set -u

input="$(cat)"
tool_name=$(printf '%s' "$input" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("tool_name",""))' 2>/dev/null || echo "")
command=$(printf '%s' "$input" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("tool_input",{}).get("command",""))' 2>/dev/null || echo "")

if [ "$tool_name" != "Bash" ]; then exit 0; fi
case "$command" in *"git commit"*) : ;; *) exit 0 ;; esac

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
rules_file="$repo_root/.claude/rules/forbidden-patterns.md"
if [ ! -f "$rules_file" ]; then exit 0; fi

# Get the staged diff (paths + body). Empty diff → nothing to scan.
diff_body=$(git -C "$repo_root" diff --cached --no-color 2>/dev/null || true)
if [ -z "$diff_body" ]; then exit 0; fi

python3 - "$rules_file" <<'PY'
import fnmatch, re, sys, subprocess, pathlib
try:
    import yaml
except ImportError:
    # PyYAML missing → cannot enforce; fail open like forbidden-patterns-live.sh.
    sys.exit(0)

rules_path = pathlib.Path(sys.argv[1])
text = rules_path.read_text(encoding="utf-8", errors="replace")

# Extract the first ```yaml … ``` block.
m = re.search(r"```yaml\s*\n(.*?)\n```", text, flags=re.S)
if not m:
    sys.exit(0)  # nothing to enforce.
try:
    doc = yaml.safe_load(m.group(1)) or {}
except Exception as e:
    print(f"forbidden-patterns: YAML parse error, {e}", file=sys.stderr)
    sys.exit(0)

patterns = doc.get("patterns", [])
if not patterns:
    sys.exit(0)

test_globs = [
    "**/*.test.*", "**/*.spec.*", "**/tests/**",
    "**/__tests__/**", "**/test_*.py",
]

# Collect per-file staged additions (+ lines, not - or context).
proc = subprocess.run(
    ["git", "diff", "--cached", "--no-color", "-U0"],
    capture_output=True, text=True, check=False,
)
current_file = None
added = {}  # path -> list of (lineno_in_file, line)
new_lineno = 0
for raw in proc.stdout.splitlines():
    if raw.startswith("+++ b/"):
        current_file = raw[6:]
        added[current_file] = []
        continue
    if raw.startswith("+++ /dev/null"):
        current_file = None
        continue
    if raw.startswith("@@"):
        # @@ -a,b +c,d @@ , we only care about +c.
        mm = re.search(r"\+(\d+)(?:,(\d+))?", raw)
        if mm:
            new_lineno = int(mm.group(1))
        continue
    if current_file is None:
        continue
    if raw.startswith("+") and not raw.startswith("+++"):
        added[current_file].append((new_lineno, raw[1:]))
        new_lineno += 1
    elif raw.startswith(" "):
        new_lineno += 1

def path_matches(path, globs):
    return any(fnmatch.fnmatch(path, g) for g in globs)

critical_hits = []
warning_hits = []

for rule in patterns:
    rid = rule.get("id", "<unnamed>")
    try:
        regex = re.compile(rule["regex"])
    except re.error as e:
        print(f"forbidden-patterns: skip {rid}: bad regex ({e})", file=sys.stderr)
        continue
    severity = rule.get("severity", "warning")
    incl = rule.get("paths") or ["**/*"]
    excl = rule.get("exclude") or []
    hint = rule.get("hint", "")

    for path, lines in added.items():
        if not path_matches(path, incl):
            continue
        if path_matches(path, excl):
            continue
        if path_matches(path, test_globs):
            continue
        for lineno, line in lines:
            if regex.search(line):
                (critical_hits if severity == "critical" else warning_hits).append(
                    (rid, path, lineno, line.strip(), hint)
                )

if warning_hits:
    print("forbidden-patterns: warnings (non-blocking):", file=sys.stderr)
    for rid, path, lineno, line, hint in warning_hits:
        print(f"  [warn] {rid} {path}:{lineno}  {line[:120]}", file=sys.stderr)
        if hint:
            print(f"         hint: {hint}", file=sys.stderr)

if critical_hits:
    print("forbidden-patterns: blocking, critical pattern(s) found in staged diff:", file=sys.stderr)
    for rid, path, lineno, line, hint in critical_hits:
        print(f"  [block] {rid} {path}:{lineno}  {line[:120]}", file=sys.stderr)
        if hint:
            print(f"          hint: {hint}", file=sys.stderr)
    sys.exit(2)

sys.exit(0)
PY
