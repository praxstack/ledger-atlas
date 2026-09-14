import CSQLite
import CryptoKit
import Darwin
import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

@MainActor
@Suite("Phase 0.0 Money Manager import journey")
struct MoneyManagerPhase00JourneyTests {
  @Test("Mac family import edits, analyzes, adds a Mac-native transaction, and 1:1 backups")
  func macFamilyJourneyIsThePhase00Foundation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("mac-money-manager.sqlite")
    try writeMacFamilySource(to: source)
    let sourceBefore = SHA256.hash(data: try Data(contentsOf: source)).map {
      String(format: "%02x", $0)
    }.joined()
    let canonical = directory.appendingPathComponent("canonical.sqlite")
    let journey = LedgerJourney()

    journey.performSelectSource(
      source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
      canonicalDatabaseURL: canonical,
      sourceTimeZone: try SourceTimeZone(fixedOffsetSeconds: 0))
    #expect(journey.lastFailure == nil)
    #expect(journey.phase == .reviewing)
    #expect(journey.summary.decision == .reviewable)
    #expect(
      journey.summary.rows.contains(
        .init(label: "Classification status", value: "Inferred family")))
    #expect(
      !journey.summary.rows.contains(
        .init(label: "Classification status", value: "Supported")))

    try journey.approveAndOpen(canonicalDatabaseURL: canonical)
    #expect(journey.phase == .imported)
    #expect((journey.snapshot?.transactions.count ?? 0) == 2)
    #expect(journey.rows(for: .ledger).count == 2)
    #expect(!journey.rows(for: .accounts).isEmpty)
    #expect(journey.rows(for: .categories).contains { $0.title == "Preserved category" })
    #expect(journey.rows(for: .transfers).contains { $0.title == "Preserved source record" })
    #expect(!(journey.snapshot?.preservedSource.isEmpty ?? true))
    let insights = journey.rows(for: .insights)
    #expect(insights.contains { $0.title == "Imported" && $0.detail.contains("2") })
    #expect(insights.contains { $0.title == "Mac-native" && $0.detail.hasPrefix("0") })
    #expect(insights.contains { $0.title == "Transactions" })
    #expect(journey.insightTable.contains("Activity by kind"))

    try journey.performBeginEditing()
    let imported = try #require(journey.snapshot?.transactions.first)
    journey.performCorrectAmount(
      transactionID: imported.id, amountLiteral: "8.00",
      createdAt: UTCInstant(
        epochMilliseconds: imported.currentRevision.createdAt.epochMilliseconds + 1))
    #expect(journey.lastFailure == nil)
    #expect(
      journey.snapshot?.transactions.contains {
        $0.currentRevision.draft.effects[0].amount.amount.rawLiteral == "8.00"
      } == true)

    journey.performCreateMacTransaction(
      amountLiteral: "3.50",
      createdAt: UTCInstant(
        epochMilliseconds: imported.currentRevision.createdAt.epochMilliseconds + 2))
    #expect(journey.lastFailure == nil)
    let afterNative = try #require(journey.snapshot)
    #expect(afterNative.transactions.count == 3)
    #expect(
      afterNative.transactions.contains {
        $0.currentRevision.draft.origin.label == "mac-native"
          && $0.currentRevision.draft.effects[0].amount.amount.rawLiteral == "3.50"
      })
    let afterInsights = journey.rows(for: .insights)
    #expect(afterInsights.contains { $0.title == "Imported" && $0.detail.contains("2") })
    #expect(afterInsights.contains { $0.title == "Mac-native" && $0.detail.contains("1") })

    #expect(throws: LedgerApplication.Error.invalidCommand) {
      _ = try journey.exportPackage()
    }

    let backupURL = directory.appendingPathComponent("ledger-1to1.sqlite")
    try journey.backupCanonicalLedger(to: backupURL)
    #expect(FileManager.default.fileExists(atPath: backupURL.path))
    let reopened = LedgerJourney()
    reopened.openLedger(backupURL)
    #expect(reopened.phase == .imported)
    #expect(reopened.rows(for: .ledger).count == 3)
    #expect(try reopened.checksum() == journey.checksum())

    let sourceAfter = SHA256.hash(data: try Data(contentsOf: source)).map {
      String(format: "%02x", $0)
    }.joined()
    #expect(sourceAfter == sourceBefore)
  }

  @Test("iOS family import visualizes, edits, and requires an exact canonical backup")
  func iosFamilyJourneyImportsAndBacksUp() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("money.sqlite")
    try writeIOSFamilySource(to: source)
    let canonical = directory.appendingPathComponent("canonical.sqlite")
    let journey = LedgerJourney()
    journey.performSelectSource(
      source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
      canonicalDatabaseURL: canonical,
      sourceTimeZone: try SourceTimeZone(fixedOffsetSeconds: 0))
    #expect(journey.phase == .reviewing)
    try journey.approveAndOpen(canonicalDatabaseURL: canonical)
    #expect(journey.phase == .imported)
    #expect((journey.snapshot?.transactions.count ?? 0) == 2)
    #expect(!journey.rows(for: .insights).isEmpty)
    try journey.performBeginEditing()
    journey.performCreateMacTransaction(
      amountLiteral: "1.25", createdAt: UTCInstant(epochMilliseconds: 1_738_547_201_000))
    #expect(journey.lastFailure == nil)
    #expect(throws: LedgerApplication.Error.invalidCommand) {
      _ = try journey.exportPackage()
    }
    let backupURL = directory.appendingPathComponent("ios-canonical-backup.sqlite")
    try journey.backupCanonicalLedger(to: backupURL)
    let restored = LedgerJourney()
    restored.openLedger(backupURL)
    #expect(restored.rows(for: .ledger).count == 3)
  }
}

