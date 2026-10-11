# Graph insights - ledger-atlas (graphify 0.9.74, built from d2c2ba3)

Graph: 71,044 nodes / 99,960 edges / 5,006 communities. Caveat: ~92% of nodes (65,349) come from `.agents/` (vendored skill packs), 2,480 from Sources/, 870 tests, 381 docs. Community hubs, "surprising connections" and the 39,463 "isolated nodes" are dominated by skill content (last30days, cloudflare refs, poteto-mode, etc.) and are NOT product signal. Recommendation: exclude `.agents/` and `.cursor/` via `.graphifyignore` for any future product graph.

## God nodes (product)
LedgerStore (154 edges), SQLiteCanonicalCommitter (145), LedgerStoreLifecycle (143), LedgerJourney (137), SourceTimeZone (121), UTCInstant (112), ExactDecimal (110), LedgerAccount (106), SourceTemporal (90), SourceLocalDate (89).
Meaning: two persistence hubs (LedgerStore, Committer) + lifecycle manager = highest blast radius for data-loss bugs; the temporal types are the most-depended primitives (any change to time semantics ripples through import, reports, UI); LedgerJourney is the single UI-side orchestrator (shortest path LedgerJourney -> approveAndOpen -> commit -> SQLiteCanonicalCommitter is 3 hops, two INFERRED).

## Communities (product-relevant)
LedgerJourney (UI orchestration + docs describing 5.1 RootView), SQLiteCanonicalCommitter (import commit + canonical models), LedgerStore, LedgerStoreLifecycle (+ LedgerStoreLifecycleTests), CanonicalLedgerHealthSemanticReplayTests, LedgerAppLock (34 nodes, tight, referenced only from LedgerAtlasRootView:99/128), SourceTimeZone/temporal, SyntheticMoneyManagerOracle, StagingManifest/StagingRequest, RoundingPolicy.

## Layering / coupling
- Cross-module edge aggregation (Sources only) follows Package.swift: Store->Core 324, MacUI->Core 212, MMImport->Core 121, MacUI->Store 65, MMImport->Store 10 (SQLiteCanonicalCommitter only imports LedgerStore), Store->AdapterSemantics 15.
- Apparent back-edges (LedgerStore->LedgerAtlasMacUI 9, LedgerAdapterSemantics->MMImport 4) and Sources->tests edges are label/name collisions of the extractor (`rg '^import'` shows no such imports). No real layering violation. Graphify reports "Import Cycles: None detected".
- Notable but legitimate coupling: LedgerAtlasMacUI depends directly on MMImport (ImportReview/ImportWorkspace) so UI knows the importer, not just the canonical store.

## Isolated / entry-point files (no inbound edges)
Only entry points and shims: LedgerAtlasMacApp.swift, AppIntents.swift, LedgerAtlasWidget.swift, mmctl/main.swift, CSQLite.c/.h, LedgerCore.swift, MMImport.swift, MMFixtures.swift (5-line placeholders), plus MoneyManagerV19ObservedGraph.swift and SyntheticMoneyManagerOracle.swift (reached by tests/other modules via type names the extractor did not link). No dead production module found. Placeholder files LedgerCore.swift/MMImport.swift/MMFixtures.swift are 4-5 lines (harmless).

## Docs vs code
- Graph links docs/specifications/architecture-stabilization-v1.md to csqlite_open_pinned_rw(): spec concept present in code.
- Docs that describe components absent/disabled: AGENTS.md `.scratch/ledger-atlas-end-to-end/issues/` (not in repo; .scratch untracked), CLAUDE.md `docs/adr/` (actual dir is docs/decisions), commit-gate system (ADM-*, criteria/*.txt) described in many docs but removed from code (.codex hooks only keep a quality hook).
- Code present with docs saying todo: App Intents, lock, PDF, OCR, portal, planning (prd.json MACV2-10..20 `todo`).
- Web track (app/, lib/) is an isolated 4-file island with no link to the Swift product.

## Hotspots for later hunters
LedgerStore/Lifecycle/Committer cluster (largest, most connected), temporal primitives, LedgerJourney, LedgerAppLock.
