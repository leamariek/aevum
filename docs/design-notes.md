---
id: design-notes
title: Aevum Design Notes
created: 2026-05-17T00:00:00Z
updated: 2026-05-17T00:00:00Z
status: active
owner: founder
---

# Aevum design notes

Why the orchestrator is shaped the way it is. Read this when you are
making a non-trivial change to the harness or when you are deciding
whether to use Aevum on a new project.

## The unit: a block

A **block** is a small set of related **clusters** of **tasks**.
Tasks within a cluster run in parallel (one Agent dispatch per task).
Clusters run sequentially. Every cluster ends with a gate chain
(Gate 1 build, Gate 2 forbidden patterns, Gate 3a acceptance, Gate
3b code review). Every block ends with a founder sign-off ceremony.

The block primitive grew out of a frustration with phase-based or
sprint-based planning: those work at the wrong scale. A phase is too
big (the orchestrator cannot resume from a phase-tail rotation
without losing state); a sprint is too long (the gate chain has to
re-run after every cluster, and a sprint-sized batch makes the gate
chain noise impossible to attribute). A block is the unit at which
the orchestrator's gate chain pays for itself: small enough that the
cluster boundary is meaningful, large enough that the gate chain
runs only every few hours rather than every commit.

## Why a stub-write-first contract

Gates 2 and 3a are agent-authored. Agents fragment: under context
pressure or network hiccup, an agent can terminate mid-run with no
output. The orchestrator that polls the gate JSON for a verdict has
no way to distinguish "agent is still working" from "agent died
silently."

Aevum's gate agents resolve this with a **stub-write-first
contract**: the first observable side effect is a single Bash call
that writes `logs/gates/gate<N>.json` with `verdict: "pending"`. The
real work happens after. Atomic write at the end replaces the stub
with the terminal verdict. If the orchestrator reads `pending`, it
knows the agent fragmented and enters the fragmentation-recovery
branch (re-dispatch on the next fix iteration) rather than guessing
or hanging.

The fragmentation-recovery path is **tracked separately from the
substantive fix-loop budget** to avoid burning the founder-pause
threshold on agent reliability rather than block work. If
`fragmentation_recovery > 10` in a single cluster, a storm alarm
aborts the block; the workaround has itself become the failure
mode and the operator needs to act.

## Why three liveness signals

The wrapper's wedge detector watches three independent signals:

1. Inner-claude stdout size.
2. Inner-claude ledger event count
   (`logs/blocks/<BLOCK>/progress.jsonl`).
3. Freshest file mtime across all worker worktrees for the block.

A wedge fires only when ALL THREE stagnate for `SILENCE_LIMIT`
seconds. The third signal (worker mtime) was added after an
incident where parallel-cluster workers were falsely killed mid-run:
the inner claude was correctly blocked waiting for `Agent(...)`
returns, so signals 1 and 2 both stagnated, but workers were
actively writing files in their worktrees. With three signals,
parallel-task waits cannot be mistaken for wedges because a
productive worker advances mtime on every Edit/Write tool call
inside its worktree. Real hangs (worker stuck on a no-op spin,
frozen network call with no FS activity) still trip the wedge.

## Why an append-only ledger

`logs/blocks/<BLOCK>/progress.jsonl` is append-only and never
mutated. Every event the inner claude emits and every event the
wrapper emits goes here. The ledger is the source of truth for:

- Resume after context-limit rotation (read the tail, find the last
  `cluster_start` or `task_dispatched` event, check out the
  expected branch, proceed from there).
- Stale-gate-verdict detection (a `gate*_result` event carries the
  `head_sha_at_emit` field; if the cluster branch tip has advanced
  past that SHA without consuming the verdict, the verdict is stale
  and the operator must re-run the gate).
- Block close ceremony (`block_moat_demonstrated` followed by a
  founder-written `signoff/SIGNED.md` or `signoff/REJECTED.md`).
- Audit (every decision the orchestrator made, in order, with
  timestamps and SHAs).

The ledger lives under `logs/` rather than `.claude/` because
`.claude/` is committed configuration and `logs/` is runtime output.
See `.claude/rules/runtime-vs-config.md`.

## Why the gate chain order

The four gates run in a deterministic order at every cluster close,
and the order is not arbitrary:

1. **Gate 1 (build, lint, typecheck, test)** runs first because it
   is the cheapest verdict on a broken cluster. If Gate 1 fails,
   the subsequent gates' findings would mostly be downstream
   symptoms; bucket Gate 1 errors and fix them first.
