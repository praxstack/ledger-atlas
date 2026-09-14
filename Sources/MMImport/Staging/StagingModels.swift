import Foundation

public struct StagingLimits: Codable, Equatable, Sendable {
  public let maximumTables: Int
  public let maximumRecords: Int
  public let maximumFields: Int
  public let maximumFieldsPerRecord: Int
  public let maximumValueBytes: Int
  public let maximumRecordBytes: Int
  public let maximumTotalBytes: Int
  public let maximumMetadataBytes: Int
  public let maximumCanonicalBytes: Int

  public init(
    maximumTables: Int = 10_000,
    maximumRecords: Int = 2_000_000,
    maximumFields: Int = 10_000_000,
    maximumFieldsPerRecord: Int = 10_000,
    maximumValueBytes: Int = 64 * 1_024 * 1_024,
    maximumRecordBytes: Int = 128 * 1_024 * 1_024,
    maximumTotalBytes: Int = 512 * 1_024 * 1_024,
    maximumMetadataBytes: Int = 16 * 1_024 * 1_024,
    maximumCanonicalBytes: Int = 512 * 1_024 * 1_024
  ) throws {
    guard maximumTables > 0, maximumRecords > 0, maximumFields > 0,
      maximumFieldsPerRecord > 0,
      maximumValueBytes > 0, maximumRecordBytes > 0, maximumTotalBytes > 0,
      maximumMetadataBytes > 0, maximumCanonicalBytes > 0,
      maximumValueBytes <= maximumRecordBytes,
      maximumRecordBytes <= maximumTotalBytes
    else { throw StagingError.invalidLimits }
    self.init(
      validatedMaximumTables: maximumTables,
      maximumRecords: maximumRecords,
      maximumFields: maximumFields,
      maximumFieldsPerRecord: maximumFieldsPerRecord,
      maximumValueBytes: maximumValueBytes,
      maximumRecordBytes: maximumRecordBytes,
      maximumTotalBytes: maximumTotalBytes,
      maximumMetadataBytes: maximumMetadataBytes,
      maximumCanonicalBytes: maximumCanonicalBytes)
  }

  private init(
    validatedMaximumTables maximumTables: Int,
    maximumRecords: Int,
    maximumFields: Int,
    maximumFieldsPerRecord: Int,
    maximumValueBytes: Int,
    maximumRecordBytes: Int,
    maximumTotalBytes: Int,
    maximumMetadataBytes: Int,
    maximumCanonicalBytes: Int
  ) {
    self.maximumTables = maximumTables
    self.maximumRecords = maximumRecords
    self.maximumFields = maximumFields
    self.maximumFieldsPerRecord = maximumFieldsPerRecord
    self.maximumValueBytes = maximumValueBytes
    self.maximumRecordBytes = maximumRecordBytes
    self.maximumTotalBytes = maximumTotalBytes
    self.maximumMetadataBytes = maximumMetadataBytes
    self.maximumCanonicalBytes = maximumCanonicalBytes
  }

  public static let standard = StagingLimits(
    validatedMaximumTables: 10_000,
    maximumRecords: 2_000_000,
    maximumFields: 10_000_000,
    maximumFieldsPerRecord: 10_000,
    maximumValueBytes: 64 * 1_024 * 1_024,
    maximumRecordBytes: 128 * 1_024 * 1_024,
    maximumTotalBytes: 512 * 1_024 * 1_024,
    maximumMetadataBytes: 16 * 1_024 * 1_024,
    maximumCanonicalBytes: 512 * 1_024 * 1_024)

  var stableDescription: String {
    [
      maximumTables, maximumRecords, maximumFields, maximumFieldsPerRecord,
      maximumValueBytes, maximumRecordBytes, maximumTotalBytes, maximumMetadataBytes,
      maximumCanonicalBytes,
    ].map(String.init).joined(separator: ":")
  }

  private enum CodingKeys: String, CodingKey {
    case maximumTables
    case maximumRecords
    case maximumFields
    case maximumFieldsPerRecord
    case maximumValueBytes
    case maximumRecordBytes
    case maximumTotalBytes
    case maximumMetadataBytes
    case maximumCanonicalBytes
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      maximumTables: container.decode(Int.self, forKey: .maximumTables),
      maximumRecords: container.decode(Int.self, forKey: .maximumRecords),
      maximumFields: container.decode(Int.self, forKey: .maximumFields),
      maximumFieldsPerRecord: container.decode(Int.self, forKey: .maximumFieldsPerRecord),
      maximumValueBytes: container.decode(Int.self, forKey: .maximumValueBytes),
      maximumRecordBytes: container.decode(Int.self, forKey: .maximumRecordBytes),
      maximumTotalBytes: container.decode(Int.self, forKey: .maximumTotalBytes),
      maximumMetadataBytes: container.decode(Int.self, forKey: .maximumMetadataBytes),
      maximumCanonicalBytes: container.decode(Int.self, forKey: .maximumCanonicalBytes))
  }
}

public struct StagingRequest: Equatable, Sendable {
  public static let automaticAdapterVersion = "mmimport-staging-v1"

  public let sourceURL: URL
  public let stagingDatabaseURL: URL
  public let adapterVersion: String
  public let limits: StagingLimits

