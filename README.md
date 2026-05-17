# Aevum

A Claude Code orchestration harness for managing long-form
multi-agent work.

Aevum (Latin: age, lifetime) is the unit of disciplined, sustained
effort. The harness shares the same shape: it carries work across
many sessions, many context-limit rotations, and many specialist
agents without losing state, without dropping the audit trail, and
without quietly cutting corners.

## What this is

Aevum drives blocks of multi-agent work end to end:

- A small, validated `block.yaml` schema for declaring clusters of
  parallel-safe tasks.
- A wrapper plus inner-orchestrator split: the wrapper handles
  process lifecycle (rotation, wedge detection, founder kill
  signals); the inner is a `claude -p` invocation that dispatches
  workers and runs gates.
- Worktree isolation for every parallel task; no working-tree
  collisions when three workers land at the same gate boundary.
- A four-gate chain at every cluster close (build / lint / typecheck,
  forbidden-pattern scan, acceptance verification, architectural
  review).
- An append-only ledger (`logs/blocks/<BLOCK>/progress.jsonl`) that
  every wrapper and agent event flows into; the orchestrator resumes
  from the ledger tail after a context-limit rotation.
- Fix-loop bucketing when a gate fails (bucket errors by category +
  module, dispatch one fix worker per bucket, re-run the failing
  gate, iterate).
- A founder sign-off ceremony at block close (`SIGNED.md` or
  `REJECTED.md` files; no autonomous push to main).

The harness ships with seven stack-agnostic infrastructure agents
(`session-orchestrator`, `code-reviewer`, `config-validator`,
`criteria-checker`, `fix-bucketer`, `merge-analyser`,
`status-tracker`). The specialist agents that do real product work
(UI workers, API workers, deploy workers) are yours; see
`examples/agents/AGENT_TEMPLATE.md`.

## Why you might want this

Most Claude Code workflows hit the same wall: the model is great at
focused work in a single turn, but loses coherence across long
sessions, parallel dispatches, and gate boundaries. Aevum's
contribution is the **structural discipline** that keeps long-form
work coherent:

- **Resumable.** Every state transition is in the ledger; a fresh
  `claude -p` invocation can resume exactly where the previous one
  ran out of context.
- **Observable.** Gate verdicts are atomic JSON files; the
  orchestrator never guesses whether an agent is still working
  (stub-write-first contract).
- **Bounded.** Fix loops have substantive-iteration milestones and a
  fragmentation-storm alarm; a stuck cluster asks for help, it does
  not silently spin.
- **Auditable.** Every decision the orchestrator made, in order,
  with timestamps and SHAs, lives in the ledger forever.
- **Hardened against the obvious failure modes.** No autonomous
  push, no force-push, no hook bypass, no `git add -A`, no
  destructive resets. The harness denies these at the settings
  layer; no agent can override.

The discipline is opinionated. Read
[`docs/design-notes.md`](docs/design-notes.md) for the
reasoning behind each choice.

## Quickstart

### Requirements

- Claude Code CLI on PATH (`claude --version` should work).
- `git`, `python3`, `bash`, `flock` available locally.
- For the default Node/pnpm Gate-1 runner: `pnpm` and a project
  with `package.json`, `pnpm lint`, `pnpm build`, `pnpm exec tsc
  --noEmit`. Swap these for your stack at the Gate-1 seam (see
  [`docs/swap-points.md`](docs/swap-points.md)).

### Install

```bash
git clone https://github.com/<you>/aevum.git
cd aevum

# Optionally drop the harness into an existing project:
#   cp -r aevum/.claude /path/to/your/project/
#   cp -r aevum/scripts /path/to/your/project/
#   cp -r aevum/docs/blocks /path/to/your/project/docs/
```

### Author a block

Copy the template:

```bash
mkdir -p docs/blocks/B1
cp .claude/templates/block.yaml docs/blocks/B1/block.yaml
```

Edit `docs/blocks/B1/block.yaml`: set `id`, `title`, `base_sha`,
declare clusters and tasks. Each cluster needs exactly one task with
`parallel: false` (the serialising tail). Each task names an
`agent:` slug that resolves to a file under `.claude/agents/`.

Validate at draft time:

```bash
python3 scripts/block-preflight.py B1
```

Exit 0 means the plan is clean. Exit 2 means at least one
structural blocker; fix in place and re-run.

Capture the Gate-1 baseline (errors at block-open time become the
floor; subsequent gates measure regression vs. this floor, not
absolute zero):

```bash
bash scripts/capture-baseline.sh B1
```

### Dispatch

```bash
bash .claude/scripts/orchestrate-block-loop.sh B1
```

The loop wrapper invokes the inner `claude -p` orchestrator,
re-spawns it across context-limit rotations, and exits when the
block reaches a terminal state (founder sign-off, abort, or
max-rotations exhaustion).

