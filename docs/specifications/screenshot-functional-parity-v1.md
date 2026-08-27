# Ledger Atlas Screenshot Functional Parity and Real-Data Population Specification

Status: Reviewed v1; implementation not started
Date: 2026-08-26
Scope: Native macOS product, 25 supplied Money Manager Android screenshots, and the supplied Android v19 reference corpus

Release-one authority: `ledger-atlas-mac-completion-v2.md` governs scope conflicts.
In particular, release-one backups are warned plaintext mode-0600 packages, the
local portal binds to loopback, and browser ledger editing is excluded.

## 1. Problem Statement

Ledger Atlas has a substantial canonical ledger and synthetic test candidate, but the native app does not expose the complete user workflows visible in the supplied Money Manager screenshots. The exact supplied Android v19 database is recognized but does not populate a Ledger Atlas ledger.

This specification solves four concrete problems:

1. Every supplied screenshot needs an exact, auditable functional destination in Ledger Atlas.
2. Every visible control needs a real action, state transition, or explicit non-goal. Dead controls are forbidden.
3. The supplied Android v19 data needs to populate the canonical ledger used by those screens without omissions, duplicates, or unsupported guesses.
4. Product completion needs proof from persisted behavior, reconciliation, accessibility, and synthetic UI captures rather than backend-command counts.

Important boundary:

- Functional parity means equivalent user capability, information hierarchy, and state coverage.
- Functional parity does not mean copying Money Manager branding, advertising, icons, layout pixels, or proprietary creative assets.
- The 25 source screenshots remain read-only private evidence outside the product repository.
- A screenshot proves visible state only. Hidden calculations and persistence behavior require database, ledger, and round-trip oracles.

## 2. Evidence Authority

### 2.1 Primary evidence

1. Restricted screenshots:
   - Root: `/Users/prax/Developer/money-manager-reverse-engineering/docs/real-app-screenshots/`
   - Count: `25`
   - Pixel size: `1080 x 2392`
   - Product processes must not copy these files into this repository.

2. Direct screenshot checklist:
   - `docs/specifications/screenshot-traceability-v1.json` is the machine-readable source of truth.
   - Section 7 is its human-readable summary.
   - The manifest records every exact filename, route, state, visible control, private root, and future synthetic capture path.

3. Supporting per-control research:
   - `waves/pass-01/batch-a.md`
   - `waves/pass-01/batch-b.md`
   - `waves/pass-01/batch-c.md`

4. Functional and oracle matrix:
   - `waves/pass-02/functional-coverage.md`

5. Supplied reference corpus:
   - `/Users/prax/Developer/money-manager-reverse-engineering/reference/2026-08-26/`
   - Five overlapping XLSX report exports
   - One Android SQLite v19 database
   - One ZIP backup whose database payload is byte-identical to the supplied SQLite database

### 2.2 Evidence grades

- `O` (observed): visible in a supplied screenshot.
- `D` (documented): described by captured official documentation but not visible in the supplied screenshots.
- `B` (data-backed): required by the supplied v19 schema or aggregate manifest.
- `I` (inferred): needed to connect observed states but not directly demonstrated.
- `U` (unknown): exact vendor behavior lacks evidence.

An `O`, `D`, or `B` grade does not prove persistence or financial semantics. Ledger Atlas must implement explicit behavior and test it independently.

## 3. Goals and Non-Goals

### 3.1 Goals

1. Map all 25 screenshots exactly once to 14 native route families and their state variants.
2. Implement every visible non-advertising control as a working native interaction.
3. Implement the five visible transaction modes: Daily, Calendar, Monthly, Total, and Note.
4. Implement statistics overview, category drill-down, and total-balance analytics with accessible table alternatives.
5. Implement account overview, account editing, account creation, group management, account visibility, and include-in-totals behavior.
6. Implement configuration, passcode, local web access, and backup hub entry points shown in the screenshots.
7. Populate all supported screens from the exact supplied Android v19 data.
8. Preserve unsupported source data with provenance and block certification on unexplained loss.
9. Capture privacy-safe synthetic Ledger Atlas screenshots for every required route and state.
10. Prove import, edit, search, report, backup, restore, reopen, and reconciliation in one end-to-end smoke run.

### 3.2 Non-goals

