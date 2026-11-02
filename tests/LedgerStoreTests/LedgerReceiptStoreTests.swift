import CSQLite
import Foundation
import LedgerCore
import Testing

@testable import LedgerStore

// Synthetic data only: the "images" are tiny made-up byte strings with real file signatures.

private func memoryStore() throws -> (LedgerStore, OpaquePointer) {
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
  return (try LedgerStore(takingOwnershipOfValidatedCanonicalDatabase: database), database)
}

private let origin = try! LedgerOrigin(id: String(repeating: "7", count: 64), label: "synthetic")
private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array("synthetic-png".utf8))
private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array("synthetic-jpeg".utf8))
private let pdf = Data("%PDF-1.7 synthetic".utf8)
private let heic = Data([0, 0, 0, 0x18] + Array("ftypheic".utf8) + Array("synthetic".utf8))
private let at = UTCInstant(epochMilliseconds: 1_780_000_000_000)

private func expense(_ app: LedgerApplication) throws -> LedgerTransactionRevision {
  let wallet = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
    name: "Wallet", currencyUnit: "INR", origin: origin)
  try app.createAccount(wallet)
  return try app.createTransaction(
    idempotencyKey: String(repeating: "b", count: 64),
    draft: LedgerTransactionDraft(
      effects: [
        LedgerTransactionEffect(
          accountID: wallet.id, direction: .decrease,
          amount: CurrencyAmount(unitCode: "INR", amount: ExactDecimal("120")))
      ], categoryID: nil, kind: .expense,
      occurredAt: SourceTemporal(
        resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 9, day: 3)),
        in: SourceTimeZone(fixedOffsetSeconds: 19_800), precision: .day),
      origin: origin),
    createdAt: at)
}

@Test func receiptMediaTypeComesFromTheBytes() {
  #expect(LedgerReceiptAttachment.MediaType(sniffing: png) == .png)
  #expect(LedgerReceiptAttachment.MediaType(sniffing: jpeg) == .jpeg)
  #expect(LedgerReceiptAttachment.MediaType(sniffing: pdf) == .pdf)
  #expect(LedgerReceiptAttachment.MediaType(sniffing: heic) == .heic)
  #expect(LedgerReceiptAttachment.MediaType(sniffing: Data("GIF89a".utf8)) == nil)
  #expect(LedgerReceiptAttachment.MediaType(sniffing: Data()) == nil)
}

@Test func receiptsAreStoredExactlyLinkedAndRemovedWithoutLosingBytes() throws {
  let (store, _) = try memoryStore()
  let app = LedgerApplication(store: store)
  let transaction = try expense(app)

  let receipt = try store.addReceipt(png, origin: origin, createdAt: at)
  #expect(receipt.mediaType == .png)
  #expect(receipt.transactionID == nil)  // unresolved until linked
  #expect(receipt.sha256 == LedgerReceiptAttachment.digest(png))
  #expect(try store.receiptBytes(receipt.id) == png)

  // Adding the same image again is the same receipt; giving a target links it.
  let again = try store.addReceipt(png, origin: origin, linkedTo: transaction.transactionID, createdAt: at)
  #expect(again.id == receipt.id)
  #expect(try store.receiptAttachments().map(\.transactionID) == [transaction.transactionID])

  // A link may stay on a deleted transaction.
  _ = try app.tombstoneTransaction(
    transactionID: transaction.transactionID, expectedCurrentRevisionID: transaction.id,
    createdAt: UTCInstant(epochMilliseconds: at.epochMilliseconds + 1))
  #expect(try store.receiptAttachments().first?.transactionID == transaction.transactionID)
  try store.linkReceipt(receipt.id, to: nil)
  #expect(try store.receiptAttachments().first?.transactionID == nil)

  try store.tombstoneReceipt(receipt.id)
  #expect(try store.receiptAttachments().first?.lifecycle == .tombstoned)
  #expect(try store.receiptBytes(receipt.id) == png)  // kept so a restore stays exact
  #expect(throws: LedgerStore.Error.receiptRemoved) {
    try store.linkReceipt(receipt.id, to: transaction.transactionID)
  }
  #expect(throws: LedgerStore.Error.receiptRemoved) {
    try store.addReceipt(png, origin: origin, createdAt: at)
  }
}

@Test func receiptsRefuseUnknownMediaMissingTargetsAndOversizeImages() throws {
  let (store, _) = try memoryStore()
  let checksum = try store.semanticChecksum()
  #expect(throws: LedgerStore.Error.unsupportedReceipt) {
    try store.addReceipt(Data("GIF89a synthetic".utf8), origin: origin, createdAt: at)
  }
  var huge = jpeg
  huge.append(Data(count: LedgerReceiptAttachment.maximumBytes))
  #expect(throws: LedgerStore.Error.unsupportedReceipt) {
    try store.addReceipt(huge, origin: origin, createdAt: at)
  }
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try store.addReceipt(
      jpeg, origin: origin, linkedTo: String(repeating: "c", count: 64), createdAt: at)
  }
  #expect(try store.semanticChecksum() == checksum)
}

