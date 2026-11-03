import Foundation
import LedgerCore
import LedgerStore

/// Everything the Overview screen shows, computed once from one ledger snapshot off the main
/// thread. Every figure follows the rules the Accounts and Insights screens use, so the
/// numbers here always match theirs.
struct OverviewModel: Sendable {
  struct NetWorthPoint: Identifiable, Sendable {
    /// First day of the month this point closes.
    let month: SourceLocalDate
    let value: ExactDecimal
    var id: SourceLocalDate { month }
  }

  struct SpendingLine: Identifiable, Sendable {
    let id: String
    let name: String
    let amount: ExactDecimal
    /// Share of the month's spending, 0...1.
    let share: Double
  }

  struct BudgetLine: Identifiable, Sendable {
    let id: String
    let name: String
    let spent: CurrencyAmount
    let available: CurrencyAmount
    let remaining: CurrencyAmount
    let fraction: Double
    var isOver: Bool { remaining.amount.isNegative }
  }

  struct RecentLine: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let day: SourceLocalDate
    let amount: CurrencyAmount
    let sign: LedgerDisplayFormatter.SignStyle
    let isIncome: Bool
  }

  let unitCode: String
  let netWorth: CurrencyAmount
  /// Change since the close of last month, nil without a previous month.
  let monthChange: CurrencyAmount?
  /// Twelve month-end closes, oldest first.
  let history: [NetWorthPoint]
  /// This month's statistics and the six-month trend (money in and out).
  let month: InsightsReport
  let spending: [SpendingLine]
  let budgets: [BudgetLine]
  let recent: [RecentLine]

  init(
    snapshot: LedgerStore.LedgerReadSnapshot, today: SourceLocalDate, rule: LedgerPeriodRule
  ) throws {
    let day = InsightsReport.openingDay(in: snapshot, today: today, .month, rule: rule)
    let month = try InsightsReport(
      snapshot: snapshot, kind: .month, containing: day, unitCode: nil, rule: rule)
    let unit = month.unitCode
    self.unitCode = unit
    self.month = month

    // Twelve months ending with the shown one.
    var periods = [month.period]
    for _ in 1..<12 {
      periods.insert(try InsightsReport.period(before: periods[0], .month, rule: rule), at: 0)
    }
    let closes = try LedgerNetWorthHistory.closing(
      accounts: snapshot.accounts, transactions: snapshot.transactions, unitCode: unit,
      before: periods.map(\.end))
    history = zip(periods, closes).map { NetWorthPoint(month: $0.start, value: $1) }

    let sheet = try LedgerAccountBalanceSheet(
      accounts: snapshot.accounts, transactions: snapshot.transactions)
    let zero = try ExactDecimal("0")
    let net = sheet.summaries.first { $0.unitCode == unit }?.net ?? zero
    netWorth = try CurrencyAmount(unitCode: unit, amount: net)
    if closes.count >= 2 {
      monthChange = try CurrencyAmount(
        unitCode: unit, amount: try closes[closes.count - 1].subtracting(closes[closes.count - 2]))
    } else {
      monthChange = nil
    }

    // Top-level spending categories, largest first.
    let topLevel = month.statistics.expenseCategories.filter { $0.depth == 0 }
    let total = Self.double(month.statistics.expense)
    spending =
      topLevel
      .sorted { $0.totalAmount > $1.totalAmount }
      .prefix(6)
      .map {
        SpendingLine(
          id: $0.id, name: $0.name, amount: $0.totalAmount,
          share: total > 0 ? Self.double($0.totalAmount) / total : 0)
      }

    budgets = snapshot.budgets
      .filter { $0.lifecycle == .active && $0.amount.unitCode == unit }
      .compactMap { budget -> BudgetLine? in
        guard let status = try? budget.status(on: day, transactions: snapshot.transactions),
          let spent = try? CurrencyAmount(unitCode: unit, amount: status.spent),
          let available = try? CurrencyAmount(unitCode: unit, amount: status.available),
          let remaining = try? CurrencyAmount(unitCode: unit, amount: status.remaining)
        else { return nil }
        let limit = Self.double(status.available)
        return BudgetLine(
          id: budget.id, name: budget.name,
          spent: spent, available: available, remaining: remaining,
          fraction: limit > 0 ? Self.double(status.spent) / limit : (status.spent.isPositive ? 2 : 0))
      }
      .sorted { $0.fraction > $1.fraction }

    let categoryNames = Dictionary(
      snapshot.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let accountNames = Dictionary(
      snapshot.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    recent =
      snapshot.transactions
      .filter { $0.currentRevision.lifecycle == .active }
      .sorted { $0.currentRevision.draft.occurredAt.localDateTime > $1.currentRevision.draft.occurredAt.localDateTime }
      .prefix(8)
      .compactMap { transaction in
        Self.recentLine(transaction, categories: categoryNames, accounts: accountNames)
      }
  }

  static func recentLine(
    _ transaction: LedgerTransactionSnapshot, categories: [String: String], accounts: [String: String]
  ) -> RecentLine? {
    let draft = transaction.currentRevision.draft
    guard let first = draft.effects.first else { return nil }
    let category = draft.categoryID.flatMap { categories[$0] }
    let account = accounts[first.accountID] ?? "Account"
    let note = draft.note?.trimmingCharacters(in: .whitespacesAndNewlines)
    switch draft.kind {
    case .transfer:
      let destination = draft.effects.dropFirst().first.flatMap { accounts[$0.accountID] }
      let from = draft.effects.first { $0.direction == .decrease }.flatMap { accounts[$0.accountID] }
      let to = draft.effects.first { $0.direction == .increase }.flatMap { accounts[$0.accountID] }
      return RecentLine(
        id: transaction.id, title: note.flatMap { $0.isEmpty ? nil : $0 } ?? "Transfer",
        detail: "\(from ?? account) → \(to ?? destination ?? account)",
        day: draft.occurredAt.localDateTime.date, amount: first.amount, sign: .never,
        isIncome: false)
    default:
      guard
        let signed = try? draft.effects.reduce(ExactDecimal("0"), { total, effect in
          switch effect.direction {
          case .increase: try total.adding(effect.amount.amount)
          case .decrease: try total.subtracting(effect.amount.amount)
          }
        }),
        let amount = try? CurrencyAmount(unitCode: first.amount.unitCode, amount: signed)
      else { return nil }
      let title = note.flatMap { $0.isEmpty ? nil : $0 } ?? category ?? draft.kind.rawValue.capitalized
      let detail = [category == title ? nil : category, account].compactMap { $0 }.joined(separator: " · ")
      return RecentLine(
        id: transaction.id, title: title, detail: detail, day: draft.occurredAt.localDateTime.date,
        amount: amount, sign: .always, isIncome: signed.isPositive)
    }
  }

  static func double(_ value: ExactDecimal) -> Double { Double(value.description) ?? 0 }
}
