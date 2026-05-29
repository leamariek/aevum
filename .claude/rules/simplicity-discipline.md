---
id: simplicity-discipline
title: Simplicity Discipline
created: 2026-05-29T00:00:00Z
updated: 2026-05-29T00:00:00Z
status: active
owner: founder
---

# Simplicity Discipline

The default failure mode of a capable code agent is not too little; it
is too much. Left alone it reaches for a bloated, brittle construction
where a small one would do, invents abstraction nobody asked for, leaves
dead code behind, and edits lines orthogonal to the task because it did
not understand them. None of that trips a compiler. All of it is a
maintenance cost the project pays later. This rule makes the smallest
correct change the target. It is the peer of `fix-discipline.md`: that
file governs WHERE you fix (the upstream cause), this one governs HOW
MUCH you change (the minimum that meets the criteria).

## The shape to avoid

A real pattern: an agent ships a 1000-line implementation, you ask
"couldn't you just do this instead?", and it cuts the same behaviour to
100 lines without losing a single acceptance criterion. The 900 lines
were never required; they were the agent over-reaching. The worker
should not have written them and the reviewer should have caught them.

## Rules

1. **Smallest construction that meets the acceptance criteria.** No
   speculative abstraction, no extra indirection layer, no API surface
   or config field beyond what the dispatched `GOAL` requires. An
   abstraction earns its place when it has real consumers now, not when
   it might have one later (see `design-principles.md`, Schema First).

2. **Naive-correct first, then optimize preserving correctness.** Write
   the obviously-correct version first. Optimize only when an acceptance
   criterion (latency, memory, throughput) demands it, and keep the
   criterion-verifying test green across the change. A clever
   construction that no criterion requires is bloat.

3. **Clean up in the same diff.** When a change supersedes code, delete
   the old path in the same diff; do not leave it beside its successor.
   No commented-out blocks, no helpers left uncalled, no branches made
   unreachable. Dead code is debt the next reader has to reason about.
   (Mechanical unused-import and unused-variable lint is Gate 1's job;
   this rule targets the dead code lint misses.)

4. **No orthogonal churn.** Do not edit, delete, reformat, or "improve"
   comments or code unrelated to the task, even inside files you own.
   Touch only the hunks the task requires. Reformatting or deleting a
   comment you do not fully understand as a side effect is the most
   common way a diff silently loses intent (see `workflow.md` R1,
   trace-to-task at hunk granularity).

## What this is not

Not a ban on abstraction or refactoring. Extracting a helper with three
real call sites is good. Propagating a schema change through its
consumers is good. Deleting genuinely dead code the task already touches
is good. What is banned is surface the task does not need, and churn the
task did not ask for.

## Enforcement

- **Worker prevention** (`examples/agents/AGENT_TEMPLATE.md`, Hard
  constraints): the worker is told to build the smallest thing, prefer
  naive-correct, delete superseded code, and leave orthogonal lines
  alone, before it writes the diff.
- **Gate 3b** (`code-reviewer`, "Simplicity and diff hygiene" section):
  all four rules above are diff-visible, so the reviewer enforces them
  against the cluster diff. Bloat spread thin across many small files is
  caught by the proportional-to-scope check, not the per-file 400-LOC
  smell.
- **Self-check before each diff:** count the surface you are adding. If
  a layer, field, or abstraction is not required by an acceptance
  criterion, cut it.

## Related

- `fix-discipline.md`: fix the upstream cause, not N symptoms. The
  complementary diff-reasoning rule (that one is about location, this
  one is about volume).
- `design-principles.md`: Schema First and Variable First; an
  abstraction or config field needs a present consumer.
- `workflow.md`: R1 (trace-to-task) and R2 (tests alongside, test-first
  where a runner is wired).
