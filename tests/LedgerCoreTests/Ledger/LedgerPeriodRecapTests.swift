import LedgerCore
import Testing

// #239 Month in Review and Year in Review. Synthetic data only.

@Suite("Month and Year in Review")
struct LedgerPeriodRecapTests {
  let origin: LedgerOrigin

  init() throws {
    origin = try LedgerOrigin(id: String(repeating: "3", count: 64), label: "local")
  }

  private func account(_ key: Character, unit: String = "INR") throws -> LedgerAccount {
    try LedgerAccount(
      id: try StableLedgerID.account(origin: origin, localKey: String(repeating: key, count: 64)),
      name: "Account \(key)", currencyUnit: unit, origin: origin)
  }

  private func category(_ key: Character, _ name: String, kind: LedgerCategoryKind = .expense)
    throws -> LedgerCategory
  {
    try LedgerCategory(
      id: try StableLedgerID.category(origin: origin, localKey: String(repeating: key, count: 64)),
      name: name, kind: kind, origin: origin)
  }

  private var serial = Counter()
  final class Counter: @unchecked Sendable { var value = 0 }

  private func entry(
    _ kind: LedgerTransactionKind, _ amount: String, on account: LedgerAccount,
    to other: LedgerAccount? = nil, category: LedgerCategory? = nil, year: Int = 2026,
    month: Int = 10, day: Int = 5, note: String? = nil,
    lifecycle: LedgerLifecycleState = .active
  ) throws -> LedgerTransactionSnapshot {
    serial.value += 1
    let money = try CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal(amount))
    var effects = [
      try LedgerTransactionEffect(
        accountID: account.id, direction: kind == .income ? .increase : .decrease, amount: money)
    ]
    if let other {
      effects.append(try LedgerTransactionEffect(accountID: other.id, direction: .increase, amount: money))
    }
    let when = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: year, month: month, day: day)),
      in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .minute)
    let draft = try LedgerTransactionDraft(
      effects: effects, categoryID: category?.id, kind: kind, occurredAt: when, note: note,
      origin: origin)
    let id = try StableLedgerID.transaction(
      origin: origin, localKey: String(format: "%064x", serial.value))
    let revision = try LedgerTransactionRevision(
      id: try StableLedgerID.revision(transactionID: id, revision: 1), transactionID: id,
      revision: 1, predecessorID: nil, draft: draft, lifecycle: lifecycle,
      createdAt: UTCInstant(epochMilliseconds: 0))
    return try LedgerTransactionSnapshot(id: id, currentRevision: revision)
  }

  @Test("a month's figures are compared with the month before")
  func monthAgainstTheMonthBefore() throws {
    let cash = try account("a")
    let bank = try account("b")
    let food = try category("f", "Food")
    let salary = try category("c", "Salary", kind: .income)
    let transactions = [
      try entry(.income, "50000", on: bank, category: salary, month: 9, day: 1),
      try entry(.expense, "1000", on: cash, category: food, month: 9, day: 3),
      try entry(.income, "52000", on: bank, category: salary, month: 10, day: 1),
      try entry(.expense, "1500", on: cash, category: food, month: 10, day: 3),
      // A transfer is neither in nor out, and a closed entry doesn't count at all.
      try entry(.transfer, "9999", on: bank, to: cash, month: 10, day: 4),
      try entry(.expense, "777", on: cash, category: food, month: 10, day: 4, lifecycle: .tombstoned),
    ]
    let recap = try LedgerPeriodRecap(
      period: .month(2026, 10), accounts: [cash, bank], categories: [food, salary],
      transactions: transactions)
    let inr = try #require(recap.currencies.first)
    #expect(recap.currencies.map(\.unitCode) == ["INR"])
    #expect(inr.income.description == "52000")
    #expect(inr.expense.description == "1500")
    #expect(inr.net.description == "50500")
    #expect(inr.previousIncome.description == "50000")
    #expect(inr.previousExpense.description == "1000")
    #expect(inr.previousNet.description == "49000")
    #expect(inr.topCategories.map(\.name) == ["Food"])
    #expect(inr.topCategories.first?.percent == 100)
    #expect(inr.topCategories.first?.previousAmount?.description == "1000")
    // Three active entries (income, expense, transfer) on three days; October has 31.
    #expect(recap.entryCount == 3)
    #expect(recap.daysWithoutEntries == 28)
    #expect(inr.months.isEmpty)
  }

  @Test("the top five categories are listed, then the rest as Other")
  func topFiveThenOther() throws {
    let cash = try account("a")
    let names = ["Rent", "Food", "Travel", "Fuel", "Phone", "Gifts", "Books"]
    let amounts = ["9000", "3000", "2000", "1000", "500", "300", "200"]
    let categories = try zip(["1", "2", "3", "4", "5", "6", "7"], names).map {
      try category(Character($0.0), $0.1)
    }
    var transactions = try zip(categories, amounts).map {
      try entry(.expense, $0.1, on: cash, category: $0.0)
    }
    transactions.append(try entry(.expense, "1000", on: cash, category: categories[6], month: 9))
    let recap = try LedgerPeriodRecap(
      period: .month(2026, 10), accounts: [cash], categories: categories,
      transactions: transactions)
    let top = try #require(recap.currencies.first).topCategories
    #expect(top.map(\.name) == ["Rent", "Food", "Travel", "Fuel", "Phone", "Other"])
    #expect(top.last?.id == LedgerPeriodRecap.otherCategoryID)
    #expect(top.last?.amount.description == "500")
    #expect(top.last?.previousAmount == nil)
    // 9000 of 16000 is 56.25%, shown as 56.
    #expect(top.first?.percent == 56)
    #expect(top.first?.previousAmount?.description == "0")
  }

  @Test("the biggest expenses come largest first, earliest first on a tie")
  func biggestExpenses() throws {
    let cash = try account("a")
    let transactions = [
      try entry(.expense, "100", on: cash, day: 9, note: "small"),
      try entry(.expense, "800", on: cash, day: 7, note: "tied later"),
      try entry(.expense, "800", on: cash, day: 2, note: "tied earlier"),
      try entry(.expense, "950", on: cash, day: 20, note: "largest"),
      try entry(.income, "5000", on: cash, day: 1),
    ]
    let recap = try LedgerPeriodRecap(
      period: .month(2026, 10), accounts: [cash], categories: [], transactions: transactions)
    let biggest = try #require(recap.currencies.first).biggestExpenses
    #expect(biggest.map(\.note) == ["largest", "tied earlier", "tied later"])
  }

  @Test("each currency has its own figures and nothing is converted")
  func twoCurrencies() throws {
    let cash = try account("a")
    let euros = try account("e", unit: "EUR")
    let transactions = [
      try entry(.expense, "200", on: cash),
      try entry(.expense, "15.50", on: euros),
      try entry(.income, "40", on: euros, day: 6),
    ]
    let recap = try LedgerPeriodRecap(
      period: .month(2026, 10), accounts: [cash, euros], categories: [],
      transactions: transactions)
    #expect(recap.currencies.map(\.unitCode) == ["EUR", "INR"])
    #expect(recap.currencies[0].expense.description == "15.5")
    #expect(recap.currencies[0].net.description == "24.5")
    #expect(recap.currencies[1].expense.description == "200")
    #expect(recap.currencies[1].topCategories.map(\.id) == [LedgerPeriodStatistics.uncategorizedID])
  }

  @Test("a period with no entries is empty but still compares with the one before")
  func emptyPeriod() throws {
    let cash = try account("a")
    let transactions = [try entry(.expense, "300", on: cash, month: 9)]
    let recap = try LedgerPeriodRecap(
      period: .month(2026, 10), accounts: [cash], categories: [], transactions: transactions)
    #expect(recap.isEmpty)
    #expect(recap.busiestDay == nil)
    #expect(recap.daysWithoutEntries == 31)
    let inr = try #require(recap.currencies.first)
    #expect(inr.expense.description == "0")
    #expect(inr.previousExpense.description == "300")
    #expect(inr.topCategories.isEmpty)
    #expect(inr.biggestExpenses.isEmpty)
  }

  @Test("the busiest day is the one with most entries, the earliest on a tie")
  func busiestDay() throws {
    let cash = try account("a")
    let transactions = [
      try entry(.expense, "1", on: cash, day: 12),
      try entry(.expense, "1", on: cash, day: 12),
      try entry(.expense, "1", on: cash, day: 4),
      try entry(.expense, "1", on: cash, day: 4),
      try entry(.expense, "1", on: cash, day: 20),
    ]
    let recap = try LedgerPeriodRecap(
      period: .month(2026, 10), accounts: [cash], categories: [], transactions: transactions)
    #expect(recap.busiestDay == (try SourceLocalDate(year: 2026, month: 10, day: 4)))
    #expect(recap.busiestDayCount == 2)
    #expect(recap.entryCount == 5)
    #expect(recap.daysWithoutEntries == 28)
  }

  @Test("a year has twelve months and its best and worst month by net")
  func yearInReview() throws {
    let cash = try account("a")
    let transactions = [
      try entry(.income, "1000", on: cash, year: 2025, month: 2),
      try entry(.expense, "100", on: cash, year: 2025, month: 2),
      try entry(.expense, "700", on: cash, year: 2025, month: 7),
      try entry(.income, "300", on: cash, year: 2025, month: 11),
      try entry(.expense, "50", on: cash, year: 2024, month: 5),
    ]
    let recap = try LedgerPeriodRecap(
      period: .year(2025), accounts: [cash], categories: [], transactions: transactions)
    let inr = try #require(recap.currencies.first)
    #expect(inr.months.map(\.month) == Array(1...12))
    #expect(inr.months[6].expense.description == "700")
    #expect(inr.bestMonth?.month == 2)
    #expect(inr.worstMonth?.month == 7)
    #expect(inr.previousExpense.description == "50")
    #expect(recap.daysWithoutEntries == 365 - 3)
  }

  @Test("budgets are judged on the period's last day")
  func budgetsKeptAndOverspent() throws {
    let cash = try account("a")
    let food = try category("f", "Food")
    let fuel = try category("d", "Fuel")
    func budget(_ key: Character, _ category: LedgerCategory, _ limit: String) throws
      -> LedgerBudget
    {
      try LedgerBudget(
        id: String(repeating: key, count: 64), origin: origin, name: category.name,
        categoryID: category.id,
        amount: CurrencyAmount(unitCode: "INR", amount: ExactDecimal(limit)), period: .monthly,
        rollover: false, start: SourceLocalDate(year: 2026, month: 1, day: 1))
    }
    let transactions = [
      try entry(.expense, "900", on: cash, category: food),
      try entry(.expense, "100", on: cash, category: fuel),
    ]
    let recap = try LedgerPeriodRecap(
      period: .month(2026, 10), accounts: [cash], categories: [food, fuel],
      transactions: transactions,
      budgets: [try budget("1", food, "500"), try budget("2", fuel, "500")])
    #expect(recap.budgetsKept == 1)
    #expect(recap.budgetsOverspent == 1)
  }

  @Test("only finished months and years with entries are offered, newest first")
  func finishedPeriods() throws {
    let cash = try account("a")
    let transactions = [
      try entry(.expense, "1", on: cash, year: 2025, month: 12),
      try entry(.expense, "1", on: cash, year: 2026, month: 9),
      try entry(.expense, "1", on: cash, year: 2026, month: 11),
    ]
    let periods = LedgerRecapPeriod.finished(
      in: transactions, today: try SourceLocalDate(year: 2026, month: 11, day: 8))
    #expect(periods.map(\.id) == ["2026-09", "2025", "2025-12"])
    #expect(LedgerRecapPeriod.month(2026, 1).previous == .month(2025, 12))
    #expect(LedgerRecapPeriod.year(2026).previous == .year(2025))
  }
}