1. Reproduce Money Manager advertising. Ledger Atlas remains ad-free.
2. Copy Money Manager branding, wordmarks, icons, typography, or exact pixel layout.
3. Claim iOS, historical Android, or universal compatibility without separate named evidence cells.
4. Infer unknown vendor behavior from a static icon or hidden screenshot chrome.
5. Use binary floating point for money.
6. Place real financial values, names, notes, photos, or screenshots in tracked fixtures, logs, prompts, or test output.
7. Treat public backend commands as proof that the corresponding native user workflow exists.

## 4. Completion Vocabulary

- `mapped`: a screenshot has one declared Ledger Atlas route/state counterpart.
- `wired`: every visible control reaches its declared action or state.
- `persisted`: the action survives close and reopen of the ledger.
- `reconciled`: the resulting canonical records and derived totals match the declared oracle.
- `captured`: a synthetic privacy-safe Ledger Atlas screenshot exists for the route/state.
- `screen-complete`: mapped, wired, persisted where applicable, accessible, captured, and tested.
- `profile-certified`: the named source profile passes structural, semantic, reconciliation, negative, and round-trip checks.
- `delivery-complete`: every required screen is screen-complete, the exact supplied profile is certified, all checks pass, and the delivered code is committed.

No weaker state may be reported as complete.

## 5. System Components

### 5.1 `LedgerAtlasRootView`

Owns the macOS window shell, native sidebar, toolbar, route presentation, sheets, alerts, keyboard commands, and accessibility focus.

Must not calculate balances, mutate SQLite directly, parse Money Manager rows, or own duplicate ledger-open state.

### 5.2 `LedgerJourney`

Owns onboarding, source review, destination selection, import approval, ledger opening, and transition into the editable product session.

Must not render generic string rows as a substitute for typed product screens.

### 5.3 `LedgerSession`

Owns the currently opened ledger identity, selected route, query state, user presentation settings, and refresh snapshots.

Exactly one object owns open-ledger state.

### 5.4 `LedgerApplication`

Owns typed financial commands and queries. Every native mutation routes through this boundary.

### 5.5 `LedgerStore`

Owns descriptor-bound canonical SQLite access, schema migration, transactions, rollback, checksums, backup, and restore.

### 5.6 `MMImport`

Owns immutable Money Manager classification, staging, adapter mapping, provenance, sidecars, reconciliation, certification, and atomic canonical commit.

Vendor schema names and codes must not escape this component.

### 5.7 `PresentationModels`

Owns typed screen projections for transactions, statistics, accounts, settings, backup, security, and local web access.

Presentation models contain formatted display strings and stable canonical identifiers. Formatted values must never be parsed back into canonical truth.

### 5.8 `UISmokeArtifacts`

Owns synthetic test-ledger setup, deterministic route navigation, accessibility-tree capture, and PNG capture of Ledger Atlas screens.

The component must never read or embed the 25 private source PNGs.

## 6. Core Contract Types

### 6.1 `ScreenshotEvidence`

- `filename` (`string`, required): exact source filename. `screenshot_id` is derived by removing the extension.
- `route_id` (`ScreenRouteID`, required): exactly one route from Section 7.
- `state_id` (`string`, required): deterministic route variant.
- `evidence_grade` (`enum`, manifest default `observed`): `observed`, `documented`, `data_backed`, `inferred`, or `unknown`.
- `visible_control_ids` (`array<string>`, required): empty only when the screenshot contains no actionable control.
- `private_source_path` (derived): manifest `private_root` joined with `filename`; it must resolve outside the product repository in the private verification profile.
- `synthetic_capture_path` (`string or null`, default `null`): tracked privacy-safe Ledger Atlas capture after implementation. `null` is valid while the screen remains incomplete.

Validation:

- Every supplied screenshot filename appears exactly once and matches the current read-only directory inventory.
- The checked-in manifest matches the fixed non-sensitive filename inventory. The optional private profile also verifies the current read-only directory contents.
- No derived `private_source_path` is under the Ledger Atlas repository root.
- Every `visible_control_id` belongs to the manifest's closed `control_contract_ids` registry and corresponds to a Section 8 contract.

### 6.2 `ScreenRouteID`

Closed enum for the first parity release:

1. `transactions.daily`
2. `statistics.overview`
3. `statistics.category_detail`
4. `statistics.total_balance`
5. `accounts.overview`
6. `accounts.account_info`
7. `settings.configuration`
8. `settings.accounts`
9. `settings.account_groups`
10. `settings.account_list`
11. `accounts.add`
12. `security.set_passcode`
13. `local_web_access.idle`
14. `backup.hub`

