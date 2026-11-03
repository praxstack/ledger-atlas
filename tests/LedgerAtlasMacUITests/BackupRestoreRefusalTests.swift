import CSQLite
import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

// Synthetic data only: every name, amount and date here is made up.

private func key(_ character: Character) -> String { String(repeating: character, count: 64) }

/// MACV2-15 (#51): a damaged, truncated, foreign or newer file picked as a backup is refused by
/// every restore path. Nothing is created at the destination, and the open ledger and its file
/// stay exactly as they were.
@MainActor
@Test(arguments: BadBackup.allCases)
func unusableBackupsAreRefusedWithoutTouchingAnything(_ bad: BadBackup) async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let original = directory.appendingPathComponent("original.sqlite")
  let suite = "LedgerAtlasMacUITests.refusal.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let bookmarks = SecurityScopedBookmarkStore(
    defaults: defaults, makeBookmark: { Data($0.path.utf8) },
    resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) })

  let journey = LedgerJourney()
  let created = await LedgerAtlasRootView.performLedgerLifecycle(
    .create, at: original, bookmarkStore: bookmarks, widgetPublisher: .init(write: { _ in }),
    journey: journey, session: LedgerSession(testingScopeStarter: { _ in true }),
    scopeStarter: { _ in true }, scopeStopper: { _ in })
  #expect(created.kind == .created)
  try journey.performBeginEditing()
  let origin = try LedgerOrigin.macNative()
  let wallet = try LedgerAccount(
    id: try StableLedgerID.account(origin: origin, localKey: key("a")), name: "Wallet",
    currencyUnit: "INR", origin: origin)
  try journey.createAccount(wallet)
  _ = try journey.createNativeTransaction(
    amountLiteral: "42", kind: .expense, accountID: wallet.id, categoryID: nil,
    note: "Synthetic lunch",
    createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()),
    submissionID: "refusal")
  let backup = directory.appendingPathComponent("backup.sqlite")
  try journey.backupCanonicalLedger(to: backup)

  let source = directory.appendingPathComponent("picked-\(bad.rawValue).sqlite")
  try bad.write(to: source, from: backup)
  let sourceBytes = try Data(contentsOf: source)
  let openURL = journey.ledgerURL
  let openChecksum = try journey.checksum()
  let originalBytes = try Data(contentsOf: original)

  let restoreTarget = directory.appendingPathComponent("restored.sqlite")
  #expect(throws: (any Error).self) {
    try journey.restoreCanonicalBackup(from: source, to: restoreTarget)
  }
  #expect(!FileManager.default.fileExists(atPath: restoreTarget.path))

  let packageTarget = directory.appendingPathComponent("from-package.sqlite")
  #expect(throws: (any Error).self) {
    try journey.restorePortablePackage(from: source, to: packageTarget)
  }
  #expect(!FileManager.default.fileExists(atPath: packageTarget.path))

  // Merge reads the picked file first; a refused file never reaches the preview.
  #expect(throws: (any Error).self) {
    _ = try LedgerJourney.incomingPackage(from: source)
  }

  #expect(journey.ledgerURL == openURL)
  #expect(try journey.checksum() == openChecksum)
  #expect(try Data(contentsOf: original) == originalBytes)
  #expect(try Data(contentsOf: source) == sourceBytes)
  let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    .filter { !["original.sqlite", "backup.sqlite", source.lastPathComponent].contains($0) }
  #expect(leftovers.allSatisfy { $0.hasPrefix("original.sqlite") }, "\(leftovers)")
}

enum BadBackup: String, CaseIterable, Sendable {
  /// Not a database at all.
  case damaged
  /// The first half of a real backup, as after an interrupted copy.
  case truncated
  /// A valid SQLite file that isn't a ledger.
  case foreign
  /// A real backup that claims a schema newer than this app knows.
  case newer

  func write(to url: URL, from backup: URL) throws {
    switch self {
    case .damaged:
      try Data(String(repeating: "not a ledger\n", count: 400).utf8).write(to: url)
    case .truncated:
      let bytes = try Data(contentsOf: backup)
      try bytes.prefix(bytes.count / 2).write(to: url)
    case .foreign:
      try execute(
        at: url,
        """
        CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT);
        INSERT INTO notes(body) VALUES ('synthetic');
        """)
    case .newer:
      try FileManager.default.copyItem(at: backup, to: url)
      try execute(at: url, "UPDATE ledger_meta SET value='999' WHERE key='schema_version';")
    }
  }
}

private func execute(at url: URL, _ sql: String) throws {
  var database: OpaquePointer?
  guard
    sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
      == SQLITE_OK,
    let database
  else { throw RefusalTestError.sqlite }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw RefusalTestError.sqlite
  }
}

private enum RefusalTestError: Error { case sqlite }
