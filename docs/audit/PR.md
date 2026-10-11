# ledger-atlas PR

PR: https://github.com/praxstack/ledger-atlas/pull/67 (open, not draft, no auto-merge, no reviewers requested)
Branch: fix/audit-2026-10 -> main, head 8166957. Body file: PR-BODY.ledger-atlas.md. I read it back with `gh pr view`: it matches the file and references LA ids only.

## Commits added in step 1 (review follow-up)
- cea3ad8 fix(report): transfer row computed per transaction as max(increase, decrease) legs, then summed [review: M1]
- e5f857c fix(splits): tolerant split read in createSplit; non-throwing splitPurchaseListing; unreadable groups stay visible with a notice [review: m1, m2, N3]
- 971d144 test(ui): rounding, tags, transfer legs, cross-currency refusal on amount edit [review: m3]
- 2a7d6c8 fix(ui): correct the provenance comment; conversion.* filter marked defensive [review: N1, N2]
- 4d12817 test(report): negative adjustment sign [review: m3]
- 8166957 test(ui): run the amount-edit test on an empty ledger. The first version made the timing-sensitive lifecycle test fail under full-suite load. [review: m3]

## Check results (head 8166957)
- ruff check / ruff format --check: pass. pytest tests/orchestration: 11 pass. check-sync-gstack-skills.py: PASS.
- swift build: pass. swift run mmctl: `schema=11 importer=11`, rc=0.
- swift test: 490 passing test lines, 1 failure (LA-003 LossReportTests.swift:34 `.io`, same as base), rc=1. Ran the full suite twice with the same result.
- npm ci, lint, typecheck, test: pass (3 files, 15 tests).
- xcodebuild build -scheme LedgerAtlas (CODE_SIGNING_ALLOWED=NO): BUILD SUCCEEDED. The new "no calls to throwing functions" warning is gone.

## Codex
- Posted `@codex review` and `@codex security review`. The private repo uses PR comments. A Codex code review was running on 8166957 when I checked.
- CodeRabbit hit its free-plan rate limit, so it only posted a summary.

## Open owner decisions
- N4: relabel "Total" as "Net" in the accessible table and PDF, since rows are magnitudes and Total is the signed net.
- LA-005: add `files.bookmarks.app-scope` and `network.server` entitlements, then run a signed-build smoke test.
- m4: won't fix by design. `import.*` provenance stays on revision 1 because the health SQL rejects duplicates.
- Out of scope: LA-003 harness failure; `categoryRows` direction.

## Codex findings (review of 8166957, addressed 2026-10-08)
| Comment | Sev | Path:line | Finding | Status |
|---|---|---|---|---|
| 4219761466 | P2 | Sources/LedgerStore/LedgerApplication.swift:167 | Duplicate purchase IDs hidden by unreadable split groups | **fixed in 3544a7e**. createSplit now rejects a draft ID that is claimed by a `split.purchaseID` literal or by an unreadable group's parent ID. A regression test in `splitPurchasesSkippingInvalidKeepsValidGroupsVisible` retries with new line IDs and expects `invalidCommand` with an unchanged ledger. Without the fix the test fails because a second group is inserted. |
| 4219761477 | P2 | Sources/LedgerStore/LedgerApplication.swift:590 | Signed net exported as "Total" next to magnitude rows | **needs-decision**. The finding is real and matches review N4. Relabelling the accessible/PDF "Total" line, or switching to signed rows, is user-facing wording, so it stays an owner decision. The fix would be one line, `LedgerProducts.swift:394`, and no tests parse "Total:". |

Replies posted in both threads (4220067937, 4220068303) and read back on PR #67. Then posted `@codex review`. Pushed 8166957..3544a7e (no force). No merge, auto-merge still off.

Checks at 3544a7e. Logs are `codexfix-ledger-atlas-*.log`.
- ruff check, ruff format --check, pytest (11), check-sync-gstack-skills: pass.
- swift build: pass. mmctl: `schema=11 importer=11`.
- swift test: 492 passing, rc=1. Two failures:
  - LA-003 LossReportTests:34 `.io`, a known failure that was already there on base.
  - `blockedLifecycleKeepsTheMainActorResponsive…` at LedgerLifecycleFlowTests.swift:430. This test is timing-sensitive. The machine load average was about 150 during the runs. It fails the same way at 8166957 without this change (codexfix-ledger-atlas-swifttest-base8166957.log) and passes when run alone. It comes from the environment, not from this change.
- npm ci, lint, typecheck, test (15): pass.
- xcodebuild LedgerAtlas (CODE_SIGNING_ALLOWED=NO): BUILD SUCCEEDED. The only warning is the existing one in RedactedWidgetProjection.swift:99.
