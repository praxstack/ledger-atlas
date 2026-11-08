import Foundation

/// A finished calendar month or year that a recap (#239) covers.
public struct LedgerRecapPeriod: Hashable, Comparable, Sendable, Identifiable {
  public enum Kind: String, Sendable { case month, year }

  public let kind: Kind
  public let year: Int
  /// 1...12 for a month; nil for a year.
  public let month: Int?

  public static func month(_ year: Int, _ month: Int) -> LedgerRecapPeriod {
    LedgerRecapPeriod(kind: .month, year: year, month: month)
  }

  public static func year(_ year: Int) -> LedgerRecapPeriod {
    LedgerRecapPeriod(kind: .year, year: year, month: nil)
  }

  /// "2026-10" or "2026".
  public var id: String {
    month.map { String(format: "%04d-%02d", year, $0) } ?? String(format: "%04d", year)
  }

  public var first: SourceLocalDate {
    get throws { try SourceLocalDate(year: year, month: month ?? 1, day: 1) }
  }

  /// The first day after the period.
  public var end: SourceLocalDate {
    get throws {
      switch kind {
      case .year: return try SourceLocalDate(year: year + 1, month: 1, day: 1)
      case .month:
        let month = self.month ?? 12
        return month == 12
          ? try SourceLocalDate(year: year + 1, month: 1, day: 1)
          : try SourceLocalDate(year: year, month: month + 1, day: 1)
      }
    }
  }

  public var statisticsPeriod: LedgerStatisticsPeriod {
    get throws { try LedgerStatisticsPeriod(start: first, end: end) }
  }

  /// The month or year before.
  public var previous: LedgerRecapPeriod {
    switch kind {
    case .year: return .year(year - 1)
    case .month:
      let month = self.month ?? 1
      return month == 1 ? .month(year - 1, 12) : .month(year, month - 1)
    }
  }

  /// Years sort before their months; otherwise by date.
  public static func < (lhs: LedgerRecapPeriod, rhs: LedgerRecapPeriod) -> Bool {
    if lhs.year != rhs.year { return lhs.year < rhs.year }
    return (lhs.month ?? 0) < (rhs.month ?? 0)
  }

  /// Every finished month and year that has entries, newest first, years before their
  /// months. The period holding `today` is not finished, so it is not offered.
  public static func finished(
    in transactions: [LedgerTransactionSnapshot], today: SourceLocalDate
  ) -> [LedgerRecapPeriod] {
    var periods = Set<LedgerRecapPeriod>()
    for transaction in transactions where transaction.currentRevision.lifecycle == .active {
      let date = transaction.currentRevision.draft.occurredAt.localDay
      if date.year < today.year || (date.year == today.year && date.month < today.month) {
        periods.insert(.month(date.year, date.month))
      }
      if date.year < today.year { periods.insert(.year(date.year)) }
    }
    return periods.sorted { lhs, rhs in
      if lhs.year != rhs.year { return lhs.year > rhs.year }
      return (lhs.month ?? 13) > (rhs.month ?? 13)
    }
  }
}

/// Month in Review and Year in Review (#239): a read-only recap of a finished period, built
/// from the ledger alone. Each currency has its own figures and nothing is converted.
/// Transfers and adjustments are neither in nor out, as in every other total.
public struct LedgerPeriodRecap: Equatable, Sendable {
  public static let topCategoryCount = 5
  public static let biggestExpenseCount = 3
  public static let otherCategoryID = "other"

  public struct CategoryShare: Equatable, Sendable, Identifiable {
    /// A top-level category ID, `LedgerPeriodStatistics.uncategorizedID`, or
    /// `LedgerPeriodRecap.otherCategoryID` for everything past the top five.
    public let id: String
    public let name: String
    public let amount: ExactDecimal
    /// Whole percent of the period's spending, rounded half-even.
    public let percent: Int
    /// The same category's spending in the period before (zero when it had none). Nil for
    /// "Other", whose members differ between periods.
    public let previousAmount: ExactDecimal?
  }

  public struct Expense: Equatable, Sendable, Identifiable {
    public let id: String
    public let date: SourceLocalDate
    public let amount: ExactDecimal
    public let categoryID: String?
    public let note: String?
  }

