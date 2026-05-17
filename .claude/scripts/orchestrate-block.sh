#!/usr/bin/env bash
# orchestrate-block.sh, block-era orchestrator wrapper.
#
# Usage:
#   bash .claude/scripts/orchestrate-block.sh <BLOCK_ID>
#   bash .claude/scripts/orchestrate-block.sh <BLOCK_ID> --dry-run
#   bash .claude/scripts/orchestrate-block.sh <BLOCK_ID> --skip-preflight
#   bash .claude/scripts/orchestrate-block.sh <BLOCK_ID> --self-test
#
# Responsibilities (small by design):
#   1. Validate inputs (block.yaml, baseline.json present).
#   2. Acquire an orchestrator lock for this block.
#   3. Run scripts/block-preflight.py to catch stale plan inputs before
#      dispatching workers. Preflight blockers -> exit 2, no claude
#      launch. Pass --skip-preflight to override (not recommended).
#   4. Spawn a heartbeat subshell that appends wrapper_heartbeat events
#      to logs/blocks/<BLOCK>/progress.jsonl every 60 s.
#   5. Launch `claude -p "$(< orchestrate-block.prompt.md)"` with
#      BLOCK_ID exported. The launch is a backgrounded subshell run
#      under bash job control (`set -m`) so the subshell becomes its
#      own process-group leader; every descendant claude spawns
#      (subagent processes, Bash-tool subprocesses, tee) inherits the
#      same PGID. Capture stdout; watch for:
#        a. SENTINEL::CONTEXT_LIMIT_REACHED  -> exit 4 (rotate, outer re-spawns)
#        b. 7200 s with both STDOUT_TAIL byte size AND inner-emitted
#           ledger event count stable (wrapper-only events excluded)
#                                          -> SIGTERM inner subtree, exit 4
#        c. clean exit from claude           -> exit 0
#        d. non-zero exit from claude        -> exit 1
#   6. On exit 4, the outer loop re-invokes itself and the prompt resumes
#      from the ledger tail.
#   7. Trap on EXIT/INT/TERM kills the inner-claude process group as a
#      whole (`kill -- -$INNER_PGID`, 10 s grace, SIGKILL fallback).
#      The process-group design fixes an orphan class surfaced by
#      upstream production: a long-lived orphan inner-claude that
#      survived its parent wrapper's death because the previous trap
#      only killed the immediate subshell PID, leaving claude + tee
#      + subagents reparented to init.
#      Why job control, not setsid: setsid forks itself (parent dies,
#      child becomes session leader), so `$!` captures the dead parent,
#      not the live PGID. `set -m` puts the backgrounded subshell in
#      its own pgrp directly; `$!` then equals both the leader's PID
#      and the new PGID. Verified by upstream smoke testing.
#
# Exit codes:
#   0   block finished (signed off / rejected / aborted cleanly)
#   1   claude exited non-zero
#   2   setup error (missing inputs, lock contention)
#   4   rotate requested (context-limit sentinel or wedge); caller re-spawns
set -euo pipefail

BLOCK_ID="${1:-}"
shift || true
DRY_RUN=0
SKIP_PREFLIGHT=0
SELF_TEST=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-preflight) SKIP_PREFLIGHT=1 ;;
    --self-test) SELF_TEST=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ -z "$BLOCK_ID" ]]; then
  echo "usage: $0 <BLOCK_ID> [--dry-run] [--skip-preflight] [--self-test]" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# shellcheck source=lib/wrapper-event-filter.sh
. "$REPO_ROOT/.claude/scripts/lib/wrapper-event-filter.sh"

BLOCK_DIR="docs/blocks/$BLOCK_ID"
BLOCK_YAML="$BLOCK_DIR/block.yaml"
BASELINE="$BLOCK_DIR/baseline.json"
LEDGER_DIR="logs/blocks/$BLOCK_ID"
LEDGER="$LEDGER_DIR/progress.jsonl"
PROMPT_FILE=".claude/scripts/orchestrate-block.prompt.md"
LOCK_DIR="logs/locks"
LOCK_FILE="$LOCK_DIR/block-$BLOCK_ID.orchestrator.lock"
STDOUT_TAIL="$LEDGER_DIR/orchestrator.stdout.log"
SIGNOFF_DIR="$LEDGER_DIR/signoff"
ABORT_FILE="$SIGNOFF_DIR/ABORT.md"

# ---- 1. validate inputs ------------------------------------------------------

if [[ ! -f "$BLOCK_YAML" ]]; then
  echo "ERROR: missing $BLOCK_YAML" >&2
  exit 2
fi
if [[ ! -f "$BASELINE" ]]; then
  echo "ERROR: missing $BASELINE (run scripts/capture-baseline.sh $BLOCK_ID first)" >&2
  exit 2
fi
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: missing $PROMPT_FILE" >&2
  exit 2
fi

mkdir -p "$LEDGER_DIR" "$LOCK_DIR"
touch "$LEDGER"

