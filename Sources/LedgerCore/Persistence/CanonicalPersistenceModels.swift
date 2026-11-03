import CryptoKit
import Foundation

/// Stable, length-delimited primitives for digests persisted in canonical SQLite rows.
/// Keep component ordering with the caller: these routines deliberately only encode primitives.
package enum CanonicalReceiptDigest {
  package static let eventSetPrefix = "ledger-atlas/canonical-event-set/v4"

  package static func hash(_ components: [String]) -> String {
    var hasher = SHA256()
    for component in components {
      // Hashes the UTF-8 bytes in place. Health recomputes hundreds of thousands of these for a
      // real import, so copying each string into `Data` first was a large share of open time.
      var component = component
      component.withUTF8 { bytes in
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(bytes))
      }
    }
    return hex(hasher.finalize())
  }

  private static let hexDigits = Array("0123456789abcdef".utf8)

  /// Lowercase hex, the same text `String(format: "%02x")` gives, without a formatter per byte.
  package static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    var utf8: [UInt8] = []
    utf8.reserveCapacity(64)
    for byte in bytes {
      utf8.append(hexDigits[Int(byte >> 4)])
      utf8.append(hexDigits[Int(byte & 0x0f)])
    }
    return String(decoding: utf8, as: UTF8.self)
  }

  package static func optionalComponents(_ value: String?) -> [String] {
    value.map { ["optional:some", $0] } ?? ["optional:none"]
  }

  package static func sha256(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
  }
}

public enum CanonicalPersistenceError: String, Error, Equatable, Sendable {
  case invalidIdentifier = "invalid_identifier"
  case invalidEvent = "invalid_event"
  case invalidSourceBinding = "invalid_source_binding"
  case invalidSidecarReference = "invalid_sidecar_reference"
  case invalidReceiptOwnedPreservation = "invalid_receipt_owned_preservation"
}

public enum CanonicalEventKind: String, Codable, CaseIterable, Sendable {
  case income
  case expense
  case transferDebit = "transfer_debit"
  case transferCredit = "transfer_credit"
  case adjustment
  /// A balance adjustment that removes money (for example a Money Manager balance decrease).
  /// Plain `adjustment` adds money.
  case adjustmentDebit = "adjustment_debit"
}

public enum CanonicalFieldStorageClass: String, Codable, CaseIterable, Sendable {
  case null
  case integer
  case real
  case blob
  case text
}

public enum CanonicalEventSourceSemantic: String, Codable, CaseIterable, Sendable {
  case amount
  case currency
  case occurredAt = "occurred_at"
  case account
  case kind
}

public enum CanonicalPreservationSubjectKind: String, Codable, CaseIterable, Sendable {
  case table
  case record
}

public struct CanonicalEventSourceBinding: Codable, Equatable, Hashable, Sendable {
  public let semantic: CanonicalEventSourceSemantic
  public let provenance: FieldProvenance
  public let declaredType: String?
  public let storageClass: CanonicalFieldStorageClass

  public init(
    semantic: CanonicalEventSourceSemantic,
    provenance: FieldProvenance,
    declaredType: String?,
    storageClass: CanonicalFieldStorageClass
  ) throws {
    guard CanonicalIdentifier.isValid(provenance.deterministicID),
      declaredType?.utf8.count ?? 0 <= 1_024,
      declaredType?.utf8.contains(0) != true,
      provenance.locator.containerMember?.utf8.contains(0) != true,
      !provenance.locator.table.utf8.contains(0),
      !provenance.locator.recordKey.utf8.contains(0),
      provenance.locator.columnName?.utf8.contains(0) != true
    else { throw CanonicalPersistenceError.invalidSourceBinding }
    self.semantic = semantic
    self.provenance = provenance
    self.declaredType = declaredType
    self.storageClass = storageClass
  }
}

public struct CanonicalSidecarReference: Codable, Equatable, Hashable, Sendable {
  public let sidecarID: String
  public let provenanceID: String

  public init(sidecarID: String, provenanceID: String) throws {
    guard CanonicalIdentifier.isValid(sidecarID), CanonicalIdentifier.isValid(provenanceID) else {
      throw CanonicalPersistenceError.invalidSidecarReference
    }
    self.sidecarID = sidecarID
    self.provenanceID = provenanceID
  }
}

public struct CanonicalPersistedSidecar: Codable, Equatable, Sendable {
  public let sidecarID: String
  public let eventID: String
  public let formatVersion: Int
  public let declaredType: String?
  public let storageClass: CanonicalFieldStorageClass
  public let payload: Data
  public let provenance: FieldProvenance

