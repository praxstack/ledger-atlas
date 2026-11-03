import Foundation
import LedgerAtlasMacUI
import LedgerCore
import LedgerStore
import Testing

private let origin = try! LedgerOrigin(id: String(repeating: "6", count: 64), label: "tests")

private func key(_ seed: Character) -> String { String(repeating: seed, count: 64) }

private func entry(
  _ seed: Character, _ account: LedgerAccount, _ kind: LedgerTransactionKind, _ literal: String,
  category: LedgerCategory? = nil, year: Int = 2026, month: Int, day: Int = 10
) throws -> LedgerTransactionSnapshot {
  let transactionID = try StableLedgerID.transaction(origin: origin, localKey: key(seed))
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: year, month: month, day: day)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let draft = try LedgerTransactionDraft(
    effects: [
      LedgerTransactionEffect(
        accountID: account.id, direction: kind == .income ? .increase : .decrease,
        amount: CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal(literal)))
    ], categoryID: category?.id, kind: kind, occurredAt: when, origin: origin)
  let revision = try LedgerTransactionRevision(
    id: StableLedgerID.revision(transactionID: transactionID, revision: 1),
    transactionID: transactionID, revision: 1, predecessorID: nil, draft: draft,
    createdAt: UTCInstant(epochMilliseconds: 1))
  return try LedgerTransactionSnapshot(id: transactionID, currentRevision: revision)
}

private func fixture() throws -> LedgerStore.LedgerReadSnapshot {
  let cash = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: key("a")), name: "Cash",
    currencyUnit: "INR", origin: origin)
  let food = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: key("b")), name: "Food",
    kind: .expense, origin: origin)
  let rent = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: key("c")), name: "Rent",
    kind: .expense, origin: origin, displayOrder: 1)
  let transactions = [
    try entry("1", cash, .expense, "250", category: food, month: 11),
    try entry("2", cash, .expense, "9000", category: rent, month: 11),
    try entry("3", cash, .income, "50000", month: 11),
    try entry("4", cash, .expense, "300", category: food, month: 10),
    try entry("5", cash, .expense, "120", category: food, year: 2025, month: 6),
  ]
  return LedgerStore.LedgerReadSnapshot(
    accounts: [cash], transactions: transactions,
    revisionHistory: transactions.map(\.currentRevision), undisplayedImportedEventCount: 0,
    categories: [food, rent])
}

private let november = try! SourceLocalDate(year: 2026, month: 11, day: 15)

@Test func insightsMonthShowsTheMonthAndASixMonthTrend() throws {
  let report = try InsightsReport(
    snapshot: fixture(), kind: .month, containing: november, unitCode: nil,
    rule: LedgerPeriodRule())
  #expect(report.unitCode == "INR")
  #expect(report.period.start == (try SourceLocalDate(year: 2026, month: 11, day: 1)))
  #expect(report.statistics.expense == (try ExactDecimal("9250")))
  #expect(report.statistics.income == (try ExactDecimal("50000")))
  #expect(report.statistics.expenseCategories.map(\.name) == ["Food", "Rent"])
  #expect(report.trend.count == 6)
  #expect(report.trend.first?.period.start == (try SourceLocalDate(year: 2026, month: 6, day: 1)))
  #expect(report.trend.last?.expense == report.statistics.expense)
  #expect(report.trend[4].expense == (try ExactDecimal("300")))
  #expect(report.title(LedgerDisplayFormatter(locale: Locale(identifier: "en_US"))) == "November 2026")
}

@Test func insightsYearAddsUpTheMonthsAndStepsByYear() throws {
  let rule = LedgerPeriodRule()
  let report = try InsightsReport(
    snapshot: fixture(), kind: .year, containing: november, unitCode: nil, rule: rule)
  #expect(report.statistics.expense == (try ExactDecimal("9550")))
  #expect(report.trend.count == 5)
  #expect(report.trend[3].expense == (try ExactDecimal("120")))
  #expect(report.title(LedgerDisplayFormatter(locale: Locale(identifier: "en_US"))) == "2026")
  let previous = try InsightsReport.date(november, movedBy: -1, .year, rule: rule)
  #expect(previous == (try SourceLocalDate(year: 2025, month: 1, day: 1)))
}

@Test func insightsMonthFollowsTheLedgersMonthStartDay() throws {
  let rule = LedgerPeriodRule(monthStartDay: 25)
  let period = try InsightsReport.period(.month, containing: november, rule: rule)
  #expect(period.start == (try SourceLocalDate(year: 2026, month: 10, day: 25)))
  #expect(period.end == (try SourceLocalDate(year: 2026, month: 11, day: 25)))
  let next = try InsightsReport.date(november, movedBy: 1, .month, rule: rule)
  #expect(next == (try SourceLocalDate(year: 2026, month: 11, day: 25)))
}

@Test func periodStatementCanHideCategoryNamesAndSaysItIsNotARecord() throws {
  let report = try InsightsReport(
    snapshot: fixture(), kind: .month, containing: november, unitCode: nil,
    rule: LedgerPeriodRule())
  let shown = report.statementLines(redactingNames: false, title: "November 2026")
  #expect(shown.contains("  Food: 250 (1)"))
  #expect(shown.contains("Expense: 9250 INR (2)"))
  #expect(shown.contains("Snapshot \(report.statistics.snapshotDigest)"))

  let hidden = report.statementLines(redactingNames: true, title: "November 2026")
  #expect(!hidden.joined(separator: "\n").contains("Food"))
  #expect(!hidden.joined(separator: "\n").contains("Rent"))
  #expect(hidden.contains("  Category 1: 250 (1)"))
  #expect(hidden.contains("  Category 2: 9000 (1)"))
  // Hiding names never changes a figure.
  #expect(hidden.filter { $0.hasPrefix("Income") || $0.hasPrefix("Expense:") || $0.hasPrefix("Net") }
    == shown.filter { $0.hasPrefix("Income") || $0.hasPrefix("Expense:") || $0.hasPrefix("Net") })
  #expect(hidden.contains { $0.contains("not a record") })

  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "ledger-atlas-period-\(UUID().uuidString).pdf")
  defer { try? FileManager.default.removeItem(at: url) }
  try LedgerPDFStatementExporter.export(lines: hidden, to: url)
  #expect(try Data(contentsOf: url).starts(with: Data("%PDF".utf8)))
}
