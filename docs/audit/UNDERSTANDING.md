# Ledger Atlas - UNDERSTANDING (audit comprehension lead)

Repo: <repo root>, HEAD d2c2ba3 (main, 2026-09-14), 72 commits, 6296 tracked files (6012 of them under `.agents/` = vendored skill packs; ~284 are the real product). Private repo praxstack/ledger-atlas. Contributors: Prax Lannister 52, Cursor Agent 15, cursor[bot] 5. Activity: burst 2026-08-19..09-14 (peak 08-29 and 08-31); last commit 2026-09-14.

## 1. What it is
Two tracks in one repo:
1. Lightweight Next.js 15 ledger demo (`app/`, `lib/ledger.ts`) - JSON-file persisted, one GET/POST route. Originally the whole repo (README/CLAUDE.md still lead with it).
2. The real product: macOS-first, local-first personal-finance app in Swift 6.2 (SwiftPM + XcodeGen `project.yml`), with a Money Manager (Realbyte) Android v19 compatibility perimeter. Canonical SQLite ledger (schema v11), exact decimal money, immutable-source staging with loss reports, atomic/idempotent import, SwiftUI shell, widget, App Intents, loopback read-only portal.

## 2. Document authority
Authoritative (current): AGENTS.md (operating contract, invariants), CONTEXT.md (durable context; stale tail, see drift), SPEC.md (milestone-one AC-01..07), docs/specifications/ledger-atlas-mac-completion-v2.md (accepted release-one contract; 33 stories / 23 tickets MACV2-01..23 = GH #37-#59), prd.json (ticket+atom status; stale), docs/orchestration/RUNBOOK.md, EVIDENCE.md (external read-only evidence at /Users/prax/Developer/money-manager-reverse-engineering), docs/decisions/0007,0008,0010,0011.
Historical / superseded: JOURNAL.md (ends 2026-08-18), progress.txt (ends 08-31, mixes), plans/RUN-2026-08-10.md, plans/001-003 native (SUPERSEDED/REMOVED), advisor-plans/001-005 (DONE, predate removal of commit governance on 2026-08-26), docs/orchestration/criteria/ADM-*.txt + audit/wave-01, docs/specifications/architecture-stabilization-v1*.md (gated-commit era; ARC-001/ADM-002), commit-governance-audit.*, governance-remnants-audit.html, screenshot-functional-parity-v1.md (v2 governs conflicts).
Agent plumbing (not product): .agents/skills (879 dirs), .cursor/*, .codex/* (hooks/quality.py = denies destructive git + test deletion + protected-evidence writes), .specify/ (Spec Kit; constitution), openspec/config.yaml (empty template), skills-lock.json, scripts/install-*.sh, sync-gstack-skills.sh.
Generated HTML dashboards at root: spec.html, specProgress.html, status.html, guide.html, feature-parity-tracker.html (derived by scripts/annotate_parity.py, render_completion_spec.py), reports/project-status-environment.html.

## 3. Module map (Swift, Package.swift; ~29.6k LOC in Sources/, tests in lowercase `tests/`)
| Target | Role | Key files (LOC) |
|---|---|---|
| CSQLite | C shim: pinned/descriptor-bound SQLite open (`csqlite_open_pinned_rw`), links sqlite3+z | CSQLite.c |
| LedgerCore | Exact primitives (ExactDecimal, CurrencyAmount, SourceTemporal/TimeZone/LocalDate/UTCInstant, BoundedUTF8), domain (LedgerDomain, LedgerProducts), canonical schema v11 (CanonicalLedgerSchema), provenance | SourceTemporal 727, LedgerProducts 546 |
| LedgerAdapterSemantics | Vendor semantics isolated from core (MoneyManagerV19Semantics) | 1 file |
| LedgerStore | Writable canonical SQLite: LedgerStore (2506), LedgerStoreLifecycle (2563; create v11, v10->v11 upgrade with recovery image), LedgerApplication public command seam (1429), CanonicalLedgerHealth (1112), LedgerReceiptTrust; links Security | |
| MMImport | Perimeter: SourceClassifier + ZIP32Inspector, ImmutableSourceStager, SQLiteStagingStore, StagingReconciler (loss report), V19 adapter + observed-structure review, SQLiteCanonicalCommitter (3201, atomic/idempotent), ImportWorkspace (the only write path), CompatibilityCertification (L0-L5 named cells), SyntheticMoneyManagerOracle | |
| MMFixtures | synthetic fixtures | |
| LedgerAtlasMacUI | SwiftUI: LedgerAtlasRootView (2701), LedgerJourney (state/flows), LedgerSession, LedgerShell, ImportReview, PlanningViews, LedgerAppLock+LockSurfaces (Keychain passcode, LAContext), ReceiptAttachmentStore (Vision OCR), PDFStatementExporter, LedgerLoopbackPortal (NWListener 127.0.0.1), LedgerNotificationScheduler, RedactedWidgetProjection, LedgerIntentBridge (App-Group UserDefaults), SecurityScopedBookmarkStore, LedgerPortablePackageFile | |
| mmctl | CLI: inspect|classify, coverage, stage, reconcile (redacted JSON); cannot write canonical ledger | main.swift 452 |
| LedgerAtlasMac / LedgerAtlasWidget | App entry + 5 App Intents (AddExpense/AddIncome/AddTransfer/CreateBackup/OpenBudgets); WidgetKit extension | |
Dependency layering matches Package.swift (Core <- AdapterSemantics <- Store <- MMImport <- MacUI <- Mac). rg of imports found no illegal upward import.
Web: app/page.tsx, app/api/transactions/route.ts, lib/ledger.ts (cents-validated, write-lock, tmp+rename 0600), vitest 15 tests.
Python: tests/orchestration (5 files: brand mark, completion spec, mac container, quality hook, screenshot traceability), scripts/*.py.

## 4. Flows
Import: file -> `SourceClassifier` (read-only immutable open, hash first, profile match) -> `ImmutableSourceStager` -> `SQLiteStagingStore` -> `StagingReconciler` (every entity mapped/sidecar/excluded/blocking) -> `ImportWorkspace` approval -> `SQLiteCanonicalCommitter` (atomic, idempotent retry) -> canonical ledger -> `LedgerJourney`/`LedgerSession` opens it. Positive import only for the synthetic text-only v19 subset; real observed v19 is L0 classification/structure-review only.
Edit: UI -> `LedgerJourney` -> `LedgerApplication` commands (create/correct/tombstone, transfers w/ fee+FX, splits, installments, recurrence, budgets) -> `LedgerStore.mutate`.
Backup/restore: SQLite backup (`backupCanonicalDatabase`), portable package export (checksummed, tmp 0600 + move) and restore-as-new-ledger; lifecycle create/open/upgrade with security-scoped bookmark.
Locking: LedgerAppLock (passcode digest + state in Keychain, lockout 5->60s, 10->15min, biometrics).

## 5. Data and state
Canonical ledger: single SQLite file, owner-only 0600, rollback journal (no WAL), schema v11 (frozen v10 identity + category tree/account org). Staging DB per import. Receipts under 0700 dir, files 0600. Widget projection + pending intent via App Group `group.com.praxstack.ledgeratlas` UserDefaults. Keychain: lock digest + state. Web: data/transactions.json (gitignored). No network client code in Sources (rg URLSession: none).

## 6. Build / run / test (as documented and as observed)
- Web: `npm ci && npm run dev` (binds 0.0.0.0:3000), `npm test` (15 pass), `npm run typecheck` rc0, `npm run lint` rc0 (observed).
- Native: `./scripts/bootstrap.sh` (uv sync --frozen; ok), `./scripts/verify.sh --fast|--full`, `swift run mmctl`.
- Observed: `swift build` OK (Swift 6.4/Xcode 27, 29s). `swift test`: ~370 tests executed, 1 failure (LossReportTests.swift:34 "a public client cannot compile a caller-selected proof token", throws .io). `verify.sh` stops at its first step: ruff check/format fail on scripts/check-sync-gstack-skills.py (4 errors + 1 unformatted); pytest tests/orchestration passes (11). xcodebuild/xcodegen project build not attempted (comprehension pass).
- Xcode project generated by XcodeGen (`project.yml`); hard-coded DEVELOPMENT_TEAM 57GGJTRSFG; sandbox entitlements.

## 7. CI
None. `.github/` absent; `gh run list` empty; workflows API total_count 0. plans/001-ci-workflow.md still TODO.

## 8. GitHub backlog (2026-10-04)
Open issues: 58 (#1-#3 .. #59). #1 and #36 carry `wontfix` yet are open. #3-#32 old parent/foundation epics (mostly ready-for-agent); #37-#59 MACV2 tickets: #39 (MACV2-03) ready-for-agent, #40-#51,#54-#57 needs-info, #53,#58,#59 ready-for-human. PRs: 7 total (#60-#66), all merged, last 2026-08-30; later work (Mac completion, architecture review) landed by direct merge commits. Remote branches prax/architecture-review-20260823 and prax/mac-completion-v2: 0 commits ahead of main (fully merged, stale; 67/47 behind).

## 9. Roadmap vs reality (spot-checks, all against code at HEAD)
1. Schema v11 (CONTEXT) - CanonicalLedgerSchema.swift:19 `version = 11` TRUE. product-status.json says v10 - stale.
2. mmctl commands inspect/coverage/stage/reconcile only - main.swift:446-449 TRUE; no commit path.
3. No float for money - rg Double in LedgerCore/Store/MMImport: only temporal sub-second, ZIP ratio, one health ratio; TRUE for financial values.
4. 5 App Intents (MACV2-19, prd todo) - AppIntents.swift has 5 structs; implemented despite `todo`/needs-info.
5. Keychain app lock (MACV2-14 todo) - implemented (LedgerAppLock.swift, SecItem*, LAContext).
6. PDF statement export (MACV2-10 todo) - implemented (PDFStatementExporter CGContext PDF).
7. Receipt OCR (MACV2-12 todo) - implemented (VNRecognizeTextRequest, ReceiptAttachmentStore:152).
8. Loopback portal (MACV2-20) - NWListener bound to .ipv4(.loopback) TRUE; but sandbox entitlements lack network.server (see finding).
9. Backup "must show a warning" (plaintext) - NO warning text anywhere in Sources (rg plaintext/unencrypted: 0 hits). Spec claim unmet (ticket MACV2-15 still todo, so honest).
10. Package export mode 0600 + atomic - LedgerJourney.swift:455-458 TRUE (tmp, chmod 0600, moveItem).
11. Advisor plan 001 (December advance) / 002 (partial fee throws) - LedgerApplication.swift:100 `(fee == nil) != (feeAccountID == nil)` throws TRUE.
12. Widget redaction + App Group - RedactedWidgetProjection exists; entitlement group present.
13. "Normal commits resume; no gate" - .codex/hooks/quality.py only denies destructive git/test deletion; consistent.
14. Passing counts: product-status.json "283 tests", progress.txt "444 tests in 14 suites", observed ~370 (1 failing) - three different numbers.
Net: product is ahead of its status files. prd.json marks MACV2-03..23 `todo` although many underlying capabilities (editors, planning, lock, receipts, PDF, intents, portal, backup/restore) have commits d3b50bf..390f75d (Aug 31 - Sep 14). Unimplemented/unproven per docs: real-v19 lossless certification (0 certified cells), signed/notarized DMG, owner oracle session, iOS app, sync.

## 10. Risk areas where bugs likely live
1. SQLiteCanonicalCommitter (3.2k lines) and LedgerStoreLifecycle (v10->v11 upgrade, recovery image, TOCTOU) - data-loss class.
2. LedgerStore full-snapshot-per-mutate (advisor PERF-01 deferred) and CanonicalLedgerHealth replay.
3. Money/time arithmetic: SourceTemporal (DST/offset resolution), transfers with FX+fee, split rounding, report effect summing.
4. Backup/restore/package decode (fail-closed enums, nonempty destination), security-scoped bookmarks, sandbox entitlements.
5. App lock (unsalted digest), loopback portal token in URL query, intent bridge via shared UserDefaults.
6. UI god-file LedgerAtlasRootView (2.7k lines) and LedgerJourney state races (several stale-open tests exist).
7. Web demo: unauthenticated API on 0.0.0.0, unhandled GET failure.
8. Test suite coupling to SwiftPM build layout (.build/ module discovery in LossReportTests).
