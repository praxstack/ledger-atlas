import CSQLite
import Foundation
import LedgerCore
import Testing

@testable import MMImport

/// Release certification for Money Manager v19 import (#54). Every case runs on a synthetic
/// backup built from the frozen v19 DDL (docs/compatibility/money-manager-android-v19.schema.sql)
/// and checks the canonical file with SQL, so a pass means the property holds in the store
/// itself rather than in a summary the importer reports about itself.
@Suite("Money Manager v19 certification")
struct MoneyManagerV19CertificationTests {
  // MARK: (a) Unsupported exports fail visibly

  @Test("a backup with another user_version is refused before anything is written")
  func refusesWrongUserVersion() throws {
    try withDirectory { directory in
      let source = directory.appendingPathComponent("MM(synthetic).mmbak")
      try writeFullSchemaBackup(to: source)
      try execute(at: source, sql: "PRAGMA user_version = 20;")
      try expectRefused(source: source, in: directory, diagnostic: "unknown_source_profile")
    }
  }

  @Test("a backup missing a core contract table is refused before anything is written")
  func refusesMissingContractTable() throws {
    try withDirectory { directory in
      let source = directory.appendingPathComponent("MM(synthetic).mmbak")
      try writeFullSchemaBackup(to: source)
      try execute(at: source, sql: "DROP TABLE CURRENCY;")
      try expectRefused(source: source, in: directory, diagnostic: "schema_drift")
    }
  }

  @Test("a file that is not SQLite is refused before anything is written")
  func refusesNonSQLiteFile() throws {
    try withDirectory { directory in
      let source = directory.appendingPathComponent("MM(synthetic).mmbak")
      try Data(String(repeating: "not a database\n", count: 20).utf8).write(to: source)
      try expectRefused(source: source, in: directory, diagnostic: nil)
    }
  }

  // MARK: (b) Zero duplicates

  @Test("re-importing the same backup changes nothing and maps no record twice")
  func reimportIsUnchanged() throws {
    try withDirectory { directory in
      let source = directory.appendingPathComponent("MM(synthetic).mmbak")
      try writeFullSchemaBackup(to: source)
      let canonical = directory.appendingPathComponent("canonical.sqlite")
      let workspace = ImportWorkspace()
      let first = try importBackup(source, into: canonical, staging: "stage-1", in: directory)
      #expect(first.status == .committed)
      let before = try tableCounts(at: canonical)

      let handle = try #require(
        try workspace.prepare(
          .init(
            sourceURL: source,
            stagingDatabaseURL: directory.appendingPathComponent("stage-2.sqlite"),
            canonicalDatabaseURL: canonical,
            sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800))
        ).preparedHandle)
      let second = try workspace.commit(handle, approval: workspace.approve(handle))
      #expect(second.status == .unchanged)
      #expect(try tableCounts(at: canonical) == before)

