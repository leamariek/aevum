#!/usr/bin/env python3
"""Block preflight validator.

Runs before ``orchestrate-block.sh`` launches ``claude -p``, so stale
plan inputs never burn worker minutes. Three checks, one script, one
report.

1. Plan structural integrity
   Validate ``docs/blocks/<BLOCK>/block.yaml`` at the schema level:
     - required top-level keys (``id``, ``base_branch``, ``base_sha``,
       ``clusters``);
     - cluster IDs unique; task IDs unique within each cluster;
     - every task carries an ``id`` and non-empty ``acceptance``;
     - exactly one task per cluster has ``parallel: false`` (the
       serialising task);
     - ``depends_on`` entries resolve to existing cluster IDs;
     - no two ``parallel: true`` tasks in the same cluster claim the
       same literal path in ``files_touched_globs``.

2. Base SHA integrity
     - ``base_sha`` resolves to a commit;
     - ``base_sha`` is an ancestor of ``base_branch`` (default ``main``);
       otherwise the block is branching from an unmerged commit.

3. State audit
   For every entry in ``.claude/state.yaml`` ``blockers:``, a cheap probe
   (pure git queries; no subprocess heavier than ``git grep``) classifies
   it as ``reproduces | reproduces_with_drift | stale | unknown``.

   Each task's ``acceptance`` text is scanned for explicit blocker
   cross-references (``blocker[s]? #\\d+``). A task that names a blocker
   the state audit classifies as ``stale`` is flagged: the acceptance
   condition is likely already satisfied, so the task will return a
   no-op.

Output:
  ``logs/blocks/<BLOCK>/preflight.json``   structured report
  stderr                                    human summary

Exit codes:
  0  clean or warnings only (unless ``--strict``)
  2  at least one blocker
  3  invocation error (missing block.yaml, unresolvable SHA, etc.)

Invocation:
  python3 scripts/block-preflight.py <BLOCK_ID>
    [--base-sha <SHA>] [--strict] [--report-only]

Design note: glob-existence checks (do files in ``files_touched_globs``
exist at base_sha?) are deliberately absent. Most tasks legitimately
create new files; a missing target says nothing about plan validity.
The two signals that actually discriminate "plan is fresh" from "plan
is stale" are (a) structural drift in block.yaml and (b) acceptance
conditions that target already-resolved blockers. The preflight checks
both and stays out of the way otherwise.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any, Callable

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
BLOCKS_ROOT = ROOT / "docs" / "blocks"
LOGS_BLOCKS_ROOT = ROOT / "logs" / "blocks"
STATE_YAML = ROOT / ".claude" / "state.yaml"
SCHEMA_VERSION = 1

NON_SOURCE_PREFIXES = (
    "docs/", "archive/", ".claude/", "logs/", "knowledge/", "prompts/",
)
NON_SOURCE_SUFFIXES = (".md", ".mdx")

# Acceptance-text anchor for a state.yaml blocker reference. We match
# the word, then scan forward within the same sentence for numeric
# tokens. Handles singular ("blocker 3"), hash-prefixed ("blocker #3"),
# and list forms ("blockers #3, #4, #5").
BLOCKER_ANCHOR_RE = re.compile(r"(?i)blocker[s]?\b")
SENTENCE_SPLIT_RE = re.compile(r"[.\n]")
BARE_ID_AFTER_ANCHOR_RE = re.compile(r"^\s+(\d+)\b")
HASH_ID_RE = re.compile(r"#\s*(\d+)")
GLOB_META = set("*?[]")

# Block-progress lifecycle events tracked for the post-close-hygiene
# rule. block_abort is deliberately excluded: it fires on every
# refused-relaunch attempt against a closed block, so including it
# would defeat the rule's whole purpose (a closed block whose
# progress.jsonl was polluted by prior failed re-launches would
# never demote to info). The wrapper-authored wedge event is in the
# set because a wedged closure is not a clean closure and re-runs
# must still be refused.
PROGRESS_TERMINAL_EVENTS = frozenset({
    "block_complete",
    "block_signed_off",
    "block_rejected",
    "wrapper_wedge_detected",
})
PROGRESS_CLEAN_CLOSURE_EVENTS = frozenset({
    "block_complete",
    "block_signed_off",
})


# -------------------------------------------------------------------- git
#
# Subprocess wrappers; exercised by the CLI integration run, not unit
# tests. Marked ``pragma: no cover`` because unit-testing these adds
# mocking noise without catching real bugs (the bugs live at the shell
# boundary, which only a live git repo can demonstrate).

def _git(*args: str, check: bool = True) -> str:  # pragma: no cover
    result = subprocess.run(
        ["git", *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if check and result.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(args)} failed ({result.returncode}): "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    return result.stdout


def git_rev_parse(sha_or_ref: str) -> str:  # pragma: no cover
    return _git("rev-parse", "--verify", f"{sha_or_ref}^{{commit}}").strip()


def git_tree_files(sha: str) -> list[str]:  # pragma: no cover
    out = _git("ls-tree", "-r", "--name-only", sha)
    return [line for line in out.splitlines() if line]


def git_ref_reachable(sha: str, ref: str) -> bool:  # pragma: no cover
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", sha, ref],
        cwd=ROOT,
        capture_output=True,
        check=False,
    )
    return result.returncode == 0


def git_grep_files(sha: str, pattern: str) -> list[str]:  # pragma: no cover
    result = subprocess.run(
        ["git", "grep", "-l", "-E", pattern, sha],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode not in (0, 1):
        raise RuntimeError(
            f"git grep failed on '{pattern}' at {sha[:7]}: "
            f"{result.stderr.strip()}"
        )
    paths: list[str] = []
    for line in result.stdout.splitlines():
        _, sep, path = line.partition(":")
        if sep:
            paths.append(path)
    return paths


# ------------------------------------------------------------ findings

class Finding:
    __slots__ = ("severity", "scope", "message", "detail")

    def __init__(
        self,
        severity: str,
        scope: str,
        message: str,
        detail: dict[str, Any] | None = None,
    ) -> None:
        self.severity = severity
        self.scope = scope
        self.message = message
        self.detail = detail or {}

    def to_dict(self) -> dict[str, Any]:
        return {
            "severity": self.severity,
            "scope": self.scope,
            "message": self.message,
            "detail": self.detail,
        }


# -------------------------------------------------- structural checks

def _is_literal(path: str) -> bool:
    return not any(c in GLOB_META for c in path)


def _block_closed_cleanly(root: pathlib.Path, block_id: str) -> bool:
    """True iff the block was signed off after a clean orchestrator close.

    The post-close-hygiene rule: an operator legitimately re-runs
    the gate chain against a closed block when downstream
    preconditions clear (e.g. an external dependency that was
    blocking finally lands post-close). The closed-status finding
    stays a blocker for wedged or in-flight closures, but demotes to
    info when both SIGNED.md is present and progress.jsonl's last
    lifecycle terminal event is a clean closure.

    Three conditions, all required:
      1. logs/blocks/<id>/signoff/SIGNED.md exists.
      2. logs/blocks/<id>/progress.jsonl exists, parses, and contains
         at least one event in PROGRESS_TERMINAL_EVENTS.
      3. The last event in PROGRESS_TERMINAL_EVENTS is a clean-closure
         event (block_complete or block_signed_off).

    block_abort is excluded from PROGRESS_TERMINAL_EVENTS so a
    re-launch attempt against an already-closed block (which itself
    appends block_abort{reason: block_status_closed} to the ledger)
    cannot itself flip a previously clean closure into a non-clean
    one.
    """
    signoff = root / "logs" / "blocks" / block_id / "signoff" / "SIGNED.md"
    if not signoff.exists():
        return False
    progress = root / "logs" / "blocks" / block_id / "progress.jsonl"
    if not progress.exists():
        return False
    try:
        raw = progress.read_text()
    except OSError:
        return False
    last_terminal: str | None = None
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        ev = event.get("event") if isinstance(event, dict) else None
        if isinstance(ev, str) and ev in PROGRESS_TERMINAL_EVENTS:
            last_terminal = ev
    if last_terminal is None:
        return False
    return last_terminal in PROGRESS_CLEAN_CLOSURE_EVENTS


def check_block_structure(
    block: dict[str, Any],
    root: pathlib.Path | None = None,
    block_id: str | None = None,
) -> list[Finding]:
    findings: list[Finding] = []

    if not isinstance(block.get("id"), str):
        findings.append(Finding(
            "blocker", "block", "top-level 'id' missing or not a string",
        ))
    if not isinstance(block.get("base_sha"), str):
        findings.append(Finding(
            "blocker", "block",
            "top-level 'base_sha' missing or not a string",
        ))

    # Block must be active before the orchestrator can dispatch. The
    # orchestrator prompt itself enforces this at runtime via
    # block_abort{reason: "block_status_draft"}, but surfacing it at
    # preflight time gives the operator a single failure path with
    # all activation work to do, rather than discovering it after a
    # successful preflight + spawned inner-claude.
    status = block.get("status")
    if status == "draft":
        findings.append(Finding(
            "blocker", "block",
            "block.yaml status is 'draft'; must be 'active' before "
            "launch. Activation pattern: a single commit that flips "
            "status: draft -> active, populates activated_at + "
            "activated_by, refreshes base_sha to current main tip, "
            "and flips any draft ADRs the block depends on from "
            "proposed -> accepted.",
        ))
    elif status == "closed":
        # Post-close-hygiene exception: when the block closed cleanly
        # (SIGNED.md present and last lifecycle terminal in
        # progress.jsonl is block_complete or
        # block_signed_off) the closed-status finding demotes to
        # info. This supports the legitimate post-close re-run
        # pattern (e.g., re-running a closed block against an
        # external dependency that finally landed) without training
        # operators to reach for --report-only as the bypass.
        # Wedged or in-flight closures must still refuse re-launch,
        # so the helper returns False for those and the original
        # blocker stays.
        clean_close = (
            root is not None
            and block_id is not None
            and _block_closed_cleanly(root, block_id)
        )
        severity = "info" if clean_close else "blocker"
        findings.append(Finding(
            severity, "block",
            "block.yaml status is 'closed'; the block cannot be "
            "relaunched. Closed blocks are immutable by design. "
            "If new work belongs to this scope, open a successor "
            "block with its own block.yaml.",
        ))
    elif status != "active":
        findings.append(Finding(
            "blocker", "block",
            f"block.yaml status is '{status}'; must be 'active' before "
            f"launch. Allowed values: draft (pre-activation), active "
            f"(orchestrator-runnable), closed (immutable historical).",
        ))

    clusters = block.get("clusters")
    if not isinstance(clusters, list) or not clusters:
        findings.append(Finding(
            "blocker", "block",
            "'clusters' must be a non-empty list",
        ))
        return findings

    cluster_ids: set[str] = set()
    for idx, cluster in enumerate(clusters):
        if not isinstance(cluster, dict):
            findings.append(Finding(
                "blocker", f"clusters[{idx}]",
                "cluster must be a mapping",
            ))
            continue
        cid = cluster.get("id")
        scope_c = f"cluster[{cid or idx}]"
        if not isinstance(cid, str) or not cid:
            findings.append(Finding(
                "blocker", scope_c, "cluster 'id' missing or not a string",
            ))
            continue
        if cid in cluster_ids:
            findings.append(Finding(
                "blocker", scope_c, f"duplicate cluster id '{cid}'",
            ))
        cluster_ids.add(cid)

        tasks = cluster.get("tasks")
        if not isinstance(tasks, list) or not tasks:
            findings.append(Finding(
                "blocker", scope_c, "cluster 'tasks' missing or empty",
            ))
            continue

        task_ids: set[str] = set()
        serialising_count = 0
        literal_path_owner: dict[str, str] = {}
        for t_idx, task in enumerate(tasks):
            if not isinstance(task, dict):
                findings.append(Finding(
                    "blocker", f"{cid}:task[{t_idx}]",
                    "task must be a mapping",
                ))
                continue
            tid = task.get("id")
            scope_t = f"{cid}:{tid or t_idx}"
            if not isinstance(tid, str) or not tid:
                findings.append(Finding(
                    "blocker", scope_t, "task 'id' missing or not a string",
                ))
                continue
            if tid in task_ids:
                findings.append(Finding(
                    "blocker", scope_t, f"duplicate task id '{tid}' in cluster",
                ))
            task_ids.add(tid)

            acc = task.get("acceptance")
            if not isinstance(acc, list) or not acc:
                findings.append(Finding(
                    "blocker", scope_t, "task 'acceptance' missing or empty",
                ))

            if task.get("parallel") is False:
                serialising_count += 1

            if task.get("parallel", True):
                globs = task.get("files_touched_globs") or []
                for g in globs:
                    if isinstance(g, str) and _is_literal(g):
                        prior = literal_path_owner.get(g)
                        if prior and prior != tid:
                            findings.append(Finding(
                                "blocker", scope_t,
                                f"literal path '{g}' is also claimed by "
                                f"parallel task '{prior}' in the same cluster",
                            ))
                        else:
                            literal_path_owner[g] = tid

        if serialising_count == 0:
            findings.append(Finding(
                "blocker", scope_c,
                "cluster has no serialising task (parallel: false)",
            ))
        elif serialising_count > 1:
            findings.append(Finding(
                "blocker", scope_c,
                f"cluster has {serialising_count} serialising tasks; exactly one required",
            ))

    for cluster in clusters:
        if not isinstance(cluster, dict):
            continue
        cid = cluster.get("id")
        scope_c = f"cluster[{cid}]"
        deps = cluster.get("depends_on") or []
        if not isinstance(deps, list):
            findings.append(Finding(
                "blocker", scope_c, "'depends_on' must be a list",
            ))
            continue
        for dep in deps:
            if dep not in cluster_ids:
                findings.append(Finding(
                    "blocker", scope_c,
                    f"depends_on references unknown cluster '{dep}'",
                ))
            if dep == cid:
                findings.append(Finding(
                    "blocker", scope_c,
                    f"cluster '{cid}' depends_on itself",
                ))

    return findings


# ---------------------------------------------------- state.yaml loader

def load_state_blockers() -> tuple[list[dict[str, Any]], Finding | None]:
    """Parse just the ``blockers:`` section of .claude/state.yaml.

    Full-file parse can fail on unquoted colons in multi-line scalars
    (observed in governance.summary). Fall back to extracting the
    blockers block by string slicing if the full parse fails.
    """
    if not STATE_YAML.exists():
        return [], None
    raw = STATE_YAML.read_text()
    try:
        full = yaml.safe_load(raw)
        if isinstance(full, dict) and isinstance(full.get("blockers"), list):
            return full["blockers"], None
    except yaml.YAMLError:
        pass

    m = re.search(r"(?m)^blockers:\s*$", raw)
    if not m:
        return [], Finding(
            "warning", "state_yaml",
            "state.yaml: full parse failed and no top-level 'blockers:' key found",
        )
    start = m.start()
    rest = raw[m.end():]
    next_top = re.search(r"(?m)^[A-Za-z_][A-Za-z0-9_-]*:\s*$", rest)
    end = m.end() + (next_top.start() if next_top else len(rest))
    snippet = raw[start:end]
    try:
        parsed = yaml.safe_load(snippet)
    except yaml.YAMLError as e:
        return [], Finding(
            "warning", "state_yaml",
            f"state.yaml blockers block did not parse: {e}",
        )
    blockers = (parsed or {}).get("blockers", []) if isinstance(parsed, dict) else []
    return blockers, Finding(
        "info", "state_yaml",
        "state.yaml: full parse failed; used partial-parse fallback for blockers",
    )


# --------------------------------------------------------------- probes

def _is_source_path(path: str) -> bool:
    if path.startswith(NON_SOURCE_PREFIXES):
        return False
    if path.endswith(NON_SOURCE_SUFFIXES):
        return False
    return True


# Per-blocker probes are intentionally empty in Aevum core.
#
# Upstream iterations carried probes for project-specific blocker
# patterns (report-stack file presence, locale-specific calques,
# template xfail tests). Those probes are inherently project-coupled,
# so Aevum ships none by default. New probes can be slotted in here
# if a project's state.yaml lists blockers that warrant a cheap
# git-grep-style probe; until then the empty dict makes
# run_state_audit a clean no-op for every blocker the state.yaml
# lists (each one classifies as "unknown" with an info-severity
# finding, no false positives).
BLOCKER_PROBES: dict[int, Callable[
    [str, list[str], str], tuple[str, dict[str, Any]]
]] = {}


def run_state_audit(
    blockers: list[dict[str, Any]],
    base_sha: str,
    tree_files: list[str],
) -> tuple[list[Finding], dict[int, str]]:
    """Returns (findings, blocker_status_by_id)."""
    findings: list[Finding] = []
    status_by_id: dict[int, str] = {}
    for blocker in blockers:
        bid = blocker.get("id")
        sev = blocker.get("sev", "P?")
        text = (blocker.get("text") or "").strip()
        scope = f"blocker:{bid}"
        probe = BLOCKER_PROBES.get(bid) if isinstance(bid, int) else None
        if probe is None:
            if isinstance(bid, int):
                status_by_id[bid] = "unknown"
            findings.append(Finding(
                "info", scope,
                f"blocker #{bid} ({sev}) has no automated probe",
                {"text_head": text[:120]},
            ))
            continue
        try:
            status, detail = probe(base_sha, tree_files, text)
        except RuntimeError as e:
            status, detail = "unknown", {"error": str(e)}
        status_by_id[bid] = status
        detail = {"text_head": text[:120], **detail}
        if status == "stale":
            findings.append(Finding(
                "warning", scope,
                f"blocker #{bid} ({sev}) does not reproduce at base_sha "
                "-- likely resolved by a later commit",
                detail,
            ))
        elif status == "reproduces_with_drift":
            findings.append(Finding(
                "warning", scope,
                f"blocker #{bid} ({sev}) still reproduces but the count "
                "in the state.yaml text disagrees with the probe",
                detail,
            ))
        elif status == "reproduces":
            findings.append(Finding(
                "info", scope,
                f"blocker #{bid} ({sev}) still reproduces at base_sha",
                detail,
            ))
        else:
            findings.append(Finding(
                "info", scope,
                f"blocker #{bid} ({sev}): probe inconclusive",
                detail,
            ))
    return findings, status_by_id


# ----------------------------------------------- environment probes
#
# SWAP-ME: the pnpm and node_modules probes below are the Node-stack
# defaults Aevum ships. When you swap the Gate 1 runner for your
# stack, swap these probes too (e.g. _probe_uv + _probe_venv for
# Python, _probe_cargo for Rust). The claude-CLI, disk-space,
# orchestrator-lock, zombie-worktree, and memory probes are stack-
# agnostic and stay. See docs/swap-points.md.
#
# Every environmental surprise that ever bit a real run becomes a
# named finding here. These probes run before the plan-structure
# checks so the operator sees setup errors before the block-specific
# findings.

def _probe_claude_cli() -> list[Finding]:
    which = shutil.which("claude")
    if which:
        return [Finding("info", "env:claude", f"claude resolved at {which}")]
    return [Finding(
        "blocker", "env:claude",
        "claude CLI not found on PATH",
    )]


def _probe_disk_space(root: pathlib.Path) -> list[Finding]:
    try:
        stat = os.statvfs(str(root))
    except (OSError, AttributeError):
        return []
    free_mb = (stat.f_bavail * stat.f_frsize) // (1024 * 1024)
    detail = {"free_mb": int(free_mb)}
    if free_mb < 500:
        return [Finding(
            "blocker", "env:disk",
            f"only {free_mb} MB free at repo root; need at least 500 MB",
            detail,
        )]
    if free_mb < 2048:
        return [Finding(
            "warning", "env:disk",
            f"only {free_mb} MB free at repo root; below 2 GB threshold",
            detail,
        )]
    return [Finding("info", "env:disk", f"{free_mb} MB free at repo root")]


def _probe_orchestrator_lock(
    root: pathlib.Path, block_id: str,
) -> list[Finding]:
    """Self-healing lock file probe.

    A live flock holder is left alone -- the wrapper's own ``flock -n``
    acquire will refuse to launch if another orchestrator is active.

    An unheld lock is classified as stale (0-byte leftover from an
    interrupted startup, or a stamped PID that is no longer alive, or
    unparseable content). Stale entries are removed on the spot per plan
    E2 "remove the lock and retry once" -- preflight should unblock the
    next run, not just name the problem.
    """
    lock = root / "logs" / "locks" / f"block-{block_id}.orchestrator.lock"
    if not lock.exists():
        return []
    size = lock.stat().st_size
    held = False
    try:
        import fcntl
        with open(lock, "r+") as f:
            try:
                fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)
            except BlockingIOError:
                held = True
    except (OSError, ImportError):
        pass
    if held:
        return [Finding(
            "info", "env:lock",
            f"{lock.name} currently held by another flock holder",
        )]

    content = lock.read_text(errors="ignore").strip() if size else ""
    pid: int | None = None
    pid_alive = False
    if content:
        m = re.match(r"^(\d+)(?::(\d+))?", content)
        if m:
            pid = int(m.group(1))
            try:
                os.kill(pid, 0)
                pid_alive = True
            except (ProcessLookupError, PermissionError):
                pid_alive = False

    if pid is not None and pid_alive:
        return [Finding(
            "info", "env:lock",
            f"lock content pid={pid} is alive but not held",
            {"path": str(lock), "pid": pid},
        )]

    # Stale: 0-byte unheld, dead PID, or unparseable content. Remove and
    # emit info so the next run starts clean.
    if size == 0:
        reason = "0-byte unheld leftover"
    elif pid is not None:
        reason = f"stamped pid {pid} not alive"
    else:
        reason = "unparseable content"
    try:
        lock.unlink()
    except OSError as e:
        return [Finding(
            "blocker", "env:lock",
            f"stale lock {lock} ({reason}); removal failed: {e}",
            {"path": str(lock), "reason": reason, "remove_error": str(e)},
        )]
    return [Finding(
        "info", "env:lock",
        f"removed stale lock {lock.name} ({reason})",
        {"path": str(lock), "reason": reason},
    )]


def _parse_worktree_list(porcelain: str) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for rec in porcelain.split("\n\n"):
        entry: dict[str, Any] = {
            "path": "", "branch": "", "locked": False, "lock_reason": "",
        }
        for line in rec.splitlines():
            if line.startswith("worktree "):
                entry["path"] = line[len("worktree "):]
            elif line.startswith("branch refs/heads/"):
                entry["branch"] = line[len("branch refs/heads/"):]
            elif line == "locked":
                entry["locked"] = True
            elif line.startswith("locked "):
                entry["locked"] = True
                entry["lock_reason"] = line[len("locked "):]
        if entry["path"]:
            entries.append(entry)
    return entries


def _probe_zombie_worktrees(root: pathlib.Path) -> list[Finding]:
    findings: list[Finding] = []
    try:
        proc = subprocess.run(
            ["git", "worktree", "list", "--porcelain"],
            cwd=root, capture_output=True, text=True, check=False,
        )
    except OSError:
        return []
    for entry in _parse_worktree_list(proc.stdout):
        path = entry["path"]
        if "/.claude/worktrees/" not in path or not entry["locked"]:
            continue
        if not pathlib.Path(path).exists():
            findings.append(Finding(
                "warning", "env:worktree",
                f"locked worktree entry has no directory: {path}",
                {"path": path, "cause": "dir_missing"},
            ))
            continue
        m = re.search(r"\(pid\s+(\d+)\)", entry["lock_reason"])
        if m:
            pid = int(m.group(1))
            try:
                os.kill(pid, 0)
            except (ProcessLookupError, PermissionError):
                findings.append(Finding(
                    "warning", "env:worktree",
                    f"locked worktree holder pid {pid} is dead: {path}",
                    {"path": path, "cause": "pid_dead", "pid": pid},
                ))
    return findings


def _probe_memory(
    meminfo_path: pathlib.Path = pathlib.Path("/proc/meminfo"),
    min_gb: float = 11.0,
) -> list[Finding]:
    """Warning if MemTotal below ``min_gb``.

    Threshold matches state.yaml ``next_phase.pre_kickoff_checklist``
    ``confirm_wslconfig_memory_12GB_swap_8GB``. Probe is a no-op if
    /proc/meminfo is absent (macOS, Windows dev boxes).
    """
    if not meminfo_path.exists():
        return []
    try:
        for line in meminfo_path.read_text().splitlines():
            if line.startswith("MemTotal:"):
                kb = int(line.split()[1])
                gb = kb / (1024 * 1024)
                detail = {"mem_total_gb": round(gb, 1)}
                if gb < min_gb:
                    return [Finding(
                        "warning", "env:memory",
                        f"MemTotal {gb:.1f} GB below {min_gb:.0f} GB "
                        "threshold (wslconfig expects memory=12GB, swap=8GB)",
                        detail,
                    )]
                return [Finding(
                    "info", "env:memory", f"MemTotal {gb:.1f} GB", detail,
                )]
    except (OSError, ValueError):
        pass
    return []


def _probe_node_modules(root: pathlib.Path) -> list[Finding]:
    # Only fire when the project actually uses Node (signalled by a
    # package.json at the repo root). Aevum core ships no package.json;
    # non-Node consumers would see a spurious warning otherwise.
    if not (root / "package.json").exists():
        return []
    nm = root / "node_modules"
    if nm.exists():
        return []
    return [Finding(
        "warning", "env:node_modules",
        "node_modules/ not present -- run `pnpm install`",
    )]


def _probe_pnpm_conditional(root: pathlib.Path) -> list[Finding]:
    # Only fires when the project actually uses pnpm (signalled by a
    # package.json at the repo root). Aevum core ships the default
    # pnpm Gate-1 runner but no package.json, so an unconditional pnpm
    # probe would block on a fresh clone with no project layered on.
    if not (root / "package.json").exists():
        return []
    which = shutil.which("pnpm")
    local = root / "node_modules" / ".bin" / "pnpm"
    if which:
        return [Finding("info", "env:pnpm", f"pnpm resolved at {which}")]
    if local.exists():
        return [Finding(
            "info", "env:pnpm", f"pnpm resolved at {local}",
        )]
    return [Finding(
        "blocker", "env:pnpm",
        "pnpm binary not found on PATH and not at "
        "node_modules/.bin/pnpm -- enable corepack and run `pnpm install`",
    )]


def check_environment(root: pathlib.Path, block_id: str) -> list[Finding]:
    findings: list[Finding] = []
    findings.extend(_probe_pnpm_conditional(root))
    findings.extend(_probe_claude_cli())
    findings.extend(_probe_disk_space(root))
    findings.extend(_probe_orchestrator_lock(root, block_id))
    findings.extend(_probe_zombie_worktrees(root))
    findings.extend(_probe_memory())
    findings.extend(_probe_node_modules(root))
    return findings


# ---------------------------------------- harness presence at base_sha
#
# SWAP-ME: REQUIRED_HARNESS_FILES below includes Node-stack entries
# (`package.json`, `.claude/scripts/gate1.sh`). Swap these
# for your stack's equivalents when you replace the Gate 1 runner.
# The orchestrator-prompt / gate-agent / hook / rule entries are
# stack-agnostic and stay. See docs/swap-points.md.
#
# The orchestrator boots a fresh `claude -p`, dispatches workers
# onto `block/<BLOCK>/<cluster_id>-<task_id>` branches forked from
# `base_sha`, then runs Gate 1 to Gate 3b against the merged cluster
# tree. Every gate resolves paths through the cluster branch's tree,
# not the host repository's working directory. If `base_sha` predates
# the harness (the gates' own scripts), the gate chain aborts
# mid-cluster with no preflight signal; an early smoke run surfaced
# exactly that: worker landed a marker file, cluster merge succeeded,
# then the inner orchestrator aborted at
# `post_cluster_merge_pre_gate1` because the Gate 1 runner script was
# not in the tree at base_sha.
#
# This check forecloses that failure mode at draft time. It
# enumerates the load-bearing harness files the gate chain needs and
# rejects any `base_sha` whose tree is missing any of them.

REQUIRED_HARNESS_FILES = (
    # Aevum core (always required at base_sha; orchestrator's own
    # machinery)
    "scripts/baseline-diff.py",
    "scripts/check-stale-gate-verdicts.py",
    "scripts/check-fix-loop-budget.py",
    # Gate 1 runner files (Node/pnpm default; swap for your stack at
    # the Gate-1 seam, see docs/swap-points.md). These stay required
    # because Aevum ships them as the default and they must exist in
    # the tree at base_sha for the gate chain to run. Replace with
    # your stack's equivalent file paths when you swap the runner.
    "scripts/quality-gate.py",
    ".claude/scripts/gate1.sh",
    # Inner orchestrator
    ".claude/scripts/orchestrate-block.prompt.md",
    # Gates 2, 3a, 3b agents
    ".claude/agents/config-validator.md",
    ".claude/agents/criteria-checker.md",
    ".claude/agents/code-reviewer.md",
    # Write-time enforcement hooks
    ".claude/hooks/commit-policy.sh",
    ".claude/hooks/forbidden-patterns-live.sh",
    ".claude/hooks/worker-worktree-jail.sh",
    # Pattern YAML the live-hook + config-validator both consume
    ".claude/rules/forbidden-patterns.md",
)


def check_harness_presence(
    tree_files: list[str],
    base_sha: str,
) -> list[Finding]:
    if not tree_files:
        return []
    present = set(tree_files)
    missing = [p for p in REQUIRED_HARNESS_FILES if p not in present]
    if not missing:
        return []
    return [Finding(
        "blocker",
        "harness",
        f"base_sha {base_sha[:7]} tree is missing "
        f"{len(missing)} load-bearing harness file(s); the gate chain "
        f"cannot run against this base. Update block.yaml:base_sha to a "
        f"commit where the harness is in tree.",
        {"missing": missing, "base_sha": base_sha},
    )]


# ----------------------------------------- baseline.json at base_sha
#
# The cluster branch is forked from base_sha. Gate 1's baseline-diff.py
# resolves docs/blocks/<BLOCK>/baseline.json through the cluster tree,
# not the host repo's working tree. If base_sha predates the commit
# that committed baseline.json, Gate 1 fails with
# verdict=fail, reason=baseline_missing AFTER worker dispatch and
# cluster merge -- minutes of worker time burnt before the operator
# learns about a setup-order defect.
#
# This check forecloses that failure mode at preflight time. It uses
# the existing tree_files list (already loaded for harness-presence)
# rather than a second git ls-tree call. Same severity contract as
# check_harness_presence: blocker, with an actionable remediation
# message that names the activation-commit pattern.

def check_baseline_present(
    root: pathlib.Path,
    block_id: str,
    base_sha: str,
) -> list[Finding]:
    relpath = f"docs/blocks/{block_id}/baseline.json"
    try:
        out = _git(
            "ls-tree", "-r", "--name-only", base_sha, "--", relpath,
        )
    except RuntimeError as e:
        return [Finding(
            "blocker", "baseline",
            f"baseline.json presence check failed at base_sha "
            f"{base_sha[:7]}: {e}",
            {"path": relpath, "base_sha": base_sha},
        )]
    if relpath in {line for line in out.splitlines() if line}:
        return []
    return [Finding(
        "blocker", "baseline",
        f"base_sha {base_sha[:7]} tree is missing "
        f"{relpath}; Gate 1 will abort with baseline_missing. Run "
        f"`bash scripts/capture-baseline.sh {block_id}` then commit "
        f"baseline.json + block.yaml; ensure block.yaml's base_sha "
        f"references a commit whose tree contains baseline.json.",
        {"path": relpath, "base_sha": base_sha},
    )]


# --------------------------------------- acceptance -> blocker crossref

def _extract_blocker_refs(acceptance_text: str) -> set[int]:
    ids: set[int] = set()
    for anchor in BLOCKER_ANCHOR_RE.finditer(acceptance_text):
        tail = acceptance_text[anchor.end():]
        tail = SENTENCE_SPLIT_RE.split(tail, 1)[0]
        bare = BARE_ID_AFTER_ANCHOR_RE.match(tail)
        if bare:
            try:
                ids.add(int(bare.group(1)))
            except ValueError:
                pass
        for m in HASH_ID_RE.finditer(tail):
            try:
                ids.add(int(m.group(1)))
            except ValueError:
                pass
    return ids


def check_acceptance_blocker_refs(
    block: dict[str, Any],
    blocker_status: dict[int, str],
    known_ids: set[int],
) -> list[Finding]:
    findings: list[Finding] = []
    for cluster in block.get("clusters", []) or []:
        if not isinstance(cluster, dict):
            continue
        cid = cluster.get("id", "?")
        for task in cluster.get("tasks", []) or []:
            if not isinstance(task, dict):
                continue
            tid = task.get("id", "?")
            scope = f"{cid}:{tid}"
            acc_text = " ".join(task.get("acceptance") or [])
            for ref in sorted(_extract_blocker_refs(acc_text)):
                if ref not in known_ids:
                    findings.append(Finding(
                        "warning", scope,
                        f"acceptance references blocker #{ref} which "
                        "is absent from .claude/state.yaml",
                    ))
                    continue
                status = blocker_status.get(ref, "unknown")
                if status == "stale":
                    findings.append(Finding(
                        "warning", scope,
                        f"acceptance targets blocker #{ref} which the "
                        "state audit classifies as STALE at base_sha; "
                        "this task will likely be a no-op",
                        {"blocker_id": ref, "status": status},
                    ))
    return findings


# ----------------------------------------------------------- reporting

def build_report(
    block_id: str,
    base_sha: str,
    base_branch: str,
    findings: list[Finding],
    tree_file_count: int,
) -> dict[str, Any]:
    ts = datetime.now(timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z",
    )
    return {
        "schema": SCHEMA_VERSION,
        "generated_at": ts,
        "block_id": block_id,
        "base_sha": base_sha,
        "base_branch": base_branch,
        "tree_file_count": tree_file_count,
        "findings": [f.to_dict() for f in findings],
        "counts": {
            "blocker": sum(1 for f in findings if f.severity == "blocker"),
            "warning": sum(1 for f in findings if f.severity == "warning"),
            "info": sum(1 for f in findings if f.severity == "info"),
        },
    }


def render_summary(report: dict[str, Any], strict: bool, stream) -> None:
    counts = report["counts"]
    print(
        f"Preflight -- block {report['block_id']} @ "
        f"{report['base_sha'][:7]}  ({counts['blocker']} blocker, "
        f"{counts['warning']} warning, {counts['info']} info)",
        file=stream,
    )
    for f in report["findings"]:
        if f["severity"] == "info":
            continue
        tag = "BLOCKER" if f["severity"] == "blocker" else "WARN   "
        if strict and f["severity"] == "warning":
            tag = "BLOCKER"
        print(f"  {tag}  {f['scope']}: {f['message']}", file=stream)


# ---------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> int:  # pragma: no cover
    parser = argparse.ArgumentParser(
        description="Validate a block plan and state.yaml against base_sha "
                    "before the orchestrator launches workers.",
    )
    parser.add_argument("block_id", help="e.g. B1")
    parser.add_argument(
        "--base-sha",
        help="override base_sha from block.yaml",
    )
    parser.add_argument(
        "--strict", action="store_true",
        help="treat warnings as blockers",
    )
    parser.add_argument(
        "--report-only", action="store_true",
        help="always exit 0; write the report and summary regardless",
    )
    args = parser.parse_args(argv)

    block_yaml = BLOCKS_ROOT / args.block_id / "block.yaml"
    if not block_yaml.exists():
        print(f"ERROR: {block_yaml} not found", file=sys.stderr)
        return 3
    try:
        block = yaml.safe_load(block_yaml.read_text())
    except yaml.YAMLError as e:
        print(f"ERROR: {block_yaml} is not valid YAML: {e}", file=sys.stderr)
        return 3
    if not isinstance(block, dict):
        print(f"ERROR: {block_yaml} top level must be a mapping",
              file=sys.stderr)
        return 3

    base_sha_input = args.base_sha or block.get("base_sha")
    if not base_sha_input:
        print("ERROR: no base_sha in block.yaml and --base-sha not given",
              file=sys.stderr)
        return 3
    try:
        base_sha = git_rev_parse(base_sha_input)
    except RuntimeError as e:
        print(f"ERROR: base_sha '{base_sha_input}' is not a valid commit: "
              f"{e}", file=sys.stderr)
        return 3

    base_branch = block.get("base_branch", "main")
    tree_files = git_tree_files(base_sha)

    findings: list[Finding] = []
    findings.extend(check_environment(ROOT, args.block_id))
    findings.extend(check_block_structure(block, ROOT, args.block_id))
    if not git_ref_reachable(base_sha, base_branch):
        findings.append(Finding(
            "warning", "base_sha",
            f"base_sha {base_sha[:7]} is not reachable from "
            f"'{base_branch}'; block is branching from an unmerged commit",
        ))
    findings.extend(check_harness_presence(tree_files, base_sha))
    findings.extend(check_baseline_present(ROOT, args.block_id, base_sha))

    blockers, parse_note = load_state_blockers()
    if parse_note is not None:
        findings.append(parse_note)
    state_findings, blocker_status = run_state_audit(
        blockers, base_sha, tree_files,
    )
    findings.extend(state_findings)
    known_blocker_ids = {
        b.get("id") for b in blockers if isinstance(b.get("id"), int)
    }
    findings.extend(check_acceptance_blocker_refs(
        block, blocker_status, known_blocker_ids,
    ))

    report = build_report(
        args.block_id, base_sha, base_branch, findings, len(tree_files),
    )
    if args.strict:
        report["strict"] = True

    out_dir = LOGS_BLOCKS_ROOT / args.block_id
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "preflight.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n",
    )

    render_summary(report, args.strict, sys.stderr)

    if args.report_only:
        return 0
    blockers_count = report["counts"]["blocker"]
    if args.strict:
        blockers_count += report["counts"]["warning"]
    return 2 if blockers_count > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
