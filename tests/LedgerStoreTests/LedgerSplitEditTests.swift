import CSQLite
import Foundation
import LedgerCore
import Testing

@testable import LedgerStore

// Synthetic data only: every name, amount and date here is made up.

private func makeSplitStore() throws -> LedgerStore {
  var database: OpaquePointer?
  guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  for statement in CanonicalLedgerSchema.creationStatements {
    guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
      throw LedgerStore.Error.incompatibleCanonicalStore
    }
  }
  guard
    sqlite3_exec(
      database, "PRAGMA application_id=\(CanonicalLedgerSchema.applicationID)", nil, nil, nil)
      == SQLITE_OK,
    sqlite3_exec(
      database,
      "INSERT INTO ledger_meta(key, value) VALUES('schema_version', '\(CanonicalLedgerSchema.version)'), ('ledger_identity', 'ledger-atlas-canonical'), ('schema_fingerprint', '\(CanonicalLedgerSchema.fingerprint)')",
      nil, nil, nil) == SQLITE_OK
  else { throw LedgerStore.Error.incompatibleCanonicalStore }
  return try LedgerStore(takingOwnershipOfValidatedCanonicalDatabase: database)
}

private func key(_ character: Character) -> String { String(repeating: character, count: 64) }

private func usd(_ literal: String) throws -> CurrencyAmount {
  try CurrencyAmount(unitCode: "USD", amount: ExactDecimal(literal))
}

private struct SplitFixture {
  let app: LedgerApplication
  let origin: LedgerOrigin
  let cash: LedgerAccount
  let card: LedgerAccount
  let groceries: LedgerCategory
  let health: LedgerCategory
  let home: LedgerCategory
  let when: SourceTemporal
  let purchase: LedgerSplitPurchase

  init() throws {
    app = LedgerApplication(store: try makeSplitStore())
    origin = try LedgerOrigin(id: key("9"), label: "local")
    cash = try LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: key("a")), name: "Cash",
      currencyUnit: "USD", origin: origin)
    card = try LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: key("e")), name: "Card",
      currencyUnit: "USD", origin: origin)
    try app.createAccount(cash)
    try app.createAccount(card)
    groceries = try LedgerCategory(
      id: StableLedgerID.category(origin: origin, localKey: key("b")), name: "Groceries",
      kind: .expense, origin: origin)
    health = try LedgerCategory(
      id: StableLedgerID.category(origin: origin, localKey: key("c")), name: "Health",
      kind: .expense, origin: origin)
    home = try LedgerCategory(
      id: StableLedgerID.category(origin: origin, localKey: key("f")), name: "Home",
      kind: .expense, origin: origin)
    for category in [groceries, health, home] { try app.createCategory(category) }
    when = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 8, day: 31)),
      in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
    purchase = try app.createSplit(
      try LedgerSplitDraft(
        id: key("d"), accountID: cash.id, parentAmount: usd("10.00"),
        lines: [
          try LedgerSplitLine(
            id: StableLedgerID.splitLine(origin: origin, localKey: key("1")),
            amount: usd("6.25"), categoryID: groceries.id, description: "Food",
            displayOrder: 0),
          try LedgerSplitLine(
            id: StableLedgerID.splitLine(origin: origin, localKey: key("2")),
            amount: usd("3.75"), categoryID: health.id, description: "Medicine",
            displayOrder: 1),
        ], occurredAt: when, note: "Market receipt", origin: origin),
      createdAt: UTCInstant(epochMilliseconds: 1))
  }

  func edited(
    total: String, amounts: [String], categories: [String], order: [Int],
    account: String? = nil, note: String? = "Market receipt"
  ) throws -> LedgerSplitDraft {
    let lines = try zip(purchase.lines, zip(amounts, zip(categories, order))).map {
      line, change in
      try LedgerSplitLine(
        id: line.id, amount: usd(change.0), categoryID: change.1.0,
        description: line.description, displayOrder: change.1.1)
    }
    return try LedgerSplitDraft(
      id: purchase.id, accountID: account ?? cash.id, parentAmount: usd(total), lines: lines,
      occurredAt: when, note: note, origin: origin)
  }
}

