import CSQLite
import Foundation
import LedgerCore
import Testing

@testable import LedgerStore

// Synthetic data only: every name, amount and date here is made up.

private func createSchema(_ database: OpaquePointer) throws {
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
}

private func makeMemoryApp() throws -> LedgerApplication {
  var database: OpaquePointer?
  guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  try createSchema(database)
  return LedgerApplication(
    store: try LedgerStore(takingOwnershipOfValidatedCanonicalDatabase: database))
}

private let origin = try! LedgerOrigin(id: String(repeating: "6", count: 64), label: "synthetic")
private let createdAt = UTCInstant(epochMilliseconds: 1_780_000_000_000)

private func key(_ seed: String) -> String {
  let hex = seed.unicodeScalars.map { String(format: "%02x", $0.value) }.joined()
  return String((hex + String(repeating: "0", count: 64)).prefix(64))
}

/// A workbook's content: live and deleted records, a transfer, tags, and a deleted row.
private struct Workbook {
  let everyday: LedgerAccountGroup
  let closed: LedgerAccountGroup
  let wallet: LedgerAccount
  let savings: LedgerAccount
  let oldCard: LedgerAccount
  let food: LedgerCategory
  let snacks: LedgerCategory
  let oldHobby: LedgerCategory
  let trip: LedgerTag
  let retired: LedgerTag
  let content: LedgerXLSXExchange.Content

  init() throws {
    everyday = try LedgerAccountGroup(id: key("group-everyday"), name: "Everyday")
    closed = try LedgerAccountGroup(
      id: key("group-closed"), name: "Closed", displayOrder: 1, lifecycle: .tombstoned)
    wallet = try LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: key("wallet")), name: "Wallet",
      currencyUnit: "INR", origin: origin, groupID: everyday.id)
    savings = try LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: key("savings")), name: "Savings",
      currencyUnit: "INR", origin: origin)
    oldCard = try LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: key("old-card")), name: "Old card",
      currencyUnit: "INR", origin: origin, lifecycle: .tombstoned, groupID: closed.id)
    food = try LedgerCategory(
      id: StableLedgerID.category(origin: origin, localKey: key("food")), name: "Food",
      kind: .expense, origin: origin)
    snacks = try LedgerCategory(
      id: StableLedgerID.category(origin: origin, localKey: key("snacks")), name: "Snacks",
      kind: .expense, origin: origin, parentID: food.id)
    oldHobby = try LedgerCategory(
      id: StableLedgerID.category(origin: origin, localKey: key("old-hobby")), name: "Old hobby",
      kind: .expense, origin: origin, lifecycle: .tombstoned)
    trip = try LedgerTag(
      id: StableLedgerID.tag(origin: origin, localKey: key("trip")), name: "trip", origin: origin)
    retired = try LedgerTag(
      id: StableLedgerID.tag(origin: origin, localKey: key("retired")), name: "retired",
      origin: origin, lifecycle: .tombstoned)

    let when = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 5, day: 2)),
      in: SourceTimeZone(fixedOffsetSeconds: 19_800), precision: .day)
    func inr(_ literal: String) throws -> CurrencyAmount {
      try CurrencyAmount(unitCode: "INR", amount: ExactDecimal(literal))
    }
    func row(
      _ seed: String, _ effects: [LedgerTransactionEffect], kind: LedgerTransactionKind,
      category: String? = nil, lifecycle: LedgerLifecycleState = .active, tags: [String] = []
    ) throws -> LedgerXLSXExchange.Transaction {
      LedgerXLSXExchange.Transaction(
        id: try StableLedgerID.transaction(origin: origin, localKey: key(seed)),
        draft: try LedgerTransactionDraft(
          effects: effects, categoryID: category, kind: kind, occurredAt: when, origin: origin),
        lifecycle: lifecycle, tags: try LedgerTagLinks(tags))
    }
    let wallet = self.wallet
    let savings = self.savings
    let oldCard = self.oldCard
    content = LedgerXLSXExchange.Content(
      accountGroups: [everyday, closed], accounts: [wallet, savings, oldCard],
      categories: [snacks, food, oldHobby], tags: [trip, retired],
      transactions: [
        try row(
          "chips", [LedgerTransactionEffect(accountID: wallet.id, direction: .decrease, amount: inr("40"))],
          kind: .expense, category: snacks.id, tags: [trip.id, retired.id]),
        try row(
          "move",
          [
            LedgerTransactionEffect(accountID: wallet.id, direction: .decrease, amount: inr("500")),
            LedgerTransactionEffect(accountID: savings.id, direction: .increase, amount: inr("500")),
          ], kind: .transfer),
        // Live rows on records the workbook marks deleted.
        try row(
          "card", [LedgerTransactionEffect(accountID: oldCard.id, direction: .decrease, amount: inr("75"))],
          kind: .expense, category: oldHobby.id),
        try row(
          "gone", [LedgerTransactionEffect(accountID: wallet.id, direction: .decrease, amount: inr("1"))],
          kind: .expense, lifecycle: .tombstoned),
      ])
  }
}

