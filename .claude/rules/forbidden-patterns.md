---
id: forbidden-patterns
title: Forbidden Patterns
created: 2026-05-15T00:00:00Z
updated: 2026-05-17T00:00:00Z
status: active
owner: founder
---

# Forbidden Patterns

Patterns that must not appear in production code, each with its
approved replacement. The YAML block below is consumed by the
`forbidden-patterns-live.sh` hook and referenced by the
`config-validator` agent. **Edit the YAML, do not duplicate**.

Aevum ships with a small set of universal patterns (commit-trailer
hygiene, hook-bypass refusal, runtime-vs-config separation, common
secret shapes). Project-specific patterns (stack-bound type hygiene,
domain-bound thresholds, scene-id literals) belong in the
**Project-specific patterns** section at the bottom; add yours there
or in a sibling rule that the hook also reads.

## Table

| Instead of | Do | Why |
|---|---|---|
| Plaintext API keys or secrets in source | `.env*` (gitignored); read via host language's env primitive | Security |
| Writes into `.claude/` outside the allow-list | Use `logs/` for runtime artefacts | Runtime-vs-config |
| `Co-Authored-By: Claude` or "Generated with Claude Code" trailer | Plain Conventional Commit, no trailer | Commit policy |
| Skipping hooks with the bypass flag | Fix the underlying issue | Commit policy |
| Hardcoded thresholds in code | Read from config or env | Variable First |
| Direct push to `main` | Worker branch then cluster then integration then fast-forward to `main` | Commit policy |
| Em-dash (U+2014) in commit subjects or bodies | Periods, semicolons, commas, parens, or rephrase | Commit policy |

## Machine-readable block (hook-consumed)

```yaml
# forbidden-patterns-live.sh and config-validator both read this block.
# `severity: critical` blocks the tool call; `severity: warning` only warns.
# `paths` are glob patterns against the file path; omit means applies everywhere.
# `exclude` overrides `paths`. Test files (*.test.*, test_*.py) are global-exempt.
patterns:
  - id: plaintext-secrets-suspicious
    regex: '\b(sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|xi-[a-f0-9]{32,}|gh[ps]_[A-Za-z0-9]{36,}|AKIA[0-9A-Z]{16})\b'
    severity: critical
    paths: ['**']
    exclude:
      - '.env.example'
      - '.env.local.example'
      - '.claude/rules/**'
      - 'docs/**'
      - 'examples/**'
      - 'archive/**'
      - '**/*.test.*'
      - '**/tests/**'
    hint: "Secrets belong in .env.local (gitignored), never inline. The regex matches Anthropic, OpenAI, ElevenLabs, GitHub, and AWS key shapes; extend per project."

  - id: ai-authorship-trailer
    regex: '(?i)(co-authored-by:\s*claude|generated with \[?claude code)'
    severity: critical
    paths: ['**']
    exclude:
      - '.claude/rules/**'
      - '.claude/hooks/**'
      - '.claude/templates/**'
      - '.claude/agents/**'
      - '.claude/scripts/**'
      - 'docs/plans/**'
      - 'examples/**'
      - 'archive/**'
    hint: "AI authorship trailers are forbidden (see commit-policy.md)."

  - id: no-verify-flag
    regex: '-{2}no-verify'
    severity: critical
    paths: ['**']
    exclude:
      - '.claude/rules/**'
      - '.claude/hooks/**'
      - '.claude/agents/**'
      - '.claude/scripts/**'
      - 'docs/**'
      - 'examples/**'
      - 'archive/**'
    hint: "Never bypass hooks; fix the underlying issue."

  - id: runtime-under-claude
    regex: '\.claude/(gate[0-9a-b]*\.json|metrics\.json|gap-report\.json|phase-[^/]+\.json|gate1-raw/|blocks/|locks/|gate1\.lock)'
    severity: critical
    paths: ['**']
    exclude:
      - '.claude/rules/**'
      - '.claude/hooks/**'
      - 'archive/**'
      - 'docs/**'
      - 'examples/**'
      - '**/*.test.*'
      - '**/tests/**'
      - 'logs/**'
    hint: "Runtime artefacts live under logs/, not .claude/. See .claude/rules/runtime-vs-config.md."
```

The `no-verify-flag` regex uses `-{2}` instead of the literal `--`
so this file's own content does not trigger the live-hook scan on
edits to forbidden-patterns.md itself. The match is semantically
identical: both forms match the bypass flag in incoming diffs.

The exclusion of test files is applied by the hook itself, not in the
regex, so authors can read the regex without the path noise. Add new
patterns by appending to the `patterns:` list above; no code changes
needed.

## Project-specific patterns (template)

The patterns below are **commented-out examples** of project-specific
rules an Aevum consumer might adopt. They are not enforced as shipped.
Copy the ones that apply to your stack into the `patterns:` block
above, or maintain them in a project-side rule file the hook also
reads.

```yaml
# - id: ts-any
#   regex: ':\s*any(\b|\[)'
#   severity: critical
#   paths: ['src/**/*.ts', 'src/**/*.tsx']
#   exclude: ['**/*.test.ts', '**/*.test.tsx', '**/*.spec.ts']
#   hint: "Define a concrete type or use `unknown` plus narrow."
#
# - id: hardcoded-thresholds-in-domain
#   regex: '\b(latency|timeout|retry|delay|interval)\s*[:=]\s*\d{3,}\b'
#   severity: warning
#   paths: ['src/<your-domain>/**/*.ts']
#   exclude: ['**/*.test.ts', '**/*.test.tsx', '**/*.spec.ts']
#   hint: "Thresholds belong in the project's config module, not inline."
#
# - id: hardcoded-scene-id
#   regex: '\b(SUITE|GARDENS|POOL|BAR)\b'
#   severity: warning
#   paths: ['src/**/*.ts', 'src/**/*.tsx']
#   exclude: ['src/core/store.ts', 'src/core/types.ts']
#   hint: "Scene-name literals belong in the typed enum in src/core/store.ts."
```

## Notes on omitted patterns

- Stack-specific type hygiene (e.g. forbidding `any` in TypeScript):
  project-specific; ship in the template section above and adopt per
  project.
- Domain-bound thresholds (latency, timeouts, retries inside a
  specific subdirectory): project-specific; adopt as the project
  declares its hot-path domain.
- Locale-specific rules (umlaut substitution, regional cloud domains):
  not in Aevum core.
- The em-dash rule is enforced inside `commit-policy.sh` directly
  (strict ASCII subject check) rather than as a YAML pattern. The rule
  applies to commit subjects AND bodies; the hook is the authoritative
  gate.
