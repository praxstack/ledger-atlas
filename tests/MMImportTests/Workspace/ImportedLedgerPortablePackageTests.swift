import CSQLite
import CryptoKit
import Foundation
import LedgerCore
import LedgerStore
import MMImport
import Testing

/// LA-048: a ledger with imported Money Manager history exports as a v4 portable package and
/// restores to the same ledger. All data is synthetic, built from the frozen v19 DDL.
@Suite("Imported ledger portable package")
struct ImportedLedgerPortablePackageTests {
  @Test("an imported ledger exports, restores to the same checksum, and keeps taking writes")
  func roundTripRebuildsTheSameLedger() throws {
    try withPackageDirectory { directory in
      let source = try importedLedger(in: directory)
      let sourceApplication = LedgerApplication(store: source)
      let exported = try sourceApplication.exportPackage()
      #expect(exported.manifest.formatVersion == LedgerPortablePackageFormat.version)
      let object = try packageObject(exported.payload)
      let graph = try #require(object["importGraph"] as? [String: Any])
      #expect(graph["canonicalChecksum"] as? String == (try source.semanticChecksum()))
      let tables = try #require(graph["tables"] as? [[String: Any]])
      #expect(tables.compactMap { $0["name"] as? String } == LedgerImportGraph.tableNames)

      let destinationURL = directory.appendingPathComponent("restored.sqlite")
      var destination: LedgerStore? = try LedgerStoreLifecycle.create(at: destinationURL).store
      try LedgerApplication(store: try #require(destination)).importPackage(
        manifest: exported.manifest, payload: exported.payload)
      let restored = try #require(destination)
      #expect(try restored.semanticChecksum() == source.semanticChecksum())
      let restoredSnapshot = try restored.readSnapshot()
      let sourceSnapshot = try source.readSnapshot()
      #expect(restoredSnapshot.accounts == sourceSnapshot.accounts)
      #expect(restoredSnapshot.categories == sourceSnapshot.categories)
      #expect(restoredSnapshot.revisionHistory == sourceSnapshot.revisionHistory)
      #expect(restoredSnapshot.recurrenceRules == sourceSnapshot.recurrenceRules)
      #expect(restoredSnapshot.budgets == sourceSnapshot.budgets)
      // Exporting the restored ledger gives back the same bytes.
      #expect(try LedgerApplication(store: restored).exportPackage().payload == exported.payload)

      // Write, reopen, write again: the restored ledger is a normal ledger afterwards.
      let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
      try LedgerApplication(store: restored).createAccount(
        try LedgerAccount(
          id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
          name: "After restore", currencyUnit: "USD", origin: origin))
      destination = nil
      let reopened = try LedgerStore.openForMutation(at: destinationURL)
      try LedgerApplication(store: reopened).createAccount(
        try LedgerAccount(
          id: StableLedgerID.account(origin: origin, localKey: String(repeating: "b", count: 64)),
          name: "After reopen", currencyUnit: "USD", origin: origin))
      let names = try reopened.readSnapshot().accounts.map(\.name)
      #expect(names.contains("After restore"))
      #expect(names.contains("After reopen"))
      #expect(try reopened.readSnapshot().transactions.count
        == source.readSnapshot().transactions.count)
    }
  }

  @Test("merge refuses a package with imported history, on either side")
  func mergeRefusesImportedHistory() throws {
    try withPackageDirectory { directory in
      let imported = try LedgerApplication(store: try importedLedger(in: directory))
        .exportPackage()
      let plainURL = directory.appendingPathComponent("plain.sqlite")
      let plainStore = try LedgerStoreLifecycle.create(at: plainURL).store
      let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
      try LedgerApplication(store: plainStore).createAccount(
        try LedgerAccount(
          id: StableLedgerID.account(origin: origin, localKey: String(repeating: "c", count: 64)),
          name: "Cash", currencyUnit: "USD", origin: origin))
      let plain = try LedgerApplication(store: plainStore).exportPackage()

      for (current, incoming) in [(imported, imported), (plain, imported), (imported, plain)] {
        #expect(throws: LedgerMergeError.importedHistory) {
          _ = try LedgerApplication.mergedPackage(current: current, incoming: incoming)
        }
      }
    }
  }

  @Test("an edited import graph is refused as tampered and nothing is written")
  func editedGraphIsTampered() throws {
    try withPackageDirectory { directory in
      let exported = try LedgerApplication(store: try importedLedger(in: directory))
        .exportPackage()
      let edited = try editingGraph(exported.payload) { graph in
        try setCell(in: &graph, table: "economic_event", column: "amount_literal", to: ["t", "41.00"])
      }
      try expectRestoreRefused(edited, in: directory, with: .packageTampered)
    }
  }

  @Test("an import graph from another schema is refused with its own reason")
  func otherSchemaIsRefused() throws {
    try withPackageDirectory { directory in
      let exported = try LedgerApplication(store: try importedLedger(in: directory))
        .exportPackage()
      let edited = try editingGraph(exported.payload) { graph in
        graph["schemaVersion"] = CanonicalLedgerSchema.version - 1
      }
      try expectRestoreRefused(edited, in: directory, with: .packageSchemaMismatch)
    }
  }

  @Test("an import graph signed with a key this Mac lacks is refused with its own reason")
  func missingKeyIsRefused() throws {
    try withPackageDirectory { directory in
      let exported = try LedgerApplication(store: try importedLedger(in: directory))
        .exportPackage()
      // A receipt identity no key was ever made for.
      let edited = try editingGraph(exported.payload) { graph in
        try setCell(
          in: &graph, table: "import_receipt", column: "idempotency_key",
          to: ["t", String(repeating: "f", count: 64)])
      }
      try expectRestoreRefused(edited, in: directory, with: .packageReceiptKeyMissing)
    }
  }

  @Test("an import graph with an unknown table or column is refused")
  func unknownShapeIsRefused() throws {
    try withPackageDirectory { directory in
      let exported = try LedgerApplication(store: try importedLedger(in: directory))
        .exportPackage()
      let renamedTable = try editingGraph(exported.payload) { graph in
        var tables = try #require(graph["tables"] as? [[String: Any]])
        tables[0]["name"] = "sqlite_master"
        graph["tables"] = tables
      }
      try expectRestoreRefused(renamedTable, in: directory, with: .invalidCommand)
      let renamedColumn = try editingGraph(exported.payload) { graph in
        var tables = try #require(graph["tables"] as? [[String: Any]])
        var columns = try #require(tables[0]["columns"] as? [String])
        columns[0] = "provenance_id); DROP TABLE ledger_meta; --"
        tables[0]["columns"] = columns
        graph["tables"] = tables
      }
      try expectRestoreRefused(renamedColumn, in: directory, with: .packageTampered)
    }
  }

  @Test("an edited graph with a recomputed checksum is still refused and nothing is written")
  func recomputedChecksumDoesNotHideAnEdit() throws {
    try withPackageDirectory { directory in
      let exported = try LedgerApplication(store: try importedLedger(in: directory))
        .exportPackage()
      // The checksum travels in the package, so an attacker can recompute it. Edit a copy of
      // the ledger the same way and take its checksum, then patch both into the package.
      let checksum = try forgedChecksum(in: directory) {
        "UPDATE economic_event SET amount_literal='41.00' WHERE rowid=(SELECT min(rowid) FROM economic_event)"
      }
      let edited = try editingGraph(exported.payload) { graph in
        try setCell(in: &graph, table: "economic_event", column: "amount_literal", to: ["t", "41.00"])
        graph["canonicalChecksum"] = checksum
      }
      // Not `.packageTampered`: the checksum matches, so the refusal comes from the receipt
      // checks in ledger health, which recompute the receipt digest from the rows.
      try expectRestoreRefused(edited, in: directory, with: .invalidCommand)
    }
  }

  @Test("a receipt signature made with another key is refused even with a matching checksum")
  func forgedSignatureIsRefused() throws {
    try withPackageDirectory { directory in
      let exported = try LedgerApplication(store: try importedLedger(in: directory))
        .exportPackage()
      let object = try packageObject(exported.payload)
      let graph = try #require(object["importGraph"] as? [String: Any])
      let receipt = try #require(
        cell(in: graph, table: "import_receipt", column: "idempotency_key"))
      let integrityHash = try #require(
        cell(in: graph, table: "import_receipt", column: "reconciliation_hash"))
      // A well-formed HMAC over the real receipt, made with a key that isn't this ledger's.
      let forged = LedgerReceiptTrust.signature(
        key: Data(repeating: 7, count: 32), receiptID: receipt, integrityHash: integrityHash)
      let checksum = try forgedChecksum(in: directory) {
        "UPDATE ledger_receipt_trust_anchor SET signature='\(forged)'"
      }
      let edited = try editingGraph(exported.payload) { graph in
        try setCell(in: &graph, table: "ledger_receipt_trust_anchor", column: "signature", to: ["t", forged])
        graph["canonicalChecksum"] = checksum
      }
      // Rows, digest and checksum all match; only the HMAC check with this Mac's key fails.
      try expectRestoreRefused(edited, in: directory, with: .invalidCommand)
    }
  }

  @Test("a malformed import graph is refused before anything is written")
  func malformedGraphIsRefused() throws {
    try withPackageDirectory { directory in
      let exported = try LedgerApplication(store: try importedLedger(in: directory))
        .exportPackage()
      let swapped = try editingGraph(exported.payload) { graph in
        var tables = try #require(graph["tables"] as? [[String: Any]])
        tables.swapAt(0, 1)
        graph["tables"] = tables
      }
      try expectRestoreRefused(swapped, in: directory, with: .invalidCommand)
      let shortRow = try editingGraph(exported.payload) { graph in
        var tables = try #require(graph["tables"] as? [[String: Any]])
        var rows = try #require(tables[0]["rows"] as? [[[String]]])
        rows[0].removeLast()
        tables[0]["rows"] = rows
        graph["tables"] = tables
      }
      try expectRestoreRefused(shortRow, in: directory, with: .invalidCommand)
    }
  }

  @Test("a v3 package that carries an import graph is refused")
  func legacyPackageWithGraphIsRefused() throws {
    try withPackageDirectory { directory in
      let exported = try LedgerApplication(store: try importedLedger(in: directory))
        .exportPackage()
      // Strip the other v4 keys so the import graph is the only thing v3 doesn't allow.
      var object = removingV4ProvenanceKeys(try packageObject(exported.payload))
      object["importGraph"] = try packageObject(exported.payload)["importGraph"]
      let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      let manifest = LedgerExportManifest(
        formatVersion: LedgerPortablePackageFormat.legacyV3Version,
        formatFingerprint: LedgerPortablePackageFormat.legacyV3Fingerprint,
        payloadSHA256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
        createdAtMilliseconds: 0)
      try expectRestoreRefused((manifest, payload), in: directory, with: .invalidCommand)
    }
  }

  @Test("a package from the previous schema restores through the upgrade chain")
  func previousSchemaPackageRestores() throws {
    try withPackageDirectory { directory in
      let source = try importedLedger(in: directory, includingTransfers: false)
      let exported = try LedgerApplication(store: source).exportPackage()
      // Turn today's package into one written at v11: the same ledger without the v12 objects,
      // with its v11 checksum, and without the v12 graph table.
      let v11Checksum = try previousReleaseChecksum(in: directory)
      let previous = try editingGraph(exported.payload) { graph in
        try makeV11(&graph, checksum: v11Checksum)
      }
      let destinationURL = directory.appendingPathComponent("upgraded.sqlite")
      let destination = try LedgerStoreLifecycle.create(at: destinationURL).store
      try LedgerApplication(store: destination).importPackage(
        manifest: previous.manifest, payload: previous.payload)
      // The v12 tables are empty in this ledger, so upgrading gives back the same ledger.
      #expect(try destination.semanticChecksum() == source.semanticChecksum())
      #expect(
        try destination.readSnapshot().transactions.count
          == source.readSnapshot().transactions.count)
      #expect(try LedgerApplication(store: destination).exportPackage().payload == exported.payload)

      // The checksum is checked at the package's own schema, before the upgrade.
      let tampered = try editingGraph(exported.payload) { graph in
        try makeV11(&graph, checksum: String(repeating: "0", count: 64))
      }
      try expectRestoreRefused(tampered, in: directory, with: .packageTampered)

      // v11 has no tags, so a v11 package that carries one is refused, not a crash.
      let withTag = try editingGraph(previous.payload) { _ in }
      var object = try packageObject(withTag.payload)
      let account = try #require((object["accounts"] as? [[String: Any]])?.first)
      let origin = try LedgerOrigin(
        id: try #require(account["originID"] as? String),
        label: try #require(account["originLabel"] as? String),
        provenanceID: account["originProvenanceID"] as? String)
      object["tags"] = [
        [
          "id": try StableLedgerID.tag(origin: origin, localKey: String(repeating: "d", count: 64)),
          "name": "Not in v11", "originID": origin.id, "originLabel": origin.label,
          "originProvenanceID": account["originProvenanceID"] ?? NSNull(), "lifecycle": "active",
        ] as [String: Any]
      ]
      let tagged = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      try expectRestoreRefused(
        (withTag.manifest.resealed(tagged), tagged), in: directory, with: .invalidCommand)
    }
  }

  /// v12 is the first schema a package with import history was written at. Every later schema
  /// must keep it in the upgrade chain, or those packages stop restoring (issue #115).
  @Test("every schema since package v4 still restores")
  func everyPackageSchemaHasAnUpgradePath() {
    #expect(CanonicalLedgerSchema.version >= 12)
    for version in 12..<max(12, CanonicalLedgerSchema.version) {
      let release = CanonicalLedgerSchema.lifecycleUpgradeSteps.first {
        $0.from.version == version
      }?.from
      #expect(
        release.flatMap {
          LedgerImportGraph.release(schemaVersion: $0.version, schemaFingerprint: $0.fingerprint)
        } != nil,
        "Schema \(version) must stay in the upgrade chain so its packages still restore.")
    }
  }
}

