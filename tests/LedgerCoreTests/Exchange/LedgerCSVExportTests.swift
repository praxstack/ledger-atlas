import Foundation
import Testing

@testable import LedgerCore

@Suite("Ledger view CSV export")
struct LedgerCSVExportTests {
  private static let origin = try! LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  private static let cash = String(repeating: "a", count: 64)
  private static let bank = String(repeating: "b", count: 64)
  private static let food = String(repeating: "c", count: 64)
  private static let groceries = String(repeating: "d", count: 64)
  private static let salary = String(repeating: "e", count: 64)
  private static let household = String(repeating: "f", count: 64)
  private static let shared = String(repeating: "7", count: 64)
  private static let trip = String(repeating: "8", count: 64)

  private static func id(_ n: Int) throws -> String {
    try StableLedgerID.transaction(origin: origin, localKey: String(format: "%064x", n))
  }

  /// Synthetic entry `n`, with no real data.
  private static func transaction(
    _ n: Int, day: Int, hour: Int = 9, minute: Int = 0,
    precision: SourceTemporalPrecision = .minute, kind: LedgerTransactionKind = .expense,
    amount: String, unit: String = "INR", note: String? = nil, account: String = cash,
    to destination: String = bank, received: String? = nil, category: String? = food,
    lifecycle: LedgerLifecycleState = .active, links: [LedgerTransactionLink] = []
  ) throws -> LedgerTransactionSnapshot {
    let transactionID = try id(n)
    let money = try CurrencyAmount(unitCode: unit, amount: ExactDecimal(amount))
    let effects: [LedgerTransactionEffect]
    switch kind {
    case .income:
      effects = [try .init(accountID: account, direction: .increase, amount: money)]
    case .expense, .adjustment:
      effects = [try .init(accountID: account, direction: .decrease, amount: money)]
    case .transfer:
      let arrived = try received.map { try CurrencyAmount(unitCode: "INR", amount: ExactDecimal($0)) }
      effects = [
        try .init(accountID: account, direction: .decrease, amount: money),
        try .init(accountID: destination, direction: .increase, amount: arrived ?? money),
      ]
    }
    let when = try SourceTemporal(
      resolving: SourceLocalDateTime(
        date: SourceLocalDate(year: 2026, month: 3, day: day), hour: hour, minute: minute),
      in: SourceTimeZone(fixedOffsetSeconds: 19_800), precision: precision)
    let draft = try LedgerTransactionDraft(
      effects: effects, categoryID: kind == .transfer ? nil : category, kind: kind,
      occurredAt: when, note: note, origin: origin)
    let revision = try LedgerTransactionRevision(
      id: StableLedgerID.revision(transactionID: transactionID, revision: 1),
      transactionID: transactionID, revision: 1, predecessorID: nil, draft: draft,
      lifecycle: lifecycle, createdAt: UTCInstant(epochMilliseconds: 0))
    return try LedgerTransactionSnapshot(id: transactionID, currentRevision: revision, links: links)
  }

  private static func category(
    _ id: String, _ name: String, _ kind: LedgerCategoryKind, parent: String? = nil
  ) throws -> LedgerCategory {
    try LedgerCategory(id: id, name: name, kind: kind, origin: origin, parentID: parent)
  }

  private static let names = try! LedgerCSVExport.Names(
    accounts: [cash: "Cash, wallet", bank: "Bank"],
    categories: [
      category(food, "Food", .expense), category(groceries, "Groceries", .expense, parent: food),
      category(household, "Household", .expense), category(salary, "Salary", .income),
    ],
    tags: [shared: "👥 shared", trip: "trip"])

