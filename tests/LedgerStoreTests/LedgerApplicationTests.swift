import CSQLite
import CryptoKit
import Darwin
import Dispatch
import Foundation
import LedgerCore
import Testing

@testable import LedgerStore

private func makeApplicationStore(seedSQL: String? = nil) throws -> LedgerStore {
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
  if let seedSQL,
    sqlite3_exec(database, seedSQL, nil, nil, nil) != SQLITE_OK
  {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  return try LedgerStore(takingOwnershipOfValidatedCanonicalDatabase: database)
}

@Test func macAndIOSFacingClientsAgreeOnSyntheticCommands() throws {
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 1, day: 1)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let draft = try LedgerTransactionDraft(
    effects: [
      try LedgerTransactionEffect(
        accountID: account.id, direction: .increase,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("4.00")))
    ], categoryID: nil, kind: .income, occurredAt: when, origin: origin)

  func run(_ client: some LedgerClient) throws -> String {
    try client.createAccount(account)
    let created = try client.createTransaction(
      idempotencyKey: String(repeating: "b", count: 64), draft: draft,
      createdAt: UTCInstant(epochMilliseconds: 1))
    return created.id
  }

  let first = LedgerApplication(store: try makeApplicationStore())
  let second = LedgerApplication(store: try makeApplicationStore())
  #expect(try run(first) == run(second))
}

@Test func accountGroupsAndPreferencesRoundTripWithStableIdentity() throws {
  let app = LedgerApplication(store: try makeApplicationStore())
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let group = try LedgerAccountGroup(
    id: String(repeating: "2", count: 64), name: "Borrowed", displayOrder: 3)
  try app.createAccountGroup(group)
  try app.createAccountGroup(group)

  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Credit", currencyUnit: "USD", origin: origin, groupID: group.id, displayOrder: 4,
    hidden: true, includeInTotals: false, variant: .loan)
  try app.createAccount(account)
  try app.createAccount(account)

  var snapshot = try app.snapshot()
  #expect(snapshot.accountGroups == [group])
  #expect(snapshot.accounts == [account])

  let renamed = try LedgerAccount(
    id: account.id, name: "Credit card", currencyUnit: account.currencyUnit, origin: origin,
    lifecycle: .tombstoned, groupID: group.id, displayOrder: 1, hidden: false,
    includeInTotals: true, variant: .overdraft)
  try app.updateAccount(renamed)
  snapshot = try app.snapshot()
  #expect(snapshot.accounts.first == renamed)

  let restored = try LedgerAccount(
    id: renamed.id, name: renamed.name, currencyUnit: renamed.currencyUnit, origin: origin,
    lifecycle: .active, groupID: group.id, displayOrder: renamed.displayOrder,
    hidden: renamed.hidden, includeInTotals: renamed.includeInTotals, variant: renamed.variant)
  try app.updateAccount(restored)
  #expect(try app.snapshot().accounts.first?.lifecycle == .active)

  let occurredAt = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 8, day: 1)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  _ = try app.createTransaction(
    idempotencyKey: String(repeating: "b", count: 64),
    draft: LedgerTransactionDraft(
      effects: [
        try LedgerTransactionEffect(
          accountID: restored.id, direction: .decrease,
          amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("5.00")))
      ], categoryID: nil, kind: .expense, occurredAt: occurredAt, origin: origin),
    createdAt: UTCInstant(epochMilliseconds: 4))
  let report = try app.report(unitCode: "USD")
  #expect(report.rows.contains { $0.id == LedgerTransactionKind.expense.rawValue })

  let renamedGroup = try LedgerAccountGroup(
    id: group.id, name: "Liabilities", displayOrder: 1, lifecycle: .active)
  try app.updateAccountGroup(renamedGroup)
  #expect(try app.snapshot().accountGroups.first == renamedGroup)

  let exported = try app.exportPackage()
  let restoredApp = LedgerApplication(store: try makeApplicationStore())
  try restoredApp.importPackage(manifest: exported.manifest, payload: exported.payload)
  #expect(try restoredApp.snapshot().accounts == app.snapshot().accounts)
  #expect(try restoredApp.snapshot().accountGroups == app.snapshot().accountGroups)
  #expect(try restoredApp.checksum() == app.checksum())
  #expect(try restoredApp.exportPackage().manifest.payloadSHA256 == exported.manifest.payloadSHA256)

  try app.tombstoneAccount(account.id)
  try app.updateAccountGroup(
    LedgerAccountGroup(id: group.id, name: renamedGroup.name, displayOrder: 1, lifecycle: .tombstoned))
  let tombstonedExport = try app.exportPackage()
  let tombstonedRestore = LedgerApplication(store: try makeApplicationStore())
  try tombstonedRestore.importPackage(
    manifest: tombstonedExport.manifest, payload: tombstonedExport.payload)
  #expect(try tombstonedRestore.snapshot().accounts == app.snapshot().accounts)
  #expect(try tombstonedRestore.snapshot().accountGroups == app.snapshot().accountGroups)
  #expect(try tombstonedRestore.checksum() == app.checksum())
}

@Test func categoryTreeSupportsArbitraryDepthAndRejectsCyclesAtomically() throws {
  let app = LedgerApplication(store: try makeApplicationStore())
  let origin = try LedgerOrigin(id: String(repeating: "3", count: 64), label: "local")
  let parent = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Living", kind: .expense, origin: origin, displayOrder: 2)
  let child = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "b", count: 64)),
    name: "Home", kind: .expense, origin: origin, parentID: parent.id, displayOrder: 1)
  let grandchild = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Supplies", kind: .expense, origin: origin, parentID: child.id, displayOrder: 0)
  try app.createCategory(parent)
  try app.createCategory(child)
  try app.createCategory(grandchild)
  try app.createCategory(grandchild)

  let snapshot = try app.snapshot()
  #expect(snapshot.categories.count == 3)
  #expect(snapshot.categories.first(where: { $0.id == grandchild.id })?.parentID == child.id)

  let before = try app.checksum()
  let cycle = try LedgerCategory(
    id: parent.id, name: parent.name, kind: parent.kind, origin: origin,
    parentID: grandchild.id, displayOrder: parent.displayOrder)
  #expect(throws: LedgerStore.Error.categoryCycleDetected) {
    try app.updateCategory(cycle)
  }
  #expect(try app.checksum() == before)

  let tombstoned = try LedgerCategory(
    id: grandchild.id, name: grandchild.name, kind: grandchild.kind, origin: origin,
    lifecycle: .tombstoned, parentID: child.id, displayOrder: grandchild.displayOrder)
  try app.updateCategory(tombstoned)
  #expect(try app.snapshot().categories.first(where: { $0.id == grandchild.id })?.lifecycle == .tombstoned)
  let restored = try LedgerCategory(
    id: grandchild.id, name: grandchild.name, kind: grandchild.kind, origin: origin,
    lifecycle: .active, parentID: child.id, displayOrder: grandchild.displayOrder)
  try app.updateCategory(restored)
  #expect(try app.snapshot().categories.first(where: { $0.id == grandchild.id }) == restored)

  let exported = try app.exportPackage()
  let restoredApp = LedgerApplication(store: try makeApplicationStore())
  try restoredApp.importPackage(manifest: exported.manifest, payload: exported.payload)
  #expect(try restoredApp.snapshot().categories == app.snapshot().categories)
  #expect(try restoredApp.checksum() == app.checksum())

  try app.tombstoneCategory(grandchild.id)
  try app.tombstoneCategory(child.id)
  try app.tombstoneCategory(parent.id)
  let tombstonedExport = try app.exportPackage()
  let tombstonedRestore = LedgerApplication(store: try makeApplicationStore())
  try tombstonedRestore.importPackage(
    manifest: tombstonedExport.manifest, payload: tombstonedExport.payload)
  #expect(try tombstonedRestore.snapshot().categories == app.snapshot().categories)
  #expect(try tombstonedRestore.checksum() == app.checksum())
}

@Test func accountStateSearchFiltersAndHierarchyMutationsAreExplicit() throws {
  let app = LedgerApplication(store: try makeApplicationStore())
  let origin = try LedgerOrigin(id: String(repeating: "4", count: 64), label: "local")
  let visible = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Visible", currencyUnit: "USD", origin: origin)
  let hidden = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "b", count: 64)),
    name: "Hidden", currencyUnit: "USD", origin: origin, hidden: true)
  let excluded = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Excluded", currencyUnit: "USD", origin: origin, includeInTotals: false)
  try app.createAccount(visible)
  try app.createAccount(hidden)
  try app.createAccount(excluded)
  for (index, account) in [visible, hidden, excluded].enumerated() {
    _ = try app.createTransaction(
      idempotencyKey: String(repeating: String(index), count: 64),
      draft: try expenseDraft(
        accountID: account.id, categoryID: nil, origin: origin, amount: "1.00",
        year: 2026, month: 9, day: index + 1),
      createdAt: UTCInstant(epochMilliseconds: Int64(index + 1)))
  }
  #expect(try app.search(LedgerSearchQuery(accountHidden: true)).count == 1)
  #expect(try app.search(LedgerSearchQuery(accountHidden: false)).count == 2)
  #expect(try app.search(LedgerSearchQuery(accountIncludedInTotals: false)).count == 1)
  #expect(
    try app.search(
      LedgerSearchQuery(
        accountID: hidden.id, accountHidden: false, includeTombstones: true)).isEmpty)

  let group = try LedgerAccountGroup(
    id: String(repeating: "d", count: 64), name: "Grouped")
  try app.createAccountGroup(group)
  let grouped = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "d", count: 64)),
    name: "Grouped account", currencyUnit: "USD", origin: origin, groupID: group.id)
  try app.createAccount(grouped)
  let groupBefore = try app.checksum()
  let tombstonedGroup = try LedgerAccountGroup(
    id: group.id, name: group.name, lifecycle: .tombstoned)
  #expect(throws: LedgerStore.Error.accountGroupHasActiveAccounts) {
    try app.updateAccountGroup(tombstonedGroup)
  }
  #expect(try app.checksum() == groupBefore)

  let parent = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "e", count: 64)),
    name: "Parent", kind: .expense, origin: origin)
  let child = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "f", count: 64)),
    name: "Child", kind: .expense, origin: origin, parentID: parent.id)
  try app.createCategory(parent)
  try app.createCategory(child)
  let categoryBefore = try app.checksum()
  let hiddenParent = try LedgerCategory(
    id: parent.id, name: parent.name, kind: parent.kind, origin: origin, hidden: true)
  #expect(throws: LedgerStore.Error.categoryHasActiveChildren) {
    try app.updateCategory(hiddenParent)
  }
  #expect(try app.checksum() == categoryBefore)
  let tombstonedParent = try LedgerCategory(
    id: parent.id, name: parent.name, kind: parent.kind, origin: origin,
    lifecycle: .tombstoned)
  #expect(throws: LedgerStore.Error.categoryHasActiveChildren) {
    try app.updateCategory(tombstonedParent)
  }
  #expect(try app.checksum() == categoryBefore)

  let hiddenInternalParent = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "0", count: 64)),
    name: "Hidden parent", kind: .expense, origin: origin, parentID: parent.id, hidden: true)
  try app.createCategory(hiddenInternalParent)
  let hiddenInternalChild = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "1", count: 64)),
    name: "Hidden child", kind: .expense, origin: origin, parentID: hiddenInternalParent.id)
  let beforeHiddenChild = try app.checksum()
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try app.createCategory(hiddenInternalChild)
  }
  #expect(try app.checksum() == beforeHiddenChild)

  let invalidPackage = LedgerCanonicalPackage(
    formatVersion: LedgerPortablePackageFormat.version,
    formatFingerprint: LedgerPortablePackageFormat.fingerprint,
    accounts: [], categories: [parent, hiddenInternalParent, hiddenInternalChild], revisions: [], links: [],
    recurrenceRules: [], budgets: [], installmentPlans: [])
  let importStore = try makeApplicationStore()
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try importStore.applyExport(invalidPackage)
  }
  #expect(try LedgerApplication(store: importStore).snapshot().categories.isEmpty)
}

@Test func healthRejectsActiveAccountAssignedToTombstonedGroup() throws {
  let origin = String(repeating: "6", count: 64)
  let account = String(repeating: "7", count: 64)
  let group = String(repeating: "8", count: 64)
  let sql = """
  INSERT INTO ledger_origin VALUES ('\(origin)', 'Synthetic', NULL);
  INSERT INTO ledger_account_group VALUES ('\(group)', 'Tombstoned', 0, 'tombstoned');
  INSERT INTO ledger_account VALUES ('\(account)', 'Cash', 'USD', '\(origin)', 'active');
  INSERT INTO ledger_account_preferences VALUES ('\(account)', '\(group)', 0, 0, 1, 'standard');
  """
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    _ = try makeApplicationStore(seedSQL: sql)
  }
}

@Test func reportRollsCategoryAmountsToVisibleAncestorsOnce() throws {
  let app = LedgerApplication(store: try makeApplicationStore())
  let origin = try LedgerOrigin(id: String(repeating: "5", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let parent = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "b", count: 64)),
    name: "Living", kind: .expense, origin: origin)
  let child = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Home", kind: .expense, origin: origin, parentID: parent.id)
  let grandchild = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "d", count: 64)),
    name: "Supplies", kind: .expense, origin: origin, parentID: child.id)
  try app.createCategory(parent)
  try app.createCategory(child)
  try app.createCategory(grandchild)
  for (category, amount, day) in [(parent, "2.00", 1), (child, "3.00", 2), (grandchild, "4.00", 3)] {
    _ = try app.createTransaction(
      idempotencyKey: String(repeating: String(day), count: 64),
      draft: try expenseDraft(
        accountID: account.id, categoryID: category.id, origin: origin, amount: amount,
        year: 2026, month: 10, day: day),
      createdAt: UTCInstant(epochMilliseconds: Int64(day)))
  }
  let report = try app.report(unitCode: "USD")
  let living = try #require(report.categoryRows.first { $0.id == parent.id })
  let home = try #require(report.categoryRows.first { $0.id == child.id })
  let supplies = try #require(report.categoryRows.first { $0.id == grandchild.id })
  #expect(try ExactDecimal(living.amountLiteral) == ExactDecimal("9.00"))
  #expect(living.count == 3)
  #expect(try ExactDecimal(home.amountLiteral) == ExactDecimal("7.00"))
  #expect(home.count == 2)
  #expect(try ExactDecimal(supplies.amountLiteral) == ExactDecimal("4.00"))
  #expect(supplies.count == 1)
  #expect(report.accessibleTable.contains("Category Living"))

  let hiddenLeaf = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "e", count: 64)),
    name: "Private", kind: .expense, origin: origin, parentID: parent.id, hidden: true)
  try app.createCategory(hiddenLeaf)
  _ = try app.createTransaction(
    idempotencyKey: String(repeating: "e", count: 64),
    draft: try expenseDraft(
      accountID: account.id, categoryID: hiddenLeaf.id, origin: origin, amount: "10.00",
      year: 2026, month: 10, day: 4),
    createdAt: UTCInstant(epochMilliseconds: 4))
  let hiddenReport = try app.report(unitCode: "USD")
  let hiddenParent = try #require(hiddenReport.categoryRows.first { $0.id == parent.id })
  #expect(try ExactDecimal(hiddenParent.amountLiteral) == ExactDecimal("9.00"))
  #expect(hiddenReport.categoryRows.contains { $0.id == hiddenLeaf.id } == false)

  let tombstonedLeaf = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "f", count: 64)),
    name: "Retired", kind: .expense, origin: origin, parentID: parent.id)
  try app.createCategory(tombstonedLeaf)
  _ = try app.createTransaction(
    idempotencyKey: String(repeating: "0", count: 64),
    draft: try expenseDraft(
      accountID: account.id, categoryID: tombstonedLeaf.id, origin: origin, amount: "11.00",
      year: 2026, month: 10, day: 5),
    createdAt: UTCInstant(epochMilliseconds: 5))
  let beforeTombstone = try app.report(unitCode: "USD")
  #expect(try #require(beforeTombstone.categoryRows.first { $0.id == parent.id }).amountLiteral == "20")
  try app.tombstoneCategory(tombstonedLeaf.id)
  let afterTombstone = try app.report(unitCode: "USD")
  #expect(try #require(afterTombstone.categoryRows.first { $0.id == parent.id }).amountLiteral == "9")
}

