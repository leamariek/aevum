---
id: swap-points
title: Stack Seams in Aevum
created: 2026-05-17T00:00:00Z
updated: 2026-05-17T00:00:00Z
status: active
owner: founder
---

# Stack seams in Aevum

Aevum is stack-agnostic at the orchestration layer; the wrapper,
inner-orchestrator, ledger, gate machinery, rule set, and
infrastructure agents do not depend on a specific language or
framework. This file lists the **stack-bound seams** the harness
exposes, where each lives, what its contract is, and how to swap
it for your language.

The single seam every adopter must touch is the **Gate 1 runner**.
Everything else has a sensible default; touch only if you need to.

## Seam 1: Gate 1 runner (required swap)

**Files:**

- `.claude/scripts/pnpm-locked-gate.sh` (the flock-protected shim
  the orchestrator calls).
- `scripts/quality-gate.py` (the actual lint / build / typecheck
  invocation the shim delegates to).

**Contract:**

- Exit code 0: Gate 1 passed.
- Exit code 1: Gate 1 failed.
- Exit code 2: setup error (e.g. linter not installed).
- Exit code 3: lock acquisition failed.
- The script writes `logs/gates/gate1.json` atomically before
  exit. Schema is documented in `scripts/quality-gate.py`'s
  docstring; key fields are `overall: "pass"|"fail"`,
  `gates: {name: {status, duration_s, error_count, ...}}`,
  `raw_outputs_dir: "logs/gates/raw/<UTC>/"`.
- Stdout and stderr from each individual check are persisted to
  `logs/gates/raw/<UTC>/<check>.{stdout,stderr}.txt` so the
  `fix-bucketer` agent can read complete logs.

**Default implementation:** Node / pnpm.

```python
CHECKS = {
    "lint": ["pnpm", "lint"],
    "build": ["pnpm", "build"],
    "typecheck": ["pnpm", "exec", "tsc", "--noEmit"],
}
```

**How to swap:**

1. Edit `scripts/quality-gate.py`. Replace the `CHECKS` dict with
   your stack's commands. Examples:

   - **Python (uv, ruff, mypy, pytest):**
     ```python
     CHECKS = {
         "lint":      ["ruff", "check", "."],
         "typecheck": ["mypy", "."],
         "test":      ["pytest", "-q"],
     }
     FAST_CHECKS = ["lint"]
     ```

   - **Rust (cargo, clippy):**
     ```python
     CHECKS = {
         "lint":  ["cargo", "clippy", "--", "-D", "warnings"],
         "build": ["cargo", "build"],
         "test":  ["cargo", "test"],
     }
     FAST_CHECKS = ["lint", "build"]
     ```

   - **Go (golangci-lint, go):**
     ```python
     CHECKS = {
         "lint":  ["golangci-lint", "run"],
         "build": ["go", "build", "./..."],
         "test":  ["go", "test", "./..."],
     }
     FAST_CHECKS = ["lint", "build"]
     ```

2. Remove the `pnpm`-on-PATH check at the top of
   `scripts/quality-gate.py`; replace with your toolchain's
   equivalent (`shutil.which("cargo")` etc.).

3. Edit `.claude/scripts/pnpm-locked-gate.sh`:

   - Rename to `gate1.sh` if you prefer (and update references in
     `.claude/scripts/orchestrate-block.prompt.md` §6.5,
     `scripts/capture-baseline.sh`, and
     `scripts/block-preflight.py`'s `REQUIRED_HARNESS_FILES`
     tuple).
   - Replace the `PATH="$REPO_ROOT/node_modules/.bin:$PATH"` line
     with your stack's binary-path setup if needed (e.g. activate
     a Python venv).
   - Update the lock filename `logs/locks/pnpm.lock` to
     `logs/locks/gate1.lock` (or leave; it is opaque to the
     orchestrator).

4. Edit `scripts/block-preflight.py`:

   - In `_probe_pnpm`, replace with `_probe_<your-toolchain>`.
   - In `_probe_node_modules`, replace with `_probe_<your-envdir>`
     (`.venv/`, `target/`, etc.).
   - In `REQUIRED_HARNESS_FILES`, swap `package.json` for your
     project's manifest (`pyproject.toml`, `Cargo.toml`, `go.mod`).

5. Edit `.claude/settings.json`:

   - Remove `Bash(pnpm:*)`, `Bash(node:*)`, `Bash(npx:*)` from the
     allow list.
   - Add your stack's tooling: `Bash(cargo:*)`, `Bash(uv:*)`,
     `Bash(ruff:*)`, etc.

## Seam 2: project manifest filename

**File:** `scripts/block-preflight.py` (`REQUIRED_HARNESS_FILES`
tuple).

