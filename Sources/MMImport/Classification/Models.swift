import Foundation

public enum SourceContainer: String, Codable, Sendable {
  case sqlite
  case zip
  case unknown
}

public struct SourceFingerprint: Codable, Equatable, Sendable {
  public let sha256: String
  public let sizeBytes: UInt64
  public let deviceID: UInt64
  public let inode: UInt64
  public let modificationTimeSeconds: Int64
  public let modificationTimeNanoseconds: Int64

  public init(
    sha256: String,
    sizeBytes: UInt64,
    deviceID: UInt64,
    inode: UInt64,
    modificationTimeSeconds: Int64,
    modificationTimeNanoseconds: Int64
  ) {
    self.sha256 = sha256
    self.sizeBytes = sizeBytes
    self.deviceID = deviceID
    self.inode = inode
    self.modificationTimeSeconds = modificationTimeSeconds
    self.modificationTimeNanoseconds = modificationTimeNanoseconds
  }
}

public enum SourceFamilyShape: String, Codable, Equatable, Sendable {
  case moneyManagerAndroidV19 = "money-manager-android-v19-family-shape"
  case moneyManagerIOSV19 = "money-manager-ios-v19-family-shape"
  case moneyManagerMacV19 = "money-manager-macos-v19-family-shape"
}

public struct SourceProfile: Codable, Equatable, Sendable {
  public let identifier: String
  public let applicationID: Int32
  public let userVersion: Int32
  /// Exact schema fingerprint. Empty for family-shape matches, which are not schema cells.
  public let schemaSHA256: String
  public let familyShape: SourceFamilyShape?

  public var isExactSchemaCell: Bool { familyShape == nil }

  public init(
    identifier: String,
    applicationID: Int32,
    userVersion: Int32,
    schemaSHA256: String,
    familyShape: SourceFamilyShape? = nil
  ) {
    self.identifier = identifier
    self.applicationID = applicationID
    self.userVersion = userVersion
    self.schemaSHA256 = familyShape == nil ? schemaSHA256 : ""
    self.familyShape = familyShape
  }

  // Provenance: the read-only compatibility report for the supplied Android database and
  // byte-identical direct-.mmbak fixture. This is L0 identification of that exact profile only.
  public static let observedAndroidV19 = SourceProfile(
    identifier: "realbyte-android-sqlite-v19-observed",
    applicationID: 0,
    userVersion: 19,
    schemaSHA256: "79fb23a69fea59eb7bedcae22e84dd1019b78fb1f1caee0729c147b8732d11e6"
  )

  /// Synthetic four-table text fixture used for the positive import journey. It is intentionally
  /// distinct from the observed 20-table Android v19 profile above.
  public static let syntheticMoneyManagerV19TextSubset = SourceProfile(
    identifier: "realbyte-android-v19-synthetic-text-subset-v1",
    applicationID: 0,
    userVersion: 19,
    schemaSHA256: "37fecd8cd6e13ebc221320ea2bf5d542e5e711923ae36b04b75e4cc8081c06a3"
  )

  /// Inferred Android v19 family. Not a named schema cell and not a lossless certificate.
  public static let moneyManagerAndroidV19Family = SourceProfile(
    identifier: "realbyte-android-sqlite-v19-family",
    applicationID: 0,
    userVersion: 19,
    schemaSHA256: "",
    familyShape: .moneyManagerAndroidV19
  )

  /// Inferred iOS v19 family. Not a named schema cell and not a lossless certificate.
  public static let moneyManagerIOSV19Family = SourceProfile(
    identifier: "realbyte-ios-sqlite-v19-family",
    applicationID: 0,
    userVersion: 19,
    schemaSHA256: "",
    familyShape: .moneyManagerIOSV19
  )

  /// Inferred Mac v19 family. Not a named schema cell and not a lossless certificate.
  public static let moneyManagerMacV19Family = SourceProfile(
    identifier: "realbyte-macos-sqlite-v19-family",
    applicationID: 0,
    userVersion: 19,
    schemaSHA256: "",
    familyShape: .moneyManagerMacV19
  )

