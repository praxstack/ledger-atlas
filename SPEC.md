# Ledger Atlas milestone one specification

Status: living candidate contract (unaccepted; no baseline commit)  
Scope: headless importer/CLI plus public LedgerApplication commands and a native Mac journey

## Out of scope

Sync, cloud accounts, shipped iOS/Android clients, telemetry, ML, universal compatibility, and claims outside named corpus profiles.

## Acceptance criteria

### AC-01 — Immutable classification

WHEN `mmctl inspect` receives an input, the system SHALL open source SQLite read-only/immutable, hash it before interpretation, classify container/schema against a versioned profile, and make no source write.

Verified by: `swift test --filter SourceClassificationTests` and before/after source SHA-256 equality.

### AC-02 — Lossless staging

WHEN a recognized profile is staged, the system SHALL account for every source entity/field as mapped, sidecar-preserved, intentionally excluded with a visible reason, or blocking.

Verified by: `swift test --filter LossReportTests` and the live CLI on the synthetic four-table v19 fixture:

```
mmctl inspect <synthetic.sqlite> --json
mmctl coverage <synthetic.sqlite> --json
mmctl stage --input <synthetic.sqlite> --staging-db <stage.sqlite> --json
mmctl reconcile --observed-v19-request <request.json> --expect-zero-loss --json
```

The CLI does not accept `mmctl reconcile <path>`. `mmctl` has no `commit` write path; the only approved write is the in-process `ImportWorkspace` approval. An automatic `mmimport-staging-v1` stage of the synthetic text-subset profile is remapped to `money-manager-android-v19-adapter-v1`.

### AC-03 — Exact financial semantics

WHEN amounts, currencies, dates, transfers, tombstones, or relationships are mapped, the system SHALL preserve raw literals/provenance and use exact decimal/minor-unit plus explicit timezone/local-date semantics without binary float.

Verified by: property tests for decimal/time round trips and synthetic transfer/reconciliation fixtures.

### AC-04 — Atomic canonical commit

IF validation, mapping, loss accounting, or reconciliation fails, THEN the system SHALL leave canonical state unchanged and emit deterministic diagnostics without source values.

Verified by: failure-injection/rollback tests and destination checksum equality.

### AC-05 — Idempotency

WHEN the same source is imported repeatedly, the system SHALL produce no duplicate economic event and SHALL distinguish unchanged, changed-source, and incompatible-profile cases.

Verified by: repeated/import-order property tests and stable canonical checksums.

### AC-06 — Named certification

WHEN compatibility is reported, the system SHALL name platform, app edition/version/build, container, schema fingerprint, fixture/oracle, and achieved L0-L5 level; it SHALL NOT claim universal compatibility.

Verified by: compatibility-matrix schema tests and release gate.

### AC-07 — Headless verification

WHEN a milestone-one atom is committed, fast/full verification and structured review SHALL be fresh and bound to the exact staged tree.

Verified by: `./scripts/verify.sh --full`, deliberate-red hook test, and attestation mutation tests.
