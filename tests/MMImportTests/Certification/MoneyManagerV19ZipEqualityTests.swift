import CSQLite
import Foundation
import LedgerCore
import Testing

@testable import MMImport

/// Release certification for Money Manager v19 import (#54): a backup imported as a plain
/// SQLite `.mmbak` and the same bytes wrapped in a ZIP `.mmbak` must produce the same ledger.
/// Every case runs on a synthetic backup built from the frozen v19 DDL
/// (docs/compatibility/money-manager-android-v19.schema.sql).
@Suite("Money Manager v19 direct and ZIP equality")
struct MoneyManagerV19ZipEqualityTests {
  @Test("a ZIP-wrapped backup imports to the same ledger as the plain file", arguments: [false, true])
  func zipMatchesDirect(compressed: Bool) throws {
    try withDirectory { directory in
      let direct = directory.appendingPathComponent("MM(synthetic).mmbak")
      try writeFullSchemaBackup(to: direct)
      let zipped = directory.appendingPathComponent("MM(synthetic-zip).mmbak")
      try zip(direct, to: zipped, compressed: compressed)
      let directBytes = try Data(contentsOf: direct)
      let zippedBytes = try Data(contentsOf: zipped)

      let directRun = try importBackup(direct, named: "direct", in: directory)
      let zippedRun = try importBackup(zipped, named: "zipped", in: directory)

      #expect(directRun.container == .sqlite)
      #expect(zippedRun.container == .zip)
      #expect(directRun.result.status == .committed)
      #expect(zippedRun.result.status == .committed)
      #expect(zippedRun.result.eventCount == directRun.result.eventCount)
      #expect(zippedRun.report.reportHash == directRun.report.reportHash)
      #expect(zippedRun.report.mappedCount == directRun.report.mappedCount)
      #expect(zippedRun.report.preservedCount == directRun.report.preservedCount)
      #expect(zippedRun.report.excludedCount == directRun.report.excludedCount)
      #expect(zippedRun.report.blockingCount == 0)
      #expect(try eventSet(at: zippedRun.canonical) == eventSet(at: directRun.canonical))
      #expect(!(try eventSet(at: directRun.canonical)).isEmpty)

      #expect(try Data(contentsOf: direct) == directBytes)
      #expect(try Data(contentsOf: zipped) == zippedBytes)

      for run in [directRun, zippedRun] {
        let again = try importBackup(
          run.source, named: "\(run.name)-again", canonical: run.canonical, in: directory)
        #expect(again.result.status == .unchanged)
      }
      // The ZIP is the same backup, so importing it into the plain file's ledger adds nothing.
      let cross = try importBackup(
        zipped, named: "zipped-into-direct", canonical: directRun.canonical, in: directory)
      #expect(cross.result.status == .unchanged)
      #expect(try Data(contentsOf: direct) == directBytes)
      #expect(try Data(contentsOf: zipped) == zippedBytes)
    }
  }
}

private struct ImportRun {
  let name: String
  let source: URL
  let canonical: URL
  let container: SourceContainer
  let report: ReconciliationReport
  let result: ImportWorkspace.CommitResult
}

/// Imports through `ImportWorkspace`, the app's own path, and recomputes the reconciliation
/// report the workspace reviewed so its hash can be compared.
private func importBackup(
  _ source: URL, named name: String, canonical: URL? = nil, in directory: URL
) throws -> ImportRun {
  let canonical = canonical ?? directory.appendingPathComponent("\(name)-canonical.sqlite")
  let timeZone = try SourceTimeZone(fixedOffsetSeconds: 19_800)
  let classification = SourceClassifier(profiles: SourceProfile.moneyManagerImportProfiles)
    .classify(source)
  let reportStaging = directory.appendingPathComponent("\(name)-report-stage.sqlite")
  let staging = try ImmutableSourceStager(classifier: { _ in classification }).stage(
    .init(
      sourceURL: source, stagingDatabaseURL: reportStaging,
      adapterVersion: MoneyManagerV19Adapter.version))
  let report = try SQLiteCanonicalCommitter().prepare(
    MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: canonical, stagingDatabaseURL: reportStaging,
      expectedManifest: staging.manifest, expectedContentDigest: staging.stagingDigest,
      sourceTimeZone: timeZone))

  let workspace = ImportWorkspace()
  let preparation = try workspace.prepare(
    .init(
      sourceURL: source,
      stagingDatabaseURL: directory.appendingPathComponent("\(name)-stage.sqlite"),
      canonicalDatabaseURL: canonical, sourceTimeZone: timeZone))
  #expect(preparation.review.mappedCount == report.mappedCount)
  #expect(preparation.review.preservedCount == report.preservedCount)
  #expect(preparation.review.excludedCount == report.excludedCount)
  let handle = try #require(preparation.preparedHandle)
  let result = try workspace.commit(handle, approval: workspace.approve(handle))
  return .init(
    name: name, source: source, canonical: canonical, container: classification.container,
    report: report, result: result)
}

