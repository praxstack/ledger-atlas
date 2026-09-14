# Plan 002: Reject a transfer fee when only one of fee/account is present

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on.
> Update `advisor-plans/README.md` when done.
>
> **Drift check**: SHA-256 prefix of
> `Sources/LedgerStore/LedgerApplication.swift` must start with
> `3bda4c58bf1d13d7`. STOP if `createTransfer` no longer matches the excerpt.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: unborn HEAD, 2026-08-18

## Why this matters

`LedgerApplication.createTransfer` posts a fee only when **both** `fee` and
`feeAccountID` are non-nil. If exactly one is set, it still creates the
transfer and returns `fee: nil`. Callers can believe a fee was applied; the
ledger is short that amount and has no fee link. Financial commands must fail
closed (`LedgerApplication.Error.invalidCommand`) and leave checksum
unchanged.

## Current state

`Sources/LedgerStore/LedgerApplication.swift:62-98`:

```swift
if let fee, let feeAccountID {
  // builds feeRequest
}
let result = try store.createTransfer(
  transfer: .init(...),
  fee: feeRequest)
return (result.transfer.revision, result.fee?.revision)
```

Convention: invalid money commands throw `invalidCommand` and must not mutate.
See existing `invalidTransferFeeLeavesLedgerUnchanged` in
`tests/LedgerStoreTests/LedgerApplicationTests.swift`.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Focused | `swift test --filter LedgerApplicationTests` (cwd product repo) | exit 0 |
| Fast gate | `./scripts/verify.sh --fast` | verification passed |

## Scope

**In scope**:
- `Sources/LedgerStore/LedgerApplication.swift` (`createTransfer` only)
- `tests/LedgerStoreTests/LedgerApplicationTests.swift`

**Out of scope**: FX conversion math, vendor transfer types 3/4, Mac UI.

## Git workflow

Use a normal local commit after the relevant checks pass. Push and merge are separate
external actions.

## Steps

### Step 1: Failing tests

Add two tests on a real temp ledger (copy the existing transfer fixture
pattern):

1. `fee` set, `feeAccountID` nil → throws `invalidCommand`; account/tx counts
   and checksum unchanged.
2. `fee` nil, `feeAccountID` set → same.

Keep the existing paired fee path green.

**Verify**: new tests fail because the transfer currently commits.

### Step 2: Fail closed

Before building drafts:

```swift
if (fee == nil) != (feeAccountID == nil) { throw Error.invalidCommand }
```

Then keep the existing `if let fee, let feeAccountID` body.

**Verify**: new tests pass; existing FX/fee tests pass.

## Test plan

Model after `invalidTransferFeeLeavesLedgerUnchanged`. Synthetic units
`USD` / `ExactDecimal("1.00")` only.

## Done criteria

- [ ] Exactly-one-of fee/account throws and leaves the ledger unchanged
- [ ] Both-set and both-nil paths unchanged
- [ ] `swift test --filter LedgerApplicationTests` exits 0
- [ ] No out-of-scope files modified

## STOP conditions

- `createTransfer` signature changed in a way that removes the optional pair.
- You need to change `LedgerStore.createTransfer` to satisfy the test.

## Maintenance notes

Mac transfer UI (if added later) must disable the fee field unless an account
is chosen, but the kernel remains the authority.
