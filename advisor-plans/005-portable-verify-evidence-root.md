# Plan 005: Make `verify.sh` portable and use the locked interpreter

> **Executor instructions**: Follow step by step. Update
> `advisor-plans/README.md` when done.
>
> **Drift check**: `scripts/verify.sh` SHA-256 prefix `e5aaf09388964ea0`.
> STOP if the script no longer hardcodes `EVIDENCE_ROOT` or already uses only
> `.venv/bin/python`.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: MED
- **Depends on**: none
- **Category**: dx
- **Planned at**: unborn HEAD, 2026-08-18

## Why this matters

`scripts/verify.sh` sets `EVIDENCE_ROOT=/Users/prax/Developer/money-manager-reverse-engineering`.
Any clone or CI without that exact sibling path fails the product gate before
Swift runs. The same script requires `.venv/bin/python` to exist, then still
invokes PATH `python3` for protected-input checks and `orchestrion.py`.
`EVIDENCE.md` already names that research root as the canonical path; the
gate should honor an override and skip/fail clearly when the tree is absent.

Do **not** weaken protected-input checks when the evidence repo **is**
present. Do **not** rewrite `gate-commit.sh` / hooks in this plan (AGENTS.md:
do not change the controls that govern a gated run in the same atom).

## Current state

`scripts/verify.sh:10-27`:

```sh
REPO_ROOT=$(git rev-parse --show-toplevel)
EVIDENCE_ROOT=/Users/prax/Developer/money-manager-reverse-engineering
...
python3 scripts/check-protected-inputs.py
(
  cd "$EVIDENCE_ROOT"
  python3 scripts/check-protected-inputs.py
)
...
python3 scripts/orchestrion.py validate
```

`EVIDENCE.md` documents the same absolute research root.

`tests/orchestration/test_harness.py` is the pattern for Python tests; add a
small test that `verify.sh` is parseable / documents the env var, or a unit
test of a tiny extracted resolver if you extract one. Prefer not to run the
full Swift suite inside a pytest.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Syntax | `sh -n scripts/verify.sh` | exit 0 |
| Orchestration tests | `.venv/bin/python -m pytest tests/orchestration` | exit 0 |
| Fast (this machine) | `./scripts/verify.sh --fast` | verification passed |

## Scope

**In scope**:
- `scripts/verify.sh`
- `EVIDENCE.md` (one paragraph on `LEDGER_ATLAS_EVIDENCE_ROOT`)
- `tests/orchestration/test_harness.py` only if you add a resolver unit test
  without pulling Swift

**Out of scope**:
- `scripts/gate-commit.sh`, `.githooks/`, `scripts/orchestrion.py` policy
- Dropping protected-input verification when the evidence tree exists
- MongoDB, CI vendor lock-in

## Git workflow

No commit unless the gate is armed.

## Steps

### Step 1: Resolve evidence root

```sh
EVIDENCE_ROOT=${LEDGER_ATLAS_EVIDENCE_ROOT:-/Users/prax/Developer/money-manager-reverse-engineering}
```

If the directory is missing or lacks
`.orchestrion/protected-inputs.sha256`:

- print a one-line skip (`evidence tree absent; skipped sibling protected-input check`)
- do **not** `cd` into it
- continue the rest of the gate

If it exists, run
`.venv/bin/python scripts/check-protected-inputs.py` from that directory
(after `cd`).

### Step 2: Locked interpreter

After the existing “locked environment missing” check, replace remaining
`python3` invocations in `verify.sh` with `.venv/bin/python`.

### Step 3: Document

Add to `EVIDENCE.md` that `LEDGER_ATLAS_EVIDENCE_ROOT` overrides the default
path and that originals remain read-only.

**Verify**: `sh -n scripts/verify.sh`; `./scripts/verify.sh --fast` still
passes on this machine (default path exists). Optionally:
`LEDGER_ATLAS_EVIDENCE_ROOT=/nonexistent ./scripts/verify.sh --fast` still
reaches Swift (do not claim this if Swift time is too high — then run only
through the evidence-check portion by extracting a function; if you cannot
extract without a large refactor, STOP after documenting the skip branch
and rely on `sh -n` plus a dry comment test).

## Test plan

If you add Python: a tiny function
`resolve_evidence_root(env, default)` in a script module already imported by
tests, with cases override / default / missing. Do not invent a new
lifecycle owner.

## Done criteria

- [ ] No hardcoded-only evidence path (override env exists)
- [ ] Missing evidence tree does not `cd` fail
- [ ] `verify.sh` uses `.venv/bin/python` for its Python steps
- [ ] `./scripts/verify.sh --fast` exits 0 here
- [ ] `gate-commit.sh` untouched

## STOP conditions

- Making the skip also skip **product** `check-protected-inputs.py`.
- You feel you must edit the hook or gate to finish.

## Maintenance notes

CI images should set `LEDGER_ATLAS_EVIDENCE_ROOT` or omit the sibling repo
deliberately. Reviewers: confirm originals are still hashed when present.
