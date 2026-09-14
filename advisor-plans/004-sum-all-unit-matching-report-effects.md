# Plan 004: Sum every in-unit effect in activity reports

> **Executor instructions**: Follow step by step. Update
> `advisor-plans/README.md` when done.
>
> **Drift check**: `LedgerApplication.swift` SHA-256 prefix `3bda4c58bf1d13d7`.
> STOP if `report(from:unitCode:)` no longer uses `draft.effects.first`.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: unborn HEAD, 2026-08-18

## Why this matters

`LedgerApplication.report` totals only `draft.effects.first` when that effect’s
unit matches. Transfers have two effects; `LedgerDomain` sorts effects by
`accountID`, so “first” is not “source.” FX destination money never enters a
USD report; same-currency transfers look like a single decrease. Insights
reuse this report (`LedgerJourney`). Reports must reconcile to canonical
events and must not become a second, quieter ledger.

## Current state

`Sources/LedgerStore/LedgerApplication.swift:310-321`:

```swift
guard let effect = draft.effects.first, effect.amount.unitCode == unitCode else { continue }
entry!.0 = try entry!.0.adding(effect.amount.amount)
entry!.1 += 1
```

`tests/LedgerStoreTests/LedgerApplicationTests.swift` already builds an FX
transfer (`10.00` USD / `9.00` EUR) and a split in
`reportInventoryReconcilesToCanonicalEventsAndProjectionRebuildLeavesChecksum`
but does not assert activity totals.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Focused | `swift test --filter reportInventory` | exit 0 |
| Application | `swift test --filter LedgerApplicationTests` | exit 0 |

## Scope

**In scope**:
- `Sources/LedgerStore/LedgerApplication.swift` (`report(from:unitCode:)` only)
- `tests/LedgerStoreTests/LedgerApplicationTests.swift`

**Out of scope**: new analytics stores, DuckDB, vendor reports, Insights UI
chrome (kernel totals first).

## Git workflow

No commit unless the gate is armed.

## Steps

### Step 1: Assert totals on the existing FX/split fixture

Extend `reportInventoryReconcilesToCanonicalEventsAndProjectionRebuildLeavesChecksum`
(or add a sibling that uses the same setup) so that after creating the FX
transfer + split:

- `report(unitCode: "USD")` includes **both** USD legs that exist (source
  transfer decrease `10.00` and any USD split/expense amounts).
- `report(unitCode: "EUR")` includes the EUR destination `9.00`.
- Count of transfer rows is not silently 0 for the other currency.

Drive `LedgerApplication.report` / `LedgerApplication.report(from:unitCode:)`.

**Verify**: test fails because only `effects.first` is summed.

### Step 2: Sum matching effects

Replace the `effects.first` guard with a loop:

```swift
for effect in draft.effects where effect.amount.unitCode == unitCode {
  // add effect.amount.amount; increment count once per transaction per unit
}
```

Count policy: increment `count` **once per transaction that has at least one
matching effect**, not once per leg (so a same-currency transfer is one
transfer row with two summed effects). Document that in the test name.

If both legs of a same-currency transfer are `10.00` decrease + `10.00`
increase, the kind total becomes `20.00` if you blindly add magnitudes.
**Do not** invent netting. Add signed amounts as stored (`ExactDecimal.adding`).
If the existing `ExactDecimal` values are unsigned and direction lives on
`LedgerEffectDirection`, apply decrease as subtraction or keep the current
sign convention used by single-effect expenses — **read one expense test and
match it**. If you cannot determine the sign convention from an existing
test, STOP.

**Verify**: FX/split assertions pass; inventory checksum test still passes.

## Test plan

Reuse the existing FX+split fixture. Synthetic only.

## Done criteria

- [ ] USD and EUR reports include the FX legs that match that unit
- [ ] `swift test --filter LedgerApplicationTests` exits 0
- [ ] No out-of-scope files

## STOP conditions

- `LedgerReportRow` cannot express two currencies (it is already per
  `unitCode` call — do not redesign the type).
- Sign convention for decrease vs increase is not evidenced by an existing
  test.

## Maintenance notes

Insights (`LedgerJourney.insightTable`) will pick this up automatically if
they call `report`. Do not add a second totaling path.
