# Ledger Atlas audit report (HEAD d2c2ba3, 2026-10-04)

Repo: <repo root> (private, praxstack/ledger-atlas). Audit files: this directory. Machine-readable list: findings.json (54 entries incl. 7 merged duplicates).

## 1. What it is
Local-first, macOS-first personal-finance app plus a small Next.js 15 demo ledger. Product: Swift 6.2 (SwiftPM + XcodeGen project.yml), canonical SQLite ledger schema v11, exact-decimal money, Money Manager (Realbyte) Android v19 importer with immutable staging and loss reports, SwiftUI shell, widget, 5 App Intents, Keychain app lock, PDF export, receipt OCR, loopback status portal, mmctl CLI. Web track: app/ + lib/ (~530 lines, one GET/POST route, JSON-file store). 72 commits, burst 2026-08-19..09-14, last commit 2026-09-14. Of 6296 tracked files, 6012 are vendored `.agents/` skills; about 284 are product.
Maturity: advanced prototype. Core import/store engine is heavily hardened and tested (502 swift tests pass). UI/product layer is partly built; release-one stories (US-22/23/27/28), widget data, budgets and release packaging are incomplete; no CI; status docs stale.

## 2. Setup on this Mac
Status: working. Needs no env vars or secrets. Details in SETUP.md. Xcode pending: no.
```sh
cd <repo root>
npm ci && npm run lint && npm run typecheck && npm test && npm run build   # all pass; vitest 15/15
npx next start --hostname 127.0.0.1 --port 3917                            # smoke ok (200/201/400); package.json scripts bind 0.0.0.0
uv sync --frozen && .venv/bin/pytest tests/orchestration                   # 11 pass
.venv/bin/ruff check scripts .codex/hooks tests/orchestration              # FAIL: 4 errors (LA-001)
swift build                                                                # pass (~30s)
swift test                                                                 # 502 pass, 1 fail (LA-003), ~2 min
swift run mmctl                                                            # schema=11 importer=11
xcodebuild build -project LedgerAtlas.xcodeproj -scheme LedgerAtlas -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO  # BUILD SUCCEEDED; app launched 6s, no crash
```
Failed/blocked: `./scripts/verify.sh` (aborts at ruff, before Swift); `swift test` one failure; signing with `CODE_SIGN_IDENTITY=-` fails (needs team 57GGJTRSFG; use CODE_SIGNING_ALLOWED=NO). Not run: `swift build -c release`, `xcodegen generate`, signed/sandboxed app (widget, intents, sandbox behavior unexercised). Nothing left running.

## 3. Architecture and graph insights
Graph: 71,044 nodes / 99,960 edges, but 92% is `.agents/` noise (exclude via .graphifyignore). Layers: LedgerCore (ExactDecimal, SourceTemporal) -> MMImport (stager, classifier, reconciler, SQLiteCanonicalCommitter) -> LedgerStore (LedgerStore, Lifecycle, LedgerApplication commands) -> LedgerAtlasMacUI (LedgerJourney orchestrator, LedgerAtlasRootView) -> app/widget targets. God nodes by edges: LedgerStore 154, SQLiteCanonicalCommitter 145, LedgerStoreLifecycle 143, LedgerJourney 137, SourceTimeZone 121, UTCInstant 112, ExactDecimal 110. Persistence hubs have the highest data-loss blast radius; temporal types are the most depended-on primitives (DST bugs LA-029/037 ripple). LedgerJourney -> commit -> SQLiteCanonicalCommitter is 3 hops. Most correctness bugs found sit in the application/UI layer (LedgerApplication, LedgerJourney), not the hardened import core. See GRAPH_INSIGHTS.md.

## 4. Security posture
No real secrets found. No first-party code vulns beyond the items below. Positive: parameterized SQL, quoted identifiers, query_only/trusted_schema=OFF imports, O_NOFOLLOW descriptors, no Process/URLSession in Sources, 0600 files, sandboxed entitlements minimal.

| Tool | Result | Triage |
|---|---|---|
| gitleaks history (65 commits) | 27 hits | 0 true (ULID form ids, UserDefaults key name LedgerIntentBridge.swift:30, skill docs) |
| gitleaks tree | 164 hits | 0 true (mostly graphify cache, .agents docs) |
| trufflehog history | 15 unverified | 0 true (placeholders in .agents docs) |
| trivy fs | 4 vulns in root lock | postcss; rest in .agents (LA-012, LA-011) |
| osv-scanner | root: postcss, vitest, brace-expansion | LA-012 |
| semgrep | 136 (135 in .agents) | 0 first-party |
| npm audit | 10 (7 high, 3 mod) | dev/build-time (LA-012) |
| GitHub Dependabot / secret / code scanning | disabled | LA-024 |

