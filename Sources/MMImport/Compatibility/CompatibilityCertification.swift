import Foundation
import LedgerCore

public enum CompatibilityLevel: String, Codable, CaseIterable, Sendable {
  case l0Identification = "L0"
  case l1ReadOnlyClassification = "L1"
  case l2LosslessStaging = "L2"
  case l3DeterministicMapping = "L3"
  case l4CanonicalRoundTrip = "L4"
  case l5BehavioralParity = "L5"

  public init(from decoder: Decoder) throws {
    do {
      let value = try decoder.singleValueContainer().decode(String.self)
      guard let level = Self(rawValue: value) else {
        throw CompatibilityCertificationError.invalidCompatibilityLevel
      }
      self = level
    } catch {
      throw CompatibilityCertificationError.invalidCompatibilityLevel
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum CompatibilityCertificationError: Error, Equatable, Sendable {
  case unsupportedVersion(kind: String, actual: Int)
  case emptyField(String)
  case fieldTooLong(String)
  case invalidSHA256(String)
  case invalidCompatibilityLevel
  case duplicateCell
  case emptyMatrix
  case invalidCoverage
  case insufficientEvidenceForLevel(CompatibilityLevel)
  case duplicateRegistryCell
  case invalidCoverageReceipt
  case invalidProfileBinding
  case unregisteredOracle
  case unregisteredFixture
  case unregisteredAdapter
  case unregisteredProfile
}

public enum CompatibilityCorpus {
  public static let oracles: Set<String> = [
    "oracle-v1", "synthetic-structural-oracle-v1", "oracle-observed-v19-pending",
    "oracle-synthetic-v19-text-subset", "synthetic-oracle-v1",
  ]
  public static let adapters: Set<String> = [
    "money-manager-android-v19-adapter-v1", "synthetic-adapter-v1",
  ]
  public static let locales: Set<String> = ["und", "en-US", "en-IN"]
  public static let currencies: Set<String> = ["XXX", "USD", "INR", "EUR"]
  public static let fixtures: Set<String> = [
    String(repeating: "b", count: 64),
    String(repeating: "c", count: 64),
    String(repeating: "d", count: 64),
    String(repeating: "e", count: 64),
  ]
  public static let profiles: Set<String> = [
    "realbyte-android-sqlite-v19-observed",
    "realbyte-android-v19-synthetic-text-subset-v1",
    "realbyte-android-sqlite-v19-family",
    "realbyte-ios-sqlite-v19-family",
    "realbyte-macos-sqlite-v19-family",
    "synthetic-profile",
    "synthetic-profile-v1",
    "first",
    "second",
  ]
}

/// The semantic areas that must be evidenced before a source profile can claim mapping or
/// round-trip compatibility. Absence means pending; it never means supported.
public enum CompatibilitySemantic: String, CaseIterable, Codable, Sendable {
  case timezoneDST
  case transfer3And4
  case type7
  case unknownTables
  case nonTextStorage
  case attachments
  case roundTrip
  case behavioralParity
}

public struct CompatibilityCertificationCoverage: Codable, Equatable, Sendable {
  public let discoveredSubjectCount: Int
  public let mappedSubjectCount: Int
  public let durablyPreservedSubjectCount: Int
  public let knownSemantics: Set<CompatibilitySemantic>

  public static let none = CompatibilityCertificationCoverage(
    discoveredSubjectCount: 0, mappedSubjectCount: 0, durablyPreservedSubjectCount: 0,
    knownSemantics: [])!

  public init?(
    discoveredSubjectCount: Int,
    mappedSubjectCount: Int,
    durablyPreservedSubjectCount: Int,
    knownSemantics: Set<CompatibilitySemantic>
  ) {
    guard discoveredSubjectCount >= 0, mappedSubjectCount >= 0,
      durablyPreservedSubjectCount >= 0, mappedSubjectCount <= discoveredSubjectCount,
      durablyPreservedSubjectCount <= discoveredSubjectCount
    else { return nil }
    self.discoveredSubjectCount = discoveredSubjectCount
    self.mappedSubjectCount = mappedSubjectCount
    self.durablyPreservedSubjectCount = durablyPreservedSubjectCount
    self.knownSemantics = knownSemantics
  }

  public func permits(_ level: CompatibilityLevel) -> Bool {
    // Classification aggregates are not a staging or mapping oracle. Only the
    // named identification level is publishable until receipt-backed transitions exist.
    level == .l0Identification
  }

  private enum CodingKeys: String, CodingKey {
    case discoveredSubjectCount, mappedSubjectCount, durablyPreservedSubjectCount, knownSemantics
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      let value = Self.init(
        discoveredSubjectCount: try container.decode(Int.self, forKey: .discoveredSubjectCount),
        mappedSubjectCount: try container.decode(Int.self, forKey: .mappedSubjectCount),
        durablyPreservedSubjectCount: try container.decode(
          Int.self, forKey: .durablyPreservedSubjectCount),
        knownSemantics: try container.decode(
          Set<CompatibilitySemantic>.self, forKey: .knownSemantics))
    else { throw CompatibilityCertificationError.invalidCoverage }
    self = value
  }
}

public struct CompatibilityCertificationCell: Codable, Equatable, Sendable {
  public let profileID: String
  public let certification: CompatibilityCertification
  public let coverage: CompatibilityCertificationCoverage

  public init(
    profileID: String, certification: CompatibilityCertification,
    coverage: CompatibilityCertificationCoverage
  ) throws {
    guard !profileID.isEmpty, profileID.utf8.count <= 256 else {
      throw CompatibilityCertificationError.emptyField("profileID")
    }
    if profileID == SourceProfile.observedAndroidV19.identifier {
      let profile = SourceProfile.observedAndroidV19
      guard certification.platform == "android", certification.container == "sqlite",
        certification.schemaFingerprint == profile.schemaSHA256
      else { throw CompatibilityCertificationError.invalidProfileBinding }
    }
    guard coverage.permits(certification.level) else {
      throw CompatibilityCertificationError.insufficientEvidenceForLevel(certification.level)
    }
    self.profileID = profileID
    self.certification = certification
    self.coverage = coverage
  }

  private enum CodingKeys: String, CodingKey { case profileID, certification, coverage }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      profileID: container.decode(String.self, forKey: .profileID),
      certification: container.decode(CompatibilityCertification.self, forKey: .certification),
      coverage: container.decode(CompatibilityCertificationCoverage.self, forKey: .coverage))
  }
}

public struct CompatibilityCertificationRegistry: Equatable, Sendable {
  public let cells: [CompatibilityCertificationCell]

