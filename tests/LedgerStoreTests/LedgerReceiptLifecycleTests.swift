import CSQLite
import Foundation
import LedgerCore
import Testing

@testable import LedgerStore

// File-backed receipt tests: upgrade from a frozen v12 ledger, write across reopen, and
// backup round trips. Synthetic data only.

private let origin = try! LedgerOrigin(id: String(repeating: "1", count: 64), label: "synthetic")
private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array("synthetic-png".utf8))
private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array("synthetic-jpeg".utf8))
private let at = UTCInstant(epochMilliseconds: 1_780_000_000_000)

private enum ReceiptLifecycleTestError: Swift.Error { case sqlite }

private func withReceiptDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory.resolvingSymlinksInPath())
}

/// A ledger exactly as schema v12 wrote it, built from the frozen v12 objects.
private func writeV12Ledger(to url: URL) throws -> String {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw ReceiptLifecycleTestError.sqlite
  }
  for object in CanonicalLedgerSchema.legacyV12Objects {
    guard sqlite3_exec(database, object.ddl, nil, nil, nil) == SQLITE_OK else {
      throw ReceiptLifecycleTestError.sqlite
    }
  }
  let accountID = String(repeating: "2", count: 64)
  let sql = """
    PRAGMA application_id=\(CanonicalLedgerSchema.applicationID);
    INSERT INTO ledger_meta(key, value) VALUES
      ('schema_version', '12'),
      ('ledger_identity', 'ledger-atlas-canonical'),
      ('schema_fingerprint', '\(CanonicalLedgerSchema.legacyV12Fingerprint)');
    INSERT INTO ledger_origin(origin_id, label, provenance_id)
      VALUES ('\(origin.id)', 'synthetic', NULL);
    INSERT INTO ledger_account(account_id, name, currency_unit, origin_id, lifecycle)
      VALUES ('\(accountID)', 'Synthetic', 'INR', '\(origin.id)', 'active');
    """
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK,
    sqlite3_close(database) == SQLITE_OK,
    chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0
  else { throw ReceiptLifecycleTestError.sqlite }
  return accountID
}

private func expense(on accountID: String, _ app: LedgerApplication) throws -> String {
  try app.createTransaction(
    idempotencyKey: String(repeating: "b", count: 64),
    draft: LedgerTransactionDraft(
      effects: [
        LedgerTransactionEffect(
          accountID: accountID, direction: .decrease,
          amount: CurrencyAmount(unitCode: "INR", amount: ExactDecimal("120")))
      ], categoryID: nil, kind: .expense,
      occurredAt: SourceTemporal(
        resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 9, day: 3)),
        in: SourceTimeZone(fixedOffsetSeconds: 19_800), precision: .day),
      origin: origin),
    createdAt: at
  ).transactionID
}

@Test func v12LedgerUpgradesAndKeepsReceiptsAcrossReopen() throws {
  try withReceiptDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    let accountID = try writeV12Ledger(to: url)

    #expect(try LedgerStoreLifecycle.inspect(at: url) == .upgradeRequired)
    let first: LedgerReceiptAttachment
    let transactionID: String
    do {
      let upgraded = try LedgerStoreLifecycle.open(at: url)
      #expect(upgraded.disposition == .upgraded)
      #expect(try upgraded.store.readSnapshot().accounts.map(\.id) == [accountID])
      #expect(try upgraded.store.receiptAttachments().isEmpty)
      transactionID = try expense(on: accountID, LedgerApplication(store: upgraded.store))
      first = try upgraded.store.addReceipt(png, origin: origin, createdAt: at)
    }

    // Write, reopen, write again.
    let reopened = try LedgerStoreLifecycle.open(at: url)
    #expect(reopened.disposition == .opened)
    #expect(try reopened.store.receiptAttachments() == [first])
    #expect(try reopened.store.receiptBytes(first.id) == png)
    try reopened.store.linkReceipt(first.id, to: transactionID)
    let second = try reopened.store.addReceipt(
      jpeg, origin: origin, linkedTo: transactionID, createdAt: at)

    let receipts = try reopened.store.receiptAttachments()
    #expect(Set(receipts.map(\.id)) == [first.id, second.id])
    #expect(receipts.allSatisfy { $0.transactionID == transactionID })
    #expect(try reopened.store.receiptBytes(second.id) == jpeg)
    #expect(try LedgerStoreLifecycle.inspect(at: url) == .current)
  }
}