@Test func applicationCreatesInspectsCorrectsAndTombstonesExactMoney() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 3, day: 4)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .minute)
  let amount = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("12.30"))
  let draft = try LedgerTransactionDraft(
    effects: [
      try LedgerTransactionEffect(accountID: account.id, direction: .increase, amount: amount)
    ], categoryID: nil, kind: .income, occurredAt: when,
    sourceLiterals: [try LedgerSourceLiteral(field: "amount", literal: "12.30")], origin: origin)
  let created = try app.createTransaction(
    idempotencyKey: String(repeating: "b", count: 64), draft: draft,
    createdAt: UTCInstant(epochMilliseconds: 1))
  let snapshot = try app.snapshot()
  #expect(snapshot.transactions.count == 1)
  #expect(
    snapshot.transactions[0].currentRevision.draft.effects[0].amount.amount.rawLiteral == "12.30")
  #expect(snapshot.transactions[0].currentRevision.draft.occurredAt.localDateTime.date.year == 2026)

  let correctedDraft = try LedgerTransactionDraft(
    effects: [
      try LedgerTransactionEffect(
        accountID: account.id, direction: .increase,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("15.00")))
    ], categoryID: nil, kind: .income, occurredAt: when, origin: origin)
  let corrected = try app.correctTransaction(
    transactionID: created.transactionID, expectedCurrentRevisionID: created.id,
    draft: correctedDraft, createdAt: UTCInstant(epochMilliseconds: 2))
  #expect(corrected.revision == 2)
  let tombstoned = try app.tombstoneTransaction(
    transactionID: created.transactionID, expectedCurrentRevisionID: corrected.id,
    createdAt: UTCInstant(epochMilliseconds: 3))
  #expect(tombstoned.lifecycle == LedgerLifecycleState.tombstoned)
}

@Test func invalidCommandLeavesChecksumUnchangedAndIsContentFree() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let before = try app.checksum()
  let sentinel = "PRIVATE-AMOUNT-99.99"
  do {
    _ = try CurrencyAmount(unitCode: "usd", amount: ExactDecimal(sentinel))
    Issue.record("expected invalid currency")
  } catch {
    #expect(!String(describing: error).contains(sentinel))
  }
  #expect(throws: LedgerDomainError.self) {
    try LedgerTransactionDraft(
      effects: [], categoryID: nil, kind: .income,
      occurredAt: SourceTemporal(
        resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 1, day: 1)),
        in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day),
      origin: origin)
  }
  #expect(try app.checksum() == before)
}

@Test func applicationCreatesSameCurrencyTransfer() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let cash = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  let savings = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "b", count: 64)),
    name: "Savings", currencyUnit: "USD", origin: origin)
  try app.createAccount(cash)
  try app.createAccount(savings)
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 1, day: 2)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let amount = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("8.00"))
  let result = try app.createTransfer(
    idempotencyKey: String(repeating: "e", count: 64), sourceAccountID: cash.id,
    destinationAccountID: savings.id, sourceAmount: amount, destinationAmount: amount,
    conversion: nil, fee: nil, feeAccountID: nil, occurredAt: when, origin: origin,
    createdAt: UTCInstant(epochMilliseconds: 1))
  #expect(result.transfer.draft.kind == LedgerTransactionKind.transfer)
  #expect(result.fee == nil)
}

@Test func invalidTransferFeeLeavesLedgerUnchanged() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let cash = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  let savings = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "b", count: 64)),
    name: "Savings", currencyUnit: "USD", origin: origin)
  try app.createAccount(cash)
  try app.createAccount(savings)
  let before = try app.checksum()
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 3, day: 4)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let amount = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("8.00"))
  let mismatchedFee = try CurrencyAmount(unitCode: "EUR", amount: ExactDecimal("0.30"))
  do {
    _ = try app.createTransfer(
      idempotencyKey: String(repeating: "f", count: 64), sourceAccountID: cash.id,
      destinationAccountID: savings.id, sourceAmount: amount, destinationAmount: amount,
      conversion: nil, fee: mismatchedFee, feeAccountID: cash.id, occurredAt: when, origin: origin,
      createdAt: UTCInstant(epochMilliseconds: 1))
    Issue.record("expected mismatched fee currency to fail")
  } catch {
    #expect(error is LedgerApplication.Error || error is LedgerStore.Error)
  }
  #expect(try app.checksum() == before)
  #expect(try app.snapshot().transactions.isEmpty)
}

@Test func transferFeeWithoutAccountLeavesLedgerUnchanged() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let cash = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  let savings = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "b", count: 64)),
    name: "Savings", currencyUnit: "USD", origin: origin)
  try app.createAccount(cash)
  try app.createAccount(savings)
  let before = try app.checksum()
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 3, day: 4)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let amount = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("8.00"))
  let fee = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("1.00"))
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    _ = try app.createTransfer(
      idempotencyKey: String(repeating: "f", count: 64), sourceAccountID: cash.id,
      destinationAccountID: savings.id, sourceAmount: amount, destinationAmount: amount,
      conversion: nil, fee: fee, feeAccountID: nil, occurredAt: when, origin: origin,
      createdAt: UTCInstant(epochMilliseconds: 1))
  }
  #expect(try app.checksum() == before)
  #expect(try app.snapshot().accounts.count == 2)
  #expect(try app.snapshot().transactions.isEmpty)
}

@Test func transferFeeAccountWithoutFeeLeavesLedgerUnchanged() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let cash = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  let savings = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "b", count: 64)),
    name: "Savings", currencyUnit: "USD", origin: origin)
  try app.createAccount(cash)
  try app.createAccount(savings)
  let before = try app.checksum()
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 3, day: 4)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let amount = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("8.00"))
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    _ = try app.createTransfer(
      idempotencyKey: String(repeating: "f", count: 64), sourceAccountID: cash.id,
      destinationAccountID: savings.id, sourceAmount: amount, destinationAmount: amount,
      conversion: nil, fee: nil, feeAccountID: cash.id, occurredAt: when, origin: origin,
      createdAt: UTCInstant(epochMilliseconds: 1))
  }
  #expect(try app.checksum() == before)
  #expect(try app.snapshot().accounts.count == 2)
  #expect(try app.snapshot().transactions.isEmpty)
}

@Test func invalidSplitComponentLeavesLedgerUnchanged() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let cash = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(cash)
  let groceries = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Groceries", kind: .expense, origin: origin)
  try app.createCategory(groceries)
  let missing = try StableLedgerID.category(
    origin: origin, localKey: String(repeating: "d", count: 64))
  let before = try app.checksum()
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 3, day: 5)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  do {
    _ = try app.createSplit(
      idempotencyKey: String(repeating: "s", count: 64), accountID: cash.id,
      parentAmount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("5.00")),
      components: [
        (CurrencyAmount(unitCode: "USD", amount: ExactDecimal("3.00")), groceries.id),
        (CurrencyAmount(unitCode: "USD", amount: ExactDecimal("2.00")), missing),
      ], occurredAt: when, origin: origin, createdAt: UTCInstant(epochMilliseconds: 1))
    Issue.record("expected missing split category to fail")
  } catch {
    #expect(error is LedgerApplication.Error || error is LedgerStore.Error)
  }
  #expect(try app.checksum() == before)
  #expect(try app.snapshot().transactions.isEmpty)
}

@Test func firstClassSplitPurchaseKeepsStableLinesAndRoundTrips() throws {
  let app = LedgerApplication(store: try makeApplicationStore())
  let origin = try LedgerOrigin(id: String(repeating: "9", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let groceries = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "b", count: 64)),
    name: "Groceries", kind: .expense, origin: origin)
  let health = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Health", kind: .expense, origin: origin)
  try app.createCategory(groceries)
  try app.createCategory(health)
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 8, day: 31)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let purchaseID = String(repeating: "d", count: 64)
  let groceryLineID = try StableLedgerID.splitLine(
    origin: origin, localKey: String(repeating: "1", count: 64))
  let healthLineID = try StableLedgerID.splitLine(
    origin: origin, localKey: String(repeating: "2", count: 64))
  let draft = try LedgerSplitDraft(
    id: purchaseID, accountID: account.id,
    parentAmount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("10.00")),
    lines: [
      try LedgerSplitLine(
        id: groceryLineID,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("6.25")),
        categoryID: groceries.id, description: "Food", displayOrder: 1),
      try LedgerSplitLine(
        id: healthLineID,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("3.75")),
        categoryID: health.id, description: "Medicine", displayOrder: 0),
    ], occurredAt: when, note: "Market receipt", origin: origin)
  let created = try app.createSplit(draft, createdAt: UTCInstant(epochMilliseconds: 1))
  let retried = try app.createSplit(draft, createdAt: UTCInstant(epochMilliseconds: 1))
  #expect(created == retried)
  #expect(created.id == purchaseID)
  #expect(created.lines.map(\.id) == [healthLineID, groceryLineID])
  #expect(created.lines.map(\.displayOrder) == [0, 1])
  #expect(created.lines.map(\.description) == ["Medicine", "Food"])
  #expect(created.note == "Market receipt")
  #expect(try app.splitPurchases() == [created])

  let exported = try app.exportPackage()
  let restored = LedgerApplication(store: try makeApplicationStore())
  try restored.importPackage(manifest: exported.manifest, payload: exported.payload)
  #expect(try restored.splitPurchases() == [created])
  #expect(try restored.checksum() == app.checksum())
}

@Test func applicationTransfersSplitsInstallmentsRecurrenceBudgetsSearchAndExport() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let usd = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "USD Cash", currencyUnit: "USD", origin: origin)
  let eur = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "b", count: 64)),
    name: "EUR Cash", currencyUnit: "EUR", origin: origin)
  try app.createAccount(usd)
  try app.createAccount(eur)
  #expect(try app.snapshot().accounts.count == 2)
  let groceries = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Groceries", kind: .expense, origin: origin)
  let fuel = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "d", count: 64)),
    name: "Fuel", kind: .expense, origin: origin)
  try app.createCategory(groceries)
  try app.createCategory(fuel)
  #expect(try app.snapshot().accounts.count == 2)

  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 1, day: 31)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let sourceAmount = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("10.00"))
  let destAmount = try CurrencyAmount(unitCode: "EUR", amount: ExactDecimal("9.00"))
  let conversion = try LedgerConversion(
    sourceAmount: sourceAmount, convertedAmount: destAmount, rate: ExactDecimal("1.1111"),
    rateScale: 4, rounding: .halfEven)
  let transfer: (transfer: LedgerTransactionRevision, fee: LedgerTransactionRevision?)
  do {
    transfer = try app.createTransfer(
      idempotencyKey: String(repeating: "e", count: 64), sourceAccountID: usd.id,
      destinationAccountID: eur.id, sourceAmount: sourceAmount, destinationAmount: destAmount,
      conversion: conversion, fee: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("0.30")),
      feeAccountID: usd.id, occurredAt: when, origin: origin,
      createdAt: UTCInstant(epochMilliseconds: 1))
  } catch {
    Issue.record("createTransfer failed: \(error)")
    throw error
  }
  #expect(transfer.transfer.draft.kind == LedgerTransactionKind.transfer)
  #expect(transfer.fee != nil)

  let split = try app.createSplit(
    idempotencyKey: String(repeating: "f", count: 64), accountID: usd.id,
    parentAmount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("5.00")),
    components: [
      (try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("2.00")), groceries.id),
      (try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("3.00")), fuel.id),
    ], occurredAt: when, origin: origin, createdAt: UTCInstant(epochMilliseconds: 2))
  #expect(split.count == 2)

  let plan = try LedgerInstallmentPlan(
    id: StableLedgerID.installmentPlan(origin: origin, localKey: String(repeating: "1", count: 64)),
    origin: origin, accountID: usd.id, categoryID: groceries.id,
    principal: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("12.00")), occurrenceCount: 3)
  let installments = try app.createInstallmentPlan(
    plan, occurredAt: when, createdAt: UTCInstant(epochMilliseconds: 3))
  #expect(installments.count == 3)

  let rule = try LedgerRecurrenceRule(
    id: StableLedgerID.recurrenceRule(origin: origin, localKey: String(repeating: "2", count: 64)),
    origin: origin, accountID: usd.id, categoryID: groceries.id, kind: .expense,
    amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("1.00")), frequency: .monthly,
    interval: 1, dayOfMonth: 31, timeZone: SourceTimeZone(fixedOffsetSeconds: 0),
    start: SourceLocalDate(year: 2024, month: 1, day: 31),
    until: SourceLocalDate(year: 2024, month: 3, day: 31))
  try app.createRecurrence(rule)
  let generated = try app.generateOccurrences(
    rule, through: SourceLocalDate(year: 2024, month: 3, day: 31),
    createdAt: UTCInstant(epochMilliseconds: 4))
  #expect(generated.count == 3)
  #expect(generated[1].draft.occurredAt.localDateTime.date.day == 29)

  let budget = try LedgerBudget(
    id: StableLedgerID.budget(origin: origin, localKey: String(repeating: "3", count: 64)),
    origin: origin, name: "Food", categoryID: groceries.id,
    amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("100.00")), period: .monthly,
    rollover: true, start: SourceLocalDate(year: 2026, month: 1, day: 1))
  try app.createBudget(budget)

  let found = try app.search(LedgerSearchQuery(accountID: usd.id, kind: .expense))
  #expect(!found.isEmpty)
  let report = try app.report(unitCode: "USD")
  #expect(report.accessibleTable.contains("expense"))
  let exported = try app.exportPackage()
  #expect(exported.manifest.formatVersion == LedgerPortablePackageFormat.version)
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try app.importPackage(manifest: exported.manifest, payload: exported.payload)
  }
  let restored = LedgerApplication(store: try makeApplicationStore())
  try restored.importPackage(manifest: exported.manifest, payload: exported.payload)
  let restoredTransfer = try #require(
    restored.snapshot().transactions.first { $0.currentRevision.draft.kind == .transfer })
  #expect(restoredTransfer.currentRevision.draft.roundingPolicy == .halfEven)
  #expect(try restored.exportPackage().manifest.payloadSHA256 == exported.manifest.payloadSHA256)
  var damaged = exported.manifest
  damaged = LedgerExportManifest(
    schemaVersion: exported.manifest.schemaVersion,
    schemaFingerprint: exported.manifest.schemaFingerprint,
    payloadSHA256: String(repeating: "0", count: 64),
    createdAtMilliseconds: 0)
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try app.importPackage(manifest: damaged, payload: exported.payload)
  }
}