2. **Gate 2 (config-validator)** runs second because it catches
   hardcoded values that survive Gate 1 (Gate 1 typechecks
   syntactic correctness; Gate 2 enforces architectural discipline).
3. **Gate 3a (criteria-checker)** runs third because acceptance
   criteria are the "did we build the right thing" check; running
   it before Gate 2 risks marking a criterion met when the
   implementation has a config violation that will block merge.
4. **Gate 3b (code-reviewer)** runs last because it depends on the
   other three gates' verdicts (it references them rather than
   re-deriving). Its job is judgment review of architectural
   compliance and commit hygiene.

If any gate fails, the cluster enters the fix loop and re-runs the
chain from Gate 1 after the fix lands. This re-runs cheap gates
before expensive ones.

## Why never push

`.claude/settings.json` denies every `git push` variant at the
harness level. The orchestrator never pushes; subagents never push;
no helper script pushes. Pushing to a remote is a human action,
performed by the operator from their own terminal.

Cost of waiting for a human push: small (typically a few seconds of
operator attention). Cost of an unwanted push (force-push to main,
leaked branch, contaminated history): large and sometimes
irreversible. The asymmetry is the entire argument.

The same logic denies `git pull`, `git fetch`, `git remote set-url`,
and `git remote add`. Agents work against the local state they
already have; the operator synchronises with the remote.

## Why worktree isolation for parallel tasks

Parallel tasks within a cluster get dispatched via
`Agent(isolation: "worktree")`. Each worker runs in its own git
worktree on its own branch (`block/<BLOCK>/<cluster_id>-<task_id>`).
This means:

- Workers never share a working tree; no race conditions on file
  writes.
- The orchestrator can observe per-worker progress via the worktree's
  own filesystem activity (the third wedge-detector signal).
- A failed worker's worktree can be removed without affecting
  siblings or the cluster branch tip.

The orchestrator's `worker-worktree-jail.sh` hook enforces the
boundary: a worker subagent can only write inside its own worktree.

## Why simplify the block schema

Earlier orchestrators (multi-week founder-discipline ruleset) layered
many fields onto the block primitive: thesis trace, research gate,
adversarial moat proof, mid-block alignment review. Those earn their
keep on multi-week blocks where the operator has 30 days of work
between block opens and the cost of a misframed block is enormous.

Aevum's core schema drops all of them. What remains is the minimum
the orchestrator's preflight actually validates: identity, base SHA,
clusters, parallel-safety invariants, acceptance. A project that
needs the heavier primitives layers them on per-project (fork the
template, add the fields, validate them in a project-side
preflight extension).

The simplification is opinionated: a tool that ships with too many
optional fields tends to grow them all unused. Better to ship a
small schema that every block actually fills in.

## Portability boundary

The Aevum harness is stack-agnostic at the orchestration layer. The
single stack-bound seam is the **Gate 1 runner**: Aevum ships a Node
/ pnpm default (`pnpm-locked-gate.sh` + `quality-gate.py`) because
that is the stack the author wrote it on; projects swap the runner
for their language (cargo, ruff, golangci-lint, etc.) at adoption
time. See `docs/swap-points.md` for the full seam list.

Everything else (rules, hooks, templates, generic agents, orchestrator
prompt, ledger format) is language- and framework-agnostic. The
generic infrastructure agents (`session-orchestrator`,
`code-reviewer`, `config-validator`, `criteria-checker`,
`fix-bucketer`, `merge-analyser`, `status-tracker`) check
architectural discipline, not stack details. Project-specific
specialist agents (UI workers, API workers, deploy workers) are
authored per project from
`examples/agents/AGENT_TEMPLATE.md`.

## Why an opinionated rule set

The harness ships 12 rules in `.claude/rules/`. Most are short
(under 100 lines). The set is opinionated: it picks the convention
the author finds works, rather than offering choices.

Examples of opinions:

- Conventional Commits for every commit message (universal in modern
  open-source).
- English by default for code, commits, prose (override per project
  if needed; rare).
- Append-only ledger, no rewrites of pushed commits (because rewrites
  destroy audit trail).
- Move-on-close for closed plans (avoids stale plans accumulating in
  active planning directories).

A project that disagrees with any opinion forks the rule file and
documents the project's reason. Aevum does not try to be neutral on
process; it tries to ship one set of conventions that works.
