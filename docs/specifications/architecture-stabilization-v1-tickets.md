# Architecture stabilization v1 implementation tickets

Status: accepted; execution waits for ARC-001 and ADM-002 gated commits  
Prepared: 2026-08-23  
Baseline: `ef515cbf1edb6f975da00210509abeb5fb221f4d`  
Prior reviewed draft SHA-256: `767ca6abd015b33d9ab4183e7475adb103773dcf7c736a2dca8d43ac8a1351dc`  
Corrected candidate spec SHA-256: `0352fdafd2a91efab10740448bcd9fd538e54746aa7ff30b3f4c5e76d1da6b9b`
Accepted spec SHA-256: `9e256c2844d3ab18323ea2b8bd709698eb77627fe6d0dd9ca91065822da3c236`

## Delivery contract

- Run each atom manually and serially in the isolated worktree. Do not use unattended or
  batch mode because writable ownership transfers between atoms.
- A subject atom never owns `prd.json`, its criterion file, or any gate/hook/verifier/
  review/attestation control. `ARC-001` is the documented PRD bootstrap exception; its
  active criterion hash must already match the working PRD.
- Every subject receives a reviewer and red-team lens. The following admission atom
  records the subject done with exact evidence before the next subject begins.
- The proposed staged diff must be under 400,000 bytes. If it is not, stop and re-specify a
  smaller atom; never weaken the provider limit.
- Tests and fixtures are synthetic. Evidence contains codes, counts, versions, and approved
  hashes only. Never record paths, names, identifiers, notes, values, payloads, or credentials.
- Stop after two no-gain candidates, an expired authority window, any scope conflict, or
  any unresolved P0/P1. Do not push, merge, rebase, deploy, release, or edit protected
  evidence.

For every atom, arm the exact PRD criterion, stage only its listed paths, run the focused
checks, then commit only through `./scripts/gate-commit.sh`. The gate adds exact-tree full
verification and required provider lenses.

## ARC-001: Freeze architecture authority

Depends on: `GATE-002`  
GitHub: #2 (planning freeze and final truth)  
Criterion: Accepted architecture specification, review record, implementation ticket
pack, future atom criteria, current-worktree-relative manual runbook, and GATE-002 evidence
are mutually consistent and frozen without changing product source, executable gate
controls, compatibility claims, or release status.

Owned paths:

- `prd.json`
- `docs/orchestration/RUNBOOK.md`
- `docs/specifications/architecture-stabilization-v1.md`
- `docs/specifications/architecture-stabilization-v1-review-record.md`
- `docs/specifications/architecture-stabilization-v1-tickets.md`
- `docs/orchestration/criteria/ADM-002.txt`
- `docs/orchestration/criteria/MIG-001.txt`
- `docs/orchestration/criteria/ADM-003.txt`
- `docs/orchestration/criteria/PKG-001.txt`
- `docs/orchestration/criteria/ADM-004.txt`
- `docs/orchestration/criteria/LED-003.txt`
- `docs/orchestration/criteria/ADM-005.txt`
- `docs/orchestration/criteria/IMP-004.txt`
- `docs/orchestration/criteria/ADM-006.txt`
- `docs/orchestration/criteria/MAC-001.txt`
- `docs/orchestration/criteria/ADM-007.txt`
- `docs/orchestration/criteria/TRUTH-001.txt`
- `docs/orchestration/criteria/ADM-008.txt`

Checks/evidence:

- accepted-spec self-review and `git diff --check`;
- `python3 scripts/orchestrion.py validate`;
- exact criteria/PRD/ticket equality check;
- GATE-002 qualified fast/full receipt and independent audit;
- no product or executable-control diff.

`docs/orchestration/criteria/ARC-001.txt` is the already-used external frozen criterion
receipt and is deliberately outside this atom's writable scope.

## ADM-002: Admit architecture authority

Depends on: `GATE-002`  
Criterion: GATE-002 is the frozen dependency; independent planning reviews have no
unresolved P0 or P1 findings; ARC-001 and GATE-002 are recorded done with exact commit and
verification evidence; ARC-001.txt is admitted as its frozen receipt; and no product
source or executable orchestration control changes.

Owned paths:

- `prd.json`
- `docs/specifications/architecture-stabilization-v1-review-record.md`
- `docs/orchestration/criteria/ARC-001.txt`

