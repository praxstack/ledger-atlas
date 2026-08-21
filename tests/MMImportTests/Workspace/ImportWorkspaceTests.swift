import CSQLite
import Foundation
import LedgerCore
import Testing

@testable import MMImport

@Suite("Import workspace")
struct ImportWorkspaceTests {
  @Test("the public workspace cannot promote an arbitrary v19 input")
  func publicWorkspaceIsClassificationOnly() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("synthetic.sqlite")
    try createSQLite(at: source, sql: "PRAGMA user_version=19; CREATE TABLE OTHER (uid TEXT);")

    let result = try ImportWorkspace().prepare(
      .init(
        sourceURL: source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
        canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
        sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0)))

    #expect(result.review.status == .classificationOnly)
    #expect(result.preparedHandle == nil)
  }

  @Test("synthetic v19 prepares without a canonical write")
  func syntheticV19Prepares() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("synthetic.sqlite")
    try createSQLite(
      at: source,
      sql: """
        PRAGMA user_version=19;
        CREATE TABLE ASSETS (uid TEXT); CREATE TABLE ZCATEGORY (uid TEXT);
        CREATE TABLE CURRENCY (uid TEXT, ISO TEXT);
        CREATE TABLE INOUTCOME (uid TEXT, assetUid TEXT, currencyUid TEXT, DO_TYPE TEXT, ctgUid TEXT, ZMONEY TEXT, WDATE TEXT, ZDATE TEXT, NOTE TEXT);
        INSERT INTO ASSETS VALUES ('asset'); INSERT INTO ZCATEGORY VALUES ('category');
        INSERT INTO CURRENCY VALUES ('currency', 'USD');
        INSERT INTO INOUTCOME VALUES ('transaction', 'asset', 'currency', '1', 'category', '12.30', '2025-02-03', '1738547200000', 'synthetic');
        """)
    let canonical = directory.appendingPathComponent("canonical.sqlite")
    let sourceBefore = try Data(contentsOf: source)

    let result = try ImportWorkspace().prepare(
      .init(
        sourceURL: source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
        canonicalDatabaseURL: canonical, sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0)))

    #expect(result.review.status == .prepared)
    #expect(result.preparedHandle != nil)
    #expect(result.review.blockingCount == 0)
    #expect(try Data(contentsOf: source) == sourceBefore)
    #expect(!FileManager.default.fileExists(atPath: canonical.path))
  }

  @Test("an approved prepared import commits once and retries unchanged")
  func approvedPreparationCommitsIdempotently() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("synthetic.sqlite")
    try createSyntheticV19(at: source)
    let canonical = directory.appendingPathComponent("canonical.sqlite")
    let workspace = ImportWorkspace()
    let preparation = try workspace.prepare(
      .init(
        sourceURL: source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
        canonicalDatabaseURL: canonical, sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0)))
    let handle = try #require(preparation.preparedHandle)

    let approval = workspace.approve(handle)
    let first = try workspace.commit(handle, approval: approval)
    let second = try workspace.commit(handle, approval: approval)

    #expect(first.status == .committed)
    #expect(second.status == .unchanged)
    #expect(try SQLiteCanonicalCommitter().eventCount(at: canonical) == 1)
  }

  @Test("approval for one prepared import cannot commit another")
  func approvalIsBoundToPreparedImport() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = ImportWorkspace()
    let first = try preparedSynthetic(
      workspace: workspace, directory: directory, name: "first", canonicalName: "first-canonical")
    let second = try preparedSynthetic(
      workspace: workspace, directory: directory, name: "second", canonicalName: "second-canonical")
    let firstHandle = try #require(first.preparedHandle)
    let secondHandle = try #require(second.preparedHandle)

    let approval = workspace.approve(firstHandle)
    #expect(throws: ImportWorkspaceError.approvalMismatch) {
      try workspace.commit(secondHandle, approval: approval)
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("second-canonical.sqlite").path))
  }

  @Test("a prepared import refuses a destination changed by another import")
  func stalePreparationCannotCommitIntoChangedDestination() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = ImportWorkspace()
    let canonicalName = "shared-canonical"
    let first = try preparedSynthetic(
      workspace: workspace, directory: directory, name: "first", canonicalName: canonicalName)
    let second = try preparedSynthetic(
      workspace: workspace, directory: directory, name: "second", canonicalName: canonicalName)
    let firstHandle = try #require(first.preparedHandle)
    let secondHandle = try #require(second.preparedHandle)

    _ = try workspace.commit(firstHandle, approval: workspace.approve(firstHandle))
    #expect(throws: ImportWorkspaceError.destinationChanged) {
      try workspace.commit(secondHandle, approval: workspace.approve(secondHandle))
    }
  }

  @Test("workspace commit result is content-free")
  func workspaceCommitResultDoesNotExposeCommitProofsOrHashes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = ImportWorkspace()
    let preparation = try preparedSynthetic(
      workspace: workspace, directory: directory, name: "single", canonicalName: "canonical")
    let handle = try #require(preparation.preparedHandle)
    let result = try workspace.commit(handle, approval: workspace.approve(handle))

    #expect(result.status == .committed)
    #expect(result.eventCount == 1)
    #expect(
      Mirror(reflecting: result).children.compactMap(\.label).sorted()
        == ["eventCount", "status"])
  }

  @Test("unknown v19 remains classification-only without output")
  func unknownV19DoesNotStageOrCommit() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("unknown.sqlite")
    try createSQLite(
      at: source,
      sql:
        "PRAGMA user_version=19; CREATE TABLE OTHER (uid TEXT); INSERT INTO OTHER VALUES ('synthetic');"
    )
    let staging = directory.appendingPathComponent("stage.sqlite")
    let canonical = directory.appendingPathComponent("canonical.sqlite")
    let result = try ImportWorkspace().prepare(
      .init(
        sourceURL: source, stagingDatabaseURL: staging, canonicalDatabaseURL: canonical,
        sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0)))

    #expect(result.review.status == .classificationOnly)
    #expect(result.preparedHandle == nil)
    #expect(result.review.tableCount == nil)
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    #expect(!FileManager.default.fileExists(atPath: canonical.path))
  }
}

