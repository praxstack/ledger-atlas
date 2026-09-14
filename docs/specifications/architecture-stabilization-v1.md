# Ledger Atlas architecture stabilization

Status: accepted for implementation  
Version: 1.0  
Prepared: 2026-08-23  
Accepted: 2026-08-23  
Baseline: `ef515cbf1edb6f975da00210509abeb5fb221f4d`  
Scope posture: hold product scope; repair foundations and verified defects only

## 1. Decision summary

Ledger Atlas keeps its existing architecture: a local-first canonical SQLite ledger,
versioned Money Manager adapters at the import perimeter, exact money and time primitives,
and a native macOS client. The review found no reason to replace those boundaries.

The stabilization changes are:

1. accept the already-implemented GATE-002 candidate only after its frozen criterion,
   clean-tree verification, and independent reviews pass;
2. make canonical schema releases and migrations a LedgerStore responsibility shared by
   native opens and import commits;
3. keep the current store at schema v10 until a real product schema delta exists; do not
   create a meaningless v11 column to exercise migration code;
4. freeze the complete existing portable package as v0, then write v1 with one manifest
   version authority and the same frozen payload shape;
5. expose typed failures on their existing command, application, and store surfaces,
   leaving speculative
   category-cycle and future feature errors to the tickets that introduce them;
6. block the classification-only observed Android profile from import and require a
   user-chosen durable canonical destination before approval;
7. close the verified data-integrity, concurrency, and native-client defects already
   recorded in issue #34; and
8. replace stale status claims with evidence derived from the accepted Git history and
   current verification receipts.

No vendor semantic mapping, compatibility certification, sync, cloud, iOS product,
release, or new parity feature is part of this specification.

## 2. Governing product contract

Ledger Atlas is an independently owned, local-first personal-finance product. The
canonical ledger, rather than a Money Manager schema, is financial truth. Every imported source
subject must be mapped, preserved with provenance, visibly excluded with a reason, or
block. Real financial content and credentials remain outside the writable repository and
all tests use synthetic fixtures.

The first production client is native macOS. A future client consumes the same
vendor-independent `LedgerClient` behavior; it does not copy a vendor interface or make
the vendor format canonical.

### Success definition

This stabilization is complete when:

- the two repository gates pass from an exact clean tree;
- GATE-002 has review-backed acceptance evidence rather than file-existence evidence;
- the migration owner is canonical and reusable by both native and import write paths;
- historical schema identities and migration statements cannot drift with current DDL;
- every successful old-store migration retains a verified pre-upgrade recovery image;
- a package written before package versioning still imports after package v1 ships;
- typed failures distinguish current command conflicts without exposing private content;
- the observed Android profile remains classification-only and no approved import can
  commit to temporary storage;
- every accepted issue #34 defect has a named regression test;
- documentation states the exact commit, test, compatibility, and release status; and
- every implementation atom is committed only through `scripts/gate-commit.sh` with all
  P0 findings closed.

### Non-goals

- No schema v11 release without an economically meaningful schema delta.
- No new account flags, category hierarchy, security lock, import format, notification,
  widget, or visual redesign.
- No change to unresolved type-7 or budget-period-6 semantics.
- No L3+ or universal Money Manager compatibility claim.
- No portable export of imported receipt/provenance graphs; imported ledgers continue to
  require exact canonical SQLite backup.
- No user-facing portable-package file transport or restore affordance. The existing
  manifest-plus-payload API remains an internal/public client seam until a separate UX
  specification defines one durable artifact and destination flow.
- No push, merge, deployment, notarization, release, or protected-evidence mutation.
- No new dependency, migration framework package, ORM, or schema DSL.

## 3. Evidence reviewed

The review read the root operating contract, product context, specification, PRD,
runbook, design contract, ADRs 0007/0008/0010/0011, orchestration audits and workflows,
plans 001–003, local issue recovery pack 01–34, canonical GitHub issues 1, 2, and 26–34,
product-status files, Git history, Swift package graph, relevant source and test call
paths, and the named autonomous-agent/orchestration/research/council skills.

Verified baseline observations:

- `Package.swift` has six products/targets above CSQLite and five test targets.
- The current canonical schema is v10.
- `ImportWorkspace` performs classify → immutable stage → adapter → reconciliation →
  prepared capability → explicit approval → atomic commit.
- `mmctl` is read/review-only: inspect, coverage, stage, and reconcile; it has no commit
  command.
- `LedgerStore` owns descriptor-bound native mutation and exact schema validation, but
  schema migration execution currently lives only in `SQLiteCanonicalCommitter`.
- The Mac shell is a working candidate, not a shipped product.
- The real observed Android v19 profile remains L0/classification-only; the positive
  import cell is a distinct synthetic text-safe subset.
- On the clean baseline, `verify.sh --fast` passes with 53 Python governance tests and
  283 Swift tests. The working `main` checkout has unrelated user changes and was not
  used as candidate evidence.
- Git history contains the admission commit `cf50880` and the implementation snapshot
  `8623651`; status text claiming that no baseline commit exists is stale.

## 4. Current architecture

```text
LedgerAtlasMac executable
          |
          v
LedgerAtlasMacUI ------------------------------------+
  LedgerJourney / LedgerSession / SwiftUI            |
          |                                           | internal import
          v                                           v
      LedgerStore <------------------------------ ImportWorkspace (MMImport)
          |                                      /       |        \
          |                              classifier   staging   v19 adapter
          |                                      \       |        /
          |                                       reconciliation
          |                                             |
          +<---------------- SQLiteCanonicalCommitter --+
          |
          v
   canonical SQLite v10
          ^
          |
      LedgerCore
  exact primitives, domain models,
  schema DDL/fingerprint, provenance

mmctl ------------------------> MMImport + LedgerCore (no canonical write command)
MMFixtures -------------------> LedgerCore
CSQLite ----------------------> descriptor-bound SQLite bridge
```

### Boundaries that remain accepted

- `LedgerCore` owns vendor-independent domain truth and exact primitives.
- `LedgerStore` owns canonical SQLite access and descriptor-bound mutation.
- `MMImport` owns vendor classification, staging, mapping, and reconciliation.
- `LedgerAtlasMacUI` may use `ImportWorkspace` internally for the first adapter. Moving a
  generic import facade is deferred until a second adapter or client creates measured
  coupling pressure.
- Rebuildable reports and UI projections are not canonical truth.

### Verified architecture gaps

