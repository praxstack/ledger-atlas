import CSQLite
import Foundation
import LedgerCore
import Testing

@testable import LedgerStore

// Synthetic data only: every name, amount and date here is made up.

/// #168: a bulk change is one all-or-nothing write, and reverting it is one step.

private func makeBulkStore() throws -> LedgerStore {
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

private func hex(_ n: Int) -> String { String(format: "%064x", n) }

private func inr(_ literal: String) throws -> CurrencyAmount {
  try CurrencyAmount(unitCode: "INR", amount: ExactDecimal(literal))
}

private struct BulkFixture {
  let app: LedgerApplication
  let origin: LedgerOrigin
  let cash: LedgerAccount
  let bank: LedgerAccount
  let food: LedgerCategory
  let home: LedgerCategory
  let salary: LedgerCategory
  let shared: LedgerTag
  let when: SourceTemporal
  /// Plain expenses, in Food.
  var expenses: [String] = []

  init(expenses count: Int = 0) throws {
    app = LedgerApplication(store: try makeBulkStore())
    origin = try LedgerOrigin(id: String(repeating: "9", count: 64), label: "local")
    cash = try LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: hex(1)), name: "Cash",
      currencyUnit: "INR", origin: origin)
    bank = try LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: hex(2)), name: "Bank",
      currencyUnit: "INR", origin: origin)
    try app.createAccount(cash)
    try app.createAccount(bank)
    food = try LedgerCategory(
      id: StableLedgerID.category(origin: origin, localKey: hex(3)), name: "Food",
      kind: .expense, origin: origin)
    home = try LedgerCategory(
      id: StableLedgerID.category(origin: origin, localKey: hex(4)), name: "Home",
      kind: .expense, origin: origin)
    salary = try LedgerCategory(
      id: StableLedgerID.category(origin: origin, localKey: hex(5)), name: "Salary",
      kind: .income, origin: origin)
    for category in [food, home, salary] { try app.createCategory(category) }
    shared = try LedgerTag(
      id: StableLedgerID.tag(origin: origin, localKey: hex(6)), name: "shared", origin: origin)
    try app.createTag(shared)
    when = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 10, day: 1)),
      in: SourceTimeZone(fixedOffsetSeconds: 19_800), precision: .day)
    for index in 0..<count {
      let draft = try LedgerTransactionDraft(
        effects: [.init(accountID: cash.id, direction: .decrease, amount: inr("\(index + 1)"))],
        categoryID: food.id, kind: .expense, occurredAt: when, note: "Synthetic \(index)",
        origin: origin)
      let revision = try app.createTransaction(
        idempotencyKey: hex(1_000 + index), draft: draft,
        createdAt: UTCInstant(epochMilliseconds: 1))
      expenses.append(revision.transactionID)
    }
  }

  func current(_ id: String) throws -> LedgerTransactionRevision {
    try #require(try app.snapshot().transactions.first { $0.id == id }).currentRevision
  }

  func plan(_ change: LedgerBulkChange, _ ids: [String]) throws -> LedgerBulkEditPlan {
    try LedgerBulkEditPlan.make(change, transactionIDs: ids, in: app.snapshot())
  }
}

@Test func twoHundredRecategorisationsCommitTogether() throws {
  let fixture = try BulkFixture(expenses: 200)
  let plan = try fixture.plan(.category(fixture.home.id), fixture.expenses)
  #expect(plan.changeCount == 200)
  #expect(plan.selectedCount == 200 && plan.linkedCount == 0 && plan.unchangedCount == 0)
  let receipt = try fixture.app.applyBulkEdit(plan, createdAt: UTCInstant(epochMilliseconds: 2))
  #expect(receipt.entries.count == 200)
  let snapshot = try fixture.app.snapshot()
  let moved = snapshot.transactions.filter {
    $0.currentRevision.draft.categoryID == fixture.home.id && $0.currentRevision.revision == 2
  }
  #expect(moved.count == 200)
  // Only the category changed: amounts, notes and dates are as before.
  for entry in receipt.entries {
    let now = try #require(snapshot.transactions.first { $0.id == entry.transactionID })
    #expect(now.currentRevision.draft.effects == entry.before.draft.effects)
    #expect(now.currentRevision.draft.note == entry.before.draft.note)
    #expect(now.currentRevision.draft.occurredAt == entry.before.draft.occurredAt)
  }
}