@Test func backupAndTwoRestoresKeepReceiptsAndChecksumsIdentical() throws {
  try withReceiptDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    let created = try LedgerStoreLifecycle.create(at: url)
    let account = try LedgerAccount(
      id: String(repeating: "4", count: 64), name: "Synthetic", currencyUnit: "INR",
      origin: origin)
    try created.store.createAccount(account)
    let transactionID = try expense(on: account.id, LedgerApplication(store: created.store))
    let linked = try created.store.addReceipt(
      png, origin: origin, linkedTo: transactionID, createdAt: at)
    let removed = try created.store.addReceipt(jpeg, origin: origin, createdAt: at)
    try created.store.tombstoneReceipt(removed.id)
    let checksum = try created.store.semanticChecksum()

    // backup -> restore -> backup -> restore, each restore made from the previous copy.
    let backup = directory.appendingPathComponent("backup.sqlite")
    try created.store.backupCanonicalDatabase(to: backup)
    let restoredOnce = directory.appendingPathComponent("restored-once.sqlite")
    try LedgerStore.openReadOnly(at: backup).backupCanonicalDatabase(to: restoredOnce)
    let backupAgain = directory.appendingPathComponent("backup-again.sqlite")
    try LedgerStore.openReadOnly(at: restoredOnce).backupCanonicalDatabase(to: backupAgain)
    let restoredTwice = directory.appendingPathComponent("restored-twice.sqlite")
    try LedgerStore.openReadOnly(at: backupAgain).backupCanonicalDatabase(to: restoredTwice)

    for copy in [backup, restoredOnce, backupAgain, restoredTwice] {
      let store = try LedgerStore.openReadOnly(at: copy)
      #expect(try store.semanticChecksum() == checksum)
      let receipts = try store.receiptAttachments()
      #expect(receipts.count == 2)
      #expect(receipts.first { $0.id == linked.id }?.transactionID == transactionID)
      #expect(receipts.first { $0.id == removed.id }?.lifecycle == .tombstoned)
      #expect(try store.receiptBytes(linked.id) == png)
      // A removed receipt keeps its bytes in v1; delete-forever is a later feature.
      #expect(try store.receiptBytes(removed.id) == jpeg)
    }

    // The restored ledger is a normal writable ledger.
    let reopened = try LedgerStoreLifecycle.open(at: restoredTwice)
    #expect(reopened.disposition == .opened)
    try reopened.store.linkReceipt(linked.id, to: nil)
    #expect(try reopened.store.semanticChecksum() != checksum)
  }
}

@Test func addingTheSameImageWithANewLinkIsSavedAcrossReopen() throws {
  try withReceiptDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    let receiptID: String
    let transactionID: String
    do {
      let created = try LedgerStoreLifecycle.create(at: url)
      let account = try LedgerAccount(
        id: String(repeating: "4", count: 64), name: "Synthetic", currencyUnit: "INR",
        origin: origin)
      try created.store.createAccount(account)
      transactionID = try expense(on: account.id, LedgerApplication(store: created.store))
      receiptID = try created.store.addReceipt(png, origin: origin, createdAt: at).id
      let again = try created.store.addReceipt(
        png, origin: origin, linkedTo: transactionID, createdAt: at)
      #expect(again.id == receiptID)
    }
    let reopened = try LedgerStoreLifecycle.open(at: url)
    #expect(try reopened.store.receiptAttachments().map(\.transactionID) == [transactionID])
  }
}