# ---- 2. lock -----------------------------------------------------------------

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "ERROR: another orchestrator holds $LOCK_FILE" >&2
  exit 2
fi
# Stamp PID and acquire-time so block-preflight.py can distinguish a
# live holder from a stale 0-byte leftover (see scripts/block-preflight.py
# _probe_orchestrator_lock). The cleanup() trap below truncates the file
# back to 0 bytes on exit so the next preflight does not see a dead PID.
printf '%s:%s\n' "$$" "$(date -u +%s)" >&9

# ---- ledger helper -----------------------------------------------------------

emit() {
  # emit <event> [<payload_json>]
  local event="$1"
  local payload="${2:-{\}}"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local sha
  sha=$(git rev-parse HEAD 2>/dev/null || echo "null")
  EMIT_TS="$ts" \
  EMIT_BLOCK="$BLOCK_ID" \
  EMIT_EVENT="$event" \
  EMIT_SHA="$sha" \
  EMIT_PAYLOAD="$payload" \
  EMIT_LEDGER="$LEDGER" \
  python3 - <<'PY'
import json, os
payload_str = os.environ.get("EMIT_PAYLOAD", "{}").strip()
try:
    payload = json.loads(payload_str) if payload_str else {}
except json.JSONDecodeError:
    payload = {"raw": payload_str}
record = {
    "schema": 2,
    "ts": os.environ["EMIT_TS"],
    "block_id": os.environ["EMIT_BLOCK"],
    "cluster_id": None,
    "task_id": None,
    "event": os.environ["EMIT_EVENT"],
    "git_sha": os.environ["EMIT_SHA"],
    "payload": payload,
}
with open(os.environ["EMIT_LEDGER"], "a") as f:
    f.write(json.dumps(record, separators=(",", ":")) + "\n")
    f.flush()
    os.fsync(f.fileno())
PY
}

# ---- gate3c.runner extractor (block.yaml -> string) -------------------------
#
# Extracted into a function so the success-path gate3c slot below and the
# --self-test branch share one implementation. Upstream hardening
# replaced the previous
# awk state-machine fallback with python3 + pyyaml. The awk parser
# silently no-op'd on four-space and tab indentation (analysis §10.8);
# pyyaml is a real YAML parser, so any indentation a YAML spec accepts
# is now handled. Tabs in indentation remain invalid per the YAML spec
# itself; pyyaml rejects them and the function returns empty, which
# matches the awk parser's prior behaviour on the same input but no
# longer hides a parser limitation behind a successful exit.
_extract_gate3c_runner() {
  local yaml_path="${1:-}"
  if [[ -z "$yaml_path" ]] || [[ ! -f "$yaml_path" ]]; then
    return 0
  fi
  if command -v yq >/dev/null 2>&1; then
    yq -r '.gates.per_cluster.gate3c.runner // ""' "$yaml_path" 2>/dev/null || true
  else
    python3 -c '
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        d = yaml.safe_load(f) or {}
except Exception:
    sys.exit(0)
gate3c = (d.get("gates", {}) or {}).get("per_cluster", {}) or {}
gate3c = gate3c.get("gate3c", {}) or {}
runner = gate3c.get("runner", "") or ""
print(runner)
' "$yaml_path" 2>/dev/null || true
  fi
}

emit "wrapper_start" "{\"dry_run\":$([[ $DRY_RUN -eq 1 ]] && echo true || echo false),\"self_test\":$([[ $SELF_TEST -eq 1 ]] && echo true || echo false)}"

# ---- self-test short-circuit -------------------------------------------------
#
# Upstream hardening, preflight stage.
# Exercises the load-bearing primitives (emit, lock, YAML extractor,
# wrapper-event filter) without spawning claude. The upstream project's
# tests/test_orchestrate_block.py covers this branch; this project has
# no test harness yet, but the flag still works for ad-hoc structural
# verification. Exits 0 with one selftest_ok event
# on the per-block ledger; the lock file is removed on the way out so
# the next test invocation does not collide.
if [[ $SELF_TEST -eq 1 ]]; then
  selftest_runner="$(_extract_gate3c_runner "$BLOCK_YAML" || true)"
  selftest_filter_pos=0
  selftest_filter_neg=0
  if is_wrapper_event "wrapper_heartbeat"; then selftest_filter_pos=1; fi
  if is_wrapper_event "task_dispatched"; then selftest_filter_neg=1; fi
  emit "selftest_ok" \
    "{\"runner\":\"$selftest_runner\",\"filter_heartbeat\":$selftest_filter_pos,\"filter_task_dispatched\":$selftest_filter_neg}"
  echo "[selftest] gate3c_runner=${selftest_runner:-(none)}"
  echo "[selftest] is_wrapper_event(wrapper_heartbeat)=$selftest_filter_pos (expect 1)"
  echo "[selftest] is_wrapper_event(task_dispatched)=$selftest_filter_neg (expect 0)"
  rm -f "$LOCK_FILE" 2>/dev/null || true
  exit 0
fi

