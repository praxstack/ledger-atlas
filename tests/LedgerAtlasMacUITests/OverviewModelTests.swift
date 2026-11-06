import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

private let origin = try! LedgerOrigin(id: String(repeating: "7", count: 64), label: "tests")

private func key(_ seed: String) -> String { String(repeating: seed, count: 64 / seed.count) }

private func entry(
  _ seed: String, _ account: LedgerAccount, _ direction: LedgerEffectDirection, _ literal: String,
  kind: LedgerTransactionKind, category: LedgerCategory? = nil, month: Int, day: Int, note: String? = nil
) throws -> LedgerTransactionSnapshot {
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: month, day: day)),
    in: SourceTimeZone(fixedOffsetSeconds: 19_800), precision: .minute)
  let draft = try LedgerTransactionDraft(
    effects: [
      try LedgerTransactionEffect(
        accountID: account.id, direction: direction,
        amount: try CurrencyAmount(unitCode: "INR", amount: ExactDecimal(literal)))
    ], categoryID: category?.id, kind: kind, occurredAt: when, note: note, origin: origin)
  let id = try StableLedgerID.transaction(origin: origin, localKey: key(seed))
  let revision = try LedgerTransactionRevision(
    id: try StableLedgerID.revision(transactionID: id, revision: 1), transactionID: id, revision: 1,
    predecessorID: nil, draft: draft, createdAt: UTCInstant(epochMilliseconds: 0))
  return try LedgerTransactionSnapshot(id: id, currentRevision: revision)
}

@Test func overviewReconcilesNetWorthSpendingAndRecentEntries() throws {
  let bank = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: key("a")), name: "Everyday Bank",
    currencyUnit: "INR", origin: origin)
  let food = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: key("f")), name: "Food", kind: .expense,
    origin: origin)
  let rent = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: key("e")), name: "Rent", kind: .expense,
    origin: origin)
  let transactions = [
    try entry("1", bank, .increase, "100000", kind: .income, month: 10, day: 1, note: "Salary"),
    try entry("2", bank, .decrease, "30000", kind: .expense, category: rent, month: 11, day: 2),
    try entry("3", bank, .decrease, "10000", kind: .expense, category: food, month: 11, day: 5),
    try entry("4", bank, .increase, "100000", kind: .income, month: 11, day: 1, note: "Salary"),
  ]
  let snapshot = LedgerStore.LedgerReadSnapshot(
    accounts: [bank], transactions: transactions,
    revisionHistory: transactions.map(\.currentRevision), undisplayedImportedEventCount: 0,
    categories: [food, rent])
  let model = try OverviewModel(
    snapshot: snapshot, today: SourceLocalDate(year: 2026, month: 11, day: 20),
    rule: LedgerPeriodRule())

  #expect(model.unitCode == "INR")
  #expect(model.netWorth.amount == (try ExactDecimal("160000")))
  #expect(model.monthChange?.amount == (try ExactDecimal("60000")))
  #expect(model.history.count == 12)
  #expect(model.history.last?.value == model.netWorth.amount)
  #expect(model.history.dropLast().last?.value == (try ExactDecimal("100000")))
  #expect(model.spending.map(\.name) == ["Rent", "Food"])
  #expect(abs((model.spending.first?.share ?? 0) - 0.75) < 0.0001)
  #expect(model.recent.first?.title == "Food")
  #expect(model.recent.first?.sign == .always)
  #expect(model.recent.first?.amount.amount.isNegative == true)
  #expect(model.recent.contains { $0.title == "Salary" && $0.isIncome })
  #expect(!model.includesLaterEntries)

  // An entry dated next month counts in the headline (as on Accounts) and is called out.
  let later = transactions + [
    try entry("5", bank, .decrease, "5000", kind: .expense, category: food, month: 12, day: 3)
  ]
  let ahead = try OverviewModel(
    snapshot: LedgerStore.LedgerReadSnapshot(
      accounts: [bank], transactions: later, revisionHistory: later.map(\.currentRevision),
      undisplayedImportedEventCount: 0, categories: [food, rent]),
    today: SourceLocalDate(year: 2026, month: 11, day: 20), rule: LedgerPeriodRule())
  #expect(ahead.includesLaterEntries)
  #expect(ahead.netWorth.amount == (try ExactDecimal("155000")))
  #expect(ahead.history.last?.value == (try ExactDecimal("160000")))
}

@Test func overviewKeepsTheLatestEntriesNewestFirst() throws {
  let bank = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: key("a")), name: "Bank",
    currencyUnit: "INR", origin: origin)
  let days = [14, 3, 27, 9, 21, 1, 18, 30, 6, 12, 25]
  let transactions = try days.enumerated().map { index, day in
    try entry(String(index, radix: 16), bank, .decrease, "1", kind: .expense, month: 11, day: day)
  }
  let latest = OverviewModel.latest(4, of: transactions)
  #expect(latest.map { $0.currentRevision.draft.occurredAt.localDateTime.date.day } == [30, 27, 25, 21])
  #expect(OverviewModel.latest(20, of: transactions).count == days.count)
}