  public init(cells: [CompatibilityCertificationCell]) throws {
    guard Set(cells.map { "\($0.profileID)\u{0}\($0.certification.cellKey)" }).count == cells.count
    else {
      throw CompatibilityCertificationError.duplicateRegistryCell
    }
    self.cells = cells.sorted { lhs, rhs in
      lhs.profileID == rhs.profileID
        ? lhs.certification.cellKey < rhs.certification.cellKey : lhs.profileID < rhs.profileID
    }
  }
}

/// A bounded, content-free receipt from an explicit read-only coverage run. It reports
/// structural L0 evidence only; it cannot be used to manufacture an L3+ claim.
public struct CompatibilityCoverageReceipt: Encodable, Equatable, Sendable {
  public static let version = 1

  public let receiptVersion: Int
  public let status: ClassificationStatus
  public let sourceSHA256: String
  public let profileID: String?
  public let schemaSHA256: String?
  public let tableCount: Int?
  public let indexCount: Int?
  public let structuralCoverage: SourceStructuralCoverage?
  public let diagnosticCodes: [ClassificationDiagnostic]

  public init(_ result: ClassificationResult) throws {
    guard let before = result.fingerprintBefore, let after = result.fingerprintAfter,
      before == after, CanonicalIdentifier.isValid(before.sha256)
    else { throw CompatibilityCertificationError.invalidCoverageReceipt }
    receiptVersion = Self.version
    status = result.status
    sourceSHA256 = before.sha256
    profileID = result.profile?.identifier
    schemaSHA256 = result.metadata?.schemaSHA256
    tableCount = result.metadata?.tableCount
    indexCount = result.metadata?.indexCount
    structuralCoverage = result.metadata?.structuralCoverage
    diagnosticCodes = result.diagnostics.sorted { $0.rawValue < $1.rawValue }
  }

}

/// A bounded, named compatibility claim. This value deliberately has no universal-compatibility
/// mode: a certification is always tied to one observed fixture/oracle cell.
public struct CompatibilityCertification: Codable, Equatable, Hashable, Sendable {
  public static let version = 1

  public let certificationVersion: Int
  public let platform: String
  public let appEdition: String
  public let appVersion: String
  public let appBuild: String
  public let container: String
  public let schemaFingerprint: String
  public let fixtureSHA256: String
  public let oracleID: String
  public let level: CompatibilityLevel

