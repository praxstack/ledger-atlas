import Foundation
import LedgerCore
import MMImport
import Testing

@Test func certificationRejectsUnregisteredOracleAndFixture() {
  #expect(throws: CompatibilityCertificationError.unregisteredOracle) {
    try CompatibilityCertification(
      platform: "android", appEdition: "observed", appVersion: "v19", appBuild: "synthetic",
      container: "sqlite", schemaFingerprint: String(repeating: "a", count: 64),
      fixtureSHA256: String(repeating: "b", count: 64), oracleID: "not-a-registered-oracle",
      level: .l0Identification)
  }
  #expect(throws: CompatibilityCertificationError.unregisteredFixture) {
    try CompatibilityCertification(
      platform: "android", appEdition: "observed", appVersion: "v19", appBuild: "synthetic",
      container: "sqlite", schemaFingerprint: String(repeating: "a", count: 64),
      fixtureSHA256: String(repeating: "a", count: 64), oracleID: "oracle-v1",
      level: .l0Identification)
  }
}

@Test func certificationRequiresNamedFixtureOracleAndLevel() throws {
  let certification = try CompatibilityCertification(
    platform: "android", appEdition: "observed", appVersion: "v19", appBuild: "synthetic",
    container: "sqlite", schemaFingerprint: String(repeating: "a", count: 64),
    fixtureSHA256: String(repeating: "b", count: 64), oracleID: "oracle-v1",
    level: .l1ReadOnlyClassification)
  #expect(certification.certificationVersion == 1)
  #expect(certification.level == .l1ReadOnlyClassification)
  #expect(certification.cellKey.contains("oracle-v1"))
}

@Test func certificationRejectsUniversalOrUnboundedClaims() throws {
  #expect(throws: CompatibilityCertificationError.self) {
    try CompatibilityCertification(
      platform: "", appEdition: "observed", appVersion: "v19", appBuild: "synthetic",
      container: "sqlite", schemaFingerprint: String(repeating: "a", count: 64),
      fixtureSHA256: String(repeating: "b", count: 64), oracleID: "oracle-v1",
      level: .l0Identification)
  }
  let certification = try CompatibilityCertification(
    platform: "android", appEdition: "observed", appVersion: "v19", appBuild: "synthetic",
    container: "sqlite", schemaFingerprint: String(repeating: "a", count: 64),
    fixtureSHA256: String(repeating: "b", count: 64), oracleID: "oracle-v1",
    level: .l0Identification)
  #expect(throws: CompatibilityCertificationError.self) {
    let cell = try CompatibilityCertificationCell(
      profileID: "synthetic-profile", certification: certification, coverage: .none)
    _ = try CompatibilityMatrix(cells: [cell, cell])
  }
}

@Test func certificationCellKeyUsesUnambiguousLengthFraming() throws {
  let common = (
    appVersion: "v19", appBuild: "synthetic", container: "sqlite",
    schemaFingerprint: String(repeating: "a", count: 64),
    fixtureSHA256: String(repeating: "b", count: 64), oracleID: "oracle-v1",
    level: CompatibilityLevel.l0Identification
  )
  let first = try CompatibilityCertification(
    platform: "android|tablet", appEdition: "observed", appVersion: common.appVersion,
    appBuild: common.appBuild, container: common.container,
    schemaFingerprint: common.schemaFingerprint, fixtureSHA256: common.fixtureSHA256,
    oracleID: common.oracleID, level: common.level)
  let second = try CompatibilityCertification(
    platform: "android", appEdition: "tablet|observed", appVersion: common.appVersion,
    appBuild: common.appBuild, container: common.container,
    schemaFingerprint: common.schemaFingerprint, fixtureSHA256: common.fixtureSHA256,
    oracleID: common.oracleID, level: common.level)

  #expect(first.cellKey != second.cellKey)
  let coverage = CompatibilityCertificationCoverage.none
  let firstCell = try CompatibilityCertificationCell(
    profileID: "first", certification: first, coverage: coverage)
  let secondCell = try CompatibilityCertificationCell(
    profileID: "second", certification: second, coverage: coverage)
  #expect(try CompatibilityMatrix(cells: [firstCell, secondCell]).cells.count == 2)
}