  /// Splits, a transfer, a cross-currency transfer, tags, a closed entry, a day-precision
  /// entry and memos a spreadsheet would misread.
  private static func ledger() throws -> (
    transactions: [LedgerTransactionSnapshot], tags: [String: LedgerTagLinks]
  ) {
    let splitLink = try LedgerTransactionLink(
      id: StableLedgerID.link(fromTransactionID: id(1), toTransactionID: id(2), kind: .split),
      fromTransactionID: id(1), toTransactionID: id(2), kind: .split)
    let transactions = [
      try transaction(
        1, day: 2, hour: 18, amount: "1200.50", note: "Big shop", category: groceries,
        links: [splitLink]),
      try transaction(
        2, day: 2, hour: 18, amount: "300", note: "Big shop", category: household,
        links: [splitLink]),
      try transaction(3, day: 2, hour: 10, kind: .transfer, amount: "5000.00"),
      try transaction(
        4, day: 1, hour: 0, precision: .day, kind: .income, amount: "85000", account: bank,
        category: salary),
      try transaction(5, day: 3, amount: ".5", note: "=HYPERLINK(\"http://x\")"),
      try transaction(6, day: 3, hour: 11, amount: "40", note: "-2+3, \"quoted\"\nsecond line"),
      try transaction(7, day: 3, hour: 12, amount: "99", note: "@SUM(A1)", lifecycle: .tombstoned),
      try transaction(
        8, day: 4, kind: .transfer, amount: "12.00", unit: "USD", account: bank, to: cash,
        received: "1000.00"),
    ]
    var tags: [String: LedgerTagLinks] = [:]
    tags[transactions[0].currentRevision.id] = try LedgerTagLinks([shared, trip])
    tags[transactions[2].currentRevision.id] = try LedgerTagLinks([trip])
    return (transactions, tags)
  }

  private static func golden() throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/ledger-view.csv")
    return try Data(contentsOf: url)
  }

  @Test("the daily view exports the same rows in the same order as the golden file")
  func dailyViewMatchesGoldenFile() throws {
    let (transactions, tags) = try Self.ledger()
    let browser = LedgerBrowser(transactions: transactions, revisionTags: tags)
    let byID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
    let shown = browser.matches(mode: .daily, filter: .init()).map { byID[browser.entries[$0].id]! }
    let data = LedgerCSVExport.data(shown, names: Self.names, revisionTags: tags)
    let golden = try? Self.golden()
    if data != golden {
      // Shows the difference in the test log; the golden file is only changed by hand.
      Issue.record("CSV differs from the golden file:\n\(String(decoding: data, as: UTF8.self))")
    }
  }

  @Test("the file is UTF-8 with a byte-order mark and CRLF line ends")
  func encodingAndLineEnds() throws {
    let (transactions, tags) = try Self.ledger()
    let data = LedgerCSVExport.data(transactions, names: Self.names, revisionTags: tags)
    #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
    let text = String(decoding: data.dropFirst(3), as: UTF8.self)
    #expect(text.hasPrefix(LedgerCSVExport.header.joined(separator: ",") + "\r\n"))
    #expect(text.hasSuffix("\r\n"))
  }

  @Test("a filter narrows the export to the rows on screen")
  func filterNarrowsRows() throws {
    let (transactions, tags) = try Self.ledger()
    let browser = LedgerBrowser(transactions: transactions, revisionTags: tags)
    let byID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
    let filter = LedgerBrowseFilter(tagID: Self.trip)
    let shown = browser.matches(mode: .daily, filter: filter).map { byID[browser.entries[$0].id]! }
    let rows = LedgerCSVExport.rows(shown, names: Self.names, revisionTags: tags)
    let ids = rows.map { $0[10] }
    let tagCells = rows.map { $0[7] }
    let expectedIDs = [try Self.id(1), try Self.id(3)]
    #expect(ids == expectedIDs)
    #expect(tagCells == ["👥 shared; trip", "trip"])
  }

  @Test("cells a spreadsheet would run as formulas get a leading quote; amounts stay numbers")
  func formulaCellsAreNeutralized() {
    for start in ["=1+1", "+1", "-1", "@A1", "\tx", "\rx"] {
      #expect(LedgerCSVExport.neutralized(start) == "'" + start)
    }
    #expect(LedgerCSVExport.neutralized("Coffee") == "Coffee")
    #expect(LedgerCSVExport.neutralized("") == "")
    let row = LedgerCSVExport.line(
      ["2026-03-01", "-Cash", "expense", "", "-12.50", "INR", "=1", "", "", "active", "x"],
      amountColumn: 4)
    #expect(row == "2026-03-01,'-Cash,expense,,-12.50,INR,'=1,,,active,x\r\n")
  }

  @Test("amounts keep their exact digits with no grouping and a plain minus")
  func amountsAreExact() throws {
    let big = try ExactDecimal("1234567.890")
    let bare = try ExactDecimal("+.5")
    let trailing = try ExactDecimal("7.")
    let tiny = try ExactDecimal("0.000000000000000000000000001")
    #expect(LedgerCSVExport.amount(big, leaving: true) == "-1234567.890")
    #expect(LedgerCSVExport.amount(bare, leaving: false) == "0.5")
    #expect(LedgerCSVExport.amount(trailing, leaving: false) == "7")
    #expect(LedgerCSVExport.amount(tiny, leaving: false) == "0.000000000000000000000000001")
  }
}