Triaged findings: LA-009 (LAN-exposed unauthenticated API, P2), LA-010 (weak lock digest, P2), LA-005 (missing entitlements, plausible), LA-012, LA-022, LA-011, LA-024. Not exhaustively verified: App Intents note/amount validation, Keychain class, backup flow end to end; hardened runtime/notarization not in repo.

## 5. Prioritized backlog (47 kept: 4 P1, 24 P2, 19 P3; 0 P0; 0 refuted; 7 merged duplicates: LA-015->003, LA-016->001, LA-018/020->009, LA-021->012, LA-023->011, LA-027->005)
Note: LA-005 keeps P1 from merged LA-027 (plausible; unverifiable without a signed sandboxed build).

| id | sev | cat | title | file:line | verdict | suggested fix |
|---|---|---|---|---|---|---|
| LA-001 | P1 | build-ci | scripts/verify.sh fails at first step (ruff) on clean main | scripts/check-sync-gstack-skills.py:1-207 | confirmed | Fix 4 ruff errors (EXE001,I001,PLW1510,RUF059), ruff format, rerun verify.sh --fast/--full |
| LA-025 | P1 | bug | Activity report ignores direction: income+expense summed, transfers double-counted (probe: 100/40/25 gives total 190) | Sources/LedgerStore/LedgerApplication.swift:501-535 | confirmed | Sign by direction, count transfer once, total = net; add mixed-ledger test |
| LA-026 | P1 | bug | Amount edit drops note/tags/rounding/provenance and extra effects; one edited split child makes splitPurchases throw so UI hides all splits | Sources/LedgerAtlasMacUI/LedgerJourney.swift:232-252; LedgerAtlasRootView.swift:1101 | confirmed | Copy current draft, change only amount; tolerate bad split group; no try? ?? [] |
| LA-005 | P1 | bug | Sandbox entitlements lack bookmarks.app-scope and network.server (merged LA-027); signed build may fail to retain ledger access / start portal | LedgerAtlas.entitlements:1-20; SecurityScopedBookmarkStore.swift:38; LedgerLoopbackPortal.swift:80-84 | plausible | Add both entitlements; signed sandboxed create/relaunch/reopen smoke test |
| LA-002 | P2 | build-ci | No CI workflow exists | - | confirmed | Add macOS workflow per plans/001 (swift build/test, npm lint/typecheck/test, uv+ruff+pytest) |
| LA-003 | P2 | test-gap | swift test fails on Swift 6.4: public-API typecheck test cannot find CSQLite modulemap | tests/MMImportTests/Reconciliation/LossReportTests.swift:34,528-569 | confirmed | Find *CSQLite*.modulemap or use swift build --show-bin-path; fail loudly |
| LA-004 | P2 | spec-drift | No plaintext-backup warning before backup/portable export | Sources/LedgerAtlasMacUI/LedgerAtlasRootView.swift:404-419,926-936 | confirmed | Add confirmation alert + test |
| LA-006 | P2 | spec-drift | prd.json/product-status/CONTEXT lag the code (21 of 23 tickets still todo) | prd.json:release_one.tickets | confirmed | Truth-reconcile pass with per-ticket evidence |
| LA-008 | P2 | bug | Web GET /api/transactions unhandled when ledger file invalid; UI assumes ok | app/api/transactions/route.ts:4-10; app/page.tsx:33-36 | confirmed | try/catch 500 JSON, check response.ok, add test |
| LA-009 | P2 | security | Web dev/start bind 0.0.0.0 with unauthenticated read/write finance API, no Origin/Content-Type check (merged LA-018, LA-020) | package.json:6-7; app/api/transactions/route.ts | confirmed | Bind 127.0.0.1; require application/json + Origin check |
| LA-010 | P2 | security | App lock: unsalted SHA-256 of short passcode; UI-only gate | Sources/LedgerAtlasMacUI/LedgerAppLock.swift:169-181,195-215 | confirmed | Per-install salt + slow KDF; document lock is UI-only (P3 defensible) |
| LA-028 | P2 | bug | Recurrence catch-up throws after 366 iterations | Sources/LedgerStore/LedgerApplication.swift:367-398 | confirmed | Scale cap to range or chunk; typed error |
| LA-029 | P2 | bug | Day-precision recurrence fails in zones with DST gap at midnight (Havana probe) | Sources/LedgerStore/LedgerApplication.swift:377-381 | confirmed | Gap-tolerant policy for .day |
| LA-030 | P2 | bug | Monthly/yearly recurrence drifts to clamped day (1-31,2-28,3-28...) when dayOfMonth nil | Sources/LedgerStore/LedgerApplication.swift:813-831 | confirmed | Compute from anchor + k*interval |
| LA-031 | P2 | bug | Stale bookmarks never renewed; .renewed unreachable | Sources/LedgerAtlasMacUI/SecurityScopedBookmarkStore.swift:95-102 | confirmed | Re-save on stale; remove dead params |
| LA-032 | P2 | incomplete | Budgets stored but never evaluated; rollover/period-start/first-weekday inert | Sources/LedgerAtlasMacUI/PlanningViews.swift:340-400 | confirmed | Implement or remove controls |
| LA-040 | P2 | incomplete | US-28 XLSX exchange and complete/contents-only reset not implemented | Sources/ (absent) | confirmed | Implement typed commands or descope US-28 |
| LA-041 | P2 | incomplete | Receipts not linked to any transaction, state lost on navigation, not in backup, OCR raw lines only | Sources/LedgerAtlasMacUI/ReceiptSurface.swift:5-9,80-100 | confirmed | Receipt-link command, include in backup, category suggestions |
| LA-042 | P2 | incomplete | Restore supports only new ledger; spec US-27 wants merge/overwrite with preview | Sources/LedgerAtlasMacUI/LedgerAtlasRootView.swift:356-400 | confirmed | Add preview + modes or reduce spec |
| LA-043 | P2 | perf | Each mutation reads full ledger 3x on main actor (mechanism confirmed, magnitude unmeasured) | Sources/LedgerStore/LedgerStore.swift:2001-2026 | confirmed | 50k-txn benchmark; incremental validate; off MainActor |
| LA-044 | P2 | tech-debt | Store failures collapsed into opaque errors; no os.Logger | Sources/LedgerStore/LedgerStore.swift:2022-2026 | confirmed | Typed reasons + redacted logging |
| LA-045 | P2 | incomplete | Widget static banner, never reloaded, no summary data | Sources/LedgerAtlasWidget/LedgerAtlasWidget.swift:22-41 | confirmed | Publish ready/locked projections; reloadAllTimelines |
| LA-046 | P2 | build-ci | No app icon/category/copyright, LICENSE, or release pipeline (P3 arguable) | project.yml:18-45 | confirmed | AppIcon catalog, plist keys, archive/notarize/DMG script |
| LA-047 | P2 | bug | PDF statement picks one arbitrary currency, omits others silently | Sources/LedgerAtlasMacUI/LedgerAtlasRootView.swift:335-342 | confirmed | Pick currency or per-currency sections |
| LA-048 | P2 | incomplete | Portable package export refuses imported ledgers; createdAt 0 | Sources/LedgerStore/LedgerApplication.swift:618-648 | confirmed | Extend schema or explain; real timestamp |
| LA-049 | P2 | build-ci | verify.sh skips web track and swiftlint; toolchains unpinned (P3 arguable) | scripts/verify.sh:17-33 | confirmed | Add npm checks; pin node/swift |
| LA-050 | P2 | tech-debt | LedgerAtlasRootView 2701-line god view, 35 try?, silent import-dir failure (borderline P2) | Sources/LedgerAtlasMacUI/LedgerAtlasRootView.swift:1-2701 | confirmed | Split; replace silent returns with recordFailure |
| LA-033 | P2 | bug | Queued App Intent may be missed on cold launch, then jams slot | Sources/LedgerAtlasMacUI/LedgerAtlasRootView.swift:217-233 | plausible | Consume after launch reopen; TTL |
| LA-007 | P3 | docs | JOURNAL/progress/ADR 0010/CLAUDE.md contradict repo reality | JOURNAL.md:3-9; CLAUDE.md:3,17 | confirmed | Mark historical, fix paths and status |
| LA-011 | P3 | tech-debt | 6012 of 6296 tracked files are vendored .agents skill packs (merged LA-023); vulnerable pins, scanner noise | /.agents/ | confirmed | Untrack (canonical copy is ~/.agents/skills) or add scanner/graph ignores |
| LA-013 | P3 | docs | Open wontfix issues #1,#36; two merged-undeleted remote branches | - | confirmed | Close issues, delete branches (owner) |
| LA-017 | P3 | build-ci | Xcode project fails with CODE_SIGN_IDENTITY=-; only CODE_SIGNING_ALLOWED=NO works, undocumented | project.yml:20-70 | confirmed | Document flag or add unsigned config |
| LA-022 | P3 | security | Loopback portal hardening: token in query string, == compare, no Host check | Sources/LedgerAtlasMacUI/LedgerLoopbackPortal.swift:96,113-135 | confirmed | Header token, constant-time compare, guard token with queue |
| LA-024 | P3 | build-ci | GitHub Dependabot/secret scanning disabled; hardened runtime not set | LedgerAtlas.xcodeproj/project.pbxproj | confirmed | Enable GitHub features; ENABLE_HARDENED_RUNTIME=YES for release |
| LA-034 | P3 | bug | Installment split uses principal literal scale (100 in 3 gives 33,33,34) | Sources/LedgerStore/LedgerApplication.swift:299-306 | confirmed | Use currency minor-unit scale |
| LA-036 | P3 | bug | Undecodable pending-intent payload jams slot forever; no TTL | Sources/LedgerAtlasMacUI/LedgerIntentBridge.swift:34-52 | confirmed | Drop bad payloads; add createdAt+TTL |
| LA-039 | P3 | bug | POST /api/transactions returns 400 for every server failure and leaks message | app/api/transactions/route.ts:28-34 | confirmed | 400 only for validation; generic 500 |
| LA-051 | P3 | test-gap | LedgerNotificationScheduler and PlanningViews untested | tests/LedgerAtlasMacUITests | confirmed | Inject notification center; view-model tests |
| LA-052 | P3 | docs | Agent docs cite nonexistent paths (docs/adr, prompts/..., md-personas) | AGENTS.md / CLAUDE.md / docs/agents/*.md | confirmed | Repoint to docs/decisions |
| LA-053 | P3 | ux | Web page has no error handling for failed fetches | app/page.tsx:31-60 | confirmed | try/catch, ok check, error state |
| LA-012 | P3 | security | Vulnerable npm dev/transitive deps: postcss 8.4.31, vitest/mocker 3.2.7, brace-expansion (merged LA-021) | package-lock.json | plausible | npm audit fix, bump vitest, postcss override |
| LA-014 | P3 | tech-debt | God files (SQLiteCanonicalCommitter 3201 lines, LedgerStoreLifecycle, LedgerStore) | Sources/MMImport/Commit/SQLiteCanonicalCommitter.swift | plausible | Split along seams after CI exists |
| LA-019 | P3 | test-gap | Xcode schemes have no test action | project.yml | plausible | Add test action or document swift test as entry point |
| LA-035 | P3 | bug | Loopback portal unsynchronized state; continuation unresumed if stopped during start | Sources/LedgerAtlasMacUI/LedgerLoopbackPortal.swift:44-130 | plausible | Confine to queue/actor; resume on .cancelled; reject empty token |
| LA-037 | P3 | bug | Native transaction creation uses local midnight with .reject policy; may fail on DST-midnight dates | Sources/LedgerAtlasMacUI/LedgerJourney.swift:417-423 | plausible | Gap-tolerant policy |
| LA-038 | P3 | bug | Restore flows treat destination security scope inconsistently | Sources/LedgerAtlasMacUI/LedgerAtlasRootView.swift:356-460 | plausible | Treat false from startAccessing as non-fatal; unify |
| LA-054 | P3 | build-ci | Swift toolchain range undocumented, no .swift-version | Package.swift:1-4 | plausible | Document Xcode/Swift range |
## 6. Incomplete work vs roadmap
- prd.json: 21 of 23 MACV2 tickets marked todo while code exists for intents, app lock, PDF export, OCR, planning, portal (LA-006). Reconcile first.
- Not delivered vs spec: plaintext backup warning (LA-004, MACV2-15), US-28 XLSX/reset (LA-040), US-22/23 receipt linkage (LA-041), US-27 restore merge/overwrite (LA-042), widget data D-09 (LA-045), budgets/rollover (LA-032), package export for imported ledgers (LA-048), signed-DMG packaging MACV2-23 (LA-046), sandbox smoke tests MACV2-20/23 (LA-005).
- plans/001-ci-workflow.md still TODO (LA-002). GitHub: 58 open issues, #1/#36 wontfix but open (LA-013).
- Not reviewed in depth: SQLiteCanonicalCommitter, lifecycle upgrade recovery, MMImport adapters; no coverage or perf benchmark run.

## 7. Recommended next 5 actions
1. Fix scripts/check-sync-gstack-skills.py lint/format so verify.sh runs; fix LossReportTests modulemap lookup (LA-001, LA-003). Gets a green local gate.
2. Fix report totals and amount-edit data loss with regression tests (LA-025, LA-026); these produce wrong money and silent data loss on common paths.
3. Add bookmarks.app-scope and network.server entitlements and run a signed sandboxed create/relaunch/reopen smoke test (LA-005, LA-031).
4. Add plaintext-backup warning and bind web scripts to 127.0.0.1 (LA-004, LA-009); then add CI from plans/001 including web and verify.sh (LA-002, LA-049).
5. Truth-reconcile prd.json/CONTEXT/product-status and untrack or ignore `.agents/` (LA-006, LA-011); then recurrence fixes (LA-028/029/030).