@Test func editingASplitKeepsItsIdentityAndCountsEachLineOnce() throws {
  let fixture = try SplitFixture()
  let app = fixture.app
  let draft = try fixture.edited(
    total: "12.00", amounts: ["4.00", "8.00"], categories: [fixture.groceries.id, fixture.home.id],
    order: [1, 0], account: fixture.card.id, note: "Corner shop")

  let edited = try app.editSplit(draft, createdAt: UTCInstant(epochMilliseconds: 2))
  #expect(edited.id == fixture.purchase.id)
  #expect(edited.accountID == fixture.card.id)
  #expect(edited.parentAmount == (try usd("12.00")))
  #expect(edited.note == "Corner shop")
  // Line identity survives; order follows the new display order.
  #expect(edited.lines.map(\.id) == [fixture.purchase.lines[1].id, fixture.purchase.lines[0].id])
  #expect(edited.lines.map(\.categoryID) == [fixture.home.id, fixture.groceries.id])
  #expect(edited.lines.map(\.description) == ["Medicine", "Food"])
  #expect(try app.splitPurchases() == [edited])

  // Each line is one revision-2 transaction; history keeps revision 1.
  let snapshot = try app.snapshot()
  #expect(snapshot.transactions.count == 2)
  #expect(snapshot.transactions.allSatisfy { $0.currentRevision.revision == 2 })
  #expect(snapshot.revisionHistory.count == 4)

  // Reports count the purchase's money once: the expense row is the purchase total.
  let report = try app.report(unitCode: "USD")
  let expense = try #require(report.rows.first { $0.id == "expense" })
  #expect(try ExactDecimal(expense.amountLiteral) == ExactDecimal("12"))
  let homeRow = try #require(report.categoryRows.first { $0.id == fixture.home.id })
  #expect(try ExactDecimal(homeRow.amountLiteral) == ExactDecimal("8"))
  #expect(report.categoryRows.first { $0.id == fixture.health.id } == nil)

  // The same edit again writes nothing.
  let again = try app.editSplit(draft, createdAt: UTCInstant(epochMilliseconds: 3))
  #expect(again == edited)
  #expect(try app.snapshot().revisionHistory.count == 4)

  // Edits survive a portable package round trip.
  let exported = try app.exportPackage()
  let restored = LedgerApplication(store: try makeSplitStore())
  try restored.importPackage(manifest: exported.manifest, payload: exported.payload)
  #expect(try restored.splitPurchases() == [edited])
  #expect(try restored.checksum() == app.checksum())
}

@Test func aSplitEditThatFailsPartWayChangesNothing() throws {
  let fixture = try SplitFixture()
  let app = fixture.app
  let before = try app.checksum()

  // The second line points at a category that does not exist, so its correction fails after
  // the first line's correction was written inside the same database transaction.
  let missing = try StableLedgerID.category(origin: fixture.origin, localKey: key("0"))
  let broken = try fixture.edited(
    total: "10.00", amounts: ["5.00", "5.00"], categories: [fixture.home.id, missing],
    order: [0, 1])
  #expect(throws: (any Error).self) {
    try app.editSplit(broken, createdAt: UTCInstant(epochMilliseconds: 2))
  }
  #expect(try app.checksum() == before)
  #expect(try app.splitPurchases() == [fixture.purchase])

  // Lines cannot be added or removed by an edit.
  let oneLine = try LedgerSplitDraft(
    id: fixture.purchase.id, accountID: fixture.cash.id, parentAmount: usd("6.25"),
    lines: [fixture.purchase.lines[0]], occurredAt: fixture.when, note: "Market receipt",
    origin: fixture.origin)
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try app.editSplit(oneLine, createdAt: UTCInstant(epochMilliseconds: 2))
  }
  #expect(try app.checksum() == before)
}

@Test func closingASplitClosesEveryLineTogether() throws {
  let fixture = try SplitFixture()
  let app = fixture.app

  try app.closeSplit(purchaseID: fixture.purchase.id, createdAt: UTCInstant(epochMilliseconds: 2))

  let snapshot = try app.snapshot()
  #expect(snapshot.transactions.allSatisfy { $0.currentRevision.lifecycle == .tombstoned })
  let listing = LedgerApplication.splitPurchaseListing(from: snapshot)
  #expect(listing.purchases.isEmpty)
  #expect(listing.unreadableGroupCount == 0)
  #expect(listing.closedTransactionIDs == Set(snapshot.transactions.map(\.id)))
  #expect(try app.splitPurchases().isEmpty)
  #expect(try app.report(unitCode: "USD").rows.first { $0.id == "expense" } == nil)

  // A closed purchase can't be edited or closed again.
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try app.closeSplit(
      purchaseID: fixture.purchase.id, createdAt: UTCInstant(epochMilliseconds: 3))
  }
}

@Test func aPurchaseWithOnlySomeLinesClosedIsListedLineByLine() throws {
  let fixture = try SplitFixture()
  let app = fixture.app
  let member = try #require(try app.snapshot().transactions.first)
  _ = try app.tombstoneTransaction(
    transactionID: member.id, expectedCurrentRevisionID: member.currentRevision.id,
    createdAt: UTCInstant(epochMilliseconds: 2))

  let listing = LedgerApplication.splitPurchaseListing(from: try app.snapshot())
  #expect(listing.purchases.isEmpty)
  #expect(listing.unreadableGroupCount == 1)
  #expect(listing.unreadableTransactionIDs.count == 2)
}
