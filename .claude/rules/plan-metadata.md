---
id: plan-metadata
title: Plan Metadata & Frontmatter
created: 2026-04-16T00:00:00Z
updated: 2026-04-20T17:30:00Z
status: active
owner: founder
---

# Plan Metadata

Every file under `docs/plans/**/*.md` and `archive/plans/**/*.md` **must**
start with a valid YAML frontmatter block. The hook
`.claude/hooks/plan-frontmatter.sh` blocks Writes/Edits that violate this.

## Required fields

```yaml
---
id: <kebab-case-slug>                 # unique, stable; used for supersedes/superseded_by
title: <Short Human Title>
created: 2026-04-16T00:00:00Z         # ISO 8601 UTC; never changes after creation
updated: 2026-04-16T00:00:00Z         # ISO 8601 UTC; bumped on every substantive edit
status: draft                         # draft | active | completed | superseded | archived
owner: <name-or-agent-id>             # human name or agent slug
---
```

## Conditionally required fields

```yaml
completed: 2026-04-20T00:00:00Z       # REQUIRED when status: completed; ISO 8601 UTC
superseded_by: <new-id>               # REQUIRED when status: superseded; must resolve to an existing plan id
```

The hook blocks on `status: completed` without `completed:` and on
`status: superseded` without `superseded_by:`. Both `supersedes:` and
`superseded_by:` must point at an `id:` that actually exists under
`docs/plans/` or `archive/plans/` (no ghost IDs).

## Optional fields

```yaml
phase: P3.5                           # phase tag if applicable
supersedes: <old-id>                  # set when this replaces an older plan (must resolve)
tags: [roadmap, backlog]              # free-form
estimated_hours: 142
```

## Filename convention

- Plans with a point-in-time: `YYYY-MM-DD_<slug>.md`
  (e.g. `2026-04-16_roadmap.md`, `2026-04-16_gap-analysis.md`).
- Living docs that carry no single "created on" date:
  `<slug>.md` without the date prefix (e.g. `status-dashboard.md`,
  `backlog-postponed.md`). Frontmatter `updated` tracks freshness.
- ISO date first → alphabetical sort becomes chronological.

## Status transitions

```
draft     → active          : plan is being executed against.
draft     → archived        : abandoned before work started.
active    → completed       : work done, plan frozen for history.
active    → superseded      : replaced by a newer plan (set superseded_by).
active    → archived        : abandoned mid-flight; add archive README.
completed → superseded      : completed plan later replaced by a rework.
completed → archived        : after 14-day grace, move to archive/plans/.
superseded → archived       : after 7-day grace, move to archive/plans/.
```

**Forbidden transitions** (hook rejects):

- Any terminal → non-terminal revival (`completed → active`,
  `superseded → active`, `archived → *`).
- Skip-ahead through lifecycle (`draft → completed`,
  `draft → superseded`).

Grace periods and archive discipline are codified in
`.claude/rules/doc-lifecycle.md`.

## When `updated` must change

- Every substantive content edit (not pure typo fixes).
- Every status transition.
- Every time the plan is moved between directories or renamed.

The hook computes the current UTC timestamp and expects `updated` to be
within 24 h of it when the file is modified; otherwise it asks for a bump.

## Template

`.claude/templates/plan.md` holds the canonical scaffold. Copy it when
creating a new plan and fill in `id`, `title`, `created`, `updated`, and
`owner` before the first commit.

## Enforcement

- **Hook**: `.claude/hooks/plan-frontmatter.sh` runs on `PreToolUse` for
  `Write|Edit` matching `docs/plans/` or `archive/plans/`. Blocks on:
  missing frontmatter, invalid YAML, missing required field, `status` not
  in the allowed set, stale `updated` on content changes, `completed`
  missing when `status: completed`, `superseded_by` missing or unresolved
  when `status: superseded`, `supersedes:` / `superseded_by:` pointing
  at ghost IDs, invalid `status` transitions. Warns (non-blocking) when
  `status: active` files are untouched for more than 90 days.
- **Exempt** from the hook: `_SESSION_TEMPLATE.md`, any `README.md`, and
  per-task execution prompts under `docs/plans/sessions/prompts/*-prompt.md`
  (transcripts, not plans: canonical location is `logs/phase-N/*-prompt.md`).
- **Review**: `fap-reviewer` verifies frontmatter at Gate 3b when a session
  touches a plan file.