private func preparedSynthetic(
  workspace: ImportWorkspace, directory: URL, name: String, canonicalName: String
) throws -> ImportWorkspace.Preparation {
  let source = directory.appendingPathComponent("\(name).sqlite")
  try createSyntheticV19(at: source)
  return try workspace.prepare(
    .init(
      sourceURL: source,
      stagingDatabaseURL: directory.appendingPathComponent("\(name)-stage.sqlite"),
      canonicalDatabaseURL: directory.appendingPathComponent("\(canonicalName).sqlite"),
      sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0)))
}

private func createSyntheticV19(at url: URL) throws {
  try createSQLite(
    at: url,
    sql: """
      PRAGMA user_version=19;
      CREATE TABLE ASSETS (uid TEXT); CREATE TABLE ZCATEGORY (uid TEXT);
      CREATE TABLE CURRENCY (uid TEXT, ISO TEXT);
      CREATE TABLE INOUTCOME (uid TEXT, assetUid TEXT, currencyUid TEXT, DO_TYPE TEXT, ctgUid TEXT, ZMONEY TEXT, WDATE TEXT, ZDATE TEXT, NOTE TEXT);
      INSERT INTO ASSETS VALUES ('asset'); INSERT INTO ZCATEGORY VALUES ('category');
      INSERT INTO CURRENCY VALUES ('currency', 'USD');
      INSERT INTO INOUTCOME VALUES ('transaction', 'asset', 'currency', '1', 'category', '12.30', '2025-02-03', '1738547200000', 'synthetic');
      """)
}

private func createSQLite(at url: URL, sql: String) throws {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
      == SQLITE_OK,
    let database
  else { throw WorkspaceTestError.sqlite }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw WorkspaceTestError.sqlite
  }
}

private enum WorkspaceTestError: Error { case sqlite }