@Test func certificationDecodingEnforcesConstructorInvariants() throws {
  let validJSON = """
    {
      "certificationVersion": 1,
      "platform": "android",
      "appEdition": "observed",
      "appVersion": "v19",
      "appBuild": "synthetic",
      "container": "sqlite",
      "schemaFingerprint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "fixtureSHA256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "oracleID": "oracle-v1",
      "level": "L1"
    }
    """
  let decoder = JSONDecoder()
  let certification = try decoder.decode(
    CompatibilityCertification.self, from: Data(validJSON.utf8))
  #expect(certification.cellKey.contains("oracle-v1"))

  for hostileJSON in [
    validJSON.replacingOccurrences(
      of: "\"certificationVersion\": 1", with: "\"certificationVersion\": 2"),
    validJSON.replacingOccurrences(of: "\"platform\": \"android\"", with: "\"platform\": \"\""),
    validJSON.replacingOccurrences(
      of: "\"fixtureSHA256\": \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"",
      with: "\"fixtureSHA256\": \"not-a-digest\""),
    validJSON.replacingOccurrences(
      of: "\"oracleID\": \"oracle-v1\"",
      with: "\"oracleID\": \"" + String(repeating: "x", count: 257) + "\""),
  ] {
    #expect(throws: CompatibilityCertificationError.self) {
      try decoder.decode(CompatibilityCertification.self, from: Data(hostileJSON.utf8))
    }
  }

  let sentinel = "DO-NOT-LEAK-UNTRUSTED-LEVEL"
  let unsupportedLevel = validJSON.replacingOccurrences(
    of: "\"level\": \"L1\"", with: "\"level\": \"\(sentinel)\"")
  do {
    _ = try decoder.decode(CompatibilityCertification.self, from: Data(unsupportedLevel.utf8))
    Issue.record("Expected unsupported compatibility level to fail decoding")
  } catch {
    #expect((error as? CompatibilityCertificationError) == .invalidCompatibilityLevel)
    #expect(!String(describing: error).contains(sentinel))
  }

}

@Test func matrixDecodingEnforcesVersionUniquenessAndNonEmptyInvariant() throws {
  let cell = """
    {"profileID":"synthetic-profile","certification":{"certificationVersion":1,"platform":"android","appEdition":"observed","appVersion":"v19","appBuild":"synthetic","container":"sqlite","schemaFingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fixtureSHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","oracleID":"oracle-v1","level":"L0"},"coverage":{"discoveredSubjectCount":0,"mappedSubjectCount":0,"durablyPreservedSubjectCount":0,"knownSemantics":[]}}
    """
  let validJSON = """
    {"matrixVersion":2,"cells":[\(cell)]}
    """
  let decoder = JSONDecoder()
  let matrix = try decoder.decode(CompatibilityMatrix.self, from: Data(validJSON.utf8))
  #expect(matrix.cells.count == 1)

  for hostileJSON in [
    validJSON.replacingOccurrences(of: "\"matrixVersion\":2", with: "\"matrixVersion\":1"),
    "{\"matrixVersion\":2,\"cells\":[]}",
    "{\"matrixVersion\":2,\"cells\":[\(cell),\(cell)]}",
    validJSON.replacingOccurrences(of: "\"level\":\"L0\"", with: "\"level\":\"L1\""),
    validJSON.replacingOccurrences(
      of: "\"discoveredSubjectCount\":0", with: "\"discoveredSubjectCount\":-1"),
  ] {
    #expect(throws: CompatibilityCertificationError.self) {
      try decoder.decode(CompatibilityMatrix.self, from: Data(hostileJSON.utf8))
    }
  }

  let mismatchedObservedCell =
    cell
    .replacingOccurrences(
      of: "\"synthetic-profile\"", with: "\"realbyte-android-sqlite-v19-observed\""
    )
    .replacingOccurrences(
      of: String(repeating: "a", count: 64), with: String(repeating: "c", count: 64))
  #expect(throws: CompatibilityCertificationError.invalidProfileBinding) {
    try decoder.decode(
      CompatibilityMatrix.self,
      from: Data("{\"matrixVersion\":2,\"cells\":[\(mismatchedObservedCell)]}".utf8))
  }
}