  public static var moneyManagerImportProfiles: [SourceProfile] {
    [
      .observedAndroidV19, .syntheticMoneyManagerV19TextSubset,
      .moneyManagerAndroidV19Family, .moneyManagerIOSV19Family, .moneyManagerMacV19Family,
    ]
  }
}

public enum ClassificationStatus: String, Codable, Sendable {
  case supported
  case familyMatch = "family_match"
  case unsupported
  case unavailable
  case incomplete
  case corrupt

  public var admitsImportPreparation: Bool {
    switch self {
    case .supported, .familyMatch: true
    case .unsupported, .unavailable, .incomplete, .corrupt: false
    }
  }
}

public enum ClassificationDiagnostic: String, Codable, Error, Sendable {
  case fileNotFound = "file_not_found"
  case fileUnreadable = "file_unreadable"
  case sourceSymlink = "source_symlink"
  case sourceNotRegular = "source_not_regular_file"
  case unsupportedContainer = "unsupported_container"
  case truncatedInput = "truncated_input"
  case invalidSQLite = "invalid_or_corrupt_sqlite"
  case sourceChanged = "source_changed_during_inspection"
  case sqliteNotReadonly = "sqlite_not_readonly"
  case integrityFailed = "integrity_check_failed"
  case companionFiles = "sqlite_companion_files_present"
  case archivedCompanionFiles = "archived_sqlite_companion_files_present"
  case unknownProfile = "unknown_source_profile"
  case schemaDrift = "schema_drift"
  case unknownSchema = "unknown_schema_fingerprint"
  case malformedZIP = "malformed_zip"
  case unsupportedZIP64 = "unsupported_zip64"
  case encryptedZIP = "encrypted_zip"
  case multidiskZIP = "multidisk_zip"
  case unsafeZIPPath = "unsafe_zip_path"
  case duplicateZIPName = "duplicate_zip_name"
  case symlinkZIPEntry = "symlink_zip_entry"
  case unsupportedZIPCompression = "unsupported_zip_compression"
  case unsupportedZIPDataDescriptor = "unsupported_zip_data_descriptor"
  case zipStructureOverlap = "zip_structure_overlap"
  case zipBoundsExceeded = "zip_bounds_exceeded"
  case zipCRCFailed = "zip_crc_failed"
  case duplicateSQLiteCandidates = "duplicate_sqlite_candidates"
  case noSQLiteCandidate = "no_sqlite_candidate"
  /// ZIP members are structurally validated, but SQLite inspection is disabled until it can
  /// remain descriptor/in-memory read-only without materializing a writable source copy.
  case zipSQLiteInspectionUnavailable = "zip_sqlite_inspection_unavailable"
  case familyProfileMatch = "family_profile_match"
}

public struct SourceMetadata: Codable, Equatable, Sendable {
  public let applicationID: Int32
  public let userVersion: Int32
  public let pageSize: Int32
  public let encoding: String
  public let schemaSHA256: String
  public let tableCount: Int
  public let indexCount: Int
  public let structuralCoverage: SourceStructuralCoverage?

  public init(
    applicationID: Int32,
    userVersion: Int32,
    pageSize: Int32,
    encoding: String,
    schemaSHA256: String,
    tableCount: Int,
    indexCount: Int,
    structuralCoverage: SourceStructuralCoverage? = nil
  ) {
    self.applicationID = applicationID
    self.userVersion = userVersion
    self.pageSize = pageSize
    self.encoding = encoding
    self.schemaSHA256 = schemaSHA256
    self.tableCount = tableCount
    self.indexCount = indexCount
    self.structuralCoverage = structuralCoverage
  }
}

