# Ledger Atlas agent domains

Keep one task context focused on one domain. Cross-domain work must be split into linked tickets with explicit interface acceptance criteria.

Layout: single-context. Root `CONTEXT.md` is the shared vocabulary; architecture decisions are recorded as ADRs under `docs/decisions/` (numbered markdown files), not `docs/adr/`.

## Engineering quality

Acceptance criteria, architecture boundaries, root-cause fixes, focused and full
verification, risk-based review, and tracker synchronization. Quality checks improve
the product; they do not create a separate commit-permission system.

## Compatibility laboratory

Read-only classification, named profile registry, synthetic fixtures, schema fingerprints, immutable staging, and certification evidence. Vendor schemas and codes stop at this boundary.

## Canonical ledger

Exact money and temporal primitives, accounts, transactions, provenance, loss reconciliation, atomic persistence, idempotency, migrations, backup, export, and restore.

## Money Manager v19 adapter

Observed source structure and evidence-backed semantics for accounts, categories, currencies, transactions, transfers, recurrence, installments, attachments, tombstones, and unknown preservation. Never infer universal compatibility.

## Native Mac product

Ledger browsing, import review, editing, settings, search, reports, budgets, accessibility, reduced motion, menus, window behavior, and recovery UX.

## Shared clients

Stable independently owned contracts for future sync and iOS. Client parity is measured against canonical behaviors, not copied vendor UI.