| ID | Severity | Gap | Evidence | Required correction |
|---|---|---|---|---|
| A1 | P0 | Historical migration definitions derive from evolving current DDL. | `CanonicalLedgerSchema.v8ToV9MigrationStatements` and `v9ToV10MigrationStatements` filter `expectedObjects`. | Freeze release-owned object groups, fingerprints, and per-step SQL. |
| A2 | P0 | Migration execution is owned by the Money Manager committer, while native LedgerStore opens reject every older release. | `SQLiteCanonicalCommitter.ensureSchema`; exact-only `LedgerStore.validateCanonicalSchema`. | Move the execution seam to LedgerStore and reuse it from both writers. |
| A3 | P1 | Issue #33 requires a v11 ALTER but defines no v11 DDL delta and omits MMImport paths that own current migration. | GitHub #33 and the uncommitted main-worktree FND-001 proposal. | Correct the ticket: build migration foundations at v10; the first real schema feature owns v11. Expand current migration-owner paths for the refactor. |
| A4 | P0 | Portable package identity is coupled to canonical schema identity, and populated-destination identity uses wire-byte SHA rather than normalized ledger content. | `LedgerExportManifest`, `LedgerCanonicalPackage`, `decodePackage`, `importPackage`. | Freeze complete v0/v1 contracts and compare normalized packages across wire versions. |
| A5 | P1 | Command-visible conflicts collapse into `incompatibleCanonicalStore` or `invalidCommand`, while the draft originally mixed command, package, and store errors. | `LedgerCommandError`, `LedgerStore.Error`, `LedgerApplication.Error`. | Preserve the three existing ownership surfaces and add only current, testable distinctions. |
| A6 | P0 | Three current data paths have injection, TOCTOU, or partial-commit risk. | Issue #34 items 1–3. | Parameterize imported IDs; move recurrence read-modify-write into one transaction; batch occurrence generation atomically and reject over-limit requests. |
| A7 | P1 | Native state has split ownership and accessibility/performance defects. | Issue #34 items 4–8. | Use one Journey owner, remove render-time export, consume existing typed domain rows directly, and unify motion state. |
| A8 | P1 | Status authorities contradict Git history and current verification. | `CONTEXT.md`, `JOURNAL.md`, `product-status.json`, status pages. | Derive one evidence-labelled status summary and mark old narrative records historical. |
| A9 | P0 | The gate cannot atomically commit its own PRD transition to `done`; it accepts only `todo`/`doing`. | `gate_commit.bind_prd_atom`; dependency readiness requires `done`. | Predeclare a manual P0 admission atom after every subject atom. It records the reviewed subject as done and admits the next frozen criterion; no subject edits its own criterion and no gate code self-edit is allowed. |
| A10 | P0 | The observed Android profile can reach a prepared import handle although the accepted compatibility claim is L0 classification-only. | `SourceProfile`, `MoneyManagerV19Adapter`, `ImportWorkspace`; `CONTEXT.md`. | Keep classification/review, but return no import capability until a named tested cell is accepted. |
| A11 | P0 | The Mac import flow supplies a canonical destination under `FileManager.temporaryDirectory`. | `LedgerAtlasRootView`; `DESIGN.md` destination step. | Require a user-chosen durable destination before preparation or approval; temporary storage is staging only. |

## 5. Target architecture

```text
                         LedgerCore
              schema releases + exact domain truth
                              |
                              v
                      LedgerStore module
       +----------------------------------------------+
       | LedgerApplication: commands + package codec |
       | LedgerStore: pinned handle, release auth,    |
       |              migration, atomic persistence   |
       +----------------------------------------------+
                ^                            ^
                |                            |
       LedgerAtlasMacUI             SQLiteCanonicalCommitter
                                             ^
                                             |
                       MMImport classify/stage/map/reconcile
```

The target adds no new architectural layer. It moves one existing responsibility to its
correct owner and gives existing serialization an independent version.

### 5.1 Canonical schema releases

`CanonicalLedgerSchema` remains in LedgerCore and exposes immutable release data:

- v8 import/provenance objects;
- v9 canonical application-ledger objects;
- v10 recurrence, budget, and installment objects;
- one `CanonicalSchemaRelease` value per release with
  `version: Int`, `applicationID: Int32`, `ledgerIdentity: String`,
  `objects: [CanonicalSchemaObject]`, `fingerprint: String`, and
  `migrationFromPrevious: [String]`; and
- explicit one-step SQL arrays for v8→v9 and v9→v10.

`expectedObjects`, `fingerprint`, and `creationStatements` describe only the current v10
release. Historical releases are assembled from frozen groups, never by filtering a
future current schema. `additiveMigrationStatements(fromVersion:)` returns exactly one
step, not a cumulative list.

The v8, v9, and v10 object inventories and SHA-256 fingerprints are literal release
constants. A v9 store is authenticated against the v9 inventory and fingerprint before
any v9→v10 statement runs. `applicationID` is `0x4C415431` and `ledgerIdentity` is
`ledger-atlas-canonical` for all three releases.

Each release also freezes ordered semantic-checksum queries for every row-bearing table
in that release except the migration-owned `ledger_meta` values. Successful migration
compares those query results before and after migration; added tables must be empty.
`ledger_meta` is checked separately: `ledger_identity` is unchanged, only
`schema_version` and `schema_fingerprint` make the exact declared old-to-new transition,
the table still has exactly those three keys, and no additional metadata appears. This
proves preservation of populated events, provenance, sidecars, receipts, product rows,
tombstones, and links rather than only proving DDL identity.

No v10→v11 step exists in this foundation. Issue #27 (or the first accepted real schema
delta) must define v11 objects, exact ALTER statements, defaults/backfill behavior,
checksum impact, and downgrade posture.

### 5.2 Migration ownership and transaction

LedgerStore owns one package-visible schema function operating on an already
descriptor-bound SQLite handle. It:

1. detects an empty database or authenticates one exact known release;
2. checks `sqlite3_txn_state(database, "main") == SQLITE_TXN_WRITE` before the first DDL
   statement and fails unchanged otherwise;
3. starts no nested transaction because the named caller owns `BEGIN IMMEDIATE`;
4. publishes and verifies the pre-upgrade recovery image while that writer lock is held;
5. applies one release step at a time;
6. validates the resulting exact objects and fingerprint after every step;
7. updates schema metadata only after that step succeeds; and
8. leaves the caller to commit or roll back.

After either writer acquires `BEGIN IMMEDIATE` and before its first DDL statement,
LedgerStore streams the recovered, authenticated pinned database bytes into a verified
0600 recovery image using a fixed 1 MiB buffer. Holding the SQLite writer transaction
prevents another process from committing between the backup and migration. LedgerStore
publishes the image with no-follow descriptor operations and exclusive rename as
`.ledger-atlas-preupgrade-v<old>-<first12-image-sha256>.sqlite` beside the ledger. The
image SHA-256 is computed from the pinned database bytes after authenticated DELETE
journal recovery and before migration. LedgerStore reopens the image read-only, verifies
the old release identity, health, byte count, and image SHA-256, and returns the recovery
URL only to the in-process caller. Logs and review evidence contain the release number and
hash, never the source or recovery path. An existing recovery leaf is reusable only after
the same validation; every other collision fails closed.

