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
}

// MARK: - Helpers

private func importedLedger(in directory: URL) throws -> LedgerStore {
  let backup = directory.appendingPathComponent("MM(synthetic).mmbak")
  try SyntheticV19Backup.write(to: backup)
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
