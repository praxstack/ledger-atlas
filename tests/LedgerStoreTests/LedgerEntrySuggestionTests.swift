import Foundation
import LedgerCore
import Testing

@testable import LedgerStore

/// #169: the income and expense form pre-fills account and category from the most recent
/// entry with the same memo. Synthetic data only.
@Suite("Entry suggestion from a memo")
struct LedgerEntrySuggestionTests {
  private let fixture = try! SuggestionFixture()

  @Test("an exact memo suggests that entry's account and category, and says the day")
  func exactMatch() throws {
    let entries = [try fixture.entry("a", note: "Chai at office", account: fixture.cash, category: fixture.food, day: 3)]
    let suggestion = try #require(fixture.suggest("Chai at office", in: entries))
    #expect(suggestion.accountID == fixture.cash.id)
    #expect(suggestion.categoryID == fixture.food.id)
    #expect(suggestion.fromDay == (try SourceLocalDate(year: 2026, month: 10, day: 3)))
    #expect(suggestion.sourceTransactionID == entries[0].id)
  }

  @Test("case and spacing do not matter; a part of a memo is not a match")
  func trimmedAndCaseInsensitive() throws {
    let entries = [try fixture.entry("a", note: "Chai  at Office", account: fixture.cash, category: fixture.food, day: 3)]
    #expect(fixture.suggest("  chai at office ", in: entries) != nil)
    #expect(fixture.suggest("CHAI\tAT\nOFFICE", in: entries) != nil)
    #expect(fixture.suggest("chai", in: entries) == nil)
    #expect(fixture.suggest("chai at office today", in: entries) == nil)
  }

  @Test("the most recent matching entry wins")
  func mostRecentWins() throws {
    let entries = [
      try fixture.entry("old", note: "Groceries", account: fixture.cash, category: fixture.food, day: 1),
      try fixture.entry("new", note: "groceries", account: fixture.bank, category: fixture.home, day: 20),
      try fixture.entry("mid", note: "GROCERIES", account: fixture.cash, category: fixture.food, day: 10),
    ]
    let suggestion = try #require(fixture.suggest("Groceries", in: entries))
    #expect(suggestion.accountID == fixture.bank.id)
    #expect(suggestion.categoryID == fixture.home.id)
    #expect(suggestion.fromDay.day == 20)
  }

  @Test("the entry that happened last wins, even if an older one was entered later")
  func occurrenceBeatsEntryTime() throws {
    let entries = [
      try fixture.entry(
        "late-typed", note: "Rent", account: fixture.cash, category: fixture.food, day: 2,
        createdAt: 99),
      try fixture.entry(
        "happened-last", note: "Rent", account: fixture.bank, category: fixture.home, day: 25,
        createdAt: 1),
    ]
    let suggestion = try #require(fixture.suggest("Rent", in: entries))
    #expect(suggestion.accountID == fixture.bank.id)
    #expect(suggestion.categoryID == fixture.home.id)
  }

  @Test("an income memo suggests from income entries only")
  func incomeMatch() throws {
    let entries = [
      try fixture.entry("pay", note: "Salary", account: fixture.bank, category: fixture.salary, day: 1, kind: .income),
      try fixture.entry("spend", note: "Salary", account: fixture.cash, category: fixture.food, day: 9),
    ]
    let suggestion = try #require(fixture.suggest("salary", kind: .income, in: entries))
    #expect(suggestion.accountID == fixture.bank.id)
    #expect(suggestion.categoryID == fixture.salary.id)
    #expect(suggestion.sourceTransactionID == entries[0].id)
  }

  @Test("no match: blank memo, other memo, other kind, or only a closed entry")
  func noMatch() throws {
    let live = try fixture.entry("a", note: "Rent", account: fixture.bank, category: fixture.home, day: 3)
    #expect(fixture.suggest("", in: [live]) == nil)
    #expect(fixture.suggest("   ", in: [live]) == nil)
    #expect(fixture.suggest("Salary", in: [live]) == nil)
    #expect(fixture.suggest("Rent", kind: .income, in: [live]) == nil)
    let closed = try fixture.entry(
      "b", note: "Rent", account: fixture.bank, category: fixture.home, day: 4, lifecycle: .tombstoned)
    #expect(fixture.suggest("Rent", in: [closed]) == nil)
    #expect(fixture.suggest("Rent", in: []) == nil)
  }

