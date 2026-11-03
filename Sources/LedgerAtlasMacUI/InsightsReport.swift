import Foundation
import LedgerCore
import LedgerStore

/// Month or year, for the Insights period picker.
public enum InsightsPeriodKind: String, CaseIterable, Hashable, Sendable, Identifiable {
  case month
  case year

  public var id: Self { self }
  public var title: String { self == .month ? "Month" : "Year" }
}

/// Everything the Insights screen and its PDF show for one period and currency, computed from
/// one ledger snapshot. The screen, its tables and the PDF all read this one value.
public struct InsightsReport: Equatable, Sendable {
  public let kind: InsightsPeriodKind
  public let units: [String]
  public let statistics: LedgerPeriodStatistics
  /// The selected period and the ones before it, oldest first: six months or five years.
  public let trend: [LedgerTrendPoint]

  public var unitCode: String { statistics.unitCode }
  public var period: LedgerStatisticsPeriod { statistics.period }

  public init(
    snapshot: LedgerStore.LedgerReadSnapshot, kind: InsightsPeriodKind, containing date: SourceLocalDate,
    unitCode: String?, rule: LedgerPeriodRule
  ) throws {
    let units = LedgerStatement.unitCodes(in: snapshot)
    let unit = unitCode.flatMap { units.contains($0) ? $0 : nil } ?? units[0]
    let period = try Self.period(kind, containing: date, rule: rule)
    var periods = [period]
    for _ in 1..<(kind == .month ? 6 : 5) {
      periods.insert(try Self.period(before: periods[0], kind, rule: rule), at: 0)
    }
    self.kind = kind
    self.units = units
    self.statistics = try LedgerPeriodStatistics(
      accounts: snapshot.accounts, categories: snapshot.categories,
      transactions: snapshot.transactions, unitCode: unit, period: period)
    self.trend = try LedgerPeriodStatistics.trend(
      accounts: snapshot.accounts, categories: snapshot.categories,
      transactions: snapshot.transactions, unitCode: unit, periods: periods)
  }

  /// The month (by the ledger's month start day) or calendar year that contains `date`.
  public static func period(
    _ kind: InsightsPeriodKind, containing date: SourceLocalDate, rule: LedgerPeriodRule
  ) throws -> LedgerStatisticsPeriod {
    switch kind {
    case .month:
      let range = rule.monthPeriod(containing: date)
      return try LedgerStatisticsPeriod(start: range.start, end: range.end)
    case .year:
      return try LedgerStatisticsPeriod(
        start: SourceLocalDate(year: date.year, month: 1, day: 1),
        end: SourceLocalDate(year: date.year + 1, month: 1, day: 1))
    }
  }

  public static func period(
    before period: LedgerStatisticsPeriod, _ kind: InsightsPeriodKind, rule: LedgerPeriodRule
  ) throws -> LedgerStatisticsPeriod {
    switch kind {
    case .month:
      let range = rule.monthPeriod(
        before: LedgerLocalDateRange(start: period.start, end: period.end))
      return try LedgerStatisticsPeriod(start: range.start, end: range.end)
    case .year:
      return try Self.period(
        .year, containing: SourceLocalDate(year: period.start.year - 1, month: 1, day: 1),
        rule: rule)
    }
  }

  /// A date inside the period `offset` steps away from the one containing `date`.
  public static func date(
    _ date: SourceLocalDate, movedBy offset: Int, _ kind: InsightsPeriodKind,
    rule: LedgerPeriodRule
  ) throws -> SourceLocalDate {
    var period = try Self.period(kind, containing: date, rule: rule)
    for _ in 0..<abs(offset) {
      if offset < 0 {
        period = try Self.period(before: period, kind, rule: rule)
      } else {
        period = try Self.period(kind, containing: period.end, rule: rule)
      }
    }
    return period.start
  }

  /// "Nov 2026" style for a month that starts on the 1st, the date range otherwise, or the year.
  public func title(_ formatter: LedgerDisplayFormatter) -> String {
    switch kind {
    case .year:
      return String(period.start.year)
    case .month:
      if period.start.day == 1 {
        let format = DateFormatter()
        format.locale = formatter.locale
        format.setLocalizedDateFormatFromTemplate("MMMMy")
        format.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        format.calendar = calendar
        let components = DateComponents(
          year: period.start.year, month: period.start.month, day: 15, hour: 12)
        if let date = calendar.date(from: components) { return format.string(from: date) }
      }
      let last = LedgerPeriodRule.date(fromDays: LedgerPeriodRule.days(from: period.end) - 1)
      return "\(formatter.date(period.start)) – \(formatter.date(last))"
    }
  }

  /// The lines of a printable statement. With `redactingNames`, category names become
  /// "Category 1", "Category 2" … in the order they appear, so the PDF can be shared without
  /// naming what the money was for. Notes and account names are never included.
  public func statementLines(redactingNames: Bool, title: String) -> [String] {
    var aliases: [String: String] = [:]
    func name(_ row: LedgerCategoryStatistic) -> String {
      guard redactingNames, row.id != LedgerPeriodStatistics.uncategorizedID else {
        return row.name
      }
      if let alias = aliases[row.id] { return alias }
      let alias = "Category \(aliases.count + 1)"
      aliases[row.id] = alias
      return alias
    }
    let s = statistics
    var lines = [
      "Ledger Atlas statement",
      "\(title) · \(s.unitCode)",
      "",
      "Income: \(s.income.rawLiteral) \(s.unitCode) (\(s.incomeCount))",
      "Expense: \(s.expense.rawLiteral) \(s.unitCode) (\(s.expenseCount))",
      "Net: \(s.net.rawLiteral) \(s.unitCode)",
    ]
    if let balance = s.closingBalance {
      lines.append("Balance at period end: \(balance.net.rawLiteral) \(s.unitCode)")
    }
    lines.append("Transfers: \(s.transferCount), adjustments: \(s.adjustmentCount) (not in income or expense)")
    for (heading, rows) in [("Expense by category", s.expenseCategories), ("Income by category", s.incomeCategories)]
    where !rows.isEmpty {
      lines += ["", heading]
      for row in rows {
        let indent = String(repeating: "  ", count: row.depth + 1)
        lines.append("\(indent)\(name(row)): \(row.totalAmount.rawLiteral) (\(row.totalCount))")
      }
    }
    lines += ["", "Trend (income / expense / net)"]
    for point in trend {
      lines.append(
        "  \(LedgerPeriodStatistics.isoText(point.period.start)): \(point.income.rawLiteral) / \(point.expense.rawLiteral) / \(point.net.rawLiteral)"
      )
    }
    lines += [
      "",
      "This statement is a printed view of the ledger, not a record. The ledger file stays the only source of truth; a PDF is never read back into it.",
      redactingNames ? "Category names are hidden." : "Category names are shown.",
      "Snapshot \(s.snapshotDigest)",
    ]
    return lines
  }
}

extension LedgerPeriodStatistics {
  static func isoText(_ date: SourceLocalDate) -> String {
    String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
  }
}
