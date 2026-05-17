#!/usr/bin/env bash
# plan-frontmatter.sh, PreToolUse hook for Write|Edit under
# docs/plans/ and archive/plans/. Requires a valid YAML frontmatter block
# with required fields, and bumps `updated` on substantive edits.

set -u
CLAUDE_HOOK_PAYLOAD="$(cat)"
export CLAUDE_HOOK_PAYLOAD

python3 <<'PY'
import json, os, pathlib, re, sys, datetime

raw = os.environ.get("CLAUDE_HOOK_PAYLOAD", "")
try:
    p = json.loads(raw) if raw.strip() else {}
except Exception as e:
    print(f"plan-frontmatter: malformed hook JSON: {e}", file=sys.stderr)
    sys.exit(0)

tool = p.get("tool_name", "")
if tool not in ("Write", "Edit"):
    sys.exit(0)

tool_input = p.get("tool_input", {})
path = str(tool_input.get("file_path", ""))
if not path:
    sys.exit(0)

norm = path.replace("\\", "/").lower()
in_plans = ("/docs/plans/" in norm or norm.startswith("docs/plans/")
            or "/archive/plans/" in norm or norm.startswith("archive/plans/"))
if not in_plans:
    sys.exit(0)
if not norm.endswith(".md"):
    sys.exit(0)
if norm.endswith("/_session_template.md") or norm.endswith("/readme.md"):
    sys.exit(0)
# Per-task execution prompts are transcripts, not plans. Canonical location
# is logs/phase-N/*-prompt.md; legacy copies live under
# docs/plans/sessions/prompts/, both are exempt.
if "/sessions/prompts/" in norm and norm.endswith("-prompt.md"):
    sys.exit(0)

def block(msg):
    print(f"plan-frontmatter: {msg}", file=sys.stderr)
    sys.exit(2)

if tool == "Write":
    content = tool_input.get("content", "")
else:
    try:
        orig = pathlib.Path(path).read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        block(f"Edit against missing file: {path}")
    old = tool_input.get("old_string", "")
    new = tool_input.get("new_string", "")
    if tool_input.get("replace_all", False):
        content = orig.replace(old, new)
    else:
        content = orig.replace(old, new, 1)

m = re.match(r"^---\s*\n(.*?)\n---\s*(?:\n|$)", content, flags=re.S)
if not m:
    block(f"missing YAML frontmatter in {path}, see .claude/rules/plan-metadata.md")

fm_text = m.group(1)
try:
    import yaml
    fm = yaml.safe_load(fm_text) or {}
except Exception as e:
    block(f"invalid YAML frontmatter in {path}: {e}")

required = ("id", "title", "created", "updated", "status", "owner")
placeholders = {"<kebab-case-slug>", "<Short Human Title>", "<name-or-agent-id>"}
missing = [k for k in required
           if k not in fm
           or fm[k] in (None, "")
           or str(fm[k]) in placeholders]
if missing:
    block(f"{path}: missing/placeholder frontmatter field(s): {', '.join(missing)}")

allowed_status = {"draft", "active", "completed", "superseded", "archived"}
if str(fm["status"]) not in allowed_status:
    block(f"{path}: status='{fm['status']}' not in {sorted(allowed_status)}")

ts_re = re.compile(r"^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?$")
for k in ("created", "updated"):
    raw_v = fm[k]
    if isinstance(raw_v, (datetime.datetime, datetime.date)):
        v = raw_v.isoformat()
    else:
        v = str(raw_v)
    if not ts_re.match(v):
        block(f"{path}: {k}='{v}' is not ISO 8601 (e.g. 2026-04-16T00:00:00Z)")

if tool == "Edit":
    try:
        raw_u = fm["updated"]
        if isinstance(raw_u, datetime.datetime):
            upd = raw_u
        elif isinstance(raw_u, datetime.date):
            upd = datetime.datetime.combine(raw_u, datetime.time.min)
        else:
            upd = datetime.datetime.fromisoformat(str(raw_u).replace("Z", "+00:00"))
        if upd.tzinfo is None:
            upd = upd.replace(tzinfo=datetime.timezone.utc)
        now = datetime.datetime.now(datetime.timezone.utc)
        if (now - upd).total_seconds() > 24 * 3600:
            block(f"{path}: `updated` is stale ({fm['updated']}), bump to current UTC on substantive edits.")
    except SystemExit:
        raise
    except Exception as e:
        block(f"{path}: could not parse `updated` timestamp: {e}")

new_status = str(fm["status"])

# status: completed requires `completed:` timestamp.
if new_status == "completed":
    comp = fm.get("completed")
    if comp in (None, ""):
        block(f"{path}: status=completed requires a `completed: <ISO-8601>` field (see plan-metadata.md).")
    comp_str = comp.isoformat() if isinstance(comp, (datetime.datetime, datetime.date)) else str(comp)
    if not ts_re.match(comp_str):
        block(f"{path}: completed='{comp_str}' is not ISO 8601.")

