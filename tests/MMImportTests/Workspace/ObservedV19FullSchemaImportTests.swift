import CSQLite
import Foundation
import LedgerCore
import Testing

@testable import MMImport

/// End-to-end import of a synthetic backup built from the frozen v19 DDL
/// (docs/compatibility/money-manager-android-v19.schema.sql). The DDL is byte-for-byte the
/// observed Android schema, so this exercises the real 19-table profile with synthetic rows.
@Suite("Observed Android v19 full-schema import")
struct ObservedV19FullSchemaImportTests {
  @Test("full v19 schema classifies as the observed profile and imports without blocking")
  func importsFullSchemaBackup() throws {
    try withDirectory { directory in
      let source = directory.appendingPathComponent("MM(synthetic).mmbak")
      try writeFullSchemaBackup(to: source)
      let sourceBefore = try Data(contentsOf: source)
      let canonical = directory.appendingPathComponent("canonical.sqlite")
      let workspace = ImportWorkspace()

      let preparation = try workspace.prepare(
        .init(
          sourceURL: source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
          canonicalDatabaseURL: canonical,
          sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800)))

      #expect(preparation.review.status == .prepared)
      #expect(preparation.review.classificationStatus == .supported)
      #expect(preparation.review.blockingCount == 0)
      let handle = try #require(preparation.preparedHandle)
      let result = try workspace.commit(handle, approval: workspace.approve(handle))

      // income, expense, balance edits recorded as income (0, -4) and expense (1, -4), and a
      // balance increase left out of income (7, -4) as an adjustment. The balance decrease left
      // out of expenses (8, -4) and the transfer legs stay preserved for now.
      #expect(result.status == .committed)
      #expect(result.eventCount == 5)
      #expect(try SQLiteCanonicalCommitter().eventCount(at: canonical) == 5)
      #expect(try Data(contentsOf: source) == sourceBefore)

      let retry = try workspace.prepare(
        .init(
          sourceURL: source, stagingDatabaseURL: directory.appendingPathComponent("stage-2.sqlite"),
          canonicalDatabaseURL: canonical,
          sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800)))
      let retryHandle = try #require(retry.preparedHandle)
      let second = try workspace.commit(retryHandle, approval: workspace.approve(retryHandle))
      #expect(second.status == .unchanged)
      #expect(try SQLiteCanonicalCommitter().eventCount(at: canonical) == 5)
    }
  }

  @Test("type 7 maps to an adjustment only with the built-in balance-edit category")
  func balanceIncreaseNeedsBuiltInCategory() throws {
    #expect(MoneyManagerV19Vocabulary.reason(forType: "7", categoryUID: "-4") == nil)
    #expect(
      MoneyManagerV19Vocabulary.reason(forType: "7", categoryUID: "cat-food")
        == .unknownTransactionType)
    #expect(
      MoneyManagerV19Vocabulary.reason(forType: "7", categoryUID: nil) == .unknownTransactionType)
    #expect(
      MoneyManagerV19Vocabulary.reason(forType: "3", categoryUID: "-4")
        == .transferDirectionUnproven)
    #expect(MoneyManagerV19Vocabulary.eventKind(forType: "0") == .income)
    #expect(MoneyManagerV19Vocabulary.eventKind(forType: "1") == .expense)
    #expect(MoneyManagerV19Vocabulary.eventKind(forType: "7") == .adjustment)
    #expect(MoneyManagerV19Vocabulary.eventKind(forType: "8") == nil)
    #expect(MoneyManagerV19Vocabulary.reason(forType: "8", categoryUID: "-4") != nil)
    #expect(MoneyManagerV19Vocabulary.categoryResolves("-4", known: []))
    #expect(!MoneyManagerV19Vocabulary.categoryResolves("missing", known: ["cat-food"]))
  }
}

