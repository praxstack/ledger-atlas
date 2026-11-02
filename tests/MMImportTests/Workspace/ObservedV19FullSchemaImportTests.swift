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

      // income, expense, balance edits recorded as income (0, -4) and expense (1, -4), a
      // balance increase left out of income (7, -4) as an adjustment, a balance decrease left
      // out of expenses (8, -4) as a decreasing adjustment, and both legs of the grp-1
      // transfer. The orphan leg and the same-account pair stay preserved.
      #expect(result.status == .committed)
      #expect(result.eventCount == 8)
      #expect(try SQLiteCanonicalCommitter().eventCount(at: canonical) == 8)
      #expect(try scalar(at: canonical, "SELECT count(*) FROM economic_event_transfer") == 1)
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM economic_event_transfer t JOIN economic_event d ON d.event_id=t.debit_event_id JOIN economic_event c ON c.event_id=t.credit_event_id WHERE d.event_kind='transfer_debit' AND c.event_kind='transfer_credit' AND d.amount_literal='40.00' AND c.amount_literal='40.00'"
        ) == 1)
      #expect(try Data(contentsOf: source) == sourceBefore)

      let retry = try workspace.prepare(
        .init(
          sourceURL: source, stagingDatabaseURL: directory.appendingPathComponent("stage-2.sqlite"),
          canonicalDatabaseURL: canonical,
          sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800)))
      let retryHandle = try #require(retry.preparedHandle)
      let second = try workspace.commit(retryHandle, approval: workspace.approve(retryHandle))
      #expect(second.status == .unchanged)
      #expect(try SQLiteCanonicalCommitter().eventCount(at: canonical) == 8)
      #expect(try scalar(at: canonical, "SELECT count(*) FROM economic_event_transfer") == 1)
    }
  }

  @Test("every source field survives import: photos, recurring rules and drift columns")
  func preservesEverySourceField() throws {
    try withDirectory { directory in
      let source = directory.appendingPathComponent("MM(synthetic).mmbak")
      try writeFullSchemaBackup(to: source)
      // Additive drift: a column and a table that a future Money Manager might add.
      try execute(
        at: source,
        sql: """
          ALTER TABLE INOUTCOME ADD COLUMN ZFUTURE_COLUMN TEXT;
          UPDATE INOUTCOME SET ZFUTURE_COLUMN = 'future-' || uid;
          CREATE TABLE ZFUTURE_TABLE (uid TEXT PRIMARY KEY, note TEXT);
          INSERT INTO ZFUTURE_TABLE (uid, note) VALUES ('future-1', 'synthetic');
          INSERT INTO PHOTO (uid, IS_DEL, txUid, FILE_SIZE, FILE_PATH, FILE_NAME)
            VALUES ('photo-gone', 1, 'tx-missing', 11, '/synthetic/gone.jpg', 'gone.jpg');
          """)
      let staging = directory.appendingPathComponent("stage.sqlite")
      let canonical = directory.appendingPathComponent("canonical.sqlite")
      let workspace = ImportWorkspace()
      let preparation = try workspace.prepare(
        .init(
          sourceURL: source, stagingDatabaseURL: staging, canonicalDatabaseURL: canonical,
          sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800)))
      #expect(preparation.review.blockingCount == 0)
      let handle = try #require(preparation.preparedHandle)
      let result = try workspace.commit(handle, approval: workspace.approve(handle))
      #expect(result.status == .committed)

      // The drift really was staged, so the checks below cover it.
      #expect(
        try scalar(
          at: staging, "SELECT count(*) FROM staged_field WHERE column_name='ZFUTURE_COLUMN'")
          > 0)

      // No staged field is missing from the canonical store: each one is a semantic binding,
      // an event sidecar, or a receipt-owned preservation payload.
      #expect(
        try scalar(
          at: canonical, attaching: staging,
          """
          SELECT count(*) FROM s.staged_field f WHERE f.field_id NOT IN (
            SELECT provenance_id FROM event_source_binding
            UNION SELECT provenance_id FROM sidecar_reference
            UNION SELECT source_subject_id FROM receipt_preservation_payload)
          """) == 0)

      // Preserved bytes are the staged bytes, not a re-encoding.
      #expect(
        try scalar(
          at: canonical, attaching: staging,
          "SELECT count(*) FROM receipt_preservation_payload x JOIN s.staged_field f ON f.field_id=x.source_subject_id WHERE x.payload<>f.payload OR x.storage_class<>f.storage_class OR x.declared_type IS NOT f.declared_type"
        ) == 0)
      #expect(
        try scalar(
          at: canonical, attaching: staging,
          "SELECT count(*) FROM sidecar_reference x JOIN s.staged_field f ON f.field_id=x.sidecar_id WHERE x.payload<>f.payload OR x.storage_class<>f.storage_class OR x.declared_type IS NOT f.declared_type"
        ) == 0)

      // Attachments keep their path metadata only, including a photo whose transaction is gone.
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM receipt_preservation_payload x JOIN provenance_reference p ON p.provenance_id=x.provenance_id WHERE p.source_table='PHOTO' AND p.source_column_name='FILE_PATH' AND CAST(x.payload AS TEXT) IN ('/synthetic/photo.jpg','/synthetic/gone.jpg')"
        ) == 2)
      // The recurring rule keeps its schedule code.
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM receipt_preservation_payload x JOIN provenance_reference p ON p.provenance_id=x.provenance_id WHERE p.source_table='REPEATTRANSACTION' AND p.source_column_name='REPEAT_TYPE'"
        ) == 1)
      // The unknown table is preserved too.
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM receipt_preservation_payload x JOIN provenance_reference p ON p.provenance_id=x.provenance_id WHERE p.source_table='ZFUTURE_TABLE'"
        ) == 2)
    }
  }

  @Test("balance edits and transfer legs map only with the expected category")
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
    #expect(MoneyManagerV19Vocabulary.eventKind(forType: "8") == .adjustmentDebit)
    #expect(MoneyManagerV19Vocabulary.reason(forType: "8", categoryUID: "-4") == nil)
    #expect(
      MoneyManagerV19Vocabulary.reason(forType: "8", categoryUID: "cat-food")
        == .unsupportedTransactionType)
    #expect(MoneyManagerV19Vocabulary.eventKind(forType: "9") == nil)
    #expect(MoneyManagerV19Vocabulary.reason(forType: "3", categoryUID: nil) == nil)
    #expect(MoneyManagerV19Vocabulary.reason(forType: "4", categoryUID: "") == nil)
    #expect(
      MoneyManagerV19Vocabulary.reason(forType: "3", categoryUID: "cat-food")
        == .transferDirectionUnproven)
    #expect(MoneyManagerV19Vocabulary.eventKind(forType: "3") == .transferDebit)
    #expect(MoneyManagerV19Vocabulary.eventKind(forType: "4") == .transferCredit)
    #expect(
      MoneyManagerV19Vocabulary.transferID(debitEventID: "d", creditEventID: "c")
        == MoneyManagerV19Vocabulary.transferID(debitEventID: "d", creditEventID: "c"))
    #expect(
      MoneyManagerV19Vocabulary.transferID(debitEventID: "d", creditEventID: "c")
        != MoneyManagerV19Vocabulary.transferID(debitEventID: "c", creditEventID: "d"))
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
         '1738547440000', '2025-02-03', '', '', '0', 'cur-main', 1738547440000),
        ('tx-orphan-out', 'acct-a', NULL, 'acct-b', 'grp-2', '3', '5.00', '5.00', 5.0,
         '1738547500000', '2025-02-03', '', '', '0', 'cur-main', 1738547500000),
        ('tx-self-out', 'acct-a', '', 'acct-a', 'grp-3', '3', '6.00', '6.00', 6.0,
         '1738547560000', '2025-02-03', '', '', '0', 'cur-main', 1738547560000),
        ('tx-self-in', 'acct-a', '', 'acct-a', 'grp-3', '4', '6.00', '6.00', 6.0,
         '1738547560001', '2025-02-03', '', '', '0', 'cur-main', 1738547560001);
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

private func scalar(at url: URL, _ sql: String) throws -> Int {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
    let database
  else { throw FullSchemaTestError.sqlite }
  defer { sqlite3_close(database) }
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
    throw FullSchemaTestError.sqlite
  }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement) == SQLITE_ROW else { throw FullSchemaTestError.sqlite }
  return Int(sqlite3_column_int64(statement, 0))
}

private func scalar(at url: URL, attaching attached: URL, _ sql: String) throws -> Int {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
    let database
  else { throw FullSchemaTestError.sqlite }
  defer { sqlite3_close(database) }
  let escaped = attached.path.replacingOccurrences(of: "'", with: "''")
  guard sqlite3_exec(database, "ATTACH DATABASE '\(escaped)' AS s", nil, nil, nil)
    == SQLITE_OK
  else { throw FullSchemaTestError.sqlite }
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
    throw FullSchemaTestError.sqlite
  }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement) == SQLITE_ROW else { throw FullSchemaTestError.sqlite }
  return Int(sqlite3_column_int64(statement, 0))
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
