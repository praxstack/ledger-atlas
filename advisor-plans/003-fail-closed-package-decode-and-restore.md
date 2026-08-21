# Plan 003: Fail closed on unknown package enums and non-empty product restore

> **Executor instructions**: Follow step by step. Update
> `advisor-plans/README.md` when done.
>
> **Drift check**: `LedgerApplication.swift` SHA-256 prefix `3bda4c58bf1d13d7`,
> `LedgerStore.swift` prefix `905da6afd8b9cae9`. STOP if `importPackage` /
> `decodePackage` / `applyExport` excerpts no longer match.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: unborn HEAD, 2026-08-18

## Why this matters

Package decode uses `LedgerEffectDirection(rawValue:) ?? .increase` and the
same defaulting for kind/link/lifecycle. A hand-edited or newer package can
invert a decrease or rewrite an expense as an adjustment and persist it as
canonical history. Restore admission only checks empty accounts/transactions,
so a category+budget ledger (legal from Mac create) **merges** via
`ON CONFLICT DO UPDATE`. CONTEXT.md: invalid commands leave the ledger
unchanged; restore is “empty destination or fail.”

## Current state

`LedgerApplication.importPackage` (~395–407):

```swift
if !existing.accounts.isEmpty || !existing.transactions.isEmpty {
  // identical digest → return; else throw
}
try store.applyExport(try decodePackage(payload, manifest: manifest))
```

`LedgerStore.applyExport` (~682–686):

```swift
guard snapshot.transactions.isEmpty, snapshot.accounts.isEmpty else {
  throw Error.incompatibleCanonicalStore
}
```

`decodePackage` (~668–693) defaults unknown `direction`/`kind`/`link kind`.

Convention: `throw Error.invalidCommand` / `incompatibleCanonicalStore`.
No `as!` on untrusted enum strings. Tests: existing two-cycle restore in
`LedgerApplicationTests.swift` / journey tests.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Focused | `swift test --filter LedgerApplicationTests` | exit 0 |
| Store | `swift test --filter LedgerStoreTests` | exit 0 |
| Fast | `./scripts/verify.sh --fast` | verification passed |

## Scope

**In scope**:
- `Sources/LedgerStore/LedgerApplication.swift` (`importPackage`, `decodePackage`)
- `Sources/LedgerStore/LedgerStore.swift` (`applyExport` empty-destination guard)
- Matching tests under `tests/LedgerStoreTests/`

**Out of scope**: inventing vendor enums, changing export schema version,
rewriting checksum algorithm, originals.

## Git workflow

No commit unless the gate is armed.

## Steps

### Step 1: Failing tests

1. Build a valid synthetic package, then mutate one decoded JSON direction to
   `"not-a-direction"` (or encode a package dict with that raw value) and
   `importPackage` into an empty ledger → must throw; destination still empty.
2. Create only a native category (or budget) in a dest ledger, then
   `importPackage` a valid package → must throw; dest category still the only
   row.

Drive `LedgerApplication.importPackage` / `LedgerStore.applyExport`. Do not
reimplement decode in the test beyond building the hostile payload.

**Verify**: tests fail on current defaults / empty-accounts-only guard.

### Step 2: Typed decode

Replace `?? .increase` / `?? .adjustment` / `?? .related` / similar decode
defaults with `guard let value = Enum(rawValue: raw) else { throw
Error.invalidCommand }`. Prefer not adding new `as!` keys.

### Step 3: Empty product destination

Extend both `importPackage` and `applyExport` guards so restore is refused
when **any** native product collection is non-empty (accounts, transactions,
categories, recurrence, budgets, installment plans — whatever the snapshot
already exposes). Keep the identical-digest early return on a full re-import
of the same package into the **same** filled ledger if that path is already
tested; do not use it to allow merge into a *different* nonempty dest.

**Verify**: new tests pass; two-cycle export/import tests still pass.

## Test plan

Pattern: `midRestoreProductErrorLeavesDestinationUnchanged` and
`exportImportTwoCyclesPreserveLinksMoneyAndProductCollections`.
Synthetic IDs (`c`×64 keys) already used in those tests.

## Done criteria

- [ ] Unknown enum raw values throw; dest unchanged
- [ ] Category-only dest cannot merge a package
- [ ] Focused Swift tests above exit 0
- [ ] No out-of-scope files

## STOP conditions

- Snapshot type has no category/budget counts and you would invent a SQL
  side channel — report instead of guessing table names.
- Two-cycle restore starts failing for a reason other than your guard.

## Maintenance notes

If schema v11 adds tables, the empty-destination check must include them.
Reviewers: this is P0 export/restore.
