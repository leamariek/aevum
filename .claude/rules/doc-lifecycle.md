---
id: doc-lifecycle
title: Document Lifecycle & Archive Discipline
created: 2026-04-20T17:30:00Z
updated: 2026-04-20T21:20:00Z
status: active
owner: founder
---

# Document Lifecycle

Plans and living docs accumulate fast in a planning-heavy repo. Without a
lifecycle rule, drafts pile up, completed plans rot at `status: active`,
and superseded plans hang on next to their replacements. This rule codifies
when a doc moves states and when it physically leaves `docs/plans/` for
`archive/`.

Scope: every file under `docs/plans/**/*.md` and `archive/plans/**/*.md`.
The layout rules live in `repo-hygiene.md`; the frontmatter schema
lives in `plan-metadata.md`; this file owns transitions and the
move-on-close rule.

## Status transition graph

```
draft
  ├─→ active                   (work begins)
  └─→ archived                 (abandoned before start; add archive README)

active
  ├─→ completed                (work done; set `completed: <ISO>`)
  ├─→ superseded               (replaced; set `superseded_by: <id>`)
  └─→ archived                 (abandoned mid-flight; add archive README)

completed
  ├─→ superseded               (later rework replaces the finished plan)
  └─  (terminal at docs/plans/): the file MUST `git mv` to archive/plans/
                                   in the same commit as the status flip

superseded
  └─  (terminal at docs/plans/): same rule: move in the same commit

archived
  └─  (terminal)               (never revive; create a new plan instead)
```

All other transitions are rejected by
`.claude/hooks/plan-frontmatter.sh`. Reviving a terminal plan is forbidden
because it erases the audit trail: if a completed plan's work needs
redoing, open a new plan that `supersedes:` the original.

## Move-on-close rule

Closed plans move immediately. There is no grace period. The moment a
plan's `status` flips to `completed`, `superseded`, or `archived`, the
same commit that flips the status also runs `git mv` to move the file
under `archive/plans/`.

| From state | Move to `archive/plans/` |
|---|---|
| `completed` | Same commit as the flip. |
| `superseded` | Same commit as the flip. |
| `archived` at creation | Same day as creation. |

Rationale: two weeks of "completed" plans living in `docs/plans/`
alongside active roadmaps has been a durable source of confusion. The
audit trail is preserved by git history and by `archive/plans/`; having
closed files physically present in the active planning directory buys
nothing. `/hygiene` treats any `completed` or `superseded` plan at
`docs/plans/` root as a **blocker**, not a cleanable.

The move-on-close rule is enforced three ways:

1. `.claude/hooks/plan-frontmatter.sh` rejects a flip to `completed` or
   `superseded` unless the file is being moved in the same tool call,
   or the file is already under `archive/plans/`.
2. `/hygiene` skill (optional, ships unauthored in Aevum core; when a
   project adds it, the canonical path is
   `.claude/skills/hygiene/SKILL.md`) will surface stragglers as
   **blocker** findings at every phase or block boundary. Until the
   skill lands, this enforcement is review-time only.
3. `code-reviewer` at Gate 3b flags any PR that closes a plan without
   the matching `git mv`.

## Archive discipline

Every `archive/plans/<subtree>/` root **must** contain a `README.md` that
answers three questions:

1. **Why is this here?** One sentence describing the subtree's purpose
   (e.g. "phase 3 session artefacts", "orchestrator v3 drafts").
2. **What replaced it?** Point at the successor plan / ADR / block.
3. **When did it archive?** ISO 8601 date of the archival commit.

Without the README, the archive becomes a graveyard of context-free files.
A future reader cannot reconstruct why a plan was superseded. The README
is a one-time write per subtree; it does not need to update as new files
land in the same subtree unless the collective meaning shifts.

Example skeleton:

```markdown
# Orchestrator v3 drafts (archived 2026-04-20)

These files captured the v3 orchestrator design before v0 (block model)
superseded them. Three technical decisions worth preserving were
extracted into `docs/block-model.md §v1-prep`; the rest of the reasoning
is kept here for auditability.

Replaced by: `docs/block-model.md`, `.claude/scripts/orchestrate-block.*`.
```

## Ownership and staleness signals

`status: active` is not a parking lot. A plan that has not been touched
in 90 days is either done (flip to `completed`), replaced (flip to
`superseded`), or abandoned (flip to `archived` and add the README).
The plan-frontmatter hook warns (non-blocking) when it sees an
active plan whose `updated:` is older than 90 days; the warning goes to
stderr so the founder sees it during any edit to that plan.

The warning does not fire for `draft` plans because drafts routinely
incubate for months. It does not fire for terminal states because those
are intended to be stable.

## When to start a new plan vs. edit an existing one

- New plan when: the scope, owner, or acceptance criteria change
  materially. Set `supersedes:` on the new plan; flip the old to
  `superseded` in the same commit where possible (hook allows within 24 h).
- Edit in place when: typos, clarifications, or content refinements that
  do not change scope or criteria. Bump `updated:`; do not change
  `status`.

If you are unsure, prefer a new plan with `supersedes:`. Branching is
cheaper than rewriting history.

## Interaction with other rules

- `repo-hygiene.md` owns directory placement; this rule tells you
  when to move between directories.
- `plan-metadata.md` owns the frontmatter schema; this rule tells you
  how state transitions between the schema values.
- `hygiene-cadence.md` runs the `/hygiene` audit at phase / block
  boundaries; this rule is the policy the audit enforces.

## Enforcement

- **Commit time** (`.claude/hooks/plan-frontmatter.sh`): transition graph
  rejection, ghost-ID validation, `completed:` / `superseded_by:`
  presence, move-on-close enforcement (flip to closed state requires a
  same-commit `git mv` into `archive/plans/`), 90-day-active warning.
- **Weekly** (`docs-watcher` agent): archive-README presence check,
  orphan-plan scan, stale `active` detection.
- **On-demand** (`/hygiene` skill): full repo audit; flags any closed
  plan still at `docs/plans/` root as **blocker**.
- **Review** (`code-reviewer` at Gate 3b): spot check that new plans
  touched in the session follow the lifecycle.

Advisory cadence (`/hygiene` skill) continues to exist for the founder-
initiated audits; it overlaps with the weekly scan and that is
intentional: the weekly scan catches drift between founder audits.
