import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

// #246: a bulk change and its revert are written off the main thread. Synthetic data only.

@MainActor
private func bulkLedger(in directory: URL) throws -> (
  journey: LedgerJourney, food: LedgerCategory, ids: [String]
) {
  let url = directory.appendingPathComponent("bulk.sqlite")
  _ = try LedgerStoreLifecycle.create(at: url)
  let journey = LedgerJourney()
  try journey.beginEditing(url)
  let origin = try LedgerOrigin.macNative()
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "4", count: 64)),
    name: "Synthetic wallet", currencyUnit: "INR", origin: origin)
  try journey.createAccount(account)
  let food = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "5", count: 64)),
    name: "Synthetic food", kind: .expense, origin: origin)
  try journey.createCategory(food)
  for index in 1...3 {
    let saved = journey.saveNativeEntry(
      amountLiteral: "\(index)0", kind: .expense, accountID: account.id, categoryID: nil,
      note: nil, createdAt: UTCInstant(epochMilliseconds: Int64(index)),
      submissionID: UUID().uuidString, tags: .empty)
    guard case .saved = saved else { throw LedgerApplication.Error.invalidCommand }
  }
  let ids = journey.snapshot?.transactions.map(\.id) ?? []
  return (journey, food, ids)
}

private func temporaryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

@MainActor
@Test func aBulkChangeAndItsRevertAreWrittenOffTheMainThread() async throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let (journey, food, ids) = try bulkLedger(in: directory)
  #expect(ids.count == 3)

  let plan = try journey.planBulkEdit(.category(food.id), transactionIDs: ids)
  try await journey.applyBulkEdit(plan, createdAt: UTCInstant(epochMilliseconds: 10))
  #expect(journey.backgroundWork == nil)
  #expect(journey.isEditing)
  #expect(journey.lastBulkEdit?.entries.count == 3)
  let changed = journey.snapshot?.transactions.map(\.currentRevision.draft.categoryID)
  #expect(changed == [food.id, food.id, food.id])

  try await journey.revertLastBulkEdit(createdAt: UTCInstant(epochMilliseconds: 11))
  #expect(journey.backgroundWork == nil)
  #expect(journey.lastBulkEdit == nil)
  let reverted = journey.snapshot?.transactions.map(\.currentRevision.draft.categoryID)
  #expect(reverted == [nil, nil, nil])
}

@MainActor
@Test func aBulkChangeForAClosedLedgerChangesNothingOnScreen() async throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let (journey, food, ids) = try bulkLedger(in: directory)
  let plan = try journey.planBulkEdit(.category(food.id), transactionIDs: ids)
  let writing = Task {
    try await journey.applyBulkEdit(plan, createdAt: UTCInstant(epochMilliseconds: 10))
  }
  // Whether the write had started or not, closing the ledger means its result is dropped.
  await Task.yield()
  journey.closeLedger()
  _ = try? await writing.value
  #expect(journey.snapshot == nil)
  #expect(journey.lastBulkEdit == nil)
  #expect(journey.backgroundWork == nil)
}

@MainActor
@Test func nothingElseUsesTheLedgerWhileABulkChangeIsWritten() async throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let (journey, food, ids) = try bulkLedger(in: directory)
  let package = try journey.exportPackage()
  let plan = try journey.planBulkEdit(.category(food.id), transactionIDs: ids)
  // The write waits here until every other use of the ledger has been tried.
  let gate = DispatchSemaphore(value: 0)
  journey.beforeBackgroundWrite = { gate.wait() }
  let writing = Task {
    try await journey.applyBulkEdit(plan, createdAt: UTCInstant(epochMilliseconds: 10))
  }
  while journey.backgroundWork == nil { await Task.yield() }

  let refused = LedgerApplication.Error.invalidCommand
  #expect(throws: refused) {
    _ = try journey.backupCanonicalLedger(to: directory.appendingPathComponent("copy.sqlite"))
  }
  #expect(throws: refused) {
    try journey.exportXLSX(to: directory.appendingPathComponent("out.xlsx"))
  }
  #expect(throws: refused) {
    _ = try journey.planXLSXImport(from: directory.appendingPathComponent("in.xlsx"))
  }
  #expect(throws: refused) { _ = try journey.receiptAttachments() }
  #expect(throws: refused) { _ = try journey.receiptBytes("receipt") }
  #expect(throws: refused) { _ = try journey.exportPackage() }
  #expect(throws: refused) {
    try journey.restorePackage(
      manifest: package.manifest, payload: package.payload,
      into: directory.appendingPathComponent("bulk.sqlite"))
  }
  #expect(throws: refused) {
    try journey.beginEditing(directory.appendingPathComponent("bulk.sqlite"))
  }

  gate.signal()
  try await writing.value
  #expect(journey.backgroundWork == nil)
  #expect(journey.snapshot?.transactions.map(\.currentRevision.draft.categoryID)
    == [food.id, food.id, food.id])
  #expect(try journey.receiptAttachments().isEmpty)
}

@MainActor
@Test func theBulkProgressSaysWhatIsBeingWritten() {
  #expect(BulkEditWording.working(.bulkEditing(count: 1)) == "Changing 1 entry…")
  #expect(BulkEditWording.working(.bulkEditing(count: 1_200)) == "Changing 1200 entries…")
  #expect(BulkEditWording.working(.revertingBulkEdit(count: 3)) == "Reverting 3 entries…")
  #expect(BulkEditWording.working(.importing) == nil)
}
