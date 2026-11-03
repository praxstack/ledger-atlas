import LedgerCore
import Testing

@Suite("Period statistics roll up categories and reconcile to one snapshot")
struct LedgerStatisticsTests {
  let origin: LedgerOrigin

  init() throws {
    origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  }

  private func account(
    _ key: Character, unit: String = "INR", includeInTotals: Bool = true
  ) throws -> LedgerAccount {
    try LedgerAccount(
      id: try StableLedgerID.account(origin: origin, localKey: String(repeating: key, count: 64)),
      name: "Account \(key)", currencyUnit: unit, origin: origin, lifecycle: .active,
      groupID: nil, hidden: false, includeInTotals: includeInTotals, variant: .standard)
  }

  private func category(
    _ key: Character, _ name: String, kind: LedgerCategoryKind = .expense,
    parent: LedgerCategory? = nil, order: Int = 0
  ) throws -> LedgerCategory {
    try LedgerCategory(
      id: try StableLedgerID.category(origin: origin, localKey: String(repeating: key, count: 64)),
      name: name, kind: kind, origin: origin, parentID: parent?.id, displayOrder: order)
  }

  private func transaction(
    _ key: String, kind: LedgerTransactionKind,
    _ effects: [(LedgerAccount, LedgerEffectDirection, String)],
    category: LedgerCategory? = nil, day: Int = 2, month: Int = 11,
    lifecycle: LedgerLifecycleState = .active
  ) throws -> LedgerTransactionSnapshot {
    let when = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: month, day: day)),
      in: SourceTimeZone(fixedOffsetSeconds: 19_800), precision: .minute)
    let draft = try LedgerTransactionDraft(
      effects: try effects.map {
        try LedgerTransactionEffect(
          accountID: $0.0.id, direction: $0.1,
          amount: try CurrencyAmount(unitCode: $0.0.currencyUnit, amount: ExactDecimal($0.2)))
      },
      categoryID: category?.id, kind: kind, occurredAt: when, origin: origin)
    let localKey = String(repeating: key, count: 64 / key.count)
    let transactionID = try StableLedgerID.transaction(origin: origin, localKey: localKey)
    let revision = try LedgerTransactionRevision(
      id: try StableLedgerID.revision(transactionID: transactionID, revision: 1),
      transactionID: transactionID, revision: 1, predecessorID: nil, draft: draft,
      lifecycle: lifecycle, createdAt: UTCInstant(epochMilliseconds: 0))
    return try LedgerTransactionSnapshot(id: transactionID, currentRevision: revision)
  }

  private func november() throws -> LedgerStatisticsPeriod {
    try LedgerStatisticsPeriod(
      start: SourceLocalDate(year: 2026, month: 11, day: 1),
      end: SourceLocalDate(year: 2026, month: 12, day: 1))
  }

  private func decimal(_ literal: String) throws -> ExactDecimal { try ExactDecimal(literal) }

  @Test("a category's total includes its subcategories and top-level lines add up")
  func rollUpReconciles() throws {
    let cash = try account("a")
    let food = try category("f", "Food")
    let groceries = try category("e", "Groceries", parent: food)
    let dining = try category("d", "Dining", parent: food, order: 1)
    let rent = try category("c", "Rent", order: 1)
    let salary = try category("b", "Salary", kind: .income)
    let transactions = [
      try transaction("1", kind: .expense, [(cash, .decrease, "100")], category: groceries),
      try transaction("2", kind: .expense, [(cash, .decrease, "40.50")], category: dining),
      try transaction("3", kind: .expense, [(cash, .decrease, "10")], category: food),
      try transaction("4", kind: .expense, [(cash, .decrease, "900")], category: rent),
      try transaction("5", kind: .expense, [(cash, .decrease, "5")]),
      try transaction("6", kind: .income, [(cash, .increase, "2000")], category: salary),
    ]
    let statistics = try LedgerPeriodStatistics(
      accounts: [cash], categories: [food, groceries, dining, rent, salary],
      transactions: transactions, unitCode: "INR", period: november())

    #expect(statistics.expense == (try decimal("1055.50")))
    #expect(statistics.income == (try decimal("2000")))
    #expect(statistics.net == (try decimal("944.50")))
    #expect(statistics.expenseCategories.map(\.name) == [
      "Food", "Groceries", "Dining", "Rent", "Uncategorized",
    ])
    #expect(statistics.expenseCategories.map(\.depth) == [0, 1, 1, 0, 0])
    let foodRow = try #require(statistics.expenseCategories.first)
    #expect(foodRow.totalAmount == (try decimal("150.50")))
    #expect(foodRow.ownAmount == (try decimal("10")))
    #expect(foodRow.totalCount == 3)
    #expect(foodRow.ownCount == 1)

    // Top-level lines (depth 0, including Uncategorized) add up to the expense exactly.
    var sum = try decimal("0")
    for row in statistics.expenseCategories where row.depth == 0 {
      sum = try sum.adding(row.totalAmount)
    }
    #expect(sum == statistics.expense)
    #expect(statistics.incomeCategories.map(\.name) == ["Salary"])

    // Drill-down returns exactly the transactions behind each figure.
    #expect(
      statistics.transactionIDs(inCategory: food.id, includingSubcategories: true).sorted()
        == [transactions[0].id, transactions[1].id, transactions[2].id].sorted())
    #expect(
      statistics.transactionIDs(inCategory: food.id, includingSubcategories: false)
        == [transactions[2].id])
    #expect(
      statistics.transactionIDs(
        inCategory: LedgerPeriodStatistics.uncategorizedID, includingSubcategories: true)
        == [transactions[4].id])
  }

  @Test("split lines count once each, in their own categories")
  func splitLinesCountOnce() throws {
    let cash = try account("a")
    let food = try category("f", "Food")
    let home = try category("a", "Home", order: 1)
    // A split purchase is stored as one expense transaction per line.
    let lines = [
      try transaction("1", kind: .expense, [(cash, .decrease, "300")], category: food),
      try transaction("2", kind: .expense, [(cash, .decrease, "200")], category: home),
    ]
    let statistics = try LedgerPeriodStatistics(
      accounts: [cash], categories: [food, home], transactions: lines, unitCode: "INR",
      period: november())
    #expect(statistics.expense == (try decimal("500")))
    #expect(statistics.expenseCount == 2)
    #expect(statistics.expenseCategories.map(\.totalAmount) == [
      try decimal("300"), try decimal("200"),
    ])
  }

  @Test("transfers, adjustments, other periods, other currencies and deleted entries stay out")
  func onlyCountedActivity() throws {
    let cash = try account("a")
    let bank = try account("b")
    let dollars = try account("c", unit: "USD")
    let excluded = try account("e", includeInTotals: false)
    let transactions = [
      try transaction("1", kind: .expense, [(cash, .decrease, "100")]),
      try transaction("2", kind: .transfer, [(bank, .decrease, "500"), (cash, .increase, "500")]),
      try transaction("3", kind: .adjustment, [(bank, .increase, "7")]),
      try transaction("4", kind: .expense, [(cash, .decrease, "60")], month: 10),
      try transaction("5", kind: .expense, [(dollars, .decrease, "9")]),
      try transaction("6", kind: .expense, [(excluded, .decrease, "11")]),
      try transaction("7", kind: .expense, [(cash, .decrease, "13")], lifecycle: .tombstoned),
      try transaction("8", kind: .income, [(bank, .increase, "1000")], month: 12),
    ]
    let statistics = try LedgerPeriodStatistics(
      accounts: [cash, bank, dollars, excluded], categories: [], transactions: transactions,
      unitCode: "INR", period: november())
    #expect(statistics.expense == (try decimal("100")))
    #expect(statistics.income == (try decimal("0")))
    #expect(statistics.transferCount == 1)
    #expect(statistics.adjustmentCount == 1)
    // Balance at the end of November: October and November entries, not December's.
    // cash: -60 -100 +500 = 340; bank: -500 +7 = -493; together -153.
    #expect(statistics.closingBalance?.net == (try decimal("-153")))
    #expect(statistics.closingBalance?.accountCount == 2)
  }

  @Test("the snapshot digest changes with the data it read, and only with that")
  func digestTracksInputs() throws {
    let cash = try account("a")
    let base = [try transaction("1", kind: .expense, [(cash, .decrease, "100")])]
    let first = try LedgerPeriodStatistics(
      accounts: [cash], categories: [], transactions: base, unitCode: "INR", period: november())
    let again = try LedgerPeriodStatistics(
      accounts: [cash], categories: [], transactions: base, unitCode: "INR", period: november())
    #expect(first.snapshotDigest == again.snapshotDigest)
    #expect(first.snapshotDigest.count == 64)

    let later = try LedgerPeriodStatistics(
      accounts: [cash], categories: [],
      transactions: base + [try transaction("2", kind: .expense, [(cash, .decrease, "1")], month: 12)],
      unitCode: "INR", period: november())
    #expect(later.snapshotDigest == first.snapshotDigest)

    let changed = try LedgerPeriodStatistics(
      accounts: [cash], categories: [],
      transactions: base + [try transaction("3", kind: .expense, [(cash, .decrease, "1")])],
      unitCode: "INR", period: november())
    #expect(changed.snapshotDigest != first.snapshotDigest)
  }

  @Test("a trend applies the same rules to each period")
  func trendPerPeriod() throws {
    let cash = try account("a")
    let transactions = [
      try transaction("1", kind: .expense, [(cash, .decrease, "60")], month: 10),
      try transaction("2", kind: .income, [(cash, .increase, "500")], month: 10),
      try transaction("3", kind: .expense, [(cash, .decrease, "100")]),
    ]
    let october = try LedgerStatisticsPeriod(
      start: SourceLocalDate(year: 2026, month: 10, day: 1),
      end: SourceLocalDate(year: 2026, month: 11, day: 1))
    let points = try LedgerPeriodStatistics.trend(
      accounts: [cash], categories: [], transactions: transactions, unitCode: "INR",
      periods: [october, november()])
    #expect(points.map(\.expense) == [try decimal("60"), try decimal("100")])
    #expect(points.map(\.income) == [try decimal("500"), try decimal("0")])
    #expect(points.map(\.net) == [try decimal("440"), try decimal("-100")])
  }

  @Test("the accessible table lists every figure the screen shows")
  func accessibleTable() throws {
    let cash = try account("a")
    let food = try category("f", "Food")
    let statistics = try LedgerPeriodStatistics(
      accounts: [cash], categories: [food],
      transactions: [try transaction("1", kind: .expense, [(cash, .decrease, "100")], category: food)],
      unitCode: "INR", period: november())
    let lines = statistics.accessibleLines
    #expect(lines.contains("Expense: 100 INR (1)"))
    #expect(lines.contains("  Food: 100 INR (1)"))
    #expect(lines.contains("Period: 2026-11-01 to 2026-12-01 (end not included)"))
    #expect(lines.last == "Snapshot: \(statistics.snapshotDigest.prefix(16))")
  }

  @Test("an empty or reversed period is refused")
  func invalidPeriod() throws {
    let day = try SourceLocalDate(year: 2026, month: 11, day: 1)
    #expect(throws: LedgerStatisticsError.invalidPeriod) {
      try LedgerStatisticsPeriod(start: day, end: day)
    }
  }
}
