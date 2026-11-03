import LedgerCore
import Testing

@Suite("Net worth history closes each period with the balance sheet's rule")
struct LedgerNetWorthHistoryTests {
  let origin: LedgerOrigin

  init() throws {
    origin = try LedgerOrigin(id: String(repeating: "2", count: 64), label: "local")
  }

  private func account(
    _ key: Character, unit: String = "INR", hidden: Bool = false,
    variant: LedgerAccountVariant = .standard
  ) throws -> LedgerAccount {
    try LedgerAccount(
      id: try StableLedgerID.account(origin: origin, localKey: String(repeating: key, count: 64)),
      name: "Account \(key)", currencyUnit: unit, origin: origin, hidden: hidden, variant: variant)
  }

  private func posted(
    _ key: Character, _ account: LedgerAccount, _ direction: LedgerEffectDirection, _ literal: String,
    month: Int, day: Int = 10, lifecycle: LedgerLifecycleState = .active
  ) throws -> LedgerTransactionSnapshot {
    let when = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: month, day: day)),
      in: SourceTimeZone(fixedOffsetSeconds: 19_800), precision: .minute)
    let draft = try LedgerTransactionDraft(
      effects: [
        try LedgerTransactionEffect(
          accountID: account.id, direction: direction,
          amount: try CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal(literal)))
      ], categoryID: nil, kind: direction == .increase ? .income : .expense, occurredAt: when,
      origin: origin)
    let transactionID = try StableLedgerID.transaction(
      origin: origin, localKey: String(repeating: key, count: 64))
    let revision = try LedgerTransactionRevision(
      id: try StableLedgerID.revision(transactionID: transactionID, revision: 1),
      transactionID: transactionID, revision: 1, predecessorID: nil, draft: draft,
      lifecycle: lifecycle, createdAt: UTCInstant(epochMilliseconds: 0))
    return try LedgerTransactionSnapshot(id: transactionID, currentRevision: revision)
  }

  private func firstOf(_ month: Int) throws -> SourceLocalDate {
    try SourceLocalDate(year: 2026, month: month, day: 1)
  }

  @Test("each close counts everything dated before it, and the last matches the sheet")
  func closesReconcileToTheBalanceSheet() throws {
    let bank = try account("a")
    let card = try account("b", variant: .loan)
    let hidden = try account("c", hidden: true)
    let dollars = try account("d", unit: "USD")
    let transactions = [
      try posted("1", bank, .increase, "1000", month: 8),
      try posted("2", card, .decrease, "200", month: 9),
      try posted("3", bank, .decrease, "50.5", month: 9, day: 30),
      try posted("4", hidden, .increase, "999", month: 9),
      try posted("5", dollars, .increase, "5", month: 9),
      try posted("6", bank, .increase, "10", month: 10, lifecycle: .tombstoned),
      try posted("7", bank, .increase, "300", month: 10, day: 1),
    ]
    let accounts = [bank, card, hidden, dollars]
    let closes = try LedgerNetWorthHistory.closing(
      accounts: accounts, transactions: transactions, unitCode: "INR",
      before: [try firstOf(9), try firstOf(10), try firstOf(11)])
    #expect(closes.map(\.description) == ["1000", "749.5", "1049.5"])
    let sheet = try LedgerAccountBalanceSheet(accounts: accounts, transactions: transactions)
    #expect(sheet.summaries.first { $0.unitCode == "INR" }?.net == closes.last)
  }

  @Test("no periods, no points")
  func emptyEnds() throws {
    #expect(
      try LedgerNetWorthHistory.closing(
        accounts: [], transactions: [], unitCode: "INR", before: []
      ).isEmpty)
  }
}