Durability order is mandatory: write the owned temporary leaf, `fsync` its descriptor,
validate it, rename it exclusively to the recovery leaf, then `fsync` the parent directory.
No migration DDL runs until all five operations succeed. Any write, file `fsync`, rename,
directory `fsync`, or validation failure rolls back the still-unmodified transaction and
cleans only an inode the process created and re-authenticated.

The import committer delegates to the function and remains the transaction owner for its
larger atomic import. It replaces its authenticate-close-path-reopen sequence with the
existing `csqlite_open_pinned_rw` seam and retains the authenticated database descriptor,
parent-directory descriptor, VFS registration, and authenticated recovery-journal
descriptor through commit/rollback and `csqlite_close_pinned`. SQLite never opens the
writable destination by pathname after authentication. Native mutable open owns its
`BEGIN IMMEDIATE`, recovery-image publication, migration, health and path validation,
commit, and rollback. Failure to create or validate the recovery image rolls back before
DDL and leaves the store unchanged. A migration failure rolls back and closes the pinned
handle. A successful migration retains the verified recovery image for explicit restore.

Native empty-ledger creation is explicit through `LedgerStore.create(at:)`. It pins a new
0600 regular file, bootstraps v10 inside one immediate transaction, validates health and
path identity, and publishes no partially initialized store. `openForMutation(at:)` never
silently creates a missing file.

Read-only open never mutates. A known older release returns a typed
`migrationRequired(current:target:)` result; unknown, drifted, companion-bearing, or
damaged stores remain `incompatibleCanonicalStore`.

“Companion-bearing” excludes one authenticated DELETE-mode recovery journal. Mutable open
may recover that journal through the existing pinned path, then measures the pre-upgrade
image and migrates. WAL, SHM, hot or unauthenticated journals, and every other companion
remain incompatible.

### 5.3 Portable package versions

The current unversioned manifest-plus-payload pair becomes legacy format v0. The manifest
adds `packageFormatVersion: Int?`; absence means v0 and new exports set it to `1`. The
manifest is the only format-version authority. Both v0 and v1 payloads use the current
frozen exact-key JSON shape; v1 exists to establish explicit dispatch without inventing a
product-field delta. A later payload-shape change must use v2.

The frozen v0 compatibility vector contains the complete legacy manifest values, exact
payload bytes, payload SHA-256, and expected normalized `LedgerCanonicalPackage`. It is
checked into the synthetic test fixtures and is never regenerated by the v1 encoder.
Import processing is:

```text
manifest + payload
      |
      +-- missing/empty/oversize/duplicate keys --> reject, no destination change
      |
      v
SHA-256 equality
      |
      +-- mismatch ------------------------------> packageIntegrityFailure
      |
      v
manifest format dispatch: absent => v0 | 1 => v1 | other => unsupportedPackageVersion
      |
      v
strict shared v0/v1 decode and invariant validation
      |
      v
normalize to LedgerCanonicalPackage
      |
      v
one atomic LedgerStore.applyExport
```

Both v0 and v1 dispatch to the same frozen decoder because their payload shape is
identical; there is no duplicate version-specific implementation. Both retain schema
version/fingerprint fields. Package-format compatibility does not authorize an unknown
canonical schema or invent defaults for future product fields. A future package v2 gets
a new decoder; v0 and v1 exact-key validation remains frozen. Digest verification
precedes version dispatch so no decoder sees unauthenticated payload bytes.

“Empty destination” means every canonical table except `ledger_meta` has zero rows,
including import receipts, receipt membership, provenance, sidecars, preserved source,
origins, tombstones, and visible product rows. “Identical content” first requires a
complete valid destination projection. The metadata table has exactly the three current
expected keys; all import/provenance/receipt/sidecar tables are empty; and every remaining
row is either represented by the package or is an exact deterministic persistence row
derived from it. A surplus origin, transaction header, revision child, link, product row,
tombstone, or metadata key invalidates the projection. Only then does the decoded, sorted,
normalized `LedgerCanonicalPackage` compare with the destination package projection;
manifest timestamps, format versions, and payload bytes are not semantic identity. A v0
package imported into an identical v1/current destination returns unchanged.

### 5.4 Typed command failures

Keep the existing three public error owners; do not add another hierarchy or catch-all
mapping:

| Owner | Added cases | Exposed by |
|---|---|---|
| `LedgerCommandError` | `idempotencyConflict`, `staleRevision` | create, correct, and tombstone commands |
| `LedgerStore.Error` | `migrationRequired(current:target:)` | read-only canonical open and release inspection; mutable open performs the Section 5.2 backed-up migration |
| `LedgerApplication.Error` | `packageIntegrityFailure`, `unsupportedPackageVersion`, `destinationNotEmpty` | portable package import |

Existing domain-specific invalid cases continue to cover malformed command input.
Malformed package structure remains `LedgerApplication.Error.invalidCommand`. Low-level
SQLite errors, unknown schema objects, failed foreign keys, and corrupt stores remain
content-free storage errors. Public methods propagate the typed cases above unchanged;
no `catch` converts them to `invalidCommand` or `incompatibleCanonicalStore`.

Future category-cycle or inactive-category errors are added only with those commands.

### 5.5 Verified defect corrections

- Bind `sourceAccountUID` through SQLite parameters; no staged/vendor identifier enters
  SQL text.
- Execute recurrence `.thisOccurrence` read/merge/write inside one `LedgerStore.mutate`
  transaction.
- Precompute at most 366 scheduled candidates, counting skipped dates as candidates. A
  range requiring candidate 367 throws `LedgerCommandError.invalidRecurrence` before any
  write. Persist up to 366 transactions and links through the existing atomic linked-
  transaction path.
- Split the existing workspace preparation at the product's declared import boundary.
  `ImportWorkspace.reviewSource` classifies, immutably stages, and derives a structural
  coverage review plus an opaque reviewed-source handle without a timezone, canonical
  destination, or commit capability. `ImportWorkspace.prepare` consumes that handle only
  after the user chooses a fresh timezone and durable destination, reauthenticates the
  staging artifact, derives the canonical request, and returns the existing approval-bound
  prepared handle. Any count or identity drift blocks and replaces the preliminary review
  with the final content-free result; no source value enters either review.
