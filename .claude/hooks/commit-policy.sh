#!/usr/bin/env bash
# commit-policy.sh, PreToolUse hook for Bash "git commit …".
# Blocks Conventional-Commits violations, AI-authorship trailers,
# --amend / --no-verify / -A / --all, and non-ASCII subject lines.
#
# Reads Claude Code hook JSON from stdin. Exit 2 blocks the tool call.
# Exit 0 allows. Stderr goes to the user + agent.

set -u

input="$(cat)"
tool_name=$(printf '%s' "$input" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("tool_name",""))' 2>/dev/null || echo "")
command=$(printf '%s' "$input" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("tool_input",{}).get("command",""))' 2>/dev/null || echo "")

if [ "$tool_name" != "Bash" ]; then exit 0; fi
case "$command" in *"git commit"*) : ;; *) exit 0 ;; esac

block() { echo "commit-policy: $1" 1>&2; exit 2; }

# Flag checks on the command line.
case "$command" in
  *"--amend"*)      block "git commit --amend is forbidden (create a NEW commit instead)." ;;
  *"--no-verify"*)  block "--no-verify is forbidden (fix the underlying hook failure)." ;;
esac
# Match "git add -A", "git add --all", and "git add ." only when the arg is
# a complete token (followed by whitespace / end-of-string). This avoids a
# false positive on e.g. "git add .claude/settings.json".
if [[ "$command" =~ (^|[[:space:]])git[[:space:]]+add[[:space:]]+(-A|--all|\.)([[:space:]]|$|\&|\;) ]]; then
  block "stage explicit paths; 'git add -A/--all/.' is forbidden."
fi

# Extract the commit message. Supports -m "…", -m'…', and -F <path>.
msg=""
py_extract=$(cat <<'PY'
import json,re,sys,shlex,pathlib
cmd=json.load(sys.stdin).get("tool_input",{}).get("command","")
try:
    parts=shlex.split(cmd)
except ValueError:
    parts=cmd.split()
m=""
i=0
while i < len(parts):
    p=parts[i]
    if p in ("-m","--message") and i+1 < len(parts):
        m = parts[i+1]; break
    if p.startswith("-m") and len(p) > 2:
        m = p[2:]; break
    if p.startswith("--message="):
        m = p.split("=",1)[1]; break
    if p in ("-F","--file") and i+1 < len(parts):
        path = parts[i+1]
        try:
            m = pathlib.Path(path).read_text(encoding="utf-8", errors="replace")
        except Exception:
            m = ""
        break
    i += 1
print(m)
PY
)
msg=$(printf '%s' "$input" | python3 -c "$py_extract" 2>/dev/null || echo "")

if [ -z "$msg" ]; then
  # Allow interactive "git commit" (no -m / -F) to proceed; the editor path
  # is rarely used by agents and we cannot inspect the message here.
  exit 0
fi

subject=$(printf '%s' "$msg" | head -n 1)

# Conventional Commits prefix.
if ! printf '%s' "$subject" | grep -Eq '^(feat|fix|refactor|test|docs|chore|build|ci|perf|style|revert)(\([a-zA-Z0-9._/-]+\))?: .+'; then
  block "subject must match Conventional Commits '<type>(<scope>): <subject>', got: $subject"
fi

# Non-ASCII in subject.
if printf '%s' "$subject" | LC_ALL=C grep -q '[^[:print:]\t]'; then
  block "subject contains non-ASCII characters; full Unicode is allowed only in the body."
fi
if printf '%s' "$subject" | python3 -c 'import sys;s=sys.stdin.read();sys.exit(0 if all(ord(c)<128 for c in s) else 1)'; then :; else
  block "subject contains non-ASCII characters; full Unicode is allowed only in the body."
fi

# Forbidden AI-authorship trailers anywhere in the message.
if printf '%s' "$msg" | grep -Eiq '(co-authored-by:[[:space:]]*claude|generated with \[?claude code|🤖 generated)'; then
  block "AI-authorship trailer detected (Co-Authored-By: Claude / 🤖 Generated …). Remove it."
fi

exit 0
