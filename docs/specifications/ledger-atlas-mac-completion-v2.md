# Ledger Atlas Mac App Completion v2

Status: accepted release-one product contract; implementation remains incomplete
Version: 2.0
Date: 2026-08-27
Scope: native macOS 15+ Apple-silicon product, Money Manager Android v19 perimeter compatibility, widget, local integrations, and signed DMG delivery
Authority: this versioned specification governs release-one scope; GitHub Issues govern ticket state

## Product contract

### Objective

Ledger Atlas release one gives a Mac user a complete local personal-finance product. The user can create or import a ledger, manage daily financial activity, inspect exact reports, protect private data, back up and restore the ledger, use a redacted widget, and install a signed application. Money Manager data enters through a versioned compatibility adapter and never defines the canonical domain.

Release-one completion requires all 23 delivery tickets to meet their acceptance text. Passing a focused test, rendering an HTML board, creating a ticket, or committing code proves only that named result. A release claim also requires the private supplied-corpus proof and the signed, notarized, installed DMG smoke proof.

### Financial truth

- Canonical money uses exact decimal or integer minor units. Binary floating point never represents financial truth.
- Each amount preserves its raw literal, currency or commodity unit, scale, and rounding rule.
- Each temporal value preserves the local date, wall time, timezone identifier, resolved offset, calendar, and instant when the source provides them.
- Revisions append correction history. Tombstones preserve identity and links.
- A source record may create several canonical effects. `SourceEffectIdentity` binds the source profile, table, record identifier, effect ordinal, adapter version, and canonical effect identifier.
- Transactions, split lines, transfer effects, fees, generated occurrences, attachments, budgets, and provenance keep stable identities through edit, backup, restore, and reopen.

### Canonical and adapter boundaries

1. Versioned source adapters classify immutable compatibility inputs.
2. Staging and loss accounting map, sidecar-preserve, intentionally exclude with a visible reason, or block each source item.
3. `LedgerApplication` owns typed commands and queries. Native views, App Intents, the widget, and the local portal do not write SQLite.
4. `LedgerStore` owns descriptor-bound SQLite access, transactions, migration, rollback, checksum, backup, and restore.
5. Search indexes, report snapshots, widget projections, PDFs, and diagnostics remain rebuildable derivatives.
6. Vendor tables, codes, filenames, and lifecycle assumptions stay inside versioned Money Manager adapters and compatibility evidence.

### Native product boundary

- The first client is a sandboxed native macOS 15+ Apple-silicon app built with SwiftUI and AppKit conventions.
- The app and widget share an App Group. The shared container holds only a redacted projection.
- Security-scoped bookmarks retain user-selected ledger, import, backup, attachment, and export locations.
- `LedgerJourney` owns onboarding and open-ledger transitions. `LedgerSession` owns one opened ledger and its presentation state.
- The product uses typed destinations for Overview, Transactions, Accounts, Plans, Reports, Import, Backup, and Settings.
- Each command has a visible control or menu item. Keyboard shortcuts supplement those controls.

### Daily finance behavior

- Users can manage accounts, account groups, arbitrary-depth category trees, income, expenses, split purchases, transfers, foreign exchange, fees, budgets, recurrence, installments, notes, and receipt attachments.
- The transaction ledger supplies Daily, Calendar, Monthly, Total, and Note modes with paging, filters, stable selection, edit return position, and conflict display.
- Statistics derive from one immutable report snapshot. Category ancestors roll up child effects once. Transfers remain neutral where the report defines them as neutral.
- PDF statements and XLSX exchange use versioned projections. They never become canonical truth.
- Local OCR produces suggestions. Only a user-confirmed command can create or change financial truth.

### Privacy and security