/// Aggregate-only cell shape counts. It deliberately contains no table, field, or value names.
public struct SourceStructuralCoverage: Codable, Equatable, Sendable {
  public let recordCount: UInt64
  public let fieldCount: UInt64
  public let nullCount: UInt64
  public let integerCount: UInt64
  public let realCount: UInt64
  public let textCount: UInt64
  public let blobCount: UInt64

  public init(
    recordCount: UInt64, fieldCount: UInt64, nullCount: UInt64, integerCount: UInt64,
    realCount: UInt64, textCount: UInt64, blobCount: UInt64
  ) {
    self.recordCount = recordCount
    self.fieldCount = fieldCount
    self.nullCount = nullCount
    self.integerCount = integerCount
    self.realCount = realCount
    self.textCount = textCount
    self.blobCount = blobCount
  }
}

public struct ClassificationResult: Codable, Equatable, Sendable {
  public let container: SourceContainer
  public let fingerprintBefore: SourceFingerprint?
  public let fingerprintAfter: SourceFingerprint?
  public let status: ClassificationStatus
  public let profile: SourceProfile?
  public let metadata: SourceMetadata?
  public let diagnostics: [ClassificationDiagnostic]

  public init(
    container: SourceContainer,
    fingerprintBefore: SourceFingerprint?,
    fingerprintAfter: SourceFingerprint?,
    status: ClassificationStatus,
    profile: SourceProfile? = nil,
    metadata: SourceMetadata? = nil,
    diagnostics: [ClassificationDiagnostic]
  ) {
    self.container = container
    self.fingerprintBefore = fingerprintBefore
    self.fingerprintAfter = fingerprintAfter
    self.status = status
    self.profile = profile
    self.metadata = metadata
    self.diagnostics = diagnostics
  }
}

public struct ZIPInspectionLimits: Equatable, Sendable {
  public let maximumArchiveBytes: Int
  public let maximumEntries: Int
  public let maximumTotalUncompressedBytes: Int
  public let maximumMemberBytes: Int
  public let maximumCompressionRatio: Double

  public init(
    maximumArchiveBytes: Int = 512 * 1_024 * 1_024,
    maximumEntries: Int = 1_024,
    maximumTotalUncompressedBytes: Int = 512 * 1_024 * 1_024,
    maximumMemberBytes: Int = 256 * 1_024 * 1_024,
    maximumCompressionRatio: Double = 200
  ) throws {
    guard maximumArchiveBytes > 0, maximumEntries > 0,
      maximumTotalUncompressedBytes > 0, maximumMemberBytes > 0,
      maximumCompressionRatio.isFinite, maximumCompressionRatio > 0
    else { throw ZIPLimitError.invalidLimit }
    self.maximumArchiveBytes = maximumArchiveBytes
    self.maximumEntries = maximumEntries
    self.maximumTotalUncompressedBytes = maximumTotalUncompressedBytes
    self.maximumMemberBytes = maximumMemberBytes
    self.maximumCompressionRatio = maximumCompressionRatio
  }

  public static var `default`: ZIPInspectionLimits {
    ZIPInspectionLimits(
      maximumArchiveBytes: 512 * 1_024 * 1_024,
      maximumEntries: 1_024,
      maximumTotalUncompressedBytes: 512 * 1_024 * 1_024,
      maximumMemberBytes: 256 * 1_024 * 1_024,
      maximumCompressionRatio: 200,
      unchecked: true)
  }

  private init(
    maximumArchiveBytes: Int,
    maximumEntries: Int,
    maximumTotalUncompressedBytes: Int,
    maximumMemberBytes: Int,
    maximumCompressionRatio: Double,
    unchecked: Bool
  ) {
    _ = unchecked
    self.maximumArchiveBytes = maximumArchiveBytes
    self.maximumEntries = maximumEntries
    self.maximumTotalUncompressedBytes = maximumTotalUncompressedBytes
    self.maximumMemberBytes = maximumMemberBytes
    self.maximumCompressionRatio = maximumCompressionRatio
  }
}

public enum ZIPLimitError: Error { case invalidLimit }
