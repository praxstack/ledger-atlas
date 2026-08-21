import CryptoKit
import Foundation
import LedgerCore

public enum StableStagingID {
  public static func stage(
    artifactSHA256: String,
    profileID: String,
    adapterVersion: String
  ) -> String {
    digest([
      "ledger-atlas/staging/v1", artifactSHA256, profileID, adapterVersion,
    ])
  }

  public static func table(stagingID: String, table: String) -> String {
    digest(["ledger-atlas/staging/table/v1", stagingID, table])
  }

  public static func record(
    stagingID: String,
    table: String,
    recordKey: String
  ) -> String {
    digest(["ledger-atlas/staging/record/v1", stagingID, table, recordKey])
  }

  public static func field(stagingID: String, locator: SourceLocator) -> String {
    digest([
      "ledger-atlas/staging/field/v1",
      stagingID,
      locator.containerMember ?? "",
      locator.table,
      locator.recordKey,
      locator.columnOrdinal.map(String.init) ?? "",
      locator.columnName ?? "",
    ])
  }

  static func rowKey(canonicalRecord: Data, duplicateOrdinal: Int) -> String {
    digest([
      Data("ledger-atlas/staging/row-key/v1".utf8),
      canonicalRecord,
      Data(String(duplicateOrdinal).utf8),
    ])
  }

  static func digest(_ components: [String]) -> String {
    digest(components.map { Data($0.utf8) })
  }

  static func digest(_ components: [Data]) -> String {
    var hasher = SHA256()
    for component in components {
      var length = UInt64(component.count).bigEndian
      withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
      hasher.update(data: component)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