- The reviewed-source handle owns a one-shot `StagingLease`, transferred instead of copied to
  the prepared handle. The lease retains the authenticated 0600 staging inode through the
  existing `PublicationPin`, a pinned app-owned 0700 lease directory, and an exclusively
  locked 0600 marker. Replacement, cancellation, stale generation, blocking/failure,
  commit completion, or teardown waits for the active workspace operation, then uses the
  existing descriptor-authenticated unlink and `unlinkat` on the pinned directory. A
  swapped pathname is never removed. Missing/replaced storage expires the review and
  requires source selection again; cleanup failure produces only a content-free
  cleanup-failed state and leaves the residue for authenticated recovery.
- On launch, the workspace scans only its authenticated app-owned staging root. It skips
  a lease whose marker lock is live and removes a crash residue only after acquiring that
  lock, validating the exact marker/stage-only directory shape and identities, unlinking
  through retained descriptors, and removing the now-empty directory. It never sweeps a
  caller URL, an unrecognized entry, or a replaced directory.
- Make `LedgerJourney` the sole active-ledger coordinator. It owns loading, generation,
  read snapshot, mutable store, and presentation state; the root never opens SQLite and
  the redundant `LedgerSession` opener is removed. The latest generation wins, and begin
  editing publishes the fresh mutable snapshot through the same state. Source review,
  final preparation, open, upgrade, and create use the same generation rule on cancellable
  tasks; a stale generation cannot update review, approval, rescue, or loaded state.
- Each Journey task acquires security-scoped access inside the task and balances it with
  `defer` on success, failure, cancellation, and stale-generation exit. The source scope
  remains live through immutable staging; later preparation uses only the authenticated
  staging artifact. Open, upgrade, edit, and backup reacquire their own scope before any
  path operation, so no asynchronous work outlives the callback's access grant.
- Compute backup export on an explicit action/state transition, never during SwiftUI body
  or derived-row evaluation. Retain the last verified backup kind, completion time,
  checksum, and in-process destination URL as
  `BackupStatus(kind: BackupKind, completedAt: UTCInstant, checksum: String,
  destination: URL)` for the Backup surface; logs remain path-free.
- Present insight rows as navigable accessibility elements, not one multiline blob.
- Use `MotionPolicy` as the single reduced-motion source.
- Delete the universal string-only `LedgerJourney.SurfaceRow`. Views consume the existing
  typed `LedgerReadSnapshot` collections (`LedgerAccount`, `LedgerTransactionSnapshot`,
  `LedgerCategory`, `LedgerRecurrenceRule`, `LedgerBudget`, `LedgerInstallmentPlan`, and
  `LedgerPreservedSourceRecord`) and `LedgerReportRow` directly, then derive visible and
  accessibility text at the view boundary. Backup and other non-financial status surfaces
  may consume their small existing state values directly; no replacement universal row,
  view-model hierarchy, or component framework is introduced.
- Match the accepted design contract's 900 by 620 point minimum window. New and changed
  controls expose a label, keyboard focus, and a usable VoiceOver order.
- Reset the selected source timezone whenever a new import starts and require a fresh
  nonempty choice after structural coverage review and before final preparation.
- Keep `realbyte-android-sqlite-v19-observed` classification/review-only and never issue a
  prepared handle for that exact profile. Existing tested Mac/iOS/Android family matches
  and the named synthetic Android text-subset cell retain their current preparation
  behavior.
- Require a user-chosen absolute durable canonical URL after timezone selection and before
  final preparation. A cancelled, temporary, or unsafe destination blocks before approval;
  only staging uses temporary storage.
- Default a fresh app session to Onboarding and expose the three existing design choices:
  import a Money Manager backup, open a Ledger Atlas ledger, or create an empty ledger at
  a user-chosen durable URL. This adds no product feature beyond the accepted native shell.
- Keep the existing exact canonical backup/restore flow, but remove copy that implies the
  deferred portable package is a user-facing restore artifact. The Backup destination
  label and hint name exact canonical backup and restore only.

### 5.6 Native journey states

```text
Onboarding
  ├── Import -> select source -> identify profile -> review coverage -> choose timezone
  │          -> choose durable destination -> final prepare -> blocked / approve -> loaded
  ├── Open existing -> loading -> loaded / unavailable
  │                              \-> upgrade-required -> user confirms -> upgrading
  │                                                       -> loaded / unchanged failure
  └── Create empty -> choose durable destination -> creating -> loaded / unchanged failure
```

| Flow | Loading | Empty | Error | Success | Partial |
|---|---|---|---|---|---|
| Open ledger | “Opening ledger…” and latest selection wins | “No transactions” with create/open actions | permission, upgrade-required, and incompatible outcomes have distinct rescue actions | selected ledger rows and status | preserved imported count links to coverage |
| Import | source-review and final-prepare phases; choosing another source invalidates the old result | no source: choose-source action | blocked reason is prominent and content-free | declared step order shows mapped/preserved/excluded/blocked counts before approval | reviewable unknowns stay visible; no capability for classification-only profile |
| Create empty | “Creating ledger…” | empty ledger explains that it is valid and local | unsafe/cancelled destination leaves no file | v10 ledger opens in editing state | none |
| Backup | explicit action shows phase and whether a write has occurred | no prior backup: “No verified backup yet” | failure retains prior verified-backup metadata | kind, completion time, checksum, and user-visible destination | portable package unavailable for imported ledgers; exact backup remains available |

At five seconds the user sees one primary next action and whether data is local. During the
task the user sees the phase, immutable-source promise, destination, and block/rescue
state. On return years later, backup and schema status distinguish verified recovery from
an unverified copy. The implementation reuses the current navigation, native controls,
`MotionPolicy`, import review, and backup publisher; it introduces no visual redesign.

Startup performs no automatic source import, schema migration, or ledger write. A fresh
session enters Onboarding. Read-only open of a known old release enters a typed
`upgradeRequired(url:from:to:)` presentation state. Only its explicit Upgrade action
enters `upgrading`; it invokes descriptor-bound mutable open, surfaces the verified
recovery checksum without a path, then reaches loaded or returns to upgrade-required with
an unchanged content-free failure. Cancellation is honored before the write transaction;
once `BEGIN IMMEDIATE` starts, the bounded atomic migration commits or rolls back before a
stale result is discarded. On window/app teardown, the Journey invalidates all generations,
cancels their tasks, balances security scopes, disposes the active staging lease after its
workspace operation returns, and closes each pinned handle after its active transaction
resolves. There is no background daemon, retry loop, or shutdown drain.

## 6. State machines

### Canonical store open/migration

```text
absent --create/pinned--> empty --bootstrap v10--> current
known v8/v9 --authenticate/recover journal--> BEGIN IMMEDIATE --> recovery image verified
                                                                      |
                                                                      v
                                                              migrating --validate--> current
                                                                  \--error--> rollback --> original release
current --authenticate/pin---------------> current
unknown/drifted/unsafe -------------------> rejected (no write)
read-only known-old ----------------------> migrationRequired (no write)
```

