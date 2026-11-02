import Foundation
import Testing

@testable import LedgerCore

private let origin = try! LedgerOrigin(id: String(repeating: "3", count: 64), label: "synthetic")
private let imported = try! LedgerOrigin(
  id: String(repeating: "4", count: 64), label: "money-manager",
  provenanceID: String(repeating: "5", count: 64))

private func key(_ seed: String) -> String {
  let hex = seed.unicodeScalars.map { String(format: "%02x", $0.value) }.joined()
  return String((hex + String(repeating: "0", count: 64)).prefix(64))
}

private func when(
  _ day: Int, hour: Int = 0, minute: Int = 0, zone: SourceTimeZone,
  precision: SourceTemporalPrecision = .minute
) throws -> SourceTemporal {
  try SourceTemporal(
    resolving: SourceLocalDateTime(
      date: SourceLocalDate(year: 2026, month: 3, day: day), hour: hour, minute: minute),
    in: zone, precision: precision)
}

private func money(_ literal: String, _ unit: String = "INR") throws -> CurrencyAmount {
  try CurrencyAmount(unitCode: unit, amount: ExactDecimal(literal))
}

/// Every record type, both lifecycles, two currencies, an IANA zone and a fixed offset,
/// awkward text, tags and source literals.
private func sampleContent() throws -> LedgerXLSXExchange.Content {
  let kolkata = try SourceTimeZone(ianaIdentifier: "Asia/Kolkata")
  let fixed = try SourceTimeZone(fixedOffsetSeconds: -18_000)
  let group = try LedgerAccountGroup(id: key("group"), name: "Everyday", displayOrder: 1)
  let cash = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: key("cash")), name: "Cash & coins",
    currencyUnit: "INR", origin: origin, groupID: group.id)
  let bank = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: key("bank")), name: "Bank",
    currencyUnit: "INR", origin: imported, displayOrder: 2, includeInTotals: false,
    variant: .overdraft)
  let travel = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: key("travel")), name: "Travel card",
    currencyUnit: "USD", origin: origin, lifecycle: .tombstoned, hidden: true)
  let food = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: key("food")), name: "Food",
    kind: .expense, origin: origin)
  let cafes = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: key("cafes")), name: "Cafés",
    kind: .expense, origin: origin, parentID: food.id, displayOrder: 3, hidden: true)
  let salary = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: key("salary")), name: "Salary",
    kind: .income, origin: imported, lifecycle: .tombstoned)
  let shared = try LedgerTag(
    id: StableLedgerID.tag(origin: origin, localKey: key("shared")), name: "👥 shared",
    origin: origin)
  let trip = try LedgerTag(
    id: StableLedgerID.tag(origin: origin, localKey: key("trip")), name: "trip", origin: origin,
    lifecycle: .tombstoned)

  func transaction(
    _ seed: String, _ draft: LedgerTransactionDraft, lifecycle: LedgerLifecycleState = .active,
    tags: [String] = []
  ) throws -> LedgerXLSXExchange.Transaction {
    LedgerXLSXExchange.Transaction(
      id: try StableLedgerID.transaction(origin: origin, localKey: key(seed)), draft: draft,
      lifecycle: lifecycle, tags: try LedgerTagLinks(tags))
  }
  let transactions = [
    try transaction(
      "pay",
      LedgerTransactionDraft(
        effects: [LedgerTransactionEffect(accountID: bank.id, direction: .increase, amount: money("50000.00"))],
        categoryID: salary.id, kind: .income, occurredAt: when(1, zone: kolkata, precision: .day),
        origin: imported)),
    try transaction(
      "coffee",
      LedgerTransactionDraft(
        effects: [LedgerTransactionEffect(accountID: cash.id, direction: .decrease, amount: money("180.50"))],
        categoryID: cafes.id, kind: .expense, occurredAt: when(2, hour: 9, minute: 30, zone: kolkata),
        note: "Line one\nline two, with \"quotes\" & <tags>", roundingPolicy: .halfEven,
        sourceLiterals: [
          LedgerSourceLiteral(field: "ZMONEY", literal: "180.5"),
          LedgerSourceLiteral(field: "ZCONTENT", literal: "  padded _x0041_ ", provenanceID: String(repeating: "6", count: 64)),
        ], origin: origin),
      tags: [shared.id, trip.id]),
    try transaction(
      "move",
      LedgerTransactionDraft(
        effects: [
          LedgerTransactionEffect(accountID: bank.id, direction: .decrease, amount: money("1000")),
          LedgerTransactionEffect(accountID: cash.id, direction: .increase, amount: money("1000")),
        ], categoryID: nil, kind: .transfer, occurredAt: when(3, hour: 23, minute: 59, zone: fixed),
        origin: origin)),
    try transaction(
      "fix",
      LedgerTransactionDraft(
        effects: [LedgerTransactionEffect(accountID: travel.id, direction: .decrease, amount: money("0.01", "USD"))],
        categoryID: nil, kind: .adjustment, occurredAt: when(4, zone: fixed, precision: .day),
        origin: origin),
      lifecycle: .tombstoned),
  ]
  return LedgerXLSXExchange.Content(
    accountGroups: [group], accounts: [cash, bank, travel], categories: [food, cafes, salary],
    tags: [shared, trip], transactions: transactions)
}