Additional documented screens may ship, but they do not replace any required route.

### 6.3 `ScreenState`

- `phase` (`enum`, required): `idle`, `loading`, `progress`, `success`, `retryable_error`, `terminal_error`, `empty`, or `locked`.
- `selection` (`set<string>`, default empty): selected stable identifiers.
- `query` (`string`, default empty, maximum 512 UTF-8 bytes).
- `period` (`PeriodSelection or null`, default `null`).
- `is_dirty` (`boolean`, default `false`).
- `focus_target` (`string or null`, default `null`).
- `error` (`ProductError or null`, default `null`).

### 6.4 `PeriodSelection`

- `kind` (`enum`, required): `day`, `week`, `month`, `year`, or `custom`.
- `start_local_date` (`YYYY-MM-DD`, required).
- `end_local_date` (`YYYY-MM-DD`, required).
- `timezone_id` (`IANA timezone string`, required).
- `calendar_id` (`string`, default `gregorian`).

Validation:

- `end_local_date` must not precede `start_local_date`.
- Period boundaries derive from stored user settings and never from UTC truncation.

### 6.5 `SourceEffectIdentity`

- `source_profile_id` (`string`, required).
- `source_table` (`string`, required).
- `source_record_id` (`string`, required): stable literal source identifier.
- `effect_ordinal` (`unsigned integer`, required): starts at `0`, unique within one source record.
- `canonical_effect_id` (`string`, required): deterministic hash of the four preceding fields and adapter version.
- `effect_role` (`enum`, required): `primary`, `counterparty`, `fee`, `tax`, `rounding`, `installment`, `card_settlement`, `budget`, `recurrence`, `attachment`, `tag`, `memo`, or `opaque_preservation`.

One source record may produce many effects. One canonical effect must have exactly one source anchor for the import being certified.

### 6.6 `ProductError`

- `code` (`ProductErrorCode`, required).
- `message_key` (`string`, required): localizable key without private values.
- `recovery` (`enum`, required): `retry`, `review_source`, `change_input`, `choose_destination`, `authenticate`, `restore_backup`, or `contact_support`.
- `is_retryable` (`boolean`, required).
- `diagnostic_id` (`UUID string`, required): content-free correlation identifier.

## 7. Screenshot-to-Route Traceability

| # | Screenshot suffix | Ledger Atlas route | Required state |
|---:|---|---|---|
| 1 | `003508` | `transactions.daily` | dark, populated, free-source-ad omitted, root navigation visible |
| 2 | `003514` | `statistics.overview` | monthly expense |
| 3 | `003520` | `statistics.overview` | annual expense |
| 4 | `003523` | `statistics.overview` | annual income, scrolled content |
| 5 | `003528` | `statistics.category_detail` | annual income, category |
| 6 | `003532` | `statistics.category_detail` | preserved anomaly reference; canonical route must not reproduce clipping |
| 7 | `003539` | `statistics.category_detail` | annual expense, subcategory |
| 8 | `003550` | `statistics.total_balance` | monthly total-balance trend |
| 9 | `003555` | `accounts.overview` | upper scroll, card rows, totals |
| 10 | `003600` | `accounts.overview` | card and savings groups |
| 11 | `003604` | `accounts.overview` | active scroll, lower groups |
| 12 | `003608` | `accounts.overview` | restored chrome equivalent |
| 13 | `003612` | `accounts.overview` | investments to others boundary |
| 14 | `003616` | `accounts.account_info` | existing account edit |
| 15 | `003623` | `settings.configuration` | configuration index |
| 16 | `003632` | `settings.accounts` | accounts configuration index |
| 17 | `003635` | `settings.account_groups` | add, edit, delete/protected, reorder |
| 18 | `003641` | `settings.account_list` | upper scroll, dimmed or hidden variant |
| 19 | `003644` | `settings.account_list` | tail scroll |
| 20 | `003649` | `accounts.add` | group picker open |
| 21 | `003652` | `accounts.add` | name focused, keyboard-visible equivalent |
| 22 | `003703` | `accounts.account_info` | savings account edit |
| 23 | `003726` | `security.set_passcode` | first passcode entry, zero digits |
| 24 | `003736` | `local_web_access.idle` | passcode off, service stopped |
| 25 | `003741` | `backup.hub` | all backup, import, export, help, and reset entries visible |