@Test func aFailureAtRowOneHundredLeavesTheLedgerUnchanged() throws {
  let fixture = try BulkFixture(expenses: 200)
  let before = try fixture.app.checksum()
  let plan = try fixture.plan(.category(fixture.home.id), fixture.expenses)
  // Row 100 points at a category the ledger doesn't have, so its write fails after 99 rows
  // were written in the same database transaction.
  var targets = plan.targets
  let row = targets[99]
  targets[99] = LedgerBulkEditPlan.Target(
    current: row.current, currentTags: row.currentTags,
    draft: try LedgerBulkEditPlan.correctedDraft(row.current.draft, categoryID: hex(999)),
    tags: row.tags)
  let broken = LedgerBulkEditPlan(
    change: plan.change, selectedCount: plan.selectedCount, linkedCount: 0, unchangedCount: 0,
    targets: targets)
  #expect(throws: (any Error).self) {
    try fixture.app.applyBulkEdit(broken, createdAt: UTCInstant(epochMilliseconds: 2))
  }
  #expect(try fixture.app.checksum() == before)
  let snapshot = try fixture.app.snapshot()
  #expect(snapshot.transactions.allSatisfy { $0.currentRevision.revision == 1 })
  #expect(snapshot.revisionHistory.count == 200)
}

@Test func revertRestoresTheExactPriorCategoryAndTagsInOneStep() throws {
  let fixture = try BulkFixture(expenses: 5)
  let app = fixture.app
  let tagged = try app.applyBulkEdit(
    fixture.plan(.addTag(fixture.shared.id), Array(fixture.expenses.prefix(2))),
    createdAt: UTCInstant(epochMilliseconds: 2))
  #expect(tagged.entries.count == 2)
  let before = try app.snapshot()
  let receipt = try app.applyBulkEdit(
    fixture.plan(.category(fixture.home.id), fixture.expenses),
    createdAt: UTCInstant(epochMilliseconds: 3))
  #expect(receipt.entries.count == 5)

  try app.revertBulkEdit(receipt, createdAt: UTCInstant(epochMilliseconds: 4))
  let after = try app.snapshot()
  for id in fixture.expenses {
    let old = try #require(before.transactions.first { $0.id == id }).currentRevision
    let now = try #require(after.transactions.first { $0.id == id }).currentRevision
    #expect(now.draft == old.draft)
    #expect(after.tags(forRevision: now.id) == before.tags(forRevision: old.id))
    // A new revision on top: history keeps the bulk change.
    #expect(now.revision == old.revision + 2)
  }
  // Reverting again finds every entry moved on, and changes nothing.
  let checksum = try app.checksum()
  #expect(throws: LedgerBulkEditRefusal.changedSince(count: 5)) {
    try app.revertBulkEdit(receipt, createdAt: UTCInstant(epochMilliseconds: 5))
  }
  #expect(try app.checksum() == checksum)
}

@Test func revertIsRefusedWhenAnEntryWasEditedSince() throws {
  let fixture = try BulkFixture(expenses: 3)
  let app = fixture.app
  let receipt = try app.applyBulkEdit(
    fixture.plan(.category(fixture.home.id), fixture.expenses),
    createdAt: UTCInstant(epochMilliseconds: 2))
  let edited = try fixture.current(fixture.expenses[1])
  _ = try app.correctTransaction(
    transactionID: edited.transactionID, expectedCurrentRevisionID: edited.id,
    draft: try LedgerTransactionDraft(
      effects: edited.draft.effects, categoryID: fixture.food.id, kind: .expense,
      occurredAt: edited.draft.occurredAt, note: "Edited later", origin: fixture.origin),
    createdAt: UTCInstant(epochMilliseconds: 3))
  let checksum = try app.checksum()
  #expect(throws: LedgerBulkEditRefusal.changedSince(count: 1)) {
    try app.revertBulkEdit(receipt, createdAt: UTCInstant(epochMilliseconds: 4))
  }
  #expect(try app.checksum() == checksum)
}

