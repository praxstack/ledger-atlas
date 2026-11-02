import CSQLite
import Foundation
import LedgerCore
import Testing

@testable import LedgerStore

// Synthetic data only: every name, amount and date here is made up.

private func makeMergeStore() throws -> LedgerStore {
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

private struct MergeFixture {
  let origin: LedgerOrigin
  let cash: LedgerAccount
  let food: LedgerCategory
  let when: SourceTemporal

  init() throws {
    origin = try LedgerOrigin(id: key("9"), label: "local")
    cash = try LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: key("a")), name: "Cash",
      currencyUnit: "USD", origin: origin)
    food = try LedgerCategory(
      id: StableLedgerID.category(origin: origin, localKey: key("b")), name: "Food",
      kind: .expense, origin: origin)
    when = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 7, day: 4)),
      in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  }

  func draft(_ amount: String, account: LedgerAccount? = nil) throws -> LedgerTransactionDraft {
    try LedgerTransactionDraft(
      effects: [
        try LedgerTransactionEffect(
          accountID: (account ?? cash).id, direction: .decrease,
          amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal(amount)))
      ], categoryID: food.id, kind: .expense, occurredAt: when, origin: origin)
  }

  /// A ledger with one account, one category and one expense.
  func seeded() throws -> (app: LedgerApplication, first: LedgerTransactionRevision) {
    let app = LedgerApplication(store: try makeMergeStore())
    try app.createAccount(cash)
    try app.createCategory(food)
    let first = try app.createTransaction(
      idempotencyKey: key("1"), draft: draft("4.00"), createdAt: UTCInstant(epochMilliseconds: 1))
    return (app, first)
  }

  func copy(of app: LedgerApplication) throws -> LedgerApplication {
    let exported = try app.exportPackage()
    let copy = LedgerApplication(store: try makeMergeStore())
    try copy.importPackage(manifest: exported.manifest, payload: exported.payload)
    return copy
  }
}

@Test func mergingABackupAddsOnlyWhatTheOpenLedgerLacks() throws {
  let fixture = try MergeFixture()
  let (open, first) = try fixture.seeded()
  let backup = try fixture.copy(of: open)

  // After the copy, the backup gains a card, a second expense and an edit of the first.
  let card = try LedgerAccount(
    id: StableLedgerID.account(origin: fixture.origin, localKey: key("c")), name: "Card",
    currencyUnit: "USD", origin: fixture.origin)
  try backup.createAccount(card)
  _ = try backup.createTransaction(
    idempotencyKey: key("2"), draft: fixture.draft("7.50", account: card),
    createdAt: UTCInstant(epochMilliseconds: 2))
  _ = try backup.correctTransaction(
    transactionID: first.transactionID, expectedCurrentRevisionID: first.id,
    draft: fixture.draft("4.25"), createdAt: UTCInstant(epochMilliseconds: 3))
  // Meanwhile the open ledger renamed its account. The open ledger's version wins.
  try open.updateAccount(
    try LedgerAccount(
      id: fixture.cash.id, name: "Wallet", currencyUnit: "USD", origin: fixture.origin))

  let merged = try LedgerApplication.mergedPackage(
    current: try open.exportPackage(), incoming: try backup.exportPackage())
  #expect(
    merged.summary
      == LedgerMergeSummary(
        addedAccounts: 1, addedCategories: 0, addedTransactions: 1, addedRevisions: 2,
        addedOther: 0))

  let result = LedgerApplication(store: try makeMergeStore())
  try result.importPackage(manifest: merged.manifest, payload: merged.payload)
  let snapshot = try result.snapshot()
  #expect(Set(snapshot.accounts.map(\.name)) == ["Wallet", "Card"])
  #expect(snapshot.transactions.count == 2)
  #expect(snapshot.revisionHistory.count == 3)
  let edited = try #require(snapshot.transactions.first { $0.id == first.transactionID })
  #expect(edited.currentRevision.revision == 2)

  // Merging the same backup again adds nothing and gives the same ledger.
  let again = try LedgerApplication.mergedPackage(
    current: try result.exportPackage(), incoming: try backup.exportPackage())
  #expect(again.summary.isEmpty)
  let twice = LedgerApplication(store: try makeMergeStore())
  try twice.importPackage(manifest: again.manifest, payload: again.payload)
  #expect(try twice.checksum() == result.checksum())
}

@Test func mergingLedgersThatEditedTheSameHistoryDifferentlyIsRefused() throws {
  let fixture = try MergeFixture()
  let (open, first) = try fixture.seeded()
  let backup = try fixture.copy(of: open)
  _ = try open.correctTransaction(
    transactionID: first.transactionID, expectedCurrentRevisionID: first.id,
    draft: fixture.draft("5.00"), createdAt: UTCInstant(epochMilliseconds: 2))
  _ = try backup.correctTransaction(
    transactionID: first.transactionID, expectedCurrentRevisionID: first.id,
    draft: fixture.draft("6.00"), createdAt: UTCInstant(epochMilliseconds: 2))

  #expect(throws: LedgerMergeError.conflictingHistory(revisions: 1)) {
    try LedgerApplication.mergedPackage(
      current: try open.exportPackage(), incoming: try backup.exportPackage())
  }
}

@Test func resetKeepsTheSetupOrNothingAndNeverTouchesTheOpenLedger() throws {
  let fixture = try MergeFixture()
  let (open, _) = try fixture.seeded()
  let trip = try LedgerTag(
    id: StableLedgerID.tag(origin: fixture.origin, localKey: key("d")), name: "Trip",
    origin: fixture.origin)
  try open.createTag(trip)
  let before = try open.checksum()

  let contents = try LedgerApplication.resetPackage(
    from: try open.snapshot(), scope: .contentsOnly)
  let kept = LedgerApplication(store: try makeMergeStore())
  try kept.importPackage(manifest: contents.manifest, payload: contents.payload)
  let keptSnapshot = try kept.snapshot()
  #expect(keptSnapshot.accounts.map(\.id) == [fixture.cash.id])
  #expect(keptSnapshot.categories.map(\.id) == [fixture.food.id])
  #expect(keptSnapshot.tags.map(\.id) == [trip.id])
  #expect(keptSnapshot.transactions.isEmpty)

  let complete = try LedgerApplication.resetPackage(from: try open.snapshot(), scope: .complete)
  let empty = LedgerApplication(store: try makeMergeStore())
  try empty.importPackage(manifest: complete.manifest, payload: complete.payload)
  let emptySnapshot = try empty.snapshot()
  #expect(emptySnapshot.accounts.isEmpty && emptySnapshot.categories.isEmpty)
  #expect(emptySnapshot.transactions.isEmpty && emptySnapshot.tags.isEmpty)

  #expect(try open.checksum() == before)
}

@Test func twoPackageRestoreCyclesKeepTheChecksum() throws {
  let fixture = try MergeFixture()
  let (open, _) = try fixture.seeded()
  let once = try fixture.copy(of: open)
  let twice = try fixture.copy(of: once)
  #expect(try once.checksum() == open.checksum())
  #expect(try twice.checksum() == open.checksum())
}
