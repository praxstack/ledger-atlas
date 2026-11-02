import CSQLite
import CryptoKit
import Foundation
import LedgerCore

/// The two economic events of one transfer, stored as one row of `economic_event_transfer`.
public struct CanonicalTransferPair: Equatable, Sendable {
  public let transferID: String
  public let debitEventID: String
  public let creditEventID: String

  public init(transferID: String, debitEventID: String, creditEventID: String) {
    self.transferID = transferID
    self.debitEventID = debitEventID
    self.creditEventID = creditEventID
  }
}

public struct CanonicalCommitRequest: Sendable {
  public let canonicalDatabaseURL: URL
  public let stagingDatabaseURL: URL
  public let expectedManifest: StagingManifest
  public let expectedStagingDigest: String
  public let mappingDecisions: [ReconciliationDecision]
  public let events: [CanonicalEconomicEvent]
  public let transferPairs: [CanonicalTransferPair]
  let adapterAuthorization: CanonicalCommitAdapterAuthorization?

  public init(
    canonicalDatabaseURL: URL,
    stagingDatabaseURL: URL,
    expectedManifest: StagingManifest,
    expectedStagingDigest: String,
    mappingDecisions: [ReconciliationDecision],
    events: [CanonicalEconomicEvent]
  ) {
    self.canonicalDatabaseURL = canonicalDatabaseURL
    self.stagingDatabaseURL = stagingDatabaseURL
    self.expectedManifest = expectedManifest
    self.expectedStagingDigest = expectedStagingDigest
    self.mappingDecisions = mappingDecisions
    self.events = events
    transferPairs = []
    adapterAuthorization = nil
  }

  init(
    observedV19CanonicalDatabaseURL canonicalDatabaseURL: URL,
    stagingDatabaseURL: URL,
    expectedManifest: StagingManifest,
    expectedStagingDigest: String,
    mappingDecisions: [ReconciliationDecision],
    events: [CanonicalEconomicEvent],
    transferPairs: [CanonicalTransferPair] = [],
    receiptOwnedSubjectIDs: Set<String>,
    sourceTimeZone: SourceTimeZone? = nil
  ) {
    self.canonicalDatabaseURL = canonicalDatabaseURL
    self.stagingDatabaseURL = stagingDatabaseURL
    self.expectedManifest = expectedManifest
    self.expectedStagingDigest = expectedStagingDigest
    self.mappingDecisions = mappingDecisions
    self.events = events
    self.transferPairs = transferPairs
    adapterAuthorization = .observedV19(
      receiptOwnedSubjectIDs: receiptOwnedSubjectIDs, sourceTimeZone: sourceTimeZone)
  }

  var isObservedV19AdapterAuthorized: Bool {
    if case .observedV19? = adapterAuthorization { return true }
    return false
  }

  var observedV19ReceiptOwnedSubjectIDs: Set<String>? {
    guard case .observedV19(let receiptOwnedSubjectIDs, _)? = adapterAuthorization else {
      return nil
    }
    return receiptOwnedSubjectIDs
  }

  var observedV19SourceTimeZone: SourceTimeZone? {
    guard case .observedV19(_, let sourceTimeZone)? = adapterAuthorization else { return nil }
    return sourceTimeZone
  }

  var hasAdapterAuthorization: Bool { adapterAuthorization != nil }
}

enum CanonicalCommitAdapterAuthorization: Sendable {
  case observedV19(receiptOwnedSubjectIDs: Set<String>, sourceTimeZone: SourceTimeZone?)
}

public enum CanonicalCommitStatus: String, Codable, Equatable, Sendable {
  case committed
  case unchanged
}

/// Evidence created only by a successful canonical transaction. Public callers can inspect but
/// cannot construct this value; reconciliation can consume it inside MMImport without a cycle.
public struct CanonicalCommitProof: Equatable, Sendable {
  public let stageDigest: String
  public let sourceSubjectID: String
  public let targetEventID: String
  public let provenanceID: String
  public let proofToken: String

  init(
    stageDigest: String,
    sourceSubjectID: String,
    targetEventID: String,
    provenanceID: String
  ) {
    self.stageDigest = stageDigest
    self.sourceSubjectID = sourceSubjectID
    self.targetEventID = targetEventID
    self.provenanceID = provenanceID
    proofToken = CanonicalCommitDigest.hash([
      "ledger-atlas/canonical-commit-proof/v1", stageDigest, sourceSubjectID, targetEventID,
      provenanceID,
    ])
  }
}

public struct CanonicalCommitResult: Equatable, Sendable {
  public let status: CanonicalCommitStatus
  public let eventCount: Int
  public let canonicalChecksum: String
  public let reconciliationHash: String
  public let proofs: [CanonicalCommitProof]

