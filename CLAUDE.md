# Aevum

A Claude Code orchestration harness for managing long-form
multi-agent work. The harness itself is developer tooling; the
projects that consume it ship the actual product code.

## If you are Claude Code joining this project, START HERE

Read in this order:

1. `@.claude/rules/00-index.md`. Canonical rule index.
2. `@.claude/scripts/orchestrate-block.prompt.md`. Inner-orchestrator
   doctrine (the `claude -p` operating manual). Skim §0 to §3, dip
   into §6 cluster loop and §8 rotation as needed.
3. `@.claude/templates/block.yaml`. Block schema.
4. `@docs/design-notes.md`. Why the harness is shaped the way it is.
5. `@docs/swap-points.md`. Where the stack-bound seams are and how
   to swap them for your stack.
6. The rest of this file.

Working conventions to carry forward:

- Discuss before installing. No new packages without confirmation.
- No em-dashes in any output written for the founder or for the
  repo. Use commas, periods, parens, semicolons.
- Modular plus active-archive discipline. Small focused files; deep
  folder splits when justified; closed plans move immediately to
  `archive/plans/`.
- Doc-not-chat for multi-step config. Write reasoning to markdown;
  keep chat sparse.
- Best-in-class Anthropic patterns: subagents with minimal tools,
  skills with templates, hooks for write-time enforcement,
  `@path` imports in CLAUDE.md.

## Stack

Aevum core is stack-agnostic at the orchestration layer. The default
implementations assume:

- **Node 22+** for the Claude Code runtime and for
  `chrome-devtools-mcp` (optional).
- **Python 3.10+** for `scripts/*.py` (preflight, baseline,
  fix-loop budget, stale-verdict checks, gate runner).
- **pnpm** for the default Gate 1 runner
  (`.claude/scripts/gate1.sh` plus
  `scripts/quality-gate.py`).
- **bash** and **flock** for the wrapper and lock primitives.

Swap the Gate 1 stack for your language at the seam documented in
`docs/swap-points.md`.

## Project conventions

- Harness state under `.claude/` (rules, hooks, scripts, templates,
  agents, settings, state.yaml). All committed; runtime artefacts
  forbidden here (enforced by `claude-dir-write.sh`).
- Runtime artefacts under `logs/` (block ledgers, gate verdicts,
  gap reports, locks). Append-only; gitignored except where the
  project explicitly opts in.
- Block plans and fixtures under `docs/blocks/<BLOCK_ID>/`.
- Specialist agents the project authors live under `.claude/agents/`
  alongside the seven infrastructure agents Aevum ships.
- Plans under `docs/plans/` carry YAML frontmatter
  (`.claude/rules/plan-metadata.md`); closed plans move to
  `archive/plans/` immediately (`.claude/rules/doc-lifecycle.md`).

## Specialist agents

Aevum ships seven stack-agnostic infrastructure agents:

| Agent | Role |
|---|---|
| session-orchestrator | Plans and dispatches the cluster loop. |
| code-reviewer | Gate 3b judgment review. |
| config-validator | Gate 2 hardcoded-value and forbidden-pattern scan. |
| criteria-checker | Gate 3a acceptance verification. |
| fix-bucketer | Partition gate failures into repair buckets. |
| merge-analyser | Pre-merge file-collision detection. |
| status-tracker | Metrics and state.yaml updates. |

Project-specific specialists (UI workers, API workers, deploy
workers, voice-pipeline workers, etc.) are authored per project
from `examples/agents/AGENT_TEMPLATE.md` and live alongside the
infrastructure agents under `.claude/agents/`.

## Build / dev

Aevum itself has no build step; it is a directory of configuration,
shell scripts, and Python utilities. The projects that consume
Aevum bring their own build commands.

To smoke-test the harness on a fresh clone:

```bash
python3 scripts/block-preflight.py EXAMPLE
```

(Replace `EXAMPLE` with the slug of the example block under
`docs/blocks/`.)

## Demo loop and what NOT to do

The harness is developer tooling. Projects that consume the harness
own their own demo loops. The harness's contract ends at the
sign-off ceremony; promoting an integration branch to `main` is a
human action.

Never push, never force-push, never bypass hooks. The settings deny
list enforces all three. If you think you need to bypass one, the
answer is to fix the underlying issue or to ask the operator.

## Status

Aevum's orchestrator harness is stable. Active blocks (if any) are
listed in `.claude/state.yaml`.