@Test func xlsxImportAddsEverythingInOneStepAndKeepsDeletedRecordsDeleted() throws {
  let workbook = try Workbook()
  let app = try makeMemoryApp()
  let bytes = try LedgerXLSXExchange.xlsxData(workbook.content)
  let plan = try app.planXLSXImport(try LedgerXLSXExchange.content(fromXLSX: bytes))
  #expect(plan.canApply)
  #expect(plan.transactions.count == 3)
  #expect(plan.skippedDeletedTransactions == 1)

  try app.applyXLSXImport(plan, createdAt: createdAt)
  let ledger = try app.snapshot()

  #expect(
    ledger.accountGroups.sorted { $0.id < $1.id }
      == [workbook.everyday, workbook.closed].sorted { $0.id < $1.id })
  #expect(
    ledger.accounts.sorted { $0.id < $1.id }
      == [workbook.wallet, workbook.savings, workbook.oldCard].sorted { $0.id < $1.id })
  #expect(
    ledger.categories.sorted { $0.id < $1.id }
      == [workbook.food, workbook.snacks, workbook.oldHobby].sorted { $0.id < $1.id })
  #expect(
    ledger.tags.sorted { $0.id < $1.id }
      == [workbook.trip, workbook.retired].sorted { $0.id < $1.id })

  let importOrigin = try LedgerXLSXImportPlan.origin()
  #expect(ledger.transactions.count == 3)
  #expect(ledger.transactions.allSatisfy { $0.currentRevision.draft.origin == importOrigin })
  #expect(ledger.transactions.allSatisfy { $0.currentRevision.lifecycle == .active })
  let transfers = ledger.transactions.filter { $0.currentRevision.draft.kind == .transfer }
  #expect(transfers.count == 1)
  #expect(transfers.first?.currentRevision.draft.effects.count == 2)
  let chips = try #require(
    ledger.transactions.first { $0.currentRevision.draft.categoryID == workbook.snacks.id })
  #expect(
    ledger.revisionTags[chips.currentRevision.id]?.tagIDs.sorted()
      == [workbook.trip.id, workbook.retired.id].sorted())
}

@Test func reimportingTheSameWorkbookOrTheLedgersOwnExportAddsNothing() throws {
  let workbook = try Workbook()
  let app = try makeMemoryApp()
  try app.applyXLSXImport(try app.planXLSXImport(workbook.content), createdAt: createdAt)
  let checksum = try app.checksum()

  let again = try app.planXLSXImport(workbook.content)
  #expect(again.canApply)
  #expect(again.isEmpty)
  #expect(again.summary["Transactions"] == .init(added: 0, unchanged: 3))
  try app.applyXLSXImport(again, createdAt: createdAt)

  let ownExport = LedgerXLSXExchange.Content(snapshot: try app.snapshot())
  let roundTrip = try LedgerXLSXExchange.content(
    fromXLSX: try LedgerXLSXExchange.xlsxData(ownExport))
  let fromOwnExport = try app.planXLSXImport(roundTrip)
  #expect(fromOwnExport.canApply)
  #expect(fromOwnExport.isEmpty)
  #expect(try app.checksum() == checksum)
}