@Test func aTransferAndItsFeeMoveTogetherAndRevertTogether() throws {
  let fixture = try BulkFixture()
  let app = fixture.app
  let (transfer, fee) = try app.createTransfer(
    idempotencyKey: hex(50), sourceAccountID: fixture.bank.id,
    destinationAccountID: fixture.cash.id, sourceAmount: inr("500"),
    destinationAmount: inr("500"), conversion: nil, fee: inr("5"),
    feeAccountID: fixture.bank.id, occurredAt: fixture.when, origin: fixture.origin,
    createdAt: UTCInstant(epochMilliseconds: 1))
  let feeID = try #require(fee).transactionID

  // A category can't go on a transfer, so recategorising its fee is refused as a whole.
  #expect(throws: LedgerBulkEditRefusal.transfersHaveNoCategory(count: 1)) {
    try fixture.plan(.category(fixture.home.id), [feeID])
  }
  // A tag on the fee tags the transfer too.
  let plan = try fixture.plan(.addTag(fixture.shared.id), [feeID])
  #expect(plan.selectedCount == 1 && plan.linkedCount == 1 && plan.changeCount == 2)
  let receipt = try app.applyBulkEdit(plan, createdAt: UTCInstant(epochMilliseconds: 2))
  let tagged = try app.snapshot()
  for id in [transfer.transactionID, feeID] {
    let now = try #require(tagged.transactions.first { $0.id == id }).currentRevision
    #expect(tagged.tags(forRevision: now.id).tagIDs == [fixture.shared.id])
  }
  // Revert untags both legs.
  try app.revertBulkEdit(receipt, createdAt: UTCInstant(epochMilliseconds: 3))
  let reverted = try app.snapshot()
  for id in [transfer.transactionID, feeID] {
    let now = try #require(reverted.transactions.first { $0.id == id }).currentRevision
    #expect(reverted.tags(forRevision: now.id).isEmpty)
    #expect(now.revision == 3)
  }
}

@Test func aSplitLineKeepsItsCategoryAndATagReachesEveryLine() throws {
  let fixture = try BulkFixture()
  let app = fixture.app
  let lines = try app.createSplit(
    idempotencyKey: hex(60), accountID: fixture.cash.id, parentAmount: inr("100"),
    components: [(inr("60"), fixture.food.id), (inr("40"), fixture.home.id)],
    occurredAt: fixture.when, origin: fixture.origin,
    createdAt: UTCInstant(epochMilliseconds: 1))
  let ids = lines.map(\.transactionID)
  #expect(throws: LedgerBulkEditRefusal.splitLinesKeepTheirCategories(count: 2)) {
    try fixture.plan(.category(fixture.home.id), [ids[0]])
  }
  let plan = try fixture.plan(.addTag(fixture.shared.id), [ids[0]])
  #expect(plan.changeCount == 2 && plan.linkedCount == 1)
}

@Test func anInstallmentPaymentMovesWithItsPlan() throws {
  let fixture = try BulkFixture()
  let app = fixture.app
  let plan = try LedgerInstallmentPlan(
    id: StableLedgerID.installmentPlan(origin: fixture.origin, localKey: hex(70)),
    origin: fixture.origin, accountID: fixture.bank.id, categoryID: fixture.food.id,
    principal: inr("300"), occurrenceCount: 3)
  let payments = try app.createInstallmentPlan(
    plan, occurredAt: fixture.when, createdAt: UTCInstant(epochMilliseconds: 1))
  let bulk = try fixture.plan(.category(fixture.home.id), [payments[1].transactionID])
  #expect(bulk.selectedCount == 1 && bulk.linkedCount == 2 && bulk.changeCount == 3)
}

@Test func aCategoryForAnotherKindOrNoChangeIsRefused() throws {
  let fixture = try BulkFixture(expenses: 3)
  #expect(throws: LedgerBulkEditRefusal.categoryDoesNotFit(count: 3)) {
    try fixture.plan(.category(fixture.salary.id), fixture.expenses)
  }
  #expect(throws: LedgerBulkEditRefusal.nothingToChange) {
    try fixture.plan(.category(fixture.food.id), fixture.expenses)
  }
  #expect(throws: LedgerBulkEditRefusal.nothingToChange) {
    try fixture.plan(.removeTag(fixture.shared.id), fixture.expenses)
  }
  #expect(throws: LedgerBulkEditRefusal.nothingSelected) {
    try fixture.plan(.category(fixture.home.id), [])
  }
  // Some already in Home: they are counted, not rewritten.
  let partial = try fixture.app.applyBulkEdit(
    fixture.plan(.category(fixture.home.id), [fixture.expenses[0]]),
    createdAt: UTCInstant(epochMilliseconds: 2))
  #expect(partial.entries.count == 1)
  let rest = try fixture.plan(.category(fixture.home.id), fixture.expenses)
  #expect(rest.changeCount == 2 && rest.unchangedCount == 1)
}
