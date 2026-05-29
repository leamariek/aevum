---
id: workflow
title: 8-Step Session Workflow
created: 2026-05-13T00:00:00Z
updated: 2026-05-29T00:00:00Z
status: active
owner: founder
---

# Session Workflow

Every orchestrated session follows the 8-step scheme. Direct,
non-orchestrated work (typing into Claude Code at the repo root) is
exempt; the workflow applies to subagent-driven block sessions kicked
off via the orchestrator.

The detailed protocol lives in
`.claude/scripts/orchestrate-block.prompt.md`; this file is the short
reference.

## The 8 steps

1. **Plan read**: read the active block plan and the roadmap entry for
   the session; read `CLAUDE.md` and any subdirectory-local conventions
   for every domain the session touches.
2. **Session plan**: `session-orchestrator` writes a session plan and
   any per-task prompt bundle under
   `logs/blocks/<BLOCK>/<session-id>-task-<task-id>-prompt.md`.
3. **Implement**: per-task subagents (whichever specialists the project
   registers under `.claude/agents/`) do the work on
   `block/<BLOCK_ID>/<cluster_id>-<task_id>` worker branches. Workers
   may self-plan inline first (a short approach note in the task's
   prompt bundle) before writing the diff; see `examples/agents/AGENT_TEMPLATE.md`
   Step 2.5.
4. **Gate 1 (build, lint, typecheck, test)**: runs via the project's
   Gate-1 runner. Aevum's default runner is
   `bash .claude/scripts/gate1.sh --force` (Node/pnpm
   example; swap for your stack at this single seam, see
   `docs/swap-points.md`). The runner serialises against concurrent
   invocations via flock and writes `logs/gates/gate1.json`.
5. **Gate 2 (config-validator)**: scans the diff for hardcoded business
   values and forbidden patterns (consumes
   `.claude/rules/forbidden-patterns.md` YAML).
6. **Gate 3a (criteria-checker)**: verifies each acceptance criterion
   against diff plus runtime evidence.
7. **Gate 3b (code-reviewer)**: architectural review, repo-hygiene
   compliance, commit-hygiene spot check. Writes
   `logs/gates/gate3b.json`.
8. **Merge and close**: fast-forward merge of cluster branches onto
   `block/<BLOCK_ID>/integration`, then onto `main` when the block
   closes (founder-initiated); `status-tracker` updates
   `.claude/state.yaml`; session entry added to
   `logs/blocks/<BLOCK>/progress.jsonl`.

## Rules every agent must honor

- **R1**: Every code change must trace to a task in a session plan or
  to a logged deviation in the active block's plan or `HANDOVER.md`.
- **R2**: Tests are written alongside the code, not after. Default
  coverage target is at least 80% per domain where a test runner is
  wired; projects override at adoption time. Where a runner is wired
  and the acceptance criterion is mechanically testable, prefer
  authoring the test that encodes the criterion first, then
  implementing to green, so the worker loops against its own test
  rather than a downstream gate; this is the same declarative-acceptance
  leverage `criteria-checker` applies at Gate 3a.
- **R3**: Changes to shared types or the shared store need
  coordination (the store is typically a DAG leaf; everything depends
  on it). Coordinate via comment in PR or `HANDOVER.md` before a
  non-trivial shape change lands.
- **R4**: Thresholds, field names, business rules live in
  configuration (project's config module, env vars, or a config file),
  not inline in code. Enforced by `config-validator`.
- **R5**: Every session gets a review before merge (Gate 3b).
- **R6**: Gates must be green before merge. A red gate enters the fix
  loop. After 5 substantive iterations the session escalates to
  founder review; after 10 a fragmentation-storm alarm aborts the
  block.
- **R7**: No direct commits to `main`; no force pushes; no amends of
  pushed commits. See `commit-policy.md`.
- **R8**: Session plans and phase plans carry valid YAML frontmatter
  (see `plan-metadata.md`).
- **R9**: Deviations from the active block plan are logged in the
  active block's narrative plan or in `HANDOVER.md`, with date and
  reason.
- **R10**: Commits follow Conventional Commits and never carry
  AI-authorship trailers (see `commit-policy.md`).
- **R11**: Workers fail loud, they do not guess. When a load-bearing
  ambiguity, a conflict with a shared contract the worker consumes but
  does not own (R3), a sibling-task conflict, a task that can only be
  satisfied by breaking a rule, or a dispatched premise the worker
  believes is wrong survives reading the envelope and the surface, the
  worker surfaces it rather than inventing an interpretation, silently
  working around it, or complying anyway: return `status: failed` with a
  specific `reason`, or implement the rule-compliant version and log an
  R9 deviation. Prevented at the worker template
  (`examples/agents/AGENT_TEMPLATE.md`); only the durable diff and the R9
  log reach Gate 3b.

## State files

- `.claude/state.yaml`: advisory snapshot of project state (active
  block, active branch, blockers).
- `logs/blocks/<BLOCK>/progress.jsonl`: authoritative event log per
  block.
- `logs/gates/gate1.json` through `gate3b.json`: atomic per-gate
  snapshots.

Deviations logged in the active block's plan or in `HANDOVER.md`.
