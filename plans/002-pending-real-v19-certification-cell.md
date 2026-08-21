# Plan 002: Establish a pending real Android v19 certification cell

> Execute only after Plan 001 is green and reviewed. Keep checked-in fixtures
> synthetic. Any explicitly authorized external evidence remains read-only and
> may produce only bounded redacted structural receipts.

## Status

- Priority: P0
- Effort: M
- Risk: HIGH
- Depends on: Plan 001
- Category: compatibility / tests / direction
- Planned at: unborn `HEAD`, 2026-08-10

## Why this matters

The exact observed Android v19 classifier profile can classify and stage a real
direct SQLite input, while the only positive adapter profile is an intentionally
different synthetic text-safe subset. A real file therefore cannot enter the
adapter by construction, and no versioned certification registry records what
the real cell proves or still blocks. Merging the identities would create a
false compatibility claim.

## Frozen acceptance criterion

Add a named pending direct-SQLite Android v19 certification cell that binds the
exact classifier profile, available app/platform metadata, a sanitized
fixture/oracle reference, and an achieved L0-L5 level. A private opt-in read-only
coverage command may emit only counts, schema/storage-class shapes, diagnostic
codes, and hashes. The release gate rejects L3+ while any discovered subject
lacks evidenced mapping or durable preservation, or while timezone, transfer,
or type-7 semantics remain unknown.

## Required work

1. Add a registry entry distinct from the synthetic adapter cell.
2. Add synthetic tests for pending/achieved transitions and universal-claim
   rejection.
3. Add an opt-in external receipt path that is absent and fail-closed by default
   and proves before/after source hash equality.
4. Record table/record/field/storage-class coverage without private values.
5. Keep transfers 3/4, type 7, unknown tables, non-text semantics, timezone/DST,
   attachments, and round-trip levels pending until their own oracles exist.

## Verification

- `swift test --filter CompatibilityCertificationTests` exits zero.
- Private-harness tests use synthetic external files and prove redaction.
- The repository full gate exits zero with no external fixture configured.
- No command writes to the external source; before/after SHA-256 is identical.

## STOP conditions

- Any step would place a real backup, raw row value, account/note/name, SMS,
  photo, credential, or private fixture location in tracked content.
- Available evidence cannot identify edition/version/build or timezone policy;
  keep that field pending rather than guessing.
- The plan would relabel generic staging preservation as semantic L3 import.