  init(
    status: CanonicalCommitStatus,
    eventCount: Int,
    canonicalChecksum: String,
    reconciliationHash: String,
    proofs: [CanonicalCommitProof]
  ) {
    self.status = status
    self.eventCount = eventCount
    self.canonicalChecksum = canonicalChecksum
    self.reconciliationHash = reconciliationHash
    self.proofs = proofs
  }

  public var humanDescription: String {
    [
      "status=\(status.rawValue)",
      "events=\(eventCount)",
      "canonical_checksum=\(canonicalChecksum)",
      "reconciliation_hash=\(reconciliationHash)",
    ].joined(separator: "\n")
  }
}

public enum CanonicalCommitError: String, Error, Equatable, Sendable {
  case invalidRequest = "invalid_commit_request"
  case unauthenticatedStaging = "unauthenticated_staging"
  case unsafeMapping = "unsafe_mapping"
  case idempotencyConflict = "idempotency_conflict"
  case incompatibleCanonicalStore = "incompatible_canonical_store"
  case canonicalReadFailed = "canonical_read_failed"
  case canonicalWriteFailed = "canonical_write_failed"
  case injectedFailure = "injected_commit_failure"
}

enum CanonicalCommitDigest {
  static let maximumSidecarBytes = 64 * 1_024 * 1_024
  static let maximumTotalSidecarBytes = 512 * 1_024 * 1_024

  static func hash(_ components: [String]) -> String {
    CanonicalReceiptDigest.hash(components)
  }

  static func eventSet(
    _ events: [CanonicalEconomicEvent],
    sidecarsByEvent: [String: [CanonicalPersistedSidecar]]
  ) throws -> String {
    var components = [eventSetPrefix]
    for event in events.sorted(by: { $0.eventID < $1.eventID }) {
      components.append(
        contentsOf: eventSetComponents(
          event, sidecars: sidecarsByEvent[event.eventID, default: []]))
    }
    return hash(components)
  }

  static let eventSetPrefix = CanonicalReceiptDigest.eventSetPrefix

  static func optionalComponents(_ value: String?) -> [String] {
    CanonicalReceiptDigest.optionalComponents(value)
  }

  static func eventSetComponents(
    _ event: CanonicalEconomicEvent, sidecars: [CanonicalPersistedSidecar]
  ) -> [String] {
    let date = event.occurredAt.localDateTime.date
    let zoneKind = event.occurredAt.timeZone.ianaIdentifier == nil ? "fixed" : "iana"
    let zoneValue =
      event.occurredAt.timeZone.ianaIdentifier
      ?? String(event.occurredAt.timeZone.fixedOffsetSeconds ?? Int.min)
    var components = [
      event.eventID, event.accountID, event.kind.rawValue, event.amount.amount.rawLiteral,
      event.amount.unitCode, String(event.occurredAt.instant.epochMilliseconds),
      String(date.year), String(date.month), String(date.day),
      String(event.occurredAt.localDateTime.hour), String(event.occurredAt.localDateTime.minute),
      String(event.occurredAt.localDateTime.second),
      String(event.occurredAt.localDateTime.millisecond), zoneKind, zoneValue,
      event.occurredAt.precision.rawValue, String(event.occurredAt.resolvedOffsetSeconds),
      event.sourceRecordID, event.amountProvenance.deterministicID,
    ]
    for binding in event.sourceBindings.sorted(by: { $0.semantic.rawValue < $1.semantic.rawValue })
    {
      components.append(binding.semantic.rawValue)
      components.append(binding.provenance.deterministicID)
      components.append(contentsOf: optionalComponents(binding.declaredType))
      components.append(binding.storageClass.rawValue)
    }
    for sidecar in sidecars.sorted(by: { $0.sidecarID < $1.sidecarID }) {
      components.append(contentsOf: sidecarComponents(sidecar))
    }
    return components
  }

  static func sidecarComponents(_ sidecar: CanonicalPersistedSidecar) -> [String] {
    let locator = sidecar.provenance.locator
    let payloadHash = SHA256.hash(data: sidecar.payload).lowercaseHex
    var components = [
      sidecar.sidecarID, sidecar.provenance.deterministicID,
      String(sidecar.formatVersion),
    ]
    components.append(contentsOf: optionalComponents(sidecar.declaredType))
    components.append(contentsOf: [
      sidecar.storageClass.rawValue, payloadHash,
      sidecar.provenance.artifactSHA256, sidecar.provenance.profileID,
      sidecar.provenance.adapterVersion,
    ])
    components.append(contentsOf: optionalComponents(locator.containerMember))
    components.append(contentsOf: [locator.table, locator.recordKey])
    components.append(contentsOf: optionalComponents(locator.columnOrdinal.map(String.init)))
    components.append(contentsOf: optionalComponents(locator.columnName))
    return components
  }