Impossible transitions are prevented by exact release fingerprints, owner-only regular
file checks, no-follow descriptor opens, authenticated DELETE-journal recovery, rejection
of all other companions, a verified recovery image, an enforced write transaction, and
post-migration exact-object validation.

### Portable package

```text
bytes -> bounded -> integrity-checked -> version-dispatched -> decoded -> validated
  |         |              |                    |              |          |
  +---------+--------------+--------------------+--------------+----------+
                                any failure => rejected / destination unchanged

validated -> all-domain-tables empty -> atomic apply -> restored
validated -> normalized package identical -> unchanged
validated -> any conflicting/hidden row -> destinationNotEmpty
```

### Delivery atom

```text
todo -> explicitly armed -> implementing -> verified -> independently reviewed
  |            |               |             |                 |
  +--> blocked +--> expired ----+--> failed --+--> findings ----+
                                           all pass
                                              |
                                              v
                                       gated commit -> accepted by later state atom
```

The final arrow documents the current GATE state-transition limitation (A9); it is not
presented as the desired long-term model.

## 7. Error and rescue registry

| Code path | Failure | Typed result | Rescue/action | User-visible result | Mutation |
|---|---|---|---|---|---|
| read-only open | exact older release | `LedgerStore.Error.migrationRequired` | offer descriptor-bound upgrade path | “This ledger needs an upgrade.” | none |
| any open | unknown/drifted/unsafe store | storage incompatibility | close handle | “Ledger could not be opened.” | none |
| migration | recovery image cannot be published/verified | storage incompatibility | close before write | “A recovery backup could not be created.” | none |
| migration | SQL/validation/path failure | storage incompatibility | rollback, close, retain recovery image | “Ledger could not be upgraded.” | rolled back |
| create/retry | same id, different content | `LedgerCommandError.idempotencyConflict` | reject | content-free conflict | none |
| correct/tombstone | current revision changed | `LedgerCommandError.staleRevision` | refresh snapshot | “Transaction changed; review the latest version.” | none |
| package import | oversize/duplicate/malformed JSON | `LedgerApplication.Error.invalidCommand` | reject before decode/apply | “Backup package is invalid.” | none |
| package import | digest mismatch | `LedgerApplication.Error.packageIntegrityFailure` | reject | “Backup package failed integrity check.” | none |
| package import | future/unknown format | `LedgerApplication.Error.unsupportedPackageVersion` | reject | “This backup format is not supported.” | none |
| package import | any non-identical row, including import/provenance | `LedgerApplication.Error.destinationNotEmpty` | reject | choose an empty destination | none |
| occurrence generation | candidate 367 required | `LedgerCommandError.invalidRecurrence` | reject before mutation | explain 366-candidate range | none |
| occurrence generation | write/link failure | storage error | rollback full batch | generic save failure | none |
| import commit | source/stage/destination changed | existing typed import/commit error | reject and require re-review | import must be reviewed again | none |
| import preparation | classification-only observed profile | existing blocked review outcome | keep structural review, issue no capability | “This profile is classification-only.” | none |
| import preparation | durable destination absent/cancelled/temporary/unsafe | content-free preparation failure | choose a durable destination | “Choose where to save the Ledger Atlas ledger.” | none |
| import review | staging lease expired or cleanup failed | content-free Journey state | select source again; retry authenticated cleanup on next launch | “Import review expired; choose the backup again.” | no canonical mutation |

No error message may include source paths, names, values, notes, identifiers, payloads, or
credentials. Debug evidence uses registered codes, counts, schema versions, and hashes
only where those hashes are already approved for evidence output.

## 8. Security and privacy

- All new SQLite values are bound parameters.
- Historical schema acceptance requires application ID, ledger identity, exact release
  version/fingerprint, exact object inventory, quick check, and foreign-key check.
- The migration executor verifies an active SQLite write transaction before DDL.
- Migrations run only after descriptor/path/directory/companion authentication and under
  the existing writer exclusion boundary.
- Both native and import writers retain the existing pinned VFS registration and parent
  descriptor until SQLite closes; neither reopens an authenticated destination pathname.
- No migration follows a symlink, accepts a hardlink/foreign owner/permissive mode, or
  opens WAL/SHM state. Only the existing authenticated DELETE-journal recovery path is
  allowed before migration.
- Every asynchronous file task owns a balanced security-scoped access interval; stale or
  cancelled tasks release it before discarding their result.
- Real-content staging remains descriptor-pinned inside an owner-only locked lease; only
  that authenticated inode and directory can be deleted on terminal cleanup or restart.
- Package parsing retains current byte, depth, token, string, duplicate-key, exact-key,
  enum, identity, and collection bounds.
- No new secret, service, endpoint, network call, analytics, or telemetry is introduced.
- External model review receives only the synthetic, secret-scanned bounded spec or diff;
  no real evidence or personal financial content is sent.

Threat posture:

| Threat | Likelihood | Impact | Mitigation |
|---|---|---|---|
| crafted staged ID changes SQL meaning | medium | high | parameter binding plus regression test |
| swapped/unsafe ledger receives migration writes | low | high | pinned VFS from authentication through close plus final identity checks |
| async task outlives security-scoped access | medium | high | task-owned balanced scope plus cancellation regression |
| abandoned or swapped staging leaks/deletes private data | medium | high | one-shot locked staging lease, authenticated unlink, and crash-residue regression |
| forged legacy schema gains trusted migration | low | high | exact frozen release object fingerprint |
| malicious package bypasses decoder | medium | high | unique keys, strict per-version shapes, bounds, digest, atomic apply |
| partial recurrence writes create wrong balances | medium | high | prevalidation plus one transaction |
| review diff leaks private content | low | high | synthetic-only scope, secret scan, provider byte cap |

## 9. Performance and limits

- Schema authentication remains O(number of schema objects), currently small and fixed.
- Each migration step is executed once inside one transaction. Future table backfills must
  declare row-count/lock limits in the version that introduces them.
- Pre-upgrade recovery copies the pinned file once with a fixed 1 MiB buffer while holding
  the writer lock; memory is O(1) and required free disk is at least the current file size
  plus temporary-publication overhead.
- Package decoding remains bounded at 64 MiB, 64 levels, 1 MiB per string, and one million
  structural tokens. Streaming decode remains deferred until those limits are raised.
- Occurrence generation validates at most 366 scheduled candidates before one write
  transaction; skipped dates consume the same bound and there is no silent truncation.
- Import commit retains the existing process-wide lock. Per-ledger locks are deferred
  until concurrent local imports become a measured need.

