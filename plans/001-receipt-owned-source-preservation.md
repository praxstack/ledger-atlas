# Plan 001: Add receipt-owned source preservation

> **Superseded on 2026-08-26.** Keep this file as historical design evidence.
> Do not execute its manifest, fixed-scope, no-commit, or frozen-review instructions.
> Use the current `prd.json` item and issue tracker instead.

> Historical executor instruction: work test-first and only in the declared paths. Use synthetic SQLite
> fixtures only. Do not stage, commit, push, merge, deploy, or modify external
> evidence.

## Status

- State: SUPERSEDED

- Priority: P0
- Effort: M
- Risk: HIGH
- Depends on: none
- Category: correctness / data model / migration
- Planned at: unborn `HEAD`, 2026-08-10
- Baseline manifest: `617fe580de79b4972bfcdcb5e173b59fe62a4e2e546d4854a18a4c3a4cf42440`

The checksum stop condition below belonged to the superseded plan and no longer
controls editing or commits.

## Why this matters

The canonical schema requires every opaque sidecar to reference an economic
event. The synthetic v19 adapter consequently adds every `ASSETS`, `ZCATEGORY`,
and `CURRENCY` field to the first transaction. That retains bytes but invents
ownership, cannot represent an empty table, and cannot commit a source with only
non-event entities. The product contract defines a sidecar for any not-yet-
modeled source field or entity.

## Current state

- `CanonicalLedgerSchema.swift:77-89` makes `sidecar_reference.event_id`
  mandatory; `:121-129` repeats that owner in `receipt_sidecar`.
- `CanonicalPersistenceModels.swift:70-111` makes `eventID` mandatory on
  `CanonicalPersistedSidecar`; `:114-156` makes events own all sidecar references.
- `MoneyManagerV19Adapter.swift:60-92` appends support fields only to the first
  mapped event.
- `SQLiteCanonicalCommitter.swift:507-540` builds sidecars only by event, while
  `:573-592` proves preserved records/tables through those event-owned fields.
- `MoneyManagerV19AdapterTests.swift:64-120` asserts one event owns all staged
  support fields.

Preserve strict versioned SQLite DDL, exact schema fingerprints, lowercase
64-hex canonical identifiers, content-free diagnostics, and complete checksum,
idempotency, membership, global-health, and rollback coverage.

## Frozen acceptance criterion

Given a synthetic authenticated stage containing an event field, support
entities not owned by an event, an empty table, and an unknown table/record, one
atomic canonical commit persists a receipt-owned, provenance-bound preservation
anchor for every non-event subject/field without assigning it to an economic
event. Reconciliation reaches zero blockers only when every staged artifact,
table, record, and field has target-bound evidence. An identical retry has the
same checksum, and injected failure leaves no event, receipt, anchor, or sidecar.

## Verification

- `swift test --filter AtomicCanonicalCommitTests` exits zero.
- `swift test --filter MoneyManagerV19AdapterTests` exits zero.
- `swift test --filter CanonicalPersistenceModelsTests` exits zero.
- The repository full gate exits zero.

The pre-plan baseline was 121 passing Swift tests and 26 passing auxiliary tests.

## Scope

Only the existing persistence schema/models, commit models/committer, v19
adapter, and their persistence/commit/adapter/reconciliation test files may
change. Locate them by these exact filenames:

- `CanonicalLedgerSchema.swift`
- `CanonicalPersistenceModels.swift`
- `CanonicalCommitModels.swift`
- `SQLiteCanonicalCommitter.swift`
- `MoneyManagerV19Adapter.swift`
- `CanonicalPersistenceModelsTests.swift`
- `AtomicCanonicalCommitTests.swift`
- `MoneyManagerV19AdapterTests.swift`
- `LossReportTests.swift`

Out of scope: real-profile authorization, compatibility certification, UI,
exports, transfers/type-7 semantics, governance controls, external evidence,
and migration of an already-released canonical store.

## Steps

### 1. Add failing synthetic ownership regressions

Add tests proving support-table fields are absent from event sidecars; receipt-
owned payloads/provenance survive staging removal; empty tables receive durable
anchors; a preservation-only request with zero events is available only through
an internal authenticated adapter path; retries are unchanged; forged/surplus
membership conflicts; and injected failure rolls all new and old rows back.

The first focused run must fail for missing behavior, not a syntax error.

### 2. Introduce an explicit receipt-owned model

Add a distinct persisted model for non-event preservation. It must carry a
canonical anchor ID, staged subject ID and kind, artifact/profile/adapter
provenance, optional locator components, typed storage class, exact bounded
payload, and format version. Do not overload `eventID`, use a sentinel event, or
invent a record key for an empty table. Keep subject anchors distinct from field
payloads so an empty subject needs no fabricated bytes.

### 3. Version the exact canonical schema

Bump the bootstrap schema version and add strict objects for receipt-owned
anchors/payloads and their membership. Add exact foreign keys, uniqueness,
allowed kind/disposition checks, checksum queries, object-count assertions, and
fingerprint coverage. Existing event-sidecar objects remain supported.

### 4. Extend commit and reconciliation atomically

Derive receipt-owned targets only from the pinned staging graph. Validate every
locator, storage class, and payload. Include the new rows in target-bound
evidence, checksum, receipt-integrity hash, retry, global-health, orphan/surplus
detection, and rollback. Permit zero events only for an internally authorized
request with nonempty authenticated anchors and complete reconciliation. No
public caller-selected proof or payload can become trusted.

### 5. Move synthetic v19 support ownership

Keep transaction fields event-owned. Move accounts, categories, currencies, and
other non-event subjects to receipt-owned anchors. Delete the first-event
support-field behavior. Unknown semantics remain blocked, and the real
classifier profile remains unauthorized.

### 6. Verify and freeze for P0 review

Run focused checks and the full repository gate, then inspect the exact diff and
scope. Give the frozen criterion and exact changed files to independent reviewer
and adversarial data-integrity lenses.

## Done criteria

- All new red tests fail before and pass after implementation.
- No non-event staged subject is assigned to an arbitrary event.
- Empty-table and zero-event preservation-only cases are durable/idempotent.
- Missing, surplus, forged, or orphaned preservation rows are rejected.
- The full test/gate baseline does not regress.
- Only scoped files change; no stage, commit, push, merge, or deploy occurs.
- Fresh reviewer and red-team lenses have no unresolved P0/P1 finding.

## STOP conditions

- Existing canonical stores must be migrated rather than rejected as an older
  bootstrap schema; that requires a separate migration atom.
- Correctness would require weakening provenance, staging authentication,
  reconciliation, or privacy checks.
- The implementation needs governance-control changes or real data in tests or
  logs.
- Two failed implementation hypotheses expose an incompatible ownership model;
  stop and redesign instead of adding a sentinel event or lossy workaround.

## Maintenance notes

Every future canonical schema change must update exact DDL, fingerprints,
checksums, retry membership, global health, and capability tests together. The
next certification atom must consume this model without merging synthetic and
real source-profile identities.
