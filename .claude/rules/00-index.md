---
id: rules-index
title: Project Rules Index
created: 2026-05-15T00:00:00Z
updated: 2026-05-17T00:00:00Z
status: active
owner: founder
---

# Project Rules

**Read these before coding.** `CLAUDE.md` at the repo root is
orientation only; the enforceable rules live in this directory. Every
rule file is short, focused, and self-contained. Hooks under
`.claude/hooks/` and the review agents under `.claude/agents/` enforce
subsets of these rules automatically.

## Reading order

Order moves from universal (apply everywhere) to process (workflow,
branches) to meta (planning, audit). Read in order; later rules
reference earlier ones.

1. **[design-principles.md](./design-principles.md)**: four
   non-negotiable architecture principles: Config-over-Code, Schema
   First, Variable First, Module Isolation.
2. **[language-policy.md](./language-policy.md)**: English by default
   for code, commits, comments, docs, PRs.
3. **[commit-policy.md](./commit-policy.md)**: Conventional Commits,
   project scopes, branch naming, forbidden trailers (including a ban
   on AI authorship trailers), forbidden git flags.
4. **[forbidden-patterns.md](./forbidden-patterns.md)**: patterns that
   must not appear in code, with machine-readable YAML block consumed
   by hooks and the `config-validator` agent.
5. **[runtime-vs-config.md](./runtime-vs-config.md)**: `.claude/`
   holds committed configuration only; runtime artefacts live under
   `logs/`. Enforced by `claude-dir-write.sh` allow-list.
6. **[repo-hygiene.md](./repo-hygiene.md)**: where files belong in the
   repository layout, naming conventions, archival policy, "no loose
   `.md` at the repo root" rule.
7. **[plan-metadata.md](./plan-metadata.md)**: mandatory YAML
   frontmatter for every file under `docs/plans/` and
   `archive/plans/`.
8. **[doc-lifecycle.md](./doc-lifecycle.md)**: status-transition
   graph, move-on-close rule, archive-README requirement.
9. **[workflow.md](./workflow.md)**: the 8-step orchestrated session
   workflow and rules R1 to R11. Direct (non-orchestrated) work is
   exempt; the workflow applies to subagent-driven block sessions.
10. **[frontend-tooling.md](./frontend-tooling.md)**: optional Chrome
    DevTools MCP operational notes (WSL2 networking, Chrome launch
    flags) for projects that ship a web UI. Playwright is the default
    fallback.
11. **[block-discipline.md](./block-discipline.md)**: kill criteria
    (optional), draft-time preflight validation, post-close hygiene.
12. **[fix-discipline.md](./fix-discipline.md)**: fix the upstream
    cause, not N symptoms. Bans variable-extraction-as-fix and
    mechanical find-replace diffs that do not change runtime
    behaviour.
13. **[simplicity-discipline.md](./simplicity-discipline.md)**: the
    smallest correct change. Bans speculative abstraction, dead code
    left behind, and orthogonal churn; pairs naive-correct-first with
    optimize-preserving-correctness. Enforced at Gate 3b (code-reviewer)
    and prevented at the worker template.

## How these rules are enforced

- **Hooks** (`.claude/hooks/*.sh`) block tool calls at `PreToolUse`:
  - `commit-policy.sh`: Conventional-Commits enforcement, forbidden
    flags, AI-authorship trailers, non-ASCII subject rejection.
  - `forbidden-patterns-live.sh`: the YAML pattern block in
    `forbidden-patterns.md` against the diff of added lines.
  - `forbidden-patterns.sh`: same patterns at `git commit` time.
  - `claude-dir-write.sh`: `.claude/` allow-list per
    `runtime-vs-config.md`.
  - `plan-frontmatter.sh`: YAML frontmatter validation per
    `plan-metadata.md`.
  - `worker-worktree-jail.sh`: worker write boundary per
    `orchestrate-block.prompt.md` §6.2.
  - `session-hygiene-warn.sh` (SessionStart) and `session-reminders.sh`
    (UserPromptSubmit) surface state hints non-blockingly.
- **`config-validator` agent** runs at Gate 2 and scans for hardcoded
  values and forbidden patterns across the whole diff.
- **`criteria-checker` agent** runs at Gate 3a and verifies acceptance
  criteria against diff plus runtime evidence.
- **`code-reviewer` agent** runs at Gate 3b and checks design-principle
  compliance, repo-hygiene, block-discipline shape, and architectural
  violations.
- **CI** (whatever the project wires up: a preview build plus
  `<lint> && <typecheck>`, or equivalent for non-Node stacks) is the
  final gate before merge.

## If a rule here conflicts with another document

Order of precedence:

1. `.claude/rules/` (this directory). Canonical.
2. `docs/adr/`. Architecture Decision Records, binding once accepted.
3. `CLAUDE.md`. Orientation; if it contradicts a rule here, the rule
   wins.
4. `HANDOVER.md`. Running session state, not rules.

File a PR against the conflicting doc to resolve; do not silently work
around a rule.
