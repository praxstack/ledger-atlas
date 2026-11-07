import Foundation
import LedgerAtlasMacUI
import LedgerCore
import LedgerStore
import Testing

private let origin = try! LedgerOrigin(id: String(repeating: "5", count: 64), label: "tests")
private let when = try! SourceTemporal(
  resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 3, day: 1)),
  in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)

private func key(_ seed: Character) -> String { String(repeating: seed, count: 64) }

private func account(
  _ seed: Character, _ unit: String, hidden: Bool = false, includeInTotals: Bool = true
) throws -> LedgerAccount {
  try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: key(seed)), name: "Account \(seed)",
    currencyUnit: unit, origin: origin, hidden: hidden, includeInTotals: includeInTotals)
}

private func posted(
  _ seed: Character, _ account: LedgerAccount, _ direction: LedgerEffectDirection,
  _ literal: String, _ kind: LedgerTransactionKind
) throws -> LedgerTransactionSnapshot {
  let transactionID = try StableLedgerID.transaction(origin: origin, localKey: key(seed))
  let draft = try LedgerTransactionDraft(
    effects: [
      LedgerTransactionEffect(
        accountID: account.id, direction: direction,
        amount: CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal(literal)))
    ], categoryID: nil, kind: kind, occurredAt: when, origin: origin)
  let revision = try LedgerTransactionRevision(
    id: StableLedgerID.revision(transactionID: transactionID, revision: 1),
    transactionID: transactionID, revision: 1, predecessorID: nil, draft: draft,
    createdAt: UTCInstant(epochMilliseconds: 1))
  return try LedgerTransactionSnapshot(id: transactionID, currentRevision: revision)
}

private func snapshot(
  _ accounts: [LedgerAccount], _ transactions: [LedgerTransactionSnapshot]
) -> LedgerStore.LedgerReadSnapshot {
  LedgerStore.LedgerReadSnapshot(
    accounts: accounts, transactions: transactions,
    revisionHistory: transactions.map(\.currentRevision), undisplayedImportedEventCount: 0)
}

@Test func pdfStatementExportWritesAReadablePDF() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "ledger-atlas-statement-\(UUID().uuidString).pdf")
  defer { try? FileManager.default.removeItem(at: url) }
  let report = LedgerReport(
    title: "Activity by kind",
    rows: [LedgerReportRow(id: "expense", label: "expense", amountLiteral: "12.30", unitCode: "USD", count: 1)],
    totalLiteral: "12.30", unitCode: "USD")
  try LedgerPDFStatementExporter.export(report, to: url)
  let bytes = try Data(contentsOf: url)
  #expect(bytes.starts(with: Data("%PDF".utf8)))
  #expect(bytes.contains(Data("%%EOF".utf8)))
}

@Test func statementLabelsTheBottomLineNetNotTotal() {
  let report = LedgerReport(
    title: "Activity by kind",
    rows: [
      LedgerReportRow(id: "income", label: "income", amountLiteral: "100", unitCode: "USD", count: 1),
      LedgerReportRow(id: "expense", label: "expense", amountLiteral: "40", unitCode: "USD", count: 1),
    ],
    totalLiteral: "60", unitCode: "USD")
  #expect(report.accessibleTable.contains("Net: 60 USD"))
  #expect(!report.accessibleTable.contains("Total"))
  #expect(LedgerStatement(reports: [report]).text == report.accessibleTable)
}

@Test func statementShowsEveryCurrencyOnItsOwnAndNeverAddsThemTogether() throws {
  let dollars = try account("a", "USD")
  let rupees = try account("b", "INR")
  let ledger = snapshot(
    [rupees, dollars],
    [
      try posted("1", dollars, .increase, "100", .income),
      try posted("2", dollars, .decrease, "40", .expense),
      try posted("3", rupees, .increase, "500", .income),
    ])

  #expect(LedgerStatement.unitCodes(in: ledger) == ["INR", "USD"])
  let statement = try LedgerStatement(snapshot: ledger)
  #expect(statement.reports.map(\.unitCode) == ["INR", "USD"])
  #expect(try ExactDecimal(statement.reports[0].totalLiteral) == ExactDecimal("500"))
  #expect(try ExactDecimal(statement.reports[1].totalLiteral) == ExactDecimal("60"))

  let text = statement.text
  #expect(text.contains("Shown separately by currency: INR, USD."))
  #expect(text.contains("never added together"))
  let netLines = text.split(separator: "\n").filter { $0.hasPrefix("Net: ") }
  #expect(netLines.count == 2)
  #expect(netLines.allSatisfy { $0.hasSuffix(" INR") || $0.hasSuffix(" USD") })
  // Record counts are listed once, not once per currency.
  if let inventory = statement.reports.first?.inventoryLines.first {
    #expect(text.components(separatedBy: inventory).count == 2)
  }

  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "ledger-atlas-statement-\(UUID().uuidString).pdf")
  defer { try? FileManager.default.removeItem(at: url) }
  try LedgerPDFStatementExporter.export(statement, to: url)
  #expect(try Data(contentsOf: url).starts(with: Data("%PDF".utf8)))
}