@Test func installmentLastShareAbsorbsRemainderAndDatesAdvance() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let groceries = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Groceries", kind: .expense, origin: origin)
  try app.createCategory(groceries)
  let start = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 1, day: 15)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let plan = try LedgerInstallmentPlan(
    id: StableLedgerID.installmentPlan(origin: origin, localKey: String(repeating: "1", count: 64)),
    origin: origin, accountID: account.id, categoryID: groceries.id,
    principal: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("10.00")), occurrenceCount: 3)
  let created = try app.createInstallmentPlan(
    plan, occurredAt: start, createdAt: UTCInstant(epochMilliseconds: 1))
  #expect(created.count == 3)
  let amounts = created.map { $0.draft.effects[0].amount.amount }
  var total = try ExactDecimal("0")
  for amount in amounts { total = try total.adding(amount) }
  let expectedTotal = try ExactDecimal("10.00")
  #expect(total == expectedTotal)
  #expect(amounts[0] == amounts[1])
  #expect(amounts[2] != amounts[0])
  #expect(created[0].draft.occurredAt.localDateTime.date.month == 1)
  #expect(created[1].draft.occurredAt.localDateTime.date.month == 2)
  #expect(created[2].draft.occurredAt.localDateTime.date.month == 3)
}

@Test func portablePackageIdentityIsIndependentAndFrozenV10PayloadsStillDecode() throws {
  let source = LedgerApplication(store: try makeApplicationStore())
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try source.createAccount(account)

  let exported = try source.exportPackage()
  #expect(exported.manifest.formatVersion == LedgerPortablePackageFormat.version)
  #expect(exported.manifest.formatFingerprint == LedgerPortablePackageFormat.fingerprint)
  #expect(exported.manifest.formatVersion != CanonicalLedgerSchema.version)
  let currentObject = try #require(
    JSONSerialization.jsonObject(with: exported.payload) as? [String: Any])
  #expect(currentObject["formatVersion"] as? Int == LedgerPortablePackageFormat.version)
  #expect(currentObject["formatFingerprint"] as? String == LedgerPortablePackageFormat.fingerprint)
  #expect(currentObject["schemaVersion"] == nil)
  #expect(currentObject["schemaFingerprint"] == nil)

  let legacyPayload = Data(
    (#"{"accounts":[{"currencyUnit":"USD","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","lifecycle":"active","name":"Cash","originID":"1111111111111111111111111111111111111111111111111111111111111111","originLabel":"synthetic"}],"budgets":[],"categories":[],"installmentPlans":[],"links":[],"preservedSource":[],"recurrenceRules":[],"revisions":[],"schemaFingerprint":"aca9d078dd357cd64a6fe209e04fb7e3ac724525cf15b8c313e0b8177d2b6926","schemaVersion":10}"#)
      .utf8)
  let legacyManifestBytes = Data(
    (#"{"createdAtMilliseconds":0,"payloadSHA256":"3689355a3fdc2624bf56bf94cae56e8c06ca827b2a8f6057870ed078deebcdff","schemaFingerprint":"aca9d078dd357cd64a6fe209e04fb7e3ac724525cf15b8c313e0b8177d2b6926","schemaVersion":10}"#)
      .utf8)
  let legacyManifestObject = try #require(
    JSONSerialization.jsonObject(with: legacyManifestBytes) as? [String: Any])
  let legacyManifest = LedgerExportManifest(
    schemaVersion: try #require(legacyManifestObject["schemaVersion"] as? Int),
    schemaFingerprint: try #require(legacyManifestObject["schemaFingerprint"] as? String),
    payloadSHA256: try #require(legacyManifestObject["payloadSHA256"] as? String),
    createdAtMilliseconds: try #require(
      legacyManifestObject["createdAtMilliseconds"] as? Int64))
  let destination = LedgerApplication(store: try makeApplicationStore())
  try destination.importPackage(manifest: legacyManifest, payload: legacyPayload)
  #expect(try destination.snapshot().accounts.map(\.id) == [String(repeating: "a", count: 64)])

  var legacyV1Object = currentObject
  for key in ["accountGroups", "tags", "transactionTemplates", "memos", "revisionTags"] {
    legacyV1Object.removeValue(forKey: key)
  }
  if var rows = legacyV1Object["accounts"] as? [[String: Any]] {
    rows = rows.map { row in
      var row = row
      for key in ["groupID", "displayOrder", "hidden", "includeInTotals", "variant"] {
        row.removeValue(forKey: key)
      }
      return row
    }
    legacyV1Object["accounts"] = rows
  }
  if var rows = legacyV1Object["categories"] as? [[String: Any]] {
    rows = rows.map { row in
      var row = row
      for key in ["parentID", "displayOrder", "hidden"] { row.removeValue(forKey: key) }
      return row
    }
    legacyV1Object["categories"] = rows
  }
  legacyV1Object["formatVersion"] = LedgerPortablePackageFormat.legacyV1Version
  legacyV1Object["formatFingerprint"] = LedgerPortablePackageFormat.legacyV1Fingerprint
  let legacyV1Payload = try JSONSerialization.data(
    withJSONObject: legacyV1Object, options: [.sortedKeys])
  let legacyV1Digest = SHA256.hash(data: legacyV1Payload).map {
    String(format: "%02x", $0)
  }.joined()
  let legacyV1Manifest = LedgerExportManifest(
    formatVersion: LedgerPortablePackageFormat.legacyV1Version,
    formatFingerprint: LedgerPortablePackageFormat.legacyV1Fingerprint,
    payloadSHA256: legacyV1Digest, createdAtMilliseconds: 0)
  let legacyV1Destination = LedgerApplication(store: try makeApplicationStore())
  try legacyV1Destination.importPackage(manifest: legacyV1Manifest, payload: legacyV1Payload)
  #expect(try legacyV1Destination.snapshot().accounts.map(\.id) == source.snapshot().accounts.map(\.id))
}

@Test func applyExportRejectsUnknownPortableIdentityBeforeMutation() throws {
  let store = try makeApplicationStore()
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "synthetic")
  let account = try LedgerAccount(
    id: String(repeating: "a", count: 64), name: "Future", currencyUnit: "USD", origin: origin)
  let future = LedgerCanonicalPackage(
    formatVersion: LedgerPortablePackageFormat.version + 1,
    formatFingerprint: String(repeating: "f", count: 64), accounts: [account], categories: [],
    revisions: [], links: [], recurrenceRules: [], budgets: [], installmentPlans: [])

  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try store.applyExport(future)
  }
  #expect(try store.readSnapshot().accounts.isEmpty)
}

@Test func exportIncludesV11OrganizationStateAndRejectsStandaloneOrigin() throws {
  let origin = String(repeating: "1", count: 64)
  let account = String(repeating: "2", count: 64)
  let category = String(repeating: "3", count: 64)
  let group = String(repeating: "4", count: 64)
  let cases = [
    "INSERT INTO ledger_account_group VALUES ('\(group)', 'Synthetic', 0, 'active')",
    """
    INSERT INTO ledger_origin VALUES ('\(origin)', 'synthetic', NULL);
    INSERT INTO ledger_category VALUES ('\(category)', 'Synthetic', 'expense', '\(origin)', 'active');
    INSERT INTO ledger_category_tree VALUES ('\(category)', NULL, 0, 0)
    """,
    """
    INSERT INTO ledger_origin VALUES ('\(origin)', 'synthetic', NULL);
    INSERT INTO ledger_account VALUES ('\(account)', 'Synthetic', 'USD', '\(origin)', 'active');
    INSERT INTO ledger_account_preferences VALUES ('\(account)', NULL, 0, 0, 1, 'standard')
    """,
    "INSERT INTO ledger_origin VALUES ('\(origin)', 'standalone', NULL)",
  ]
  let groupExport = try LedgerApplication(store: try makeApplicationStore(seedSQL: cases[0]))
    .exportPackage()
  let groupObject = try #require(
    JSONSerialization.jsonObject(with: groupExport.payload) as? [String: Any])
  #expect((groupObject["accountGroups"] as? [[String: Any]])?.count == 1)

  let categoryExport = try LedgerApplication(store: try makeApplicationStore(seedSQL: cases[1]))
    .exportPackage()
  let categoryObject = try #require(
    JSONSerialization.jsonObject(with: categoryExport.payload) as? [String: Any])
  #expect((categoryObject["categories"] as? [[String: Any]])?.first?["hidden"] as? Bool == false)

  let accountExport = try LedgerApplication(store: try makeApplicationStore(seedSQL: cases[2]))
    .exportPackage()
  let accountObject = try #require(
    JSONSerialization.jsonObject(with: accountExport.payload) as? [String: Any])
  #expect((accountObject["accounts"] as? [[String: Any]])?.first?["includeInTotals"] as? Bool == true)

  let standalone = LedgerApplication(store: try makeApplicationStore(seedSQL: cases[3]))
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try standalone.exportPackage()
  }
}

@Test func packageImportRejectsAnyPreexistingCanonicalRowWithoutMutation() throws {
  let source = LedgerApplication(store: try makeApplicationStore())
  let exported = try source.exportPackage()
  let origin = String(repeating: "1", count: 64)
  let account = String(repeating: "2", count: 64)
  let category = String(repeating: "3", count: 64)
  let group = String(repeating: "4", count: 64)
  for sql in [
    "INSERT INTO ledger_origin VALUES ('\(origin)', 'standalone', NULL)",
    "INSERT INTO ledger_account_group VALUES ('\(group)', 'Synthetic', 0, 'active')",
    "INSERT INTO ledger_origin VALUES ('\(origin)', 'synthetic', NULL); INSERT INTO ledger_category VALUES ('\(category)', 'Synthetic', 'expense', '\(origin)', 'active'); INSERT INTO ledger_category_tree VALUES ('\(category)', NULL, 0, 0)",
    "INSERT INTO ledger_origin VALUES ('\(origin)', 'synthetic', NULL); INSERT INTO ledger_account VALUES ('\(account)', 'Synthetic', 'USD', '\(origin)', 'active'); INSERT INTO ledger_account_preferences VALUES ('\(account)', NULL, 0, 0, 1, 'standard')",
  ] {
    let store = try makeApplicationStore(seedSQL: sql)
    let before = try store.semanticChecksum()
    #expect(throws: LedgerApplication.Error.invalidCommand) {
      try LedgerApplication(store: store).importPackage(
        manifest: exported.manifest, payload: exported.payload)
    }
    #expect(try store.semanticChecksum() == before)
  }
}

@Test func repeatedPackageImportRejectsAfterPreferenceMutationWithoutMutation() throws {
  let source = LedgerApplication(store: try makeApplicationStore())
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: String(repeating: "2", count: 64), name: "Synthetic", currencyUnit: "USD", origin: origin)
  try source.createAccount(account)
  let exported = try source.exportPackage()

  var database: OpaquePointer?
  guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  for statement in CanonicalLedgerSchema.creationStatements {
    #expect(sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK)
  }
  #expect(
    sqlite3_exec(
      database,
      "PRAGMA application_id=\(CanonicalLedgerSchema.applicationID); INSERT INTO ledger_meta VALUES ('schema_version','\(CanonicalLedgerSchema.version)'), ('ledger_identity','ledger-atlas-canonical'), ('schema_fingerprint','\(CanonicalLedgerSchema.fingerprint)')",
      nil, nil, nil) == SQLITE_OK)
  let store = try LedgerStore(takingOwnershipOfValidatedCanonicalDatabase: database)
  let destination = LedgerApplication(store: store)
  try destination.importPackage(manifest: exported.manifest, payload: exported.payload)
  #expect(
    sqlite3_exec(
      database,
      "INSERT INTO ledger_account_preferences VALUES ('\(account.id)', NULL, 0, 1, 0, 'synthetic')",
      nil, nil, nil) == SQLITE_OK)
  let before = try store.semanticChecksum()
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try destination.importPackage(manifest: exported.manifest, payload: exported.payload)
  }
  #expect(try store.semanticChecksum() == before)
}

@Test func twelveMonthlyInstallmentsStartingJanuaryStayInTheSameYear() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let groceries = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Groceries", kind: .expense, origin: origin)
  try app.createCategory(groceries)
  let start = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2024, month: 1, day: 15)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let created = try app.createInstallmentPlan(
    LedgerInstallmentPlan(
      id: StableLedgerID.installmentPlan(
        origin: origin, localKey: String(repeating: "1", count: 64)),
      origin: origin, accountID: account.id, categoryID: groceries.id,
      principal: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("12.00")),
      occurrenceCount: 12),
    occurredAt: start, createdAt: UTCInstant(epochMilliseconds: 1))
  #expect(created.count == 12)
  let last = created[11].draft.occurredAt.localDateTime.date
  #expect(last.year == 2024)
  #expect(last.month == 12)
  #expect(last.day == 15)
}

@Test func monthlyIntervalElevenFromJanuaryLandsInDecemberSameYear() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let groceries = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Groceries", kind: .expense, origin: origin)
  try app.createCategory(groceries)
  let start = try SourceLocalDate(year: 2024, month: 1, day: 15)
  let rule = try LedgerRecurrenceRule(
    id: StableLedgerID.recurrenceRule(origin: origin, localKey: String(repeating: "2", count: 64)),
    origin: origin, accountID: account.id, categoryID: groceries.id, kind: .expense,
    amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("1.00")), frequency: .monthly,
    interval: 11, timeZone: SourceTimeZone(fixedOffsetSeconds: 0), start: start)
  try app.createRecurrence(rule)
  let created = try app.generateOccurrences(
    rule, through: SourceLocalDate(year: 2024, month: 12, day: 15),
    createdAt: UTCInstant(epochMilliseconds: 1))
  let next = try #require(created.dropFirst().first).draft.occurredAt.localDateTime.date
  #expect(next.year == 2024)
  #expect(next.month == 12)
  #expect(next.day == 15)
}