@Test func receiptContentCannotBeRewrittenOrDeleted() throws {
  let (store, database) = try memoryStore()
  let receipt = try store.addReceipt(pdf, origin: origin, createdAt: at)
  for sql in [
    "UPDATE ledger_receipt_attachment SET bytes=x'00' WHERE attachment_id='\(receipt.id)'",
    "UPDATE ledger_receipt_attachment SET sha256='\(String(repeating: "0", count: 64))' WHERE attachment_id='\(receipt.id)'",
    "DELETE FROM ledger_receipt_attachment WHERE attachment_id='\(receipt.id)'",
  ] {
    #expect(sqlite3_exec(database, sql, nil, nil, nil) != SQLITE_OK)
  }
  try store.tombstoneReceipt(receipt.id)
  #expect(
    sqlite3_exec(
      database,
      "UPDATE ledger_receipt_attachment SET lifecycle='active' WHERE attachment_id='\(receipt.id)'",
      nil, nil, nil) != SQLITE_OK)
}

@Test func healthRejectsAReceiptWhoseBytesDoNotMatchItsDigest() throws {
  let (store, database) = try memoryStore()
  _ = try store.addReceipt(jpeg, origin: origin, createdAt: at)
  #expect(CanonicalLedgerHealth.isHealthy(database))
  // Swap the image for another of the same size underneath the triggers, as a tampered file
  // would: still a JPEG, same byte count, different bytes.
  var swapped = jpeg
  swapped[swapped.count - 1] ^= 0xFF
  let hex = swapped.map { String(format: "%02X", $0) }.joined()
  #expect(
    sqlite3_exec(
      database,
      "DROP TRIGGER ledger_receipt_attachment_content_immutable; UPDATE ledger_receipt_attachment SET bytes=x'\(hex)'",
      nil, nil, nil) == SQLITE_OK)
  #expect(!CanonicalLedgerHealth.isHealthy(database))
}

@Test func receiptChecksumCoversMetadataAndChangesWithTheLink() throws {
  let (store, _) = try memoryStore()
  let empty = try store.semanticChecksum()
  let receipt = try store.addReceipt(heic, origin: origin, createdAt: at)
  let added = try store.semanticChecksum()
  #expect(added != empty)
  try store.tombstoneReceipt(receipt.id)
  #expect(try store.semanticChecksum() != added)
}

@Test func portablePackageRefusesALedgerWithReceiptsUntilItCanCarryThem() throws {
  let (store, _) = try memoryStore()
  let app = LedgerApplication(store: store)
  let transaction = try expense(app)
  _ = try app.exportPackage()  // exportable before any receipt

  let receipt = try store.addReceipt(
    png, origin: origin, linkedTo: transaction.transactionID, createdAt: at)
  #expect(throws: LedgerApplication.Error.invalidCommand) { try app.exportPackage() }
  // Removing the receipt keeps its bytes, so the package still refuses.
  try store.tombstoneReceipt(receipt.id)
  #expect(throws: LedgerApplication.Error.invalidCommand) { try app.exportPackage() }
}

@Test func addingTheSameImageWithANewLinkRelinksIt() throws {
  let (store, _) = try memoryStore()
  let app = LedgerApplication(store: store)
  let transaction = try expense(app)
  let receipt = try store.addReceipt(png, origin: origin, createdAt: at)
  let relinked = try store.addReceipt(
    png, origin: origin, linkedTo: transaction.transactionID, createdAt: at)
  #expect(relinked.id == receipt.id)
  #expect(relinked.transactionID == transaction.transactionID)
  #expect(try store.receiptAttachments().map(\.transactionID) == [transaction.transactionID])
}

@Test func removingAReceiptTwiceIsUnchanged() throws {
  let (store, _) = try memoryStore()
  let receipt = try store.addReceipt(png, origin: origin, createdAt: at)
  try store.tombstoneReceipt(receipt.id)
  let checksum = try store.semanticChecksum()
  try store.tombstoneReceipt(receipt.id)
  #expect(try store.semanticChecksum() == checksum)
  #expect(try store.receiptAttachments().map(\.lifecycle) == [.tombstoned])
}

/// Opening, backing up and restoring a ledger re-hashes every receipt. This pins the cost for
/// about 200 MB of receipts so a slow change shows up here.
@Test func checkingTwoHundredMegabytesOfReceiptsStaysQuick() throws {
  let (store, database) = try memoryStore()
  let size = LedgerReceiptAttachment.maximumBytes
  for index in 0..<8 {
    var bytes = Data(repeating: UInt8(index), count: size)
    bytes.replaceSubrange(0..<4, with: [0xFF, 0xD8, 0xFF, 0xE0])
    try store.addReceipt(bytes, origin: origin, createdAt: at)
  }
  let clock = ContinuousClock()
  let elapsed = try clock.measure { try CanonicalLedgerHealth.validate(database) }
  print("Receipt health check for 200 MiB took \(elapsed)")
  #expect(elapsed < .seconds(10))
}