  public init(
    sidecarID: String,
    eventID: String,
    formatVersion: Int,
    declaredType: String?,
    storageClass: CanonicalFieldStorageClass,
    payload: Data,
    provenance: FieldProvenance,
    maximumBytes: Int = 64 * 1_024 * 1_024
  ) throws {
    guard CanonicalIdentifier.isValid(sidecarID), CanonicalIdentifier.isValid(eventID),
      sidecarID == provenance.deterministicID, formatVersion == 1,
      maximumBytes > 0, payload.count <= maximumBytes,
      declaredType?.utf8.count ?? 0 <= 1_024,
      declaredType?.utf8.contains(0) != true,
      provenance.locator.containerMember?.utf8.contains(0) != true,
      !provenance.locator.table.utf8.contains(0),
      !provenance.locator.recordKey.utf8.contains(0),
      provenance.locator.columnName?.utf8.contains(0) != true
    else { throw CanonicalPersistenceError.invalidSidecarReference }
    switch storageClass {
    case .null:
      guard payload.isEmpty else { throw CanonicalPersistenceError.invalidSidecarReference }
    case .integer, .real:
      guard payload.count == MemoryLayout<UInt64>.size else {
        throw CanonicalPersistenceError.invalidSidecarReference
      }
    case .blob, .text:
      break
    }
    self.sidecarID = sidecarID
    self.eventID = eventID
    self.formatVersion = formatVersion
    self.declaredType = declaredType
    self.storageClass = storageClass
    self.payload = payload
    self.provenance = provenance
  }
}

public struct CanonicalReceiptOwnedAnchor: Codable, Equatable, Sendable {
  public let anchorID: String
  public let receiptID: String
  public let sourceSubjectID: String
  public let subjectKind: CanonicalPreservationSubjectKind
  public let artifactSHA256: String
  public let profileID: String
  public let adapterVersion: String
  public let containerMember: String?
  public let sourceTable: String
  public let sourceRecordKey: String?

  public init(
    anchorID: String,
    receiptID: String,
    sourceSubjectID: String,
    subjectKind: CanonicalPreservationSubjectKind,
    artifactSHA256: String,
    profileID: String,
    adapterVersion: String,
    containerMember: String?,
    sourceTable: String,
    sourceRecordKey: String?
  ) throws {
    guard CanonicalIdentifier.isValid(anchorID), CanonicalIdentifier.isValid(receiptID),
      CanonicalIdentifier.isValid(sourceSubjectID),
      anchorID
        == (try? StableCanonicalID.preservationAnchor(
          stagingID: receiptID, sourceSubjectID: sourceSubjectID, kind: subjectKind)),
      CanonicalIdentifier.isValid(artifactSHA256),
      !profileID.isEmpty, profileID.utf8.count <= 256,
      !profileID.utf8.contains(0),
      !adapterVersion.isEmpty, adapterVersion.utf8.count <= 256,
      !adapterVersion.utf8.contains(0),
      containerMember?.utf8.count ?? 0 <= 4_096,
      containerMember?.utf8.contains(0) != true,
      !sourceTable.isEmpty, sourceTable.utf8.count <= 1_024,
      !sourceTable.utf8.contains(0),
      sourceRecordKey?.utf8.count ?? 0 <= 4_096,
      sourceRecordKey?.utf8.contains(0) != true,
      (subjectKind == .table && sourceRecordKey == nil)
        || (subjectKind == .record && sourceRecordKey?.isEmpty == false)
    else { throw CanonicalPersistenceError.invalidReceiptOwnedPreservation }
    self.anchorID = anchorID
    self.receiptID = receiptID
    self.sourceSubjectID = sourceSubjectID
    self.subjectKind = subjectKind
    self.artifactSHA256 = artifactSHA256
    self.profileID = profileID
    self.adapterVersion = adapterVersion
    self.containerMember = containerMember
    self.sourceTable = sourceTable
    self.sourceRecordKey = sourceRecordKey
  }
}

public struct CanonicalReceiptOwnedPayload: Codable, Equatable, Sendable {
  public let payloadID: String
  public let receiptID: String
  public let anchorID: String
  public let sourceSubjectID: String
  public let formatVersion: Int
  public let declaredType: String?
  public let storageClass: CanonicalFieldStorageClass
  public let payload: Data
  public let provenance: FieldProvenance

