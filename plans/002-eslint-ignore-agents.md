# Plan 002: Exclude agent skills from ESLint scope

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving to the next step. If anything in the "STOP conditions" section occurs, stop and report — do not improvise. When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 997c85f..HEAD -- eslint.config.mjs`
> If any in-scope file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `997c85f`, 2026-08-29

## Why this matters

`npm run lint` runs `eslint .` and scans `.agents/skills/` (800+ third-party skill files), producing thousands of errors unrelated to the Ledger app. Developers and CI cannot use lint as a gate. `tsconfig.json` already excludes `.agents`; ESLint should match.

## Current state

`eslint.config.mjs` (lines 12–17):

```javascript
const eslintConfig = [
  {
    ignores: ["next-env.d.ts", ".next/**"],
  },
  ...compat.extends("next/core-web-vitals", "next/typescript"),
];
```

`tsconfig.json` excludes: `"node_modules", "vendor", ".agents"`.

Running `npm run lint` today exits 1 with errors only under `.agents/skills/`.
Running `npx eslint app lib` exits 0.

## Commands you will need

| Purpose   | Command              | Expected on success |
|-----------|----------------------|---------------------|
| Lint all  | `npm run lint`       | exit 0              |
| Lint app  | `npx eslint app lib` | exit 0              |

## Scope

**In scope**:
- `eslint.config.mjs`

**Out of scope**:
- Any file under `.agents/skills/`
- `app/`, `lib/` source changes
- CI workflow (plan 001 may use `npx eslint app lib` until this lands)

## Git workflow

- Branch: `advisor/002-eslint-ignore-agents`
- Commit message: `chore: exclude .agents from ESLint scope`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add ignore pattern

In `eslint.config.mjs`, update the `ignores` array to:

```javascript
ignores: ["next-env.d.ts", ".next/**", ".agents/**"],
```

Match the `tsconfig.json` convention of excluding `.agents`.

**Verify**: `grep -q '.agents/\*\*' eslint.config.mjs` → match found

### Step 2: Verify lint passes

```bash
npm run lint
```

**Verify**: exit 0

```bash
npx eslint app lib
```

**Verify**: exit 0

## Test plan

No new tests. Lint exit code is the gate.

## Done criteria

- [ ] `eslint.config.mjs` ignores `.agents/**`
- [ ] `npm run lint` exits 0
- [ ] `npx eslint app lib` still exits 0
- [ ] `plans/README.md` status row for 002 updated to DONE

## STOP conditions

- `npm run lint` still reports errors under `app/` or `lib/` — stop and report; those are pre-existing app issues outside this plan's scope.
- `eslint.config.mjs` structure differs from excerpt — stop and reconcile.

## Maintenance notes

- If plan 001 CI uses `npx eslint app lib`, update CI to `npm run lint` after this plan merges.
- Do not remove `.agents` from `tsconfig.json` exclude — skills are intentionally out of app typecheck scope.