At 10× current synthetic corpus size, package memory and SQLite write duration are the
first expected limits. At 100×, the 64 MiB package cap or existing import bounds reject
before uncontrolled allocation. No cache or background worker is introduced.

### 9.1 Configuration cheat sheet

This stabilization adds no runtime configuration, environment key, feature flag, retry,
or timeout. The fixed conformance limits are:

| Limit | Value | Change rule |
|---|---:|---|
| portable payload bytes | 64 MiB | new package-format specification and tests |
| JSON nesting | 64 levels | new package-format specification and tests |
| JSON string bytes | 1 MiB | new package-format specification and tests |
| JSON structural tokens | 1,000,000 | new package-format specification and tests |
| recurrence candidates | 366 inclusive | product requirement plus boundary tests |
| provider review diff | 400,000 bytes | separate manual P0 gate-control atom |

## 10. Test specification

### Migration and release identity

- frozen v8, v9, and v10 fingerprints remain exact constants;
- changing current DDL cannot change a historical migration statement;
- migration execution outside `SQLITE_TXN_WRITE` fails before its first DDL statement;
- a pinned synthetic v8 fixture migrates through v9 to v10 atomically;
- a pinned synthetic v9 fixture migrates to v10 atomically;
- populated synthetic v8 and v9 fixtures preserve the exact ordered old-release semantic
  checksum after successful migration, every newly added table is empty, and only the
  declared version/fingerprint metadata changes while identity and key count remain exact;
- current v10 is unchanged;
- unknown version/fingerprint/object drift is rejected without mutation;
- authenticated DELETE-journal recovery followed by migration succeeds; WAL, SHM, hot or
  unauthenticated journals reject before migration;
- failure to publish or verify a recovery image leaves the original image SHA-256 and
  release identity unchanged;
- injected recovery-file or parent-directory `fsync` failure runs no DDL and leaves the
  old store valid;
- a competing connection cannot commit after backup begins and before migration
  commits/rolls back;
- injected failure after each migration statement rolls back to the post-recovery,
  pre-migration pinned-byte SHA-256 and release identity;
- successful migration retains a read-only-valid recovery image whose byte SHA-256 and
  old release identity match the pre-migration measurement;
- native descriptor-bound mutation and import commit use the same migration executor;
- the import writer retains `csqlite_open_pinned_rw` descriptors/registration through
  close, and a pathname swap with a hot journal between authentication and writable open
  cannot mutate either inode;
- read-only open of v8/v9 returns migration-required and leaves bytes unchanged;
- explicit empty-ledger creation publishes one valid v10 file and every injected
  bootstrap failure leaves no destination;
- import-workspace migration tests for v8 and v9 preserve source and staging SHA-256,
  roll back the destination for every injected statement failure, and emit no source path,
  identifier, note, or value.

### Package format

- current exports contain manifest format v1 and the frozen exact payload shape;
- a frozen pre-change v0 manifest, exact payload bytes, digest, and expected normalized
  package import unchanged through the public API;
- v0 and v1 two-cycle round trips preserve declared money, time, links, lifecycle, and
  product collections;
- future manifest version, digest mismatch, oversized input, duplicate payload key, and
  malformed row all leave the destination unchanged;
- an import-only/provenance-only/tombstone-only destination returns destination-not-empty;
- an otherwise identical visible package with a surplus origin, revision child, receipt,
  provenance row, or metadata key returns destination-not-empty;
- v0 imported into semantically identical v1/current state returns unchanged even when
  manifest or payload bytes differ;
- imported receipt/provenance graphs remain refused for portable export.

### Typed errors and defects

- same id/different content returns idempotency conflict;
- stale correction and tombstone return stale revision with unchanged checksum;
- imported account identifiers containing quote/comment/control shapes are data, never
  SQL syntax;
- recurrence concurrent update cannot lose a skip;
- occurrence batch failure at first/middle/last write leaves zero new revisions/links;
- candidate counts 365, 366, and 367 produce success, success, and typed failure;
  skipped candidates count toward the same boundary;
- latest ledger open wins and `LedgerJourney` presentation matches its active mutable
  snapshot; one selected URL causes one SQLite open;
- source review precedes timezone and destination selection; final preparation reuses the
  authenticated stage, and an invalidated review/preparation cannot expose approval;
- source review and every later file task keep security-scoped access balanced through
  success, failure, cancellation, stale-generation exit, and teardown;
- the reviewed staging lease transfers exactly once to preparation, survives the choice
  interval, and is descriptor-authenticated before reuse;
- success, structural block, thrown failure after staging, cancellation, source
  replacement, stale generation, commit failure/success, and teardown dispose only the
  leased inode after active work returns; a swapped path is retained and reported
  content-free rather than unlinked;
- next-launch cleanup skips a live locked lease, removes an exact authenticated crash
  residue, and ignores unknown/replaced entries;
- repeated view rendering performs no package export;
- native surfaces consume the corresponding typed snapshot/domain/report collections;
  removing `SurfaceRow` cannot erase account, transaction, category, recurrence, budget,
  installment, preserved-source, or insight semantics;
- a new import cannot reuse the prior source timezone;
- the observed Android profile produces no prepared capability;
- tested Mac/iOS/Android family matches and the synthetic Android text-subset still
  prepare and commit under their existing named expectations;
- cancelled/temporary/unsafe canonical destinations cause no commit, while a selected
  durable destination survives staging-directory removal;
- a fresh root starts on Onboarding and its import, open, and create-empty actions reach
  the corresponding Journey states;
- read-only old-store open reaches upgrade-required; only explicit confirmation reaches
  upgrading, then loaded with recovery status or unchanged upgrade-required failure;
- Backup destination copy promises exact canonical backup/restore only, never portable
  package restore;
- VoiceOver can navigate each insight row;
- changed controls have labels and keyboard focus, the minimum window is 900 by 620, and
  reduced motion has one source of truth.

### Required commands

```sh
swift test --filter CanonicalPersistenceModelsTests
swift test --filter AtomicCanonicalCommitTests
swift test --filter LedgerStoreTests
swift test --filter LedgerApplicationTests
swift test --filter LedgerJourneyTests
swift test --filter AppDestinationTests
swift test --filter LedgerAtlasRootViewAccessibilityTests
./scripts/verify.sh --fast
./scripts/verify.sh --full
```

The UI atom uses one package-visible minimum-size constant and one ordered focus-target
enum as the implementation seams. Its focused test mounts the changed surfaces in
`NSHostingView`, asserts distinct insight accessibility elements and labels, verifies the
declared focus order, and proves the root consumes the 900 by 620 constant. Because that
does not prove assistive-technology behavior, the MAC admission gate also launches the
release executable and records a runtime keyboard traversal plus Accessibility
Inspector/VoiceOver check; no XCUITest target or new test framework is added.