  static func trustedMappingProof(
    stageDigest: String,
    subjectID: String,
    kind: ReconciliationSubjectKind,
    disposition: ReconciliationDisposition,
    targetComponents: [String]
  ) -> String {
    hash(
      [
        "ledger-atlas/trusted-commit-mapping/v1", stageDigest, subjectID, kind.rawValue,
        disposition.rawValue,
      ] + targetComponents.sorted())
  }
}

/// A SQL-only size/type pass over descriptor-bound staging input. This must run before any
/// staging digest or row reader asks SQLite for a text/blob pointer.
enum CanonicalStagingPreflight {
  static let maximumDatabaseBytes: Int64 = 1_073_741_824

  static func validate(
    database: OpaquePointer, descriptorSize: Int64, expected: StagingManifest
  ) -> Bool {
    let limits = StagingLimits.standard
    guard descriptorSize > 0, descriptorSize <= maximumDatabaseBytes,
      expected.formatVersion == 1,
      (0...limits.maximumTables).contains(expected.tableCount),
      (0...limits.maximumRecords).contains(expected.recordCount),
      (0...limits.maximumFields).contains(expected.fieldCount),
      (0...limits.maximumTotalBytes).contains(expected.opaqueByteCount),
      scalarInt64(database, "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'")
        == 6,
      scalarInt64(database, "SELECT count(*) FROM staging_meta") ?? -1 <= 16,
      scalarInt64(database, "SELECT count(*) FROM staged_artifact") == 1,
      scalarInt64(database, "SELECT count(*) FROM staging_manifest") == 1,
      scalarInt64(database, "SELECT count(*) FROM staged_table") == Int64(expected.tableCount),
      scalarInt64(database, "SELECT count(*) FROM staged_record") == Int64(expected.recordCount),
      scalarInt64(database, "SELECT count(*) FROM staged_field") == Int64(expected.fieldCount),
      queryHasNoRows(
        database,
        "SELECT 1 FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' AND (typeof(type)<>'text' OR typeof(name)<>'text' OR typeof(tbl_name)<>'text' OR typeof(sql)<>'text' OR length(CAST(type AS BLOB))>16 OR length(CAST(name AS BLOB))>128 OR length(CAST(tbl_name AS BLOB))>128 OR length(CAST(sql AS BLOB))>65536)"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM staging_meta WHERE typeof(key)<>'text' OR typeof(value)<>'text' OR length(CAST(key AS BLOB))<1 OR length(CAST(key AS BLOB))>128 OR length(CAST(value AS BLOB))>\(limits.maximumMetadataBytes)"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM staged_artifact WHERE typeof(artifact_id)<>'text' OR length(CAST(artifact_id AS BLOB))<>64 OR typeof(artifact_sha256)<>'text' OR length(CAST(artifact_sha256 AS BLOB))<>64 OR typeof(profile_id)<>'text' OR length(CAST(profile_id AS BLOB))<1 OR length(CAST(profile_id AS BLOB))>256 OR typeof(adapter_version)<>'text' OR length(CAST(adapter_version AS BLOB))<1 OR length(CAST(adapter_version AS BLOB))>256 OR typeof(source_size_bytes)<>'integer' OR source_size_bytes<0"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM staged_table WHERE typeof(table_id)<>'text' OR length(CAST(table_id AS BLOB))<>64 OR typeof(artifact_id)<>'text' OR length(CAST(artifact_id AS BLOB))<>64 OR typeof(ordinal)<>'integer' OR ordinal<0 OR ordinal>=\(limits.maximumTables) OR typeof(table_name)<>'text' OR length(CAST(table_name AS BLOB))<1 OR length(CAST(table_name AS BLOB))>1024 OR typeof(record_count)<>'integer' OR record_count<0 OR record_count>\(limits.maximumRecords)"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM staged_record WHERE typeof(record_id)<>'text' OR length(CAST(record_id AS BLOB))<>64 OR typeof(table_id)<>'text' OR length(CAST(table_id AS BLOB))<>64 OR typeof(record_key)<>'text' OR length(CAST(record_key AS BLOB))<1 OR length(CAST(record_key AS BLOB))>4096 OR typeof(field_count)<>'integer' OR field_count<0 OR field_count>\(limits.maximumFieldsPerRecord) OR typeof(opaque_byte_count)<>'integer' OR opaque_byte_count<0 OR opaque_byte_count>\(limits.maximumRecordBytes)"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM staged_field WHERE typeof(field_id)<>'text' OR length(CAST(field_id AS BLOB))<>64 OR typeof(record_id)<>'text' OR length(CAST(record_id AS BLOB))<>64 OR typeof(ordinal)<>'integer' OR ordinal<0 OR ordinal>=\(limits.maximumFieldsPerRecord) OR typeof(column_name)<>'text' OR length(CAST(column_name AS BLOB))<1 OR length(CAST(column_name AS BLOB))>1024 OR (declared_type IS NOT NULL AND (typeof(declared_type)<>'text' OR length(CAST(declared_type AS BLOB))>1024)) OR typeof(storage_class)<>'text' OR storage_class NOT IN ('null','integer','real','blob','text') OR typeof(payload)<>'blob' OR length(payload)>\(limits.maximumValueBytes) OR (storage_class='null' AND length(payload)<>0) OR (storage_class IN ('integer','real') AND length(payload)<>8) OR typeof(sidecar_version)<>'integer' OR sidecar_version<>1 OR (container_member IS NOT NULL AND (typeof(container_member)<>'text' OR length(CAST(container_member AS BLOB))>4096))"
      ),
      queryHasNoRows(
        database,
        "SELECT 1 FROM staging_manifest WHERE typeof(format_version)<>'integer' OR format_version<>1 OR typeof(staging_id)<>'text' OR length(CAST(staging_id AS BLOB))<>64 OR typeof(artifact_sha256)<>'text' OR length(CAST(artifact_sha256 AS BLOB))<>64 OR typeof(profile_id)<>'text' OR length(CAST(profile_id AS BLOB))<1 OR length(CAST(profile_id AS BLOB))>256 OR typeof(adapter_version)<>'text' OR length(CAST(adapter_version AS BLOB))<1 OR length(CAST(adapter_version AS BLOB))>256 OR typeof(table_count)<>'integer' OR table_count<0 OR table_count>\(limits.maximumTables) OR typeof(record_count)<>'integer' OR record_count<0 OR record_count>\(limits.maximumRecords) OR typeof(field_count)<>'integer' OR field_count<0 OR field_count>\(limits.maximumFields) OR typeof(opaque_byte_count)<>'integer' OR opaque_byte_count<0 OR opaque_byte_count>\(limits.maximumTotalBytes)"
      ),
      queryHasNoRows(
        database,
        """
        SELECT 1 WHERE
          EXISTS(SELECT 1 FROM staging_meta
                 WHERE instr(key,char(0))>0 OR instr(value,char(0))>0)
          OR EXISTS(SELECT 1 FROM staged_artifact
                    WHERE instr(artifact_id,char(0))>0 OR instr(artifact_sha256,char(0))>0
                      OR instr(profile_id,char(0))>0 OR instr(adapter_version,char(0))>0)
          OR EXISTS(SELECT 1 FROM staged_table
                    WHERE instr(table_id,char(0))>0 OR instr(artifact_id,char(0))>0
                      OR instr(table_name,char(0))>0)
          OR EXISTS(SELECT 1 FROM staged_record
                    WHERE instr(record_id,char(0))>0 OR instr(table_id,char(0))>0
                      OR instr(record_key,char(0))>0)
          OR EXISTS(SELECT 1 FROM staged_field
                    WHERE instr(field_id,char(0))>0 OR instr(record_id,char(0))>0
                      OR instr(column_name,char(0))>0
                      OR (declared_type IS NOT NULL AND instr(declared_type,char(0))>0)
                      OR instr(storage_class,char(0))>0
                      OR (container_member IS NOT NULL AND instr(container_member,char(0))>0))
          OR EXISTS(SELECT 1 FROM staging_manifest
                    WHERE instr(staging_id,char(0))>0 OR instr(artifact_sha256,char(0))>0
                      OR instr(profile_id,char(0))>0 OR instr(adapter_version,char(0))>0)
        """),
      queryHasNoRows(
        database,
        "SELECT 1 WHERE (SELECT total(length(payload)) FROM staged_field)>\(limits.maximumTotalBytes).0"
      ),
      scalarDouble(database, "SELECT total(length(payload)) FROM staged_field")
        == Double(expected.opaqueByteCount)
    else { return false }
    return true
  }

  private static func scalarInt64(_ database: OpaquePointer, _ sql: String) -> Int64? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_type(statement, 0) == SQLITE_INTEGER
    else { return nil }
    return sqlite3_column_int64(statement, 0)
  }

  private static func scalarDouble(_ database: OpaquePointer, _ sql: String) -> Double? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_type(statement, 0) == SQLITE_FLOAT
    else { return nil }
    return sqlite3_column_double(statement, 0)
  }

  private static func queryHasNoRows(_ database: OpaquePointer, _ sql: String) -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return false }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_DONE
  }
}