@Test func monthlyAdvanceFromJanuaryThirtyFirstClampsToFebruaryLastDay() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let groceries = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Groceries", kind: .expense, origin: origin)
  try app.createCategory(groceries)
  let start = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2024, month: 1, day: 31)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let created = try app.createInstallmentPlan(
    LedgerInstallmentPlan(
      id: StableLedgerID.installmentPlan(
        origin: origin, localKey: String(repeating: "1", count: 64)),
      origin: origin, accountID: account.id, categoryID: groceries.id,
      principal: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("3.00")), occurrenceCount: 3),
    occurredAt: start, createdAt: UTCInstant(epochMilliseconds: 1))
  let january = try SourceLocalDate(year: 2024, month: 1, day: 31)
  let february = try SourceLocalDate(year: 2024, month: 2, day: 29)
  let march = try SourceLocalDate(year: 2024, month: 3, day: 31)
  #expect(created[0].draft.occurredAt.localDateTime.date == january)
  #expect(created[1].draft.occurredAt.localDateTime.date == february)
  #expect(created[2].draft.occurredAt.localDateTime.date == march)
}

@Test func midPlanInstallmentErrorLeavesLedgerUnchanged() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("ledger.sqlite")
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
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
  sqlite3_close(database)
  #expect(chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

  var inserted = 0
  let store = try LedgerStore.openForMutation(at: url) { phase in
    guard phase == .afterInsertingTransaction else { return }
    inserted += 1
    if inserted >= 2 { throw LedgerStore.Error.incompatibleCanonicalStore }
  }
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let groceries = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Groceries", kind: .expense, origin: origin)
  try app.createCategory(groceries)
  let before = try app.checksum()
  let start = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 6, day: 1)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  do {
    _ = try app.createInstallmentPlan(
      LedgerInstallmentPlan(
        id: StableLedgerID.installmentPlan(
          origin: origin, localKey: String(repeating: "1", count: 64)),
        origin: origin, accountID: account.id, categoryID: groceries.id,
        principal: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("10.00")),
        occurrenceCount: 3),
      occurredAt: start, createdAt: UTCInstant(epochMilliseconds: 1))
    Issue.record("expected mid-plan installment insert to fail")
  } catch {
    #expect(error is LedgerApplication.Error || error is LedgerStore.Error)
  }
  #expect(inserted == 2)
  #expect(try app.checksum() == before)
  #expect(try app.snapshot().transactions.isEmpty)
  #expect(try app.snapshot().installmentPlans.isEmpty)
}

@Test func updateRecurrenceThisAndFuturePersistsAmountAndThisOccurrenceOnlySkips() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let category = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Bills", kind: .expense, origin: origin)
  try app.createCategory(category)
  let start = try SourceLocalDate(year: 2026, month: 4, day: 1)
  let skip = try SourceLocalDate(year: 2026, month: 5, day: 1)
  let zone = try SourceTimeZone(fixedOffsetSeconds: 0)
  let ruleID = try StableLedgerID.recurrenceRule(
    origin: origin, localKey: String(repeating: "2", count: 64))
  try app.createRecurrence(
    LedgerRecurrenceRule(
      id: ruleID, origin: origin, accountID: account.id, categoryID: category.id, kind: .expense,
      amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("2.00")), frequency: .monthly,
      interval: 1, timeZone: zone, start: start))

  let occurrenceEdit = try LedgerRecurrenceRule(
    id: ruleID, origin: origin, accountID: account.id, categoryID: category.id, kind: .expense,
    amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("9.00")), frequency: .weekly,
    interval: 1, timeZone: zone, start: start, skippedDates: [skip])
  try app.updateRecurrence(occurrenceEdit, scope: .thisOccurrence)
  let afterSkip = try #require(app.snapshot().recurrenceRules.first)
  #expect(afterSkip.amount.amount.rawLiteral == "2.00")
  #expect(afterSkip.frequency == .monthly)
  #expect(afterSkip.skippedDates == [skip])

  let futureEdit = try LedgerRecurrenceRule(
    id: ruleID, origin: origin, accountID: account.id, categoryID: category.id, kind: .expense,
    amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("5.50")), frequency: .weekly,
    interval: 2, dayOfMonth: nil, timeZone: zone, start: start, skippedDates: afterSkip.skippedDates
  )
  try app.updateRecurrence(futureEdit, scope: .thisAndFuture)
  let afterFuture = try #require(app.snapshot().recurrenceRules.first)
  #expect(afterFuture.amount.amount.rawLiteral == "5.50")
  #expect(afterFuture.frequency == .weekly)
  #expect(afterFuture.interval == 2)
  #expect(afterFuture.skippedDates == [skip])
}

@Test func recurrencePauseUpdatesTheSameRuleAndStopsGeneration() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let category = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Bills", kind: .expense, origin: origin)
  try app.createCategory(category)
  let start = try SourceLocalDate(year: 2026, month: 4, day: 1)
  var rule = try LedgerRecurrenceRule(
    id: StableLedgerID.recurrenceRule(origin: origin, localKey: String(repeating: "2", count: 64)),
    origin: origin, accountID: account.id, categoryID: category.id, kind: .expense,
    amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("2.00")), frequency: .monthly,
    interval: 1, timeZone: SourceTimeZone(fixedOffsetSeconds: 0), start: start)
  try app.createRecurrence(rule)
  let first = try app.generateOccurrences(
    rule, through: SourceLocalDate(year: 2026, month: 4, day: 1),
    createdAt: UTCInstant(epochMilliseconds: 1))
  #expect(first.count == 1)
  #expect(first[0].draft.sourceLiterals.contains { $0.field == "recurrence.ruleID" })
  rule = try LedgerRecurrenceRule(
    id: rule.id, origin: origin, accountID: account.id, categoryID: category.id, kind: .expense,
    amount: rule.amount, frequency: .monthly, interval: 1,
    timeZone: SourceTimeZone(fixedOffsetSeconds: 0), start: start, paused: true)
  try app.updateRecurrence(rule, scope: .thisAndFuture)
  let paused = try app.generateOccurrences(
    rule, through: SourceLocalDate(year: 2026, month: 6, day: 1),
    createdAt: UTCInstant(epochMilliseconds: 2))
  #expect(paused.isEmpty)
  #expect(try app.snapshot().recurrenceRules.contains { $0.id == rule.id && $0.paused })
}

@Test func exportImportRestoresRecurrenceBudgetAndInstallmentPlans() throws {
  let source = try makeApplicationStore()
  let app = LedgerApplication(store: source)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let category = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Bills", kind: .expense, origin: origin)
  try app.createCategory(category)
  let start = try SourceLocalDate(year: 2026, month: 4, day: 1)
  let until = try SourceLocalDate(year: 2026, month: 8, day: 1)
  let skipped = try SourceLocalDate(year: 2026, month: 5, day: 1)
  let zone = try SourceTimeZone(fixedOffsetSeconds: 19_800)
  let rule = try LedgerRecurrenceRule(
    id: StableLedgerID.recurrenceRule(origin: origin, localKey: String(repeating: "2", count: 64)),
    origin: origin, accountID: account.id, categoryID: category.id, kind: .expense,
    amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("2.50")), frequency: .monthly,
    interval: 1, dayOfMonth: 1, timeZone: zone, start: start, until: until, skippedDates: [skipped])
  try app.createRecurrence(rule)
  try app.createBudget(
    LedgerBudget(
      id: StableLedgerID.budget(origin: origin, localKey: String(repeating: "3", count: 64)),
      origin: origin, name: "Bills", categoryID: category.id,
      amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("40.00")), period: .monthly,
      rollover: true, start: start))
  let occurred = try SourceTemporal(
    resolving: SourceLocalDateTime(date: start), in: SourceTimeZone(fixedOffsetSeconds: 0),
    precision: .day)
  _ = try app.createInstallmentPlan(
    LedgerInstallmentPlan(
      id: StableLedgerID.installmentPlan(
        origin: origin, localKey: String(repeating: "4", count: 64)),
      origin: origin, accountID: account.id, categoryID: category.id,
      principal: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("9.00")), occurrenceCount: 2),
    occurredAt: occurred, createdAt: UTCInstant(epochMilliseconds: 1))
  let generated = try app.generateOccurrences(
    rule, through: SourceLocalDate(year: 2026, month: 6, day: 1),
    createdAt: UTCInstant(epochMilliseconds: 2))
  #expect(generated.map { $0.draft.occurredAt.localDateTime.date.month } == [4, 6])

  let exported = try app.exportPackage()
  let destination = LedgerApplication(store: try makeApplicationStore())
  try destination.importPackage(manifest: exported.manifest, payload: exported.payload)
  let restored = try destination.snapshot()
  // MACV2-11: catching up after a restore adds only the missing dates, exactly once.
  let caughtUp = try destination.generateOccurrences(
    rule, through: until, createdAt: UTCInstant(epochMilliseconds: 3))
  #expect(caughtUp.map { $0.draft.occurredAt.localDateTime.date.month } == [4, 6, 7, 8])
  #expect(caughtUp.prefix(2).map(\.id) == generated.map(\.id))
  let afterCatchUp = try destination.checksum()
  _ = try destination.generateOccurrences(
    rule, through: until, createdAt: UTCInstant(epochMilliseconds: 4))
  #expect(try destination.checksum() == afterCatchUp)
  let restoredRule = try #require(restored.recurrenceRules.first)
  #expect(restoredRule.id == rule.id)
  #expect(restoredRule.amount.amount.rawLiteral == "2.50")
  #expect(restoredRule.until == until)
  #expect(restoredRule.skippedDates == [skipped])
  #expect(restoredRule.timeZone == zone)
  #expect(restoredRule.dayOfMonth == 1)
  let restoredBudget = try #require(restored.budgets.first)
  #expect(restoredBudget.amount.amount.rawLiteral == "40.00")
  #expect(restoredBudget.rollover)
  let restoredPlan = try #require(restored.installmentPlans.first)
  #expect(restoredPlan.principal.amount.rawLiteral == "9.00")
  #expect(restoredPlan.occurrenceCount == 2)
}

@Test func exportImportTwoCyclesRestoreMoneyTimeLinksAndTombstones() throws {
  let source = try makeApplicationStore()
  let app = LedgerApplication(store: source)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 5, day: 6)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let draft = try LedgerTransactionDraft(
    effects: [
      try LedgerTransactionEffect(
        accountID: account.id, direction: .increase,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("7.50")))
    ], categoryID: nil, kind: .income, occurredAt: when, origin: origin)
  let created = try app.createTransaction(
    idempotencyKey: String(repeating: "b", count: 64), draft: draft,
    createdAt: UTCInstant(epochMilliseconds: 1))
  _ = try app.tombstoneTransaction(
    transactionID: created.transactionID, expectedCurrentRevisionID: created.id,
    createdAt: UTCInstant(epochMilliseconds: 2))
  let first = try app.exportPackage()
  let destination = LedgerApplication(store: try makeApplicationStore())
  try destination.importPackage(manifest: first.manifest, payload: first.payload)
  let restored = try destination.snapshot()
  #expect(restored.accounts.map(\.id) == [account.id])
  #expect(restored.transactions.count == 1)
  #expect(restored.transactions[0].currentRevision.lifecycle == .tombstoned)
  #expect(
    restored.transactions[0].currentRevision.draft.effects[0].amount.amount.rawLiteral == "7.50")
  #expect(restored.transactions[0].currentRevision.draft.occurredAt.localDateTime.date.day == 6)
  #expect(restored.revisionHistory.count == 2)
  let second = try destination.exportPackage()
  #expect(second.manifest.payloadSHA256 == first.manifest.payloadSHA256)
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try destination.importPackage(manifest: second.manifest, payload: second.payload)
  }
}

@Test func iosFacingAdapterMatchesMacApplicationOnProductCommands() throws {
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let cash = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  let savings = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "b", count: 64)),
    name: "Savings", currencyUnit: "USD", origin: origin)
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 1, day: 2)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let amount = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("3.00"))

  func exercise(_ client: some LedgerClient) throws -> String {
    try client.createAccount(cash)
    try client.createAccount(savings)
    let groceries = try LedgerCategory(
      id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
      name: "Groceries", kind: .expense, origin: origin)
    try client.createCategory(groceries)
    let transfer = try client.createTransfer(
      idempotencyKey: String(repeating: "e", count: 64), sourceAccountID: cash.id,
      destinationAccountID: savings.id, sourceAmount: amount, destinationAmount: amount,
      conversion: nil, fee: nil, feeAccountID: nil, occurredAt: when, origin: origin,
      createdAt: UTCInstant(epochMilliseconds: 1))
    _ = try client.createSplit(
      idempotencyKey: String(repeating: "f", count: 64), accountID: cash.id,
      parentAmount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("4.00")),
      components: [
        (try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("1.50")), groceries.id),
        (try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("2.50")), groceries.id),
      ], occurredAt: when, origin: origin, createdAt: UTCInstant(epochMilliseconds: 2))
    _ = try client.createInstallmentPlan(
      LedgerInstallmentPlan(
        id: StableLedgerID.installmentPlan(
          origin: origin, localKey: String(repeating: "1", count: 64)),
        origin: origin, accountID: cash.id, categoryID: groceries.id,
        principal: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("6.00")),
        occurrenceCount: 2),
      occurredAt: when, createdAt: UTCInstant(epochMilliseconds: 3))
    try client.createRecurrence(
      LedgerRecurrenceRule(
        id: StableLedgerID.recurrenceRule(
          origin: origin, localKey: String(repeating: "2", count: 64)),
        origin: origin, accountID: cash.id, categoryID: groceries.id, kind: .expense,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("1.00")), frequency: .monthly,
        interval: 1, timeZone: SourceTimeZone(fixedOffsetSeconds: 0),
        start: SourceLocalDate(year: 2026, month: 1, day: 2)))
    try client.createBudget(
      LedgerBudget(
        id: StableLedgerID.budget(origin: origin, localKey: String(repeating: "3", count: 64)),
        origin: origin, name: "Food", categoryID: groceries.id,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("30.00")), period: .monthly,
        rollover: false, start: SourceLocalDate(year: 2026, month: 1, day: 1)))
    let found = try client.search(LedgerSearchQuery(kind: .expense))
    let report = try client.report(unitCode: "USD")
    let projection = try client.makeProjection(unitCode: "USD")
    let exported = try client.exportPackage()
    return [
      transfer.transfer.id, exported.manifest.payloadSHA256, try client.checksum(),
      String(found.count), report.accessibleTable, projection.report.accessibleTable,
      projection.report.inventory.first { $0.id == "budgets" }.map { String($0.count) } ?? "0",
    ].joined(separator: "|")
  }

  let mac = LedgerApplication(store: try makeApplicationStore())
  let ios = IOSFacingLedgerClient(store: try makeApplicationStore())
  #expect(try exercise(mac) == exercise(ios))
}

