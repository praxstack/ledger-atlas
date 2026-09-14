import CSQLite
import CryptoKit
import Foundation
import LedgerCore
import Testing

@testable import MMImport

@Suite("Money Manager Mac and iOS family import")
struct MoneyManagerFamilyImportTests {
  @Test("Mac v19 family prepares, commits mapped 0/1 rows, and sidecars 3/4/7")
  func macFamilyImportsWithoutBlocking() throws {
    try withFamilyDirectory { directory in
      let source = directory.appendingPathComponent("mac-money-manager.sqlite")
      try writeMacFamilyV19(to: source)
      let sourceBefore = try Data(contentsOf: source)
      let canonical = directory.appendingPathComponent("canonical.sqlite")
      let workspace = ImportWorkspace()

      let preparation = try workspace.prepare(
        .init(
          sourceURL: source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
          canonicalDatabaseURL: canonical, sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0)))

      #expect(preparation.review.status == .prepared)
      #expect(preparation.review.classificationStatus == .familyMatch)
      #expect(preparation.review.familyMatch == true)
      #expect(preparation.review.losslessCertificationBlocked == true)
      #expect(preparation.review.blockingCount == 0)
      #expect((preparation.review.mappedCount ?? 0) > 0)
      #expect((preparation.review.preservedCount ?? 0) > 0)
      let handle = try #require(preparation.preparedHandle)

      let first = try workspace.commit(handle, approval: workspace.approve(handle))
      #expect(first.status == .committed)
      #expect(first.eventCount == 2)
      #expect(try Data(contentsOf: source) == sourceBefore)
      #expect(try SQLiteCanonicalCommitter().eventCount(at: canonical) == 2)
      let preservation = try SQLiteCanonicalCommitter().receiptOwnedPreservation(
        at: canonical,
        receiptID: try workspaceReceiptID(at: canonical))
      #expect(preservation.anchors.contains { $0.sourceTable == "MAC_SETTING" })
      #expect(preservation.anchors.contains { $0.sourceTable == "INOUTCOME" })
    }
  }

  @Test("iOS v19 family with Z-tables prepares and commits mapped 0/1 rows")
  func iosFamilyImportsWithoutBlocking() throws {
    try withFamilyDirectory { directory in
      let source = directory.appendingPathComponent("money.sqlite")
      try writeIOSFamilyV19(to: source)
      let sourceBefore = try Data(contentsOf: source)
      let canonical = directory.appendingPathComponent("canonical.sqlite")
      let staging = directory.appendingPathComponent("stage.sqlite")
      let workspace = ImportWorkspace()

      let preparation = try workspace.prepare(
        .init(
          sourceURL: source, stagingDatabaseURL: staging,
          canonicalDatabaseURL: canonical, sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0)))

      #expect(preparation.review.status == .prepared)
      #expect(preparation.review.classificationStatus == .familyMatch)
      #expect(preparation.review.blockingCount == 0)
      let handle = try #require(preparation.preparedHandle)
      let result = try workspace.commit(handle, approval: workspace.approve(handle))
      #expect(result.status == .committed)
      #expect(result.eventCount == 2)
      #expect(try Data(contentsOf: source) == sourceBefore)
      #expect(try SQLiteCanonicalCommitter().eventCount(at: canonical) == 2)
    }
  }

  @Test("Android v19 family that is not the exact observed hash still prepares")
  func androidFamilyImportsWithoutExactHash() throws {
    try withFamilyDirectory { directory in
      let source = directory.appendingPathComponent("money_android.sqlite")
      try writeAndroidFamilyV19(to: source)
      let canonical = directory.appendingPathComponent("canonical.sqlite")
      let workspace = ImportWorkspace()
      let preparation = try workspace.prepare(
        .init(
          sourceURL: source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
          canonicalDatabaseURL: canonical, sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0)))
      #expect(preparation.review.status == .prepared)
      #expect(preparation.review.classificationStatus == .familyMatch)
      let handle = try #require(preparation.preparedHandle)
      let result = try workspace.commit(handle, approval: workspace.approve(handle))
      #expect(result.status == .committed)
      #expect(result.eventCount == 1)
    }
  }
}