      // One source record, one event. A transfer is two records, one per leg, never one record
      // fanned out into two events.
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM (SELECT source_record_id FROM economic_event GROUP BY source_record_id HAVING count(*) > 1)"
        ) == 0)
      // Each event is materialized exactly once. A transfer pair shares one transaction, as
      // its debit and credit legs.
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM economic_event e WHERE (SELECT count(*) FROM ledger_transaction_source_literal l WHERE l.field IN ('import.eventID','import.eventID.debit','import.eventID.credit') AND l.literal=e.event_id) <> 1"
        ) == 0)
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM economic_event_transfer t WHERE NOT EXISTS (SELECT 1 FROM ledger_transaction_source_literal d JOIN ledger_transaction_source_literal c ON c.revision_id=d.revision_id WHERE d.field='import.eventID.debit' AND d.literal=t.debit_event_id AND c.field='import.eventID.credit' AND c.literal=t.credit_event_id)"
        ) == 0)
      #expect(try scalar(at: canonical, "SELECT count(*) FROM import_receipt") == 1)
    }
  }

  // MARK: (c) Zero orphans

  @Test("the committed store has no orphaned transactions, effects, transfers or provenance")
  func committedStoreHasNoOrphans() throws {
    try withDirectory { directory in
      let source = directory.appendingPathComponent("MM(synthetic).mmbak")
      try writeFullSchemaBackup(to: source)
      let canonical = directory.appendingPathComponent("canonical.sqlite")
      #expect(
        try importBackup(source, into: canonical, staging: "stage", in: directory).status
          == .committed)

      #expect(try rows(at: canonical, "PRAGMA foreign_key_check").isEmpty)
      // Every transaction's current revision names the event it came from, and that event is
      // still in the store.
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM ledger_transaction t WHERE NOT EXISTS (SELECT 1 FROM ledger_transaction_source_literal l JOIN economic_event e ON e.event_id=l.literal WHERE l.revision_id=t.current_revision_id AND l.field IN ('import.eventID','import.eventID.debit','import.eventID.credit'))"
        ) == 0)
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM ledger_transaction_effect f WHERE f.account_id NOT IN (SELECT account_id FROM ledger_account)"
        ) == 0)
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM economic_event e WHERE e.account_id NOT IN (SELECT account_id FROM ledger_account)"
        ) == 0)
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM economic_event_transfer t WHERE t.debit_event_id NOT IN (SELECT event_id FROM economic_event) OR t.credit_event_id NOT IN (SELECT event_id FROM economic_event)"
        ) == 0)
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM economic_event e WHERE e.event_id NOT IN (SELECT event_id FROM receipt_event)"
        ) == 0)

      // Every provenance row is referenced by some column that points at provenance_reference.
      // The referencing columns are read from the schema, so a new one cannot be missed.
      let references = try rows(
        at: canonical,
        """
        SELECT m.name, f."from" FROM sqlite_master m, pragma_foreign_key_list(m.name) f
        WHERE m.type='table' AND f."table"='provenance_reference' ORDER BY m.name, f."from"
        """)
      #expect(references.count >= 8)
      let referenced = references.map { "SELECT \"\($0[1])\" FROM \"\($0[0])\"" }
        .joined(separator: " UNION ")
      #expect(try scalar(at: canonical, "SELECT count(*) FROM provenance_reference") > 0)
      #expect(
        try scalar(
          at: canonical,
          "SELECT count(*) FROM provenance_reference WHERE provenance_id NOT IN (\(referenced))")
          == 0)
    }
  }

  // MARK: (d) Reconciliation totals

  @Test("mapped, preserved and excluded add up to every staged subject")
  func reconciliationTotalsCoverEveryStagedSubject() throws {
    try withDirectory { directory in
      let source = directory.appendingPathComponent("MM(synthetic).mmbak")
      try writeFullSchemaBackup(to: source)
      let staging = directory.appendingPathComponent("stage.sqlite")
      let preparation = try ImportWorkspace().prepare(
        .init(
          sourceURL: source, stagingDatabaseURL: staging,
          canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
          sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800)))
      let review = preparation.review
      #expect(review.status == .prepared)
      let mapped = try #require(review.mappedCount)
      let preserved = try #require(review.preservedCount)
      let excluded = try #require(review.excludedCount)
      #expect(review.blockingCount == 0)

      // Subjects are counted from the staging file itself: one artifact plus every table,
      // record and field staged from the source.
      let staged = try scalar(
        at: staging,
        "SELECT (SELECT count(*) FROM staged_artifact) + (SELECT count(*) FROM staged_table) + (SELECT count(*) FROM staged_record) + (SELECT count(*) FROM staged_field)"
      )
      #expect(staged > 0)
      #expect(mapped + preserved + excluded == staged)
      #expect(
        1 + (review.tableCount ?? -1) + (review.recordCount ?? -1) + (review.fieldCount ?? -1)
          == staged)
      #expect(mapped > 0)
      #expect(preserved > 0)
    }
  }

  // MARK: (e) Named certificate

  @Test("a certificate names the bytes, profile, adapter, locale, oracle and derived level")
  func certificateNamesEverythingItWasTestedAgainst() throws {
    try withDirectory { directory in
      let source = directory.appendingPathComponent("MM(synthetic).mmbak")
      try writeCertifiableBackup(to: source)
      let sourceBefore = try Data(contentsOf: source)
      let oracle = MoneyManagerV19AggregateOracle(
        eventsByKind: [
          "income": 2, "expense": 2, "adjustment": 1, "adjustment_debit": 1,
          "transfer_debit": 1, "transfer_credit": 1,
        ],
        transferPairs: 1)
      let work = directory.appendingPathComponent("work-l3")
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
      let certificate = try MoneyManagerV19ImportCertifier.certify(
        sourceURL: source, workDirectory: work,
        sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800), locale: "en-IN",
        oracle: oracle)

      #expect(certificate.checks.filter { !$0.passed }.map(\.name) == [])
      #expect(certificate.achievedLevel == .l3DeterministicMapping)
      #expect(certificate.sourceSHA256 == CanonicalReceiptDigest.sha256(sourceBefore))
      #expect(certificate.sourceByteCount == sourceBefore.count)
      #expect(certificate.profileID == "realbyte-android-sqlite-v19-observed")
      #expect(certificate.adapterVersion == MoneyManagerV19Adapter.version)
      #expect(certificate.importedArtifactSHA256 == certificate.sourceSHA256)
      #expect(certificate.locale == "en-IN")
      // The backup's own locale is recorded next to the one certified, never replaced by it.
      #expect(certificate.sourceLocales == ["en_US"])
      #expect(certificate.sourceTimeZone == "fixed:19800")
      #expect(certificate.oracleID == oracle.oracleID)
      #expect(certificate.eventCount == 8)
      #expect(certificate.transferPairs == 1)
      #expect(try Data(contentsOf: source) == sourceBefore)

      // Aggregates and hashes only: nothing from the backup's rows reaches the certificate.
      let json = String(decoding: try JSONEncoder().encode(certificate), as: UTF8.self)
      for secret in ["Wallet", "Salary", "Snacks", "synthetic", "acct-a", "tx-income", "40.00"] {
        #expect(!json.contains(secret))
      }
    }
  }

  @Test("a ZIP certificate names the wrapper and the imported SQLite member")
  func zipCertificateNamesWrapperAndMember() throws {
    try withDirectory { directory in
      let plain = directory.appendingPathComponent("MM(synthetic).mmbak")
      try writeCertifiableBackup(to: plain)
      let zipped = directory.appendingPathComponent("MM(synthetic-zip).mmbak")
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
      process.arguments = ["-q", "-j", zipped.path, plain.path]
      try process.run()
      process.waitUntilExit()
      try #require(process.terminationStatus == 0)
      func certify(_ source: URL, _ name: String) throws -> MoneyManagerV19ImportCertificate {
        let work = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        return try MoneyManagerV19ImportCertifier.certify(
          sourceURL: source, workDirectory: work,
          sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800), locale: "en-IN",
          oracle: nil)
      }
      let direct = try certify(plain, "work-plain")
      let zip = try certify(zipped, "work-zip")

      #expect(zip.achievedLevel == .l2LosslessStaging)
      #expect(zip.container == "zip")
      #expect(zip.sourceSHA256 == CanonicalReceiptDigest.sha256(try Data(contentsOf: zipped)))
      #expect(zip.importedArtifactSHA256 != zip.sourceSHA256)
      #expect(zip.importedArtifactSHA256 == direct.sourceSHA256)
      #expect(zip.eventSetHash == direct.eventSetHash)
      #expect(zip.sourceLocales == ["en_US"])
    }
  }

  @Test("without a matching oracle the certificate stops at lossless staging")
  func certificateLevelNeedsAMatchingOracle() throws {
    try withDirectory { directory in
      let source = directory.appendingPathComponent("MM(synthetic).mmbak")
      try writeCertifiableBackup(to: source)
      func certify(_ name: String, _ oracle: MoneyManagerV19AggregateOracle?) throws
        -> MoneyManagerV19ImportCertificate
      {
        let work = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        return try MoneyManagerV19ImportCertifier.certify(
          sourceURL: source, workDirectory: work,
          sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800), locale: "en-IN",
          oracle: oracle)
      }
      let none = try certify("none", nil)
      #expect(none.achievedLevel == .l2LosslessStaging)
      #expect(none.oracleID == nil)

      let wrong = try certify(
        "wrong", MoneyManagerV19AggregateOracle(eventsByKind: ["income": 3], transferPairs: 1))
      #expect(wrong.achievedLevel == .l2LosslessStaging)
      #expect(wrong.checks.first { $0.name == "oracle_counts" }?.passed == false)

      #expect(throws: MoneyManagerV19ImportCertifierError.unsupportedLocale) {
        _ = try MoneyManagerV19ImportCertifier.certify(
          sourceURL: source, workDirectory: directory,
          sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800), locale: "xx-XX",
          oracle: nil)
      }
    }
  }

  @Test("an unpaired transfer leg keeps the certificate below lossless staging")
  func unpairedTransferBlocksLosslessCertificate() throws {
    try withDirectory { directory in
      // The full synthetic backup keeps one transfer leg with no partner, on purpose.
      let source = directory.appendingPathComponent("MM(synthetic).mmbak")
      try writeFullSchemaBackup(to: source)
      let work = directory.appendingPathComponent("work")
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
      let certificate = try MoneyManagerV19ImportCertifier.certify(
        sourceURL: source, workDirectory: work,
        sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800), locale: "en-IN", oracle: nil)
      #expect(certificate.achievedLevel == .l1ReadOnlyClassification)
      #expect(certificate.checks.filter { !$0.passed }.map(\.name) == ["no_unresolved_semantics"])
    }
  }
}