@Test func midRestoreProductErrorLeavesDestinationUnchanged() throws {
  let source = try makeApplicationStore()
  let app = LedgerApplication(store: source)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let category = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Bills", kind: .expense, origin: origin)
  try app.createCategory(category)
  try app.createBudget(
    LedgerBudget(
      id: StableLedgerID.budget(origin: origin, localKey: String(repeating: "3", count: 64)),
      origin: origin, name: "Bills", categoryID: category.id,
      amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("20.00")), period: .monthly,
      rollover: false, start: SourceLocalDate(year: 2026, month: 1, day: 1)))
  let exported = try app.exportPackage()

  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("restore.sqlite")
  try writeEmptyCanonicalFile(to: url)
  let dest = try LedgerStore.openForMutation(at: url) { phase in
    if phase == .afterApplyingExportCore { throw LedgerStore.Error.incompatibleCanonicalStore }
  }
  let destination = LedgerApplication(store: dest)
  let before = try destination.checksum()
  do {
    try destination.importPackage(manifest: exported.manifest, payload: exported.payload)
    Issue.record("expected mid-restore product write to fail")
  } catch {
    #expect(error is LedgerApplication.Error || error is LedgerStore.Error)
  }
  #expect(try destination.checksum() == before)
  #expect(try destination.snapshot().accounts.isEmpty)
  #expect(try destination.snapshot().budgets.isEmpty)
  #expect(try destination.snapshot().transactions.isEmpty)
}

@Test func exportImportTwoCyclesPreserveLinksMoneyAndProductCollections() throws {
  let source = try makeApplicationStore()
  let app = LedgerApplication(store: source)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let cash = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(cash)
  let groceries = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Groceries", kind: .expense, origin: origin)
  let fuel = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "d", count: 64)),
    name: "Fuel", kind: .expense, origin: origin)
  try app.createCategory(groceries)
  try app.createCategory(fuel)
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 7, day: 8)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let split = try app.createSplit(
    idempotencyKey: String(repeating: "f", count: 64), accountID: cash.id,
    parentAmount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("5.00")),
    components: [
      (try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("2.00")), groceries.id),
      (try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("3.00")), fuel.id),
    ], occurredAt: when, origin: origin, createdAt: UTCInstant(epochMilliseconds: 1))
  try app.createBudget(
    LedgerBudget(
      id: StableLedgerID.budget(origin: origin, localKey: String(repeating: "3", count: 64)),
      origin: origin, name: "Food", categoryID: groceries.id,
      amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("40.00")), period: .monthly,
      rollover: true, start: SourceLocalDate(year: 2026, month: 7, day: 1)))
  try app.createRecurrence(
    LedgerRecurrenceRule(
      id: StableLedgerID.recurrenceRule(
        origin: origin, localKey: String(repeating: "2", count: 64)),
      origin: origin, accountID: cash.id, categoryID: groceries.id, kind: .expense,
      amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("1.25")), frequency: .monthly,
      interval: 1, timeZone: SourceTimeZone(fixedOffsetSeconds: 0),
      start: SourceLocalDate(year: 2026, month: 7, day: 1)))

  let first = try app.exportPackage()
  let destination = LedgerApplication(store: try makeApplicationStore())
  try destination.importPackage(manifest: first.manifest, payload: first.payload)
  let restored = try destination.snapshot()
  #expect(restored.transactions.count == 2)
  #expect(Set(restored.transactions.flatMap(\.links).map(\.kind)) == [.split])
  #expect(Set(restored.transactions.flatMap(\.links).map(\.id)).count == 1)
  #expect(
    restored.transactions.map { $0.currentRevision.draft.effects[0].amount.amount.rawLiteral }
      .sorted() == ["2.00", "3.00"])
  #expect(restored.budgets.first?.amount.amount.rawLiteral == "40.00")
  #expect(restored.recurrenceRules.first?.amount.amount.rawLiteral == "1.25")
  #expect(Set(split.map(\.transactionID)) == Set(restored.transactions.map(\.id)))
  let second = try destination.exportPackage()
  #expect(second.manifest.payloadSHA256 == first.manifest.payloadSHA256)
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try destination.importPackage(manifest: second.manifest, payload: second.payload)
  }
}

@Test func unknownPackageDirectionLeavesEmptyDestinationUnchanged() throws {
  let source = try makeApplicationStore()
  let app = LedgerApplication(store: source)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 5, day: 6)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let draft = try LedgerTransactionDraft(
    effects: [
      try LedgerTransactionEffect(
        accountID: account.id, direction: .decrease,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("2.00")))
    ], categoryID: nil, kind: .expense, occurredAt: when, origin: origin)
  _ = try app.createTransaction(
    idempotencyKey: String(repeating: "b", count: 64), draft: draft,
    createdAt: UTCInstant(epochMilliseconds: 1))
  let exported = try app.exportPackage()
  guard var object = try JSONSerialization.jsonObject(with: exported.payload) as? [String: Any],
    var revisions = object["revisions"] as? [[String: Any]],
    !revisions.isEmpty,
    var effects = revisions[0]["effects"] as? [[String: Any]],
    !effects.isEmpty
  else {
    Issue.record("expected exported package revisions with effects")
    return
  }
  effects[0]["direction"] = "not-a-direction"
  revisions[0]["effects"] = effects
  object["revisions"] = revisions
  let hostile = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  let digest = SHA256.hash(data: hostile).map { String(format: "%02x", $0) }.joined()
  let manifest = LedgerExportManifest(
    schemaVersion: exported.manifest.schemaVersion,
    schemaFingerprint: exported.manifest.schemaFingerprint, payloadSHA256: digest,
    createdAtMilliseconds: exported.manifest.createdAtMilliseconds)
  let destination = LedgerApplication(store: try makeApplicationStore())
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try destination.importPackage(manifest: manifest, payload: hostile)
  }
  #expect(try destination.snapshot().accounts.isEmpty)
  #expect(try destination.snapshot().transactions.isEmpty)
  #expect(try destination.snapshot().categories.isEmpty)
}

@Test func hostilePackageRowsNumbersAndSchemaLeaveDestinationUnchanged() throws {
  let app = LedgerApplication(store: try makeApplicationStore())
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let date = try SourceLocalDate(year: 2026, month: 5, day: 6)
  let zone = try SourceTimeZone(fixedOffsetSeconds: 0)
  let occurredAt = try SourceTemporal(
    resolving: SourceLocalDateTime(date: date), in: zone, precision: .day)
  _ = try app.createTransaction(
    idempotencyKey: String(repeating: "b", count: 64),
    draft: LedgerTransactionDraft(
      effects: [
        try LedgerTransactionEffect(
          accountID: account.id, direction: .decrease,
          amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("2.00")))
      ], categoryID: nil, kind: .expense, occurredAt: occurredAt, origin: origin),
    createdAt: UTCInstant(epochMilliseconds: 1))
  try app.createRecurrence(
    LedgerRecurrenceRule(
      id: StableLedgerID.recurrenceRule(
        origin: origin, localKey: String(repeating: "c", count: 64)),
      origin: origin, accountID: account.id, categoryID: nil, kind: .expense,
      amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("2.00")),
      frequency: .monthly, interval: 1, dayOfMonth: 6, timeZone: zone, start: date))
  let exported = try app.exportPackage()
  let base = try #require(
    JSONSerialization.jsonObject(with: exported.payload) as? [String: Any])

  func expectRejected(_ object: [String: Any]) throws {
    let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try expectRejected(payload)
  }

  func expectRejected(_ payload: Data) throws {
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let manifest = LedgerExportManifest(
      schemaVersion: exported.manifest.schemaVersion,
      schemaFingerprint: exported.manifest.schemaFingerprint, payloadSHA256: digest,
      createdAtMilliseconds: exported.manifest.createdAtMilliseconds)
    let destination = LedgerApplication(store: try makeApplicationStore())
    #expect(throws: LedgerApplication.Error.invalidCommand) {
      try destination.importPackage(manifest: manifest, payload: payload)
    }
    let snapshot = try destination.snapshot()
    #expect(snapshot.accounts.isEmpty)
    #expect(snapshot.transactions.isEmpty)
    #expect(snapshot.recurrenceRules.isEmpty)
  }

  var malformedAccount = base
  malformedAccount["accounts"] = [[:]]
  try expectRejected(malformedAccount)

  var unknownTopLevel = base
  unknownTopLevel["attachments"] = [["name": "synthetic", "data": "AA=="]]
  try expectRejected(unknownTopLevel)

  var duplicateGroups = base
  let duplicateGroup: [String: Any] = [
    "id": String(repeating: "g", count: 64), "name": "Synthetic", "displayOrder": 0,
    "lifecycle": "active",
  ]
  duplicateGroups["accountGroups"] = [duplicateGroup, duplicateGroup]
  try expectRejected(duplicateGroups)

  var unknownNested = base
  var unknownAccounts = try #require(unknownNested["accounts"] as? [[String: Any]])
  unknownAccounts[0]["futureField"] = "synthetic"
  unknownNested["accounts"] = unknownAccounts
  try expectRejected(unknownNested)

  let duplicateKey = try #require(String(data: exported.payload, encoding: .utf8))
    .replacingOccurrences(
      of: "\"formatVersion\":\(exported.manifest.formatVersion)",
      with:
        "\"formatVersion\":\(exported.manifest.formatVersion),\"formatVersion\":\(exported.manifest.formatVersion)",
      options: [], range: nil)
  try expectRejected(Data(duplicateKey.utf8))

  for invalidRevision in [1.5, true, 1e100] as [Any] {
    var malformedNumber = base
    var revisions = try #require(malformedNumber["revisions"] as? [[String: Any]])
    revisions[0]["revision"] = invalidRevision
    malformedNumber["revisions"] = revisions
    try expectRejected(malformedNumber)
  }

  var malformedEffects = base
  var effectRevisions = try #require(malformedEffects["revisions"] as? [[String: Any]])
  effectRevisions[0]["effects"] = "not-an-array"
  malformedEffects["revisions"] = effectRevisions
  try expectRejected(malformedEffects)

  var missingOptional = base
  var missingOptionalRevisions = try #require(
    missingOptional["revisions"] as? [[String: Any]])
  missingOptionalRevisions[0].removeValue(forKey: "roundingPolicy")
  missingOptional["revisions"] = missingOptionalRevisions
  try expectRejected(missingOptional)

  var malformedOptionalInteger = base
  var recurrence = try #require(
    malformedOptionalInteger["recurrenceRules"] as? [[String: Any]])
  recurrence[0]["dayOfMonth"] = "not-an-integer"
  malformedOptionalInteger["recurrenceRules"] = recurrence
  try expectRejected(malformedOptionalInteger)

  var missingOptionalInteger = base
  var missingIntegerRecurrence = try #require(
    missingOptionalInteger["recurrenceRules"] as? [[String: Any]])
  missingIntegerRecurrence[0].removeValue(forKey: "dayOfMonth")
  missingOptionalInteger["recurrenceRules"] = missingIntegerRecurrence
  try expectRejected(missingOptionalInteger)

  var malformedBoolean = base
  var booleanRecurrence = try #require(
    malformedBoolean["recurrenceRules"] as? [[String: Any]])
  booleanRecurrence[0]["paused"] = 1
  malformedBoolean["recurrenceRules"] = booleanRecurrence
  try expectRejected(malformedBoolean)

  var duplicateRule = base
  var duplicateRules = try #require(duplicateRule["recurrenceRules"] as? [[String: Any]])
  duplicateRules.append(duplicateRules[0])
  duplicateRule["recurrenceRules"] = duplicateRules
  try expectRejected(duplicateRule)

  var conflictingOrigin = base
  var conflictingAccounts = try #require(conflictingOrigin["accounts"] as? [[String: Any]])
  var secondAccount = conflictingAccounts[0]
  secondAccount["id"] = String(repeating: "d", count: 64)
  secondAccount["originLabel"] = "conflicting-label"
  conflictingAccounts.append(secondAccount)
  conflictingOrigin["accounts"] = conflictingAccounts
  try expectRejected(conflictingOrigin)

  var mismatchedVersion = base
  mismatchedVersion["formatVersion"] = exported.manifest.formatVersion + 1
  try expectRejected(mismatchedVersion)

  var mismatchedFingerprint = base
  mismatchedFingerprint["formatFingerprint"] = String(repeating: "0", count: 64)
  try expectRejected(mismatchedFingerprint)

  let excessiveNesting = Data(
    (String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)).utf8)
  try expectRejected(excessiveNesting)

  let oversizedKey = Data(
    ("{\"" + String(repeating: "k", count: 1_024 * 1_024 + 1) + "\":0}").utf8)
  try expectRejected(oversizedKey)

  try expectRejected(Data(repeating: 0x20, count: 64 * 1_024 * 1_024 + 1))
}

@Test func semanticChecksumChangesWhenFinancialContentChanges() throws {
  func checksum(amount: String) throws -> String {
    let application = LedgerApplication(store: try makeApplicationStore())
    let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
    let account = try LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
      name: "Cash", currencyUnit: "USD", origin: origin)
    try application.createAccount(account)
    let occurredAt = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 5, day: 6)),
      in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
    _ = try application.createTransaction(
      idempotencyKey: String(repeating: "b", count: 64),
      draft: LedgerTransactionDraft(
        effects: [
          try LedgerTransactionEffect(
            accountID: account.id, direction: .decrease,
            amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal(amount)))
        ], categoryID: nil, kind: .expense, occurredAt: occurredAt, origin: origin),
      createdAt: UTCInstant(epochMilliseconds: 1))
    return try application.checksum()
  }

  #expect(try checksum(amount: "1.00") != checksum(amount: "2.00"))
}