@Suite("Money Manager family classification")
struct MoneyManagerFamilyClassificationTests {
  @Test("Mac, iOS, and Android families classify as family matches, not certified schema cells")
  func familyProfilesClassifyWhenRegistered() throws {
    try withFamilyDirectory { directory in
      let mac = directory.appendingPathComponent("mac.sqlite")
      let ios = directory.appendingPathComponent("ios.sqlite")
      let android = directory.appendingPathComponent("android.sqlite")
      try writeMacFamilyV19(to: mac)
      try writeIOSFamilyV19(to: ios)
      try writeAndroidFamilyV19(to: android)

      let registered = SourceClassifier(profiles: SourceProfile.moneyManagerImportProfiles)
      let macResult = registered.classify(mac)
      let iosResult = registered.classify(ios)
      let androidResult = registered.classify(android)
      #expect(macResult.profile?.identifier == SourceProfile.moneyManagerMacV19Family.identifier)
      #expect(macResult.profile?.familyShape == .moneyManagerMacV19)
      #expect(macResult.profile?.isExactSchemaCell == false)
      #expect(iosResult.profile?.identifier == SourceProfile.moneyManagerIOSV19Family.identifier)
      #expect(
        androidResult.profile?.identifier
          == SourceProfile.moneyManagerAndroidV19Family.identifier)
      #expect(macResult.status == .familyMatch)
      #expect(iosResult.status == .familyMatch)
      #expect(androidResult.status == .familyMatch)
      #expect(macResult.diagnostics == [.familyProfileMatch])
      let observedSchema = try #require(macResult.metadata?.schemaSHA256)
      #expect(observedSchema != SourceProfile.moneyManagerMacV19Family.schemaSHA256)
      #expect(observedSchema.count == 64)

      let empty = SourceClassifier(profiles: [])
      #expect(empty.classify(mac).status == .unsupported)
      #expect(empty.classify(ios).status == .unsupported)
      #expect(empty.classify(android).diagnostics.contains(.unknownProfile))
    }
  }

  @Test("default classifier admits Money Manager family backups as inferred matches")
  func defaultClassifierAdmitsFamilies() throws {
    try withFamilyDirectory { directory in
      let mac = directory.appendingPathComponent("mac.sqlite")
      try writeMacFamilyV19(to: mac)
      let result = SourceClassifier().classify(mac)
      #expect(result.status == .familyMatch)
      #expect(result.profile?.identifier == SourceProfile.moneyManagerMacV19Family.identifier)
      #expect(result.profile?.familyShape == .moneyManagerMacV19)
    }
  }

  @Test("ZIP .mmbak family sources stage and prepare without writing the archive")
  func zipMMBakFamilyPrepares() throws {
    try withFamilyDirectory { directory in
      let sqlite = directory.appendingPathComponent("mac.sqlite")
      try writeMacFamilyV19(to: sqlite)
      let archive = directory.appendingPathComponent("mac-money-manager.mmbak")
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
      process.arguments = ["-q", "-j", archive.path, sqlite.path]
      try process.run()
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)
      let sourceBefore = try Data(contentsOf: archive)
      let workspace = ImportWorkspace()
      let preparation = try workspace.prepare(
        .init(
          sourceURL: archive, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
          canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
          sourceTimeZone: try SourceTimeZone(fixedOffsetSeconds: 0)))
      #expect(preparation.review.status == .prepared)
      #expect(preparation.review.container == .zip)
      #expect(preparation.review.classificationStatus == .familyMatch)
      #expect(try Data(contentsOf: archive) == sourceBefore)
      let handle = try #require(preparation.preparedHandle)
      let result = try workspace.commit(handle, approval: workspace.approve(handle))
      #expect(result.status == .committed)
      #expect(result.eventCount == 2)
    }
  }
}