private func writeFullSchemaBackup(to url: URL) throws {
  let ddlURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("docs/compatibility/money-manager-android-v19.schema.sql")
  let ddl = try String(contentsOf: ddlURL, encoding: .utf8)
  try execute(at: url, sql: ddl)
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
      INSERT INTO ZCATEGORY (uid, NAME, TYPE, STATUS, pUid, C_IS_DEL)
        VALUES ('cat-salary', 'Salary', 0, 0, '0', 0),
               ('cat-food', 'Food', 1, 0, '0', 0),
               ('cat-snacks', 'Snacks', 1, 2, 'cat-food', 0);
      INSERT INTO INOUTCOME
        (uid, assetUid, ctgUid, toAssetUid, txUidTrans, DO_TYPE, ZMONEY, IN_ZMONEY,
         AMOUNT_ACCOUNT, ZDATE, WDATE, ZCONTENT, ZDATA, CARDDIVIDMONTH, currencyUid, UTIME)
      VALUES
        ('tx-income', 'acct-b', 'cat-salary', NULL, NULL, '0', '100.00', '100.00', 100.0,
         '1738547200000', '2025-02-03', 'synthetic', '', '0', 'cur-main', 1738547200000),
        ('tx-expense', 'acct-a', 'cat-snacks', NULL, NULL, '1', '12.50', '12.50', 12.5,
         '1738547260000', '2025-02-03', 'synthetic', '', '0', 'cur-main', 1738547260000),
        ('tx-balance-up', 'acct-a', '-4', NULL, NULL, '0', '3.00', '3.00', 3.0,
         '1738547320000', '2025-02-03', 'Difference', '', '0', 'cur-main', 1738547320000),
        ('tx-balance-down', 'acct-b', '-4', NULL, NULL, '1', '2.00', '2.00', 2.0,
         '1738547380000', '2025-02-03', 'Difference', '', '0', 'cur-main', 1738547380000),
        ('tx-balance-up-quiet', 'acct-b', '-4', NULL, NULL, '7', '4.00', '4.00', 4.0,
         '1738547390000', '2025-02-03', 'Difference', '', '0', 'cur-main', 1738547390000),
        ('tx-balance-down-quiet', 'acct-a', '-4', NULL, NULL, '8', '1.00', '1.00', 1.0,
         '1738547395000', '2025-02-03', 'Difference', '', '0', 'cur-main', 1738547395000),
        ('tx-transfer-out', 'acct-a', NULL, 'acct-b', 'grp-1', '3', '40.00', '40.00', 40.0,
         '1738547440000', '2025-02-03', '', '', '0', 'cur-main', 1738547440000),
        ('tx-transfer-in', 'acct-b', NULL, 'acct-a', 'grp-1', '4', '40.00', '40.00', 40.0,
         '1738547440000', '2025-02-03', '', '', '0', 'cur-main', 1738547440000);
      INSERT INTO PHOTO (uid, IS_DEL, txUid, FILE_SIZE, FILE_PATH, FILE_NAME)
        VALUES ('photo-1', 0, 'tx-expense', 10, '/synthetic/photo.jpg', 'photo.jpg');
      INSERT INTO REPEATTRANSACTION (uid, IS_DEL, END_DATE, NEXT_DATE, DO_TYPE, REPEAT_TYPE,
        assetUid, ctgUid, currencyUid, AMOUNT_SUB, MEMO, PAYEE)
        VALUES ('rule-1', 0, 0, 1741000000000, 1, 1, 'acct-a', 'cat-food', 'cur-main', 9.99, '',
          'synthetic');
      INSERT INTO TAG (uid, name, isDel) VALUES ('tag-1', 'synthetic', 0);
      INSERT INTO ZETC (uid, ZDATATYPE, ZDATA) VALUES ('etc-1', 100, 'en');
      INSERT INTO BUDGET (uid, targetUid, DO_TYPE, PERIOD_TYPE, IS_DEL)
        VALUES ('budget-1', 'cat-food', 1, 6, 0);
      INSERT INTO BUDGET_AMOUNT (uid, budgetUid, IS_DEL, AMOUNT) VALUES ('ba-1', 'budget-1', 0, 50.0);
      """)
}

private func execute(at url: URL, sql: String) throws {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
      == SQLITE_OK,
    let database
  else { throw FullSchemaTestError.sqlite }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw FullSchemaTestError.sqlite
  }
}

private func withDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "observed-v19-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private enum FullSchemaTestError: Error { case sqlite }