@Test func strippedImportGraphStillBlocksPortableExport() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("ledger.sqlite")
  try writeEmptyCanonicalFile(to: url)
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  let accountID = String(repeating: "d", count: 64)
  let artifactID = String(repeating: "a", count: 64)
  let receiptID = CanonicalStagingID.stage(
    artifactSHA256: artifactID, profileID: "synthetic-profile",
    adapterVersion: "synthetic-adapter-v1")
  let sourceRecordID = CanonicalStagingID.record(
    stagingID: receiptID, table: "INOUTCOME", recordKey: "event")
  let eventID = try StableCanonicalID.event(sourceRecordID: sourceRecordID, effectOrdinal: 0)
  let bindingIDs = (0..<5).map { (index: Int) in
    CanonicalStagingID.field(
      stagingID: receiptID,
      locator: SourceLocator(
        table: "INOUTCOME", recordKey: "event", columnOrdinal: index,
        columnName: "c\(index)"))
  }
  let provenanceID = bindingIDs[0]
  let provenanceRows = bindingIDs.enumerated().map { index, id in
    "INSERT INTO provenance_reference VALUES ('\(id)', '\(artifactID)', 'synthetic-profile', 'synthetic-adapter-v1', NULL, 'INOUTCOME', 'event', \(index), 'c\(index)')"
  }.joined(separator: ";")
  let bindings = zip(["amount", "currency", "occurred_at", "account", "kind"], bindingIDs)
    .map { semantic, id in
      "INSERT INTO event_source_binding VALUES ('\(eventID)', '\(semantic)', '\(id)', 'TEXT', 'text'); INSERT INTO receipt_binding VALUES ('\(receiptID)', '\(eventID)', '\(semantic)', '\(id)')"
    }.joined(separator: ";")
  var eventComponents = [
    CanonicalReceiptDigest.eventSetPrefix, eventID, accountID, "adjustment", "1.00", "USD",
    "0", "1970", "1", "1", "0", "0", "0", "0", "fixed", "0", "millisecond", "0",
    sourceRecordID, provenanceID,
  ]
  for (semantic, id) in zip(
    ["amount", "currency", "occurred_at", "account", "kind"], bindingIDs
  ).sorted(by: { $0.0 < $1.0 }) {
    eventComponents.append(contentsOf: [semantic, id, "optional:some", "TEXT", "text"])
  }
  let eventSetHash = CanonicalReceiptDigest.hash(eventComponents)
  let preservationHash = CanonicalReceiptDigest.hash([
    "ledger-atlas/receipt-owned-preservation-set/v4"
  ])
  let reconciliationHash = CanonicalReceiptDigest.hash([
    "ledger-atlas/canonical-receipt-integrity/v6", receiptID, artifactID, artifactID,
    "synthetic-profile", "synthetic-adapter-v1", eventSetHash, "1", "8", eventSetHash,
    preservationHash,
  ])
  let insert = """
    \(provenanceRows);
    INSERT INTO economic_event(
      event_id, account_id, event_kind, amount_literal, currency_unit,
      instant_milliseconds, local_year, local_month, local_day, local_hour, local_minute,
      local_second, local_millisecond, timezone_kind, timezone_value, temporal_precision,
      resolved_offset_seconds, source_record_id, provenance_id
    ) VALUES (
      '\(eventID)', '\(accountID)', 'adjustment', '1.00', 'USD',
      0, 1970, 1, 1, 0, 0, 0, 0, 'fixed', '0', 'millisecond',
      0, '\(sourceRecordID)', '\(provenanceID)'
    );
    INSERT INTO import_receipt VALUES ('\(receiptID)', '\(artifactID)', '\(artifactID)', 'synthetic-profile', 'synthetic-adapter-v1', '\(reconciliationHash)', '\(eventSetHash)', 1, 8);
    INSERT INTO receipt_event VALUES ('\(receiptID)', '\(eventID)');
    \(bindings);
    """
  guard sqlite3_exec(database, insert, nil, nil, nil) == SQLITE_OK else {
    sqlite3_close(database)
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  sqlite3_close(database)

  var store: LedgerStore? = try LedgerStore.openForMutation(at: url)
  try store?.materializeImportedEvents()
  store = nil

  var strippedDatabase: OpaquePointer?
  guard sqlite3_open(url.path, &strippedDatabase) == SQLITE_OK, let strippedDatabase else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  guard
    sqlite3_exec(
      strippedDatabase, "DELETE FROM economic_event; DELETE FROM provenance_reference;", nil, nil,
      nil)
      == SQLITE_OK
  else {
    sqlite3_close(strippedDatabase)
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  sqlite3_close(strippedDatabase)

  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try LedgerStore.openForMutation(at: url)
  }
}

@Test func portableExportUsesOneReadTransactionWhenAnotherConnectionWrites() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("ledger.sqlite")
  try writeEmptyCanonicalFile(to: url)
  let writer = ConcurrentSQLiteCommit()
  defer { if let database = writer.database { sqlite3_close(database) } }
  let store = try LedgerStore.openForMutation(at: url) { phase in
    guard phase == .afterPortableExportSnapshotRead, writer.database == nil else { return }
    guard sqlite3_open(url.path, &writer.database) == SQLITE_OK, let database = writer.database,
      sqlite3_busy_timeout(database, 100) == SQLITE_OK,
      sqlite3_exec(
        database, "BEGIN IMMEDIATE; UPDATE ledger_category SET name='Later'", nil, nil, nil)
        == SQLITE_OK
    else { throw LedgerStore.Error.incompatibleCanonicalStore }
    Thread {
      writer.result = sqlite3_exec(writer.database, "COMMIT", nil, nil, nil)
      writer.finished.signal()
    }.start()
    #expect(writer.finished.wait(timeout: .now() + .seconds(5)) == .success)
    #expect(writer.result == SQLITE_BUSY)
    #expect(sqlite3_exec(writer.database, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
  }
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Before", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let category = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "b", count: 64)),
    name: "Category Before", kind: .expense, origin: origin)
  try app.createCategory(category)

  let exported = try app.exportPackage()
  #expect(String(data: exported.payload, encoding: .utf8)?.contains("Category Before") == true)
  #expect(
    sqlite3_exec(
      writer.database, "BEGIN IMMEDIATE; UPDATE ledger_category SET name='Later'; COMMIT", nil,
      nil, nil) == SQLITE_OK)
  let current = try app.snapshot().categories
  #expect(current.count == 1)
  #expect(current.first?.name == "Later")
}

@Test func ordinarySnapshotUsesOneReadTransactionWhenAnotherConnectionWrites() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("ledger.sqlite")
  try writeEmptyCanonicalFile(to: url)
  let writer = ConcurrentSQLiteCommit()
  defer { if let database = writer.database { sqlite3_close(database) } }
  let store = try LedgerStore.openForMutation(at: url) { phase in
    guard phase == .afterReadSnapshotCoreRead, writer.database == nil else { return }
    guard sqlite3_open(url.path, &writer.database) == SQLITE_OK, let database = writer.database,
      sqlite3_busy_timeout(database, 100) == SQLITE_OK,
      sqlite3_exec(
        database, "BEGIN IMMEDIATE; UPDATE ledger_category SET name='Later'", nil, nil, nil)
        == SQLITE_OK
    else { throw LedgerStore.Error.incompatibleCanonicalStore }
    Thread {
      writer.result = sqlite3_exec(writer.database, "COMMIT", nil, nil, nil)
      writer.finished.signal()
    }.start()
    #expect(writer.finished.wait(timeout: .now() + .seconds(5)) == .success)
    #expect(writer.result == SQLITE_BUSY)
    #expect(sqlite3_exec(writer.database, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
  }
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  try app.createAccount(
    LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
      name: "Before", currencyUnit: "USD", origin: origin))
  try app.createCategory(
    LedgerCategory(
      id: StableLedgerID.category(origin: origin, localKey: String(repeating: "b", count: 64)),
      name: "Category Before", kind: .expense, origin: origin))

  let snapshot = try app.snapshot()
  #expect(snapshot.categories.first?.name == "Category Before")
  #expect(
    sqlite3_exec(
      writer.database, "BEGIN IMMEDIATE; UPDATE ledger_category SET name='Later'; COMMIT", nil,
      nil, nil) == SQLITE_OK)
  #expect(try app.snapshot().categories.first?.name == "Later")
}

private final class ConcurrentSQLiteCommit: @unchecked Sendable {
  var database: OpaquePointer?
  var result = SQLITE_OK
  let finished = DispatchSemaphore(value: 0)
}

@Test func malformedPreservedSourceLeavesEmptyDestinationUnchanged() throws {
  let exported = try LedgerApplication(store: makeApplicationStore()).exportPackage()
  guard var object = try JSONSerialization.jsonObject(with: exported.payload) as? [String: Any]
  else {
    Issue.record("expected exported package object")
    return
  }
  object["preservedSource"] = [
    [
      "table": "INOUTCOME", "recordKey": "record", "columnName": "NOTE",
      "storageClass": "text", "payload": "not-base64", "reasonCode": "preserved",
    ]
  ]
  let hostile = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  let digest = SHA256.hash(data: hostile).map { String(format: "%02x", $0) }.joined()
  let manifest = LedgerExportManifest(
    schemaVersion: exported.manifest.schemaVersion,
    schemaFingerprint: exported.manifest.schemaFingerprint, payloadSHA256: digest,
    createdAtMilliseconds: exported.manifest.createdAtMilliseconds)
  let destination = LedgerApplication(store: try makeApplicationStore())

  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try destination.importPackage(manifest: manifest, payload: hostile)
  }
  #expect(try destination.snapshot().accounts.isEmpty)
  #expect(try destination.snapshot().transactions.isEmpty)
  #expect(try destination.snapshot().categories.isEmpty)
}

@Test func wrongPreservedSourceShapeLeavesEmptyDestinationUnchanged() throws {
  let exported = try LedgerApplication(store: makeApplicationStore()).exportPackage()
  guard var object = try JSONSerialization.jsonObject(with: exported.payload) as? [String: Any]
  else {
    Issue.record("expected exported package object")
    return
  }
  object["preservedSource"] = "not-an-array"
  let hostile = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  let digest = SHA256.hash(data: hostile).map { String(format: "%02x", $0) }.joined()
  let manifest = LedgerExportManifest(
    schemaVersion: exported.manifest.schemaVersion,
    schemaFingerprint: exported.manifest.schemaFingerprint, payloadSHA256: digest,
    createdAtMilliseconds: exported.manifest.createdAtMilliseconds)
  let destination = LedgerApplication(store: try makeApplicationStore())

  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try destination.importPackage(manifest: manifest, payload: hostile)
  }
  #expect(try destination.snapshot().accounts.isEmpty)
}

@Test func malformedLegacyPreservationMetadataBlocksExport() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("ledger.sqlite")
  try writeEmptyCanonicalFile(to: url)
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  guard
    sqlite3_exec(
      database,
      "INSERT INTO ledger_meta(key,value) VALUES('source_preservation_v1','{}')", nil, nil, nil)
      == SQLITE_OK
  else {
    sqlite3_close(database)
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  sqlite3_close(database)
  let application = LedgerApplication(store: try LedgerStore.openForMutation(at: url))

  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    _ = try application.exportPackage()
  }
}

@Test func importPackageRefusesCategoryOnlyDestination() throws {
  let source = try makeApplicationStore()
  let app = LedgerApplication(store: source)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let exported = try app.exportPackage()

  let destination = LedgerApplication(store: try makeApplicationStore())
  let destOrigin = try LedgerOrigin(id: String(repeating: "2", count: 64), label: "local")
  let existing = try LedgerCategory(
    id: StableLedgerID.category(origin: destOrigin, localKey: String(repeating: "c", count: 64)),
    name: "Existing", kind: .expense, origin: destOrigin)
  try destination.createCategory(existing)
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try destination.importPackage(manifest: exported.manifest, payload: exported.payload)
  }
  let snapshot = try destination.snapshot()
  #expect(snapshot.categories.map(\.id) == [existing.id])
  #expect(snapshot.accounts.isEmpty)
  #expect(snapshot.transactions.isEmpty)
}

@Test func applyExportRefusesCategoryOnlyDestination() throws {
  let destStore = try makeApplicationStore()
  let destination = LedgerApplication(store: destStore)
  let origin = try LedgerOrigin(id: String(repeating: "2", count: 64), label: "local")
  let existing = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Existing", kind: .expense, origin: origin)
  try destination.createCategory(existing)
  let empty = LedgerCanonicalPackage(
    schemaVersion: destStore.schemaIdentity.version,
    schemaFingerprint: destStore.schemaIdentity.fingerprint, accounts: [], categories: [],
    revisions: [], links: [], recurrenceRules: [], budgets: [], installmentPlans: [])
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try destStore.applyExport(empty)
  }
  #expect(try destination.snapshot().categories.map(\.id) == [existing.id])
}

private func writeEmptyCanonicalFile(to url: URL) throws {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  defer { sqlite3_close(database) }
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
  #expect(chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
}

@Test func searchFiltersByAccountDateAmountCategoryMemoTagStatusAndCorrectionHistory() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let cash = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  let savings = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "b", count: 64)),
    name: "Savings", currencyUnit: "USD", origin: origin)
  try app.createAccount(cash)
  try app.createAccount(savings)
  let groceries = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Groceries", kind: .expense, origin: origin)
  let fuel = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "d", count: 64)),
    name: "Fuel", kind: .expense, origin: origin)
  try app.createCategory(groceries)
  try app.createCategory(fuel)

  let january = try app.createTransaction(
    idempotencyKey: String(repeating: "e", count: 64),
    draft: try expenseDraft(
      accountID: cash.id, categoryID: groceries.id, origin: origin, amount: "1.00",
      note: "alpha-memo", tag: "rent", year: 2026, month: 1, day: 15),
    createdAt: UTCInstant(epochMilliseconds: 1))
  let february = try app.createTransaction(
    idempotencyKey: String(repeating: "f", count: 64),
    draft: try expenseDraft(
      accountID: cash.id, categoryID: fuel.id, origin: origin, amount: "5.00",
      note: "beta-memo", tag: "fuel", year: 2026, month: 2, day: 15),
    createdAt: UTCInstant(epochMilliseconds: 2))
  let march = try app.createTransaction(
    idempotencyKey: String(repeating: "0", count: 64),
    draft: try expenseDraft(
      accountID: savings.id, categoryID: groceries.id, origin: origin, amount: "2.00",
      note: "gamma-memo", tag: "misc", year: 2026, month: 3, day: 15),
    createdAt: UTCInstant(epochMilliseconds: 3))

  let correctedFebruary = try LedgerTransactionDraft(
    effects: [
      try LedgerTransactionEffect(
        accountID: cash.id, direction: .decrease,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("5.50")))
    ], categoryID: fuel.id, kind: .expense,
    occurredAt: february.draft.occurredAt, note: "beta-memo",
    sourceLiterals: [try LedgerSourceLiteral(field: "tag", literal: "fuel")], origin: origin)
  _ = try app.correctTransaction(
    transactionID: february.transactionID, expectedCurrentRevisionID: february.id,
    draft: correctedFebruary, createdAt: UTCInstant(epochMilliseconds: 4))
  _ = try app.tombstoneTransaction(
    transactionID: march.transactionID, expectedCurrentRevisionID: march.id,
    createdAt: UTCInstant(epochMilliseconds: 5))

  let januaryOnly = try app.search(
    LedgerSearchQuery(
      occurredOnOrAfter: SourceLocalDate(year: 2026, month: 1, day: 1),
      occurredOnOrBefore: SourceLocalDate(year: 2026, month: 1, day: 31)))
  #expect(januaryOnly.map(\.id) == [january.transactionID])

  let large = try app.search(
    LedgerSearchQuery(minimumAmount: ExactDecimal("4.00"), unitCode: "USD"))
  #expect(large.map(\.id) == [february.transactionID])

  let groceriesActive = try app.search(LedgerSearchQuery(categoryID: groceries.id))
  #expect(groceriesActive.map(\.id) == [january.transactionID])

  let memo = try app.search(LedgerSearchQuery(noteContains: "alpha"))
  #expect(memo.map(\.id) == [january.transactionID])

  let tagged = try app.search(LedgerSearchQuery(tagContains: "fuel"))
  #expect(tagged.map(\.id) == [february.transactionID])

  let savingsAccount = try app.search(
    LedgerSearchQuery(accountID: savings.id, includeTombstones: true))
  #expect(savingsAccount.map(\.id) == [march.transactionID])

  let tombstones = try app.search(
    LedgerSearchQuery(lifecycle: .tombstoned, includeTombstones: true))
  #expect(tombstones.map(\.id) == [march.transactionID])

  let corrected = try app.search(LedgerSearchQuery(hasCorrections: true))
  #expect(corrected.map(\.id) == [february.transactionID])

  let uncorrected = try app.search(LedgerSearchQuery(hasCorrections: false))
  #expect(uncorrected.map(\.id) == [january.transactionID])

  let text = try app.search(LedgerSearchQuery(textContains: "beta"))
  #expect(text.map(\.id) == [february.transactionID])
}

