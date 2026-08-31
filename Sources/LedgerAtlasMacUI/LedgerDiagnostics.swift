import Foundation
import LedgerCore
import LedgerStore

public struct LedgerDiagnosticsSnapshot: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let canonicalSchemaVersion: Int
  public let accountCount: Int
  public let categoryCount: Int
  public let transactionCount: Int
  public let preservedSourceCount: Int
  public let importedTransactionCount: Int
  public let nativeTransactionCount: Int

  public init(snapshot: LedgerStore.LedgerReadSnapshot) {
    schemaVersion = 1
    canonicalSchemaVersion = CanonicalLedgerSchema.version
    accountCount = snapshot.accounts.count
    categoryCount = snapshot.categories.count
    transactionCount = snapshot.transactions.count
    preservedSourceCount = snapshot.preservedSource.count
    importedTransactionCount = snapshot.transactions.filter {
      $0.currentRevision.draft.origin.label == LedgerOrigin.importedLabel
    }.count
    nativeTransactionCount = snapshot.transactions.filter {
      $0.currentRevision.draft.origin.label == LedgerOrigin.macNativeLabel
    }.count
  }
}

public enum LedgerDiagnosticsWriter {
  public static func write(_ diagnostics: LedgerDiagnosticsSnapshot, to destination: URL) throws {
    guard destination.isFileURL, !FileManager.default.fileExists(atPath: destination.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    let data = try JSONEncoder.output.encode(diagnostics)
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
      ".ledger-atlas-diagnostics-\(UUID().uuidString).tmp")
    do {
      try data.write(to: temporary, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: temporary.path)
      try FileManager.default.moveItem(at: temporary, to: destination)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }
}

private extension JSONEncoder {
  static let output: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return encoder
  }()
}
