import Foundation
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

@Test func diagnosticsWriterExportsOnlyBoundedStructuralFields() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let snapshot = LedgerStore.LedgerReadSnapshot(
    accounts: [], transactions: [], revisionHistory: [], undisplayedImportedEventCount: 0)
  let destination = directory.appendingPathComponent("diagnostics.json")
  try LedgerDiagnosticsWriter.write(.init(snapshot: snapshot), to: destination)
  let text = try String(contentsOf: destination, encoding: .utf8)
  #expect(text.contains("canonicalSchemaVersion"))
  #expect(!text.contains("/"))
  #expect(!text.contains("USD"))
  #expect(throws: CocoaError(.fileWriteFileExists)) {
    try LedgerDiagnosticsWriter.write(.init(snapshot: snapshot), to: destination)
  }
}
