---
id: design-principles
title: Four Design Principles
created: 2026-05-15T00:00:00Z
updated: 2026-05-17T00:00:00Z
status: active
owner: founder
---

# Four Design Principles

Every line of code is reviewed against these. When in doubt, apply them.

## 1. Configuration over Code

Business logic (thresholds, mappings, agent prompts, signed-URL TTLs)
lives in config (typed constants in your project's config module, env
vars, or YAML alongside `docs/blocks/*/block.yaml`). If the urge to
hardcode a value strikes, make it configurable first.

## 2. Schema First

Define the interface (types on the client, request and response shapes
on the network boundary, structured outputs from agent dispatch) before
implementing. The output of each layer is the contract for the next
layer.

Shared types live in a shared module if used across domains; per-domain
types stay local. Changing a shared type affects every consumer;
coordinate first (see `workflow.md` R3).

## 3. Variable First

No threshold, no field name, no mapping is hardcoded. Everything flows
through config so a per-project tweak does not need a code change.
Hardcoded string literals in business logic are a config violation
(config-validator flags them at Gate 2).

## 4. Module Isolation

Domain subdirectories under `<source-root>/<subdir>/` are independent.
Cross-domain imports go only through each subdir's barrel
(`index.ts`, `__init__.py`, `mod.rs`, etc.). Direct imports between
feature subdirs are forbidden when the project's linter declares an
import-boundary DAG (for example `import/no-restricted-paths` in an
ESLint config). Aevum itself ships without such a DAG; add it
per-project, matched to the project's language and linter.

## Enforcement

- `config-validator` agent runs at Gate 2 to flag hardcoded business values.
- `code-reviewer` agent runs at Gate 3b to flag principle violations.
- Forbidden-pattern hook (`.claude/hooks/forbidden-patterns.sh`) blocks the
  most common offenders at `PreToolUse` for `git commit`.

## Forbidden patterns to alternatives

See `.claude/rules/forbidden-patterns.md` for the full table plus the YAML
block the hooks consume.