// MARK: - Helpers

private func expectRefused(source: URL, in directory: URL, diagnostic: String?) throws {
  let canonical = directory.appendingPathComponent("canonical.sqlite")
  let staging = directory.appendingPathComponent("stage.sqlite")
  let preparation = try ImportWorkspace().prepare(
    .init(
      sourceURL: source, stagingDatabaseURL: staging, canonicalDatabaseURL: canonical,
      sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800)))
  #expect(preparation.review.status == .classificationOnly)
  #expect(!preparation.review.classificationStatus.admitsImportPreparation)
  #expect(preparation.preparedHandle == nil)
  #expect(!preparation.review.diagnosticCodes.isEmpty)
  if let diagnostic {
    #expect(preparation.review.diagnosticCodes == [diagnostic])
  }
  #expect(!FileManager.default.fileExists(atPath: canonical.path))
  #expect(!FileManager.default.fileExists(atPath: staging.path))
}

private func importBackup(
  _ source: URL, into canonical: URL, staging: String, in directory: URL
) throws -> ImportWorkspace.CommitResult {
  let workspace = ImportWorkspace()
  let preparation = try workspace.prepare(
    .init(
      sourceURL: source,
      stagingDatabaseURL: directory.appendingPathComponent("\(staging).sqlite"),
      canonicalDatabaseURL: canonical,
      sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800)))
  let handle = try #require(preparation.preparedHandle)
  return try workspace.commit(handle, approval: workspace.approve(handle))
}

