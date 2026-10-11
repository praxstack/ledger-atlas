# ledger-atlas review: fix/audit-2026-10

Reviewer: independent Opus review, 2026-10-08. Worktree `<fix worktree>` (HEAD `3780350`), merge-base with origin/main `d2c2ba3`. Branch left as it was: no edits, commits or checkouts. Behaviour checks ran in throwaway detached worktrees (`/tmp/review-ledger-atlas-base` at d2c2ba3, `/tmp/review-ledger-atlas-probe` at 3780350). Both have been removed. All data was synthetic.

## Verdict: request-changes

LA-001 is clean. LA-026 is correct, including the multi-currency refusal, and is well tested. LA-025 fixes the two cases the finding names: income plus expense no longer add together, and a single same-currency transfer is no longer counted twice. The transfer row is still wrong whenever there is more than one transfer and at least one of them shows only one leg in the report's currency. That covers a cross-currency transfer, or a transfer to or from an account excluded from totals or hidden. This is a money-correctness bug in code the branch just wrote, so it should be fixed before merge. The fix is small and I validated it below.

Counts: blocker 0, major 1, minor 4, nit 4.

## Per-commit verdicts

| Commit | Finding | Verdict | Notes |
|---|---|---|---|
| 2090f6a | LA-001 | approve | Apart from formatting: imports sorted (I001), `check=False` added to `subprocess.run` (PLW1510, same behaviour), unused `cursor` renamed to `_cursor` (RUF059), mode set to 100755 (EXE001). Diffed against ruff-formatted base: no other changes. ruff check, ruff format and pytest are green. |
| f875c78 | LA-025 | request-changes | Total is now the signed net (correct). Income, expense and adjustment rows are signed correctly. The transfer row is still wrong when transfers are mixed (M1). The new test fails on base and passes on head, but it only covers the single-transfer case. |
| 3780350 | LA-026 | approve-with-nits | correctAmount copies note, rounding, tag, split, installment and recurrence literals. Same-currency transfers update both legs, and the fee transaction stays separate and unchanged. Cross-currency transfers are refused with `invalidCommand` and the ledger is byte-identical afterwards. The tolerant split read works. Residual issues are m1 to m4 and the nits. |

## Findings

### M1 (major): transfer row mixes up one-sided and two-sided transfers. Sources/LedgerStore/LedgerApplication.swift:529-533, 556-558

`increases` is summed across every transfer of the kind. The row then shows `increases` if it is non-zero, and `-net` only when it is zero. When a two-sided transfer and a one-sided transfer appear together, the one-sided transfer's visible leg is lost. When an inbound and an outbound one-sided transfer appear together, one of them is lost.

Evidence (probe tests run on 3780350, synthetic USD and EUR accounts):

| Scenario | Expected transfer row | Actual | Total (correct) |
|---|---|---|---|
| A: One→Two 25 (both included) + One→Off 10 (Off `includeInTotals: false`) | 35 | **25** | -10 |
| B: Off→One 10 + One→Off 10 | 20 | **10** | 0 |
| C: One→Two 25 USD + One→EUR 10 USD→9 EUR (with conversion) | 35 | **25** | -10 |
| D: One→Two 25 with a 1.50 fee | 25, adjustment -1.5 | 25, -1.5 | -1.5 |

Scenario C is the ordinary case of one FX transfer plus any local transfer. The USD activity report then under-reports the transfer value. The FIXES.md claim "transfer = one leg" holds only per kind in aggregate, not per transaction.

Suggested fix (validated): compute the leg per transaction, then sum. Inside the per-transaction loop:
```swift
var txIn = zero, txOut = zero
for effect in matching { if effect.direction == .increase { txIn = try txIn.adding(effect.amount.amount) } else { txOut = try txOut.adding(effect.amount.amount) } }
entry.oneLeg = try entry.oneLeg.adding(txOut < txIn ? txIn : txOut)
```
Then use `shown = entry.oneLeg` for `.transfer`. I applied this in the probe worktree. Scenarios A to D give 35 / 20 / 35 / 25. All 175 LedgerStoreTests pass, including the existing cross-currency test at LedgerApplicationTests.swift:2246-2275 and the new LA-025 test. Add scenarios A and C as regression tests.

### m1 (minor): one malformed split group still blocks creating any new split. Sources/LedgerStore/LedgerApplication.swift:165

`createSplit(_:createdAt:)` still calls the strict `Self.splitPurchases(from:)`. If the ledger holds a malformed group, every new split creation throws `invalidCommand`. Probe: one valid group, then one group with a child corrected without its split literals, then a brand-new split with fresh IDs fails with `invalidCommand`. Ledgers where a split child was amount-edited before this fix already contain such a group. The UI read is fixed, but split creation is still broken for those users. Suggestion: use the tolerant read for the "existing purchase with this id" lookup at :165, which matters only for the requested id, and the strict or targeted read at :173. Alternatively, track this as a follow-up.

### m2 (minor): malformed group's transactions disappear from both lists without any notice. Sources/LedgerAtlasMacUI/LedgerAtlasRootView.swift:1099-1110, 1437

`splitTransactionIDs` is built from `.split` links, so a malformed group's children are removed from the main list. `splitPurchases(skippingInvalid: true)` drops the same group from the split list. The money still counts in reports, but the user cannot see or fix those rows, and nothing tells them. This is better than before (previously every group was hidden), but the finding's "no try? ?? []" asked for the failure to be surfaced. Suggestion: return the skipped parent IDs, or a count, and show a notice. Alternatively, exclude from `splitTransactionIDs` only the members of groups that parsed.

### m3 (minor): tests miss the cases the fix claims to handle. tests/LedgerStoreTests/LedgerApplicationTests.swift:2395-2440, tests/LedgerAtlasMacUITests/LedgerJourneyTests.swift:820-878