Structural traceability fails if the set contains fewer or more than 25 records, a filename appears twice, or the route set differs from the 14 required families. Delivery traceability additionally fails when any required synthetic capture is still `null`.

The ordinary verifier checks the non-sensitive manifest without opening private files.
On the evidence-owning Mac, run the explicit private inventory check:

```sh
LEDGER_ATLAS_VERIFY_PRIVATE_EVIDENCE=1 .venv/bin/python -m pytest tests/orchestration/test_screenshot_traceability.py
```

## 8. Route Functional Contracts

### 8.1 Transactions

#### 8.1.1 Daily

The Daily route must provide:

1. Previous and next period controls.
2. Current month and year label.
3. Favourites, search, and filter actions.
4. Daily, Calendar, Monthly, Total, and Note mode controls in that order.
5. Income, expense, and net totals for the selected period.
6. Recurrence preview with next due date and amount.
7. Date-grouped transaction rows with category, subcategory, description, time, account, semantic amount, and indicators for transfer, note, photo, recurrence, correction, and deletion.
8. Add Income, Add Expense, Add Transfer, and Quick Add actions.
9. Empty, active-filter, no-result, loading, and error states.

Selecting a transaction opens typed detail. Editing, copying, correcting, tombstoning, and attachment actions must persist through `LedgerApplication`.

#### 8.1.2 Calendar

The Calendar mode must render a month grid, daily income/expense/net values, selected-day ledger, adjacent-month navigation, today marker, empty day, week-start setting, and accessible list alternative.

#### 8.1.3 Monthly

The Monthly mode must group entries by month, show income/expense/net per month, expand contributing entries, and honor hidden-account and include-in-totals rules.

#### 8.1.4 Total

The Total mode must show exact income, expense, transfer-neutral net, and balance movement for the selected range with contributing rows.

#### 8.1.5 Note

The Note mode must list transaction notes and standalone memos, support search and pinning, and preserve source linkage.

### 8.2 Statistics overview

The Statistics overview must provide month, week, year, and custom range selection; income and expense segments; category distribution; ranked category rows; selected-slice state; empty state; and an accessible data table.

Percentage calculation:

```text
function category_percent(category_amount, included_total):
  if included_total == 0:
    return 0
  return round_half_even(category_amount / included_total * 100, 1)
```

Ranking order is exact absolute amount descending, canonical category order ascending, then stable category identifier ascending.

### 8.3 Statistics category detail

The Category Detail route must show selected category/subcategory, period controls, aggregate total, All/category/subcategory breakdown, time trend, contributing transactions, back navigation, and return-position preservation.

The clipped screenshot suffix `003532` is evidence of an anomalous capture. Ledger Atlas must not reproduce clipped content as intended layout.

### 8.4 Total-balance analytics

The Total Balance route must show included account scope, selected period, total balance, trend, contributing entries, liability signs, multi-currency valuation status, and accessible table alternative.

The launch action is Ledger Atlas Accounts toolbar `Show Balance History`. This resolves the unknown vendor launch route without claiming vendor equivalence.

### 8.5 Accounts overview

The Accounts route must provide:

1. Assets, liabilities, and net totals.
2. Group totals and collapsible group sections.
3. Standard account rows with one balance.
4. Card rows with payable and outstanding balances.
5. Hidden, excluded-from-totals, deleted, zero, negative, and unsupported-variant states.
6. Add Account, Manage Accounts, Manage Groups, and Show Balance History actions.
7. Stable scroll and selection state.

Advertising space visible in source screenshots is intentionally omitted.

### 8.6 Account information and add account

Fields:

- `group_id` (`CanonicalID`, required).
- `name` (`UTF-8 string`, required, 1 to 256 bytes after trimming).
- `opening_amount` (`ExactDecimal`, required, default `0`).
- `description` (`UTF-8 string`, optional, default empty, maximum 4096 bytes).
- `currency_code` (`ISO-4217 or registered custom code`, required).
- `include_in_totals` (`boolean`, default `true`).
- `is_hidden` (`boolean`, default `false`).
- `variant` (`enum`, default `standard`): `standard`, `card`, `loan`, `overdraft`, `investment`, `insurance`, or `prepaid`.

