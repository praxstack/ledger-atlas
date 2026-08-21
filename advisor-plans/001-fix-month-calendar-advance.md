# Plan 001: Fix monthly calendar advance so December landings stay in the same year

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md`.
>
> **Drift check (run first)**: SHA-256 prefix of
> `Sources/LedgerStore/LedgerApplication.swift` must still start with
> `3bda4c58bf1d13d7`. If it does not, compare the excerpts below to live code
> and STOP on a mismatch.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: unborn HEAD, 2026-08-18
- **Issue**: omitted

## Why this matters

`advance` adds `month / 12` to the year **before** reducing the month into 1…12.
When `month + interval` is a multiple of 12 (January + 11, January + 23, a
12-payment installment’s last step), Swift integer division adds a year and the
month stays 12. A 12-month installment starting in January therefore places the
final payment in December of the *next* year. That is wrong financial time.

CONTEXT.md: financial truth never uses guessed dates. Fix the arithmetic; do
not invent vendor calendar rules.

## Current state

- `Sources/LedgerStore/LedgerApplication.swift` — `advance` at ~503–523;
  installments call it with `frequency: .monthly, interval: index` at ~142–145.
- `tests/LedgerStoreTests/LedgerApplicationTests.swift` — installment tests
  only cover a 3-month plan.

Excerpt (`LedgerApplication.swift`):

```swift
var month = date.month + (frequency == .monthly ? interval : 0)
var year = date.year + (frequency == .yearly ? interval : month / 12)
month = ((month - 1) % 12) + 1
```

Convention: throw `LedgerApplication.Error.invalidCommand` on impossible dates.
Use `SourceLocalDate` constructors. Synthetic dates only (`2024-01-15` style).
Match existing Swift Testing `@Test` style in `LedgerApplicationTests.swift`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests | `cd /Users/prax/Developer/ledger-atlas && swift test --filter LedgerApplicationTests` | exit 0 |
| Full gate | `./scripts/verify.sh --fast` | `verification passed (--fast)` |

## Scope

**In scope**:
- `Sources/LedgerStore/LedgerApplication.swift` (`advance` only, plus any
  private helper it already uses)
- `tests/LedgerStoreTests/LedgerApplicationTests.swift`

**Out of scope**:
- Recurrence generateOccurrence batching (advisor-plans/002 is unrelated)
- Vendor DO_TYPE / ZDATE semantics
- `scripts/gate-commit.sh`, hooks, originals

## Git workflow

- Do not `git commit` unless a finite run arms `./scripts/gate-commit.sh`.
- This repo has an unborn HEAD. Do not `git init` extra remotes or push.

## Steps

### Step 1: Add failing calendar cases

Add tests that drive `LedgerApplication.createInstallmentPlan` (or
`createRecurrence` + generate) from a real temp ledger, not a reimplementation
of `advance`.

Cases (synthetic):
- Start `2024-01-15`, 12 monthly installments: last date year must be `2024`,
  month `12`.
- Start `2024-01-15`, monthly interval 11: next date `2024-12-15`.
- Start `2024-02-29` (or last day of Feb), monthly +1: clamp to March last day
  via existing `lastDay`.

**Verify**: `swift test --filter installment` (or your new test name) **fails**
on the year/month assertion, not on compile.

### Step 2: Fix `advance` with absolute months

Replace the monthly/yearly branch with:

```swift
let monthDelta = frequency == .monthly ? interval : 0
let yearDelta = frequency == .yearly ? interval : 0
let total = date.year * 12 + (date.month - 1) + monthDelta + yearDelta * 12
let year = total / 12
let month = total % 12 + 1
```

Then clamp day with existing `lastDay(year:month:)`. Keep daily/weekly
`addDays` unchanged.

**Verify**: the new tests pass; previous 3-month installment test still passes.

## Test plan

- New tests in `LedgerApplicationTests.swift`, modeled on
  `installmentLastShareAbsorbsRemainderAndDatesAdvance`.
- Drive `LedgerApplication` / `LedgerStore` on a temp SQLite URL.
- No real amounts from backups; use `ExactDecimal("10.00")` style fixtures
  already in that file.

## Done criteria

- [ ] `swift test --filter LedgerApplicationTests` exits 0
- [ ] January+11 and 12-occurrence monthly plans stay in the start year
- [ ] No files outside the in-scope list change
- [ ] `advisor-plans/README.md` status row updated

## STOP conditions

- `advance` no longer exists or installments no longer call it.
- Verification fails twice after a reasonable fix.
- The fix appears to require touching MMImport or vendor adapters.

## Maintenance notes

Any new frequency (quarterly) must use the same absolute-month formula.
Reviewers: check negative intervals if the API ever allows them (today
interval is a positive installment index).