// MARK: - Helpers

extension LedgerExportManifest {
  fileprivate func resealed(_ payload: Data) -> LedgerExportManifest {
    LedgerExportManifest(
      formatVersion: formatVersion, formatFingerprint: formatFingerprint,
      payloadSHA256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
      createdAtMilliseconds: createdAtMilliseconds)
  }
}

private func importedLedger(in directory: URL, includingTransfers: Bool = true) throws
  -> LedgerStore
{
  let backup = directory.appendingPathComponent("MM(synthetic).mmbak")
  try SyntheticV19Backup.write(to: backup, includingTransfers: includingTransfers)
  let canonical = directory.appendingPathComponent("imported.sqlite")
  let workspace = ImportWorkspace()
  let preparation = try workspace.prepare(
    .init(
      sourceURL: backup, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
      canonicalDatabaseURL: canonical,
      sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 19_800)))
  let handle = try #require(preparation.preparedHandle)
  #expect(try workspace.commit(handle, approval: workspace.approve(handle)).status == .committed)
  return try LedgerStore.openReadOnly(at: canonical)
}

private func expectRestoreRefused(
  _ package: (manifest: LedgerExportManifest, payload: Data), in directory: URL,
  with expected: LedgerApplication.Error
) throws {
  let url = directory.appendingPathComponent("refused-\(UUID().uuidString).sqlite")
  let store = try LedgerStoreLifecycle.create(at: url).store
  let before = try store.semanticChecksum()
  #expect(throws: expected) {
    try LedgerApplication(store: store).importPackage(
      manifest: package.manifest, payload: package.payload)
  }
  #expect(try store.semanticChecksum() == before)
  #expect(try store.readSnapshot().transactions.isEmpty)
}