Create and edit must validate before mutation. Closing a dirty form requires Save, Discard, or Cancel. Delete means canonical tombstone unless a separate empty-history permanent-delete precondition passes.

The group picker must expose the 11 observed source classifications through independently named Ledger Atlas groups or explicit preserved-source labels.

### 8.7 Configuration

The Configuration route must provide working destinations for:

1. Income categories.
2. Expense categories.
3. Subcategory hierarchy.
4. Budgets.
5. Recurrence.
6. Currencies and rates.
7. Start screen.
8. Monthly start day.
9. Weekly start day.
10. Carry-over.
11. Swipe or keyboard quick action.
12. Income and expense colors.
13. Appearance.
14. Locale, date, time, and number presentation.
15. Notifications and reminders.

Every row must open a typed screen. A generic text row with no action fails conformance.

### 8.8 Account administration

The Account Settings route must provide grouped account rows, create, edit, hide/show, include/exclude from totals, reorder, tombstone, restore, and deleted-item destinations.

The Group Manager must provide add, rename, reorder, hide, tombstone, restore, and protected-group states. Category and account group cycles are invalid.

### 8.9 Passcode

The app-lock flow must provide set, confirm, mismatch, unlock, wrong attempt, lockout, change, remove, biometric fallback, background lock, and accessibility states.

Security contract:

- Passcode secret and attempt counters live in Keychain.
- Plain passcode digits never enter logs, analytics, crash text, screenshots, or SQLite.
- Five failed attempts lock for 60 seconds.
- Ten failed attempts lock for 900 seconds.
- A successful unlock resets the failure counter.
- Biometric failure falls back to passcode and never bypasses lockout.

### 8.10 Local web access

The Local Web Access route replaces the observed PC Manager capability with a secure independent implementation.

Defaults:

- `enabled`: `false`.
- `bind_scope`: `loopback`.
- `session_idle_timeout_seconds`: `900`.
- `maximum_failed_logins`: `5` per 15 minutes per source address.
- `maximum_concurrent_sessions`: `2`.

Required states: idle, starting, running, stopping, stopped, permission denied, no network, address changed, port unavailable, authentication failed, and session expired.

Browser CRUD is not certified by screenshot `003736`. It becomes required only when the browser surface is implemented and independently tested. The idle screen must not imply unsupported browser functionality.

### 8.11 Backup hub

The Backup Hub must provide distinct routes for:

1. Scheduled backup to a user-selected durable folder, including mounted cloud-synced folders.
2. Create local backup.
3. Restore local backup.
4. Share backup through the system share service.
5. XLSX report export.
6. XLSX or TSV import with preview and duplicate policy.
7. Photo sidecar export.
8. Photo sidecar import.
9. Backup help.
10. Complete reset.
11. Contents-only reset.

Every destructive or importing route must expose preview, confirm, progress, cancel where safe, success, retryable error, terminal error, and rollback result.

Release-one backup creation shows a plaintext warning, writes a checksum manifest,
and publishes atomically with mode `0600`. Encryption is outside release-one scope.

Complete reset creates a new empty ledger and atomically swaps it into place after authentication. Contents-only reset preserves user presentation settings and removes canonical financial content through the same create-and-swap boundary.

## 9. User Configuration

### 9.1 Settings fields

- `start_screen` (`enum`, default `transactions.daily`): any root route shipped by the app.
- `month_start_day` (`integer`, default `1`, valid `1...28`).
- `week_start_day` (`integer`, default captured system calendar first weekday, valid `1...7`).
- `carry_over_enabled` (`boolean`, default `false`).
- `quick_action` (`enum`, default `change_date`): `change_date`, `copy`, `correct`, or `none`.
- `income_color_role` (`enum`, default `positive`).
- `expense_color_role` (`enum`, default `negative`).
- `appearance` (`enum`, default `system`): `system`, `light`, or `dark`.
- `locale_identifier` (`string`, default captured system locale identifier).
- `timezone_identifier` (`IANA string`, default captured system timezone identifier).
- `date_style` (`enum`, default `locale_short`): `locale_short`, `iso8601`, `day_month_year`, or `month_day_year`.
- `time_style` (`enum`, default `locale`): `locale`, `hour12`, or `hour24`.
- `privacy_redaction_enabled` (`boolean`, default `true`).
- `reduced_motion_override` (`enum`, default `system`): `system`, `on`, or `off`.

