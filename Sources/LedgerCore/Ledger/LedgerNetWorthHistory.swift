/// Net worth in one currency at the close of each of a series of days, for the Overview chart.
///
/// It follows the same rule as `LedgerAccountBalanceSheet`: only active transactions, only
/// accounts that count in totals, and only effects in the account's own currency. Net worth is
/// assets plus liabilities (a loan you owe on is a negative balance), so the last point
/// matches that sheet's net for the currency when no entry is dated after it.
public enum LedgerNetWorthHistory {
  /// Net worth before each of `ends` (an exclusive day: everything dated earlier counts).
  /// `ends` must be in ascending order; the result has one value per end.
  public static func closing(
    accounts: [LedgerAccount], transactions: [LedgerTransactionSnapshot], unitCode: String,
    before ends: [SourceLocalDate]
  ) throws -> [ExactDecimal] {
    let zero = try ExactDecimal("0")
    guard !ends.isEmpty else { return [] }
    let counting = Set(
      accounts.filter { $0.countsInTotals && $0.currencyUnit == unitCode }.map(\.id))
    // Sum each transaction into the first period that closes after its day.
    var buckets = [ExactDecimal](repeating: zero, count: ends.count + 1)
    for transaction in transactions where transaction.currentRevision.lifecycle == .active {
      let draft = transaction.currentRevision.draft
      let day = draft.occurredAt.localDateTime.date
      let index = ends.firstIndex(where: { day < $0 }) ?? ends.count
      for effect in draft.effects
      where counting.contains(effect.accountID) && effect.amount.unitCode == unitCode {
        buckets[index] =
          switch effect.direction {
          case .increase: try buckets[index].adding(effect.amount.amount)
          case .decrease: try buckets[index].subtracting(effect.amount.amount)
          }
      }
    }
    var running = zero
    var result: [ExactDecimal] = []
    result.reserveCapacity(ends.count)
    for index in ends.indices {
      running = try running.adding(buckets[index])
      result.append(running)
    }
    return result
  }
}
