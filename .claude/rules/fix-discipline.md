---
id: fix-discipline
title: Fix Discipline
created: 2026-05-15T00:00:00Z
updated: 2026-05-17T00:00:00Z
status: active
owner: founder
---

# Fix Discipline

A change must solve a problem at its source. Painting over the symptom
at N call sites is not a fix; it is a diff that compiles, reviews
cleanly at a glance, and changes nothing that matters.

This rule exists because a real session proposed exactly this:

```python
# BANNED: variable-extraction-as-fix
TURBO = shutil.which("turbo") or str(repo_root / "node_modules" / ".bin" / "turbo")
CHECKS = {
    "build":     [TURBO, "build"],
    "test":      [TURBO, "test"],
    "lint":      [TURBO, "lint"],
    "typecheck": [TURBO, "typecheck"],
}
```

Four mechanical edits, one shared variable, zero change to the upstream
cause: `PATH` does not contain `node_modules/.bin`. The correct fix was
one line in the wrapper that owns the environment:

```bash
# in the wrapper that calls the Python gate:
export PATH="$REPO_ROOT/node_modules/.bin:$PATH"
```

## Rules

1. **Fix upstream, not at every call site.** If a bug manifests in N
   places, there is almost always one upstream cause (a bad PATH, a
   missing init, a stale cache, a caller that forgot a guarantee).
   Patch the cause; the symptoms disappear for free.

2. **Variable extraction is not a fix.** Replacing a literal with a
   name holding the same literal, across multiple call sites, changes
   zero runtime behavior. The literal still resolves the same way. If
   the value needs to be computed, compute it at the boundary where
   the invariant fails, not at each consumer.

3. **Separation of concerns.** Each file or layer owns one job. Do not
   add environment logic to a script whose caller is already responsible
   for the environment. Do not add validation to a consumer whose
   caller was supposed to validate.

4. **Loud failure at boundaries.** If an invariant is supposed to hold
   on entry, assert it once, at entry, and fail loudly if it does not.
   Do not compensate for its absence at every use downstream; that
   hides the real bug and multiplies the surface area of the fix.

## The three-edit test

Before proposing a diff, count how many identical or near-identical
edits it contains. If three or more lines look like the same
find-and-replace, stop. Ask:

- Where did this literal, value, or behavior originate?
- Why is it wrong at each of these N sites?
- Is there one place upstream where a single change makes all N sites
  correct?

Answer those, then rewrite the diff. A one-line upstream fix beats
N-line downstream patches every time.

## What this is not

Not every repetitive edit is a symptom patch. Renaming a deprecated
API across call sites is legitimate. Propagating a schema change
through consumers is legitimate. What is banned is the case where
**the same substitution done N times does not itself solve the
reported problem**; it only looks like a solution because every row
now mentions a different symbol.

## Enforcement

- **Self-check before each diff.** Apply the three-edit test. If a
  proposed change fails, redesign before implementing.
- **Plan review.** If a plan phase describes its scope as "change X
  to Y in N places" and does not identify a single upstream cause,
  reject the phase and ask for the upstream version.
- **Gate 3b.** `fap-reviewer` flags diffs with three or more
  mechanical-looking edits as `fix-discipline` findings. This is a
  judgment call, not a regex rule; the reviewer asks "does this
  actually fix the reported symptom, or only move it?".

## Related

- `design-principles.md` for the architectural principles; this file
  is about reasoning discipline, not architecture.
- `forbidden-patterns.md` for regex-detectable anti-patterns; the
  pattern this file bans is not regex-detectable because it lives in
  the relationship between a diff and the bug it claims to fix.