@Test func statementSkipsCurrenciesThatOnlyExcludedAccountsUse() throws {
  let dollars = try account("a", "USD")
  let hiddenEuros = try account("b", "EUR", hidden: true)
  let excludedPounds = try account("c", "GBP", includeInTotals: false)
  let ledger = snapshot(
    [dollars, hiddenEuros, excludedPounds],
    [
      try posted("1", hiddenEuros, .increase, "7", .income),
      try posted("2", excludedPounds, .increase, "9", .income),
    ])
  #expect(LedgerStatement.unitCodes(in: ledger) == ["USD"])
  #expect(try LedgerStatement(snapshot: ledger).text.contains("Net: 0 USD"))
}

@Test func emptyLedgerStatementStillListsRecordCounts() throws {
  let ledger = snapshot([], [])
  #expect(LedgerStatement.unitCodes(in: ledger) == ["USD"])
  let text = try LedgerStatement(snapshot: ledger).text
  #expect(text.hasPrefix("Activity by kind"))
  #expect(!text.contains("Shown separately by currency"))
}

@Test func pdfExportWritesOnlyThePickedFileAndReplacesAnExistingOne() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("statement.pdf")
  try Data("older statement".utf8).write(to: url)
  let report = LedgerReport(title: "Activity by kind", rows: [], totalLiteral: "0", unitCode: "USD")

  try LedgerPDFStatementExporter.export(report, to: url)

  // The App Sandbox allows only the picked file: no temporary or backup file beside it.
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["statement.pdf"])
  #expect(try Data(contentsOf: url).starts(with: Data("%PDF".utf8)))
  let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
  #expect((permissions as? NSNumber)?.intValue == 0o600)
}

@Test func pdfExportNeverReplacesAFolderOrALink() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let target = directory.appendingPathComponent("target.txt")
  try Data("keep me".utf8).write(to: target)
  let link = directory.appendingPathComponent("link.pdf")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  let report = LedgerReport(title: "Activity by kind", rows: [], totalLiteral: "0", unitCode: "USD")

  #expect(throws: LedgerPDFStatementExporter.Error.invalidDestination) {
    try LedgerPDFStatementExporter.export(report, to: link)
  }
  #expect(try Data(contentsOf: target) == Data("keep me".utf8))
  #expect(throws: LedgerPDFStatementExporter.Error.invalidDestination) {
    try LedgerPDFStatementExporter.export(report, to: directory)
  }
}

/// #206 review: pages are cut by line count, so a line that wrapped when drawn ran off the
/// page and was clipped. Lines are now broken to the page's columns before paging.
@Test func pdfLinesAreBrokenToThePageWidthSoNothingIsClipped() {
  let long =
    "  Result: no Money Manager figure, because Money Manager keeps no balance for a debit card; its entries count in A Very Long Account Name"
  let lines = LedgerPDFStatementExporter.wrapped(
    [long, "short", String(repeating: "x", count: 90)], columns: 40)
  #expect(lines.allSatisfy { $0.count <= 40 })
  #expect(lines.contains("short"))
  #expect(lines.first == "  Result: no Money Manager figure,")
  #expect(lines[1].hasPrefix("    because"))
  // Nothing is lost: the words come back in order.
  let rejoined = lines.prefix { $0 != "short" }.map { $0.trimmingCharacters(in: .whitespaces) }
    .joined(separator: " ")
  #expect(rejoined == long.trimmingCharacters(in: .whitespaces))
  #expect(lines.suffix(3).joined().filter { $0 == "x" }.count == 90)
}

/// Wide characters take more room than they count for, so the exporter measures each piece
/// with the font that draws it instead of counting characters.
@Test func pdfLinesAreBrokenByMeasuredWidthForWideCharacters() {
  let wide = "日本語の口座名がとても長い場合でも切れないこと確認します"
  let fits: (String) -> Bool = { $0.unicodeScalars.count * 2 <= 20 }
  let lines = LedgerPDFStatementExporter.wrapped([wide], fits: fits)
  #expect(lines.count > 1)
  #expect(lines.allSatisfy(fits))
  #expect(lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined() == wide)
}