System-derived defaults are captured at ledger creation and stored. Later system changes require explicit user confirmation before changing report boundaries or canonical presentation settings.

### 9.2 Settings validation

Invalid settings do not replace the last known good value. The app displays `invalid_setting_value` and focuses the invalid control.

## 10. Real Android v19 Import Contract

### 10.1 Source handling

1. Open SQLite with read-only and immutable flags.
2. Hash the source before inspection and after completion.
3. Reject any source-byte change.
4. Stage into an isolated private database.
5. Record every source table, row, column, relationship, archive member, and attachment reference.
6. Treat the ZIP payload and byte-identical SQLite as two access routes to one source payload, not two independent ledgers.
7. Treat XLSX files as overlapping report views, not authoritative append sources.

### 10.2 One-to-many mapping algorithm

```text
function map_source_record(profile, table, source_record):
  source_anchor = stable_anchor(profile, table, source_record.primary_key)
  mapping = adapter.map(source_record)

  if mapping.is_ambiguous:
    preserve_all_fields_in_sidecar(source_anchor)
    block_certification("ambiguous_source_semantics")
    return

  if mapping.effects.is_empty and not mapping.intentional_exclusion:
    block_certification("unaccounted_source_record")
    return

  for effect_ordinal, effect in enumerate(mapping.effects):
    effect_id = stable_effect_id(
      profile.id,
      table.name,
      source_record.primary_key,
      effect_ordinal,
      adapter.version
    )
    persist_effect(effect_id, source_anchor, effect_ordinal, effect)

  preserve_unknown_fields_in_sidecar(source_anchor, mapping.unknown_fields)
  record_reconciliation_outcome(source_anchor, mapping)
```

Rules:

- Re-importing identical bytes produces identical canonical effect identifiers.
- A transfer produces linked source and destination effects.
- A fee produces its own linked effect.
- FX preserves source amount, destination amount, both currencies, rate literal, rounding rule, and fee.
- Splits preserve one source anchor and deterministic child effect ordinals.
- Installments preserve the source purchase, schedule, and generated-effect relationships.
- Unknown transaction type `7` is preserved and blocks certification unless an accepted semantic oracle exists.
- Deleted rows preserve tombstone state and relationships.
- Photo metadata without bytes becomes an unresolved attachment, never a successful attachment import.

### 10.3 Import lifecycle

States:

1. `selected`
2. `classified`
3. `staged`
4. `reviewed`
5. `approved`
6. `committing`
7. `committed`
8. `reconciled`
9. `certified`
10. `blocked`
11. `failed`
12. `cancelled`

Transitions:

- Select source: `selected`.
- Immutable profile match: `selected -> classified`.
- Complete inventory: `classified -> staged`.
- Coverage and destination review: `staged -> reviewed`.
- Explicit local approval: `reviewed -> approved`.
- Begin descriptor-bound transaction: `approved -> committing`.
- Atomic write succeeds: `committing -> committed`.
- Source and canonical oracle passes: `committed -> reconciled`.
- Every required profile check passes: `reconciled -> certified`.
- Unknown or unaccounted source data: any pre-commit state -> `blocked`.
- Error before commit: active state -> `failed`, canonical destination unchanged.
- Cancellation before commit: active state -> `cancelled`, canonical destination unchanged.

No failed, blocked, or cancelled import may partially mutate the destination ledger.

### 10.4 Reconciliation requirements

The private reconciliation receipt must contain aggregate values only:

- Source table count.
- Source row count by table.
- Mapped row count.
- Sidecar-preserved row and field counts.
- Intentionally excluded count with reason codes.
- Blocking count with reason codes.
- Canonical entity and effect counts.
- Source-record to canonical-effect cardinality histogram.
- Duplicate canonical effect count, required `0`.
- Orphaned relationship count, required `0`.
- Account balance comparison result.
- Income, expense, transfer, fee, and net comparison results.
- XLSX multiset comparison result per overlapping date range.
- Source hash before and after.
- Destination checksum before import, after import, after backup, and after two restores.

No personal content may appear in the receipt.

## 11. Error Model and Recovery