  public struct MonthFigures: Equatable, Sendable, Identifiable {
    public let month: Int
    public let income: ExactDecimal
    public let expense: ExactDecimal
    public let net: ExactDecimal
    public var id: Int { month }

    public init(month: Int, income: ExactDecimal, expense: ExactDecimal, net: ExactDecimal) {
      self.month = month
      self.income = income
      self.expense = expense
      self.net = net
    }
  }

  /// One currency's figures.
  public struct Currency: Equatable, Sendable, Identifiable {
    public let unitCode: String
    public let income: ExactDecimal
    public let expense: ExactDecimal
    public let net: ExactDecimal
    public let previousIncome: ExactDecimal
    public let previousExpense: ExactDecimal
    public let previousNet: ExactDecimal
    /// Up to five top-level categories by spending, then "Other" when more spent.
    public let topCategories: [CategoryShare]
    /// The three largest expenses, largest first.
    public let biggestExpenses: [Expense]
    /// Year in Review only: all twelve months, January first.
    public let months: [MonthFigures]
    /// Year in Review only: the months with entries that had the highest and lowest net.
    public let bestMonth: MonthFigures?
    public let worstMonth: MonthFigures?
    public var id: String { unitCode }
  }

  public let period: LedgerRecapPeriod
  public let currencies: [Currency]
  /// Active entries dated in the period, of every kind.
  public let entryCount: Int
  /// The day with the most entries; the earliest such day on a tie. Nil with no entries.
  public let busiestDay: SourceLocalDate?
  public let busiestDayCount: Int
  public let daysWithoutEntries: Int
  public let budgetsKept: Int
  public let budgetsOverspent: Int

  public var isEmpty: Bool { entryCount == 0 }

  public init(
    period: LedgerRecapPeriod, accounts: [LedgerAccount], categories: [LedgerCategory],
    transactions: [LedgerTransactionSnapshot], budgets: [LedgerBudget] = []
  ) throws {
    let range = try period.statisticsPeriod
    let previous = try period.previous.statisticsPeriod
    let counted = Set(accounts.filter(\.countsInTotals).map(\.id))

    // Entries, busiest day and quiet days count every active entry dated in the period.
    var perDay: [SourceLocalDate: Int] = [:]
    var units = Set<String>()
    for transaction in transactions where transaction.currentRevision.lifecycle == .active {
      let draft = transaction.currentRevision.draft
      let day = draft.occurredAt.localDay
      let inPeriod = range.contains(day)
      if inPeriod { perDay[day, default: 0] += 1 }
      guard inPeriod || previous.contains(day), draft.kind == .income || draft.kind == .expense
      else { continue }
      for effect in draft.effects where counted.contains(effect.accountID) {
        units.insert(effect.amount.unitCode)
      }
    }
    let busiest = perDay.max { lhs, rhs in
      lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
    }
    var dayCount = 0
    var day = range.start
    while day < range.end {
      dayCount += 1
      day = try LedgerSchedule.addingDays(1, to: day)
    }

    self.period = period
    self.entryCount = perDay.values.reduce(0, +)
    self.busiestDay = busiest?.key
    self.busiestDayCount = busiest?.value ?? 0
    self.daysWithoutEntries = dayCount - perDay.count
    self.currencies = try units.sorted().map { unit in
      try Self.currency(
        unit, period: period, range: range, previous: previous, accounts: accounts,
        categories: categories, transactions: transactions, counted: counted)
    }

    // A budget is judged on the period's last day: kept when that day's budget period is
    // within its limit.
    let lastDay = try LedgerSchedule.addingDays(-1, to: range.end)
    var kept = 0
    var overspent = 0
    for budget in budgets {
      guard let status = try budget.status(on: lastDay, transactions: transactions) else {
        continue
      }
      if status.isOverBudget { overspent += 1 } else { kept += 1 }
    }
    self.budgetsKept = kept
    self.budgetsOverspent = overspent
  }