# status: superseded requires `superseded_by:`.
if new_status == "superseded":
    sb_raw = fm.get("superseded_by")
    if sb_raw in (None, ""):
        block(f"{path}: status=superseded requires a `superseded_by: <plan-id>` field (see plan-metadata.md).")

# Ghost-ID validation for `supersedes:` and `superseded_by:`.
def _parse_ref_ids(value):
    if value in (None, ""):
        return []
    if isinstance(value, list):
        return [str(v).strip() for v in value if str(v).strip()]
    # String form: split on comma or ` + ` to support multi-supersession cases.
    parts = re.split(r"\s*[,+]\s*", str(value))
    return [p.strip() for p in parts if p.strip()]

def _load_plan_id_map():
    m = {}
    for root in ("docs/plans", "archive/plans"):
        root_path = pathlib.Path(root)
        if not root_path.exists():
            continue
        for md_file in root_path.rglob("*.md"):
            name = md_file.name.lower()
            if name in ("_session_template.md", "readme.md"):
                continue
            try:
                txt = md_file.read_text(encoding="utf-8", errors="replace")
            except Exception:
                continue
            fmm = re.match(r"^---\s*\n(.*?)\n---\s*(?:\n|$)", txt, flags=re.S)
            if not fmm:
                continue
            try:
                fd = yaml.safe_load(fmm.group(1)) or {}
            except Exception:
                continue
            pid = fd.get("id")
            if pid:
                m[str(pid)] = str(md_file)
    return m

ref_fields = {k: _parse_ref_ids(fm.get(k)) for k in ("supersedes", "superseded_by")}
if any(ref_fields.values()):
    id_map = _load_plan_id_map()
    # Allow self-reference: the file being written counts as its own id.
    own_id = fm.get("id")
    if own_id:
        id_map[str(own_id)] = path
    for field, ids in ref_fields.items():
        for ref_id in ids:
            if ref_id not in id_map:
                block(f"{path}: {field} references '{ref_id}' but no plan with that id exists under docs/plans/ or archive/plans/.")

# Transition graph validation: compare old on-disk status to new status.
disk_path = pathlib.Path(path)
old_status = None
if disk_path.exists():
    try:
        disk_text = disk_path.read_text(encoding="utf-8", errors="replace")
        disk_fm_match = re.match(r"^---\s*\n(.*?)\n---\s*(?:\n|$)", disk_text, flags=re.S)
        if disk_fm_match:
            disk_fm = yaml.safe_load(disk_fm_match.group(1)) or {}
            old_raw = disk_fm.get("status")
            if old_raw:
                old_status = str(old_raw)
    except Exception:
        old_status = None

allowed_transitions = {
    "draft":      {"active", "archived"},
    "active":     {"completed", "superseded", "archived"},
    "completed":  {"superseded", "archived"},
    "superseded": {"archived"},
    "archived":   set(),
}

if old_status and old_status != new_status:
    if old_status not in allowed_transitions:
        block(f"{path}: on-disk status='{old_status}' is not a known lifecycle state.")
    if new_status not in allowed_transitions[old_status]:
        block(f"{path}: forbidden status transition {old_status} -> {new_status} (see .claude/rules/doc-lifecycle.md).")

# Warn (non-blocking) on active plans whose ON-DISK updated is older than 90 days.
# Checking disk (not proposed content) because the 24 h hook forces the new
# `updated` to be fresh; the staleness signal must come from pre-edit state.
if disk_path.exists() and old_status == "active":
    try:
        disk_text  # noqa: F821
        disk_fm_match  # noqa: F821
        if disk_fm_match:
            disk_fm_loaded = yaml.safe_load(disk_fm_match.group(1)) or {}
            raw_old_u = disk_fm_loaded.get("updated")
            if raw_old_u:
                if isinstance(raw_old_u, datetime.datetime):
                    old_upd = raw_old_u
                elif isinstance(raw_old_u, datetime.date):
                    old_upd = datetime.datetime.combine(raw_old_u, datetime.time.min)
                else:
                    old_upd = datetime.datetime.fromisoformat(str(raw_old_u).replace("Z", "+00:00"))
                if old_upd.tzinfo is None:
                    old_upd = old_upd.replace(tzinfo=datetime.timezone.utc)
                now = datetime.datetime.now(datetime.timezone.utc)
                age_days = (now - old_upd).total_seconds() / 86400
                if age_days > 90:
                    print(
                        f"plan-frontmatter: warning: {path} was status=active and untouched for "
                        f"{age_days:.0f} days before this edit. Consider flipping to "
                        f"completed/superseded/archived (see doc-lifecycle.md).",
                        file=sys.stderr,
                    )
    except Exception:
        pass  # never block on warn-path failures

sys.exit(0)
PY