private func sorted(_ content: LedgerXLSXExchange.Content) -> LedgerXLSXExchange.Content {
  LedgerXLSXExchange.Content(
    accountGroups: content.accountGroups.sorted { $0.id < $1.id },
    accounts: content.accounts.sorted { $0.id < $1.id },
    categories: content.categories.sorted { $0.id < $1.id },
    tags: content.tags.sorted { $0.id < $1.id },
    transactions: content.transactions.sorted { $0.id < $1.id })
}

/// Replaces one cell, found by sheet, header name and record row (1 = first record).
private func editing(
  _ workbook: XLSXWorkbook, sheet: String, row: Int, column: String, to value: String
) -> XLSXWorkbook {
  var copy = workbook
  let sheetIndex = copy.sheets.firstIndex { $0.name == sheet }!
  let columnIndex = copy.sheets[sheetIndex].rows[0].firstIndex(of: column)!
  var cells = copy.sheets[sheetIndex].rows[row]
  while cells.count <= columnIndex { cells.append("") }
  cells[columnIndex] = value
  copy.sheets[sheetIndex].rows[row] = cells
  return copy
}

private func issues(_ workbook: XLSXWorkbook) -> [LedgerXLSXExchange.Issue] {
  do {
    _ = try LedgerXLSXExchange.content(from: workbook)
    return []
  } catch LedgerXLSXExchange.Error.invalid(let issues) {
    return issues
  } catch {
    Issue.record("unexpected \(error)")
    return []
  }
}

@Test func xlsxExchangeRoundTripsEveryRecordExactly() throws {
  let content = try sampleContent()
  let data = try LedgerXLSXExchange.xlsxData(content)
  #expect(try LedgerXLSXExchange.xlsxData(content) == data)
  let read = try LedgerXLSXExchange.content(fromXLSX: data)
  #expect(sorted(read) == sorted(content))
}

@Test func xlsxExchangeWritesReadableSheets() throws {
  let workbook = LedgerXLSXExchange.workbook(try sampleContent())
  #expect(
    workbook.sheets.map(\.name) == [
      "About", "Account groups", "Accounts", "Categories", "Tags", "Transactions", "Effects",
      "Source literals",
    ])
  let transactions = try #require(workbook.sheet(named: "Transactions"))
  let header = transactions.rows[0]
  let coffee = try #require(transactions.rows.first { $0.contains("expense") })
  #expect(coffee[header.firstIndex(of: "local_date_time")!] == "2026-03-02 09:30:00.000")
  #expect(coffee[header.firstIndex(of: "time_zone")!] == "Asia/Kolkata")
  #expect(coffee[header.firstIndex(of: "utc_offset_seconds")!] == "19800")
  let effects = try #require(workbook.sheet(named: "Effects"))
  #expect(effects.rows.count == 1 + 5)
  #expect(effects.rows.contains { $0.contains("180.50") && $0.contains("decrease") })
}

@Test func editedLocalTimeIsResolvedAgainInItsTimeZone() throws {
  let workbook = LedgerXLSXExchange.workbook(try sampleContent())
  let row = workbook.sheet(named: "Transactions")!.rows.firstIndex { $0.contains("expense") }!
  let edited = editing(
    workbook, sheet: "Transactions", row: row, column: "local_date_time", to: "2026-03-05 18:15")
  let coffee = try #require(
    LedgerXLSXExchange.content(from: edited).transactions.first { $0.draft.kind == .expense })
  let expected = try when(5, hour: 18, minute: 15, zone: SourceTimeZone(ianaIdentifier: "Asia/Kolkata"))
  #expect(coffee.draft.occurredAt == expected)
}

@Test func importReportsEveryProblemWithItsPlace() throws {
  var workbook = LedgerXLSXExchange.workbook(try sampleContent())
  let transactions = workbook.sheet(named: "Transactions")!.rows
  let coffeeRow = transactions.firstIndex { $0.contains("expense") }!
  let payRow = transactions.firstIndex { $0.contains("income") }!
  workbook = editing(workbook, sheet: "Effects", row: 1, column: "account_id", to: key("nobody"))
  workbook = editing(workbook, sheet: "Transactions", row: coffeeRow, column: "kind", to: "spend")
  workbook = editing(workbook, sheet: "Transactions", row: payRow, column: "local_date_time", to: "2026-02-30")
  workbook = editing(workbook, sheet: "Accounts", row: 1, column: "hidden", to: "maybe")
  workbook = editing(workbook, sheet: "Tags", row: 2, column: "id", to: "")
  let found = issues(workbook)
  #expect(found.contains { $0.sheet == "Effects" && $0.row == 2 && $0.column == "account_id" })
  #expect(found.contains { $0.sheet == "Transactions" && $0.row == coffeeRow + 1 && $0.column == "kind" })
  #expect(
    found.contains {
      $0.sheet == "Transactions" && $0.row == payRow + 1 && $0.column == "local_date_time"
    })
  #expect(found.contains { $0.sheet == "Accounts" && $0.row == 2 && $0.column == "hidden" })
  #expect(found.contains { $0.sheet == "Tags" && $0.row == 3 && $0.column == "id" })
  #expect(found.allSatisfy { !$0.description.isEmpty })
}