Evidence: ARC gated commit, final CEO/council/Codex/Grok/MoA/engineering/design/DevEx
dispositions, PRD validation, and gate full verification. No implementation occurs here.

## MIG-001: Canonical release and migration owner

Depends on: `ARC-001`  
GitHub: #33  
Criterion: LedgerStore owns literal v8, v9, and v10 releases and one descriptor-bound
migration executor that requires the caller's write transaction, preserves populated
semantic rows and exact metadata transitions, publishes and verifies a durable
pre-upgrade recovery image before DDL, and is reused by native and import writers retained
through close with unchanged-on-failure tests.

Owned paths:

- `Sources/LedgerCore/Persistence/CanonicalLedgerSchema.swift`
- `Sources/LedgerStore/LedgerStore.swift`
- `Sources/MMImport/Commit/SQLiteCanonicalCommitter.swift`
- `tests/LedgerCoreTests/Persistence/CanonicalPersistenceModelsTests.swift`
- `tests/LedgerStoreTests/LedgerStoreTests.swift`
- `tests/MMImportTests/Commit/AtomicCanonicalCommitTests.swift`

Required checks:

```sh
swift test --filter CanonicalPersistenceModelsTests
swift test --filter LedgerStoreTests
swift test --filter AtomicCanonicalCommitTests
./scripts/verify.sh --fast
```

Acceptance includes literal historical fingerprints/SQL; exact old-to-new metadata;
populated v8/v9 no-loss checks; active-write-transaction enforcement; recovery file and
directory fsync failures; competing writer exclusion; import `csqlite_open_pinned_rw`
lifetime; hot-journal/path-swap rejection; and native/import executor reuse.

Rollback: before any future schema release, gated revert. After an actual migration,
restore only the verified retained pre-upgrade image after integrity validation.

## ADM-003: Admit migration foundation

Depends on: `ARC-001`  
Criterion: ARC-001 is the frozen dependency; fresh focused tests, full verification,
reviewer, and red-team evidence close every MIG-001 finding; MIG-001 and ADM-002 are
recorded done with exact commit evidence; and no product source or executable control
changes.

Owned paths: `prd.json` and
`docs/specifications/architecture-stabilization-v1-review-record.md`.

## PKG-001: Portable package and typed failures

Depends on: `MIG-001`  
GitHub: #33  
Criterion: Portable package v0 is frozen by a complete synthetic vector, new exports write
manifest version 1 through the shared frozen v0/v1 decoder, complete destination
projection rejects hidden conflicts, current typed command/store/package failures
propagate unchanged, and every rejection leaves the destination unchanged.

Owned paths:

- `Sources/LedgerCore/Ledger/LedgerProducts.swift`
- `Sources/LedgerStore/CanonicalLedgerHealth.swift`
- `Sources/LedgerStore/LedgerStore.swift`
- `Sources/LedgerStore/LedgerApplication.swift`
- `tests/LedgerStoreTests/LedgerStoreTests.swift`
- `tests/LedgerStoreTests/LedgerApplicationTests.swift`
- `fixtures/synthetic/portable-package-v0/`

Required checks:

```sh
swift test --filter LedgerStoreTests
swift test --filter LedgerApplicationTests
./scripts/verify.sh --fast
```

Acceptance includes the complete fixed v0 manifest/payload/digest/normalized package;
v1 emission; shared exact-key decode; unknown version and integrity errors; normalized
cross-version identity; complete metadata/origin/revision/import/provenance projection;
hidden-row conflicts; import-provenance export refusal; idempotency conflict; stale
revision; and unchanged checksums for every rejected path.

## ADM-004: Admit package contract

Depends on: `MIG-001`  
Criterion: MIG-001 is the frozen dependency; fresh focused tests, full verification,
reviewer, and red-team evidence close every PKG-001 finding; PKG-001 and ADM-003 are
recorded done with exact commit evidence; and no product source or executable control
changes.

Owned paths: `prd.json` and
`docs/specifications/architecture-stabilization-v1-review-record.md`.

## LED-003: Close atomic ledger defects

Depends on: `PKG-001`  
GitHub: #34 items 1–3  
Criterion: Vendor identifiers are SQL-bound, recurrence this-occurrence update is one
transaction, occurrence generation prevalidates at most 366 candidates and commits one
atomic batch, and named concurrency, boundary, injection, and rollback regressions prove
issue 34 items 1 through 3.

