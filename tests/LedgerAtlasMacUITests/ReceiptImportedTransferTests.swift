import CSQLite
import Foundation
import LedgerCore
import LedgerStore
import MMImport
import Testing

// Synthetic data only: a made-up Money Manager backup built from the frozen v19 DDL, with one
// transfer between two made-up accounts.

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array("synthetic-png".utf8))

private enum TransferFixtureError: Swift.Error { case sqlite }

private func execute(at url: URL, sql: String) throws {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw TransferFixtureError.sqlite
  }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw TransferFixtureError.sqlite
  }
}

private func texts(at url: URL, _ sql: String) throws -> [String] {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
    let database
  else { throw TransferFixtureError.sqlite }
  defer { sqlite3_close(database) }
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
    throw TransferFixtureError.sqlite
  }
  defer { sqlite3_finalize(statement) }
  var values: [String] = []
  while sqlite3_step(statement) == SQLITE_ROW {
    values.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
  }
  return values
}

private func writeTransferBackup(to url: URL) throws {
  let ddlURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("docs/compatibility/money-manager-android-v19.schema.sql")
  try execute(at: url, sql: try String(contentsOf: ddlURL, encoding: .utf8))
  try execute(
    at: url,
    sql: """
      INSERT INTO android_metadata (locale) VALUES ('en_US');
      INSERT INTO ASSETGROUP (uid, IS_DEL, ACC_GROUP_NAME, TYPE, ORDERSEQ)
        VALUES ('1', 0, 'Accounts', 1, 1);
      INSERT INTO CURRENCY (uid, NAME, ISO, MAIN_ISO, IS_DEL, RATE, IS_MAIN_CURRENCY, DECIMAL_POINT)
        VALUES ('cur-main', 'Synthetic', 'USD', 'USD', 0, 1.0, 1, 2);
      INSERT INTO ASSETS (uid, NIC_NAME, ZDATA, groupUid, currencyUid, ORDERSEQ)
        VALUES ('acct-a', 'Wallet', '0', '1', 'cur-main', 1),
               ('acct-b', 'Bank', '0', '1', 'cur-main', 2);
      INSERT INTO INOUTCOME
        (uid, assetUid, ctgUid, toAssetUid, txUidTrans, DO_TYPE, ZMONEY, IN_ZMONEY,
         AMOUNT_ACCOUNT, ZDATE, WDATE, ZCONTENT, ZDATA, CARDDIVIDMONTH, currencyUid, UTIME)
      VALUES
        ('tx-transfer-out', 'acct-a', NULL, 'acct-b', 'grp-1', '3', '40.00', '40.00', 40.0,
         '1738547440000', '2025-02-03', '', '', '0', 'cur-main', 1738547440000),
        ('tx-transfer-in', 'acct-b', NULL, 'acct-a', 'grp-1', '4', '40.00', '40.00', 40.0,
         '1738547440000', '2025-02-03', '', '', '0', 'cur-main', 1738547440000);
      """)
}

@Test func anImportedLedgerAcceptsAReceiptLinkedToItsTransfer() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("MM(synthetic).mmbak")
  try writeTransferBackup(to: source)
  let canonical = directory.appendingPathComponent("canonical.sqlite")
  let workspace = ImportWorkspace()
  let preparation = try workspace.prepare(
    .init(
      sourceURL: source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
      canonicalDatabaseURL: canonical,
      sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800)))
  let handle = try #require(preparation.preparedHandle)
  #expect(try workspace.commit(handle, approval: workspace.approve(handle)).status == .committed)
  let transfers = try texts(at: canonical, "SELECT transfer_id FROM economic_event_transfer")
  let transferID = try #require(transfers.first)
  #expect(transfers.count == 1)

  let origin = try LedgerOrigin.macNative()
  do {
    let opened = try LedgerStoreLifecycle.open(at: canonical)
    let receipt = try opened.store.addReceipt(
      png, origin: origin, linkedTo: transferID, createdAt: UTCInstant(epochMilliseconds: 1))
    #expect(receipt.transactionID == transferID)
  }
  // The link survives reopening, and the health check accepts it.
  let reopened = try LedgerStore.openReadOnly(at: canonical)
  #expect(try reopened.receiptAttachments().map(\.transactionID) == [transferID])
}