- Real financial content, credentials, SMS, photos, names, notes, transaction values, source paths, and source rows stay out of Git, prompts, logs, screenshots, diagnostics, and routine test output.
- Tracked fixtures and UI captures use synthetic data.
- Passcode secrets and failure counters live in Keychain. Five failed attempts lock for 60 seconds; ten lock for 900 seconds. The state survives restart.
- Locking redacts the app, widget, notifications, local portal, and app-switcher representation.
- The local portal binds to loopback, exposes read-only routes, and stops on lock, sleep, inactivity, or ledger switch.
- The app requests notification, biometric, local-network, photo, and file access only at the action that needs it. Denial preserves state and offers recovery.

### Backup, restore, and reset

- Release-one Ledger Atlas backups are plaintext by accepted product decision.
- Backup creation shows a visible plaintext warning, writes a complete versioned payload, records checksums, publishes with mode `0600`, and fsyncs the file and containing directory before success.
- Package format versioning remains independent from canonical schema versioning.
- Restore validates format, checksum, identity, provenance, attachments, and conflicts before mutation. Merge and overwrite are separate reviewed operations.
- Two restore cycles preserve the declared canonical checksum and attachment set.
- Complete reset and contents-only reset create a replacement ledger and publish it through an atomic swap. An interrupted reset leaves the current ledger usable.

### Compatibility and certification

- Original backups, exports, screenshots, and the reverse-engineering repository remain read-only evidence outside this repository.
- SQLite sources open with read-only and immutable flags. Before and after SHA-256 hashes must match.
- Direct SQLite and ZIP access to the same payload must create the same canonical result.
- The five supplied XLSX files are overlapping report views and never append duplicate events.
- Unknown type `7`, budget period `6`, category-depth behavior, and compound-purchase representation require owner-supervised synthetic oracle evidence before mapping.
- A certificate names the platform, app version and build, container, schema fingerprint, fixture or oracle, adapter version, locale, currency, and achieved compatibility level.
- The vendor writer rejects any compound canonical purchase that the named Money Manager profile cannot represent without loss.

### Accessibility and performance

- Every screen supports keyboard completion, visible focus, logical focus order, row-level VoiceOver, 200 percent text, high contrast, reduced motion, and non-color state cues.
- Each chart has an exact accessible table and spoken summary.
- All 25 screenshot traceability records receive synthetic privacy-safe Ledger Atlas captures. The source screenshots never enter the repository.
- Ledger browsing, search, and report paths remain paged on a 100000-entry synthetic ledger and meet the ticketed response targets.

### Delivery definition

Delivery requires the reviewed final commit, passing focused and full checks, closed risk-review findings, the private supplied-corpus proof, a Developer ID Application signature, Apple notarization and stapling, Gatekeeper verification, clean-account installation, and the accepted installed smoke suite. Credentials and owner authorization remain external gates.

## Assumptions

1. The release target is macOS 15 or newer on Apple silicon.
2. The product owner can supervise the synthetic Money Manager oracle session and the private supplied-corpus proof.
3. The supplied Android v19 SQLite, ZIP, five XLSX reports, and 25 screenshots remain available at their read-only private locations for authorized proof runs.
4. Apple Developer ID Application credentials and notarization access will be available for MACV2-23. Their current absence blocks delivery but does not change product scope.
5. Users choose durable local or mounted folder destinations and grant security-scoped access. Ledger Atlas does not request a cloud-provider credential.
6. Release-one migration starts from the current canonical v10 store and publishes canonical v11 through one named atomic migration.
7. Existing v10 stores, older supported packages, and single-category transaction callers remain supported through their declared compatibility seams.
8. GitHub repository `praxstack/ledger-atlas` remains canonical; the Linear Ledger Atlas project remains its planning mirror.

## Exclusions

