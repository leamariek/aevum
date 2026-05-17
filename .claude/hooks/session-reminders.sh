#!/usr/bin/env bash
# session-reminders.sh, UserPromptSubmit hook. Emits a two-line reminder
# about language policy and plan frontmatter. Never blocks.
cat <<'EOF' 1>&2
[reminder] all code, commits, and prose in English by default (see .claude/rules/language-policy.md).
[reminder] plans under docs/ and archive/plans/ require YAML frontmatter, see .claude/rules/plan-metadata.md.
EOF
exit 0
