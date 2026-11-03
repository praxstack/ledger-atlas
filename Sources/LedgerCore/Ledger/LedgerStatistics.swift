import CryptoKit
import Foundation

/// A half-open range of civil dates for statistics: `start` is included, `end` is not.
public struct LedgerStatisticsPeriod: Equatable, Hashable, Sendable {
  public let start: SourceLocalDate
  public let end: SourceLocalDate

  public init(start: SourceLocalDate, end: SourceLocalDate) throws {
    guard start < end else { throw LedgerStatisticsError.invalidPeriod }
    self.start = start
    self.end = end
  }

  public func contains(_ date: SourceLocalDate) -> Bool { start <= date && date < end }
}

public enum LedgerStatisticsError: Error, Equatable, Sendable {
  case invalidPeriod
}

/// One category's line in a roll-up: its own amount and the amount including every
/// subcategory. Amounts are positive for money spent (expense) or received (income).
public struct LedgerCategoryStatistic: Equatable, Sendable, Identifiable {
  /// The category ID, or `LedgerPeriodStatistics.uncategorizedID`.
  public let id: String
  public let name: String
  public let parentID: String?
  /// 0 for a top-level category.
  public let depth: Int
  public let ownAmount: ExactDecimal
  public let totalAmount: ExactDecimal
  public let ownCount: Int
  public let totalCount: Int
}

/// Income and expense for one period in a trend.
public struct LedgerTrendPoint: Equatable, Sendable, Identifiable {
  public let period: LedgerStatisticsPeriod
  public let income: ExactDecimal
  public let expense: ExactDecimal
  public let net: ExactDecimal

  public var id: SourceLocalDate { period.start }
}

/// Statistics for one currency and one period, all computed in one pass over one ledger
/// snapshot, so every figure on the screen and in the PDF reconciles to the same data.
///
/// The rules:
/// - Only active transactions on accounts that count in totals, in this currency.
/// - Income and expense come from income and expense transactions only. Transfers move money
///   between accounts and adjustments correct balances; both are counted but never added in.
/// - Each transaction counts once, in the category it names. A split purchase is stored as one
///   transaction per line, so each line counts once in its own category and the purchase is
///   never counted again as a whole.
/// - A category's total includes its subcategories. Top-level totals plus "Uncategorized" add
///   up to the income or expense figure exactly.
public struct LedgerPeriodStatistics: Equatable, Sendable {
  public static let uncategorizedID = "uncategorized"

  public let unitCode: String
  public let period: LedgerStatisticsPeriod
  public let income: ExactDecimal
  public let expense: ExactDecimal
  /// Income minus expense.
  public let net: ExactDecimal
  public let incomeCount: Int
  public let expenseCount: Int
  public let transferCount: Int
  public let adjustmentCount: Int
  /// Depth-first, siblings in display order. Only categories with activity appear.
  public let expenseCategories: [LedgerCategoryStatistic]
  public let incomeCategories: [LedgerCategoryStatistic]
  /// Balances of the counted accounts in this currency at the end of the period.
  public let closingBalance: LedgerBalanceSummary?
  /// SHA-256 of the currency, the period and every transaction revision the figures read.
  /// The screen and the PDF show it, so two copies can be checked against each other.
  public let snapshotDigest: String

  /// Transaction IDs behind each category's own line, for drill-down.
  private let ownTransactionIDs: [String: [String]]
  private let childrenByID: [String: [String]]

