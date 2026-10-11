# ledger-atlas fixes (branch fix/audit-2026-10 in <fix worktree>)

Scope: kept P0/P1 findings (0 P0; 4 P1). Nothing pushed.

| ID | Status | Commit | Test evidence | Remaining |
|----|--------|--------|---------------|-----------|
| LA-001 | fixed | 2090f6a | Before: ruff 4 errors (EXE001, I001, PLW1510, RUF059) + format diff. After: `ruff check` and `ruff format --check` clean, `pytest tests/orchestration` 11 pass, `scripts/check-sync-gstack-skills.py` PASS. | verify.sh itself not run end to end (its swift test step still hits LA-003). |
| LA-025 | fixed | f875c78 | New test `activityReportSignsByDirectionAndCountsTransferOnce` (LedgerApplicationTests): income 100, expense 40, same-currency transfer 25. Failed before (transfer row and total wrong); passes after (income 100, expense 40, transfer 25, total 60). All 47 LedgerApplicationTests pass. | Category rows (`categoryRows`) still sum raw amounts without direction; not in this finding. |
| LA-026 | fixed | 3780350 | New tests `amountEditPreservesNoteAndSplitMetadataAndKeepsSplitsVisible` (MacUI) and `splitPurchasesSkippingInvalidKeepsValidGroupsVisible` (LedgerStore). MacUI test failed before (note dropped; editing a split child threw .invalidCommand), passes after. Full `swift test`: all pass except known LA-003. | See notes. |
| LA-005 | needs-decision | none | Attempted ad-hoc signed sandboxed probe (NWListener on loopback, with/without network.server): both variants trap at launch (rc 133) in this environment, so inconclusive. The sandboxed app flow (NSOpenPanel, bookmark relaunch) cannot be driven headlessly. | Entitlements untouched. Apple docs say persistent security-scoped bookmarks need `com.apple.security.files.bookmarks.app-scope` and NWListener needs `com.apple.security.network.server`. Decision: add both to LedgerAtlas.entitlements and smoke-test with a signed build (create ledger, relaunch, reopen, start portal). network.server widens the sandbox, so owner should approve. |

## Notes
- LA-026: amount edit now copies the full draft (note, rounding, literals) and changes only the amount. Import-owned literals (`import.*`) and `conversion.*` are deliberately not copied: the canonical health check counts them across all revisions and rejects duplicates (copying them broke 3 import-journey tests). Multi-effect drafts are edited only when all legs share one currency (all legs get the new amount); mixed-currency edits are refused with invalidCommand instead of silently dropping legs. The UI split list now uses `LedgerApplication.splitPurchases(from:skippingInvalid: true)` so one malformed group no longer hides every split; the strict API is unchanged.
- LA-025 semantics: rows are income = net increases, expense = net decreases (positive), adjustment = signed net, transfer = per transaction the larger visible leg (max of increase legs, decrease legs in the report currency), summed; total = signed net of all effects (transfer legs cancel). Per-transaction leg added after review M1 (commit cea3ad8).
- Checks run: ruff, pytest, `swift build`/`swift test` (only LA-003 failure remains, pre-existing), `swift run mmctl` (schema=11 importer=11), `xcodebuild build -scheme LedgerAtlas` (CODE_SIGNING_ALLOWED=NO) BUILD SUCCEEDED. npm checks not run (no web files touched).

## Review follow-up (2026-10-08)
- M1 fixed (cea3ad8): transfer row computed per transaction, then summed. Regression test covers excluded-account, in+out to excluded, and cross-currency mixes (35 / 20 / 35).
- m1, m2, N3 fixed (e5f857c): createSplit uses the tolerant read; `LedgerApplication.splitPurchaseListing(from:)` (non-throwing) returns readable purchases plus the transaction ids/count of unreadable groups; the ledger view keeps those rows visible and shows a notice. `splitPurchases(from:skippingInvalid:)` removed (added on this branch only).
- m3 (971d144, 4d12817, 8166957): tests for rounding policy, tag literal and note on amount edit; same-currency transfer edit (both legs, directions kept); cross-currency refusal (checksum unchanged); negative adjustment sign.
- N1, N2 (2a7d6c8): comment corrected; conversion.* filter marked defensive.
- m4: won't fix, by design. An amount edit does not copy the six `import.*` provenance literals onto the new revision, because the import health SQL (CanonicalLedgerHealth.swift) selects them across all revisions and would see duplicates. Revision 1 keeps the provenance.
- N4: not changed; owner decision (relabel "Total" as "Net" in the accessible table/PDF).