- Browser-based ledger editing or browser mutation APIs.
- Sync, cloud accounts, telemetry, ML classification of financial truth, and multi-user collaboration.
- Shipped iOS, Android, Windows, or web clients.
- Universal Money Manager compatibility, historical profile claims, or source semantics without a named tested cell.
- Encrypted Ledger Atlas backups in release one. A later version may add authenticated encryption without changing the plaintext release-one contract retroactively.
- Copying Money Manager branding, advertising, proprietary assets, or pixel layout.
- Writing a vendor backup that flattens splits, drops provenance, or changes unsupported canonical structures.
- Widget writes to the canonical database.
- OCR, notification, widget, portal, or diagnostic output that changes financial truth.
- Release claims based on development signing, queued CI, local HTML, ticket creation, or test output alone.

## Implementation decisions

### D-01 — One native product

Release one ships one sandboxed Mac app, one widget extension, five App Intents, and one signed DMG. No browser editor ships.

### D-02 — Sole write boundary

`LedgerApplication` owns all canonical commands. `LedgerStore` owns SQLite. Views, intents, the widget, portal, OCR, and notifications submit typed requests or consume projections.

### D-03 — Atomic v11 migration

Canonical schema v11 uses an explicit migration from pinned v10. The store validates a recovery image and performs descriptor-bound migration and publication with rollback.

### D-04 — Independent package versions

Canonical schema, Ledger Atlas backup package, report export, widget projection, and Money Manager adapter versions advance independently.

### D-05 — First-class compound purchase

A split purchase has one stable purchase identity and ordered line identities over linked canonical effects. Existing single-category tuple callers remain compatible.

### D-06 — Exact transfers and FX

Transfers create linked source and destination effects in one transaction. FX retains both amounts and currencies, the rate literal, rounding rule, and fee effects.

### D-07 — Plaintext release-one backup

The release-one backup format is plaintext with a warning, checksum manifest, atomic mode-`0600` publication, and full provenance and attachment coverage.

### D-08 — Local attachment and OCR path

The app bounds attachment decode, hashes bytes, runs OCR on device, and presents suggestions. A user confirms each financial change.

### D-09 — Redacted widget projection

The app publishes a small redacted App Group projection. The widget never opens or mutates the canonical ledger.

### D-10 — Authenticated App Intents

Add Expense, Add Income, Add Transfer, Create Backup, and Open Budgets route through app-owned commands. Locked write intents open the app for authentication.

### D-11 — Read-only loopback portal

The local portal binds to loopback and serves report snapshots without mutation routes. Lock, sleep, inactivity, and ledger switch terminate it.

### D-12 — Owner-assisted semantic oracle

An agent builds the synthetic structural harness. The owner performs original-app actions for type `7`, budget period `6`, category depth, transfers, and attempted three-category purchases.

### D-13 — Representability-gated vendor export

The Money Manager writer emits only structures the named adapter can represent. It rejects compound purchases and unknown states that would lose meaning.

### D-14 — Synthetic UI proof

The UI proof uses 25 synthetic captures keyed by the existing screenshot traceability manifest, plus keyboard, VoiceOver, contrast, text-scale, reduced-motion, privacy, and performance checks.

### D-15 — Exact delivery artifact

The release receipt binds the reviewed commit, archive, DMG, signature, notarization, staple, Gatekeeper result, installation, and smoke run by hashes.

## User stories

### US-01 Create a ledger

As a Mac user, I can create an empty ledger at a durable location so my financial data survives app restart.

### US-02 Open or upgrade a ledger

As a returning user, I can open a supported ledger or upgrade v10 to v11 without losing the prior store if migration fails.

### US-03 Manage accounts

As a user, I can create, edit, reorder, hide, include in totals, tombstone, restore, and classify accounts.

### US-04 Manage account groups

As a user, I can organize accounts into ordered groups without changing transaction history or balances.

### US-05 Manage category trees

As a user, I can maintain arbitrary-depth income and expense category trees while reports preserve stable historical links.

### US-06 Record income

As a user, I can enter, validate, copy, correct, and tombstone exact income through a native form.

### US-07 Record an expense

As a user, I can enter, validate, copy, correct, and tombstone a single-category expense through the same canonical command seam.

### US-08 Split a purchase

As a user, I can split one expense across ordered category lines that sum exactly to the purchase total.