/// Every economic event as one row of text, so two ledgers compare as sets.
private func eventSet(at url: URL) throws -> Set<String> {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
    let database
  else { throw ZipEqualityTestError.sqlite }
  defer { sqlite3_close(database) }
  var statement: OpaquePointer?
  let sql = """
    SELECT event_id || '|' || account_id || '|' || event_kind || '|' || amount_literal || '|'
      || currency_unit || '|' || instant_milliseconds || '|' || local_year || '-' || local_month
      || '-' || local_day || '|' || timezone_kind || '|' || timezone_value || '|'
      || source_record_id
    FROM economic_event
    """
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
    throw ZipEqualityTestError.sqlite
  }
  defer { sqlite3_finalize(statement) }
  var rows = Set<String>()
  while sqlite3_step(statement) == SQLITE_ROW {
    rows.insert(String(cString: sqlite3_column_text(statement, 0)))
  }
  return rows
}

private func zip(_ source: URL, to archive: URL, compressed: Bool) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
  process.arguments = ["-q", "-j", compressed ? "-6" : "-0", archive.path, source.path]
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { throw ZipEqualityTestError.zip }
}

private func frozenDDL() throws -> String {
  let ddlURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("docs/compatibility/money-manager-android-v19.schema.sql")
  return try String(contentsOf: ddlURL, encoding: .utf8)
}

/// Income, expense, balance edits and a transfer pair, enough to exercise every mapping.
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
               ('cat-food', 'Food', 1, 0, '0', 0);
      INSERT INTO INOUTCOME
        (uid, assetUid, ctgUid, toAssetUid, txUidTrans, DO_TYPE, ZMONEY, IN_ZMONEY,
         AMOUNT_ACCOUNT, ZDATE, WDATE, ZCONTENT, ZDATA, CARDDIVIDMONTH, currencyUid, UTIME)
      VALUES
        ('tx-income', 'acct-b', 'cat-salary', NULL, NULL, '0', '100.00', '100.00', 100.0,
         '1738547200000', '2025-02-03', 'synthetic', '', '0', 'cur-main', 1738547200000),
        ('tx-expense', 'acct-a', 'cat-food', NULL, NULL, '1', '12.50', '12.50', 12.5,
         '1738547260000', '2025-02-03', 'synthetic', '', '0', 'cur-main', 1738547260000),
        ('tx-balance-up', 'acct-a', '-4', NULL, NULL, '0', '3.00', '3.00', 3.0,
         '1738547320000', '2025-02-03', 'Difference', '', '0', 'cur-main', 1738547320000),
        ('tx-balance-down', 'acct-b', '-4', NULL, NULL, '1', '2.00', '2.00', 2.0,
         '1738547380000', '2025-02-03', 'Difference', '', '0', 'cur-main', 1738547380000),
        ('tx-transfer-out', 'acct-a', NULL, 'acct-b', 'grp-1', '3', '40.00', '40.00', 40.0,
         '1738547440000', '2025-02-03', '', '', '0', 'cur-main', 1738547440000),
        ('tx-transfer-in', 'acct-b', NULL, 'acct-a', 'grp-1', '4', '40.00', '40.00', 40.0,
         '1738547440000', '2025-02-03', '', '', '0', 'cur-main', 1738547440000);
      """)
}

private func execute(at url: URL, sql: String) throws {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
      == SQLITE_OK,
    let database
  else { throw ZipEqualityTestError.sqlite }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw ZipEqualityTestError.sqlite
  }
}

private func withDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "v19-zip-equality-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private enum ZipEqualityTestError: Error { case sqlite, zip }