  public init(
    payloadID: String,
    receiptID: String,
    anchorID: String,
    sourceSubjectID: String,
    formatVersion: Int,
    declaredType: String?,
    storageClass: CanonicalFieldStorageClass,
    payload: Data,
    provenance: FieldProvenance,
    maximumBytes: Int = 64 * 1_024 * 1_024
  ) throws {
    guard CanonicalIdentifier.isValid(payloadID), CanonicalIdentifier.isValid(receiptID),
      CanonicalIdentifier.isValid(anchorID),
      CanonicalIdentifier.isValid(sourceSubjectID), sourceSubjectID == provenance.deterministicID,
      payloadID
        == (try? StableCanonicalID.preservationPayload(
          receiptID: receiptID, anchorID: anchorID, sourceSubjectID: sourceSubjectID,
          formatVersion: formatVersion, declaredType: declaredType,
          storageClass: storageClass, payload: payload)),
      formatVersion == 1, maximumBytes > 0, payload.count <= maximumBytes,
      declaredType?.utf8.count ?? 0 <= 1_024,
      declaredType?.utf8.contains(0) != true,
      provenance.locator.containerMember?.utf8.contains(0) != true,
      !provenance.locator.table.utf8.contains(0),
      !provenance.locator.recordKey.utf8.contains(0),
      provenance.locator.columnName?.utf8.contains(0) != true
    else { throw CanonicalPersistenceError.invalidReceiptOwnedPreservation }
    switch storageClass {
    case .null:
      guard payload.isEmpty else {
        throw CanonicalPersistenceError.invalidReceiptOwnedPreservation
      }
    case .integer, .real:
      guard payload.count == MemoryLayout<UInt64>.size else {
        throw CanonicalPersistenceError.invalidReceiptOwnedPreservation
      }
    case .blob, .text:
      break
    }
    self.payloadID = payloadID
    self.receiptID = receiptID
    self.anchorID = anchorID
    self.sourceSubjectID = sourceSubjectID
    self.formatVersion = formatVersion
    self.declaredType = declaredType
    self.storageClass = storageClass
    self.payload = payload
    self.provenance = provenance
  }
}

public struct CanonicalReceiptOwnedPreservation: Equatable, Sendable {
  public let anchors: [CanonicalReceiptOwnedAnchor]
  public let payloads: [CanonicalReceiptOwnedPayload]

  public init(
    anchors: [CanonicalReceiptOwnedAnchor], payloads: [CanonicalReceiptOwnedPayload]
  ) {
    self.anchors = anchors.sorted { $0.anchorID < $1.anchorID }
    self.payloads = payloads.sorted { $0.payloadID < $1.payloadID }
  }
}

public struct CanonicalEconomicEvent: Codable, Equatable, Sendable {
  public let eventID: String
  public let accountID: String
  public let kind: CanonicalEventKind
  public let amount: CurrencyAmount
  public let occurredAt: SourceTemporal
  public let sourceRecordID: String
  public let amountProvenance: FieldProvenance
  public let sourceBindings: [CanonicalEventSourceBinding]
  public let sidecarReferences: [CanonicalSidecarReference]

  public init(
    eventID: String,
    accountID: String,
    kind: CanonicalEventKind,
    amount: CurrencyAmount,
    occurredAt: SourceTemporal,
    sourceRecordID: String,
    amountProvenance: FieldProvenance,
    sourceBindings: [CanonicalEventSourceBinding],
    sidecarReferences: [CanonicalSidecarReference] = []
  ) throws {
    guard CanonicalIdentifier.isValid(eventID), CanonicalIdentifier.isValid(accountID),
      CanonicalIdentifier.isValid(sourceRecordID),
      CanonicalIdentifier.isValid(amountProvenance.artifactSHA256),
      CanonicalIdentifier.isValid(amountProvenance.deterministicID),
      sourceBindings.count == CanonicalEventSourceSemantic.allCases.count,
      Set(sourceBindings.map(\.semantic)).count == sourceBindings.count,
      Set(sourceBindings.map { $0.provenance.deterministicID }).count == sourceBindings.count,
      sourceBindings.contains(where: {
        $0.semantic == .amount && $0.provenance == amountProvenance
      }),
      Set(sidecarReferences.map(\.sidecarID)).count == sidecarReferences.count
    else { throw CanonicalPersistenceError.invalidEvent }
    self.eventID = eventID
    self.accountID = accountID
    self.kind = kind
    self.amount = amount
    self.occurredAt = occurredAt
    self.sourceRecordID = sourceRecordID
    self.amountProvenance = amountProvenance
    self.sourceBindings = sourceBindings.sorted { $0.semantic.rawValue < $1.semantic.rawValue }
    self.sidecarReferences = sidecarReferences.sorted { $0.sidecarID < $1.sidecarID }
  }
}

