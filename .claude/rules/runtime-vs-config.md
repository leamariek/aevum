---
id: runtime-vs-config
title: Runtime vs. Config
created: 2026-05-15T00:00:00Z
updated: 2026-05-17T00:00:00Z
status: active
owner: founder
---

# Runtime vs. Config

`.claude/` holds **committed configuration only**. Runtime artefacts
(gate JSONs, metrics, gap reports, per-block ledgers, locks) live under
`logs/`.

## Allow-list under `.claude/`

**Directories:** `rules/`, `agents/`, `hooks/`, `scripts/`, `skills/`,
`templates/`, `prompts/`, `commands/`, `worktrees/` (harness-owned).

**Files:** `settings.json`, `settings.local.json`, `state.yaml`,
`scheduled_tasks.lock` (harness-owned), `mcp.json`, `.gitignore`,
`CLAUDE.md` (if present).

Any Write/Edit to a path under `.claude/` that is **not** on this
allow-list is rejected at `PreToolUse` by
`.claude/hooks/claude-dir-write.sh`.

## Why allow-list, not block-list

Block-lists rot. Every new runtime artefact invented by a future agent
(say `.claude/new-thing.json`) sneaks past a block-list until someone
notices. An allow-list fails closed: unknown paths under `.claude/` are
rejected until an operator explicitly adds them.

## Where runtime goes

| Artefact | Path |
|---|---|
| Gate reports (phase) | `logs/gates/gate{1,2,3a,3b}.json` |
| Gate reports (block delta) | `logs/gates/gate1-delta.json` |
| Raw gate stdout/stderr | `logs/gates/raw/<UTC>/` |
| Metrics snapshot | `logs/metrics.json` |
| Gap report | `logs/gap-report.json` |
| Per-block ledger | `logs/blocks/<BLOCK>/progress.jsonl` |
| Per-phase progress | `logs/phase-<N>/progress.jsonl` |
| Orchestrator locks | `logs/locks/*.lock` |
| Turbo lock | `logs/locks/turbo.lock` |

## Enforcement

`.claude/hooks/claude-dir-write.sh` at `PreToolUse` for `Write|Edit`.
`config-validator` at Gate 2 scans the diff for forbidden paths
(`runtime-under-claude` rule in `forbidden-patterns.md`).