Every non-trivial new branch gets one smallest regression that would fail if removed.
Tests use synthetic SQLite/package data only.

## 11. Delivery and rollback

Implementation is serialized because the foundation and defect work overlap
`LedgerStore.swift`, `LedgerApplication.swift`, and their tests. No parallel writers may
own those files.

Frozen order is architecture, migration/recovery, package/errors, ledger-integrity
defects, import capability/destination, native Journey, then product truth. Every subject
commit is followed by a manual admission commit before the next subject begins.

| Subject atom | Depends on | Frozen outcome |
|---|---|---|
| `ARC-001` | `GATE-002` | Freeze the accepted spec, review record, ticket pack, future criteria, atom graph, current-worktree-relative manual runbook, and GATE-002 evidence without changing executable gate controls. |
| `MIG-001` | `ARC-001` | One LedgerStore migration owner authenticates literal v8/v9/v10 releases, enforces the caller's write transaction, preserves populated semantics and exact metadata transitions, retains a verified recovery image, and keeps both native and import writers pinned through close. |
| `PKG-001` | `MIG-001` | Freeze package v0, write manifest-v1 through one shared decoder, reject every hidden-row conflict, and expose only the current typed command/store/package failures. |
| `LED-003` | `PKG-001` | Fix issue #34 SQL binding, recurrence TOCTOU, and atomic 366-candidate occurrence generation at their shared persistence owners. |
| `IMP-004` | `LED-003` | Keep the exact observed profile classification-only and split structural review from timezone/durable-destination-bound preparation using a one-shot authenticated staging lease without broadening tested family behavior. |
| `MAC-001` | `IMP-004` | Make Journey the sole async/open owner; add explicit onboarding/create/upgrade states, balanced security scope, typed domain surfaces, exact-backup copy, explicit backup action, accessibility/focus/minimum-window evidence, and one motion source. |
| `TRUTH-001` | `MAC-001` | Reconcile product status using exact clean-tree verification and fresh review evidence, without release or compatibility expansion. |

All fourteen atoms are P0. `ADM-002` through `ADM-008` are the interleaved admission
atoms. Each owns only `prd.json` and the review record, except `ADM-002`, which also
commits the already-used `ARC-001.txt` criterion receipt, and `ADM-008`, which may finalize
the spec and status summary. An admission atom marks its subject and the preceding
admission atom done with exact commit/review/test evidence. It depends on the prior
admitted subject so it can be armed before staging those status transitions:

| Admission atom | Frozen dependency | Subject admitted |
|---|---|---|
| `ADM-002` | `GATE-002` | `ARC-001` |
| `ADM-003` | `ARC-001` | `MIG-001` and `ADM-002` |
| `ADM-004` | `MIG-001` | `PKG-001` and `ADM-003` |
| `ADM-005` | `PKG-001` | `LED-003` and `ADM-004` |
| `ADM-006` | `LED-003` | `IMP-004` and `ADM-005` |
| `ADM-007` | `IMP-004` | `MAC-001` and `ADM-006` |
| `ADM-008` | `MAC-001` | `TRUTH-001` and `ADM-007` |

The next subject depends on the admitted subject, not on the admission atom; this leaves
only the final `ADM-008` truthfully `doing` under A9.

Subject atoms do not own `prd.json`, their criterion file, a gate, hook, verifier, review
control, or attestation control. `ARC-001` is the one bootstrap exception for `prd.json`:
its armed criterion hash must match the predeclared working PRD exactly, and it may not
change that criterion after arming. Its own `ARC-001.txt` remains outside its writable
scope until `ADM-002`. All execution is manual and serial; unattended and batch modes are
ineligible because ownership intentionally transfers between atoms.

`ARC-001` replaces hard-coded product-checkout commands in the runbook with a root derived
from `git rev-parse --show-toplevel` and labels this sequence as separate manual gated
runs. It does not alter a hook, gate, verifier, review lens, or authority check.

Exact subject ownership is:

- `ARC-001`: `prd.json`; `docs/orchestration/RUNBOOK.md`; the architecture spec, review
  record, and ticket pack; and admission/future-subject criterion files `ADM-002.txt`
  through `ADM-008.txt`, `MIG-001.txt`, `PKG-001.txt`, `LED-003.txt`, `IMP-004.txt`,
  `MAC-001.txt`, and `TRUTH-001.txt`, excluding `ARC-001.txt`.
- `MIG-001`: `CanonicalLedgerSchema.swift`, `LedgerStore.swift`,
  `SQLiteCanonicalCommitter.swift`, and their three focused persistence/store/atomic-
  commit test files.
- `PKG-001`: `LedgerProducts.swift`, `CanonicalLedgerHealth.swift`, `LedgerStore.swift`,
  `LedgerApplication.swift`, their core/store/application tests, and
  `fixtures/synthetic/portable-package-v0/`.
- `LED-003`: `SQLiteCanonicalCommitter.swift`, `LedgerStore.swift`,
  `LedgerApplication.swift`, and the matching atomic-commit/store/application tests.
- `IMP-004`: classification `Models.swift`, `MoneyManagerV19Adapter.swift`,
  `ImportWorkspace.swift`, `SQLiteStagingStore.swift`, and their immutable-staging,
  adapter, workspace, and family-import tests.
- `MAC-001`: `AppDestination.swift`, `ImportReview.swift`, `LedgerAtlasRootView.swift`,
  `LedgerJourney.swift`, `LedgerSession.swift`, `LedgerShell.swift`, and the destination,
  import-review, Journey, Session, phase-journey, motion, and new root-accessibility tests.
- `TRUTH-001`: `CONTEXT.md`, `SPEC.md`, `README.md`, `JOURNAL.md`, `progress.txt`,
  `docs/product-status.json`, `status.html`, the architecture spec, review record, and
  ticket pack.

The ticket pack expands every shorthand filename above to an exact repository-relative
path. No atom may stage another path. Before arming, its proposed diff must remain below
the fixed 400,000-byte provider limit; otherwise the subject is split and the frozen
specification is re-reviewed rather than weakening the gate. A failed check or review
returns the subject to implementation; two no-gain candidates stop the run.

Rollback:

```text
before commit -> unstage exact owned paths; user work remains untouched
after code commit, before schema release -> revert candidate commit through a new gate atom
after a future schema upgrade -> old app refuses newer schema; restore exact pre-upgrade
                                backup only after integrity validation
current foundation -> no schema bump, so ordinary gated revert is sufficient
```

The implementation branch is isolated from dirty `main`. No merge or push occurs.