  public init(
    platform: String,
    appEdition: String,
    appVersion: String,
    appBuild: String,
    container: String,
    schemaFingerprint: String,
    fixtureSHA256: String,
    oracleID: String,
    level: CompatibilityLevel
  ) throws {
    for (name, value) in [
      ("platform", platform), ("appEdition", appEdition), ("appVersion", appVersion),
      ("appBuild", appBuild), ("container", container), ("oracleID", oracleID),
    ] {
      guard !value.isEmpty else { throw CompatibilityCertificationError.emptyField(name) }
      guard value.utf8.count <= 256 else {
        throw CompatibilityCertificationError.fieldTooLong(name)
      }
    }
    guard CanonicalIdentifier.isValid(schemaFingerprint) else {
      throw CompatibilityCertificationError.invalidSHA256("schemaFingerprint")
    }
    guard CanonicalIdentifier.isValid(fixtureSHA256) else {
      throw CompatibilityCertificationError.invalidSHA256("fixtureSHA256")
    }
    guard CompatibilityCorpus.oracles.contains(oracleID) else {
      throw CompatibilityCertificationError.unregisteredOracle
    }
    guard CompatibilityCorpus.fixtures.contains(fixtureSHA256) else {
      throw CompatibilityCertificationError.unregisteredFixture
    }
    certificationVersion = Self.version
    self.platform = platform
    self.appEdition = appEdition
    self.appVersion = appVersion
    self.appBuild = appBuild
    self.container = container
    self.schemaFingerprint = schemaFingerprint
    self.fixtureSHA256 = fixtureSHA256
    self.oracleID = oracleID
    self.level = level
  }

  public var cellKey: String {
    [
      platform, appEdition, appVersion, appBuild, container, schemaFingerprint, fixtureSHA256,
      oracleID,
    ].map { "\($0.utf8.count):\($0)" }.joined()
  }

  private enum CodingKeys: String, CodingKey {
    case certificationVersion
    case platform
    case appEdition
    case appVersion
    case appBuild
    case container
    case schemaFingerprint
    case fixtureSHA256
    case oracleID
    case level
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedVersion = try container.decode(Int.self, forKey: .certificationVersion)
    guard decodedVersion == Self.version else {
      throw CompatibilityCertificationError.unsupportedVersion(
        kind: "certification", actual: decodedVersion)
    }
    self = try Self.init(
      platform: container.decode(String.self, forKey: .platform),
      appEdition: container.decode(String.self, forKey: .appEdition),
      appVersion: container.decode(String.self, forKey: .appVersion),
      appBuild: container.decode(String.self, forKey: .appBuild),
      container: container.decode(String.self, forKey: .container),
      schemaFingerprint: container.decode(String.self, forKey: .schemaFingerprint),
      fixtureSHA256: container.decode(String.self, forKey: .fixtureSHA256),
      oracleID: container.decode(String.self, forKey: .oracleID),
      level: container.decode(CompatibilityLevel.self, forKey: .level))
  }
}

extension CompatibilityCertificationCell {
  /// This is a named pending cell, not a claim that the real v19 database can be mapped.
  public static func pendingObservedAndroidV19(
    fixtureSHA256: String, oracleID: String
  ) throws -> CompatibilityCertificationCell {
    let profile = SourceProfile.observedAndroidV19
    let certification = try CompatibilityCertification(
      platform: "android", appEdition: "pending", appVersion: "pending", appBuild: "pending",
      container: "sqlite", schemaFingerprint: profile.schemaSHA256,
      fixtureSHA256: fixtureSHA256, oracleID: oracleID, level: .l0Identification)
    return try CompatibilityCertificationCell(
      profileID: profile.identifier, certification: certification, coverage: .none)
  }
}

public struct CompatibilityMatrix: Codable, Equatable, Sendable {
  public static let version = 2

  public let matrixVersion: Int
  public let cells: [CompatibilityCertificationCell]

  public init(cells: [CompatibilityCertificationCell]) throws {
    guard !cells.isEmpty else { throw CompatibilityCertificationError.emptyMatrix }
    guard Set(cells.map(\.certification.cellKey)).count == cells.count
    else {
      throw CompatibilityCertificationError.duplicateCell
    }
    matrixVersion = Self.version
    self.cells = cells.sorted {
      $0.profileID == $1.profileID
        ? $0.certification.cellKey < $1.certification.cellKey : $0.profileID < $1.profileID
    }
  }

  public func cell(matching key: String) -> CompatibilityCertificationCell? {
    cells.first { $0.certification.cellKey == key }
  }

  private enum CodingKeys: String, CodingKey {
    case matrixVersion
    case cells
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedVersion = try container.decode(Int.self, forKey: .matrixVersion)
    guard decodedVersion == Self.version else {
      throw CompatibilityCertificationError.unsupportedVersion(
        kind: "matrix", actual: decodedVersion)
    }
    self = try Self.init(
      cells: container.decode([CompatibilityCertificationCell].self, forKey: .cells))
  }
}