| Error code | Trigger | Recovery | Destination mutation |
|---|---|---|---|
| `unsupported_source_profile` | No named adapter matches | Review source or add a versioned adapter | None |
| `source_changed_during_import` | Before/after source hash differs | Stop and reselect immutable source | None |
| `ambiguous_source_semantics` | A row cannot be mapped safely | Preserve sidecar and obtain oracle | None |
| `unaccounted_source_record` | Row has no effect, sidecar, exclusion, or blocker | Fix adapter | None |
| `duplicate_canonical_effect` | Stable effect ID already represents different bytes | Stop and review source | None |
| `orphaned_relationship` | Linked canonical object is missing | Stop and fix mapping | None |
| `balance_mismatch` | Reconciled account/report totals differ | Stop and inspect aggregate diff | Roll back import |
| `destination_not_empty` | Fresh-import mode targets non-empty ledger | Choose new destination or explicit merge workflow | None |
| `backup_integrity_failed` | Hash or manifest validation fails | Reject backup | None |
| `restore_version_unsupported` | Package version is newer than supported | Keep destination unchanged | None |
| `permission_denied` | User denies file, photo, notification, local-network, or biometric permission | Explain and offer system-settings path | None |
| `validation_failed` | Form field fails typed validation | Keep form state and focus invalid field | None |
| `save_conflict` | Stored revision changed since editing began | Reload, compare, and create a correction | None |
| `keychain_unavailable` | Security secret cannot be read or written | Keep app locked and retry after Keychain recovery | None |
| `local_web_access_failed` | Service cannot bind or loses network | Stop service, invalidate sessions, show retry | None |

All diagnostics use content-free codes and UUIDs. Private values are forbidden in logs and error text.

## 12. Security, Privacy, and Accessibility

1. Real backups and screenshots stay outside the writable product repository.
2. Routine tests use synthetic fixtures only.
3. Financial truth uses exact decimal or integer minor units.
4. File access uses security-scoped URLs where required and releases access deterministically.
5. The app never requests cloud credentials for local folder backup.
6. Local web access is disabled by default and invalidates sessions when stopped, locked, backgrounded, or moved to a different network.
7. Every screen exposes named controls, row-by-row VoiceOver navigation, visible keyboard focus, and logical focus order.
8. Charts expose equivalent tables and spoken summaries.
9. Color never carries income, expense, selection, warning, or error meaning alone.
10. Reduced motion removes non-essential animation without removing state feedback.
11. Synthetic UI captures contain no real names, institutions, amounts, notes, photos, identifiers, or network addresses.

## 13. Observability

Required content-free event fields:

- `event_name` (`string`).
- `diagnostic_id` (`UUID`).
- `route_id` (`ScreenRouteID or null`).
- `operation` (`string or null`).
- `state_from` (`string or null`).
- `state_to` (`string or null`).
- `duration_ms` (`unsigned integer or null`).
- `result` (`success`, `cancelled`, `blocked`, or `failed`).
- `error_code` (`ProductErrorCode or null`).
- `source_profile_id` (`string or null`).

Forbidden fields include source paths, account names, categories, notes, amounts, raw dates, identifiers, source rows, attachment names, and network addresses.

## 14. Validation Profiles

### 14.1 Core Product Conformance

Required for every delivery:

- All 25 screenshot records map exactly once.
- All 14 observed route families render and navigate.
- Every visible non-ad control is wired.
- Every mutation persists and reopens.
- Every route passes empty, populated, invalid, and error-state tests.
- Every route passes keyboard and VoiceOver structure tests.
- Synthetic capture exists for every required route and state.

### 14.2 Real v19 Integration Profile

Required for the supplied Android v19 claim:

- Immutable source hash passes.
- Complete table/row/field inventory passes.
- Every source item is mapped, sidecar-preserved, intentionally excluded, or blocking.
- One-to-many effect identities are stable and collision-free.
- Duplicate effects equal `0`.
- Orphaned relationships equal `0`.
- Accounts, balances, income, expenses, transfers, fees, and net reconcile.
- All five XLSX views reconcile as overlapping report views.
- Direct SQLite and ZIP routes produce identical canonical checksums.
- Two backup-and-restore cycles preserve the checksum.
- Negative and interrupted paths leave source and destination unchanged.

### 14.3 Extension Conformance

Required only for extensions that ship:

- Local web browser CRUD or any browser mutation route.
- Google Drive API integration beyond user-selected folders.
- iOS import.
- Historical Android profiles.
- Vendor-compatible backup output.
- Multi-device sync.

No extension may inherit certification from another profile or platform.

## 15. Test Matrix

