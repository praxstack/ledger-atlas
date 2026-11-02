import Foundation

/// Where a budget stands on a given day.
public struct LedgerBudgetStatus: Equatable, Sendable {
  public let budgetID: String
  /// First and last day (inclusive) of the period that contains the day asked about.
  public let periodStart: SourceLocalDate
  public let periodEnd: SourceLocalDate
  /// Unused amount carried in from earlier periods (zero without rollover).
  public let carried: ExactDecimal
  /// The budget amount plus what was carried in.
  public let available: ExactDecimal
  /// Active expenses in the budget's category and currency during this period.
  public let spent: ExactDecimal
  /// `available - spent`; negative when over budget.
  public let remaining: ExactDecimal

  public var isOverBudget: Bool { remaining.isNegative }

  /// How far over budget, as a positive amount; nil when within budget.
  public var overspent: ExactDecimal? {
    isOverBudget ? try? spent.subtracting(available) : nil
  }
}

extension LedgerBudget {
  /// The budget's state on `day`, or nil before the budget starts or once it is closed.
  /// Periods start on the budget's start date and repeat monthly or yearly from it (a budget
  /// starting on the 31st runs to the day before the next month's 31st, or its last day).
  /// With rollover, each period's unused amount carries forward; overspending does not.
  public func status(on day: SourceLocalDate, transactions: [LedgerTransactionSnapshot]) throws
    -> LedgerBudgetStatus?
  {
    guard lifecycle == .active, day >= start else { return nil }
    let frequency: LedgerRecurrenceFrequency = period == .monthly ? .monthly : .yearly
    func periodStart(_ index: Int) throws -> SourceLocalDate {
      try LedgerSchedule.occurrence(index, from: start, frequency: frequency, interval: 1)
    }
    // Periods from the start through the one containing `day`.
    var starts = [start]
    while true {
      let next = try periodStart(starts.count)
      if next > day { break }
      starts.append(next)
    }
    let currentEnd = try LedgerSchedule.addingDays(-1, to: periodStart(starts.count))

    let zero = try ExactDecimal("0")
    var spentByPeriod = [ExactDecimal](repeating: zero, count: starts.count)
    for transaction in transactions {
      let revision = transaction.currentRevision
      let draft = revision.draft
      guard revision.lifecycle == .active, draft.kind == .expense, draft.categoryID == categoryID
      else { continue }
      let date = draft.occurredAt.localDay
      guard date >= start, date <= currentEnd else { continue }
      let index = Self.periodIndex(of: date, in: starts)
      for effect in draft.effects
      where effect.direction == .decrease && effect.amount.unitCode == amount.unitCode {
        spentByPeriod[index] = try spentByPeriod[index].adding(effect.amount.amount)
      }
    }

    var carried = zero
    for index in 0..<(starts.count - 1) where rollover {
      let left = try amount.amount.adding(carried).subtracting(spentByPeriod[index])
      carried = left.isPositive ? left : zero
    }
    let available = try amount.amount.adding(carried)
    let spent = spentByPeriod[starts.count - 1]
    return LedgerBudgetStatus(
      budgetID: id, periodStart: starts[starts.count - 1], periodEnd: currentEnd,
      carried: carried, available: available, spent: spent,
      remaining: try available.subtracting(spent))
  }

  /// Index of the last period start on or before `date` (starts are ascending).
  private static func periodIndex(of date: SourceLocalDate, in starts: [SourceLocalDate]) -> Int {
    var low = 0
    var high = starts.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if starts[middle] <= date { low = middle } else { high = middle - 1 }
    }
    return low
  }
}