  public init(
    sourceURL: URL,
    stagingDatabaseURL: URL,
    adapterVersion: String = Self.automaticAdapterVersion,
    limits: StagingLimits = .standard
  ) {
    self.sourceURL = sourceURL
    self.stagingDatabaseURL = stagingDatabaseURL
    self.adapterVersion = adapterVersion
    self.limits = limits
  }
}

public enum StagingStatus: String, Codable, Equatable, Sendable {
  case staged
  case reused
}

public struct StagingManifest: Codable, Equatable, Sendable {
  public let formatVersion: Int
  public let stagingID: String
  public let artifactSHA256: String
  public let profileID: String
  public let adapterVersion: String
  public let tableCount: Int
  public let recordCount: Int
  public let fieldCount: Int
  public let opaqueByteCount: Int

  public init(
    formatVersion: Int = 1,
    stagingID: String,
    artifactSHA256: String,
    profileID: String,
    adapterVersion: String,
    tableCount: Int,
    recordCount: Int,
    fieldCount: Int,
    opaqueByteCount: Int
  ) {
    self.formatVersion = formatVersion
    self.stagingID = stagingID
    self.artifactSHA256 = artifactSHA256
    self.profileID = profileID
    self.adapterVersion = adapterVersion
    self.tableCount = tableCount
    self.recordCount = recordCount
    self.fieldCount = fieldCount
    self.opaqueByteCount = opaqueByteCount
  }
}

public struct StagingResult: Equatable, Sendable {
  public let status: StagingStatus
  public let manifest: StagingManifest
  /// Digest of the complete canonical staging database, including its schema and opaque fields.
  /// This is safe to expose in a redacted report and is required to authenticate adapter input.
  public let stagingDigest: String

  public init(status: StagingStatus, manifest: StagingManifest, stagingDigest: String) {
    self.status = status
    self.manifest = manifest
    self.stagingDigest = stagingDigest
  }
}

public enum StagingError: String, Codable, Error, Equatable, Sendable {
  case invalidLimits = "invalid_limits"
  case invalidRequest = "invalid_request"
  case unsupportedClassification = "unsupported_classification"
  case selectedZIPMemberUnavailable = "zip_selected_member_unavailable"
  case sourceChanged = "source_changed"
  case sourceReadFailed = "source_read_failed"
  case sourceSQLiteInvalid = "source_sqlite_invalid"
  case tableLimitExceeded = "table_limit_exceeded"
  case recordCountLimitExceeded = "record_count_limit_exceeded"
  case fieldLimitExceeded = "field_count_limit_exceeded"
  case metadataLimitExceeded = "metadata_byte_limit_exceeded"
  case canonicalLimitExceeded = "canonical_byte_limit_exceeded"
  case valueLimitExceeded = "value_limit_exceeded"
  case recordLimitExceeded = "record_byte_limit_exceeded"
  case totalLimitExceeded = "total_byte_limit_exceeded"
  case destinationExists = "destination_conflict"
  case stagingWriteFailed = "staging_write_failed"

  public var reasonCode: String { rawValue }
}

public struct RedactedStagingReport: Codable, Equatable, Sendable {
  public let reportVersion: Int
  public let status: String
  public let manifest: StagingManifest?
  public let stagingID: String?
  public let stagingDigest: String?
  public let artifactSHA256: String?
  public let profileID: String?
  public let adapterVersion: String?
  public let tableCount: Int?
  public let recordCount: Int?
  public let fieldCount: Int?
  public let opaqueByteCount: Int?
  public let reasonCodes: [String]

  public init(_ result: StagingResult) {
    reportVersion = 2
    status = result.status.rawValue
    manifest = result.manifest
    stagingID = result.manifest.stagingID
    stagingDigest = result.stagingDigest
    artifactSHA256 = result.manifest.artifactSHA256
    profileID = result.manifest.profileID
    adapterVersion = result.manifest.adapterVersion
    tableCount = result.manifest.tableCount
    recordCount = result.manifest.recordCount
    fieldCount = result.manifest.fieldCount
    opaqueByteCount = result.manifest.opaqueByteCount
    reasonCodes = []
  }

  public init(error: StagingError) {
    reportVersion = 2
    status = "blocked"
    manifest = nil
    stagingID = nil
    stagingDigest = nil
    artifactSHA256 = nil
    profileID = nil
    adapterVersion = nil
    tableCount = nil
    recordCount = nil
    fieldCount = nil
    opaqueByteCount = nil
    reasonCodes = [error.reasonCode]
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  public var humanDescription: String {
    [
      "status=\(status)",
      "staging_id=\(stagingID ?? "none")",
      "staging_digest=\(stagingDigest ?? "none")",
      "artifact_sha256=\(artifactSHA256 ?? "none")",
      "profile_id=\(profileID ?? "none")",
      "adapter_version=\(adapterVersion ?? "none")",
      "tables=\(tableCount.map(String.init) ?? "none")",
      "records=\(recordCount.map(String.init) ?? "none")",
      "fields=\(fieldCount.map(String.init) ?? "none")",
      "opaque_bytes=\(opaqueByteCount.map(String.init) ?? "none")",
      "reasons=\(reasonCodes.isEmpty ? "none" : reasonCodes.joined(separator: ","))",
    ].joined(separator: "\n")
  }
}