  @Test("a closed account or hidden category is left out of the suggestion")
  func onlyChoosableValues() throws {
    let entries = [try fixture.entry("a", note: "Old card", account: fixture.closed, category: fixture.hidden, day: 3)]
    #expect(fixture.suggest("Old card", in: entries) == nil)
    let half = [try fixture.entry("b", note: "Old card", account: fixture.closed, category: fixture.food, day: 3)]
    let suggestion = try #require(fixture.suggest("Old card", in: half))
    #expect(suggestion.accountID == nil)
    #expect(suggestion.categoryID == fixture.food.id)
  }
}

/// A 64-character lowercase hex key made from a short name, as stable ids need.
private func hexKey(_ name: String) -> String {
  let hex = name.utf8.map { String($0, radix: 16) }.joined()
  return String((hex + String(repeating: "0", count: 64)).prefix(64))
}

private struct SuggestionFixture {
  let origin: LedgerOrigin
  let cash, bank, closed: LedgerAccount
  let food, home, hidden, salary: LedgerCategory

  init() throws {
    let origin = try LedgerOrigin(id: String(repeating: "5", count: 64), label: "synthetic")
    func account(_ key: String, lifecycle: LedgerLifecycleState = .active) throws -> LedgerAccount {
      try LedgerAccount(
        id: StableLedgerID.account(origin: origin, localKey: hexKey(key)), name: key,
        currencyUnit: "USD", origin: origin, lifecycle: lifecycle)
    }
    func category(
      _ key: String, kind: LedgerCategoryKind = .expense, hidden: Bool = false
    ) throws -> LedgerCategory {
      try LedgerCategory(
        id: StableLedgerID.category(origin: origin, localKey: hexKey(key)), name: key,
        kind: kind, origin: origin, hidden: hidden)
    }
    self.origin = origin
    cash = try account("cash")
    bank = try account("bank")
    closed = try account("closed", lifecycle: .tombstoned)
    food = try category("food")
    home = try category("home")
    hidden = try category("hidden", hidden: true)
    salary = try category("salary", kind: .income)
  }

  func entry(
    _ key: String, note: String, account: LedgerAccount, category: LedgerCategory, day: Int,
    lifecycle: LedgerLifecycleState = .active, kind: LedgerTransactionKind = .expense,
    createdAt: Int64? = nil
  ) throws -> LedgerTransactionSnapshot {
    let when = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 10, day: day)),
      in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
    let draft = try LedgerTransactionDraft(
      effects: [
        try LedgerTransactionEffect(
          accountID: account.id, direction: kind == .income ? .increase : .decrease,
          amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("4.00")))
      ], categoryID: category.id, kind: kind, occurredAt: when, note: note, origin: origin)
    let id = try StableLedgerID.transaction(origin: origin, localKey: hexKey(key))
    let revision = try LedgerTransactionRevision(
      id: StableLedgerID.revision(transactionID: id, revision: 1), transactionID: id, revision: 1,
      predecessorID: nil, draft: draft, lifecycle: lifecycle,
      createdAt: UTCInstant(epochMilliseconds: createdAt ?? Int64(day)))
    return try LedgerTransactionSnapshot(id: id, currentRevision: revision)
  }

  func suggest(
    _ memo: String, kind: LedgerTransactionKind = .expense, in entries: [LedgerTransactionSnapshot]
  ) -> LedgerEntrySuggestion? {
    LedgerEntrySuggestion.suggestion(
      forMemo: memo, kind: kind, accounts: [cash, bank, closed],
      categories: [food, home, hidden, salary],
      transactions: entries)
  }
}
