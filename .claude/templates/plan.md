---
id: <kebab-case-slug>
title: <Short Human Title>
created: 2026-04-16T00:00:00Z
updated: 2026-04-16T00:00:00Z
status: draft
owner: <name-or-agent-id>
phase: <optional phase tag>
# supersedes: <old-id>
# superseded_by: <new-id>
# tags: []
# estimated_hours: 0
---

# <Plan Title>

> Replace the frontmatter fields above (especially `id`, `title`, `created`,
> `updated`, `owner`, `phase`) before the first commit. See
> `.claude/rules/plan-metadata.md` for field semantics.

## Context

Why this plan exists. What problem it solves. What was tried before (if
anything) and why it did not work.

## Goals

- Outcome 1: measurable.
- Outcome 2: measurable.
- Outcome 3: measurable.

## Non-goals

What this plan explicitly does **not** tackle, so scope does not drift.

## Approach

Ordered steps. Each step names the artifact it produces (file, decision,
merged PR). Keep steps small enough to commit individually.

1. Step 1: produces …
2. Step 2: produces …
3. Step 3: produces …

*Optionally, record the alternatives weighed:* the approach(es) rejected
and why, one line each. If a choice rises to architectural weight, record
it as an ADR under `docs/adr/` instead of here.

## Critical files

- `path/to/file-1.ts`: role in this plan.
- `path/to/file-2.py`: role in this plan.

## Risks & open questions

- Risk 1: mitigation.
- Open question 1: who decides, by when.

## Verification

How we know the plan is done. Concrete commands, checks, or acceptance
criteria.

## Out of scope / deferred

Items explicitly punted, with a link to the follow-up plan or a backlog
entry.