## 12. Status authority

After stabilization, these sources have distinct roles:

- Git history: accepted commits and tree identity.
- `prd.json`: executable atom status, dependencies, path ownership, and criterion.
- GitHub Issues: canonical product work records.
- `docs/product-status.json`: generated/maintained current product summary with an
  `updated` timestamp and exact verification evidence.
- `CONTEXT.md` and `SPEC.md`: durable intent and accepted scope, not mutable test counts.
- `JOURNAL.md` and `progress.txt`: historical narrative; entries are never rewritten, but
  a header states they are not current status.
- HTML dashboards: derived displays; they must name their source and update time.

No document may infer acceptance from file existence or a local test run. Implemented,
verified, reviewed, committed, merged, released, and certified remain separate states.

## 13. Review gates

The draft is not implementation authority. It must receive:

- internal architecture and history review;
- independent Codex and Grok review;
- a labeled internal Mixture-of-Agents review because no `/moa` executable, tool, skill,
  or installable recommended plugin is available;
- council synthesis with dissent preserved;
- CEO hold-scope review;
- engineering review across architecture, failures, security, tests, performance, and
  rollback;
- design review of the existing native-flow defect slice (no redesign); and
- DevEx review of the schema/package/error and gated-delivery surfaces.

All P0/P1 findings must be resolved in this document or rejected with evidence before
tickets are frozen. Reviewer outputs do not silently change the governing criterion.

## 14. Review decisions and feedback dispositions

The four architecture decisions are resolved:

1. **Accepted:** v10 remains current until an accepted product change defines a real v11
   delta. Codex, Grok, and both internal MoA reviewers endorsed this.
2. **Accepted with correction:** the unversioned package is v0 and remains decodable. The
   complete v0 vector is frozen; v1 has one manifest authority, a frozen payload shape,
   and normalized cross-version identity. This resolves the original Codex, Grok, and MoA
   objections to dual authorities and payload-only compatibility evidence.
3. **Accepted with correction:** migration execution moves to LedgerStore. Runtime write-
   transaction enforcement, exact v9 authentication, authenticated journal handling,
   import-side immutability tests, and a verified pre-upgrade recovery image close the
   independent reviewers’ conditions.
4. **Accepted:** this branch closes foundations and verified defects only. Parity epics,
   release, and universal compatibility remain queued.

Initial independent-review findings and their draft-2 dispositions:

| Review signal | Disposition |
|---|---|
| Codex: no pre-upgrade recovery artifact | accepted in Sections 5.2, 6, 7, and 10 |
| Codex: incomplete v0 fixture and confused error ownership | accepted in Sections 5.3, 5.4, and 10 |
| Codex: import migration safety, undefined occurrence limit, duplicate opener, and infeasible atom plan | accepted in Sections 5.2, 5.5, 10, and 11 |
| Grok: unenforced transaction, hidden-row emptiness, byte-SHA identity, dual version authority, companion ambiguity, uncertified profile, temp destination, render-time export, and duplicate opens | accepted in Sections 5.2–5.6 and 10 |
| Internal MoA integrity: transaction precondition, import-only destination, cross-version identity, and rollback-journal checksum point | accepted in Sections 5.2, 5.3, 6, and 10 |
| Internal MoA product: durable destination, onboarding choices, fresh timezone, async ownership, typed rescue, backup status, row semantics, insights, motion, and ticket feasibility | accepted in Sections 5.5, 5.6, 7, 10, and 11 |

Planning-gate findings and their draft-3 dispositions:

| Review signal | Disposition |
|---|---|
| Engineering: atom lifecycle was unable to admit dependencies and subjects owned their own criteria | accepted by the manual P0 admission graph and immutable criterion ownership in Section 11 |
| Engineering: import authentication closed its descriptor before writable path open | accepted through retained `csqlite_open_pinned_rw` ownership in Sections 5.2, 8, and 10 |
| Engineering: migration checksums conflicted with required metadata changes | accepted through masked migration-owned metadata and exact transition checks in Sections 5.1 and 10 |
| Engineering: normalized package comparison could ignore hidden surplus rows | accepted through the complete projection precondition and hidden-row regressions in Sections 5.3 and 10 |
| Engineering: async security scope, upgrade rescue, accessibility evidence, and atom size were incomplete | accepted in Sections 5.5, 5.6, 10, and 11 |
| Design: import order contradicted `DESIGN.md`; upgrade was a dead end; backup copy implied portable restore | accepted through the two-stage workspace, explicit upgrade state machine, and exact-backup-only copy in Sections 5.5–5.6 and 10 |
| Design/DevEx: labels, focus, VoiceOver order, and window size lacked executable evidence | accepted through focused native seams plus the required runtime accessibility gate in Section 10 |
| DevEx: criteria omitted product outcomes and the runbook targeted the wrong checkout/mode | accepted through the split subject criteria and current-worktree-relative manual runbook atom in Section 11 |
| Engineering/design/DevEx re-review: reviewed-source staging lacked private-data lifetime and crash cleanup | accepted through the one-shot locked staging lease, authenticated terminal cleanup, content-free expiry, and restart regressions in Sections 5.5, 7, 8, 10, and 11 |

Feedback considered and deliberately deferred:

- A user-facing portable package artifact/restore flow remains deferred because the
  current API has no single durable transport contract. Status text must not call it a
  shipped restore feature.
- Five-area navigation, menu accelerators, undo/redo, chart presentation, visual polish,
  and the complete parity interaction contract remain feature work, not stabilization.
- A generic import facade remains deferred until a second adapter or client needs it.
- Streaming JSON, per-ledger import locks, and package v2 remain deferred until current
  fixed limits or measured concurrency require them.
- A machine-readable public error-code registry remains deferred; the typed Swift cases
  are the current contract and user strings stay content-free.
- A durable gate `done` transition repair remains a separate supervised governance ticket;
  this candidate does not change its own gate and uses the explicit admission atoms in
  Section 11.

## 15. Acceptance criteria

- [x] All Section 14 architecture decisions are resolved.
- [x] The target dependency graph contains one canonical migration owner.
- [x] Historical releases and package versions are frozen independently.
- [x] All nil, empty, malformed, future-version, conflict, rollback, and privacy paths
  above specify observable outcomes and tests.
- [x] No arbitrary v11 schema field or speculative command error is introduced.
- [x] No existing compatibility claim is broadened.
- [x] The ticket pack has exact paths, dependencies, criteria, evidence, stop rules, and
  one owner per writable file.
- [x] Codex, Grok, internal MoA/council, CEO, engineering, design, and DevEx reviews have
  no unresolved P0/P1 findings.
- [x] Implementation begins only after this document is marked `accepted` with a frozen
  SHA-256.