# ---- 3. preflight ------------------------------------------------------------
#
# Validates block.yaml structure, state.yaml blocker probes, and
# acceptance<->blocker cross-references BEFORE a single worker minute is
# spent. Exit 2 from the preflight means stale plan inputs; we refuse to
# launch claude in that case. See scripts/block-preflight.py for the
# finding taxonomy and probe semantics.

PREFLIGHT_REPORT="$LEDGER_DIR/preflight.json"
HEARTBEAT_PID=""
cleanup() {
  if [[ -n "$HEARTBEAT_PID" ]] && kill -0 "$HEARTBEAT_PID" 2>/dev/null; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
  fi
  # Kill the inner-claude process group as a whole. INNER_PGID equals
  # INNER_PID by job-control invariant: with `set -m` the backgrounded
  # subshell becomes a process-group leader whose PGID is its own PID,
  # so `$!` (captured into INNER_PID) is also the PGID. Sending the
  # signal to -PGID (negative number) delivers it to every process in
  # the group: the subshell, claude, tee, and every subagent / Bash-
  # tool subprocess claude has spawned. Without this, SIGTERM to the
  # immediate subshell PID leaves claude and its descendants
  # reparented to init (the orphan bug upstream production surfaced).
  if [[ -n "${INNER_PGID:-}" ]] && kill -0 -- "-$INNER_PGID" 2>/dev/null; then
    kill -TERM -- "-$INNER_PGID" 2>/dev/null || true
    # Give the group 10 s to exit gracefully. Subagents may use this
    # window to call ExitWorktree themselves; claude flushes any
    # in-flight ledger writes; tee drains the stdout pipe.
    local wait_s=0
    while kill -0 -- "-$INNER_PGID" 2>/dev/null && (( wait_s < 10 )); do
      sleep 1
      wait_s=$((wait_s + 1))
    done
    # SIGKILL fallback for any process in the group still alive after
    # grace. SIGKILL cannot be caught or ignored, so this is the
    # backstop against subagents in uninterruptible sleep or bugs that
    # swallow SIGTERM.
    if kill -0 -- "-$INNER_PGID" 2>/dev/null; then
      kill -KILL -- "-$INNER_PGID" 2>/dev/null || true
    fi
  fi
  # Force-remove agent worktrees scoped to this block (path prefix
  # .claude/worktrees/agent- AND branch prefix block/$BLOCK_ID/) or
  # agent worktrees under .claude/worktrees/ whose lock PID is dead.
  # Subagents should call ExitWorktree themselves (see orchestrate-block.prompt.md
  # §Constraint: subagent worktree discipline); this is the safety net for
  # SIGTERM races and crashes.
  #
  # Path-prefix narrowing: a prior version of this trap selected on
  # branch alone (any worktree whose branch matched block/$BLOCK_ID/*).
  # That caught the host worktree too, because §6.1 step 2 of
  # orchestrate-block.prompt.md switches the host's HEAD to
  # block/<BLOCK>/<cluster_id>. The host worktree's path is the repo
  # root (no `agent-` prefix), so requiring `.claude/worktrees/agent-`
  # in the path excludes the host from cleanup. The smoke run on
  # 2026-05-13 lost progress.jsonl, SIGNED.md, preflight.json, and
  # orchestrator.stdout.log to the unnarrowed selector; see the
  # HANDOVER.md entry for that date.
  local removed=0
  local paths
  paths=$(BLOCK_ID="$BLOCK_ID" python3 - <<'PY' 2>/dev/null || true
import os, re, subprocess
block = os.environ.get("BLOCK_ID", "")
out = subprocess.run(
    ["git", "worktree", "list", "--porcelain"],
    capture_output=True, text=True,
).stdout
for rec in out.split("\n\n"):
    path = ""
    branch = ""
    locked = False
    lock_reason = ""
    for line in rec.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line.startswith("branch refs/heads/"):
            branch = line[len("branch refs/heads/"):]
        elif line == "locked":
            locked = True
        elif line.startswith("locked "):
            locked = True
            lock_reason = line[len("locked "):]
    if not path:
        continue
    if (
        "/.claude/worktrees/agent-" in path
        and block
        and branch.startswith("block/" + block + "/")
    ):
        print(path)
        continue
    if "/.claude/worktrees/" in path and locked:
        m = re.search(r"\(pid\s+(\d+)\)", lock_reason)
        if m:
            pid = int(m.group(1))
            try:
                os.kill(pid, 0)
            except (ProcessLookupError, PermissionError):
                print(path)
PY
)
  if [[ -n "$paths" ]]; then
    autosaved=0
    while IFS= read -r wt_path; do
      [[ -z "$wt_path" ]] && continue
      # Autosave uncommitted work on the worker branch before removing
      # the worktree. An upstream cluster lost ~2 h of parallel-worker
      # productive work when a false-positive wedge fired and
      # `git worktree remove -f -f` destroyed the uncommitted state.
      # The wedge detector now watches worker filesystem activity
      # (third signal in the loop above), so false positives should be
      # rare. This autosave is a belt-and-braces safety net for real
      # wedges where workers had partial progress that would otherwise
      # be lost. The commit lands on the worker branch with a clear
      # marker so a follow-up §1.4b option:A redispatch can choose to
      # rebase and continue, or option:C to discard and rescope.
      if [[ "$wt_path" == *".claude/worktrees/"* ]] && [ -d "$wt_path" ]; then
        if [[ -n "$(git -C "$wt_path" status --porcelain --untracked-files=all 2>/dev/null)" ]]; then
          wt_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
          if [[ "$wt_branch" == "block/$BLOCK_ID/"* ]]; then
            ts=$(date -u +%Y%m%dT%H%M%SZ)
            # Explicit-paths staging. Replaces the old `git add -A`,
            # which was a sledgehammer that risked staging anything
            # the per-file deny-list missed (env files, test fixtures
            # with secrets, gitignored build artefacts). The carve-out
            # in commit-policy.md was always meant to be temporary.
            # This path is now deterministic and aligned with the
            # rest of the project's staging discipline.
            #
            # Pipeline:
            #   1. Enumerate candidates via `git ls-files`
            #      --modified --deleted --others --exclude-standard.
            #      `--exclude-standard` already drops gitignored
            #      untracked files; modified/deleted tracked files
            #      cannot be gitignored by definition.
            #   2. Belt-and-braces secondary filter via
            #      `git check-ignore --stdin --no-index` to drop any
            #      path that gitignore matches. Defends against an
            #      `--exclude-standard` regression upstream.
            #   3. Restrict to the explicit allow-list of top-level
            #      directories that productive work lives under.
            #      Anything outside the allow-list is dropped, even
            #      if tracked.
            #   4. Stage each surviving path with explicit
            #      `git add -- <path>`. Loud failure: if zero paths
            #      survive but the worktree was dirty, log an
            #      autosave_empty event and continue without
            #      committing rather than silently passing.
            allow_globs=(
              'src/'
              'docs/'
              'scripts/'
              'tests/'
              'public/'
              '.claude/scripts/'
              '.claude/agents/'
              '.claude/rules/'
              '.claude/hooks/'
              '.claude/templates/'
            )
            mapfile -d '' -t _candidates < <(
              git -C "$wt_path" ls-files \
                --modified --deleted --others --exclude-standard \
                -z -- 2>/dev/null
            )
            staged_count=0
            for _cand in "${_candidates[@]}"; do
              [[ -z "$_cand" ]] && continue
              # Secondary gitignore filter. `git check-ignore` exits
              # 0 when stdin path matches a gitignore rule (i.e. the
              # path IS ignored), exit 1 when it does not match. We
              # want surviving paths to be NOT ignored, so an exit
              # status of 1 (or non-zero in general) means "keep".
              if git -C "$wt_path" check-ignore --stdin --no-index \
                <<<"$_cand" >/dev/null 2>&1; then
                continue
              fi
              # Allow-list prefix filter.
              _matched=0
              for _g in "${allow_globs[@]}"; do
                if [[ "$_cand" == "$_g"* ]]; then
                  _matched=1
                  break
                fi
              done
              [[ $_matched -eq 0 ]] && continue
              if git -C "$wt_path" add -- "$_cand" 2>/dev/null; then
                staged_count=$((staged_count + 1))
              fi
            done
            if [[ $staged_count -eq 0 ]]; then
              # Loud-failure boundary: dirty worktree but nothing
              # safe to autosave. Log and skip the commit; the
              # worktree removal still proceeds so the wedge does
              # not deadlock. The follow-up Section 1.4b redispatch
              # picks up the empty-autosave event in the ledger.
              emit "autosave_empty" \
                "{\"branch\":\"$wt_branch\",\"path\":\"$wt_path\"}"
            else
              if git -C "$wt_path" \
                -c user.email=orchestrator@local \
                -c user.name="orchestrator (wedge-autosave)" \
                commit \
                -m "chore(orphan-autosave): preserve uncommitted state on $wt_branch at $ts" \
                2>/dev/null; then
                autosaved=$((autosaved + 1))
              fi
            fi
          fi
        fi
      fi
      git worktree unlock "$wt_path" 2>/dev/null || true
      if git worktree remove -f -f "$wt_path" 2>/dev/null; then
        removed=$((removed + 1))
      fi
    done <<< "$paths"
  fi
  git worktree prune >/dev/null 2>&1 || true
  emit "worktree_cleanup" "{\"removed\":$removed,\"autosaved\":${autosaved:-0}}"
  # Remove the lock file on clean exit so the next preflight does not see a
  # stamped-but-dead PID or a 0-byte stale leftover. flock releases when
  # fd 9 closes on script exit; unlinking the path beforehand is safe
  # because any racing orchestrator `exec 9>"$LOCK_FILE"` would open a
  # fresh inode.
  rm -f "$LOCK_FILE" 2>/dev/null || true
  emit "wrapper_shutdown" "{}"
}
trap cleanup EXIT INT TERM