/// Copies the imported ledger, runs `sql` on the copy, and returns the copy's location.
private func editedCopy(in directory: URL, named name: String, _ sql: () -> String) throws -> URL {
  let copy = directory.appendingPathComponent(name)
  try withDatabase(directory.appendingPathComponent("imported.sqlite"), readOnly: true) {
    try exec($0, "VACUUM INTO '\(copy.path)'")
  }
  try withDatabase(copy, readOnly: false) { try exec($0, sql()) }
  return copy
}

/// What an attacker would put in the package: the checksum of the source ledger after the edit.
private func forgedChecksum(in directory: URL, _ sql: () -> String) throws -> String {
  let copy = try editedCopy(in: directory, named: "forged-\(UUID().uuidString).sqlite", sql)
  var checksum = ""
  try withDatabase(copy, readOnly: true) { checksum = try LedgerStore.canonicalChecksum($0) }
  return checksum
}

private func withDatabase(
  _ url: URL, readOnly: Bool, _ body: (OpaquePointer) throws -> Void
) throws {
  var database: OpaquePointer?
  let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
  guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
    throw SyntheticV19BackupError.sqlite
  }
  defer { sqlite3_close(database) }
  try body(database)
}

private func exec(_ database: OpaquePointer, _ sql: String) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw SyntheticV19BackupError.sqlite
  }
}