@Test func importRefusesForeignOrChangedWorkbooks() throws {
  let workbook = LedgerXLSXExchange.workbook(try sampleContent())

  var newer = workbook
  newer.sheets[0].rows[2] = ["version", "2"]
  #expect(issues(newer).first?.message.contains("version 2") == true)

  #expect(!issues(XLSXWorkbook(sheets: [.init(name: "Sheet1", rows: [["a"]])])).isEmpty)

  var extraColumn = workbook
  let accounts = extraColumn.sheets.firstIndex { $0.name == "Accounts" }!
  extraColumn.sheets[accounts].rows[0].append("balance")
  #expect(issues(extraColumn).contains { $0.column == "balance" && $0.message == "Unknown column." })

  var missingSheet = workbook
  missingSheet.sheets.removeAll { $0.name == "Effects" }
  #expect(issues(missingSheet).contains { $0.sheet == "Effects" && $0.message == "The sheet is missing." })

  var extraSheet = workbook
  extraSheet.sheets.append(.init(name: "Scratch", rows: [["notes"]]))
  #expect(issues(extraSheet).contains { $0.sheet == "Scratch" })
}

@Test func importChecksReferencesAcrossSheets() throws {
  let content = try sampleContent()
  let workbook = LedgerXLSXExchange.workbook(content)
  let categories = workbook.sheet(named: "Categories")!.rows
  let foodRow = categories.firstIndex { $0.contains("Food") }!
  let cafesRow = categories.firstIndex { $0.contains("Cafés") }!
  let food = content.categories.first { $0.name == "Food" }!
  let cafes = content.categories.first { $0.name == "Cafés" }!

  let looped = editing(workbook, sheet: "Categories", row: foodRow, column: "parent_id", to: cafes.id)
  #expect(issues(looped).contains { $0.column == "parent_id" && $0.message.contains("loop") })

  let wrongKind = editing(workbook, sheet: "Categories", row: cafesRow, column: "kind", to: "income")
  #expect(issues(wrongKind).contains { $0.row == cafesRow + 1 && $0.column == "parent_id" })

  let transactions = workbook.sheet(named: "Transactions")!.rows
  let payRow = transactions.firstIndex { $0.contains("income") }!
  let wrongCategory = editing(
    workbook, sheet: "Transactions", row: payRow, column: "category_id", to: food.id)
  #expect(issues(wrongCategory).contains { $0.row == payRow + 1 && $0.column == "category_id" })

  let unknownTag = editing(
    workbook, sheet: "Transactions", row: payRow, column: "tag_ids", to: key("ghost"))
  #expect(issues(unknownTag).contains { $0.column == "tag_ids" })

  let effects = workbook.sheet(named: "Effects")!.rows
  let usdRow = effects.firstIndex { $0.contains("USD") }!
  let wrongCurrency = editing(workbook, sheet: "Effects", row: usdRow, column: "currency", to: "EUR")
  #expect(issues(wrongCurrency).contains { $0.row == usdRow + 1 && $0.column == "currency" })

  var orphanEffect = workbook
  let effectsIndex = orphanEffect.sheets.firstIndex { $0.name == "Effects" }!
  orphanEffect.sheets[effectsIndex].rows.append([key("orphan"), content.accounts[0].id, "increase", "1", "INR"])
  #expect(issues(orphanEffect).contains { $0.sheet == "Effects" && $0.column == "transaction_id" })
}

@Test func localDateTimesParseStrictly() {
  let parse = LedgerXLSXExchange.Reader.parseLocalDateTime
  #expect(parse("2026-03-01").map(LedgerXLSXExchange.localDateTime) == "2026-03-01 00:00:00.000")
  #expect(parse("2026-03-01 09:05").map(LedgerXLSXExchange.localDateTime) == "2026-03-01 09:05:00.000")
  #expect(parse("2026-03-01T09:05:07.042").map(LedgerXLSXExchange.localDateTime) == "2026-03-01 09:05:07.042")
  for bad in ["", "2026-3-1", "01/03/2026", "2026-02-29", "2026-03-01 24:00", "2026-03-01 9:05", "2026-03-01 09:05.1", "2026-03-01 09:05:07.4", "46082"] {
    #expect(parse(bad) == nil)
  }
}