@Test func xlsxImportWithConflictsWritesNothing() throws {
  let workbook = try Workbook()
  let app = try makeMemoryApp()
  try app.createAccount(
    try LedgerAccount(
      id: workbook.savings.id, name: "Rainy day", currencyUnit: "INR", origin: origin))
  let checksum = try app.checksum()

  let plan = try app.planXLSXImport(workbook.content)
  #expect(!plan.canApply)
  #expect(plan.conflicts.map(\.sheet) == ["Accounts"])
  #expect(throws: LedgerStore.Error.importPlanNotApplicable) {
    try app.applyXLSXImport(plan, createdAt: createdAt)
  }
  #expect(try app.checksum() == checksum)
}

@Test func xlsxImportPlannedBeforeTheLedgerChangedWritesNothing() throws {
  let workbook = try Workbook()
  let app = try makeMemoryApp()
  let plan = try app.planXLSXImport(workbook.content)
  try app.createAccount(workbook.savings)  // added after planning
  let checksum = try app.checksum()

  #expect(throws: LedgerStore.Error.importPlanNotApplicable) {
    try app.applyXLSXImport(plan, createdAt: createdAt)
  }
  #expect(try app.checksum() == checksum)
  #expect(try app.snapshot().accounts == [workbook.savings])
}

@Test func xlsxImportThatFailsPartWayLeavesTheLedgerUnchanged() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("ledger.sqlite")
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  try createSchema(database)
  sqlite3_close(database)
  #expect(chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

  var inserted = 0
  let store = try LedgerStore.openForMutation(at: url) { phase in
    guard phase == .afterInsertingTransaction else { return }
    inserted += 1
    if inserted >= 2 { throw LedgerStore.Error.incompatibleCanonicalStore }
  }
  let app = LedgerApplication(store: store)
  let checksum = try app.checksum()
  let plan = try app.planXLSXImport(try Workbook().content)

  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try app.applyXLSXImport(plan, createdAt: createdAt)
  }
  #expect(inserted == 2)
  #expect(try app.checksum() == checksum)
  let ledger = try app.snapshot()
  #expect(ledger.accounts.isEmpty && ledger.categories.isEmpty && ledger.tags.isEmpty)
  #expect(ledger.transactions.isEmpty)
}

@Test func xlsxImportWithARowTheStoreRefusesWritesNothing() throws {
  let workbook = try Workbook()
  let app = try makeMemoryApp()
  let checksum = try app.checksum()
  // A row on an account that is in neither the workbook nor the ledger. Reading a workbook
  // refuses this; the store must too, after the records and earlier rows went in.
  let stray = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: key("stray")), name: "Stray",
    currencyUnit: "INR", origin: origin)
  var content = workbook.content
  content.transactions.append(
    LedgerXLSXExchange.Transaction(
      id: try StableLedgerID.transaction(origin: origin, localKey: key("zz-stray")),
      draft: try LedgerTransactionDraft(
        effects: [
          LedgerTransactionEffect(
            accountID: stray.id, direction: .decrease,
            amount: CurrencyAmount(unitCode: "INR", amount: ExactDecimal("9")))
        ], categoryID: nil, kind: .expense,
        occurredAt: content.transactions[0].draft.occurredAt, origin: origin)))
  let plan = try app.planXLSXImport(content)
  #expect(plan.canApply)

  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try app.applyXLSXImport(plan, createdAt: createdAt)
  }
  #expect(try app.checksum() == checksum)
  #expect(try app.snapshot().accounts.isEmpty)
}