if [[ $SKIP_PREFLIGHT -eq 1 ]]; then
  emit "preflight_skipped" "{}"
else
  emit "preflight_start" "{}"
  set +e
  python3 scripts/block-preflight.py "$BLOCK_ID"
  PF_EXIT=$?
  set -e
  case "$PF_EXIT" in
    0)
      emit "preflight_ok" "{\"report\":\"$PREFLIGHT_REPORT\"}"
      ;;
    2)
      emit "preflight_blocked" "{\"report\":\"$PREFLIGHT_REPORT\"}"
      emit "wrapper_exit" "{\"exit_code\":2,\"reason\":\"preflight_blocked\"}"
      echo "ERROR: preflight blockers found; see $PREFLIGHT_REPORT" >&2
      echo "       Fix the plan or rerun with --skip-preflight to override." >&2
      exit 2
      ;;
    *)
      emit "preflight_error" "{\"exit\":$PF_EXIT}"
      emit "wrapper_exit" "{\"exit_code\":$PF_EXIT,\"reason\":\"preflight_error\"}"
      echo "ERROR: preflight invocation failed (exit=$PF_EXIT); see $PREFLIGHT_REPORT" >&2
      exit "$PF_EXIT"
      ;;
  esac
fi

# ---- 3b. fragmentation pre-flight (REMOVED in Aevum core) ------------------
#
# An upstream project ran two model-policy invariants here before the
# inner claude launch: (a) grep this script for the
# `--setting-sources user,local,project` flag, and (b) require each
# gate agent's YAML frontmatter to declare model: opus|sonnet (no
# haiku). Both checks targeted an agent-fragmentation carryover from
# that project's prior runs; the fragmentation root cause was never
# isolated, but the checks closed one launch-time hypothesis by
# making the invariants testable at dispatch time.
#
# Removed in Aevum core because each consumer project owns its agent
# set directly (no shared per-agent tier policy, no shared
# agent-fragmentation history), so the dispatch-time
# invariants would either trip on missing agent files or rubber-stamp.
# The `--setting-sources user,local,project` flag is still passed to
# the inner claude launch below; if a refactor ever drops it, the
# per-agent `model:` frontmatter resolution stops working and the
# behaviour to recover is to re-add the flag (or restore this
# preflight as a guard).

