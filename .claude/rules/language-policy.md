---
id: language-policy
title: Language Policy
created: 2026-05-13T00:00:00Z
updated: 2026-05-17T00:00:00Z
status: active
owner: founder
---

# Language Policy

**English everywhere by default.** One sentence, one rule. Projects
that need a different working language flip this rule at adoption time
and update the references below accordingly.

## Where English is mandatory

- Source code: identifiers, comments, docstrings, type hints, log
  messages.
- Commit messages, PR titles, PR descriptions, branch names.
- All documentation under `docs/`, `.claude/rules/`, `archive/`.
- File names (kebab-case or snake_case per the project's convention).
- Error messages emitted by network routes and any CLI scripts.
- Configuration keys in YAML.

## Future locales

If a project iteration adds localisation it follows BCP-47 tags
(`en-GB`, `de-DE`, etc.) under a per-project i18n directory. That work
is out-of-scope for the harness itself.

## Number, date, currency formatting

Use the host language's localisation primitives for any user-facing
number, date, or currency string (for example `Intl.NumberFormat` in
JavaScript, `babel.numbers` in Python, the ICU library bindings in Go).
Never format by string concatenation. Localisation helpers belong in a
shared module if used across domains.

## Rationale for Claude and contributors

When replying in chat, writing PR summaries, or drafting documentation,
respond in English. Inline non-English examples in docs are fine when
explaining a foreign-language string; prose around them stays English.
