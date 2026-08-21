import CryptoKit
import Foundation

public enum ReconciliationSubjectKind: String, Codable, CaseIterable, Equatable, Sendable {
  case artifact
  case table
  case record
  case field

  var sortOrdinal: Int {
    switch self {
    case .artifact: 0
    case .table: 1
    case .record: 2
    case .field: 3
    }
  }
}

public enum ReconciliationDisposition: String, Codable, Equatable, Sendable {
  case mapped
  case preserved
  case excluded
  case blocked
}

/// Closed, content-free diagnostics emitted by reconciliation version 1.
public enum ReconciliationReasonCode: String, Codable, CaseIterable, Equatable, Sendable {
  case immutableSourceProvenance = "immutable_source_provenance"
  case knownTableAdapter = "known_table_adapter"
  case knownRecordAdapter = "known_record_adapter"
  case knownFieldAdapter = "known_field_adapter"
  case mappedByAdapter = "mapped_by_adapter"
  case tombstonePreserved = "tombstone_preserved"
  case opaqueSidecarPreserved = "opaque_sidecar_preserved"
  case adapterMetadataTable = "adapter_metadata_table"
  case intentionallyExcluded = "intentionally_excluded"
  case duplicateSubjectID = "duplicate_subject_id"
  case orphanSubject = "orphan_subject"
  case countMismatch = "count_mismatch"
  case duplicateDecision = "duplicate_decision"
  case missingDecisionEvidence = "missing_decision_evidence"
  case invalidDecisionEvidence = "invalid_decision_evidence"
  case invalidReasonCode = "invalid_reason_code"
  case missingMapping = "missing_mapping"
  case unknownSubject = "unknown_subject"
  case unresolvedTransactionType = "unresolved_transaction_type"
  case transferDirectionUnproven = "transfer_direction_unproven"
  case unresolvedCategory = "unresolved_category"
  case unresolvedSourceBinding = "unresolved_source_binding"
}

/// A proof over concrete canonical or sidecar targets. Only MMImport producers can construct it.
struct TargetBoundReconciliationProof: Equatable, Sendable {
  let stageDigest: String
  let subjectID: String
  let kind: ReconciliationSubjectKind
  let disposition: ReconciliationDisposition
  let token: String