| Spec area | Minimum tests |
|---|---|
| Screenshot traceability | 25 unique inputs, 25 unique mappings, 14 required route families, no private path copied into build artifacts |
| Transactions | Five modes, create income/expense/transfer, edit/copy/correct/tombstone, search/filter, recurrence, note, photo indicators |
| Statistics | Month/week/year/custom, income/expense, exact ranking, category drill-down, trend, accessible table |
| Accounts | Totals, group collapse, card rows, add/edit, group picker, visibility, totals inclusion, delete/restore, negative and multi-currency states |
| Configuration | Every visible row opens a typed destination and persists its setting |
| Passcode | Set/confirm/mismatch/unlock/lockout/change/remove/biometric fallback/restart |
| Local web access | Disabled default, start/stop, permission denial, network loss, address change, session invalidation |
| Backup hub | Scheduled folder, create, restore, share, XLSX export/import, photo sidecars, both reset scopes, interruption and rollback |
| Import mapping | Stable anchors, deterministic effect ordinals, transfers, fees, FX, splits, installments, recurrence, budgets, unknowns, tombstones |
| Reconciliation | Counts, cardinality histogram, duplicates, orphans, balances, reports, XLSX multisets, direct-vs-ZIP equality |
| Round trip | Import, edit, backup, restore twice, reopen, checksum and balance equality |
| Accessibility | VoiceOver rows, focus order, keyboard completion, 200 percent text, non-color semantics, reduced motion |
| Privacy | No real content in fixtures, logs, receipts, captures, prompts, or tracked artifacts |

## 16. Implementation Order

1. Replace generic `SurfaceRow` product presentation with typed route models and sole open-state ownership.
2. Add schema migration foundation for account flags, variants, category hierarchy, settings, security metadata, and attachment references.
3. Implement real v19 source inventory and one-to-many adapter mapping.
4. Implement transaction Daily and its four visible companion modes.
5. Implement Statistics overview, category detail, and total-balance analytics.
6. Implement Accounts overview, account info/add, group manager, and account settings.
7. Implement Configuration destinations.
8. Implement app lock.
9. Implement Backup Hub and private reconciliation surface.
10. Implement Local Web Access idle/start/stop states; keep browser CRUD excluded from release one.
11. Add synthetic UI capture harness and accessibility checks.
12. Run the supplied v19 integration profile and two-cycle restore.
13. Close independent risk-based review findings for product, finance, privacy, and accessibility changes.
14. Run full verification and create the final delivery commit.

Engineering checks may block delivery when they find a product defect. Commit paperwork
must not replace Steps 1 through 13 in product reporting.

## 17. Definition of Done

### 17.1 Screenshot parity

- [ ] All 25 screenshot records are mapped exactly once.
- [ ] All 14 observed route families are implemented.
- [ ] Every visible non-ad control works.
- [ ] All visible settings rows open working destinations.
- [ ] All required screen states have synthetic captures.
- [ ] No raw source screenshot is copied into the product repository.

### 17.2 Financial and import correctness

- [ ] The exact supplied Android v19 database imports into a fresh Ledger Atlas ledger.
- [ ] Direct SQLite and ZIP access routes create the same canonical checksum.
- [ ] Every source row, field, relationship, and archive member is accounted for.
- [ ] Stable one-to-many mapping passes for every source record.
- [ ] Duplicate canonical effect count is zero.
- [ ] Orphaned relationship count is zero.
- [ ] Account and report reconciliation passes.
- [ ] All overlapping XLSX views reconcile without being appended as new events.
- [ ] Backup and two restore cycles preserve canonical truth.

### 17.3 Product quality

- [ ] Native edit flows persist and reopen.
- [ ] All destructive flows preview consequences and fail atomically.
- [ ] Keyboard, VoiceOver, large text, high contrast, and reduced motion pass.
- [ ] Privacy scan finds no real financial content in tracked artifacts or output.
- [ ] Full tests and production build pass from a clean checkout.
- [ ] Independent risk-based review findings for high-risk changes are closed.
- [ ] Status documents match observable evidence.
- [ ] Final delivery commit exists and the worktree is clean.

## 18. Self-Review Summary

Sections: `18`
Remaining placeholders: `0`
Independent review: `Five findings closed; final re-review passed`
Implementation status: `Ready for ticketed implementation; no real-v19 certification claimed`