Owned paths:

- `Sources/MMImport/Commit/SQLiteCanonicalCommitter.swift`
- `Sources/LedgerStore/LedgerStore.swift`
- `Sources/LedgerStore/LedgerApplication.swift`
- `tests/MMImportTests/Commit/AtomicCanonicalCommitTests.swift`
- `tests/LedgerStoreTests/LedgerStoreTests.swift`
- `tests/LedgerStoreTests/LedgerApplicationTests.swift`

Required checks:

```sh
swift test --filter AtomicCanonicalCommitTests
swift test --filter LedgerStoreTests
swift test --filter LedgerApplicationTests
./scripts/verify.sh --fast
```

Acceptance includes hostile identifier shapes as bound data; concurrent recurrence skip
merge; 365/366 success and 367 pre-write failure; skipped-date counting; and injected
first/middle/last batch failures leaving zero new revisions/links.

## ADM-005: Admit ledger-integrity fixes

Depends on: `PKG-001`  
Criterion: PKG-001 is the frozen dependency; fresh focused tests, full verification,
reviewer, and red-team evidence close every LED-003 finding; LED-003 and ADM-004 are
recorded done with exact commit evidence; and no product source or executable control
changes.

Owned paths: `prd.json` and
`docs/specifications/architecture-stabilization-v1-review-record.md`.

## IMP-004: Safe two-stage import preparation

Depends on: `LED-003`  
GitHub: #35  
Criterion: The exact observed Android profile remains classification-only; structural
review precedes fresh timezone and durable destination selection; a one-shot authenticated
staging lease transfers from reviewed to prepared state and is safely disposed or
recovered on every terminal or crash path; tested family and synthetic cells retain their
named behavior.

Owned paths:

- `Sources/MMImport/Classification/Models.swift`
- `Sources/MMImport/Adapters/MoneyManagerV19/MoneyManagerV19Adapter.swift`
- `Sources/MMImport/Workspace/ImportWorkspace.swift`
- `Sources/MMImport/Staging/SQLiteStagingStore.swift`
- `tests/MMImportTests/Staging/ImmutableSourceStagingTests.swift`
- `tests/MMImportTests/Adapters/MoneyManagerV19AdapterTests.swift`
- `tests/MMImportTests/Workspace/ImportWorkspaceTests.swift`
- `tests/MMImportTests/Workspace/MoneyManagerFamilyImportTests.swift`

Required checks:

```sh
swift test --filter ImmutableSourceStagingTests
swift test --filter MoneyManagerV19AdapterTests
swift test --filter ImportWorkspaceTests
swift test --filter MoneyManagerFamilyImportTests
./scripts/verify.sh --fast
```

Acceptance includes no exact-observed capability; preserved family behavior; preliminary
structural counts before timezone/destination; reauthenticated final preparation; absolute
non-temporary durable destination; fresh timezone; one-shot lease transfer; 0700/0600
ownership; terminal cleanup; missing/swap expiry; live-lock skip; and safe crash sweep.

## ADM-006: Admit import boundary

Depends on: `LED-003`  
Criterion: LED-003 is the frozen dependency; fresh focused tests, full verification,
reviewer, and red-team evidence close every IMP-004 finding; IMP-004 and ADM-005 are
recorded done with exact commit evidence; and no product source or executable control
changes.

Owned paths: `prd.json` and
`docs/specifications/architecture-stabilization-v1-review-record.md`.

## MAC-001: One native Journey and truthful UI states

Depends on: `IMP-004`  
GitHub: #34 items 4–8  
Criterion: LedgerJourney is the sole open and async state owner; onboarding, create, open,
explicit upgrade, import, and backup states use balanced security scope and
latest-generation presentation; typed domain surfaces, explicit exact backup actions and copy,
900 by 620 minimum size, focus and VoiceOver order, and one motion policy have focused and
runtime evidence.

Owned paths:

- `Sources/LedgerAtlasMacUI/AppDestination.swift`
- `Sources/LedgerAtlasMacUI/ImportReview.swift`
- `Sources/LedgerAtlasMacUI/LedgerAtlasRootView.swift`
- `Sources/LedgerAtlasMacUI/LedgerJourney.swift`
- `Sources/LedgerAtlasMacUI/LedgerSession.swift`
- `Sources/LedgerAtlasMacUI/LedgerShell.swift`
- `tests/LedgerAtlasMacUITests/AppDestinationTests.swift`
- `tests/LedgerAtlasMacUITests/ImportReviewTests.swift`
- `tests/LedgerAtlasMacUITests/LedgerJourneyTests.swift`
- `tests/LedgerAtlasMacUITests/LedgerSessionTests.swift`
- `tests/LedgerAtlasMacUITests/MoneyManagerPhase00JourneyTests.swift`
- `tests/LedgerAtlasMacUITests/MotionPolicyTests.swift`
- `tests/LedgerAtlasMacUITests/LedgerAtlasRootViewAccessibilityTests.swift`

Required checks:

```sh
swift test --filter AppDestinationTests
swift test --filter ImportReviewTests
swift test --filter LedgerJourneyTests
swift test --filter LedgerSessionTests
swift test --filter MoneyManagerPhase00JourneyTests
swift test --filter MotionPolicyTests
swift test --filter LedgerAtlasRootViewAccessibilityTests
./scripts/verify.sh --fast
```

Acceptance includes one SQLite open per selection; latest open/review/prepare wins; fresh
mutable snapshot; DESIGN.md import order; balanced task security scope; onboarding default
and three choices; explicit create and upgrade transitions; no render-time export; retained
backup status; exact-backup-only copy; direct typed collections; row-level insight
accessibility; declared focus order; 900×620 constant; and one reduced-motion source.

## ADM-007: Admit native Journey

Depends on: `IMP-004`  
Criterion: IMP-004 is the frozen dependency; fresh focused tests, full verification,
reviewer, red-team, and recorded runtime keyboard plus Accessibility Inspector or
VoiceOver evidence close every MAC-001 finding; MAC-001 and ADM-006 are recorded done with
exact commit evidence; and no product source or executable control changes.

Owned paths: `prd.json` and
`docs/specifications/architecture-stabilization-v1-review-record.md`.

## TRUTH-001: Reconcile product truth

Depends on: `MAC-001`  
GitHub: #2  
Criterion: Status sources record exact accepted commits, verification, review,
compatibility, and release state without rewriting historical narrative or broadening
claims; clean fast and full verification and fresh code review are green.

Owned paths:

- `CONTEXT.md`
- `SPEC.md`
- `README.md`
- `JOURNAL.md`
- `progress.txt`
- `docs/product-status.json`
- `status.html`
- `docs/specifications/architecture-stabilization-v1.md`
- `docs/specifications/architecture-stabilization-v1-review-record.md`
- `docs/specifications/architecture-stabilization-v1-tickets.md`

Required checks:

```sh
./scripts/verify.sh --fast
./scripts/verify.sh --full
```

Acceptance keeps implemented, verified, reviewed, committed, merged, released, shipped,
and certified distinct. It records exact counts/hashes/timestamps and labels `JOURNAL.md`
and `progress.txt` as historical without rewriting their entries.

## ADM-008: Final delivery admission

Depends on: `MAC-001`  
Criterion: MAC-001 is the frozen dependency; all subject and prior admission atoms are
recorded done with exact gated commits, focused and full verification, reviewer, red-team,
runtime accessibility, and code-review evidence; the accepted spec and product status
identify delivery-ready local implementation without claiming merge, release,
certification, or shipment; and ADM-008 remains the only doing atom under the documented
gate limitation.

Owned paths:

- `prd.json`
- `docs/product-status.json`
- `status.html`
- `docs/specifications/architecture-stabilization-v1.md`
- `docs/specifications/architecture-stabilization-v1-review-record.md`
- `docs/specifications/architecture-stabilization-v1-tickets.md`

This is the final gated commit. It changes no product source or executable control.

## Issue-tracker synchronization

Synchronized on 2026-08-23:

1. GitHub #33 replaces arbitrary v11 DDL with `MIG-001` and `PKG-001` at v10;
2. GitHub #34 maps `LED-003` and `MAC-001` to exact acceptance/test ownership;
3. GitHub #35 owns `IMP-004`; GitHub #2 already owns the ARC/TRUTH sequence;
4. each record and the durable local pack has the single `needs-triage` readiness label
   until the planning admission commits land.

No Linear connector is available in this session. GitHub and the durable local pack remain
authoritative; the Linear mirror is pending.
