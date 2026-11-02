/// Whether an account holds value (asset) or is money owed (liability).
///
/// Variant decides the class. It never changes arithmetic: a balance is always the signed sum of
/// the account's effects, so a loan you owe on is a negative balance and net worth is simply
/// assets plus liabilities.
public enum LedgerAccountClass: String, CaseIterable, Sendable {
  case asset
  case liability

  public init(_ variant: LedgerAccountVariant) {
    switch variant {
    case .standard, .investment: self = .asset
    case .loan, .overdraft: self = .liability
    }
  }
}

extension LedgerAccount {
  public var accountClass: LedgerAccountClass { LedgerAccountClass(variant) }

  /// The one rule every total, report and summary shares: closed, hidden, and excluded
  /// accounts keep their balances but do not add to totals.
  public var countsInTotals: Bool { lifecycle == .active && !hidden && includeInTotals }
}

/// Totals for one currency over the accounts that count in totals.
public struct LedgerBalanceSummary: Equatable, Sendable {
  public let unitCode: String
  public let assets: ExactDecimal
  public let liabilities: ExactDecimal
  public let net: ExactDecimal
  public let accountCount: Int

  public init(
    unitCode: String, assets: ExactDecimal, liabilities: ExactDecimal, net: ExactDecimal,
    accountCount: Int
  ) {
    self.unitCode = unitCode
    self.assets = assets
    self.liabilities = liabilities
    self.net = net
    self.accountCount = accountCount
  }
}

/// Per-account balances, per-group subtotals and per-currency summaries, computed from the
/// current revision of each transaction.
public struct LedgerAccountBalanceSheet: Equatable, Sendable {
  /// Every account's balance in its own currency, including closed, hidden and excluded
  /// accounts, so the accounts screen can show what each one holds.
  public let balances: [String: CurrencyAmount]
  /// Group ID (nil for ungrouped) to per-currency subtotal of accounts that count in totals.
  public let groupTotals: [String?: [String: ExactDecimal]]
  /// One summary per currency, sorted by unit code.
  public let summaries: [LedgerBalanceSummary]
  /// Effects on an account in a currency other than the account's own. These are not added to
  /// any balance; a nonzero count means the ledger needs attention, not that money vanished.
  public let foreignCurrencyEffectCount: Int

  public init(accounts: [LedgerAccount], transactions: [LedgerTransactionSnapshot]) throws {
    let zero = try ExactDecimal("0")
    let accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var sums = Dictionary(uniqueKeysWithValues: accountsByID.keys.map { ($0, zero) })
    var foreign = 0
    for transaction in transactions where transaction.currentRevision.lifecycle == .active {
      for effect in transaction.currentRevision.draft.effects {
        guard let account = accountsByID[effect.accountID], let current = sums[account.id] else {
          continue
        }
        guard effect.amount.unitCode == account.currencyUnit else {
          foreign += 1
          continue
        }
        sums[account.id] =
          switch effect.direction {
          case .increase: try current.adding(effect.amount.amount)
          case .decrease: try current.subtracting(effect.amount.amount)
          }
      }
    }

    var balances: [String: CurrencyAmount] = [:]
    var groupTotals: [String?: [String: ExactDecimal]] = [:]
    var perUnit: [String: (assets: ExactDecimal, liabilities: ExactDecimal, count: Int)] = [:]
    for account in accountsByID.values {
      let balance = sums[account.id] ?? zero
      balances[account.id] = try CurrencyAmount(unitCode: account.currencyUnit, amount: balance)
      guard account.countsInTotals else { continue }
      let unit = account.currencyUnit
      groupTotals[account.groupID, default: [:]][unit] =
        try (groupTotals[account.groupID]?[unit] ?? zero).adding(balance)
      var entry = perUnit[unit] ?? (zero, zero, 0)
      switch account.accountClass {
      case .asset: entry.assets = try entry.assets.adding(balance)
      case .liability: entry.liabilities = try entry.liabilities.adding(balance)
      }
      entry.count += 1
      perUnit[unit] = entry
    }
    self.balances = balances
    self.groupTotals = groupTotals
    self.summaries = try perUnit.sorted { $0.key < $1.key }.map { unit, entry in
      LedgerBalanceSummary(
        unitCode: unit, assets: entry.assets, liabilities: entry.liabilities,
        net: try entry.assets.adding(entry.liabilities), accountCount: entry.count)
    }
    foreignCurrencyEffectCount = foreign
  }
}