### US-09 Transfer between accounts

As a user, I can move value between two accounts as linked effects that cannot drift apart.

### US-10 Record FX and fees

As a user, I can record both sides of a currency conversion with the rate, rounding, and separate fee effects.

### US-11 Browse daily activity

As a user, I can browse a paged daily ledger with exact totals, indicators, and stable selection.

### US-12 Use the calendar view

As a user, I can select a calendar day and inspect its income, expense, net, and contributing entries.

### US-13 Use monthly and total views

As a user, I can compare monthly groups and exact totals for a selected range.

### US-14 Browse notes

As a user, I can find transaction notes and standalone memos without mixing their identities.

### US-15 Search and filter

As a user, I can search and filter by account, date, amount, category, memo, tag, status, and correction history.

### US-16 Edit from the ledger

As a user, I can edit a selected item and return to the same ledger position, with stale revision conflicts shown.

### US-17 Inspect statistics

As a user, I can inspect exact category roll-up, trends, total balance, and contributing entries through charts and tables.

### US-18 Export a PDF statement

As a user, I can export a redaction-aware PDF from one immutable report snapshot.

### US-19 Plan budgets

As a user, I can create, edit, roll over, pause, and tombstone budgets whose totals derive from canonical effects.

### US-20 Plan recurrence

As a user, I can generate, pause, skip, resume, and scope edits to recurring occurrences without duplicating history.

### US-21 Plan installments

As a user, I can manage installment schedules and future edits without rewriting completed effects.

### US-22 Attach a receipt

As a user, I can add a private receipt from supported Mac sources and retain its hash and ledger linkage through backup and restore.

### US-23 Confirm OCR suggestions

As a user, I can review local multi-line OCR category suggestions before any suggestion changes financial truth.

### US-24 Configure presentation

As a user, I can choose locale, date, time, number, appearance, colors, period starts, and start screen without changing canonical literals.

### US-25 Configure behavior

As a user, I can choose carry-over, quick actions, reminders, privacy redaction, and reduced motion through typed settings.

### US-26 Lock the product

As a user, I can set, unlock, change, or remove a passcode and use biometric fallback under persistent lockout rules.

### US-27 Back up and restore

As a user, I can create a warned plaintext backup, preview restore, choose merge or overwrite, and verify two restore cycles.

### US-28 Exchange XLSX and reset

As a user, I can preview XLSX exchange, move attachment sidecars, and run complete or contents-only reset without partial state.

### US-29 Import Money Manager v19

As a migrating user, I can import the named supplied v19 profile only after immutable review, loss accounting, owner oracle evidence, and reconciliation.

### US-30 Use the widget

As a user, I can view a redacted widget summary while the canonical ledger stays private and read-only to the extension.

### US-31 Use App Intents

As a user, I can add expense, add income, add transfer, create backup, or open budgets through authenticated app-owned actions.

### US-32 Use local reports and reminders

As a user, I can open a read-only loopback report, receive redacted reminders, and export content-free diagnostics.

### US-33 Install the release

As a Mac user, I can install a Developer ID signed and notarized DMG that passes Gatekeeper and the clean-account smoke suite.

## Test seams

### TS-01 Application command seam

Drive account, category, transaction, split, transfer, planning, attachment-confirmation, settings, lock, backup, and reset behavior through `LedgerApplication`. Tests assert exact readback, stable identity, typed failure, idempotency, and unchanged state after invalid commands.

### TS-02 Descriptor-bound store seam

Drive schema migration, transactions, checksums, atomic file publication, package decode, restore, and rollback through `LedgerStore`. Tests inject failure at each mutation and publication boundary and compare destination checksums.

### TS-03 Compatibility laboratory seam

Drive immutable classification, staging, `LossReport`, stable one-to-many mapping, reconciliation, oracle diffs, and certificate registry through versioned adapters. Routine tests use synthetic inputs; the named private profile runs only under owner-authorized proof.

