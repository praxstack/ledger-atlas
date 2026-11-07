import Foundation
import LedgerCore
import Testing

@Suite("Upcoming (#171)")
struct LedgerUpcomingTests {
  private static let origin = try! LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  private static let cash = String(repeating: "a", count: 64)
  private static let bank = String(repeating: "b", count: 64)

  private static func date(_ year: Int, _ month: Int, _ day: Int) throws -> SourceLocalDate {
    try SourceLocalDate(year: year, month: month, day: day)
  }

  private static func rule(
    _ seed: Character, _ frequency: LedgerRecurrenceFrequency, start: SourceLocalDate,
    kind: LedgerTransactionKind = .expense, amount: String = "10", unit: String = "INR",
    dayOfMonth: Int? = nil, until: SourceLocalDate? = nil, paused: Bool = false,
    skipped: [SourceLocalDate] = [], lifecycle: LedgerLifecycleState = .active,
    zone: SourceTimeZone = try! SourceTimeZone(fixedOffsetSeconds: 19_800)
  ) throws -> LedgerRecurrenceRule {
    try LedgerRecurrenceRule(
      id: String(repeating: seed, count: 64), origin: origin, accountID: cash, categoryID: nil,
      kind: kind, amount: CurrencyAmount(unitCode: unit, amount: ExactDecimal(amount)),
      frequency: frequency, interval: 1, dayOfMonth: dayOfMonth, timeZone: zone, start: start,
      until: until, paused: paused, skippedDates: skipped, lifecycle: lifecycle)
  }

  /// A synthetic entry on `day`, carrying the literals a generated occurrence or installment
  /// payment carries.
  private static func entry(
    _ n: Int, on day: SourceLocalDate, amount: String = "10", literals: [(String, String)],
    lifecycle: LedgerLifecycleState = .active
  ) throws -> LedgerTransactionSnapshot {
    let transactionID = try StableLedgerID.transaction(
      origin: origin, localKey: String(format: "%064x", n))
    let draft = try LedgerTransactionDraft(
      effects: [
        try .init(
          accountID: bank, direction: .decrease,
          amount: CurrencyAmount(unitCode: "INR", amount: ExactDecimal(amount)))
      ], categoryID: nil, kind: .expense,
      occurredAt: SourceTemporal(startOf: day, in: SourceTimeZone(fixedOffsetSeconds: 19_800)),
      sourceLiterals: literals.map { try LedgerSourceLiteral(field: $0.0, literal: $0.1) },
      origin: origin)
    let revision = try LedgerTransactionRevision(
      id: StableLedgerID.revision(transactionID: transactionID, revision: 1),
      transactionID: transactionID, revision: 1, predecessorID: nil, draft: draft,
      lifecycle: lifecycle, createdAt: UTCInstant(epochMilliseconds: 0))
    return try LedgerTransactionSnapshot(id: transactionID, currentRevision: revision)
  }

  private static func plan(
    _ seed: Character, lifecycle: LedgerInstallmentPlan.Lifecycle = .active
  ) throws -> LedgerInstallmentPlan {
    try LedgerInstallmentPlan(
      id: String(repeating: seed, count: 64), origin: origin, accountID: bank, categoryID: nil,
      principal: CurrencyAmount(unitCode: "INR", amount: ExactDecimal("300")),
      occurrenceCount: 3, lifecycle: lifecycle)
  }

  private static func text(_ date: SourceLocalDate) -> String {
    String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
  }

  @Test("a month-end rule lands on the last day of short months inside the window")
  func monthEnd() throws {
    let rule = try Self.rule("2", .monthly, start: Self.date(2026, 1, 31))
    let upcoming = LedgerUpcoming(
      rules: [rule], installmentPlans: [], transactions: [], today: try Self.date(2026, 2, 20),
      days: 45, lookBackDays: 0)
    let dates = upcoming.items.map { Self.text($0.date) }
    #expect(dates == ["2026-02-28", "2026-03-31"])
    let leap = LedgerUpcoming(
      rules: [rule], installmentPlans: [], transactions: [], today: try Self.date(2028, 2, 1),
      lookBackDays: 0)
    let leapDates = leap.items.map { Self.text($0.date) }
    #expect(leapDates == ["2028-02-29"])
  }

  @Test("dates are calendar days, so a daylight-saving change neither skips nor repeats one")
  func daylightSaving() throws {
    let newYork = try SourceTimeZone(ianaIdentifier: "America/New_York")
    let rule = try Self.rule("3", .daily, start: Self.date(2026, 3, 6), zone: newYork)
    let upcoming = LedgerUpcoming(
      rules: [rule], installmentPlans: [], transactions: [], today: try Self.date(2026, 3, 6),
      days: 5, lookBackDays: 0)
    let dates = upcoming.items.map { Self.text($0.date) }
    #expect(dates == ["2026-03-06", "2026-03-07", "2026-03-08", "2026-03-09", "2026-03-10"])
    let autumn = LedgerUpcoming(
      rules: [rule], installmentPlans: [], transactions: [], today: try Self.date(2026, 10, 31),
      days: 3, lookBackDays: 0)
    let autumnDates = autumn.items.map { Self.text($0.date) }
    #expect(autumnDates == ["2026-10-31", "2026-11-01", "2026-11-02"])
  }

