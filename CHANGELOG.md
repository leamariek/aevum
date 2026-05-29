# Changelog

All notable changes to the Aevum harness are recorded here. The format
follows Keep a Changelog (https://keepachangelog.com), and the project
aims to follow Semantic Versioning (https://semver.org).

## [0.2.0] - 2026-05-29

Integration of the actionable subset of Andrej Karpathy's January 2026
field notes on coding with LLMs
(https://x.com/karpathy/status/2015883857489522876). Full rationale,
decisions, and rejected options:
`docs/plans/2026-05-29_agent-fallibility-disciplines.md`.

### Added
- `simplicity-discipline.md` rule: the smallest correct change; bans
  speculative abstraction, dead code, and orthogonal churn; pairs
  naive-correct-first with optimize-preserving-correctness. The rule
  index now lists 13 rules.
- `workflow.md` R11: workers fail loud and do not guess; they surface
  ambiguity, contract or sibling-task conflicts, rule-breaking tasks, or
  a wrong premise instead of guessing.
- `AGENT_TEMPLATE.md` Step 2.5 (inline plan) and two consolidated
  Hard-constraints (surface conflicts; build the smallest thing).
- `code-reviewer.md` "Simplicity and diff hygiene" Gate 3b dimension.
- `plan.md` optional "alternatives weighed" prompt.
- This `CHANGELOG.md` as the canonical version history.

### Changed
- `workflow.md` R2: prefer test-first where a test runner is wired.
- Rule index synced across `README.md`, `00-index.md`, and
  `design-notes.md` (13 rules; R-range `R1 to R11`).
- `repo-hygiene.md`: `CHANGELOG.md` added to the repository-root
  allow-list.

### Fixed
- Repointed deviation logging off a phantom `block.yaml` `deviations:`
  array (never declared by the template or the orchestrator) to the
  homes that exist: the active block's narrative plan and `HANDOVER.md`.

## [0.1.0] - 2026-05-17

### Added
- Initial public release of the Aevum orchestration harness
  (Apache-2.0): the block model, the four-gate chain (build, config,
  acceptance, review), seven infrastructure agents, the rule set, the
  write-time hooks, and the orchestrator scripts.
