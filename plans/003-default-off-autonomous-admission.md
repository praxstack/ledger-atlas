# Plan 003: Repair default-off autonomous admission

> This is a separately supervised P0 governance atom. It may improve candidate
> controls, but it may not arm itself, stage, commit, trust hooks, or launch an
> unattended loop. Independent review is mandatory before later admission.

## Status

- Priority: P0
- Effort: M
- Risk: HIGH
- Depends on: none
- Category: security / tooling / tests
- Planned at: unborn `HEAD`, 2026-08-10
- Baseline manifest: `ef8d8a66c8b86d9c411aa0df34bf0c3a95d3905f701780e8a8e53608f5fe4ce2`

## Why this matters

The default-off runner correctly refuses an unborn/dirty repository, but the
commit seam trusts an enabled state after finite ceilings expire, does not bind
staged paths to the active PRD atom, accepts a caller-selected criterion, and
classifies the Swift source root incorrectly for P0 review. Read-only admission
diagnostics also hit coarse lexical denials. A green fast gate does not make
those authority boundaries safe.

## Frozen acceptance criterion

Read-only admission diagnostics remain usable while mutation denials stay
fail-closed; commit authority expires at every declared ceiling and kill switch;
the gate binds the active PRD atom, dependencies, exact owned paths, frozen
criterion/hash, and P0 flag; every P0 atom receives reviewer and red-team lenses;
runtime or caller input cannot broaden authority.

## Scope

Only the existing files with these exact filenames may change:

- `orchestrion.py` under the project hook directory
- `orchestrion.py` under the command directory
- `gate_commit.py`
- `test_harness.py`
- `RUNBOOK.md`
- `prd.json`

Out of scope: product source/tests, protected evidence, provider credentials,
hook trust state, baseline creation, unattended launch, and integration.

## Required red tests

- expired time, exhausted iteration/no-progress, kill switch, future clock, and
  disabled/replayed authority all deny at the commit seam;
- staged paths outside the active atom contract deny;
- review uses the frozen PRD criterion rather than a caller path;
- PRD `p0` drives two lenses and Swift source changes are conservatively P0;
- dependency-not-ready atoms cannot arm;
- read-only validation and hook-path queries are allowed while mutations deny;
- malformed booleans, unsafe prefixes, symlinks, and path aliases fail closed.

## Implementation rules

1. Centralize one validated frozen atom/authority contract; do not duplicate
   partially different checks between runner, gate, and hook.
2. Recheck authority, kill switch, staged tree, criterion hash, and hook setting
   immediately before the commit subprocess, not only before verification.
3. Derive ownership and P0 from the validated PRD; path classification is only a
   conservative escalation.
4. Parse read-only versus mutating operations structurally instead of raw
   substring matching.
5. Keep the runner default-off and preserve all existing bypass, integration,
   destructive-operation, protected-input, and test-deletion denials.

## Verification

- The focused governance test module exits zero with the new denial matrix.
- The repository fast and full gates exit zero.
- A temporary synthetic repository denies expired, unowned, wrong-criterion,
  non-P0-lens, and forged-state cases.
- This atom performs no real trust, authority, commit, provider, or external
  action.

## STOP conditions

- Correctness needs changing attestation architecture outside declared files;
  split a new atom rather than expanding silently.
- An allow rule broadens mutation capability merely to make diagnostics pass.
- A passing test requires real hook trust, a real commit, or provider/network
  access.

## Post-implementation admission still required

After candidate review is green, a human still establishes a reviewed baseline,
reviews and trusts exact hook hashes, runs the deliberate-red lifecycle, proves a
flawed candidate is rejected, and completes one separate synthetic gated atom.
Until then unattended execution remains not admitted.