# ---- 4. heartbeat subshell ---------------------------------------------------

(
  while true; do
    sleep 60
    emit "wrapper_heartbeat" "{\"wrapper_pid\":$$}"
  done
) &
HEARTBEAT_PID=$!

# ---- 5. dry-run short-circuit ------------------------------------------------

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] would invoke: claude -p \"BLOCK_ID=$BLOCK_ID\\n...\\n\$(cat $PROMPT_FILE)\" --setting-sources user,local,project --dangerously-skip-permissions with BLOCK_ID=$BLOCK_ID"
  echo "[dry-run] block.yaml exists: $(wc -l < "$BLOCK_YAML") lines"
  echo "[dry-run] baseline fingerprints: $(python3 -c "import json; print(json.load(open('$BASELINE'))['error_count'])")"
  echo "[dry-run] ledger: $LEDGER"
  emit "wrapper_dry_run_complete" "{}"
  exit 0
fi

# ---- 6. launch claude with wedge detection -----------------------------------

if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: 'claude' CLI not found on PATH" >&2
  emit "block_abort" "{\"reason\":\"claude_cli_missing\"}"
  exit 1
fi

: > "$STDOUT_TAIL"
export BLOCK_ID="$BLOCK_ID"
export LEDGER="$LEDGER"

# Widen the per-check gate timeout for block-scale runs. Block-era
# gate workloads accumulate more tests than a dev-local 900 s budget
# can tolerate reliably. Upstream production hit timeouts on the
# previous 900 s default; the project bumped to 1800 s and made it
# overridable. Default: 1800 s (30 min). Operator override: set
# GATE_TIMEOUT_SECONDS in the environment before invoking this
# wrapper to raise or lower. quality-gate.py reads the var (default
# 900 if unset). Variable-first discipline: no block-era budget
# hardcoded in call sites.
export GATE_TIMEOUT_SECONDS="${GATE_TIMEOUT_SECONDS:-1800}"

# Prefix the prompt with a plain-text header the model can parse without
# relying on env propagation into tool-call subshells. See
# orchestrate-block.prompt.md §0 "Execution directive".
PROMPT_HEADER="BLOCK_ID=$BLOCK_ID
RUN_MODE=non-interactive

"
PROMPT_BODY="$(cat "$PROMPT_FILE")"
FULL_PROMPT="${PROMPT_HEADER}${PROMPT_BODY}"