**Contract:** the preflight check enumerates the load-bearing
harness files that must exist in the tree at `block.yaml`'s
`base_sha`. `package.json` is the Node default; replace with your
project's manifest filename.

**How to swap:** see Seam 1 step 4.

## Seam 3: settings.json allow list

**File:** `.claude/settings.json`.

**Contract:** the allow list defines which Bash commands the
harness lets through without per-call prompts. The deny list is
the safety net; everything not on the allow list and not denied
prompts the user.

**Default Node entries:** `Bash(pnpm:*)`, `Bash(node:*)`,
`Bash(npx:*)`.

**How to swap:**

- Remove Node entries if your project does not use Node.
- Add your stack's tooling: typical entries are
  `Bash(<your-package-manager>:*)`,
  `Bash(<your-build-tool>:*)`,
  `Bash(<your-test-runner>:*)`.
- Keep all the universal entries (git, ls, find, grep, jq, python3,
  etc.) and the entire deny list as shipped.

## Seam 4: commit-policy scope vocabulary

**File:** `.claude/rules/commit-policy.md` §Conventional Commits.

**Contract:** the scope vocabulary defines which scopes are valid
in commit subjects (`<type>(<scope>): <subject>`). Aevum reserves
four core scopes (`claude`, `scripts`, `docs`, `infra`); the
project declares its own scopes for product-code areas.

**How to swap:** edit `commit-policy.md` to list the project's
scopes alongside Aevum's. Example for a typical Node web app:
`api`, `web`, `core`, `db`, plus the Aevum core scopes.

## Seam 5: repo-hygiene layout

**File:** `.claude/rules/repo-hygiene.md`.

**Contract:** the directory layout the harness expects. The
`.claude/`, `scripts/`, `docs/blocks/`, and `logs/` directories
are Aevum-owned; everything else is project-owned.

**How to swap:** edit `repo-hygiene.md` to add a section
describing the project's source layout, naming conventions, and
which subdirectories are domain modules.

## Seam 6: forbidden-patterns YAML block

**File:** `.claude/rules/forbidden-patterns.md` §Machine-readable
block.

**Contract:** the YAML block declares regex patterns the live hook
and `config-validator` agent enforce. Aevum ships four universal
patterns (commit-trailer hygiene, hook-bypass refusal,
runtime-vs-config separation, common secret shapes).
Project-specific patterns (ts-any, scene-id literals, hot-path
threshold limits) belong in the **Project-specific patterns**
section.

**How to swap:** copy the desired commented-out examples from the
template section into the active `patterns:` block, or add new
patterns following the same shape.

## Seam 7: code-reviewer domain checklist

**File:** `.claude/agents/code-reviewer.md` §Domain hygiene
(project-specific).

**Contract:** Aevum ships a placeholder list of common
domain-hygiene checks (SDK error handling, secret hygiene,
hot-path discipline, stable-string discipline). Replace with the
project's actual checks; delete the entire section if the project
has no domain-specific checks to enforce.

## Seam 8: state.yaml schema extensions

**File:** `.claude/state.yaml`.

**Contract:** Aevum core uses `active_block`, `wave`, `blockers`,
`notes` plus arbitrary project-defined fields. The
`status-tracker` agent reads and writes these; it does not enforce
a schema.

**How to swap:** add project-specific fields freely. Common
additions: per-block status arrays, milestone tracking, on-call
rotation.

## Seam 9: branch-naming prefix

**File:** `.claude/rules/commit-policy.md` §Branch naming,
`.claude/scripts/orchestrate-block.sh` (branch creation logic),
`.claude/scripts/cleanup-stale-block.sh` (branch deletion glob).

**Contract:** Aevum prefixes orchestrated branches with `block/`.
This prefix is hardcoded in the orchestrator scripts as
`block/<BLOCK_ID>/<...>`.

**How to swap:** if your project uses a different convention,
edit the prefix in all three files. The orchestrator does not care
what the prefix is; it just uses the same one everywhere.

## What is NOT a seam

The following are stack-agnostic by design and should NOT be
swapped:

- Ledger format (`logs/blocks/<BLOCK>/progress.jsonl`). The schema
  is the orchestrator's contract; downstream readers depend on it.
- Gate verdict enum (`pass | fail | pending | delta_zero |
  delta_regression | APPROVED | CHANGES_REQUESTED`). The
  orchestrator routes on these.
- Stub-write-first contract for Gate 2 and Gate 3a agents. This
  is how the orchestrator detects fragmentation.
- Worktree isolation for parallel tasks. This is how parallel
  workers stay safe.
- Wedge-detector signals. The third signal (worker mtime) is
  load-bearing; do not remove.
- Never-push rule. Pushes are a human action, full stop.

If you find yourself wanting to swap one of these, please open an
issue first; you may be missing a design constraint and the
right answer is probably elsewhere.