- The LA-025 test's income and expense assertions already passed on base. Base failed only the transfer row and the total. No test covers a negative adjustment (sign change from base), a refund-style increase, the excluded-account case, or the mixed transfers that expose M1.
- The LA-026 commit title claims "rounding, tags" are kept, but no test checks `roundingPolicy` or a `tag.*` literal. Nothing tests the same-currency transfer edit (both legs), the cross-currency refusal (I checked both by probe), or that the edited import transaction keeps working after reopen.

### m4 (minor): editing an imported transaction drops all six `import.*` provenance literals from the new revision. Sources/LedgerAtlasMacUI/LedgerJourney.swift:253-258

Probe: before the edit the current revision has `import.eventID`, `import.v19Commitment`, `import.v19ReceiptGeneration`, `import.v19SourceSubjectSet`, `import.v19SourceTimeZone` and `import.v19TemporalAnchor`. After the edit it has none. The FIXES.md reason holds up: the health SQL at CanonicalLedgerHealth.swift:478/508/533/574 selects these fields across all revisions of a transaction, so copying them would create duplicates. Revision 1 keeps the provenance. This is a deliberate trade-off, not a bug, but the code comment on line 239 says "provenance literals ... carry over", which is the opposite of what happens (see N1). The finding asked for provenance to be kept. That part is "won't fix, by design" and should be stated that way in FIXES.md.

### Nits
- N1 LedgerJourney.swift:239: the comment says "note, rounding, provenance literals and every other field carry over". Import provenance literals do not carry over. Reword it to say only user-level literals carry over.
- N2 LedgerJourney.swift:257: the `conversion.` filter can never run. Conversion literals only exist on cross-currency transfers, which the guard at :243-245 refuses. Remove it, or keep it with a comment saying it is defensive.
- N3 LedgerAtlasRootView.swift:1101: `(try? …(skippingInvalid: true)) ?? []`. With `skippingInvalid: true` the call cannot throw (`splitPurchaseGroups` does not throw, and each closure is wrapped in `try?`), so the outer `try?` and `?? []` are dead. The `throws` on the tolerant overload (LedgerApplication.swift:212-217) is also misleading. xcodebuild flags it: `LedgerApplication.swift:216:12: warning: no calls to throwing functions occur within 'try' expression`, a new warning that this branch introduces.
- N4 LedgerApplication.swift:556-558: rows are now magnitudes (income 100, expense 40, transfer 25) while `totalLiteral` is the signed net (60). The rows no longer add up to "Total" in `accessibleTable` (LedgerProducts.swift:365) or in the PDF export. Consider labelling it "Net" so screen-reader and PDF users read it correctly.

Also checked, no issue:
- correctAmount on a split child keeps the group readable. The derived purchase total changes from 5.00 to 5.25, which is intended because the parent amount is derived from the line amounts.
- No secrets or PII in the diff. No dependency or lockfile changes (`npm ci` left the tree clean).
- Commit subjects match their content. Co-author lines are present.

## Check results (branch head 3780350 vs base d2c2ba3)

| Check | Base (SETUP.md / audit logs) | Head |
|---|---|---|
| `.venv/bin/ruff check scripts .codex/hooks tests/orchestration` | FAIL (4 errors) | PASS |
| `.venv/bin/ruff format --check …` | FAIL (1 file) | PASS (9 files formatted) |
| `.venv/bin/pytest tests/orchestration` | 11 pass | 11 pass |
| `python3 scripts/check-sync-gstack-skills.py` | n/a | PASS (all cases) |
| `swift build` | pass | pass |
| `swift test` | 486 passing tests, 1 failure (LA-003 LossReportTests.swift:34 `.io`) | 489 passing (base set plus the 3 new tests), same single LA-003 failure, rc=1 |
| `swift run mmctl` | `schema=11 importer=11` | `schema=11 importer=11`, rc=0 |
| `npm ci && npm run lint && npm run typecheck && npm test` | pass, 15 tests | pass, 15 tests (3 files) |
| `xcodebuild build -scheme LedgerAtlas … CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED | BUILD SUCCEEDED (rc=0) |

Test checks run on base code (new tests copied into the base worktree):
- `activityReportSignsByDirectionAndCountsTransferOnce` fails on base at the transfer-row and total assertions. It passes on head.
- `amountEditPreservesNoteAndSplitMetadataAndKeepsSplitsVisible` fails on base: the note is dropped and the strict split read throws `.invalidCommand`. It passes on head.
- `splitPurchasesSkippingInvalidKeepsValidGroupsVisible` cannot compile on base because the new API does not exist there. Its strict-throws and tolerant-count assertions are meaningful.

`./scripts/verify.sh` was not run end to end. Its `swift test` step still fails on LA-003, which this branch does not touch.

## FIXES.md claims

- Confirmed: the LA-001 before/after results. The LA-025 test fails before and passes after. The LA-026 MacUI test fails before (note dropped, `.invalidCommand`). The full `swift test` has only the LA-003 failure. mmctl and the xcodebuild result. Copying `import.*` literals breaks the import health check: consistent with the SQL in CanonicalLedgerHealth.swift. I did not reproduce the 3 test failures myself.
- Overstated: "transfer = one leg" for LA-025. That holds per kind only when every transfer shows both legs or every transfer shows one. It fails for mixed sets (M1). "Amount edit keeps … tags … rounding" is true by code reading but untested (m3).
- Could not confirm: "All 47 LedgerApplicationTests pass". I ran the full suite rather than counting that subset. All LedgerStore tests pass on head, so the claim is consistent but its number is unverified. LA-005 (needs-decision, no commit) is out of scope for this review.
