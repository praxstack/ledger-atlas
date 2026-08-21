import Foundation
import LedgerCore

public enum SQLiteStorageClass: String, Codable, CaseIterable, Sendable {
  case null
  case integer
  case real
  case blob
  case text
}

public enum OpaqueSidecarError: String, Error, Equatable, Sendable {
  case invalidFormatVersion = "invalid_sidecar_format_version"
  case invalidLimit = "invalid_sidecar_limit"
  case valueLimitExceeded = "sidecar_value_limit_exceeded"
  case invalidPayload = "invalid_sidecar_payload"
}

public struct OpaqueSidecar: Codable, Equatable, Sendable {
  public let formatVersion: Int
  public let declaredType: String?
  public let storageClass: SQLiteStorageClass
  public let payload: Data
  public let provenance: FieldProvenance

  public init(
    formatVersion: Int = 1,
    declaredType: String?,
    storageClass: SQLiteStorageClass,
    payload: Data,
    provenance: FieldProvenance,
    maximumBytes: Int = 64 * 1_024 * 1_024
  ) throws {
    guard formatVersion == 1 else { throw OpaqueSidecarError.invalidFormatVersion }
    guard maximumBytes > 0 else { throw OpaqueSidecarError.invalidLimit }
    guard payload.count <= maximumBytes else {
      throw OpaqueSidecarError.valueLimitExceeded
    }
    switch storageClass {
    case .null:
      guard payload.isEmpty else { throw OpaqueSidecarError.invalidPayload }
    case .integer, .real:
      guard payload.count == MemoryLayout<UInt64>.size else {
        throw OpaqueSidecarError.invalidPayload
      }
    case .blob, .text:
      break
    }
    self.formatVersion = formatVersion
    self.declaredType = declaredType
    self.storageClass = storageClass
    self.payload = payload
    self.provenance = provenance
  }

  public var integerBitPattern: UInt64? {
    guard storageClass == .integer, payload.count == MemoryLayout<UInt64>.size else {
      return nil
    }
    return decodeUInt64(payload)
  }

  public var realBitPattern: UInt64? {
    guard storageClass == .real, payload.count == MemoryLayout<UInt64>.size else {
      return nil
    }
    return decodeUInt64(payload)
  }

  private enum CodingKeys: String, CodingKey {
    case formatVersion
    case declaredType
    case storageClass
    case payload
    case provenance
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      formatVersion: container.decode(Int.self, forKey: .formatVersion),
      declaredType: container.decodeIfPresent(String.self, forKey: .declaredType),
      storageClass: container.decode(SQLiteStorageClass.self, forKey: .storageClass),
      payload: container.decode(Data.self, forKey: .payload),
      provenance: container.decode(FieldProvenance.self, forKey: .provenance))
  }
}

private func decodeUInt64(_ data: Data) -> UInt64 {
  data.reduce(0) { ($0 << 8) | UInt64($1) }
}
