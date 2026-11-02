import LedgerCore
import Testing

@Suite("Account balances honor account state")
struct LedgerAccountBalanceTests {
  let origin: LedgerOrigin
  let group = String(repeating: "9", count: 64)
  var serial = 0

  init() throws {
    origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  }

  private func account(
    _ key: Character, unit: String = "INR", group: String? = nil,
    lifecycle: LedgerLifecycleState = .active, hidden: Bool = false,
    includeInTotals: Bool = true, variant: LedgerAccountVariant = .standard
  ) throws -> LedgerAccount {
    try LedgerAccount(
      id: try StableLedgerID.account(origin: origin, localKey: String(repeating: key, count: 64)),
      name: "Account \(key)", currencyUnit: unit, origin: origin, lifecycle: lifecycle,
      groupID: group, hidden: hidden, includeInTotals: includeInTotals, variant: variant)
  }

  private func amount(_ literal: String, _ unit: String = "INR") throws -> CurrencyAmount {
    try CurrencyAmount(unitCode: unit, amount: ExactDecimal(literal))
  }

  private func transaction(
    _ key: Character, kind: LedgerTransactionKind,
    _ effects: [(LedgerAccount, LedgerEffectDirection, String)],
    lifecycle: LedgerLifecycleState = .active, unit: String? = nil
  ) throws -> LedgerTransactionSnapshot {
    let when = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 11, day: 2)),
      in: SourceTimeZone(fixedOffsetSeconds: 19_800), precision: .minute)
    let draft = try LedgerTransactionDraft(
      effects: try effects.map {
        try LedgerTransactionEffect(
          accountID: $0.0.id, direction: $0.1, amount: try amount($0.2, unit ?? $0.0.currencyUnit))
      },
      categoryID: nil, kind: kind, occurredAt: when, origin: origin)
    let transactionID = try StableLedgerID.transaction(
      origin: origin, localKey: String(repeating: key, count: 64))
    let revision = try LedgerTransactionRevision(
      id: try StableLedgerID.revision(transactionID: transactionID, revision: 1),
      transactionID: transactionID, revision: 1, predecessorID: nil, draft: draft,
      lifecycle: lifecycle, createdAt: UTCInstant(epochMilliseconds: 0))
    return try LedgerTransactionSnapshot(id: transactionID, currentRevision: revision)
  }

  private func decimal(_ literal: String) throws -> ExactDecimal { try ExactDecimal(literal) }

  @Test("variant decides asset or liability, never the arithmetic")
  func variantClassifies() {
    #expect(LedgerAccountClass(.standard) == .asset)
    #expect(LedgerAccountClass(.investment) == .asset)
    #expect(LedgerAccountClass(.loan) == .liability)
    #expect(LedgerAccountClass(.overdraft) == .liability)
  }

  @Test("balances are signed sums of active effects in the account's currency")
  func balancesSumActiveEffects() throws {
    let cash = try account("a")
    let bank = try account("b")
    let sheet = try LedgerAccountBalanceSheet(
      accounts: [cash, bank],
      transactions: [
        try transaction("1", kind: .income, [(bank, .increase, "50000.50")]),
        try transaction("2", kind: .expense, [(cash, .decrease, "120")]),
        try transaction("3", kind: .transfer, [(bank, .decrease, "2000"), (cash, .increase, "2000")]),
        // A deleted transaction moves nothing.
        try transaction("4", kind: .expense, [(cash, .decrease, "999")], lifecycle: .tombstoned),
      ])
    #expect(sheet.balances[cash.id]?.amount == (try decimal("1880")))
    #expect(sheet.balances[bank.id]?.amount == (try decimal("48000.50")))
    #expect(sheet.balances[bank.id]?.unitCode == "INR")
    #expect(sheet.summaries.count == 1)
    #expect(sheet.summaries[0].net == (try decimal("49880.50")))
    #expect(sheet.foreignCurrencyEffectCount == 0)
  }

  @Test("closed, hidden and excluded accounts keep balances but leave totals")
  func stateControlsTotals() throws {
    let counted = try account("a", group: group)
    let closed = try account("b", group: group, lifecycle: .tombstoned)
    let hidden = try account("c", group: group, hidden: true)
    let excluded = try account("d", includeInTotals: false)
    let accounts = [counted, closed, hidden, excluded]
    let sheet = try LedgerAccountBalanceSheet(
      accounts: accounts,
      transactions: try accounts.enumerated().map { index, account in
        try transaction(
          Character(String(index + 1)), kind: .income, [(account, .increase, "100")])
      })

    for account in accounts {
      #expect(sheet.balances[account.id]?.amount == (try decimal("100")))
    }
    #expect(counted.countsInTotals)
    #expect(!closed.countsInTotals && !hidden.countsInTotals && !excluded.countsInTotals)
    #expect(sheet.summaries == [
      LedgerBalanceSummary(
        unitCode: "INR", assets: try decimal("100"), liabilities: try decimal("0"),
        net: try decimal("100"), accountCount: 1)
    ])
    #expect(sheet.groupTotals[group]?["INR"] == (try decimal("100")))
    // The excluded account is ungrouped, and excluded accounts add nothing to its group.
    #expect(sheet.groupTotals[nil] == nil)
  }

  @Test("liabilities net against assets and currencies never mix")
  func liabilitiesAndCurrencies() throws {
    let savings = try account("a")
    let loan = try account("b", variant: .loan)
    let card = try account("c", variant: .overdraft)
    let wallet = try account("d", unit: "USD", variant: .investment)
    let sheet = try LedgerAccountBalanceSheet(
      accounts: [savings, loan, card, wallet],
      transactions: [
        try transaction("1", kind: .income, [(savings, .increase, "10000")]),
        try transaction("2", kind: .adjustment, [(loan, .decrease, "250000")]),
        try transaction("3", kind: .expense, [(card, .decrease, "1500.25")]),
        try transaction("4", kind: .income, [(wallet, .increase, "40")]),
      ])
    #expect(sheet.summaries.map(\.unitCode) == ["INR", "USD"])
    let inr = sheet.summaries[0]
    #expect(inr.assets == (try decimal("10000")))
    #expect(inr.liabilities == (try decimal("-251500.25")))
    #expect(inr.net == (try decimal("-241500.25")))
    #expect(inr.accountCount == 3)
    #expect(sheet.summaries[1].assets == (try decimal("40")))
    #expect(sheet.groupTotals[nil]?["INR"] == (try decimal("-241500.25")))
    #expect(sheet.groupTotals[nil]?["USD"] == (try decimal("40")))
  }

  @Test("an effect in another currency is counted as a warning, not silently added")
  func foreignEffectsAreFlagged() throws {
    let cash = try account("a")
    let sheet = try LedgerAccountBalanceSheet(
      accounts: [cash],
      transactions: [try transaction("1", kind: .income, [(cash, .increase, "5")], unit: "USD")])
    #expect(sheet.balances[cash.id]?.amount == (try decimal("0")))
    #expect(sheet.foreignCurrencyEffectCount == 1)
  }

  @Test("an account with no transactions has a zero balance")
  func emptyAccount() throws {
    let cash = try account("a")
    let sheet = try LedgerAccountBalanceSheet(accounts: [cash], transactions: [])
    #expect(sheet.balances[cash.id] == (try amount("0")))
    #expect(sheet.summaries.first?.net == (try decimal("0")))
  }
}
