import Foundation

/// What is due soon (#171): dates recurrence rules produce and installment payments already in
/// the ledger, for the next days, grouped by day. Read-only: nothing here writes, marks paid or
/// changes how occurrences are generated.
public struct LedgerUpcoming: Equatable, Sendable {
  public static let defaultDays = 30

  public enum Source: Equatable, Hashable, Sendable {
    /// A date a recurrence rule produces.
    case recurrence(ruleID: String)
    /// One payment of an installment plan, already recorded as a dated entry.
    case installment(planID: String, transactionID: String)
  }

  public struct Item: Equatable, Sendable, Identifiable {
    public let date: SourceLocalDate
    public let kind: LedgerTransactionKind
    public let amount: CurrencyAmount
    public let accountID: String
    public let categoryID: String?
    public let source: Source
    /// A rule's date before today that has not been entered yet.
    public let isOverdue: Bool

    public var id: String {
      let day = String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
      switch source {
      case .recurrence(let ruleID): return "recurrence:\(ruleID):\(day)"
      case .installment(_, let transactionID): return "installment:\(transactionID)"
      }
    }
  }

  public struct Day: Equatable, Sendable, Identifiable {
    public let date: SourceLocalDate
    public let items: [Item]
    public var id: SourceLocalDate { date }
  }

  /// The person's calendar day the list was made for.
  public let today: SourceLocalDate
  /// How many days ahead the list looks, today included.
  public let daysAhead: Int
  /// Overdue days first (oldest first), then today and the days ahead.
  public let days: [Day]
  /// Income and expense of every listed item, per currency.
  public let totals: [LedgerBrowseTotal]
  /// Overdue dates older than the look-back window, left out of `days`.
  public let olderOverdueCount: Int

  public var items: [Item] { days.flatMap(\.items) }
  public var isEmpty: Bool { days.isEmpty }
  public var overdueCount: Int { items.filter(\.isOverdue).count }

  /// - Parameters:
  ///   - today: the person's calendar day.
  ///   - days: how far ahead to look; today counts as the first day.
  ///   - lookBackDays: how far back an overdue rule date is still listed.
  public init(
    rules: [LedgerRecurrenceRule], installmentPlans: [LedgerInstallmentPlan],
    transactions: [LedgerTransactionSnapshot], today: SourceLocalDate,
    days: Int = defaultDays, lookBackDays: Int = defaultDays
  ) {
    let ahead = max(1, days)
    let end = (try? LedgerSchedule.addingDays(ahead - 1, to: today)) ?? today
    let lookBackStart = (try? LedgerSchedule.addingDays(-max(0, lookBackDays), to: today)) ?? today

    // Dates a rule has already been entered on, read from the entries it generated.
    var entered: [String: Set<SourceLocalDate>] = [:]
    var installmentEntries: [String: [LedgerTransactionSnapshot]] = [:]
    for transaction in transactions where transaction.currentRevision.lifecycle == .active {
      let draft = transaction.currentRevision.draft
      for literal in draft.sourceLiterals {
        switch literal.field {
        case "recurrence.ruleID":
          entered[literal.literal, default: []].insert(draft.occurredAt.localDay)
        case "installment.planID":
          installmentEntries[literal.literal, default: []].append(transaction)
        default: break
        }
      }
    }

    var items: [Item] = []
    var olderOverdue = 0
    for rule in rules where rule.lifecycle == .active && !rule.paused {
      // A rule that cannot list its dates (one past the generation limits) is left out rather
      // than guessed at.
      guard let dates = try? LedgerSchedule.dates(for: rule, through: end) else { continue }
      let done = entered[rule.id] ?? []
      for date in dates {
        let overdue = date < today
        if overdue, done.contains(date) { continue }
        if overdue, date < lookBackStart {
          olderOverdue += 1
          continue
        }
        items.append(
          Item(
            date: date, kind: rule.kind, amount: rule.amount, accountID: rule.accountID,
            categoryID: rule.categoryID, source: .recurrence(ruleID: rule.id),
            isOverdue: overdue))
      }
    }
    for plan in installmentPlans where plan.lifecycle == .active {
      for transaction in installmentEntries[plan.id] ?? [] {
        let draft = transaction.currentRevision.draft
        let date = draft.occurredAt.localDay
        guard date >= today, date <= end, let effect = draft.effects.first else { continue }
        items.append(
          Item(
            date: date, kind: draft.kind, amount: effect.amount, accountID: effect.accountID,
            categoryID: draft.categoryID,
            source: .installment(planID: plan.id, transactionID: transaction.id),
            isOverdue: false))
      }
    }

    items.sort { lhs, rhs in lhs.date != rhs.date ? lhs.date < rhs.date : lhs.id < rhs.id }
    var grouped: [Day] = []
    for item in items {
      if let last = grouped.last, last.date == item.date {
        grouped[grouped.count - 1] = Day(date: last.date, items: last.items + [item])
      } else {
        grouped.append(Day(date: item.date, items: [item]))
      }
    }
    self.today = today
    self.daysAhead = ahead
    self.days = grouped
    self.totals = Self.totals(items)
    self.olderOverdueCount = olderOverdue
  }

  private static func totals(_ items: [Item]) -> [LedgerBrowseTotal] {
    var sums: [String: (income: ExactDecimal?, expense: ExactDecimal?)] = [:]
    let zero = try! ExactDecimal("0")
    for item in items {
      var sum = sums[item.amount.unitCode] ?? (zero, zero)
      // A sum past the exact-decimal limits becomes nil and is shown as unavailable.
      if item.kind == .income {
        sum.income = sum.income.flatMap { try? $0.adding(item.amount.amount) }
      } else {
        sum.expense = sum.expense.flatMap { try? $0.adding(item.amount.amount) }
      }
      sums[item.amount.unitCode] = sum
    }
    return sums.keys.sorted().map {
      LedgerBrowseTotal(unitCode: $0, income: sums[$0]!.income, expense: sums[$0]!.expense)
    }
  }
}
