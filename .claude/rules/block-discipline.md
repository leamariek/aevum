---
id: block-discipline
title: Block Discipline
created: 2026-05-15T00:00:00Z
updated: 2026-05-17T00:00:00Z
status: active
owner: founder
---

# Block Discipline

Lightweight discipline for the block primitive. The Aevum block schema
is deliberately small: a `block.yaml` declaring identity, base SHA,
clusters, and tasks. This rule defines the minimum invariants every
block must satisfy plus a single optional primitive (`kill_criteria`)
that earns its keep on time-boxed blocks.

A heavier multi-week founder-discipline ruleset (thesis trace, research
gate, adversarial moat proof, mid-block alignment review) exists in
projects that consume Aevum for long-form work. Those primitives are
not part of the Aevum core; they are layered on per-project when the
work horizon justifies them.

## Block primitive: kill criteria (optional, encouraged)

Every `docs/blocks/<id>/block.yaml` may declare a `kill_criteria` list.
Each entry is specific, observable, and tied to measurable state:
schema, deploy status, gate verdict, or a wall-clock deadline. Vague
criteria ("if things go poorly") fail review.

Example:

```yaml
kill_criteria:
  - "if the staging smoke fails by 13:30 PT, drop Layer 2 work and
     finish Layer 1 close-out only."
  - "if Gate 3b returns CHANGES_REQUESTED on the no-op block, patch
     before continuing; do not start cluster cl-02 with cl-01 red."
```

A `block.yaml` without `kill_criteria` is accepted by preflight;
including them is encouraged for blocks with a wall-clock cap.

## Block creation: paired artefacts

Every block ships with two artefacts, created together:

1. `docs/blocks/<BLOCK_ID>/block.yaml`: the structured,
   orchestrator-executable plan (clusters, tasks, acceptance
   criteria).
2. `docs/plans/<YYYY-MM-DD>_block-<BLOCK_ID>.md`: the narrative
   plan (context, goals, reasoning, risks, post-mortem).

The canonical entry point is:

```bash
bash scripts/new-block.sh <BLOCK_ID> "<Title>" <owner>
```

It scaffolds both files from `.claude/templates/block.yaml` and
`.claude/templates/plan.md`, fills in identity and frontmatter
fields, and prints the next-step ladder (edit, activate, capture
baseline, preflight, dispatch).

For a legacy block that ships without a paired plan, back-fill
with `--plan-only`:

```bash
bash scripts/new-block.sh --plan-only <BLOCK_ID> "<Title>" <owner>
```

## Draft-time validation

Before flipping `status: draft` to `status: active`:

```bash
python3 scripts/block-preflight.py <BLOCK_ID>
```

Preflight catches: parallel-task literal-path conflicts, missing
serialising tail (no `parallel: false` task in a cluster), duplicate
cluster or task IDs, `depends_on` referencing a non-existent cluster,
`base_sha` not an ancestor of `base_branch`. Exit 0 means the plan is
clean; exit 2 means at least one structural blocker. Drafters fix in
place and re-run until clean.

## Post-close-hygiene exception

The closed-status check is normally a blocker so a closed block's
`block.yaml` cannot be silently relaunched. It demotes to `info`
(exit 0) when the block closed cleanly: `logs/blocks/<id>/signoff/SIGNED.md`
exists and the last block-progress lifecycle terminal in
`logs/blocks/<id>/progress.jsonl` is `block_signed_off`. Wedged or
in-flight closures keep the blocker.

## Enforcement

- `block-preflight.py` (mandatory at every dispatch) validates
  structural integrity.
- `code-reviewer` at Gate 3b confirms `kill_criteria` are observable
  and tied to measurable state when present.

## What Aevum intentionally does not bake in

| Primitive | Status |
|---|---|
| Thesis trace | Out of scope; layer per-project if you need it. |
| Research note (research-heavy blocks) | Out of scope; layer per-project. |
| Adversarial moat proof | Out of scope; layer per-project. |
| Mid-block alignment review | Out of scope; layer per-project. |
| Kill criteria | KEPT in core, optional. |
| Scope-creep test | Out of scope; founder-side discipline at planning time. |

If your project needs the full founder-discipline ruleset, fork this
rule into a project-specific `block-discipline.md` and add the heavier
primitives there; Aevum's job is to provide the structural enforcement
(preflight + ledger + gate chain) on top of whichever shape you choose.

## Related

- `.claude/templates/block.yaml`: the schema.
- `scripts/block-preflight.py`: the validator.
