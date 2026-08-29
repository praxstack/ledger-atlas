# Plan 003: Add ledger persistence integration tests

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving to the next step. If anything in the "STOP conditions" section occurs, stop and report — do not improvise. When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 997c85f..HEAD -- lib/ledger.ts lib/ledger.test.ts vitest.config.ts`
> If any in-scope file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `997c85f`, 2026-08-29

## Why this matters

`lib/ledger.test.ts` only tests pure functions (`calculateBalance`, `createTransaction`). The persistence path (`readLedger`, `writeLedger`, `addTransaction`) — the code that mutates `data/transactions.json` — has zero coverage. Plans 004 (race fix) and 005 (API tests) need characterization tests here first so regressions are caught.

## Current state

`lib/ledger.ts` persistence constants (lines 15–16):

```typescript
const DATA_DIR = path.join(process.cwd(), "data");
const DATA_FILE = path.join(DATA_DIR, "transactions.json");
```

`addTransaction` (lines 60–68) does read-modify-write:

```typescript
export async function addTransaction(description: string, amount: number): Promise<Transaction> {
  const ledger = await readLedger();
  const transaction = createTransaction(description, amount);
  ledger.transactions.unshift(transaction);
  await writeLedger(ledger);
  return transaction;
}
```

`readLedger` swallows all errors and returns `{ transactions: [] }` (lines 18–28).

`vitest.config.ts` excludes `.agents/**` from tests.

Existing test pattern in `lib/ledger.test.ts`: vitest `describe`/`it`/`expect`, direct imports from `./ledger`.

## Commands you will need

| Purpose   | Command                  | Expected on success |
|-----------|--------------------------|---------------------|
| Tests     | `npm test`               | all pass            |
| Typecheck | `npm run typecheck`      | exit 0              |

## Scope

**In scope**:
- `lib/ledger.test.ts` (extend)
- Optionally `lib/ledger.ts` — **only** if you need to export `DATA_FILE` for test isolation via env override; prefer testing through public API with temp directory instead

**Out of scope**:
- Changing persistence implementation (plan 004)
- API route tests (plan 005)
- Refactoring to storage adapter (architecture candidate — separate work)

## Git workflow

- Branch: `advisor/003-ledger-persistence-tests`
- Commit message: `test: add integration tests for ledger persistence`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Isolate test data directory

In `lib/ledger.test.ts`, use `beforeEach`/`afterEach` with a unique temp directory under `os.tmpdir()` or `data/test-<uuid>/`. The cleanest approach without modifying production code:

Use `vi.stubEnv` or monkey-patch is **not** ideal. Instead, add a minimal test-only seam:

**Preferred approach (requires small production change):** Add optional env override at top of `ledger.ts`:

```typescript
const DATA_DIR = process.env.LEDGER_DATA_DIR
  ? path.resolve(process.env.LEDGER_DATA_DIR)
  : path.join(process.cwd(), "data");
```

This is a one-line seam for tests. Document in comment: "Override for tests only."

In tests, set `process.env.LEDGER_DATA_DIR` to a fresh temp dir per test.

**Verify**: `grep -q LEDGER_DATA_DIR lib/ledger.ts` → found (if production change made)

### Step 2: Write persistence tests

Add tests to `lib/ledger.test.ts`:

1. **readLedger returns empty when file missing** — temp dir with no file → `{ transactions: [] }`
2. **writeLedger + readLedger round-trip** — write two transactions, read back, assert equality
3. **addTransaction appends and persists** — call `addTransaction`, then `readLedger`, assert transaction present and balance correct via `calculateBalance`
4. **addTransaction rejects invalid input** — empty description throws, nothing written to disk

Use `fs.rm(tempDir, { recursive: true, force: true })` in `afterEach`.

**Verify**: `npm test` → at least 7 tests pass (3 existing + 4 new)

### Step 3: Typecheck

```bash
npm run typecheck
```

**Verify**: exit 0

## Test plan

- New cases listed in Step 2, in `lib/ledger.test.ts`
- Model after existing `describe("ledger")` block structure
- Verification: `npm test` → all pass

## Done criteria

- [ ] `npm test` exits 0 with ≥7 tests
- [ ] Tests cover `readLedger`, `writeLedger`, `addTransaction` against real filesystem in isolated temp dirs
- [ ] `npm run typecheck` exits 0
- [ ] No modifications under `.agents/`
- [ ] `plans/README.md` status row for 003 updated to DONE

## STOP conditions

- Adding `LEDGER_DATA_DIR` env override is rejected by reviewer — stop and report; alternative is dependency injection refactor (larger scope).
- Tests write to production `data/transactions.json` — STOP immediately; fix isolation before continuing.
- `lib/ledger.ts` API changed since plan written — reconcile excerpts.

## Maintenance notes

- These tests become the safety net for plan 004's concurrency fix.
- If architecture deepening adds a storage adapter, migrate tests to use in-memory adapter while keeping one file-backed integration test.
