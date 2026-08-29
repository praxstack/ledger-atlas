# Plan 004: Fix ledger read-modify-write race

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving to the next step. If anything in the "STOP conditions" section occurs, stop and report — do not improvise. When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 997c85f..HEAD -- lib/ledger.ts lib/ledger.test.ts`
> If any in-scope file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/003-ledger-persistence-tests.md
- **Category**: bug
- **Planned at**: commit `997c85f`, 2026-08-29

## Why this matters

`addTransaction` performs an unguarded read-modify-write on `data/transactions.json`. Concurrent POST requests can interleave: both read the same snapshot, both write, and one transaction is lost. For a ledger app this is a correctness bug on the critical path.

## Current state

`lib/ledger.ts` `addTransaction` (lines 60–68):

```typescript
export async function addTransaction(
  description: string,
  amount: number,
): Promise<Transaction> {
  const ledger = await readLedger();
  const transaction = createTransaction(description, amount);
  ledger.transactions.unshift(transaction);
  await writeLedger(ledger);
  return transaction;
}
```

No file locking, no atomic rename, no queue. Node single-threaded event loop does not prevent interleaving across concurrent `await readLedger()` calls from parallel HTTP requests.

Plan 003 should add persistence tests including a concurrency characterization test (may fail before fix — that's expected).

## Commands you will need

| Purpose   | Command             | Expected on success |
|-----------|---------------------|---------------------|
| Tests     | `npm test`          | all pass            |
| Typecheck | `npm run typecheck` | exit 0              |

## Scope

**In scope**:
- `lib/ledger.ts`
- `lib/ledger.test.ts` (add concurrency test)

**Out of scope**:
- Database migration
- API route changes
- Full storage adapter refactor (architecture deepening — separate)

## Git workflow

- Branch: `advisor/004-ledger-concurrency-fix`
- Commit message: `fix: serialize ledger writes to prevent lost transactions`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add write serialization

Implement a module-level write mutex (promise chain) in `lib/ledger.ts`:

```typescript
let writeLock: Promise<void> = Promise.resolve();

async function withWriteLock<T>(fn: () => Promise<T>): Promise<T> {
  const run = writeLock.then(fn);
  writeLock = run.then(() => undefined, () => undefined);
  return run;
}
```

Wrap `addTransaction` body in `withWriteLock(async () => { ... })`.

Alternatively use `proper-lockfile` or atomic write-via-temp-rename — mutex is sufficient for single-process Next.js deployment and has no new dependency.

**Verify**: `grep -q withWriteLock lib/ledger.ts` → found

### Step 2: Add concurrency test

In `lib/ledger.test.ts`, with isolated temp data dir (from plan 003):

```typescript
it("preserves all transactions under concurrent adds", async () => {
  const results = await Promise.all([
    addTransaction("A", 10),
    addTransaction("B", 20),
    addTransaction("C", -5),
  ]);
  const ledger = await readLedger();
  expect(ledger.transactions).toHaveLength(3);
  expect(new Set(ledger.transactions.map((t) => t.id))).toEqual(
    new Set(results.map((t) => t.id)),
  );
});
```

**Verify**: `npm test` → all pass including concurrency test

### Step 3: Typecheck

```bash
npm run typecheck
```

**Verify**: exit 0

## Test plan

- Concurrency test from Step 2
- All plan 003 persistence tests must still pass
- Verification: `npm test` → all pass

## Done criteria

- [ ] `addTransaction` serializes writes (mutex or equivalent)
- [ ] Concurrent add test passes
- [ ] `npm test` and `npm run typecheck` exit 0
- [ ] `plans/README.md` status row for 004 updated to DONE

## STOP conditions

- Plan 003 tests do not exist — complete plan 003 first.
- Mutex approach causes deadlock in test suite — stop and report.
- Production `lib/ledger.ts` already has locking — reconcile and skip if equivalent.

## Maintenance notes

- Mutex protects single-process deployments only. Multi-instance deployment needs external store or distributed lock — note in code comment.
- Architecture deepening (storage adapter) should preserve the write-lock at the adapter seam.