# Run claude in the background with stdout teed to STDOUT_TAIL so we can
# measure silence. Two non-obvious mechanics, each load-bearing for the
# orphan-prevention contract (upstream-hardening, process-group trap):
#
#   (a) `set -m` enables bash job control for this spawn only. With
#       monitor mode on, the backgrounded subshell goes into a brand-new
#       process group whose PGID equals its own PID. Every fork the
#       subshell makes (the claude process, the tee process, every
#       subagent that claude spawns via the Bash tool) inherits that
#       PGID. The cleanup trap can then `kill -TERM -- -$INNER_PGID`
#       and reach the entire subtree in one syscall. We restore the
#       prior monitor mode immediately after spawn so the heartbeat
#       subshell (already running in the wrapper's pgrp) and any later
#       backgrounded forks in the cleanup trap retain default behaviour.
#
#   (b) The pipeline is wrapped in a subshell `( ... ) &` rather than
#       backgrounded directly. For a bare `cmd1 | cmd2 &`, bash sets
#       `$!` to the PID of cmd2 (the LAST process), but the pipeline's
#       PGID is the PID of cmd1 (the FIRST process). They do NOT match,
#       and `kill -- -$!` would silently target a non-existent group.
#       Wrapping in `( ... )` makes `$!` point at the subshell, whose
#       PID IS the PGID of the new pgrp under `set -m`.
#
# We previously tried `setsid bash -c ...` (commits prior to this one).
# It compiled and ran, but `$!` captured the parent setsid process,
# which exits immediately after forking its session-leader child. The
# trap's kill targeted a dead PID, the orphan bug remained.
# Smoke-tested during upstream hardening before adopting the
# job-control approach above.
#
# Final-line `__CLAUDE_EXIT_CODE__=$?` is appended after the pipeline so
# the wrapper can recover claude's exit code through the tee pipe (the
# subshell inherits `set -o pipefail` from the outer wrapper, so $?
# reflects claude, not tee).
# --dangerously-skip-permissions: tool-use prompts would block a
# non-interactive -p run; PreToolUse hooks still enforce policy.
set -m
(
  # ORCHESTRATOR_HOST=1 tells worker-worktree-jail.sh to
  # treat the inner claude process as host (not worker) context.
  # Default jail detection compares `git rev-parse --show-toplevel`
  # against `$CLAUDE_PROJECT_DIR`; from a linked worktree they
  # differ and the hook rejects writes outside the toplevel. The
  # orchestrator legitimately writes everywhere (logs/, .claude/
  # state.yaml, docs/blocks/, etc.) so the jail must opt out.
  # Subagents do NOT inherit this var because Agent(isolation:
  # "worktree") strips the parent environment.
  ANTHROPIC_BETAS="context-1m-2025-08-07" \
  ORCHESTRATOR_HOST=1 \
  claude -p "$FULL_PROMPT" \
    --setting-sources user,local,project \
    --dangerously-skip-permissions \
    2>&1 \
    | tee -a "$STDOUT_TAIL"
  echo "__CLAUDE_EXIT_CODE__=$?" >> "$STDOUT_TAIL"
) &
INNER_PID=$!
INNER_PGID=$INNER_PID
set +m

# Count ledger lines whose event is NOT a wrapper-only emission.
# Wrapper-only events are authored by this script itself and therefore
# prove nothing about inner claude liveness; they must be excluded from
# the wedge-detection signal. The exclusion set lives in
# .claude/scripts/lib/wrapper-event-filter.sh and is shared with the
# loop wrapper's last-substantive-event scan.
inner_event_count() {
  INNER_LEDGER_PATH="$LEDGER" WRAPPER_EVENTS="$WRAPPER_EVENTS" python3 - <<'PY'
import json, os
path = os.environ.get("INNER_LEDGER_PATH", "")
wrapper_events = {e for e in os.environ.get("WRAPPER_EVENTS","").split("\n") if e}
count = 0
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            ev = rec.get("event")
            if ev and ev not in wrapper_events:
                count += 1
except FileNotFoundError:
    pass
print(count)
PY
}

# SILENCE_LIMIT (default 1800 s, 30 min).
# Three independent signals must ALL stagnate for this duration before
# a wedge fires: (1) inner-claude stdout size, (2) inner-claude ledger
# event count, (3) freshest file mtime across active block's worker
# worktrees. Signal #3 was added after an upstream incident where
# parallel cluster workers were falsely killed at the 7200s mark even
# though they were actively writing files. With three signals,
# parallel-task waits cannot be mistaken for wedges because a
# productive worker advances mtime on every Edit/Write tool call
# inside its worktree. Real hangs (worker stuck on a no-op Bash spin,
# frozen network call with no FS activity) still trip the wedge after
# 30 min of three-way stagnation. If a block with longer-running
# workers needs a longer budget, override via SILENCE_LIMIT for that
# run rather than tuning the default.
#
# SILENCE_LIMIT and CHECK_INTERVAL env-var overrides exist for
# test harnesses that need to exercise the polling-loop branches
# (ABORT.md poll, wedge synthesis) on a sub-second cadence
# instead of the 15 s production tick. Variable-first discipline (no
# magic numbers wired into call sites); operators should not set
# these in production.
SILENCE_LIMIT="${SILENCE_LIMIT:-1800}"
CHECK_INTERVAL="${CHECK_INTERVAL:-15}"