@Test func reportInventoryReconcilesToCanonicalEventsAndProjectionRebuildLeavesChecksum() throws {
  let store = try makeApplicationStore()
  let app = LedgerApplication(store: store)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let usd = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "USD Cash", currencyUnit: "USD", origin: origin)
  let eur = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "b", count: 64)),
    name: "EUR Cash", currencyUnit: "EUR", origin: origin)
  try app.createAccount(usd)
  try app.createAccount(eur)
  let groceries = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Groceries", kind: .expense, origin: origin)
  let fuel = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "d", count: 64)),
    name: "Fuel", kind: .expense, origin: origin)
  try app.createCategory(groceries)
  try app.createCategory(fuel)
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 1, day: 10)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let ten = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("10.00"))
  let nine = try CurrencyAmount(unitCode: "EUR", amount: ExactDecimal("9.00"))
  _ = try app.createTransfer(
    idempotencyKey: String(repeating: "e", count: 64), sourceAccountID: usd.id,
    destinationAccountID: eur.id, sourceAmount: ten, destinationAmount: nine,
    conversion: LedgerConversion(
      sourceAmount: ten, convertedAmount: nine, rate: ExactDecimal("1.1111"), rateScale: 4,
      rounding: .halfEven),
    fee: nil, feeAccountID: nil, occurredAt: when, origin: origin,
    createdAt: UTCInstant(epochMilliseconds: 1))
  _ = try app.createSplit(
    idempotencyKey: String(repeating: "f", count: 64), accountID: usd.id,
    parentAmount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("5.00")),
    components: [
      (try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("2.00")), groceries.id),
      (try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("3.00")), fuel.id),
    ], occurredAt: when, origin: origin, createdAt: UTCInstant(epochMilliseconds: 2))
  _ = try app.createInstallmentPlan(
    LedgerInstallmentPlan(
      id: StableLedgerID.installmentPlan(
        origin: origin, localKey: String(repeating: "1", count: 64)),
      origin: origin, accountID: usd.id, categoryID: groceries.id,
      principal: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("6.00")), occurrenceCount: 2),
    occurredAt: when, createdAt: UTCInstant(epochMilliseconds: 3))
  try app.createRecurrence(
    LedgerRecurrenceRule(
      id: StableLedgerID.recurrenceRule(
        origin: origin, localKey: String(repeating: "2", count: 64)),
      origin: origin, accountID: usd.id, categoryID: groceries.id, kind: .expense,
      amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("1.00")), frequency: .monthly,
      interval: 1, timeZone: SourceTimeZone(fixedOffsetSeconds: 0),
      start: SourceLocalDate(year: 2026, month: 1, day: 31)))
  try app.createBudget(
    LedgerBudget(
      id: StableLedgerID.budget(origin: origin, localKey: String(repeating: "3", count: 64)),
      origin: origin, name: "Food", categoryID: groceries.id,
      amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("100.00")), period: .monthly,
      rollover: false, start: SourceLocalDate(year: 2026, month: 1, day: 1)))
  let income = try app.createTransaction(
    idempotencyKey: String(repeating: "4", count: 64),
    draft: LedgerTransactionDraft(
      effects: [
        try LedgerTransactionEffect(
          accountID: usd.id, direction: .increase,
          amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("4.00")))
      ], categoryID: nil, kind: .income, occurredAt: when, origin: origin),
    createdAt: UTCInstant(epochMilliseconds: 4))
  let correctedDraft = try LedgerTransactionDraft(
    effects: [
      try LedgerTransactionEffect(
        accountID: usd.id, direction: .increase,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("4.25")))
    ], categoryID: nil, kind: .income, occurredAt: when, origin: origin)
  _ = try app.correctTransaction(
    transactionID: income.transactionID, expectedCurrentRevisionID: income.id,
    draft: correctedDraft, createdAt: UTCInstant(epochMilliseconds: 5))
  let doomed = try app.createTransaction(
    idempotencyKey: String(repeating: "5", count: 64),
    draft: LedgerTransactionDraft(
      effects: [
        try LedgerTransactionEffect(
          accountID: usd.id, direction: .decrease,
          amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("0.50")))
      ], categoryID: groceries.id, kind: .expense, occurredAt: when, origin: origin),
    createdAt: UTCInstant(epochMilliseconds: 6))
  _ = try app.tombstoneTransaction(
    transactionID: doomed.transactionID, expectedCurrentRevisionID: doomed.id,
    createdAt: UTCInstant(epochMilliseconds: 7))

  let snapshot = try app.snapshot()
  let report = try app.report(unitCode: "USD")
  let expected = expectedInventory(from: snapshot)
  for row in expected {
    let actual = try #require(report.inventory.first { $0.id == row.id })
    #expect(actual.count == row.count)
    #expect(actual.label == row.label)
  }
  #expect(report.accessibleTable.contains("Transfers"))
  #expect(report.accessibleTable.contains("Tombstones"))
  let usdTransfer = try #require(report.rows.first { $0.id == "transfer" })
  let usdTransferTotal = try ExactDecimal(usdTransfer.amountLiteral)
  let expectedUSDTransfer = try ExactDecimal("10.00")
  #expect(usdTransferTotal == expectedUSDTransfer)
  #expect(usdTransfer.count == 1)
  let usdExpense = try #require(report.rows.first { $0.id == "expense" })
  let usdExpenseTotal = try ExactDecimal(usdExpense.amountLiteral)
  let expectedUSDExpense = try ExactDecimal("11.00")
  #expect(usdExpenseTotal == expectedUSDExpense)
  #expect(usdExpense.count == 4)
  let usdIncome = try #require(report.rows.first { $0.id == "income" })
  let usdIncomeTotal = try ExactDecimal(usdIncome.amountLiteral)
  let expectedUSDIncome = try ExactDecimal("4.25")
  #expect(usdIncomeTotal == expectedUSDIncome)
  #expect(usdIncome.count == 1)
  let eurReport = try app.report(unitCode: "EUR")
  let eurTransfer = try #require(eurReport.rows.first { $0.id == "transfer" })
  let eurTransferTotal = try ExactDecimal(eurTransfer.amountLiteral)
  let expectedEURTransfer = try ExactDecimal("9.00")
  #expect(eurTransferTotal == expectedEURTransfer)
  #expect(eurTransfer.count == 1)
  #expect(eurReport.rows.contains { $0.id == "expense" } == false)
  #expect(
    report.rows.allSatisfy { row in
      snapshot.transactions.contains {
        $0.currentRevision.lifecycle == .active
          && $0.currentRevision.draft.kind.rawValue == row.id
          && $0.currentRevision.draft.effects.contains { $0.amount.unitCode == "USD" }
      }
    })

  let before = try app.checksum()
  let firstProjection = try app.makeProjection(unitCode: "USD")
  #expect(firstProjection.report.inventory == report.inventory)
  firstProjection.discard()
  let rebuilt = try app.makeProjection(unitCode: "USD")
  #expect(try app.checksum() == before)
  #expect(rebuilt.report.accessibleTable == report.accessibleTable)
  #expect(rebuilt.report.inventory.map(\.count) == expected.map(\.count))
}

private func expectedInventory(from snapshot: LedgerStore.LedgerReadSnapshot) -> [LedgerReportRow] {
  let transferCount = snapshot.transactions.filter { $0.currentRevision.draft.kind == .transfer }
    .count
  let splitIDs = Set(
    snapshot.transactions.flatMap(\.links).filter { $0.kind == .split }.flatMap {
      [$0.fromTransactionID, $0.toTransactionID]
    })
  let correctionCount = snapshot.transactions.filter { $0.currentRevision.revision > 1 }.count
  let tombstoneCount = snapshot.transactions.filter {
    $0.currentRevision.lifecycle == .tombstoned
  }.count
  let currencies = Set(snapshot.accounts.map(\.currencyUnit)).count
  return [
    LedgerReportRow(
      id: "transfers", label: "Transfers", amountLiteral: "0", unitCode: "", count: transferCount),
    LedgerReportRow(
      id: "splits", label: "Splits", amountLiteral: "0", unitCode: "", count: splitIDs.count),
    LedgerReportRow(
      id: "installments", label: "Installments", amountLiteral: "0", unitCode: "",
      count: snapshot.installmentPlans.count),
    LedgerReportRow(
      id: "recurrence", label: "Recurrence", amountLiteral: "0", unitCode: "",
      count: snapshot.recurrenceRules.count),
    LedgerReportRow(
      id: "budgets", label: "Budgets", amountLiteral: "0", unitCode: "",
      count: snapshot.budgets.count),
    LedgerReportRow(
      id: "currencies", label: "Currencies", amountLiteral: "0", unitCode: "", count: currencies),
    LedgerReportRow(
      id: "corrections", label: "Corrections", amountLiteral: "0", unitCode: "",
      count: correctionCount),
    LedgerReportRow(
      id: "tombstones", label: "Tombstones", amountLiteral: "0", unitCode: "", count: tombstoneCount
    ),
  ]
}

private func expenseDraft(
  accountID: String, categoryID: String?, origin: LedgerOrigin, amount: String,
  note: String? = nil, tag: String? = nil, year: Int, month: Int, day: Int
) throws -> LedgerTransactionDraft {
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: year, month: month, day: day)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let literals = try tag.map { [try LedgerSourceLiteral(field: "tag", literal: $0)] } ?? []
  return try LedgerTransactionDraft(
    effects: [
      try LedgerTransactionEffect(
        accountID: accountID, direction: .decrease,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal(amount)))
    ], categoryID: categoryID, kind: .expense, occurredAt: when, note: note,
    sourceLiterals: literals,
    origin: origin)
}

// B08-R1/R2: generation validates its whole bounded batch before any canonical write.
@Test(arguments: [365, 366, 367, -1])
func b08RecurrenceGenerationIsBoundedAndAtomic(candidateCount: Int) throws {
  let app = LedgerApplication(store: try makeApplicationStore())
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "synthetic")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Synthetic account", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let invalidDate = candidateCount == -1
  let start = try SourceLocalDate(
    year: invalidDate ? 2011 : 2024, month: invalidDate ? 12 : 1, day: invalidDate ? 29 : 1)
  let end = try SourceLocalDate(
    year: invalidDate ? 2011 : candidateCount == 367 ? 2025 : 2024,
    month: candidateCount == 367 ? 1 : 12,
    day: candidateCount == 365 ? 30 : candidateCount == 367 ? 1 : 31)
  let zone = try invalidDate
    ? SourceTimeZone(ianaIdentifier: "Pacific/Apia") : SourceTimeZone(fixedOffsetSeconds: 0)
  let rule = try LedgerRecurrenceRule(
    id: StableLedgerID.recurrenceRule(origin: origin, localKey: String(repeating: "2", count: 64)),
    origin: origin, accountID: account.id, categoryID: nil, kind: .expense,
    amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("1.00")), frequency: .daily,
    interval: 1, timeZone: zone, start: start)
  try app.createRecurrence(rule)
  let before = try app.checksum()
  let createdAt = UTCInstant(epochMilliseconds: 1)
  if invalidDate || candidateCount == 367 {
    #expect(throws: (any Swift.Error).self) {
      try app.generateOccurrences(rule, through: end, createdAt: createdAt)
    }
    #expect(try app.checksum() == before)
    #expect(try app.snapshot().transactions.isEmpty)
    #expect(try app.snapshot().transactions.flatMap(\.links).isEmpty)
  } else {
    let revisions = try app.generateOccurrences(rule, through: end, createdAt: createdAt)
    #expect(revisions.count == candidateCount)
    #expect(try app.snapshot().transactions.count == candidateCount)
    #expect(Set(try app.snapshot().transactions.flatMap(\.links).map(\.id)).count == candidateCount - 1)
    let after = try app.checksum()
    #expect(try app.generateOccurrences(rule, through: end, createdAt: createdAt) == revisions)
    #expect(try app.checksum() == after)
  }
}

@Test func activityReportSignsByDirectionAndCountsTransferOnce() throws {
  let app = LedgerApplication(store: try makeApplicationStore())
  let origin = try LedgerOrigin(id: String(repeating: "7", count: 64), label: "local")
  let first = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "One", currencyUnit: "USD", origin: origin)
  let second = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "b", count: 64)),
    name: "Two", currencyUnit: "USD", origin: origin)
  try app.createAccount(first)
  try app.createAccount(second)
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 1, day: 10)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  func amount(_ literal: String) throws -> CurrencyAmount {
    try CurrencyAmount(unitCode: "USD", amount: ExactDecimal(literal))
  }
  func simple(_ key: String, _ direction: LedgerEffectDirection, _ literal: String,
    _ kind: LedgerTransactionKind, _ ms: Int64) throws {
    _ = try app.createTransaction(
      idempotencyKey: String(repeating: key, count: 64),
      draft: LedgerTransactionDraft(
        effects: [
          try LedgerTransactionEffect(
            accountID: first.id, direction: direction, amount: amount(literal))
        ], categoryID: nil, kind: kind, occurredAt: when, origin: origin),
      createdAt: UTCInstant(epochMilliseconds: ms))
  }
  try simple("c", .increase, "100", .income, 1)
  try simple("d", .decrease, "40", .expense, 2)
  _ = try app.createTransfer(
    idempotencyKey: String(repeating: "e", count: 64), sourceAccountID: first.id,
    destinationAccountID: second.id, sourceAmount: amount("25"),
    destinationAmount: amount("25"), conversion: nil, fee: nil, feeAccountID: nil,
    occurredAt: when, origin: origin, createdAt: UTCInstant(epochMilliseconds: 3))

  let report = try app.report(unitCode: "USD")
  func row(_ id: String) throws -> ExactDecimal {
    try ExactDecimal(#require(report.rows.first { $0.id == id }).amountLiteral)
  }
  #expect(try row("income") == ExactDecimal("100"))
  #expect(try row("expense") == ExactDecimal("40"))
  #expect(try row("transfer") == ExactDecimal("25"))
  // Net of all effects: transfer legs cancel; income minus expense.
  #expect(try ExactDecimal(report.totalLiteral) == ExactDecimal("60"))
}

