# Ledger Atlas durable context

Updated: 2026-08-18
Status: unaccepted implementation candidate. Repository commits contain an importer,
canonical-ledger kernel (schema v10), public LedgerApplication commands, redacted CLI,
and a native Mac journey/session. No real-v19 lossless import
certificate, or shipped application exists.

## Canonical vocabulary

- **Entry**: one immutable economic event in the canonical ledger, with versioned corrections rather than destructive replacement.
- **Account**: a canonical container whose balances derive from entries.
- **Transfer**: one canonical economic movement with linked source and destination effects.
- **Sidecar**: lossless opaque preservation of a source field/entity not yet modeled canonically.
- **LossReport**: deterministic accounting of every source entity as mapped, sidecar-preserved, intentionally excluded, or blocking.
- **Source profile**: a named platform/app-version/container/schema combination in the compatibility corpus.

Vendor terms such as `INOUTCOME`, `DO_TYPE`, `PERIOD_TYPE`, and `.mmbak` appear only inside Money Manager adapters and evidence documents.

## Evidence boundary

- Data-backed: the observed Android SQLite profile has `user_version=19`; the supplied newer `.sqlite` and direct `.mmbak` pair are byte-identical. Source: `/Users/prax/Developer/money-manager-reverse-engineering/research/compatibility/waves/wave-03/shard-sqlite-mmbak.md`.
- Data-backed: the supplied XLSX is a flattened partial report and omits source identities/metadata. Source: `/Users/prax/Developer/money-manager-reverse-engineering/research/compatibility/waves/wave-03/shard-xlsx-export.md`.
- Observed: 25 restricted Android screenshots cover 14 route families; the synthetic target catalog has 98 screens with explicit unknowns. Source: `/Users/prax/Developer/money-manager-reverse-engineering/research/ui-reconstruction/waves/pass-02/design-navigation-audit.md`.
- Unknown: historical Android/iOS schema/container families, attachment packaging, original-app round trips, and several enum/calculation behaviors are not certified.

## Architecture in force

1. Versioned source adapters classify immutable inputs.
2. Staging plus loss/reconciliation either commits atomically or leaves canonical state unchanged.
3. One independent SQLite ledger is the only writable financial truth.
4. Search, metrics, charts, exports, ML, Arrow/Parquet, and DuckDB are rebuildable versioned projections/packages.
5. Future clients sync canonical operations/entities, never vendor database rows.

## Current milestone boundary

The verified synthetic candidate covers immutable source classification, staging, loss
accounting/reconciliation, atomic/idempotent canonical import, a redacted `mmctl` surface,
synthetic-profile import preparation, and a public LedgerApplication seam for create,
correct, tombstone, linked transfers (including FX/fees), splits, installments, recurrence,
budgets, filtered search (account, date, amount, category, memo, tag, status,
correction history), reports that include a snapshot-derived inventory and
accessible table, rebuildable projections, export/import packages, and two-cycle
restore. Package restore writes accounts, revisions, links, recurrence, budgets,
and installment plans in one mutate; a mid-restore error leaves the destination
unchanged. Compatibility certificates can be minted only for registered
fixture/oracle names; coverage still permits L0 only.

Live `mmctl` commands are `inspect`, `coverage`, `stage`, and `reconcile`. On the
synthetic four-table profile `realbyte-android-v19-synthetic-text-subset-v1`, the
headless path is inspect → coverage → stage → `reconcile --observed-v19-request`.
`mmctl` cannot write a canonical ledger. Staging remaps automatic
`mmimport-staging-v1` to `money-manager-android-v19-adapter-v1` for that synthetic
profile (and for the observed profile identifier). The real observed Android v19
cell remains classification-only and distinct. `MoneyManagerV19ObservedSchema.review(databaseURL:)`
is an L0 structure-review seam over synthetic or local SQLite: it accounts published
tables/records/fields without mapping, without an L3+ claim, and without writing a
canonical ledger.

Advisor-plans 001–005 are implemented on this unaccepted tree: monthly
advance uses absolute months so December stays in the start year; a
half-specified transfer fee throws and leaves the ledger unchanged; package
decode rejects unknown enums; restore refuses any nonempty product
destination; activity reports sum every in-unit effect; `verify.sh` honors
`LEDGER_ATLAS_EVIDENCE_ROOT` and the locked interpreter.

The Mac executable constructs `LedgerJourney`, wires select/approve/edit, and
renders 13 data-backed destinations from journey rows. Search applies a query
against the opened canonical snapshot. Insights show activity plus inventory
counts and an accessible table. Backup/restore can export and restore a
versioned package of the opened ledger through two cycles. After begin-editing,
the journey can create accounts, categories, transfers, splits, installments,
recurrence, and budgets so those destinations are data-backed. Settings expose
reduced-motion and privacy-redaction rows. It is not a shipped finance product.
Shared `LedgerClient` / `IOSFacingLedgerClient` contracts include search, report,
projection, checksum, and export; there is no iOS app target. No sync, cloud service,
real-v19 import certificate, or universal compatibility claim exists. The custom
commit-governance system was removed by an explicit stakeholder decision on
2026-08-26. Product work now follows the technical and architecture checks in
`AGENTS.md` and `docs/orchestration/RUNBOOK.md`. No shipped product, L3+, or
real-v19 certificate is claimed.