# Returns the freshest file mtime (Unix epoch seconds, integer) across
# every linked worktree whose checked-out branch starts with
# block/<BLOCK_ID>/. Used as the third liveness signal: parallel-task
# workers write to files in their worktree during execution, so when
# inner-claude is correctly blocked on Agent() returns, the wrapper
# can still observe progress through worker filesystem activity.
# Excludes .git, node_modules, and language-specific cache dirs which
# can have unrelated mtime drift (e.g., next.js dev rebuilds, mypy
# cache writes) that would falsely register as worker progress.
worker_max_mtime() {
  local block="$1"
  local max=0
  local wt newest m_int
  while IFS= read -r wt; do
    [ -d "$wt" ] || continue
    newest=$(find "$wt" -type f \
      -not -path '*/.git/*' \
      -not -path '*/node_modules/*' \
      -not -path '*/.next/*' \
      -not -path '*/.venv/*' \
      -not -path '*/__pycache__/*' \
      -not -path '*/.pytest_cache/*' \
      -not -path '*/.ruff_cache/*' \
      -not -path '*/.mypy_cache/*' \
      -not -path '*/.turbo/*' \
      -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
    [ -z "$newest" ] && continue
    m_int=${newest%.*}
    if (( m_int > max )); then max=$m_int; fi
  done < <(git worktree list 2>/dev/null \
    | awk -v block="$block" '$0 ~ ("\\[block/"block"/") {print $1}')
  echo "$max"
}

last_stdout_size=0
last_inner_count=$(inner_event_count)
last_worker_mtime=$(worker_max_mtime "$BLOCK_ID")
silence_accum=0
ROTATE_REQUESTED=0
ABORT_REQUESTED=0
INNER_EXIT=""

while kill -0 "$INNER_PID" 2>/dev/null; do
  # Founder kill switch (abort-signal channel; upstream hardening
  # plumbed this in). The poll runs on every wedge-detector tick so detection
  # latency is bounded by CHECK_INTERVAL (default 15 s, well under the
  # 60 s contract documented at the wrapper's `--help` interface).
  # Existence of the file IS the
  # signal; frontmatter parsing happens in the inner prompt's §6.0
  # cluster-boundary check, where the abort_at and reason fields land
  # in the block_abort event verbatim. The wrapper's job is the
  # belt-and-braces path for a wedged inner that cannot reach §6.0,
  # plus the case where the inner is mid-cluster (between §6.0 checks)
  # and the founder wants the cluster to stop now, not after the next
  # boundary.
  if [[ -f "$ABORT_FILE" ]]; then
    emit "abort_signal_detected" \
      "{\"abort_file\":\"$ABORT_FILE\",\"silence_s\":$silence_accum}"
    ABORT_REQUESTED=1
    # Same SIGTERM-then-SIGKILL group kill as the sentinel and wedge
    # branches; the post-loop synthesis path waits for the inner to
    # die before deciding whether to emit a synthetic block_abort.
    kill -TERM -- "-$INNER_PGID" 2>/dev/null || true
    break
  fi

  # Rotation sentinel?
  if grep -q "SENTINEL::CONTEXT_LIMIT_REACHED" "$STDOUT_TAIL"; then
    emit "rotation_triggered" "{}"
    ROTATE_REQUESTED=1
    # Kill the inner process group as a whole, not just the leader PID.
    # Subagents and Bash-tool subprocesses share the group via the
    # `set -m` spawn block above; without group kill they survive as
    # orphans (upstream-hardening, process-group trap).
    kill -TERM -- "-$INNER_PGID" 2>/dev/null || true
    break
  fi

  stdout_size=$(wc -c < "$STDOUT_TAIL" | tr -d ' ')
  inner_count=$(inner_event_count)
  worker_mtime=$(worker_max_mtime "$BLOCK_ID")

  if [[ "$stdout_size" == "$last_stdout_size" ]] \
     && [[ "$inner_count" == "$last_inner_count" ]] \
     && (( worker_mtime <= last_worker_mtime )); then
    silence_accum=$((silence_accum + CHECK_INTERVAL))
    if (( silence_accum >= SILENCE_LIMIT )); then
      emit "wrapper_wedge_detected" "{\"silence_s\":$silence_accum,\"stdout_bytes\":$stdout_size,\"inner_events\":$inner_count,\"worker_mtime\":$worker_mtime}"
      ROTATE_REQUESTED=1
      # Same group-kill rationale as the sentinel branch above.
      kill -TERM -- "-$INNER_PGID" 2>/dev/null || true
      break
    fi
  else
    silence_accum=0
    last_stdout_size="$stdout_size"
    last_inner_count="$inner_count"
    last_worker_mtime="$worker_mtime"
  fi

  sleep "$CHECK_INTERVAL"
done

wait "$INNER_PID" 2>/dev/null || true
INNER_EXIT=$(awk -F= '/^__CLAUDE_EXIT_CODE__/{print $2}' "$STDOUT_TAIL" | tail -n1)
INNER_EXIT="${INNER_EXIT:-1}"

# Founder abort path. Takes priority over rotation and
# success: an abort signal during a rotation context-burn is still an
# abort, and an inner that exited cleanly only because it received the
# group kill is not "finished cleanly". The synthesis branch checks
# whether the inner already emitted a block_abort (via the prompt's
# §6.0 cluster-boundary check) since the most recent wrapper_start;
# if so, the inner-authored event already routes the loop wrapper to
# exit 101. If not (the inner was wedged and never reached §6.0
# before the kill arrived), the wrapper synthesises a block_abort on
# its own behalf with reason founder_abort_signal_wedged so the loop
# wrapper's last-substantive-event scan still finds a substantive
# terminal event and routes correctly.
if [[ $ABORT_REQUESTED -eq 1 ]]; then
  inner_emitted_abort=$(LEDGER_PATH="$LEDGER" python3 - <<'PY'
import json, os
path = os.environ.get("LEDGER_PATH", "")
try:
    with open(path) as f:
        lines = f.readlines()
except FileNotFoundError:
    print(0)
    raise SystemExit
# Scope to events after the most recent wrapper_start so a block_abort
# from a previous rotation does not satisfy the current invocation.
start_idx = 0
for i, line in enumerate(lines):
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("event") == "wrapper_start":
        start_idx = i
emitted = 0
for line in lines[start_idx:]:
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("event") == "block_abort":
        emitted = 1
        break
print(emitted)
PY
  )
  if [[ "$inner_emitted_abort" != "1" ]]; then
    emit "block_abort" \
      "{\"reason\":\"founder_abort_signal_wedged\",\"abort_file\":\"$ABORT_FILE\"}"
  fi
  emit "wrapper_exit" \
    "{\"exit_code\":0,\"reason\":\"founder_abort_signal\",\"inner_exit\":$INNER_EXIT,\"inner_emitted_abort\":$inner_emitted_abort}"
  exit 0
fi

# Final SENTINEL check after the inner exits.
#
# The polling loop above grep's STDOUT_TAIL only while the inner
# process is alive (`kill -0 "$INNER_PID"`). Claude can print
# SENTINEL::CONTEXT_LIMIT_REACHED and then exit cleanly within a
# single CHECK_INTERVAL window, in which case the next loop iteration
# finds the inner gone and exits without grepping. Without this final
# check, a SENTINEL + clean-exit combination is misread as
# block-finished (exit 0), the outer caller does not re-spawn, and
# the operator is dropped to the shell mid-block. Observed upstream
# after a SENTINEL emission immediately preceded a cluster close.
if [[ $ROTATE_REQUESTED -eq 0 ]] && grep -q "SENTINEL::CONTEXT_LIMIT_REACHED" "$STDOUT_TAIL"; then
  emit "rotation_triggered" "{\"detected_at\":\"post_inner_exit\",\"inner_exit\":$INNER_EXIT}"
  ROTATE_REQUESTED=1
fi

# Progress probe: any clean or rotated exit must have produced at least one
# orchestrator-lifecycle event in the ledger, otherwise claude ran without
# actually starting the block and the exit code is meaningless.
PROGRESS_EVENTS='"event":[[:space:]]*"block_start"|"event":[[:space:]]*"cluster_start"|"event":[[:space:]]*"task_dispatched"'
if ! grep -Eq "$PROGRESS_EVENTS" "$LEDGER"; then
  emit "wrapper_exit" "{\"exit_code\":1,\"reason\":\"no_progress_events\",\"inner_exit\":$INNER_EXIT,\"rotate\":$ROTATE_REQUESTED}"
  echo "ERROR: claude exited without writing block_start / cluster_start / task_dispatched to the ledger." >&2
  echo "       See $STDOUT_TAIL for the model's response." >&2
  exit 1
fi

if [[ $ROTATE_REQUESTED -eq 1 ]]; then
  emit "wrapper_exit" "{\"exit_code\":4,\"reason\":\"rotate\"}"
  exit 4
fi

if [[ "$INNER_EXIT" == "0" ]]; then
  # ---- 7. Gate 3c per-cluster invocation slot (REMOVED in Aevum core) ------
  #
  # An upstream project used an ADR-defined Gate 3c slot to invoke a
  # per-cluster runner declared in block.yaml's
  # gates.per_cluster.gate3c.runner field. Aevum core ships with the
  # gate chain Gate 1 build + Gate 2 forbidden patterns + Gate 3a
  # acceptance + Gate 3b code review, nothing per-cluster, so the
  # slot is a no-op here and the _extract_gate3c_runner function
  # (kept above for shape parity with the original's --self-test
  # branch) returns an empty string on every block.yaml Aevum ships.
  #
  # If a project needs a per-cluster runner, restore the slot in a
  # project-side fork of this script and document the schema
  # extension in the project's block.yaml.
  emit "wrapper_exit" "{\"exit_code\":0}"
  exit 0
fi

emit "wrapper_exit" "{\"exit_code\":$INNER_EXIT,\"reason\":\"inner_nonzero\"}"
exit 1
