# Plan 001: Add CI workflow for app verification

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving to the next step. If anything in the "STOP conditions" section occurs, stop and report — do not improvise. When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 997c85f..HEAD -- .github/ package.json`
> If any in-scope file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `997c85f`, 2026-08-29

## Why this matters

Ledger Atlas has `npm test`, `npm run typecheck`, and `npm run lint` scripts but no `.github/workflows/` CI. Every change — including the 800+ agent skills layer — ships without automated verification of the Next.js app. A CI workflow on `main` and PRs establishes the verification baseline that every other plan in this batch depends on.

## Current state

- `package.json` scripts (verified):
  - `npm test` → vitest run (3 tests in `lib/ledger.test.ts`)
  - `npm run typecheck` → `tsc --noEmit`
  - `npm run lint` → `eslint .` (currently fails on `.agents/skills/` — see plan 002; CI should lint only `app` and `lib` until 002 lands, or depend on 002)
- No `.github/` directory exists at repo root.
- App source lives in `app/`, `lib/`; agent skills in `.agents/skills/` (excluded from `tsconfig.json`).

Repo commit style from `git log`: conventional commits (`feat:`, `Merge pull request`).

## Commands you will need

| Purpose   | Command                  | Expected on success |
|-----------|--------------------------|---------------------|
| Install   | `npm ci`                 | exit 0              |
| Typecheck | `npm run typecheck`      | exit 0, no errors   |
| Tests     | `npm test`               | 3 passed            |
| Lint app  | `npx eslint app lib`     | exit 0              |

## Scope

**In scope**:
- `.github/workflows/ci.yml` (create)

**Out of scope**:
- `.agents/skills/**` — third-party skill content; do not lint or test in CI for this plan
- Application feature changes
- `plans/` updates beyond README status row

## Git workflow

- Branch: `advisor/001-ci-workflow`
- Commit message: `ci: add GitHub Actions workflow for test, typecheck, and lint`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create CI workflow

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "22"
          cache: npm
      - run: npm ci
      - run: npm run typecheck
      - run: npm test
      - run: npx eslint app lib
```

**Verify**: `test -f .github/workflows/ci.yml && grep -q "eslint app lib" .github/workflows/ci.yml` → prints match

### Step 2: Local dry-run

Run the same commands locally:

```bash
npm ci && npm run typecheck && npm test && npx eslint app lib
```

**Verify**: all commands exit 0

## Test plan

No new unit tests. CI itself is the verification gate.

## Done criteria

- [ ] `.github/workflows/ci.yml` exists and runs `npm ci`, `typecheck`, `test`, `eslint app lib`
- [ ] Local dry-run of all four commands exits 0
- [ ] No files outside scope modified
- [ ] `plans/README.md` status row for 001 updated to DONE

## STOP conditions

- `npm ci` fails due to lockfile drift — report, do not modify `package-lock.json` unless explicitly instructed.
- `npx eslint app lib` fails on `app/` or `lib/` code — report the errors; do not fix app code in this plan.

## Maintenance notes

- When plan 002 lands, optionally switch CI to `npm run lint` if the root eslint config ignores `.agents/`.
- Add `npm run build` to CI once build time is acceptable (not in this plan).
