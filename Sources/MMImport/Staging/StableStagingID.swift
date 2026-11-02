import CryptoKit
import Foundation
import LedgerCore

public enum StableStagingID {
  public static func stage(
    artifactSHA256: String,
    profileID: String,
    adapterVersion: String
  ) -> String {
    CanonicalStagingID.stage(
      artifactSHA256: artifactSHA256, profileID: profileID, adapterVersion: adapterVersion)
  }

  public static func table(stagingID: String, table: String) -> String {
    CanonicalStagingID.table(stagingID: stagingID, table: table)
  }

  public static func record(
    stagingID: String,
    table: String,
    recordKey: String
  ) -> String {
    CanonicalStagingID.record(stagingID: stagingID, table: table, recordKey: recordKey)
  }

  public static func field(stagingID: String, locator: SourceLocator) -> String {
    CanonicalStagingID.field(stagingID: stagingID, locator: locator)
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
    // Row keys include raw canonical bytes and therefore do not use the string-only shared API.
    var hasher = SHA256()
    for component in components {
      var length = UInt64(component.count).bigEndian
      withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
      hasher.update(data: component)
    }
    return CanonicalReceiptDigest.hex(hasher.finalize())
  }
}
