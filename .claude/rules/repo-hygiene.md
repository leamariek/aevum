---
id: repo-hygiene
title: Repository Hygiene
created: 2026-05-15T00:00:00Z
updated: 2026-05-17T00:00:00Z
status: active
owner: founder
---

# Repository Hygiene

Where files belong, how they are named, when they are archived. Applies
to every file added or moved in a project that consumes the Aevum
orchestrator.

Aevum itself is language-agnostic at the harness layer. The repository
layout below is the **default convention**; projects override or extend
it via their own `repo-hygiene.local.md` (gitignored) or by editing this
file at adoption time. The principles (one root file per role, no loose
`*.md`, archive-with-README) are the universal part. The specific
directory names are the swappable part.

## Repository root

Only these files may live at the repo root:

- `CLAUDE.md`: orientation. "If you are Claude joining this project,
  start here."
- `HANDOVER.md`: append-only session log (created on first session).
- `README.md`: external-facing overview.
- `LICENSE`: source-available or open-source license text.
- Build, tooling, and package-manager config that the language
  toolchain expects at the root (for example `.gitignore`,
  `.editorconfig`, `package.json` and `pnpm-lock.yaml` for Node,
  `pyproject.toml` and `uv.lock` for Python, `Cargo.toml` and
  `Cargo.lock` for Rust). The set is project-specific; everything else
  is forbidden at the root.
- `.env.example` (or `.env.local.example`) as a contract; real env
  files are gitignored.

Planning, status, backlog, handoff, gap-analysis documents all live
under `docs/` or `archive/`.

**No loose `*.md` at the root other than the four named above
(`CLAUDE.md`, `HANDOVER.md`, `README.md`, `LICENSE`).**

## Directory layout

The Aevum harness itself owns:

| Path | Contents |
|---|---|
| `.claude/rules/` | Enforceable project rules. |
| `.claude/hooks/` | Shell hooks the harness executes at tool-use boundaries. |
| `.claude/templates/` | Canonical templates (block.yaml, plan.md). |
| `.claude/agents/` | Subagent definitions. |
| `.claude/scripts/` | Orchestration scripts. |
| `.claude/settings.json` | Permissions, hook wiring, MCP servers. |
| `.claude/state.yaml` | Advisory project-state snapshot. |
| `scripts/` | Repo-wide helper scripts (preflight, baseline, gate runners). |
| `docs/blocks/` | Per-block plan and fixture artefacts (`block.yaml`, `baseline.json`). |
| `docs/plans/` | Narrative plans, including the paired narrative plan for every block (see `block-discipline.md`). |
| `logs/` | Run logs and runtime artefacts. Append-only. See `runtime-vs-config.md`. |

The project consuming Aevum owns the rest:

| Path | Contents |
|---|---|
| `<source-root>/` | Project source code. Name and layout per the project's language convention. |
| `<source-root>/<domain>/` | Domain subdirs created as needed; respect import boundaries when declared. |
| `public/` or `assets/` or equivalent | Static assets the project serves. |
| `docs/adr/` | Architecture Decision Records, if introduced. |
| `archive/` | Historical material grouped by `plans/`, `code/`, etc. Every subtree needs a `README.md` answering why / replaced-by / when. |

Domain code should respect import boundaries when the project's linter
or build system declares an import-boundary DAG (for example
`import/no-restricted-paths` in an ESLint config, or
`importlinter` contracts in Python). Aevum ships without such a DAG;
add it per-project at init time, matched to the project's language and
linter.

## Naming

- Directories: kebab-case.
- Source files: language-native convention.
- Plan and session docs: `YYYY-MM-DD_<slug>.md` (ISO date first means
  alphabetical sort is chronological). See `plan-metadata.md`.
- Living docs (status dashboards, rolling backlogs, `HANDOVER.md`):
  `<slug>.md` without date; frontmatter `updated:` tracks freshness.

## Archival policy

- **Closed plans move immediately.** The moment a plan flips to
  `status: completed`, `status: superseded`, or `status: archived`,
  `git mv` it to `archive/plans/` in the same commit (or the
  immediate follow-up). No grace period. Detail: `doc-lifecycle.md`.
- **Never delete planning history.** Archive with `status: superseded`
  (or `archived`) and `superseded_by:` pointing at the replacement.
- **Superseded source files archive on supersession.** When a file is
  extracted, replaced, or rewritten under a new framing, the
  supersession commit includes the `git mv` to `archive/code/`.
- Generated artefacts never live in git: build caches, lockfile
  shadows, coverage reports, `__pycache__/`, `node_modules/`,
  `target/`, `.next/`, all in `.gitignore`.

## Moving existing files

1. Use `git mv` so history is preserved.
2. Prepend frontmatter (see `plan-metadata.md`) if the target is under
   `docs/` and the file is a plan.
3. Update inbound references (`grep -r <old-name>` then patch).
4. Commit as `chore(<scope>): move <old> to <new>`.

Root-level `.md` other than the four named above is a bug; open a PR
to move it.
