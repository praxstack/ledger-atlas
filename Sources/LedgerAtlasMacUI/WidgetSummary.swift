import Foundation
import LedgerCore
import LedgerStore

extension RedactedWidgetProjection {
  /// The ready projection for an open, unlocked ledger. Only two coarse facts leave the app:
  /// how many active entries fall in the current month, and the worst budget's bucket.
  static func ready(
    snapshot: LedgerStore.LedgerReadSnapshot, today: SourceLocalDate
  ) -> RedactedWidgetProjection {
    let active = snapshot.transactions.filter { $0.currentRevision.lifecycle == .active }
    let entries = active.filter {
      let day = $0.currentRevision.draft.occurredAt.localDay
      return day.year == today.year && day.month == today.month
    }.count
    return .init(
      state: .ready,
      summary: .init(
        entriesThisMonth: entries,
        budgets: budgetBucket(snapshot.budgets, transactions: snapshot.transactions, on: today)))
  }

  /// Over if any budget is over; near its limit if any has less than a tenth left.
  static func budgetBucket(
    _ budgets: [LedgerBudget], transactions: [LedgerTransactionSnapshot], on day: SourceLocalDate
  ) -> BudgetBucket {
    let statuses = budgets.compactMap { try? $0.status(on: day, transactions: transactions) }
    guard !statuses.isEmpty else { return .none }
    if statuses.contains(where: \.isOverBudget) { return .over }
    let tenth = try? ExactDecimal("0.1")
    let near = statuses.contains { status in
      guard let tenth, let limit = try? status.available.multiplied(by: tenth) else {
        return false
      }
      return status.remaining < limit
    }
    return near ? .nearLimit : .onTrack
  }
}
