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
      // Only the monthly rule maps: weekend has no Ledger Atlas frequency and 1.005 is not an
      // exact two-decimal amount, so those two stay preserved raw. The rule starts on NEXT_DATE
      // (2025-03-03 at +05:30) so already generated rows are not generated again.
      #expect(try scalar(at: canonical, "SELECT count(*) FROM ledger_recurrence_rule") == 1)
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM ledger_recurrence_rule WHERE kind='expense' AND amount_literal='9.99' AND currency_unit='USD' AND frequency='monthly' AND interval=1 AND day_of_month=3 AND start_year=2025 AND start_month=3 AND start_day=3 AND until_year IS NULL AND paused=0 AND lifecycle='active' AND timezone_kind='fixed' AND timezone_value='19800'"
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
      #expect(try scalar(at: canonical, "SELECT count(*) FROM ledger_recurrence_rule") == 1)
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
      // Every recurring rule keeps its schedule code, mapped or not.
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM receipt_preservation_payload x JOIN provenance_reference p ON p.provenance_id=x.provenance_id WHERE p.source_table='REPEATTRANSACTION' AND p.source_column_name='REPEAT_TYPE'"
        ) == 3)
      // The unknown table is preserved too.
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM receipt_preservation_payload x JOIN provenance_reference p ON p.provenance_id=x.provenance_id WHERE p.source_table='ZFUTURE_TABLE'"
        ) == 2)
    }
  }

  @Test("a backup missing a core binding column is refused before anything is written")
  func refusesMissingContractColumn() throws {
    // Indexed columns lose their index first; SQLite cannot drop an indexed column.
    let cases = [
      "ALTER TABLE INOUTCOME DROP COLUMN ZMONEY;",
      "DROP INDEX INOUTCOME_IDX3; ALTER TABLE INOUTCOME DROP COLUMN ZDATE;",
      "DROP INDEX INOUTCOME_IDX4; ALTER TABLE INOUTCOME DROP COLUMN WDATE;",
      "DROP INDEX INOUTCOME_IDX2; ALTER TABLE INOUTCOME DROP COLUMN DO_TYPE;",
      "DROP INDEX INOUTCOME_IDX7; ALTER TABLE INOUTCOME DROP COLUMN assetUid;",
      "DROP INDEX INOUTCOME_IDX8; ALTER TABLE INOUTCOME DROP COLUMN ctgUid;",
      "DROP INDEX INOUTCOME_IDX9; ALTER TABLE INOUTCOME DROP COLUMN currencyUid;",
      "DROP INDEX UNIQUE_IDX_INOUTCOME_UID; ALTER TABLE INOUTCOME DROP COLUMN uid;",
      "ALTER TABLE CURRENCY DROP COLUMN ISO;",
    ]
    for sql in cases {
      try withDirectory { directory in
        let source = directory.appendingPathComponent("MM(synthetic).mmbak")
        try writeFullSchemaBackup(to: source)
        try execute(at: source, sql: sql)
        let canonical = directory.appendingPathComponent("canonical.sqlite")
        let preparation = try ImportWorkspace().prepare(
          .init(
            sourceURL: source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
            canonicalDatabaseURL: canonical,
            sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800)))
        #expect(preparation.preparedHandle == nil, "\(sql)")
        #expect(preparation.review.status == .classificationOnly, "\(sql)")
        #expect(preparation.review.classificationStatus == .unsupported, "\(sql)")
        #expect(preparation.review.diagnosticCodes == ["schema_drift"], "\(sql)")
        #expect(!FileManager.default.fileExists(atPath: canonical.path), "\(sql)")
      }
    }
  }

  @Test("a transaction carrying a deletion flag is preserved, never imported")
  func flaggedDeletedRowIsPreserved() throws {
    try withDirectory { directory in
      let source = directory.appendingPathComponent("MM(synthetic).mmbak")
      try writeFullSchemaBackup(to: source)
      try execute(at: source, sql: "UPDATE INOUTCOME SET IS_DEL=1 WHERE uid='tx-expense';")
      let canonical = directory.appendingPathComponent("canonical.sqlite")
      let workspace = ImportWorkspace()
      let preparation = try workspace.prepare(
        .init(
          sourceURL: source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
          canonicalDatabaseURL: canonical,
          sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800)))
      #expect(preparation.review.losslessCertificationBlocked == true)
      let handle = try #require(preparation.preparedHandle)
      let result = try workspace.commit(handle, approval: workspace.approve(handle))
      #expect(result.eventCount == 7)
    }
  }

  @Test("the contract column table matches the frozen v19 DDL")
  func contractMatchesFrozenDDL() throws {
    var database: OpaquePointer?
    guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else {
      throw FullSchemaTestError.sqlite
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, try frozenDDL(), nil, nil, nil) == SQLITE_OK else {
      throw FullSchemaTestError.sqlite
    }
    var fromDDL: [String: [String]] = [:]
    var tables: OpaquePointer?
    guard sqlite3_prepare_v2(
      database, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
      -1, &tables, nil) == SQLITE_OK, let tables
    else { throw FullSchemaTestError.sqlite }
    defer { sqlite3_finalize(tables) }
    while sqlite3_step(tables) == SQLITE_ROW {
      let name = String(cString: sqlite3_column_text(tables, 0))
      var info: OpaquePointer?
      guard sqlite3_prepare_v2(database, "PRAGMA table_info(\"\(name)\")", -1, &info, nil)
        == SQLITE_OK, let info
      else { throw FullSchemaTestError.sqlite }
      var columns: [String] = []
      while sqlite3_step(info) == SQLITE_ROW {
        columns.append(String(cString: sqlite3_column_text(info, 1)))
      }
      sqlite3_finalize(info)
      fromDDL[name] = columns
    }
    #expect(fromDDL == MoneyManagerV19Contract.androidTables)
  }

  @Test("ZDATE is a UTC instant: an early-morning IST row lands on its WDATE day")
  func zdateIsUTCInstant() throws {
    try withDirectory { directory in
      let source = directory.appendingPathComponent("MM(synthetic).mmbak")
      try writeFullSchemaBackup(to: source)
      // 2026-01-01T19:30Z is 01:00 on 2 January at +05:30, the day WDATE records.
      try execute(
        at: source,
        sql: "UPDATE INOUTCOME SET ZDATE='1767295800000', WDATE='2026-01-02' WHERE uid='tx-expense';")
      let canonical = directory.appendingPathComponent("canonical.sqlite")
      let workspace = ImportWorkspace()
      let preparation = try workspace.prepare(
        .init(
          sourceURL: source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
          canonicalDatabaseURL: canonical,
          sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800)))
      let handle = try #require(preparation.preparedHandle)
      let result = try workspace.commit(handle, approval: workspace.approve(handle))
      #expect(result.status == .committed)
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM economic_event WHERE instant_milliseconds=1767295800000 AND local_year=2026 AND local_month=1 AND local_day=2 AND local_hour=1 AND local_minute=0 AND resolved_offset_seconds=19800"
        ) == 1)
    }
  }

  @Test("replay accepts current UTC-instant events and legacy local-epoch events")
  func replayAcceptsBothZDATEReadings() throws {
    let ist = try SourceTimeZone(fixedOffsetSeconds: 19_800)
    let current = try #require(
      MoneyManagerV19Vocabulary.temporal(zdateEpochMilliseconds: 1_767_295_800_000, in: ist))
    #expect(current.localDateTime.date == (try SourceLocalDate(year: 2026, month: 1, day: 2)))
    #expect(current.localDateTime.hour == 1)
    #expect(MoneyManagerV19Vocabulary.occurredMatches("1767295800000", current))
    // An earlier build read the same literal as 19:30 local on 1 January.
    let legacyLocal = try SourceLocalDateTime(
      date: SourceLocalDate(year: 2026, month: 1, day: 1), hour: 19, minute: 30, second: 0,
      millisecond: 0)
    let legacy = try SourceTemporal(
      resolving: legacyLocal, in: ist, precision: .millisecond, ambiguityPolicy: .reject)
    #expect(MoneyManagerV19Vocabulary.occurredMatches("1767295800000", legacy))
    #expect(!MoneyManagerV19Vocabulary.occurredMatches("1767295800001", current))
    // A legacy wall time with an instant that is not that wall time in the zone is rejected,
    // for an IANA zone as well as a fixed offset.
    let kolkata = try SourceTimeZone(ianaIdentifier: "Asia/Kolkata")
    let legacyKolkata = try SourceTemporal(
      resolving: legacyLocal, in: kolkata, precision: .millisecond, ambiguityPolicy: .reject)
    #expect(MoneyManagerV19Vocabulary.occurredMatches("1767295800000", legacyKolkata))
    let wrongInstant = try SourceTemporal(
      instant: UTCInstant(epochMilliseconds: 1_767_295_800_000), localDateTime: legacyLocal,
      timeZone: kolkata, precision: .millisecond, resolvedOffsetSeconds: 0)
    #expect(!MoneyManagerV19Vocabulary.occurredMatches("1767295800000", wrongInstant))
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
    #expect(MoneyManagerV19Vocabulary.recurrence(forRepeatType: "1")?.frequency == .monthly)
    #expect(MoneyManagerV19Vocabulary.recurrence(forRepeatType: "7")?.interval == 2)
    #expect(MoneyManagerV19Vocabulary.recurrence(forRepeatType: "17")?.frequency == .yearly)
    #expect(MoneyManagerV19Vocabulary.recurrence(forRepeatType: "10") == nil)
    #expect(MoneyManagerV19Vocabulary.recurrence(forRepeatType: "2") == nil)
    func real(_ value: Double) -> Data {
      withUnsafeBytes(of: value.bitPattern.bigEndian) { Data($0) }
    }
    #expect(MoneyManagerV19Vocabulary.recurrenceAmountLiteral(realPayload: real(9.99)) == "9.99")
    #expect(MoneyManagerV19Vocabulary.recurrenceAmountLiteral(realPayload: real(1500)) == "1500.00")
    #expect(MoneyManagerV19Vocabulary.recurrenceAmountLiteral(realPayload: real(1.005)) == nil)
    #expect(MoneyManagerV19Vocabulary.recurrenceAmountLiteral(realPayload: real(0)) == nil)
    #expect(MoneyManagerV19Vocabulary.recurrenceAmountLiteral(realPayload: real(-5)) == nil)
    let ist = try SourceTimeZone(fixedOffsetSeconds: 19_800)
    // 2025-03-02T18:30:00Z is local midnight of 3 March at +05:30.
    #expect(
      MoneyManagerV19Vocabulary.localDate(epochMilliseconds: 1_740_940_200_000, in: ist)
        == (try SourceLocalDate(year: 2025, month: 3, day: 3)))
    #expect(
      MoneyManagerV19Vocabulary.localDate(epochMilliseconds: 1_740_940_199_999, in: ist)
        == (try SourceLocalDate(year: 2025, month: 3, day: 2)))
  }
}

private func frozenDDL() throws -> String {
  let ddlURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("docs/compatibility/money-manager-android-v19.schema.sql")
  return try String(contentsOf: ddlURL, encoding: .utf8)
}

private func writeFullSchemaBackup(to url: URL) throws {
  try execute(at: url, sql: try frozenDDL())
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
          'synthetic'),
          ('rule-weekend', 0, 0, 1741000000000, 1, 10, 'acct-a', 'cat-food', 'cur-main', 5.0, '',
          'synthetic'),
          ('rule-inexact', 0, 0, 1741000000000, 1, 5, 'acct-a', 'cat-food', 'cur-main', 1.005, '',
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