/// Row counts for every table in the file, so a re-import that adds anything anywhere shows up.
private func tableCounts(at url: URL) throws -> [String: Int] {
  let names = try rows(
    at: url, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
  ).map { $0[0] }
  var counts: [String: Int] = [:]
  for name in names {
    counts[name] = try scalar(at: url, "SELECT count(*) FROM \"\(name)\"")
  }
  return counts
}

// Copied from ObservedV19FullSchemaImportTests so this suite stands on its own.
/// The full synthetic backup without its deliberately unpaired transfer leg, so nothing in it
/// blocks a lossless claim.
private func writeCertifiableBackup(to url: URL) throws {
  try writeFullSchemaBackup(to: url)
  try execute(at: url, sql: "DELETE FROM INOUTCOME WHERE uid='tx-orphan-out'")
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
  else { throw CertificationTestError.sqlite }
  defer { sqlite3_close(database) }
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
    throw CertificationTestError.sqlite
  }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement) == SQLITE_ROW else { throw CertificationTestError.sqlite }
  return Int(sqlite3_column_int64(statement, 0))
}

/// Every row as text columns. Used for schema introspection and checks that must return nothing.
private func rows(at url: URL, _ sql: String) throws -> [[String]] {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
    let database
  else { throw CertificationTestError.sqlite }
  defer { sqlite3_close(database) }
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
    throw CertificationTestError.sqlite
  }
  defer { sqlite3_finalize(statement) }
  var result: [[String]] = []
  while true {
    let step = sqlite3_step(statement)
    if step == SQLITE_DONE { break }
    guard step == SQLITE_ROW else { throw CertificationTestError.sqlite }
    let columns = sqlite3_column_count(statement)
    result.append(
      (0..<columns).map { index in
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
      })
  }
  return result
}

private func execute(at url: URL, sql: String) throws {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
      == SQLITE_OK,
    let database
  else { throw CertificationTestError.sqlite }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw CertificationTestError.sqlite
  }
}

private func withDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "v19-certification-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private enum CertificationTestError: Error { case sqlite }