  @Test("nothing due gives an empty list with no totals")
  func emptyWindow() throws {
    let ended = try Self.rule("4", .weekly, start: Self.date(2025, 1, 1), until: Self.date(2025, 6, 1))
    let paused = try Self.rule("5", .daily, start: Self.date(2026, 1, 1), paused: true)
    let closed = try Self.rule("6", .daily, start: Self.date(2026, 1, 1), lifecycle: .tombstoned)
    let later = try Self.rule("7", .yearly, start: Self.date(2027, 1, 1))
    let upcoming = LedgerUpcoming(
      rules: [ended, paused, closed, later], installmentPlans: [], transactions: [],
      today: try Self.date(2026, 3, 1))
    #expect(upcoming.isEmpty)
    #expect(upcoming.totals.isEmpty)
    #expect(upcoming.overdueCount == 0)
    // The ended rule's 22 weekly dates in 2025 were never entered: older than the look-back,
    // so they are counted, not listed.
    #expect(upcoming.olderOverdueCount == 22)
  }

  @Test("overdue dates not yet entered come first, oldest first; entered and skipped ones drop out")
  func overdueOrdering() throws {
    let today = try Self.date(2026, 3, 10)
    let weekly = try Self.rule(
      "8", .weekly, start: Self.date(2026, 2, 17), skipped: [Self.date(2026, 3, 17)])
    let monthly = try Self.rule("9", .monthly, start: Self.date(2026, 3, 5), kind: .income,
      amount: "5000")
    // The weekly rule was entered on 24 Feb; 17 Feb was entered then closed, so it is still due.
    let transactions = [
      try Self.entry(1, on: Self.date(2026, 2, 24), literals: [("recurrence.ruleID", weekly.id)]),
      try Self.entry(
        2, on: Self.date(2026, 2, 17), literals: [("recurrence.ruleID", weekly.id)],
        lifecycle: .tombstoned),
    ]
    let upcoming = LedgerUpcoming(
      rules: [weekly, monthly], installmentPlans: [], transactions: transactions, today: today,
      days: 14)
    let listed = upcoming.items.map { "\(Self.text($0.date)) \($0.isOverdue ? "overdue" : "due")" }
    #expect(
      listed == [
        "2026-02-17 overdue", "2026-03-03 overdue", "2026-03-05 overdue", "2026-03-10 due",
      ])
    #expect(upcoming.overdueCount == 3)
    let dayCount = upcoming.days.count
    #expect(dayCount == 4)
    let total = try #require(upcoming.totals.first)
    let income = try ExactDecimal("5000")
    let expense = try ExactDecimal("30")
    #expect(upcoming.totals.count == 1)
    #expect(total.unitCode == "INR")
    #expect(total.income == income)
    #expect(total.expense == expense)
  }

  @Test("overdue dates older than the look-back are counted, not listed")
  func lookBack() throws {
    let daily = try Self.rule("a", .daily, start: Self.date(2026, 1, 1))
    let upcoming = LedgerUpcoming(
      rules: [daily], installmentPlans: [], transactions: [], today: try Self.date(2026, 3, 1),
      days: 1, lookBackDays: 3)
    let dates = upcoming.items.map { Self.text($0.date) }
    #expect(dates == ["2026-02-26", "2026-02-27", "2026-02-28", "2026-03-01"])
    #expect(upcoming.olderOverdueCount == 56)
  }

  @Test("installment payments in the window are listed; past, closed and cancelled ones are not")
  func installments() throws {
    let active = try Self.plan("c")
    let cancelled = try Self.plan("d", lifecycle: .cancelled)
    let transactions = [
      try Self.entry(
        10, on: Self.date(2026, 2, 15), literals: [("installment.planID", active.id)]),
      try Self.entry(
        11, on: Self.date(2026, 3, 15), literals: [("installment.planID", active.id)]),
      try Self.entry(
        12, on: Self.date(2026, 4, 15), literals: [("installment.planID", active.id)]),
      try Self.entry(
        13, on: Self.date(2026, 3, 16), literals: [("installment.planID", active.id)],
        lifecycle: .tombstoned),
      try Self.entry(
        14, on: Self.date(2026, 3, 20), literals: [("installment.planID", cancelled.id)]),
    ]
    let upcoming = LedgerUpcoming(
      rules: [], installmentPlans: [active, cancelled], transactions: transactions,
      today: try Self.date(2026, 3, 1))
    #expect(upcoming.items.count == 1)
    let item = try #require(upcoming.items.first)
    #expect(Self.text(item.date) == "2026-03-15")
    #expect(item.source == .installment(planID: active.id, transactionID: transactions[1].id))
    #expect(!item.isOverdue)
    #expect(item.accountID == Self.bank)
  }
}
