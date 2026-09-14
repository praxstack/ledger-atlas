public struct SourceLocator: Codable, Equatable, Hashable, Sendable {
  public let containerMember: String?
  public let table: String
  public let recordKey: String
  public let columnOrdinal: Int?
  public let columnName: String?

  public init(
    containerMember: String? = nil,
    table: String,
    recordKey: String,
    columnOrdinal: Int? = nil,
    columnName: String? = nil
  ) {
    self.containerMember = containerMember
    self.table = table
    self.recordKey = recordKey
    self.columnOrdinal = columnOrdinal
    self.columnName = columnName
  }
}

public struct FieldProvenance: Codable, Equatable, Hashable, Sendable {
  public let artifactSHA256: String
  public let profileID: String
  public let adapterVersion: String
  public let locator: SourceLocator
  public let deterministicID: String

  public init(
    artifactSHA256: String,
    profileID: String,
    adapterVersion: String,
    locator: SourceLocator,
    deterministicID: String
  ) {
    self.artifactSHA256 = artifactSHA256
    self.profileID = profileID
    self.adapterVersion = adapterVersion
    self.locator = locator
    self.deterministicID = deterministicID
  }
}
