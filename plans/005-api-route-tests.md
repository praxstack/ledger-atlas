# Plan 005: Add API route tests for transactions

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving to the next step. If anything in the "STOP conditions" section occurs, stop and report — do not improvise. When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 997c85f..HEAD -- app/api/transactions/route.ts lib/ledger.test.ts vitest.config.ts`
> If any in-scope file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/003-ledger-persistence-tests.md
- **Category**: tests
- **Planned at**: commit `997c85f`, 2026-08-29

## Why this matters

`app/api/transactions/route.ts` is the HTTP seam for the Ledger product but has zero tests. GET and POST handlers parse requests, call ledger functions, and shape JSON responses — bugs here bypass unit tests on pure functions. API route tests close the gap between `lib/ledger` and the running app.

## Current state

`app/api/transactions/route.ts`:

```typescript
export async function GET() {
  const ledger = await readLedger();
  return NextResponse.json({
    transactions: ledger.transactions,
    balance: calculateBalance(ledger.transactions),
  });
}

export async function POST(request: Request) {
  try {
    const body = (await request.json()) as { description?: string; amount?: number };
    const transaction = await addTransaction(body.description ?? "", Number(body.amount));
    const ledger = await readLedger();
    return NextResponse.json({ transaction, balance: calculateBalance(ledger.transactions) }, { status: 201 });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unable to create transaction";
    return NextResponse.json({ error: message }, { status: 400 });
  }
}
```

`vitest.config.ts` uses `environment: "node"` and `@` alias to repo root.

No existing API test files. Next.js 15 route handlers can be imported and called directly in Node tests without starting a server.

## Commands you will need

| Purpose   | Command             | Expected on success |
|-----------|---------------------|---------------------|
| Tests     | `npm test`          | all pass            |
| Typecheck | `npm run typecheck` | exit 0              |

## Scope

**In scope**:
- `app/api/transactions/route.test.ts` (create)
- `vitest.config.ts` — only if test file path needs include adjustment (unlikely)

**Out of scope**:
- `app/page.tsx` client tests
- E2E / browser tests
- Route handler logic changes unless required for testability

## Git workflow

- Branch: `advisor/005-api-route-tests`
- Commit message: `test: add API route tests for transactions endpoint`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Set up test isolation

Reuse `LEDGER_DATA_DIR` env override from plan 003. In `route.test.ts`:

```typescript
import { beforeEach, afterEach, describe, it, expect } from "vitest";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { GET, POST } from "./route";

let tempDir: string;

beforeEach(async () => {
  tempDir = await mkdtemp(path.join(tmpdir(), "ledger-api-"));
  process.env.LEDGER_DATA_DIR = tempDir;
});

afterEach(async () => {
  delete process.env.LEDGER_DATA_DIR;
  await rm(tempDir, { recursive: true, force: true });
});
```

If plan 003 did not add `LEDGER_DATA_DIR`, add it to `lib/ledger.ts` as part of this plan's first step (same one-line seam).

**Verify**: test file exists at `app/api/transactions/route.test.ts`

### Step 2: Write GET tests

```typescript
it("GET returns empty ledger initially", async () => {
  const response = await GET();
  const data = await response.json();
  expect(response.status).toBe(200);
  expect(data.transactions).toEqual([]);
  expect(data.balance).toBe(0);
});
```

### Step 3: Write POST tests

```typescript
it("POST creates transaction and returns 201", async () => {
  const request = new Request("http://localhost/api/transactions", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ description: "Coffee", amount: -4.5 }),
  });
  const response = await POST(request);
  const data = await response.json();
  expect(response.status).toBe(201);
  expect(data.transaction.description).toBe("Coffee");
  expect(data.balance).toBe(-4.5);
});

it("POST returns 400 for invalid amount", async () => {
  const request = new Request("http://localhost/api/transactions", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ description: "Zero", amount: 0 }),
  });
  const response = await POST(request);
  expect(response.status).toBe(400);
  const data = await response.json();
  expect(data.error).toMatch(/non-zero/i);
});
```

### Step 4: Verify full suite

```bash
npm test && npm run typecheck
```

**Verify**: all tests pass, typecheck exit 0

## Test plan

- GET empty ledger
- POST success with balance
- POST validation error (400)
- Model structure after `lib/ledger.test.ts`
- Verification: `npm test` → ≥10 tests total

## Done criteria

- [ ] `app/api/transactions/route.test.ts` exists with GET and POST cases
- [ ] Tests use isolated temp data directory
- [ ] `npm test` and `npm run typecheck` exit 0
- [ ] `plans/README.md` status row for 005 updated to DONE

## STOP conditions

- `LEDGER_DATA_DIR` seam missing and cannot be added without larger refactor — stop and report.
- Importing `GET`/`POST` fails due to Next.js build constraints — try dynamic import or document need for `@edge-runtime` shim; stop if unresolved.
- Route handler signature changed — reconcile excerpts.

## Maintenance notes

- When Ledger persistence module is deepened, route tests should remain at HTTP seam — mock the Ledger module interface only if file I/O becomes internal to adapter.
- Consider adding GET-after-POST integration test in same file.