The inner orchestrator uses `--dangerously-skip-permissions` to
run tool calls without per-call prompts. The harness's settings
deny list (`.claude/settings.json`) is the safety net: pushes,
force-pushes, `git add -A`, hook bypass, destructive resets, file
writes to common secret paths are all blocked at the tool layer
regardless.

### Sign off

When the block reaches the close ceremony, the orchestrator prints:

```
BLOCK B1 READY FOR SIGN-OFF
Integration SHA: <SHA>
To approve: write logs/blocks/B1/signoff/SIGNED.md with founder
  name, date (UTC), integration SHA, and "approved" on its own
  line.
To reject:  write logs/blocks/B1/signoff/REJECTED.md instead.
```

Write the sign-off file. The orchestrator polls every 30s, emits
`block_signed_off`, and exits. Fast-forwarding the integration
branch onto `main` is a human action (not part of the harness).

## Architecture

### Rule index

`.claude/rules/00-index.md` is the canonical entry. Read in order:

1. `design-principles.md`: Config-over-Code, Schema First, Variable
   First, Module Isolation.
2. `language-policy.md`: English by default.
3. `commit-policy.md`: Conventional Commits, branch naming, forbidden
   git flags, never push.
4. `forbidden-patterns.md`: hook-enforced regex rules.
5. `runtime-vs-config.md`: `.claude/` is committed config; `logs/` is
   runtime.
6. `repo-hygiene.md`: directory layout, naming, archival.
7. `plan-metadata.md`: YAML frontmatter contract.
8. `doc-lifecycle.md`: status-transition graph, move-on-close rule.
9. `workflow.md`: the 8-step session workflow and R1 to R10.
10. `frontend-tooling.md`: optional Playwright / Chrome DevTools MCP.
11. `block-discipline.md`: kill criteria, preflight validation.
12. `fix-discipline.md`: fix upstream, not N symptoms.

Each rule is short and self-contained. Hooks enforce the
mechanically-checkable parts; review agents enforce the rest.

### Script entry points

- `bash .claude/scripts/orchestrate-block-loop.sh <BLOCK_ID>`: the
  outer wrapper. Auto-respawns the inner orchestrator across
  context-limit rotations.
- `bash .claude/scripts/orchestrate-block.sh <BLOCK_ID>`: the wrapper
  that boots the inner `claude -p` for one rotation.
- `bash scripts/capture-baseline.sh <BLOCK_ID>`: capture the
  Gate-1 error baseline at block open.
- `python3 scripts/block-preflight.py <BLOCK_ID>`: draft-time
  validator.
- `bash .claude/scripts/pnpm-locked-gate.sh --force`: default
  Gate-1 runner (Node/pnpm; swap for your stack).
- `bash .claude/scripts/cleanup-stale-block.sh <BLOCK_ID>`: delete
  local branches for a closed or abandoned block namespace.

### Specialist agent rotation

Specialists run as `Agent(isolation: "worktree")` workers
dispatched by the inner orchestrator. Each gets a focused task
envelope (block, cluster, task, base SHA, goal, acceptance,
constraints), works on its own worker branch in its own worktree,
and returns a structured JSON response. The orchestrator merges
returned worker branches into the cluster branch in task-id order,
then runs the four-gate chain at the cluster boundary.

### Block lifecycle

```
plan (block.yaml) → preflight → dispatch → cluster loop:
  open → parallel tasks → serialising tail → merge into cluster
  → Gate 1 → Gate 2 → Gate 3a → Gate 3b → fix loop if any fail
  → close into integration branch
→ block close: replay full gate chain on integration tip
→ block_moat_demonstrated event
→ founder sign-off ceremony (SIGNED.md or REJECTED.md)
→ block_signed_off event
```

See [`docs/design-notes.md`](docs/design-notes.md) for the
reasoning behind each stage.

## Customising for your stack

The harness is stack-agnostic except for a small set of seams
documented in [`docs/swap-points.md`](docs/swap-points.md). The
single non-optional seam is the **Gate 1 runner**: Aevum ships a
Node/pnpm default; replace it with your language's equivalent
(`cargo`, `ruff` + `pytest`, `golangci-lint` + `go test`, etc.)
when you adopt.

Specialist agents (the workers that do real product work) are
yours. Aevum ships ZERO specialist agents in `.claude/agents/`
beyond the seven infrastructure agents. Copy the skeleton at
[`examples/agents/AGENT_TEMPLATE.md`](examples/agents/AGENT_TEMPLATE.md)
to write your own.

## License

PolyForm Noncommercial 1.0.0. Free for non-commercial use
(personal projects, research, education, evaluation). Commercial
use requires a separate license from the copyright holder. See
[`LICENSE`](LICENSE) for the full terms.

If you find Aevum useful for non-commercial work, an issue or a
star is the best signal back. Pull requests welcome.