private func writeMacFamilySource(to url: URL) throws {
  try executeSQL(
    at: url,
    sql: """
      PRAGMA user_version=19;
      CREATE TABLE ASSETS (uid TEXT);
      CREATE TABLE ZCATEGORY (uid TEXT);
      CREATE TABLE CURRENCY (uid TEXT, ISO TEXT);
      CREATE TABLE INOUTCOME (uid TEXT, assetUid TEXT, currencyUid TEXT, DO_TYPE TEXT, ctgUid TEXT, ZMONEY TEXT, WDATE TEXT, ZDATE TEXT, NOTE TEXT);
      CREATE TABLE MAC_SETTING (uid TEXT, value TEXT);
      INSERT INTO ASSETS VALUES ('asset');
      INSERT INTO ZCATEGORY VALUES ('category');
      INSERT INTO CURRENCY VALUES ('currency', 'USD');
      INSERT INTO INOUTCOME VALUES ('income', 'asset', 'currency', '0', 'category', '5.00', '2025-02-03', '1738547200000', 'synthetic-mac');
      INSERT INTO INOUTCOME VALUES ('expense', 'asset', 'currency', '1', 'category', '7.25', '2025-02-03', '1738547200000', 'synthetic-mac');
      INSERT INTO INOUTCOME VALUES ('unproven', 'asset', 'currency', '7', 'category', '2.00', '2025-02-03', '1738547200000', 'synthetic-mac');
      INSERT INTO MAC_SETTING VALUES ('theme', 'dark');
      """)
}

private func writeIOSFamilySource(to url: URL) throws {
  try executeSQL(
    at: url,
    sql: """
      PRAGMA user_version=19;
      CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME TEXT);
      CREATE TABLE ZASSETS (ZUID TEXT);
      CREATE TABLE ZCATEGORY (ZUID TEXT);
      CREATE TABLE ZCURRENCY (ZUID TEXT, ZISO TEXT);
      CREATE TABLE ZINOUTCOME (ZUID TEXT, ZASSETUID TEXT, ZCURRENCYUID TEXT, ZDOTYPE INTEGER, ZCTGUID TEXT, ZMONEY TEXT, ZWDATE TEXT, ZDATE TEXT, ZNOTE TEXT);
      INSERT INTO Z_PRIMARYKEY VALUES (1, 'Asset');
      INSERT INTO ZASSETS VALUES ('asset');
      INSERT INTO ZCATEGORY VALUES ('category');
      INSERT INTO ZCURRENCY VALUES ('currency', 'USD');
      INSERT INTO ZINOUTCOME VALUES ('income', 'asset', 'currency', 0, 'category', '5.00', '2025-02-03', '1738547200000', 'synthetic-ios');
      INSERT INTO ZINOUTCOME VALUES ('expense', 'asset', 'currency', 1, 'category', '7.25', '2025-02-03', '1738547200000', 'synthetic-ios');
      """)
}

private func executeSQL(at url: URL, sql: String) throws {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
}

private func writeEmptyCanonical(to url: URL) throws {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  defer { sqlite3_close(database) }
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
  #expect(chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
}
