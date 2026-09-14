# Ledger Atlas milestone one specification

Status: living milestone-one contract; not a shipped or compatibility-certified release
Scope: implemented headless/import foundations plus the current native Mac candidate

## Out of scope

Sync, cloud accounts, shipped iOS/Android clients, telemetry, ML, universal compatibility, and claims outside named corpus profiles.

## Release-one Mac completion contract

`docs/specifications/ledger-atlas-mac-completion-v2.md` supersedes the earlier
milestone-two backlog summary for release-one scope. GitHub Issues #37 through #59
carry its 23-ticket execution graph. Issues #26 through #35 remain open as broader
parents and foundations; they do not replace the v2 ticket acceptance text.

Release-one Ledger Atlas backups are plaintext by accepted product decision. They
must show a warning and publish a complete checksummed package atomically with mode
0600. Encrypted Ledger Atlas backups are excluded from release one. The local portal
binds to loopback and remains read-only; browser ledger editing is excluded.

Per-screenshot traceability remains in
`docs/specifications/screenshot-traceability-v1.json`. The v2 contract governs any
release-one conflict with the older screenshot functional specification.

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

### AC-07 — Engineering verification

WHEN a milestone-one change is delivered, its focused checks and the full verifier
SHALL pass on the delivered code. Money, import, migration, package, backup, restore,
security, and privacy changes SHALL receive independent risk-based review.

Verified by: `./scripts/verify.sh --full`, the focused tests named by the affected
acceptance criteria, and recorded review findings for high-risk changes.
