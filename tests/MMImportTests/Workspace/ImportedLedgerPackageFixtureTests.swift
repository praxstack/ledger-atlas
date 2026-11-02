import CSQLite
import CryptoKit
import Foundation
import LedgerCore
import LedgerStore
import MMImport
import Testing

/// Committed packages of an imported ledger, one per canonical schema from v12 on. Each must
/// still restore on today's schema, so a later schema can't break old backups unnoticed (for
/// example by adding a column the product writers fill). All data is synthetic.
///
/// A new schema version adds its own fixture. Run the generator on that schema (the Linux harness
/// works): `LEDGER_ATLAS_WRITE_PACKAGE_FIXTURE=1`, filtered to `writeCurrentFixture`.
@Suite("Imported ledger package fixtures")
struct ImportedLedgerPackageFixtureTests {
  /// v12 is the first schema an imported ledger could be exported at (package v4).
  static let firstVersion = 12

  @Test("every schema since v12 has a committed package fixture")
  func everySchemaHasAFixture() {
    for version in Self.firstVersion...CanonicalLedgerSchema.version {
      #expect(
        FileManager.default.fileExists(atPath: fixtureURL(version).path),
        "Add tests/MMImportTests/Fixtures/imported-ledger-v\(version).json with the generator.")
    }
  }

  @Test(
    "every committed package fixture restores on today's schema",
    arguments: Array(firstVersion...CanonicalLedgerSchema.version))
  func fixtureRestores(version: Int) throws {
    let url = fixtureURL(version)
    try #require(FileManager.default.fileExists(atPath: url.path))
    let payload = try Data(contentsOf: url)
    let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let graph = try #require(object["importGraph"] as? [String: Any])
    #expect(graph["schemaVersion"] as? Int == version)
    let identity = try #require(receiptIdentity(graph))
    try #require(
      try LedgerReceiptTrust.installKeyForTesting(fixtureKey, identity: identity),
      "Another key is already stored for this fixture's receipt on this machine.")

    try withFixtureDirectory { directory in
      let restoredURL = directory.appendingPathComponent("restored.sqlite")
      let restored = try LedgerStoreLifecycle.create(at: restoredURL).store
      try LedgerApplication(store: restored).importPackage(
        manifest: manifest(for: payload), payload: payload)
      let snapshot = try restored.readSnapshot()
      #expect(snapshot.transactions.count == transactionCount(object))
      #expect(snapshot.tags.count == (object["tags"] as? [Any])?.count)
      #expect(snapshot.transactionTemplates.count == (object["transactionTemplates"] as? [Any])?.count)
      #expect(snapshot.memos.count == (object["memos"] as? [Any])?.count)
      let reexported = try LedgerApplication(store: restored).exportPackage()
      if version == CanonicalLedgerSchema.version {
        #expect(try restored.semanticChecksum() == graph["canonicalChecksum"] as? String)
        #expect(reexported.payload == payload)
      } else {
        // Upgraded: the re-export is a current package and must itself restore unchanged.
        let again = try LedgerStoreLifecycle.create(
          at: directory.appendingPathComponent("again.sqlite")
        ).store
        try LedgerApplication(store: again).importPackage(
          manifest: reexported.manifest, payload: reexported.payload)
        #expect(try again.semanticChecksum() == restored.semanticChecksum())
      }
    }
  }

  @Test(
    "write the package fixture for today's schema",
    .enabled(if: ProcessInfo.processInfo.environment["LEDGER_ATLAS_WRITE_PACKAGE_FIXTURE"] == "1"))
  func writeCurrentFixture() throws {
    try withFixtureDirectory { directory in
      let backup = directory.appendingPathComponent("MM(fixture).mmbak")
      try SyntheticV19Backup.write(
        to: backup, marker: "package-fixture-v\(CanonicalLedgerSchema.version)")
      let canonical = directory.appendingPathComponent("fixture.sqlite")
      let staging = directory.appendingPathComponent("stage.sqlite")
      let workspace = ImportWorkspace()
      let preparation = try workspace.prepare(
        .init(
          sourceURL: backup, stagingDatabaseURL: staging, canonicalDatabaseURL: canonical,
          sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800)))
      let handle = try #require(preparation.preparedHandle)
      // Sign the receipt with the fixture key: install it for the staging ID before commit.
      let identity = try #require(stagingID(at: staging))
      try #require(try LedgerReceiptTrust.installKeyForTesting(fixtureKey, identity: identity))
      #expect(try workspace.commit(handle, approval: workspace.approve(handle)).status == .committed)

      // Product rows every schema's writers must keep restoring: a tag, a template, a memo.
      let store = try LedgerStore.openForMutation(at: canonical)
      let application = LedgerApplication(store: store)
      let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
      let account = try #require(try store.readSnapshot().accounts.first)
      let tag = try LedgerTag(
        id: StableLedgerID.tag(origin: origin, localKey: String(repeating: "a", count: 64)),
        name: "Fixture", origin: origin)
      try application.createTag(tag)
      try application.saveTransactionTemplate(
        try LedgerTransactionTemplate(
          id: StableLedgerID.transactionTemplate(
            origin: origin, localKey: String(repeating: "b", count: 64)),
          name: "Fixture template", kind: .expense, categoryID: nil,
          amount: CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal("3.25")),
          accountID: account.id, tags: try LedgerTagLinks([tag.id]), origin: origin))
      try application.saveMemo(
        try LedgerMemo(
          id: StableLedgerID.memo(origin: origin, localKey: String(repeating: "c", count: 64)),
          body: "Fixture memo", date: SourceLocalDate(year: 2025, month: 2, day: 3),
          origin: origin))
      let exported = try application.exportPackage()
      try FileManager.default.createDirectory(
        at: fixtureURL(CanonicalLedgerSchema.version).deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try exported.payload.write(to: fixtureURL(CanonicalLedgerSchema.version))
    }
  }
}

/// Test-only receipt key the fixtures are signed with. It protects nothing.
private let fixtureKey = Data(SHA256.hash(data: Data("ledger-atlas/package-fixture-key/v1".utf8)))

private func fixtureURL(_ version: Int) -> URL {
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/imported-ledger-v\(version).json")
}

private func manifest(for payload: Data) -> LedgerExportManifest {
  LedgerExportManifest(
    formatVersion: LedgerPortablePackageFormat.version,
    formatFingerprint: LedgerPortablePackageFormat.fingerprint,
    payloadSHA256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
    createdAtMilliseconds: 0)
}

private func receiptIdentity(_ graph: [String: Any]) -> String? {
  guard let tables = graph["tables"] as? [[String: Any]],
    let receipts = tables.first(where: { $0["name"] as? String == "import_receipt" }),
    let columns = receipts["columns"] as? [String],
    let index = columns.firstIndex(of: "idempotency_key"),
    let rows = receipts["rows"] as? [[[String]]], let first = rows.first,
    first[index].count == 2
  else { return nil }
  return first[index][1]
}

private func transactionCount(_ object: [String: Any]) -> Int {
  let revisions = object["revisions"] as? [[String: Any]] ?? []
  return Set(revisions.compactMap { $0["transactionID"] as? String }).count
}

private func stagingID(at url: URL) -> String? {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
    let database
  else { return nil }
  defer { sqlite3_close(database) }
  var statement: OpaquePointer?
  guard
    sqlite3_prepare_v2(
      database, "SELECT value FROM staging_meta WHERE key='staging_id'", -1, &statement, nil)
      == SQLITE_OK, let statement
  else { return nil }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0)
  else { return nil }
  return String(cString: text)
}

private func withFixtureDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "package-fixture-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}
