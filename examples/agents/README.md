# examples/agents/

This directory holds a single template, `AGENT_TEMPLATE.md`. It is
**not** a runnable agent; Claude Code only loads agents from
`.claude/agents/`. Use the template as the starting point for your
own specialist agents.

## Why Aevum ships zero specialist agents

The Aevum orchestrator is a stack-agnostic plug-in. Your project's
specialists (UI worker, API worker, deploy worker, etc.) are
inherently stack- and domain-specific, so the orchestrator has no
opinion about which ones exist. The `task.agent` field in a block's
`block.yaml` resolves to the slug of any agent file you register
under `.claude/agents/`.

Aevum ships 7 stack-agnostic infrastructure agents under
`.claude/agents/`: `session-orchestrator`, `code-reviewer`,
`config-validator`, `criteria-checker`, `fix-bucketer`,
`merge-analyser`, `status-tracker`. Those run the orchestration
machinery itself. Specialists that do real product work are yours.

## How to add a specialist

1. Copy this template:

   ```bash
   cp examples/agents/AGENT_TEMPLATE.md .claude/agents/<your-slug>.md
   ```

2. Edit the frontmatter:
   - `name`: the slug (must match the filename without `.md`).
   - `description`: one sentence describing what the specialist
     owns.
   - `tools`: the minimum tool list. Default to `Read, Edit, Bash,
     Grep, Glob`; add `Write` only if the specialist legitimately
     creates new files.
   - `disallowedTools`: keep `Write` and `NotebookEdit` in here by
     default; remove an entry only when the specialist needs it.
   - `model`: `sonnet` for mechanical specialists; `opus` for
     judgment-heavy reviewers; `haiku` is too small for orchestrated
     work.
   - `maxTurns`: 40 is a reasonable default; reviewers may want
     more.

3. Edit the body:
   - §Surface: the literal globs the agent owns.
   - §Procedure: the actual steps for the agent's domain.
   - §Smoke: a 30-second self-check.

4. Reference the agent in a block:

   ```yaml
   # docs/blocks/<BLOCK_ID>/block.yaml
   tasks:
     - id: T01
       agent: <your-slug>     # matches .claude/agents/<your-slug>.md
       parallel: true
       title: "<task title>"
       files_touched_globs: ["<surface-globs>"]
       acceptance: ["<observable outcome>"]
   ```

5. Dispatch:

   ```bash
   bash .claude/scripts/orchestrate-block.sh <BLOCK_ID>
   ```

## Tool minimisation

The single most useful discipline when writing a specialist is tool
minimisation. A specialist that has `Write, Edit, Bash, MultiEdit`
plus all MCP tools will produce diffs that wander into unrelated
files, run unrelated commands, and make merges painful. A specialist
that has the minimum set (typically `Read, Edit, Bash, Grep, Glob`,
plus or minus one) produces focused diffs, dispatches safely in
parallel, and survives review.

If you find yourself needing a new tool mid-task, that is a signal
the agent's surface is wrong. Split the agent or expand the surface
deliberately; do not silently widen the tool list.

## Coordination contracts

Specialists do not import each other's code. Coordination happens
via a small set of stable contracts. See
`.claude/agents/session-orchestrator.md` §Cross-domain coordination
for the patterns Aevum supports:

- Shared state store (a leaf module everything depends on).
- Shared manifest or schema file (one writer, many readers).
- Environment contract (`.env.example` or equivalent).

Two specialists are safe in parallel if their
`files_touched_globs` lists do not overlap on a literal path and
neither depends on the other's unmerged changes.

## Naming

Use kebab-case slugs that describe the surface, not the framework.

Good:

- `ui-component-worker`
- `api-route-worker`
- `deploy-worker`
- `voice-pipeline`
- `data-ingestion`

Less good:

- `worker-1` (uninformative)
- `helper` (uninformative)
- `react-tailwind-shadcn-worker` (too many framework details; one
  surface plus one framework hint is enough; the rest goes in the
  body)
