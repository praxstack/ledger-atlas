import Foundation
import LedgerCore
import Testing

@Suite("Budget evaluation")
struct LedgerBudgetEvaluationTests {
  private static let origin = try! LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  private static let account = String(repeating: "a", count: 64)
  private static let food = String(repeating: "c", count: 64)
  private static let fuel = String(repeating: "d", count: 64)

  private static func date(_ year: Int, _ month: Int, _ day: Int) throws -> SourceLocalDate {
    try SourceLocalDate(year: year, month: month, day: day)
  }

  private static func spend(
    _ n: Int, _ amount: String, on day: SourceLocalDate, category: String = food,
    unit: String = "USD", kind: LedgerTransactionKind = .expense,
    lifecycle: LedgerLifecycleState = .active
  ) throws -> LedgerTransactionSnapshot {
    let transactionID = try StableLedgerID.transaction(
      origin: origin, localKey: String(format: "%064x", n))
    let money = try CurrencyAmount(unitCode: unit, amount: ExactDecimal(amount))
    let draft = try LedgerTransactionDraft(
      effects: [
        try .init(
          accountID: account, direction: kind == .income ? .increase : .decrease, amount: money)
      ], categoryID: category, kind: kind,
      occurredAt: SourceTemporal(startOf: day, in: SourceTimeZone(fixedOffsetSeconds: 0)),
      origin: origin)
    return try LedgerTransactionSnapshot(
      id: transactionID,
      currentRevision: LedgerTransactionRevision(
        id: StableLedgerID.revision(transactionID: transactionID, revision: 1),
        transactionID: transactionID, revision: 1, predecessorID: nil, draft: draft,
        lifecycle: lifecycle, createdAt: UTCInstant(epochMilliseconds: 0)))
  }

  private static func budget(
    _ amount: String = "100", period: LedgerBudget.Period = .monthly, rollover: Bool = false,
    start: SourceLocalDate, lifecycle: LedgerLifecycleState = .active
  ) throws -> LedgerBudget {
    try LedgerBudget(
      id: String(repeating: "b", count: 64), origin: origin, name: "Food", categoryID: food,
      amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal(amount)), period: period,
      rollover: rollover, start: start, lifecycle: lifecycle)
  }

  @Test("spending counts only active expenses in the category, currency and period")
  func countsTheRightSpending() throws {
    let transactions = [
      try Self.spend(1, "10.50", on: Self.date(2026, 3, 1)),
      try Self.spend(2, "4.25", on: Self.date(2026, 3, 31)),
      try Self.spend(3, "99", on: Self.date(2026, 2, 28)),  // previous period
      try Self.spend(4, "7", on: Self.date(2026, 3, 5), category: Self.fuel),
      try Self.spend(5, "8", on: Self.date(2026, 3, 6), unit: "EUR"),
      try Self.spend(6, "9", on: Self.date(2026, 3, 7), lifecycle: .tombstoned),
      try Self.spend(7, "50", on: Self.date(2026, 3, 8), kind: .income),
    ]
    let status = try #require(
      try Self.budget(start: Self.date(2026, 1, 1))
        .status(on: Self.date(2026, 3, 15), transactions: transactions))
    #expect(status.periodStart == (try Self.date(2026, 3, 1)))
    #expect(status.periodEnd == (try Self.date(2026, 3, 31)))
    #expect(status.spent.rawLiteral == "14.75")
    #expect(status.carried.rawLiteral == "0")
    #expect(status.remaining.rawLiteral == "85.25")
    #expect(!status.isOverBudget)
  }

  @Test("rollover carries unused amounts forward but not overspending (LA-032)")
  func rolloverCarriesUnused() throws {
    let transactions = [
      try Self.spend(1, "60", on: Self.date(2026, 1, 10)),  // 40 unused
      try Self.spend(2, "150", on: Self.date(2026, 2, 10)),  // 140 available, 10 over
      try Self.spend(3, "30", on: Self.date(2026, 3, 10)),
    ]
    let withRollover = try Self.budget(rollover: true, start: Self.date(2026, 1, 1))
    let february = try #require(
      try withRollover.status(on: Self.date(2026, 2, 20), transactions: transactions))
    #expect(february.carried.rawLiteral == "40")
    #expect(february.available.rawLiteral == "140")
    #expect(february.remaining.rawLiteral == "-10")
    #expect(february.isOverBudget)
    #expect(february.overspent?.rawLiteral == "10")
    let march = try #require(
      try withRollover.status(on: Self.date(2026, 3, 20), transactions: transactions))
    #expect(march.carried.rawLiteral == "0")
    #expect(march.remaining.rawLiteral == "70")
    let plain = try #require(
      try Self.budget(start: Self.date(2026, 1, 1))
        .status(on: Self.date(2026, 2, 20), transactions: transactions))
    #expect(plain.carried.rawLiteral == "0")
    #expect(plain.remaining.rawLiteral == "-50")
  }

  @Test("periods start on the budget's start date")
  func periodsFollowTheStartDate() throws {
    let midMonth = try #require(
      try Self.budget(start: Self.date(2026, 1, 15))
        .status(on: Self.date(2026, 3, 2), transactions: []))
    #expect(midMonth.periodStart == (try Self.date(2026, 2, 15)))
    #expect(midMonth.periodEnd == (try Self.date(2026, 3, 14)))
    let monthEnd = try #require(
      try Self.budget(start: Self.date(2026, 1, 31))
        .status(on: Self.date(2026, 3, 1), transactions: []))
    #expect(monthEnd.periodStart == (try Self.date(2026, 2, 28)))
    #expect(monthEnd.periodEnd == (try Self.date(2026, 3, 30)))
    let yearly = try #require(
      try Self.budget(period: .yearly, start: Self.date(2025, 4, 1))
        .status(on: Self.date(2026, 3, 31), transactions: []))
    #expect(yearly.periodStart == (try Self.date(2025, 4, 1)))
    #expect(yearly.periodEnd == (try Self.date(2026, 3, 31)))
  }

  @Test("no status before the start or once closed")
  func inactiveBudgets() throws {
    #expect(
      try Self.budget(start: Self.date(2026, 5, 1))
        .status(on: Self.date(2026, 4, 30), transactions: []) == nil)
    #expect(
      try Self.budget(start: Self.date(2026, 1, 1), lifecycle: .tombstoned)
        .status(on: Self.date(2026, 4, 30), transactions: []) == nil)
  }
}