public enum StableCanonicalID {
  public static func event(sourceRecordID: String, effectOrdinal: Int) throws -> String {
    guard CanonicalIdentifier.isValid(sourceRecordID), effectOrdinal >= 0 else {
      throw CanonicalPersistenceError.invalidIdentifier
    }
    return digest(["ledger-atlas/economic-event/v1", sourceRecordID, String(effectOrdinal)])
  }

  public static func account(profileID: String, sourceAccountID: String) throws -> String {
    guard !profileID.isEmpty, profileID.utf8.count <= 256,
      !sourceAccountID.isEmpty, sourceAccountID.utf8.count <= 1024
    else { throw CanonicalPersistenceError.invalidIdentifier }
    return digest(["ledger-atlas/account/v1", profileID, sourceAccountID])
  }

  public static func category(profileID: String, sourceCategoryID: String) throws -> String {
    guard !profileID.isEmpty, profileID.utf8.count <= 256,
      !sourceCategoryID.isEmpty, sourceCategoryID.utf8.count <= 1024
    else { throw CanonicalPersistenceError.invalidIdentifier }
    return digest(["ledger-atlas/category/v1", profileID, sourceCategoryID])
  }

  public static func preservationAnchor(
    stagingID: String, sourceSubjectID: String, kind: CanonicalPreservationSubjectKind
  ) throws -> String {
    guard CanonicalIdentifier.isValid(stagingID), CanonicalIdentifier.isValid(sourceSubjectID)
    else { throw CanonicalPersistenceError.invalidIdentifier }
    return digest([
      "ledger-atlas/receipt-owned-anchor/v1", stagingID, sourceSubjectID, kind.rawValue,
    ])
  }

  public static func preservationPayload(
    receiptID: String, anchorID: String, sourceSubjectID: String,
    formatVersion: Int, declaredType: String?, storageClass: CanonicalFieldStorageClass,
    payload: Data
  ) throws -> String {
    guard CanonicalIdentifier.isValid(receiptID), CanonicalIdentifier.isValid(anchorID),
      CanonicalIdentifier.isValid(sourceSubjectID), formatVersion == 1,
      declaredType?.utf8.count ?? 0 <= 1_024
    else { throw CanonicalPersistenceError.invalidIdentifier }
    let payloadDigest = CanonicalReceiptDigest.hex(SHA256.hash(data: payload))
    var components = [
      "ledger-atlas/receipt-owned-payload/v3", receiptID, anchorID, sourceSubjectID,
      String(formatVersion),
    ]
    components.append(contentsOf: optionalComponents(declaredType))
    components.append(contentsOf: [storageClass.rawValue, payloadDigest])
    return digest(components)
  }

  private static func optionalComponents(_ value: String?) -> [String] {
    guard let value else { return ["optional:none"] }
    return ["optional:some", value]
  }

  private static func digest(_ components: [String]) -> String {
    var hasher = SHA256()
    for component in components {
      let data = Data(component.utf8)
      var length = UInt64(data.count).bigEndian
      withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
      hasher.update(data: data)
    }
    return CanonicalReceiptDigest.hex(hasher.finalize())
  }
}

/// Stable source identities shared by staging and persisted-ledger validation.
package enum CanonicalStagingID {
  package static func stage(
    artifactSHA256: String, profileID: String, adapterVersion: String
  ) -> String {
    digest(["ledger-atlas/staging/v1", artifactSHA256, profileID, adapterVersion])
  }

  package static func table(stagingID: String, table: String) -> String {
    digest(["ledger-atlas/staging/table/v1", stagingID, table])
  }

  package static func record(stagingID: String, table: String, recordKey: String) -> String {
    digest(["ledger-atlas/staging/record/v1", stagingID, table, recordKey])
  }

  package static func field(stagingID: String, locator: SourceLocator) -> String {
    digest([
      "ledger-atlas/staging/field/v1", stagingID, locator.containerMember ?? "",
      locator.table, locator.recordKey, locator.columnOrdinal.map(String.init) ?? "",
      locator.columnName ?? "",
    ])
  }

  private static func digest(_ components: [String]) -> String {
    CanonicalReceiptDigest.hash(components)
  }
}

public enum CanonicalIdentifier {
  public static func isValid(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }
}