/// The imported ledger as it would have been at v11: a copy without the v12 objects, hashed
/// with the v11 checksum queries.
private func previousReleaseChecksum(in directory: URL) throws -> String {
  let v11Names = Set(CanonicalLedgerSchema.legacyV11Objects.map(\.name))
  let added = CanonicalLedgerSchema.expectedObjects.filter { !v11Names.contains($0.name) }
  let drops =
    added.filter { $0.type != "table" }.map { "DROP \($0.type.uppercased()) \($0.name)" }
    + added.filter { $0.type == "table" }.map { "DROP TABLE \($0.name)" }
  let copy = try editedCopy(in: directory, named: "v11.sqlite") { "SELECT 1" }
  var checksum = ""
  try withDatabase(copy, readOnly: false) { database in
    // A v11 ledger has no transfer pairs, so this one must not either.
    var statement: OpaquePointer?
    #expect(
      sqlite3_prepare_v2(
        database, "SELECT count(*) FROM economic_event_transfer", -1, &statement, nil)
        == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int64(statement, 0) == 0)
    sqlite3_finalize(statement)
    for drop in drops { try exec(database, drop) }
    try exec(
      database,
      "UPDATE ledger_meta SET value='11' WHERE key='schema_version'; UPDATE ledger_meta SET value='\(CanonicalLedgerSchema.legacyV11Fingerprint)' WHERE key='schema_fingerprint'"
    )
    checksum = try LedgerStore.canonicalChecksum(
      database, queries: CanonicalLedgerSchema.legacyV11ChecksumQueries)
  }
  return checksum
}

