import CSQLite
import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

// Synthetic data only.

/// #143: approving an import must not start a second, background load of the ledger. That
/// load held a read lock for seconds on a large ledger, so the first save after approve could
/// wait on the 5 s busy timeout and freeze the UI. The session now shows the snapshot the
/// journey already read, so an edit straight after approve never meets a load.
@MainActor
@Test func editRightAfterApprovingAnImportNeverWaitsForALoad() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "load-race-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("synthetic.sqlite")
  try writeLargeSyntheticV19(to: source, transactions: 1_000)
  let journey = LedgerJourney()
  let session = LedgerSession()
  try journey.selectSource(
    source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
    sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))

  journey.performApprove(into: session)
  #expect(journey.lastFailure == nil)
  // Loaded at once, from the journey's snapshot: no load is in flight.
  guard case .loaded(let presentation) = session.state else {
    Issue.record("session is \(session.screen) right after approve, not loaded")
    return
  }
  #expect(presentation.transactions.count == journey.snapshot?.transactions.count)

  // Edit and save immediately, as a user clicking Edit straight away would.
  let started = ContinuousClock.now
  try journey.performBeginEditing()
  let first = try #require(journey.snapshot?.transactions.first)
  journey.performCorrectAmount(
    transactionID: first.id, amountLiteral: "8.25",
    createdAt: UTCInstant(
      epochMilliseconds: first.currentRevision.createdAt.epochMilliseconds + 1))
  let elapsed = ContinuousClock.now - started
  print("LOAD-RACE edit after approve of 1000 transactions took \(elapsed)")
  #expect(journey.lastFailure == nil)
  #expect(
    journey.snapshot?.transactions.first { $0.id == first.id }?.currentRevision.draft.effects[0]
      .amount.amount.rawLiteral == "8.25")
  // Still loaded from the same snapshot path: approving never started a background load.
  #expect(session.screen == .loaded)
}

/// A Money Manager v19 backup with many synthetic transactions.
private func writeLargeSyntheticV19(to url: URL, transactions: Int) throws {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  defer { sqlite3_close(database) }
  let sql = """
    PRAGMA user_version=19;
    CREATE TABLE ASSETS (uid TEXT); CREATE TABLE ZCATEGORY (uid TEXT);
    CREATE TABLE CURRENCY (uid TEXT, ISO TEXT);
    CREATE TABLE INOUTCOME (uid TEXT, assetUid TEXT, currencyUid TEXT, DO_TYPE TEXT, ctgUid TEXT, ZMONEY TEXT, WDATE TEXT, ZDATE TEXT, NOTE TEXT);
    INSERT INTO ASSETS VALUES ('asset'); INSERT INTO ZCATEGORY VALUES ('category');
    INSERT INTO CURRENCY VALUES ('currency', 'USD');
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(transactions))
    INSERT INTO INOUTCOME
      SELECT 'transaction-' || i, 'asset', 'currency', '1', 'category',
        printf('%d.%02d', i % 500 + 1, i % 100), '2025-02-03',
        CAST(1738547200000 + i * 10000 AS TEXT), 'synthetic'
      FROM n;
    """
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
}