  public init(
    accounts: [LedgerAccount], categories: [LedgerCategory],
    transactions: [LedgerTransactionSnapshot], unitCode: String, period: LedgerStatisticsPeriod
  ) throws {
    let zero = try ExactDecimal("0")
    let counted = Dictionary(
      accounts.filter { $0.countsInTotals && $0.currencyUnit == unitCode }.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
    let categoriesByID = Dictionary(
      categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    var income = zero
    var expense = zero
    var counts: [LedgerTransactionKind: Int] = [:]
    var own: [LedgerTransactionKind: [String: (amount: ExactDecimal, ids: [String])]] = [:]
    var digestLines: [String] = []

    for transaction in transactions where transaction.currentRevision.lifecycle == .active {
      let draft = transaction.currentRevision.draft
      let date = draft.occurredAt.localDateTime.date
      guard date < period.end else { continue }
      let effects = draft.effects.filter {
        counted[$0.accountID] != nil && $0.amount.unitCode == unitCode
      }
      guard !effects.isEmpty else { continue }
      // Everything up to the period end feeds the closing balance, so it is in the digest.
      digestLines.append("\(transaction.id) \(transaction.currentRevision.id)")
      guard period.contains(date) else { continue }
      counts[draft.kind, default: 0] += 1
      var signed = zero  // money in minus money out
      for effect in effects {
        signed =
          switch effect.direction {
          case .increase: try signed.adding(effect.amount.amount)
          case .decrease: try signed.subtracting(effect.amount.amount)
          }
      }
      let amount: ExactDecimal
      switch draft.kind {
      case .income:
        amount = signed
        income = try income.adding(amount)
      case .expense:
        amount = try zero.subtracting(signed)
        expense = try expense.adding(amount)
      case .transfer, .adjustment:
        continue
      }
      let key = draft.categoryID.flatMap { categoriesByID[$0] != nil ? $0 : nil }
        ?? Self.uncategorizedID
      var entry = own[draft.kind, default: [:]][key] ?? (zero, [])
      entry.amount = try entry.amount.adding(amount)
      entry.ids.append(transaction.id)
      own[draft.kind, default: [:]][key] = entry
    }

    var children: [String: [String]] = [:]
    for category in categories {
      if let parentID = category.parentID, categoriesByID[parentID] != nil {
        children[parentID, default: []].append(category.id)
      }
    }
    for key in children.keys {
      children[key]?.sort { Self.order(categoriesByID[$0], categoriesByID[$1]) }
    }

    self.unitCode = unitCode
    self.period = period
    self.income = income
    self.expense = expense
    self.net = try income.subtracting(expense)
    self.incomeCount = counts[.income] ?? 0
    self.expenseCount = counts[.expense] ?? 0
    self.transferCount = counts[.transfer] ?? 0
    self.adjustmentCount = counts[.adjustment] ?? 0
    self.childrenByID = children
    self.expenseCategories = try Self.tree(
      own[.expense] ?? [:], categories: categoriesByID, children: children, zero: zero)
    self.incomeCategories = try Self.tree(
      own[.income] ?? [:], categories: categoriesByID, children: children, zero: zero)
    var ids: [String: [String]] = [:]
    for (_, byCategory) in own {
      for (key, entry) in byCategory { ids[key, default: []] += entry.ids }
    }
    self.ownTransactionIDs = ids.mapValues { $0.sorted() }

    let balanceTransactions = transactions.filter {
      $0.currentRevision.lifecycle == .active
        && $0.currentRevision.draft.occurredAt.localDateTime.date < period.end
    }
    let sheet = try LedgerAccountBalanceSheet(
      accounts: Array(counted.values), transactions: balanceTransactions)
    self.closingBalance = sheet.summaries.first { $0.unitCode == unitCode }

    let header = "ledger-atlas.statistics.v1\n\(unitCode)\n\(Self.text(period.start))\n\(Self.text(period.end))\n"
    let body = digestLines.sorted().joined(separator: "\n")
    self.snapshotDigest = SHA256.hash(data: Data((header + body).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  /// The transactions behind a category's line, sorted by ID. With
  /// `includingSubcategories`, also those of every subcategory, matching `totalAmount`.
  public func transactionIDs(inCategory id: String, includingSubcategories: Bool) -> [String] {
    guard includingSubcategories else { return ownTransactionIDs[id] ?? [] }
    var result: [String] = []
    var pending = [id]
    var seen: Set<String> = []
    while let current = pending.popLast() {
      guard seen.insert(current).inserted else { continue }
      result += ownTransactionIDs[current] ?? []
      pending += childrenByID[current] ?? []
    }
    return result.sorted()
  }

  /// Income and expense for each period, from the same rules as a single period.
  public static func trend(
    accounts: [LedgerAccount], categories: [LedgerCategory],
    transactions: [LedgerTransactionSnapshot], unitCode: String,
    periods: [LedgerStatisticsPeriod]
  ) throws -> [LedgerTrendPoint] {
    try periods.map { period in
      let statistics = try LedgerPeriodStatistics(
        accounts: accounts, categories: [], transactions: transactions, unitCode: unitCode,
        period: period)
      return LedgerTrendPoint(
        period: period, income: statistics.income, expense: statistics.expense,
        net: statistics.net)
    }
  }

  /// A plain-text table with every figure, for screen readers and the PDF.
  public var accessibleLines: [String] {
    var lines = [
      "Period: \(Self.text(period.start)) to \(Self.text(period.end)) (end not included)",
      "Currency: \(unitCode)",
      "Income: \(income.rawLiteral) \(unitCode) (\(incomeCount))",
      "Expense: \(expense.rawLiteral) \(unitCode) (\(expenseCount))",
      "Net: \(net.rawLiteral) \(unitCode)",
      "Transfers: \(transferCount), adjustments: \(adjustmentCount) (not in income or expense)",
    ]
    if let closingBalance {
      lines.append(
        "Balance at period end: \(closingBalance.net.rawLiteral) \(unitCode) across \(closingBalance.accountCount) accounts"
      )
    }
    for (title, rows) in [("Expense by category", expenseCategories), ("Income by category", incomeCategories)]
    where !rows.isEmpty {
      lines.append(title)
      for row in rows {
        let indent = String(repeating: "  ", count: row.depth + 1)
        let own = row.ownCount == row.totalCount ? "" : ", own \(row.ownAmount.rawLiteral)"
        lines.append(
          "\(indent)\(row.name): \(row.totalAmount.rawLiteral) \(unitCode) (\(row.totalCount)\(own))")
      }
    }
    lines.append("Snapshot: \(snapshotDigest.prefix(16))")
    return lines
  }

  static func text(_ date: SourceLocalDate) -> String {
    String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
  }

  private static func order(_ lhs: LedgerCategory?, _ rhs: LedgerCategory?) -> Bool {
    guard let lhs, let rhs else { return lhs != nil }
    return (lhs.displayOrder, lhs.name, lhs.id) < (rhs.displayOrder, rhs.name, rhs.id)
  }

  /// Rolls each category's own amount into itself and every ancestor once, then lists the
  /// categories with activity depth-first. "Uncategorized" comes last.
  private static func tree(
    _ own: [String: (amount: ExactDecimal, ids: [String])],
    categories: [String: LedgerCategory], children: [String: [String]], zero: ExactDecimal
  ) throws -> [LedgerCategoryStatistic] {
    var totals: [String: (amount: ExactDecimal, count: Int)] = [:]
    for (id, entry) in own where id != uncategorizedID {
      var cursor: String? = id
      var visited: Set<String> = []
      // `visited` stops a parent cycle in damaged data from looping forever.
      while let current = cursor, categories[current] != nil, visited.insert(current).inserted {
        var total = totals[current] ?? (zero, 0)
        total.amount = try total.amount.adding(entry.amount)
        total.count += entry.ids.count
        totals[current] = total
        cursor = categories[current]?.parentID
      }
    }
    let roots = categories.values.filter {
      $0.parentID.flatMap { categories[$0] } == nil && totals[$0.id] != nil
    }.sorted { order($0, $1) }.map(\.id)
    var rows: [LedgerCategoryStatistic] = []
    var pending = roots.reversed().map { ($0, 0) }
    var emitted: Set<String> = []
    while let (id, depth) = pending.popLast() {
      guard let category = categories[id], let total = totals[id], emitted.insert(id).inserted
      else { continue }
      rows.append(
        LedgerCategoryStatistic(
          id: id, name: category.name, parentID: category.parentID, depth: depth,
          ownAmount: own[id]?.amount ?? zero, totalAmount: total.amount,
          ownCount: own[id]?.ids.count ?? 0, totalCount: total.count))
      for child in (children[id] ?? []).reversed() where totals[child] != nil {
        pending.append((child, depth + 1))
      }
    }
    if let uncategorized = own[uncategorizedID] {
      rows.append(
        LedgerCategoryStatistic(
          id: uncategorizedID, name: "Uncategorized", parentID: nil, depth: 0,
          ownAmount: uncategorized.amount, totalAmount: uncategorized.amount,
          ownCount: uncategorized.ids.count, totalCount: uncategorized.ids.count))
    }
    return rows
  }
}