@Test func pendingObservedV19CellIsDistinctAndCannotClaimMapping() throws {
  let pending = try CompatibilityCertificationCell.pendingObservedAndroidV19(
    fixtureSHA256: String(repeating: "c", count: 64), oracleID: "synthetic-structural-oracle-v1")
  #expect(pending.profileID == SourceProfile.observedAndroidV19.identifier)
  #expect(pending.profileID != MoneyManagerV19Adapter.observedProfileID)
  #expect(pending.certification.level == .l0Identification)
  #expect(pending.certification.appEdition == "pending")
  #expect(pending.certification.appVersion == "pending")
  #expect(pending.certification.appBuild == "pending")
  #expect(pending.coverage == .none)

  let attemptedL3 = try CompatibilityCertification(
    platform: "android", appEdition: "observed", appVersion: "v19", appBuild: "pending",
    container: "sqlite", schemaFingerprint: SourceProfile.observedAndroidV19.schemaSHA256,
    fixtureSHA256: String(repeating: "c", count: 64), oracleID: "synthetic-structural-oracle-v1",
    level: .l3DeterministicMapping)
  #expect(
    throws: CompatibilityCertificationError.insufficientEvidenceForLevel(.l3DeterministicMapping)
  ) {
    try CompatibilityCertificationCell(
      profileID: SourceProfile.observedAndroidV19.identifier, certification: attemptedL3,
      coverage: .none)
  }
}

@Test func selfDeclaredCoverageCannotSupportAnL3Cell() throws {
  let certification = try CompatibilityCertification(
    platform: "synthetic", appEdition: "test", appVersion: "v1", appBuild: "test",
    container: "sqlite", schemaFingerprint: String(repeating: "d", count: 64),
    fixtureSHA256: String(repeating: "e", count: 64), oracleID: "synthetic-oracle-v1",
    level: .l3DeterministicMapping)
  let coverage = try #require(
    CompatibilityCertificationCoverage(
      discoveredSubjectCount: 2, mappedSubjectCount: 2, durablyPreservedSubjectCount: 2,
      knownSemantics: Set(CompatibilitySemantic.allCases)))
  #expect(
    throws: CompatibilityCertificationError.insufficientEvidenceForLevel(.l3DeterministicMapping)
  ) {
    try CompatibilityCertificationCell(
      profileID: "synthetic-profile-v1", certification: certification, coverage: coverage)
  }
}

@Test func selfDeclaredCoverageCannotSupportAnL2Cell() throws {
  let certification = try CompatibilityCertification(
    platform: "synthetic", appEdition: "test", appVersion: "v1", appBuild: "test",
    container: "sqlite", schemaFingerprint: String(repeating: "d", count: 64),
    fixtureSHA256: String(repeating: "e", count: 64), oracleID: "synthetic-oracle-v1",
    level: .l2LosslessStaging)
  #expect(throws: CompatibilityCertificationError.insufficientEvidenceForLevel(.l2LosslessStaging))
  {
    try CompatibilityCertificationCell(
      profileID: "synthetic-profile-v1", certification: certification, coverage: .none)
  }
}

@Test func coverageReceiptRequiresAnUnchangedContentAddressedSource() throws {
  let fingerprint = SourceFingerprint(
    sha256: String(repeating: "f", count: 64), sizeBytes: 128, deviceID: 1, inode: 2,
    modificationTimeSeconds: 3, modificationTimeNanoseconds: 4)
  let valid = ClassificationResult(
    container: .sqlite, fingerprintBefore: fingerprint, fingerprintAfter: fingerprint,
    status: .supported, profile: .observedAndroidV19,
    metadata: SourceMetadata(
      applicationID: 0, userVersion: 19, pageSize: 4096, encoding: "UTF-8",
      schemaSHA256: SourceProfile.observedAndroidV19.schemaSHA256, tableCount: 20, indexCount: 4),
    diagnostics: [])
  let receipt = try CompatibilityCoverageReceipt(valid)
  #expect(receipt.sourceSHA256 == fingerprint.sha256)
  #expect(receipt.profileID == SourceProfile.observedAndroidV19.identifier)
  #expect(receipt.tableCount == 20)

  let changed = ClassificationResult(
    container: .sqlite, fingerprintBefore: fingerprint,
    fingerprintAfter: SourceFingerprint(
      sha256: fingerprint.sha256, sizeBytes: 129, deviceID: 1, inode: 2,
      modificationTimeSeconds: 3, modificationTimeNanoseconds: 4),
    status: .incomplete, diagnostics: [.sourceChanged])
  #expect(throws: CompatibilityCertificationError.invalidCoverageReceipt) {
    try CompatibilityCoverageReceipt(changed)
  }
}
