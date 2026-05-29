---
id: agent-fallibility-disciplines
title: "Agent-Fallibility Disciplines (v0.2.0): Karpathy Field-Notes Integration"
created: 2026-05-29T00:00:00Z
updated: 2026-05-29T00:00:00Z
status: active
owner: founder
tags: [harness, changelog, review]
---

# Agent-Fallibility Disciplines (v0.2.0)

What this version of the Aevum harness changed, updated, upgraded, and
fixed, and why. This is a living changelog: later versions append above
the previous entry.

## Versioning

Aevum follows SemVer. This document describes **v0.2.0**, the first
feature increment after the initial public release (treated here as
**v0.1.0**). The changes are additive and backward-compatible (new
rules, a new R-rule, template guidance), so this is a MINOR bump. If the
published harness is intended as v1.0.0, relabel this as v1.1.0; the
shape of the entry does not change.

## Source and credit

This version integrates the actionable subset of Andrej Karpathy's
January 2026 field notes on coding with LLMs:
https://x.com/karpathy/status/2015883857489522876

The notes catalogue how a capable code agent actually fails: it makes
wrong assumptions and runs with them, does not seek clarification or push
back, overcomplicates code and bloats abstractions (the
1000-lines-where-100-would-do pattern that anchors
`simplicity-discipline.md`), leaves dead code behind, and edits lines
orthogonal to the task. Their meta-lesson, that CLAUDE.md prose does not
change these behaviours, matches Aevum's existing thesis: enforcement
(hooks, gates, reviewers, worker templates) is what bites. Every change
below lands in the enforcement layer, not in narration.

## v0.2.0 (2026-05-29)

### Added

- **`simplicity-discipline.md` (new rule).** The smallest correct
  change; bans speculative abstraction, dead code, and orthogonal churn;
  pairs naive-correct-first with optimize-preserving-correctness.
  Enforced at Gate 3b (the code-reviewer "Simplicity and diff hygiene"
  subsection) and prevented at the worker template. The rule index now
  lists 13 rules.
- **`workflow.md` R11 (fail loud, do not guess).** Workers surface a
  load-bearing ambiguity, a contract or sibling-task conflict, a
  rule-breaking task, or a wrong premise via `status: failed` or a
  logged deviation, rather than inventing an interpretation or complying
  anyway.
- **`AGENT_TEMPLATE.md` Step 2.5 (inline plan).** Non-interactive
  workers write a short approach note before the diff, plus two
  consolidated Hard-constraints bullets (surface conflicts; build the
  smallest thing).
- **`code-reviewer.md`.** A diff-visible "Simplicity and diff hygiene"
  Gate 3b dimension.
- **`plan.md`.** An optional "alternatives weighed" prompt, deferring
  architectural-weight choices to `docs/adr/`.

### Upgraded and changed

- **`workflow.md` R2.** Where a test runner is wired, prefer authoring
  the test that encodes the criterion first, then implementing to green
  (the same declarative-acceptance leverage `criteria-checker` applies
  at Gate 3a).
- **Rule index synced.** `README.md` and `00-index.md` now carry 13
  entries and read `R1 to R11`; `design-notes.md` rule count went from
  12 to 13.

### Fixed

- **The `deviations:` phantom field.** R9 and the worker-template
  references told workers to log deviations in a `block.yaml`
  `deviations:` array, but neither the `block.yaml` template nor the
  orchestrator ever declared or processed that array, while R1 and
  `workflow.md`'s closing line already pointed at the real homes. R9 and
  the `AGENT_TEMPLATE.md` references now point at the homes that exist:
  the active block's narrative plan and `HANDOVER.md`. No schema field
  was added, consistent with the rejected options below.

## Already covered (verified, no change in v0.2.0)

- **C1 declarative framing.** Tasks dispatch with a `GOAL` plus an inline
  `ACCEPTANCE` list; preflight rejects a task with no criterion;
  `criteria-checker` (Gate 3a) marks vague criteria unmet.
- **C3 browser-in-the-loop.** `frontend-tooling.md` (Playwright default,
  chrome-devtools-mcp opt-in) plus the Gate 3a runtime-evidence check.
- **D2 tenacity.** The fix-loop budget (R6) and stall detector are the
  external circuit-breaker the agent will not supply itself.
- **D3 generation vs discrimination.** The read-only Gate 3b reviewer,
  the four-gate chain, and founder sign-off are the discrimination layer.

## Decisions and rejected options

The meta-lesson (prose does not change behaviour; enforcement does) is
Aevum's own thesis, so every change lands in the enforcement layer. Four
options were considered and rejected:

1. **A `block.yaml` assumptions / open-questions field. Rejected.**
   Contradicts `design-notes.md` "Why simplify the block schema" (the
   core schema deliberately drops optional fields). Assumptions arise at
   execution time; the homes are the active block's narrative plan and
   `HANDOVER.md`. The `deviations:` fix above applies the same
   principle: use existing homes, do not grow the schema.

2. **A standalone assumption-discipline rule file. Rejected for R11.**
   Assumption-surfacing is not visible in the durable diff, so a rule
   file would carry no Gate 3b teeth and would be the non-biting prose
   the meta-lesson warns against. The biting seam is the worker template
   at dispatch; R11 is the canonical index entry for that behaviour,
   consistent with R1, R3, and R9.

3. **A "every rule needs an Enforcement section" meta-rule. Rejected.**
   Six of the shipped rule files have no `## Enforcement` heading; a
   normative bar that most of the corpus fails and no hook checks is
   itself the prose-pileup the enforcement-over-prose thesis warns
   against.

4. **Two new rule files. Narrowed to one.** `simplicity-discipline.md`
   earns a file: it maps to a real, diff-visible Gate 3b dimension and
   carries a concrete example, in the mould of `fix-discipline.md`. The
   assumption cluster does not, so it is R11 rather than a second file.

## Out of scope

The reflections in the source notes (speedup vs expansion, fun, skill
atrophy, the slopacolypse, the 10X-engineer and generalist questions)
are not orchestration mechanisms and get no harness surface, consistent
with `block-discipline.md`'s precedent of declaring reflective concerns
out of scope.

## Possible follow-ups (not blocking this version)

- The root `CHANGELOG.md` is now the canonical version history. Tag the
  release (`git tag v0.2.0`) at merge so the version is also
  machine-readable for a no-build repo.

## Verification

- No em-dash (U+2014) in any added line (commit-policy ASCII rule).
- Rule count is consistent at 13 across `00-index.md`, `README.md`, and
  `design-notes.md`; the R-rule range reads `R1 to R11` in both indexes.
- No rule or worker template references a `block.yaml` `deviations:`
  array; only this changelog's Fixed note describes the removed phantom.
- One new rule file, indexed; no new `block.yaml` field.