private func withFamilyDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func writeMacFamilyV19(to url: URL) throws {
  try executeFamilySQL(
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
      INSERT INTO INOUTCOME VALUES ('transfer-out', 'asset', 'currency', '3', 'category', '1.00', '2025-02-03', '1738547200000', 'synthetic-mac');
      INSERT INTO INOUTCOME VALUES ('transfer-in', 'asset', 'currency', '4', 'category', '1.00', '2025-02-03', '1738547200000', 'synthetic-mac');
      INSERT INTO INOUTCOME VALUES ('unproven', 'asset', 'currency', '7', 'category', '2.00', '2025-02-03', '1738547200000', 'synthetic-mac');
      INSERT INTO MAC_SETTING VALUES ('theme', 'dark');
      """)
}

private func writeIOSFamilyV19(to url: URL) throws {
  try executeFamilySQL(
    at: url,
    sql: """
      PRAGMA user_version=19;
      CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME TEXT);
      CREATE TABLE Z_METADATA (Z_VERSION INTEGER, Z_UUID VARCHAR);
      CREATE TABLE ZASSETS (ZUID TEXT);
      CREATE TABLE ZCATEGORY (ZUID TEXT);
      CREATE TABLE ZCURRENCY (ZUID TEXT, ZISO TEXT);
      CREATE TABLE ZINOUTCOME (ZUID TEXT, ZASSETUID TEXT, ZCURRENCYUID TEXT, ZDOTYPE INTEGER, ZCTGUID TEXT, ZMONEY TEXT, ZWDATE TEXT, ZDATE TEXT, ZNOTE TEXT);
      INSERT INTO Z_PRIMARYKEY VALUES (1, 'Asset');
      INSERT INTO Z_METADATA VALUES (1, 'synthetic-ios-uuid');
      INSERT INTO ZASSETS VALUES ('asset');
      INSERT INTO ZCATEGORY VALUES ('category');
      INSERT INTO ZCURRENCY VALUES ('currency', 'USD');
      INSERT INTO ZINOUTCOME VALUES ('income', 'asset', 'currency', 0, 'category', '5.00', '2025-02-03', '1738547200000', 'synthetic-ios');
      INSERT INTO ZINOUTCOME VALUES ('expense', 'asset', 'currency', 1, 'category', '7.25', '2025-02-03', '1738547200000', 'synthetic-ios');
      INSERT INTO ZINOUTCOME VALUES ('transfer-out', 'asset', 'currency', 3, 'category', '1.00', '2025-02-03', '1738547200000', 'synthetic-ios');
      """)
}

private func writeAndroidFamilyV19(to url: URL) throws {
  try executeFamilySQL(
    at: url,
    sql: """
      PRAGMA user_version=19;
      CREATE TABLE android_metadata (locale TEXT);
      CREATE TABLE ASSETS (uid TEXT);
      CREATE TABLE ZCATEGORY (uid TEXT);
      CREATE TABLE CURRENCY (uid TEXT, ISO TEXT);
      CREATE TABLE INOUTCOME (uid TEXT, assetUid TEXT, currencyUid TEXT, DO_TYPE TEXT, ctgUid TEXT, ZMONEY TEXT, WDATE TEXT, ZDATE TEXT, NOTE TEXT);
      INSERT INTO android_metadata VALUES ('en_US');
      INSERT INTO ASSETS VALUES ('asset');
      INSERT INTO ZCATEGORY VALUES ('category');
      INSERT INTO CURRENCY VALUES ('currency', 'USD');
      INSERT INTO INOUTCOME VALUES ('transaction', 'asset', 'currency', '1', 'category', '12.30', '2025-02-03', '1738547200000', 'synthetic-android');
      """)
}

private func executeFamilySQL(at url: URL, sql: String) throws {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
      == SQLITE_OK,
    let database
  else { throw FamilyImportTestError.sqlite }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw FamilyImportTestError.sqlite
  }
}

private func workspaceReceiptID(at canonical: URL) throws -> String {
  var database: OpaquePointer?
  guard sqlite3_open_v2(canonical.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
    let database
  else { throw FamilyImportTestError.sqlite }
  defer { sqlite3_close(database) }
  var statement: OpaquePointer?
  guard
    sqlite3_prepare_v2(
      database, "SELECT idempotency_key FROM import_receipt LIMIT 1", -1, &statement, nil)
      == SQLITE_OK,
    let statement
  else { throw FamilyImportTestError.sqlite }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0)
  else { throw FamilyImportTestError.sqlite }
  return String(cString: bytes)
}

private enum FamilyImportTestError: Error { case sqlite }