private func makeV11(_ graph: inout [String: Any], checksum: String) throws {
  graph["schemaVersion"] = 11
  graph["schemaFingerprint"] = CanonicalLedgerSchema.legacyV11Fingerprint
  graph["canonicalChecksum"] = checksum
  var tables = try #require(graph["tables"] as? [[String: Any]])
  tables.removeAll { $0["name"] as? String == "economic_event_transfer" }
  graph["tables"] = tables
}

private func cell(in graph: [String: Any], table name: String, column: String) -> String? {
  guard let tables = graph["tables"] as? [[String: Any]],
    let table = tables.first(where: { $0["name"] as? String == name }),
    let columns = table["columns"] as? [String], let index = columns.firstIndex(of: column),
    let rows = table["rows"] as? [[[String]]], let row = rows.first, row[index].count == 2
  else { return nil }
  return row[index][1]
}

private func removingV4ProvenanceKeys(_ object: [String: Any]) -> [String: Any] {
  func strip(_ value: Any) -> Any {
    if var row = value as? [String: Any] {
      row.removeValue(forKey: "originProvenanceID")
      if Set(row.keys) == ["field", "literal", "provenanceID"] {
        row.removeValue(forKey: "provenanceID")
      }
      return row.mapValues(strip)
    }
    if let rows = value as? [Any] { return rows.map(strip) }
    return value
  }
  var object = object
  object.removeValue(forKey: "importGraph")
  return object.mapValues(strip)
}

private func packageObject(_ payload: Data) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
}

/// Re-seals a package after editing its import graph, so only the graph check can catch it.
private func editingGraph(
  _ payload: Data, _ edit: (inout [String: Any]) throws -> Void
) throws -> (manifest: LedgerExportManifest, payload: Data) {
  var object = try packageObject(payload)
  var graph = try #require(object["importGraph"] as? [String: Any])
  try edit(&graph)
  object["importGraph"] = graph
  let edited = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  return (
    LedgerExportManifest(
      formatVersion: LedgerPortablePackageFormat.version,
      formatFingerprint: LedgerPortablePackageFormat.fingerprint,
      payloadSHA256: SHA256.hash(data: edited).map { String(format: "%02x", $0) }.joined(),
      createdAtMilliseconds: 0),
    edited
  )
}

private func setCell(
  in graph: inout [String: Any], table name: String, column: String, to cell: [String]
) throws {
  var tables = try #require(graph["tables"] as? [[String: Any]])
  let index = try #require(tables.firstIndex { $0["name"] as? String == name })
  let columns = try #require(tables[index]["columns"] as? [String])
  let columnIndex = try #require(columns.firstIndex(of: column))
  var rows = try #require(tables[index]["rows"] as? [[[String]]])
  try #require(!rows.isEmpty)
  rows[0][columnIndex] = cell
  tables[index]["rows"] = rows
  graph["tables"] = tables
}

private func withPackageDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "imported-package-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}