  private static func currency(
    _ unit: String, period: LedgerRecapPeriod, range: LedgerStatisticsPeriod,
    previous: LedgerStatisticsPeriod, accounts: [LedgerAccount], categories: [LedgerCategory],
    transactions: [LedgerTransactionSnapshot], counted: Set<String>
  ) throws -> Currency {
    let now = try LedgerPeriodStatistics(
      accounts: accounts, categories: categories, transactions: transactions, unitCode: unit,
      period: range)
    let before = try LedgerPeriodStatistics(
      accounts: accounts, categories: categories, transactions: transactions, unitCode: unit,
      period: previous)
    let zero = try ExactDecimal("0")

    // Top-level categories by spending, largest first; ties by name.
    let ranked = now.expenseCategories.filter { $0.depth == 0 && $0.totalAmount > zero }
      .sorted {
        if $0.totalAmount > $1.totalAmount { return true }
        if $1.totalAmount > $0.totalAmount { return false }
        return $0.name < $1.name
      }
    let previousByID = Dictionary(
      before.expenseCategories.filter { $0.depth == 0 }.map { ($0.id, $0.totalAmount) },
      uniquingKeysWith: { first, _ in first })
    func percent(_ amount: ExactDecimal) throws -> Int {
      guard now.expense > zero else { return 0 }
      let value = try amount.multiplied(by: ExactDecimal("100"))
        .divided(by: now.expense, scale: 0, rounding: .halfEven)
      return Int(value.description) ?? 0
    }
    var shares = try ranked.prefix(topCategoryCount).map {
      CategoryShare(
        id: $0.id, name: $0.name, amount: $0.totalAmount, percent: try percent($0.totalAmount),
        previousAmount: previousByID[$0.id] ?? zero)
    }
    if ranked.count > topCategoryCount {
      var rest = zero
      for category in ranked.dropFirst(topCategoryCount) {
        rest = try rest.adding(category.totalAmount)
      }
      shares.append(
        CategoryShare(
          id: otherCategoryID, name: "Other", amount: rest, percent: try percent(rest),
          previousAmount: nil))
    }

    // The biggest expenses: money out of counted accounts in this currency.
    var expenses: [Expense] = []
    for transaction in transactions where transaction.currentRevision.lifecycle == .active {
      let draft = transaction.currentRevision.draft
      let date = draft.occurredAt.localDay
      guard draft.kind == .expense, range.contains(date) else { continue }
      var amount = zero
      var counts = false
      for effect in draft.effects
      where counted.contains(effect.accountID) && effect.amount.unitCode == unit {
        counts = true
        amount =
          effect.direction == .decrease
          ? try amount.adding(effect.amount.amount) : try amount.subtracting(effect.amount.amount)
      }
      guard counts else { continue }
      expenses.append(
        Expense(
          id: transaction.id, date: date, amount: amount, categoryID: draft.categoryID,
          note: draft.note))
    }
    expenses.sort {
      if $0.amount > $1.amount { return true }
      if $1.amount > $0.amount { return false }
      if $0.date != $1.date { return $0.date < $1.date }
      return $0.id < $1.id
    }

    var months: [MonthFigures] = []
    var best: MonthFigures?
    var worst: MonthFigures?
    if period.kind == .year {
      let active = Set(
        transactions.filter { $0.currentRevision.lifecycle == .active }.compactMap {
          let date = $0.currentRevision.draft.occurredAt.localDay
          return date.year == period.year ? date.month : nil
        })
      for month in 1...12 {
        let stats = try LedgerPeriodStatistics(
          accounts: accounts, categories: categories, transactions: transactions, unitCode: unit,
          period: LedgerRecapPeriod.month(period.year, month).statisticsPeriod)
        let figures = MonthFigures(
          month: month, income: stats.income, expense: stats.expense, net: stats.net)
        months.append(figures)
        guard active.contains(month), stats.income > zero || stats.expense > zero else { continue }
        if best == nil || figures.net > best!.net { best = figures }
        if worst == nil || figures.net < worst!.net { worst = figures }
      }
    }

    return Currency(
      unitCode: unit, income: now.income, expense: now.expense, net: now.net,
      previousIncome: before.income, previousExpense: before.expense, previousNet: before.net,
      topCategories: shares, biggestExpenses: Array(expenses.prefix(biggestExpenseCount)),
      months: months, bestMonth: best, worstMonth: worst)
  }
}
