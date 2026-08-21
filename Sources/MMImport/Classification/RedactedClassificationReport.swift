import Foundation

public struct RedactedClassificationReport: Codable, Equatable, Sendable {
  public let reportVersion: Int
  public let container: String
  public let status: String
  public let sourceSHA256Before: String?
  public let sourceSHA256After: String?
  public let sourceSizeBytes: UInt64?
  public let profile: String?
  public let applicationID: Int32?
  public let userVersion: Int32?
  public let pageSize: Int32?
  public let encoding: String?
  public let schemaSHA256: String?
  public let tableCount: Int?
  public let indexCount: Int?
  public let recordCount: UInt64?
  public let fieldCount: UInt64?
  public let nullCount: UInt64?
  public let integerCount: UInt64?
  public let realCount: UInt64?
  public let textCount: UInt64?
  public let blobCount: UInt64?
  public let diagnosticCodes: [String]

  public init(_ result: ClassificationResult) {
    reportVersion = 2
    container = result.container.rawValue
    status = result.status.rawValue
    sourceSHA256Before = result.fingerprintBefore?.sha256
    sourceSHA256After = result.fingerprintAfter?.sha256
    sourceSizeBytes = result.fingerprintBefore?.sizeBytes
    profile = result.profile?.identifier
    applicationID = result.metadata?.applicationID
    userVersion = result.metadata?.userVersion
    pageSize = result.metadata?.pageSize
    encoding = result.metadata?.encoding
    schemaSHA256 = result.metadata?.schemaSHA256
    tableCount = result.metadata?.tableCount
    indexCount = result.metadata?.indexCount
    recordCount = result.metadata?.structuralCoverage?.recordCount
    fieldCount = result.metadata?.structuralCoverage?.fieldCount
    nullCount = result.metadata?.structuralCoverage?.nullCount
    integerCount = result.metadata?.structuralCoverage?.integerCount
    realCount = result.metadata?.structuralCoverage?.realCount
    textCount = result.metadata?.structuralCoverage?.textCount
    blobCount = result.metadata?.structuralCoverage?.blobCount
    diagnosticCodes = result.diagnostics.map(\.rawValue)
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  public var humanDescription: String {
    let diagnostics = diagnosticCodes.isEmpty ? "none" : diagnosticCodes.joined(separator: ",")
    return [
      "container=\(container)",
      "status=\(status)",
      "profile=\(profile ?? "none")",
      "source_sha256=\(sourceSHA256Before ?? "unavailable")",
      "schema_sha256=\(schemaSHA256 ?? "unavailable")",
      "tables=\(tableCount.map(String.init) ?? "unavailable")",
      "indexes=\(indexCount.map(String.init) ?? "unavailable")",
      "diagnostics=\(diagnostics)",
    ].joined(separator: "\n")
  }
}

extension ClassificationResult {
  public var suggestedExitCode: Int32 {
    switch status {
    case .supported, .familyMatch: 0
    case .unsupported:
      diagnostics.contains(.unknownSchema) || diagnostics.contains(.unknownProfile)
        || diagnostics.contains(.schemaDrift) ? 3 : 2
    case .unavailable: diagnostics.contains(.fileNotFound) ? 2 : 4
    case .incomplete, .corrupt: 4
    }
  }
}