### TS-04 Native presentation seam

Drive typed routes, forms, keyboard commands, accessibility trees, redaction states, widget projections, App Intent routing, and localhost lifecycle with synthetic ledgers. Tests verify persisted effects through TS-01 instead of inspecting view internals.

### TS-05 Delivery seam

Bind the final commit to build, archive, DMG, signature, notarization, staple, Gatekeeper, installation, privacy-safe captures, performance, and smoke receipts. This seam cannot substitute development signing or queued CI for installed proof.

## Delivery tickets

### MACV2-01 Freeze completion specification and traceability

GitHub: [#37](https://github.com/praxstack/ledger-atlas/issues/37)
Linear: [PRA-69](https://linear.app/prax-lannister/issue/PRA-69)
Blocked by: none.
Acceptance: Markdown and HTML contain the full v2 contract, 33 stories, decisions, five seams, 23 linked tickets, assumptions, and exclusions; parity and tracker publication checks pass.

### MACV2-02 Launch the sandboxed Mac app and widget container

GitHub: [#38](https://github.com/praxstack/ledger-atlas/issues/38)
Linear: [PRA-72](https://linear.app/prax-lannister/issue/PRA-72)
Blocked by: MACV2-01.
Acceptance: the app and widget launch under sandboxing, and the shared container contains only a redacted projection.

### MACV2-03 Create, open, and upgrade a ledger

GitHub: [#39](https://github.com/praxstack/ledger-atlas/issues/39)
Linear: [PRA-68](https://linear.app/prax-lannister/issue/PRA-68)
Blocked by: MACV2-02.
Acceptance: interrupted, invalid, or unsupported migration leaves the original ledger unchanged and older packages still decode.

### MACV2-04 Manage accounts and account groups

GitHub: [#40](https://github.com/praxstack/ledger-atlas/issues/40)
Linear: [PRA-70](https://linear.app/prax-lannister/issue/PRA-70)
Blocked by: MACV2-03.
Acceptance: totals, reports, and search honor every account state.

### MACV2-05 Manage arbitrary-depth category trees

GitHub: [#41](https://github.com/praxstack/ledger-atlas/issues/41)
Linear: [PRA-71](https://linear.app/prax-lannister/issue/PRA-71)
Blocked by: MACV2-03.
Acceptance: cycles and destructive parent operations fail atomically, and ancestor roll-up never double-counts.

### MACV2-06 Enter and edit income or single-category expenses

GitHub: [#42](https://github.com/praxstack/ledger-atlas/issues/42)
Linear: [PRA-73](https://linear.app/prax-lannister/issue/PRA-73)
Blocked by: MACV2-04 and MACV2-05.
Acceptance: duplicate submission is idempotent and stale revisions remain visible conflicts.

### MACV2-07 Split one expense across multiple categories

GitHub: [#43](https://github.com/praxstack/ledger-atlas/issues/43)
Linear: [PRA-74](https://linear.app/prax-lannister/issue/PRA-74)
Blocked by: MACV2-06.
Acceptance: lines equal the total in one currency, any failure rolls back the group, existing tuple callers remain compatible, and the UI presents one expandable purchase.

### MACV2-08 Create transfers, FX conversions, and fees

GitHub: [#44](https://github.com/praxstack/ledger-atlas/issues/44)
Linear: [PRA-75](https://linear.app/prax-lannister/issue/PRA-75)
Blocked by: MACV2-04, MACV2-05, and MACV2-06.
Acceptance: invalid currency, account, rate, or fee leaves every account unchanged.

### MACV2-09 Browse, search, and edit the transaction ledger

GitHub: [#45](https://github.com/praxstack/ledger-atlas/issues/45)
Linear: [PRA-78](https://linear.app/prax-lannister/issue/PRA-78)
Blocked by: MACV2-06, MACV2-07, and MACV2-08.
Acceptance: a 100000-entry synthetic ledger stays paged and meets the accepted response targets.

### MACV2-10 Inspect statistics and export PDF statements

GitHub: [#46](https://github.com/praxstack/ledger-atlas/issues/46)
Linear: [PRA-76](https://linear.app/prax-lannister/issue/PRA-76)
Blocked by: MACV2-05 and MACV2-09.
Acceptance: split lines count once and every aggregate reconciles to one immutable report snapshot.

### MACV2-11 Plan budgets, recurrence, and installments

GitHub: [#47](https://github.com/praxstack/ledger-atlas/issues/47)
Linear: [PRA-77](https://linear.app/prax-lannister/issue/PRA-77)
Blocked by: MACV2-04, MACV2-05, and MACV2-09.
Acceptance: generated entries remain exact and idempotent across restart and restore.

### MACV2-12 Attach receipts and confirm local OCR suggestions

GitHub: [#48](https://github.com/praxstack/ledger-atlas/issues/48)
Linear: [PRA-79](https://linear.app/prax-lannister/issue/PRA-79)
Blocked by: MACV2-06 and MACV2-09.
Acceptance: OCR cannot write financial truth without confirmation and private content never enters tracked output or logs.

### MACV2-13 Configure locale and product behavior

GitHub: [#49](https://github.com/praxstack/ledger-atlas/issues/49)
Linear: [PRA-80](https://linear.app/prax-lannister/issue/PRA-80)
Blocked by: MACV2-03 and MACV2-05.
Acceptance: formatted display strings are never reparsed into canonical truth.

### MACV2-14 Lock and redact the product

GitHub: [#50](https://github.com/praxstack/ledger-atlas/issues/50)
Linear: [PRA-81](https://linear.app/prax-lannister/issue/PRA-81)
Blocked by: MACV2-02, MACV2-03, and MACV2-13.
Acceptance: app, widget, notifications, portal, and app switcher reveal no private content while locked.

### MACV2-15 Back up, restore, exchange XLSX, and reset safely

GitHub: [#51](https://github.com/praxstack/ledger-atlas/issues/51)
Linear: [PRA-82](https://linear.app/prax-lannister/issue/PRA-82)
Blocked by: MACV2-03, MACV2-07, MACV2-08, MACV2-11, and MACV2-12.
Acceptance: two restore cycles preserve canonical checksum and attachments, and every interrupted path preserves the existing ledger.

### MACV2-16 Build the synthetic Money Manager oracle harness

GitHub: [#52](https://github.com/praxstack/ledger-atlas/issues/52)
Linear: [PRA-83](https://linear.app/prax-lannister/issue/PRA-83)
Blocked by: MACV2-01.
Acceptance: the harness reports schemas, counts, structural differences, and hashes without copying or logging source values.

### MACV2-17 Run the owner-assisted Money Manager oracle session

GitHub: [#53](https://github.com/praxstack/ledger-atlas/issues/53)
Linear: [PRA-84](https://linear.app/prax-lannister/issue/PRA-84)
Blocked by: MACV2-16 and the product owner.
Acceptance: each conclusion has an action record, before/after synthetic backup pair, structural diff, and versioned decision.

### MACV2-18 Certify the supplied v19 import and representable export

GitHub: [#54](https://github.com/praxstack/ledger-atlas/issues/54)
Linear: [PRA-85](https://linear.app/prax-lannister/issue/PRA-85)
Blocked by: MACV2-03, MACV2-05, MACV2-08, MACV2-15, and MACV2-17.
Acceptance: source hashes remain unchanged, duplicates and orphans are zero, every source item is accounted for, and unsupported vendor export fails visibly without flattening or loss.

### MACV2-19 Ship the widget and five App Intents

GitHub: [#55](https://github.com/praxstack/ledger-atlas/issues/55)
Linear: [PRA-86](https://linear.app/prax-lannister/issue/PRA-86)
Blocked by: MACV2-07, MACV2-08, MACV2-14, and MACV2-15.
Acceptance: the widget never writes the canonical database and locked writes open authentication.

### MACV2-20 Ship localhost access, notifications, and diagnostics

GitHub: [#56](https://github.com/praxstack/ledger-atlas/issues/56)
Linear: [PRA-87](https://linear.app/prax-lannister/issue/PRA-87)
Blocked by: MACV2-10, MACV2-13, MACV2-14, and MACV2-15.
Acceptance: the portal has no mutation routes and stops on lock, sleep, inactivity, or ledger switch.

### MACV2-21 Close synthetic UI, accessibility, privacy, and performance proof

GitHub: [#57](https://github.com/praxstack/ledger-atlas/issues/57)
Linear: [PRA-88](https://linear.app/prax-lannister/issue/PRA-88)
Blocked by: MACV2-09 through MACV2-15 and MACV2-18 through MACV2-20.
Acceptance: every traceability entry and required state has a passing privacy-safe capture and executable check.

### MACV2-22 Run the private supplied-corpus delivery proof

GitHub: [#58](https://github.com/praxstack/ledger-atlas/issues/58)
Linear: [PRA-89](https://linear.app/prax-lannister/issue/PRA-89)
Blocked by: MACV2-17, MACV2-18, MACV2-21, and owner-authorized private evidence access.
Acceptance: source hashes remain unchanged, aggregate receipts contain no private values, and the named profile certificate matches the tested bytes and adapter version.

### MACV2-23 Build and smoke-test the delivery DMG

GitHub: [#59](https://github.com/praxstack/ledger-atlas/issues/59)
Linear: [PRA-90](https://linear.app/prax-lannister/issue/PRA-90)
Blocked by: MACV2-22 and release credentials.
Acceptance: the external release receipt matches the commit and artifact hashes, and every installed smoke scenario passes.

## Traceability

| Contract area | User stories | Delivery tickets | Primary test seam |
|---|---|---|---|
| App container and ledger lifecycle | US-01, US-02 | MACV2-02, MACV2-03 | TS-02, TS-04 |
| Accounts and categories | US-03 through US-05 | MACV2-04, MACV2-05 | TS-01, TS-04 |
| Daily transactions | US-06 through US-16 | MACV2-06 through MACV2-09 | TS-01, TS-04 |
| Reports and PDF | US-17, US-18 | MACV2-10 | TS-01, TS-04 |
| Planning | US-19 through US-21 | MACV2-11 | TS-01, TS-02 |
| Attachments and OCR | US-22, US-23 | MACV2-12 | TS-01, TS-02 |
| Settings and lock | US-24 through US-26 | MACV2-13, MACV2-14 | TS-01, TS-04 |
| Backup, exchange, and reset | US-27, US-28 | MACV2-15 | TS-02 |
| Money Manager compatibility | US-29 | MACV2-16 through MACV2-18, MACV2-22 | TS-03, TS-05 |
| Widget and integrations | US-30 through US-32 | MACV2-19, MACV2-20 | TS-04 |
| Product proof and delivery | US-33 | MACV2-21 through MACV2-23 | TS-05 |

### Synchronized project artifacts

- `CONTEXT.md` states the current unshipped implementation boundary and links this release-one contract.
- `SPEC.md` points milestone-two completion work at this v2 contract and records plaintext release-one backup scope.
- `prd.json` records this specification and the MACV2 dependency graph.
- [Screenshot functional parity v1](screenshot-functional-parity-v1.md) defers release-one conflicts to this v2 contract.
- [Screenshot traceability v1](screenshot-traceability-v1.json) records the 25 private-source filenames and future synthetic capture targets.
- `.scratch/ledger-atlas-end-to-end/issues/` holds one recovery Markdown file per ticket.

### Status boundary

This contract and its tracker graph are published. Product implementation, real-v19 certification, private delivery proof, signing, notarization, installation, smoke proof, and shipment remain incomplete until their tickets close with current evidence.