@Test func activityReportSignsNegativeAdjustments() throws {
  // Review m3: a decrease adjustment shows as a negative adjustment row and lowers the total.
  // (An increase on an expense is rejected by the domain, so there is no refund-style case.)
  let app = LedgerApplication(store: try makeApplicationStore())
  let origin = try LedgerOrigin(id: String(repeating: "6", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "One", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 1, day: 10)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  func post(_ key: String, _ direction: LedgerEffectDirection, _ literal: String,
    _ kind: LedgerTransactionKind, _ ms: Int64) throws {
    _ = try app.createTransaction(
      idempotencyKey: String(repeating: key, count: 64),
      draft: LedgerTransactionDraft(
        effects: [
          try LedgerTransactionEffect(
            accountID: account.id, direction: direction,
            amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal(literal)))
        ], categoryID: nil, kind: kind, occurredAt: when, origin: origin),
      createdAt: UTCInstant(epochMilliseconds: ms))
  }
  try post("c", .increase, "100", .income, 1)
  try post("d", .decrease, "40", .expense, 2)
  try post("f", .decrease, "5", .adjustment, 3)
  let report = try app.report(unitCode: "USD")
  func row(_ id: String) throws -> ExactDecimal {
    try ExactDecimal(#require(report.rows.first { $0.id == id }).amountLiteral)
  }
  #expect(try row("income") == ExactDecimal("100"))
  #expect(try row("expense") == ExactDecimal("40"))
  #expect(try row("adjustment") == ExactDecimal("-5"))
  #expect(try ExactDecimal(report.totalLiteral) == ExactDecimal("55"))
}

@Test(arguments: ["excluded", "inAndOut", "crossCurrency"])
func activityReportCountsEachTransferOncePerTransaction(_ scenario: String) throws {
  // Review M1: a transfer with only one leg visible in the report (other leg excluded from
  // totals or in another currency) must still add its leg next to fully visible transfers.
  let app = LedgerApplication(store: try makeApplicationStore())
  let origin = try LedgerOrigin(id: String(repeating: "9", count: 64), label: "local")
  func account(_ key: Character, _ name: String, _ unit: String, included: Bool = true) throws
    -> LedgerAccount
  {
    let value = try LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: String(repeating: key, count: 64)),
      name: name, currencyUnit: unit, origin: origin, includeInTotals: included)
    try app.createAccount(value)
    return value
  }
  let one = try account("a", "One", "USD")
  let two = try account("b", "Two", "USD")
  let off = try account("c", "Off", "USD", included: false)
  let eur = try account("d", "Euro", "EUR")
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 1, day: 10)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  func usd(_ literal: String) throws -> CurrencyAmount {
    try CurrencyAmount(unitCode: "USD", amount: ExactDecimal(literal))
  }
  var next: Int64 = 0
  func transfer(
    _ from: LedgerAccount, _ to: LedgerAccount, _ source: CurrencyAmount,
    _ destination: CurrencyAmount, conversion: LedgerConversion? = nil
  ) throws {
    next += 1
    _ = try app.createTransfer(
      idempotencyKey: String(repeating: String(next), count: 64), sourceAccountID: from.id,
      destinationAccountID: to.id, sourceAmount: source, destinationAmount: destination,
      conversion: conversion, fee: nil, feeAccountID: nil, occurredAt: when, origin: origin,
      createdAt: UTCInstant(epochMilliseconds: next))
  }
  let expectedTransfer: String
  let expectedTotal: String
  switch scenario {
  case "excluded":
    try transfer(one, two, usd("25"), usd("25"))
    try transfer(one, off, usd("10"), usd("10"))
    (expectedTransfer, expectedTotal) = ("35", "-10")
  case "inAndOut":
    try transfer(off, one, usd("10"), usd("10"))
    try transfer(one, off, usd("10"), usd("10"))
    (expectedTransfer, expectedTotal) = ("20", "0")
  default:
    try transfer(one, two, usd("25"), usd("25"))
    let nine = try CurrencyAmount(unitCode: "EUR", amount: ExactDecimal("9"))
    try transfer(
      one, eur, usd("10"), nine,
      conversion: LedgerConversion(
        sourceAmount: usd("10"), convertedAmount: nine, rate: ExactDecimal("1.1111"),
        rateScale: 4, rounding: .halfEven))
    (expectedTransfer, expectedTotal) = ("35", "-10")
  }
  let report = try app.report(unitCode: "USD")
  let row = try #require(report.rows.first { $0.id == "transfer" })
  #expect(try ExactDecimal(row.amountLiteral) == ExactDecimal(expectedTransfer))
  #expect(row.count == 2)
  #expect(try ExactDecimal(report.totalLiteral) == ExactDecimal(expectedTotal))
}

@Test func splitPurchasesSkippingInvalidKeepsValidGroupsVisible() throws {
  let app = LedgerApplication(store: try makeApplicationStore())
  let origin = try LedgerOrigin(id: String(repeating: "8", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "One", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let category = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Food", kind: .expense, origin: origin)
  try app.createCategory(category)
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 1, day: 10)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  func split(_ key: Character, ms: Int64) throws -> [LedgerTransactionRevision] {
    func line(_ k: Character, _ amount: String, _ order: Int) throws -> LedgerSplitLine {
      try LedgerSplitLine(
        id: StableLedgerID.splitLine(origin: origin, localKey: String(repeating: k, count: 64)),
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal(amount)),
        categoryID: category.id, description: "Line \(order)", displayOrder: order)
    }
    let first = key == "f" ? "1" : key == "e" ? "3" : "5"
    let second = key == "f" ? "2" : key == "e" ? "4" : "6"
    let purchaseID = try StableLedgerID.transaction(
      origin: origin, localKey: String(repeating: key, count: 64))
    _ = try app.createSplit(
      LedgerSplitDraft(
        id: purchaseID,
        accountID: account.id,
        parentAmount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("5.00")),
        lines: [try line(Character(first), "2.00", 0), try line(Character(second), "3.00", 1)],
        occurredAt: when, note: "Group", origin: origin),
      createdAt: UTCInstant(epochMilliseconds: ms))
    return try app.snapshot().transactions.filter {
      $0.currentRevision.draft.sourceLiterals.contains {
        $0.field == "split.purchaseID" && $0.literal == purchaseID
      }
    }.map(\.currentRevision)
  }
  _ = try split("f", ms: 1)
  let broken = try split("e", ms: 2)
  // Correct one child with its split metadata stripped, producing a malformed group.
  let child = try #require(broken.first)
  _ = try app.correctTransaction(
    transactionID: child.transactionID, expectedCurrentRevisionID: child.id,
    draft: LedgerTransactionDraft(
      effects: child.draft.effects, categoryID: child.draft.categoryID, kind: .expense,
      occurredAt: child.draft.occurredAt, origin: origin),
    createdAt: UTCInstant(epochMilliseconds: 3))
  let snapshot = try app.snapshot()
  #expect(throws: (any Error).self) { try LedgerApplication.splitPurchases(from: snapshot) }
  let listing = LedgerApplication.splitPurchaseListing(from: snapshot)
  #expect(listing.purchases.count == 1)
  // The malformed group's rows are reported so the UI can keep them visible and say why.
  #expect(listing.unreadableGroupCount == 1)
  #expect(listing.unreadableTransactionIDs == Set(broken.map(\.transactionID)))
  #expect(listing.unreadableNotice?.contains("could not be read") == true)

  // Review m1: one malformed group must not block creating an unrelated split.
  let created = try split("d", ms: 4)
  #expect(created.count == 2)
  let after = LedgerApplication.splitPurchaseListing(from: try app.snapshot())
  #expect(after.purchases.count == 2)
  #expect(after.unreadableGroupCount == 1)

  // Codex P2: a retry that reuses the unreadable group's purchase ID with new line IDs
  // must not insert a second group with the same purchase ID.
  let brokenPurchaseID = try StableLedgerID.transaction(
    origin: origin, localKey: String(repeating: "e", count: 64))
  let countBeforeRetry = try app.snapshot().transactions.count
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try app.createSplit(
      LedgerSplitDraft(
        id: brokenPurchaseID,
        accountID: account.id,
        parentAmount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("5.00")),
        lines: [
          try LedgerSplitLine(
            id: StableLedgerID.splitLine(origin: origin, localKey: String(repeating: "7", count: 64)),
            amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("2.00")),
            categoryID: category.id, description: "Retry 0", displayOrder: 0),
          try LedgerSplitLine(
            id: StableLedgerID.splitLine(origin: origin, localKey: String(repeating: "8", count: 64)),
            amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("3.00")),
            categoryID: category.id, description: "Retry 1", displayOrder: 1),
        ],
        occurredAt: when, note: "Group", origin: origin),
      createdAt: UTCInstant(epochMilliseconds: 5))
  }
  #expect(try app.snapshot().transactions.count == countBeforeRetry)
  #expect(
    LedgerSplitPurchaseListing(
      purchases: [], unreadableTransactionIDs: [], unreadableGroupCount: 0
    ).unreadableNotice == nil)
}

// MACV2-11: editing future occurrences never rewrites what was already generated.
@Test func recurrenceEditsApplyOnlyToOccurrencesNotYetGenerated() throws {
  let app = LedgerApplication(store: try makeApplicationStore())
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "synthetic")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Synthetic account", currencyUnit: "USD", origin: origin)
  try app.createAccount(account)
  let zone = try SourceTimeZone(fixedOffsetSeconds: 0)
  let ruleID = try StableLedgerID.recurrenceRule(
    origin: origin, localKey: String(repeating: "2", count: 64))
  func rule(_ amount: String) throws -> LedgerRecurrenceRule {
    try LedgerRecurrenceRule(
      id: ruleID, origin: origin, accountID: account.id, categoryID: nil, kind: .expense,
      amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal(amount)), frequency: .monthly,
      interval: 1, timeZone: zone, start: SourceLocalDate(year: 2026, month: 1, day: 31))
  }
  try app.createRecurrence(rule("2.00"))
  let first = try app.generateOccurrences(
    rule("2.00"), through: SourceLocalDate(year: 2026, month: 3, day: 31),
    createdAt: UTCInstant(epochMilliseconds: 1))
  #expect(first.map { $0.draft.occurredAt.localDateTime.date.day } == [31, 28, 31])
  let historyBefore = try app.snapshot().revisionHistory

  try app.updateRecurrence(rule("5.50"), scope: .thisAndFuture)
  let all = try app.generateOccurrences(
    rule("5.50"), through: SourceLocalDate(year: 2026, month: 5, day: 31),
    createdAt: UTCInstant(epochMilliseconds: 2))
  #expect(all.count == 5)
  #expect(Array(all.prefix(3)) == first)
  #expect(all.map { $0.draft.effects[0].amount.amount.rawLiteral }
    == ["2.00", "2.00", "2.00", "5.50", "5.50"])
  #expect(all.map { $0.draft.occurredAt.localDateTime.date.day } == [31, 28, 31, 30, 31])
  let historyAfter = try app.snapshot().revisionHistory
  #expect(historyBefore.allSatisfy { historyAfter.contains($0) })

  // Catching up again adds nothing and returns what is stored.
  let checksum = try app.checksum()
  #expect(
    try app.generateOccurrences(
      rule("5.50"), through: SourceLocalDate(year: 2026, month: 5, day: 31),
      createdAt: UTCInstant(epochMilliseconds: 3)) == all)
  #expect(try app.checksum() == checksum)
}

@Test func recurrenceStaysIdempotentAndHistoryStaysFixedAcrossReopen() throws {
  // MACV2-11: generated entries stay exact and idempotent across a restart, a rule edit only
  // affects dates not generated yet, and an invalid budget change writes nothing.
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("ledger.sqlite")
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Cash", currencyUnit: "USD", origin: origin)
  let category = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Rent", kind: .expense, origin: origin)
  let start = try SourceLocalDate(year: 2026, month: 1, day: 31)
  let rule = try LedgerRecurrenceRule(
    id: StableLedgerID.recurrenceRule(origin: origin, localKey: String(repeating: "2", count: 64)),
    origin: origin, accountID: account.id, categoryID: category.id, kind: .expense,
    amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("2.50")), frequency: .monthly,
    interval: 1, dayOfMonth: 31, timeZone: SourceTimeZone(fixedOffsetSeconds: 19_800),
    start: start)
  let march = try SourceLocalDate(year: 2026, month: 3, day: 31)
  let april = try SourceLocalDate(year: 2026, month: 4, day: 30)
  var firstRun: [LedgerTransactionRevision] = []
  var checksum = ""

  do {
    let app = LedgerApplication(store: try LedgerStoreLifecycle.create(at: url).store)
    try app.createAccount(account)
    try app.createCategory(category)
    try app.createRecurrence(rule)
    try app.createBudget(
      LedgerBudget(
        id: StableLedgerID.budget(origin: origin, localKey: String(repeating: "3", count: 64)),
        origin: origin, name: "Rent", categoryID: category.id,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("10.00")), period: .monthly,
        rollover: true, start: start))
    firstRun = try app.generateOccurrences(
      rule, through: march, createdAt: UTCInstant(epochMilliseconds: 1))
    #expect(firstRun.count == 3)
    // A raise from April on: the three generated months stay as they were.
    let raised = try LedgerRecurrenceRule(
      id: rule.id, origin: origin, accountID: account.id, categoryID: category.id, kind: .expense,
      amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("3.00")), frequency: .monthly,
      interval: 1, dayOfMonth: 31, timeZone: rule.timeZone, start: start)
    try app.updateRecurrence(raised, scope: .thisAndFuture)
    checksum = try app.checksum()
    // Changing a budget that does not exist is refused and writes nothing.
    #expect(throws: (any Swift.Error).self) {
      try app.updateBudget(
        LedgerBudget(
          id: StableLedgerID.budget(origin: origin, localKey: String(repeating: "9", count: 64)),
          origin: origin, name: "Missing", categoryID: category.id,
          amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("1.00")),
          period: .monthly, rollover: false, start: start))
    }
    #expect(try app.checksum() == checksum)
  }

  let reopened = LedgerApplication(store: try LedgerStoreLifecycle.open(at: url).store)
  #expect(try reopened.checksum() == checksum)
  let stored = try #require(try reopened.snapshot().recurrenceRules.first { $0.id == rule.id })
  #expect(stored.amount.amount == (try ExactDecimal("3.00")))
  // Catching up again after the restart returns the same three entries and writes nothing.
  #expect(
    try reopened.generateOccurrences(
      stored, through: march, createdAt: UTCInstant(epochMilliseconds: 2)) == firstRun)
  #expect(try reopened.checksum() == checksum)
  // The next month uses the new amount; the earlier ones keep theirs.
  let throughApril = try reopened.generateOccurrences(
    stored, through: april, createdAt: UTCInstant(epochMilliseconds: 3))
  #expect(throughApril.count == 4)
  #expect(Array(throughApril.prefix(3)) == firstRun)
  #expect(
    throughApril.map { $0.draft.effects[0].amount.amount.rawLiteral }
      == ["2.50", "2.50", "2.50", "3.00"])
  #expect(throughApril[1].draft.occurredAt.localDay == (try SourceLocalDate(year: 2026, month: 2, day: 28)))
}