  init(
    stageDigest: String,
    subjectID: String,
    kind: ReconciliationSubjectKind,
    disposition: ReconciliationDisposition,
    targetComponents: [String]
  ) {
    self.stageDigest = stageDigest
    self.subjectID = subjectID
    self.kind = kind
    self.disposition = disposition
    var hasher = SHA256()
    for component in [
      "ledger-atlas/trusted-commit-mapping/v1", stageDigest, subjectID, kind.rawValue,
      disposition.rawValue,
    ] + targetComponents.sorted() {
      let data = Data(component.utf8)
      var length = UInt64(data.count).bigEndian
      withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
      hasher.update(data: data)
    }
    token = hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// Opaque evidence produced by MMImport after a target has been substantively bound.
///
/// Public callers may carry this value in a decision, but cannot construct it or inject a proof
/// token. Internal producers derive the target proof from canonical commit targets, preserved
/// sidecars, or an approved exclusion before creating this value.
public struct ReconciliationEvidence: Equatable, Sendable {
  private let stageDigest: String
  private let subjectID: String
  private let kind: ReconciliationSubjectKind
  private let disposition: ReconciliationDisposition
  private let targetProof: TargetBoundReconciliationProof

  private init(
    stageDigest: String,
    subjectID: String,
    kind: ReconciliationSubjectKind,
    disposition: ReconciliationDisposition,
    targetProof: TargetBoundReconciliationProof
  ) {
    self.stageDigest = stageDigest
    self.subjectID = subjectID
    self.kind = kind
    self.disposition = disposition
    self.targetProof = targetProof
  }

  static func canonicalMapping(
    _ proof: TargetBoundReconciliationProof
  ) -> ReconciliationEvidence? {
    make(proof, expectedDisposition: .mapped)
  }

  static func opaquePreservation(
    _ proof: TargetBoundReconciliationProof
  ) -> ReconciliationEvidence? {
    make(proof, expectedDisposition: .preserved)
  }

  static func intentionalExclusion(
    _ proof: TargetBoundReconciliationProof
  ) -> ReconciliationEvidence? {
    make(proof, expectedDisposition: .excluded)
  }

  private static func make(
    _ proof: TargetBoundReconciliationProof,
    expectedDisposition: ReconciliationDisposition
  ) -> ReconciliationEvidence? {
    guard proof.disposition == expectedDisposition else { return nil }
    return ReconciliationEvidence(
      stageDigest: proof.stageDigest, subjectID: proof.subjectID, kind: proof.kind,
      disposition: proof.disposition, targetProof: proof)
  }

  func bindingToken(
    expectedStageDigest: String,
    expectedSubjectID: String,
    expectedKind: ReconciliationSubjectKind,
    expectedDisposition: ReconciliationDisposition
  ) -> String? {
    guard stageDigest == expectedStageDigest,
      subjectID == expectedSubjectID,
      kind == expectedKind,
      disposition == expectedDisposition,
      Self.isCanonicalToken(stageDigest),
      Self.isCanonicalToken(subjectID),
      Self.isCanonicalToken(targetProof.token)
    else { return nil }

    var hasher = SHA256()
    for component in [
      "ledger-atlas/reconciliation-evidence/v1", stageDigest, subjectID,
      kind.rawValue, disposition.rawValue, targetProof.token,
    ] {
      let data = Data(component.utf8)
      var length = UInt64(data.count).bigEndian
      withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  var targetProofToken: String { targetProof.token }

  private static func isCanonicalToken(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }
}

public struct ReconciliationDecision: Equatable, Sendable {
  public let subjectID: String
  public let kind: ReconciliationSubjectKind
  public let disposition: ReconciliationDisposition
  public let reasonCode: ReconciliationReasonCode
  public let evidence: ReconciliationEvidence?

  public init(
    subjectID: String,
    kind: ReconciliationSubjectKind,
    disposition: ReconciliationDisposition,
    reasonCode: String,
    evidence: ReconciliationEvidence? = nil
  ) {
    self.subjectID = subjectID
    self.kind = kind
    self.disposition = disposition
    self.reasonCode = ReconciliationReasonCode(rawValue: reasonCode) ?? .invalidReasonCode
    self.evidence = evidence
  }

  public init(
    subjectID: String,
    kind: ReconciliationSubjectKind,
    disposition: ReconciliationDisposition,
    reasonCode: ReconciliationReasonCode,
    evidence: ReconciliationEvidence? = nil
  ) {
    self.subjectID = subjectID
    self.kind = kind
    self.disposition = disposition
    self.reasonCode = reasonCode
    self.evidence = evidence
  }
}

public struct ReconciliationEntry: Encodable, Equatable, Sendable {
  public let kind: ReconciliationSubjectKind
  public let subjectToken: String
  public let parentToken: String?
  public let disposition: ReconciliationDisposition
  public let reasonCode: ReconciliationReasonCode
  public let evidenceToken: String?

}

public struct ReconciliationReport: Encodable, Equatable, Sendable {
  public let reportVersion: Int
  public let reportHash: String
  public let entries: [ReconciliationEntry]
  public let artifactCount: Int
  public let tableCount: Int
  public let recordCount: Int
  public let fieldCount: Int
  public let mappedCount: Int
  public let preservedCount: Int
  public let excludedCount: Int
  public let blockingCount: Int

  init(entries: [ReconciliationEntry]) {
    reportVersion = 1
    self.entries = entries
    artifactCount = entries.count { $0.kind == .artifact }
    tableCount = entries.count { $0.kind == .table }
    recordCount = entries.count { $0.kind == .record }
    fieldCount = entries.count { $0.kind == .field }
    mappedCount = entries.count { $0.disposition == .mapped }
    preservedCount = entries.count { $0.disposition == .preserved }
    excludedCount = entries.count { $0.disposition == .excluded }
    blockingCount = entries.count { $0.disposition == .blocked }
    reportHash = Self.hash(entries: entries)
  }

  public func requireZeroLoss() throws -> ReconciliationReport {
    guard blockingCount == 0 else { throw ReconciliationError.expectZeroLossFailed }
    return self
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  public var humanDescription: String {
    [
      "status=\(blockingCount == 0 ? "reconciled" : "blocked")",
      "report_hash=\(reportHash)",
      "artifacts=\(artifactCount)",
      "tables=\(tableCount)",
      "records=\(recordCount)",
      "fields=\(fieldCount)",
      "mapped=\(mappedCount)",
      "preserved=\(preservedCount)",
      "excluded=\(excludedCount)",
      "blocked=\(blockingCount)",
    ].joined(separator: "\n")
  }

  private static func hash(entries: [ReconciliationEntry]) -> String {
    var hasher = SHA256()
    update(&hasher, Data("ledger-atlas/reconciliation-report/v1".utf8))
    for entry in entries {
      update(&hasher, Data(entry.kind.rawValue.utf8))
      update(&hasher, Data(entry.subjectToken.utf8))
      update(&hasher, Data((entry.parentToken ?? "").utf8))
      update(&hasher, Data(entry.disposition.rawValue.utf8))
      update(&hasher, Data(entry.reasonCode.rawValue.utf8))
      update(&hasher, Data((entry.evidenceToken ?? "").utf8))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func update(_ hasher: inout SHA256, _ data: Data) {
    var length = UInt64(data.count).bigEndian
    withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
    hasher.update(data: data)
  }
}

public enum ReconciliationError: String, Error, Equatable, Sendable {
  case invalidStagingDatabase = "invalid_staging_database"
  case invalidDecision = "invalid_reconciliation_decision"
  case stagingReadFailed = "staging_read_failed"
  case expectZeroLossFailed = "expect_zero_loss_failed"
}
