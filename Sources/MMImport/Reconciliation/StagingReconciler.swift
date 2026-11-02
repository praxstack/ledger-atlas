import CSQLite
import CryptoKit
import Darwin
import Foundation
import LedgerCore

public struct StagingReconciler: Sendable {
  private let testingAfterDatabaseOpen: (@Sendable () -> Void)?
  private let testingBeforeFinalIdentity: (@Sendable () -> Void)?

  public init() {
    testingAfterDatabaseOpen = nil
    testingBeforeFinalIdentity = nil
  }

  // Internal seams used only by synthetic pathname-race regressions.
  init(
    testingAfterDatabaseOpen: @escaping @Sendable () -> Void,
    testingBeforeFinalIdentity: @escaping @Sendable () -> Void
  ) {
    self.testingAfterDatabaseOpen = testingAfterDatabaseOpen
    self.testingBeforeFinalIdentity = testingBeforeFinalIdentity
  }

  public func reconcile(
    stagingDatabaseURL: URL,
    expectedManifest: StagingManifest,
    expectedContentDigest: String,
    decisions: [ReconciliationDecision]
  ) throws -> ReconciliationReport {
    guard decisions.count <= Self.maximumDecisionCount,
      decisions.allSatisfy({ Self.isCanonicalToken($0.subjectID) })
    else { throw ReconciliationError.invalidDecision }
    guard Self.isValidExpectation(expectedManifest, contentDigest: expectedContentDigest)
    else { throw ReconciliationError.invalidStagingDatabase }
    let descriptor = Darwin.open(
      stagingDatabaseURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw ReconciliationError.invalidStagingDatabase }
    defer { Darwin.close(descriptor) }
    var descriptorBefore = stat()
    var pathBefore = stat()
    guard fstat(descriptor, &descriptorBefore) == 0,
      lstat(stagingDatabaseURL.path, &pathBefore) == 0,
      Self.isAcceptableFile(descriptorBefore),
      Self.sameIdentity(descriptorBefore, pathBefore),
      Self.hasNoSQLiteCompanions(stagingDatabaseURL)
    else { throw ReconciliationError.invalidStagingDatabase }
    let sqliteDescriptor = dup(descriptor)
    guard sqliteDescriptor >= 0 else { throw ReconciliationError.invalidStagingDatabase }
    defer { Darwin.close(sqliteDescriptor) }
    var database: OpaquePointer?
    let uri = "file:/dev/fd/\(sqliteDescriptor)?mode=ro&immutable=1"
    let openResult = sqlite3_open_v2(
      uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
    guard openResult == SQLITE_OK, let database else {
      if database != nil { sqlite3_close(database) }
      throw ReconciliationError.invalidStagingDatabase
    }
    defer { sqlite3_close(database) }
    guard sqlite3_db_readonly(database, "main") == 1,
      scalarText(database, "PRAGMA quick_check") == "ok"
    else { throw ReconciliationError.invalidStagingDatabase }
    testingAfterDatabaseOpen?()

    let subjects = try readSubjects(
      database: database,
      expectedManifest: expectedManifest,
      expectedContentDigest: expectedContentDigest)
    testingBeforeFinalIdentity?()
    var descriptorAfter = stat()
    var pathAfter = stat()
    guard fstat(descriptor, &descriptorAfter) == 0,
      lstat(stagingDatabaseURL.path, &pathAfter) == 0,
      Self.sameIdentity(descriptorBefore, descriptorAfter),
      Self.sameIdentity(descriptorBefore, pathAfter),
      Self.hasNoSQLiteCompanions(stagingDatabaseURL)
    else { throw ReconciliationError.invalidStagingDatabase }
    let subjectCounts = Dictionary(grouping: subjects, by: \.key).mapValues(\.count)
    let subjectKeys = Set(subjects.map(\.key))
    let decisionGroups = Dictionary(grouping: decisions, by: DecisionKey.init)
    let idsByKind = Dictionary(
      grouping: subjects, by: \.kind
    ).mapValues { Set($0.map(\.rawID)) }
    var occurrences: [SubjectKey: Int] = [:]
    var entries: [ReconciliationEntry] = []

    for subject in subjects {
      let occurrence = occurrences[subject.key, default: 0]
      occurrences[subject.key] = occurrence + 1
      let dispositionReasonAndEvidence:
        (
          ReconciliationDisposition, ReconciliationReasonCode, String?
        )
      if subjectCounts[subject.key, default: 0] > 1 {
        dispositionReasonAndEvidence = (.blocked, .duplicateSubjectID, nil)
      } else if let parentID = subject.parentID,
        !idsByKind[subject.kind.parentKind, default: []].contains(parentID)
      {
        dispositionReasonAndEvidence = (.blocked, .orphanSubject, nil)
      } else if !subject.countMatches {
        dispositionReasonAndEvidence = (.blocked, .countMismatch, nil)
      } else {
        let matching = decisionGroups[DecisionKey(subject.key), default: []]
        if matching.count > 1 {
          dispositionReasonAndEvidence = (.blocked, .duplicateDecision, nil)
        } else if let decision = matching.first {
          if decision.reasonCode == .invalidReasonCode {
            dispositionReasonAndEvidence = (.blocked, .invalidReasonCode, nil)
          } else if decision.disposition == .blocked {
            dispositionReasonAndEvidence = (.blocked, decision.reasonCode, nil)
          } else if decision.evidence == nil {
            dispositionReasonAndEvidence = (.blocked, .missingDecisionEvidence, nil)
          } else if let evidenceToken = decision.evidence?.bindingToken(
            expectedStageDigest: expectedContentDigest,
            expectedSubjectID: subject.rawID,
            expectedKind: subject.kind,
            expectedDisposition: decision.disposition)
          {
            dispositionReasonAndEvidence = (
              decision.disposition, decision.reasonCode, evidenceToken
            )
          } else {
            dispositionReasonAndEvidence = (.blocked, .invalidDecisionEvidence, nil)
          }
        } else {
          dispositionReasonAndEvidence = (.blocked, .missingMapping, nil)
        }
      }
      entries.append(
        ReconciliationEntry(
          kind: subject.kind,
          subjectToken: Self.token(
            kind: subject.kind, rawID: subject.rawID, occurrence: occurrence),
          parentToken: subject.parentID.map {
            Self.token(kind: subject.kind.parentKind, rawID: $0, occurrence: 0)
          },
          disposition: dispositionReasonAndEvidence.0,
          reasonCode: dispositionReasonAndEvidence.1,
          evidenceToken: dispositionReasonAndEvidence.2))
    }

    for (key, groupedDecisions) in decisionGroups where !subjectKeys.contains(key.subjectKey) {
      for occurrence in groupedDecisions.indices {
        entries.append(
          ReconciliationEntry(
            kind: key.kind,
            subjectToken: Self.token(
              kind: key.kind, rawID: key.subjectID, occurrence: occurrence),
            parentToken: nil,
            disposition: .blocked,
            reasonCode: .unknownSubject,
            evidenceToken: nil))
      }
    }

    entries.sort {
      if $0.kind.sortOrdinal != $1.kind.sortOrdinal {
        return $0.kind.sortOrdinal < $1.kind.sortOrdinal
      }
      if $0.subjectToken != $1.subjectToken { return $0.subjectToken < $1.subjectToken }
      if $0.reasonCode != $1.reasonCode {
        return $0.reasonCode.rawValue < $1.reasonCode.rawValue
      }
      return ($0.parentToken ?? "") < ($1.parentToken ?? "")
    }
    return ReconciliationReport(entries: entries)
  }

  private func readSubjects(
    database: OpaquePointer,
    expectedManifest: StagingManifest,
    expectedContentDigest: String
  ) throws -> [RawSubject] {
    guard hasExactVersionOneSchema(database),
      hasValidVersionOneValues(database),
      manifestIsBound(database, expected: expectedManifest),
      let storedDigest = scalarText(
        database, "SELECT value FROM staging_meta WHERE key='content_digest'"),
      storedDigest == expectedContentDigest,
      (try? SQLiteStagingStore().contentDigest(database: database)) == expectedContentDigest,
      let subjectCount = scalarInt(
        database,
        "SELECT (SELECT count(*) FROM staged_artifact) + (SELECT count(*) FROM staged_table) + (SELECT count(*) FROM staged_record) + (SELECT count(*) FROM staged_field)"
      ),
      subjectCount >= 0, subjectCount <= Self.maximumSubjectCount
    else { throw ReconciliationError.invalidStagingDatabase }

    var subjects: [RawSubject] = []
    try appendRows(
      database,
      sql: """
        SELECT artifact.artifact_id, NULL,
          manifest.table_count = (SELECT count(*) FROM staged_table)
          AND manifest.record_count = (SELECT count(*) FROM staged_record)
          AND manifest.field_count = (SELECT count(*) FROM staged_field)
          AND manifest.opaque_byte_count = (
            SELECT coalesce(sum(length(payload)), 0) FROM staged_field
          )
          AND NOT EXISTS (
            SELECT 1 FROM staged_table
            WHERE ordinal < 0 OR ordinal >= manifest.table_count
          )
        FROM staged_artifact AS artifact
        JOIN staging_manifest AS manifest ON manifest.staging_id = artifact.artifact_id
        ORDER BY artifact.artifact_id, artifact.rowid
        """,
      kind: .artifact,
      to: &subjects)
    try appendRows(
      database,
      sql: """
        SELECT staged_table.table_id, staged_table.artifact_id,
          staged_table.record_count = (
            SELECT count(*) FROM staged_record
            WHERE staged_record.table_id = staged_table.table_id
          )
        FROM staged_table
        ORDER BY staged_table.table_id, staged_table.artifact_id, staged_table.rowid
        """,
      kind: .table,
      to: &subjects)
    try appendRows(
      database,
      sql: """
        SELECT staged_record.record_id, staged_record.table_id,
          staged_record.field_count = (
            SELECT count(*) FROM staged_field
            WHERE staged_field.record_id = staged_record.record_id
          )
          AND staged_record.opaque_byte_count = (
            SELECT coalesce(sum(length(payload)), 0) FROM staged_field
            WHERE staged_field.record_id = staged_record.record_id
          )
          AND NOT EXISTS (
            SELECT 1 FROM staged_field
            WHERE staged_field.record_id = staged_record.record_id
              AND (ordinal < 0 OR ordinal >= staged_record.field_count)
          )
        FROM staged_record
        ORDER BY staged_record.record_id, staged_record.table_id, staged_record.rowid
        """,
      kind: .record,
      to: &subjects)
    try appendRows(
      database,
      sql: """
        SELECT field_id, record_id, 1
        FROM staged_field
        ORDER BY field_id, record_id, rowid
        """,
      kind: .field,
      to: &subjects)
    return subjects
  }

  private func appendRows(
    _ database: OpaquePointer,
    sql: String,
    kind: ReconciliationSubjectKind,
    to subjects: inout [RawSubject]
  ) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw ReconciliationError.invalidStagingDatabase }
    defer { sqlite3_finalize(statement) }
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return }
      guard result == SQLITE_ROW else { throw ReconciliationError.stagingReadFailed }
      subjects.append(
        RawSubject(
          kind: kind,
          rawID: canonicalIdentifier(statement, column: 0),
          parentID: sqlite3_column_type(statement, 1) == SQLITE_NULL
            ? nil : canonicalIdentifier(statement, column: 1),
          countMatches: sqlite3_column_int64(statement, 2) == 1))
    }
  }

  private func canonicalIdentifier(_ statement: OpaquePointer, column: Int32) -> String {
    switch sqlite3_column_type(statement, column) {
    case SQLITE_TEXT:
      let count = Int(sqlite3_column_bytes(statement, column))
      guard count > 0, let bytes = sqlite3_column_text(statement, column) else { return "" }
      return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    case SQLITE_INTEGER:
      return "invalid-integer:\(sqlite3_column_int64(statement, column))"
    case SQLITE_FLOAT:
      return "invalid-real:\(sqlite3_column_double(statement, column).bitPattern)"
    case SQLITE_BLOB:
      let count = Int(sqlite3_column_bytes(statement, column))
      guard count > 0, let bytes = sqlite3_column_blob(statement, column) else {
        return "invalid-blob:"
      }
      return "invalid-blob:"
        + Data(bytes: bytes, count: count).lowercaseHex
    default:
      return "invalid-null"
    }
  }

  private func hasExactVersionOneSchema(_ database: OpaquePointer) -> Bool {
    let sql = """
      SELECT type, name, tbl_name, sql
      FROM sqlite_schema
      WHERE name NOT LIKE 'sqlite_%'
      ORDER BY type, name, tbl_name
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return false }
    defer { sqlite3_finalize(statement) }
    var actual: [String: String] = [:]
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW,
        let type = columnText(statement, 0),
        let name = columnText(statement, 1),
        let table = columnText(statement, 2),
        let definition = columnText(statement, 3),
        type == "table", name == table
      else { return false }
      actual[name] = Self.normalizedSQL(definition)
    }
    guard actual.count == Self.versionOneSchema.count else { return false }
    return Self.versionOneSchema.allSatisfy { name, definition in
      actual[name] == Self.normalizedSQL(definition)
    }
  }

  private func hasValidVersionOneValues(_ database: OpaquePointer) -> Bool {
    let invalidRowQueries = [
      "SELECT 1 FROM staging_meta WHERE typeof(key) != 'text' OR typeof(value) != 'text' LIMIT 1",
      "SELECT 1 FROM staged_artifact WHERE NOT (\(Self.canonicalSQL("artifact_id"))) OR NOT (\(Self.canonicalSQL("artifact_sha256"))) OR typeof(profile_id) != 'text' OR length(CAST(profile_id AS BLOB)) NOT BETWEEN 1 AND 256 OR typeof(adapter_version) != 'text' OR length(CAST(adapter_version AS BLOB)) NOT BETWEEN 1 AND 256 OR typeof(source_size_bytes) != 'integer' OR source_size_bytes < 0 LIMIT 1",
      "SELECT 1 FROM staged_table WHERE NOT (\(Self.canonicalSQL("table_id"))) OR NOT (\(Self.canonicalSQL("artifact_id"))) OR typeof(ordinal) != 'integer' OR ordinal < 0 OR typeof(table_name) != 'text' OR length(CAST(table_name AS BLOB)) = 0 OR typeof(record_count) != 'integer' OR record_count < 0 LIMIT 1",
      "SELECT 1 FROM staged_record WHERE NOT (\(Self.canonicalSQL("record_id"))) OR NOT (\(Self.canonicalSQL("table_id"))) OR typeof(record_key) != 'text' OR length(CAST(record_key AS BLOB)) = 0 OR typeof(field_count) != 'integer' OR field_count < 0 OR typeof(opaque_byte_count) != 'integer' OR opaque_byte_count < 0 LIMIT 1",
      "SELECT 1 FROM staged_field WHERE NOT (\(Self.canonicalSQL("field_id"))) OR NOT (\(Self.canonicalSQL("record_id"))) OR typeof(ordinal) != 'integer' OR ordinal < 0 OR typeof(column_name) != 'text' OR length(CAST(column_name AS BLOB)) = 0 OR (declared_type IS NOT NULL AND typeof(declared_type) != 'text') OR typeof(storage_class) != 'text' OR storage_class NOT IN ('null', 'integer', 'real', 'blob', 'text') OR typeof(payload) != 'blob' OR (storage_class = 'null' AND length(payload) != 0) OR (storage_class IN ('integer', 'real') AND length(payload) != 8) OR typeof(sidecar_version) != 'integer' OR sidecar_version != 1 OR (container_member IS NOT NULL AND typeof(container_member) != 'text') LIMIT 1",
      "SELECT 1 FROM staging_manifest WHERE typeof(format_version) != 'integer' OR format_version != 1 OR NOT (\(Self.canonicalSQL("staging_id"))) OR NOT (\(Self.canonicalSQL("artifact_sha256"))) OR typeof(profile_id) != 'text' OR length(CAST(profile_id AS BLOB)) NOT BETWEEN 1 AND 256 OR typeof(adapter_version) != 'text' OR length(CAST(adapter_version AS BLOB)) NOT BETWEEN 1 AND 256 OR typeof(table_count) != 'integer' OR table_count < 0 OR typeof(record_count) != 'integer' OR record_count < 0 OR typeof(field_count) != 'integer' OR field_count < 0 OR typeof(opaque_byte_count) != 'integer' OR opaque_byte_count < 0 LIMIT 1",
    ]
    guard invalidRowQueries.allSatisfy({ queryHasNoRows(database, $0) }),
      scalarInt(database, "SELECT count(*) FROM staging_meta") == 4,
      scalarInt(
        database,
        "SELECT count(*) FROM staging_meta WHERE key IN ('format_version', 'staging_id', 'limits_description', 'content_digest')"
      ) == 4,
      queryHasNoRows(database, "PRAGMA foreign_key_check")
    else { return false }
    return true
  }

  private func manifestIsBound(
    _ database: OpaquePointer,
    expected: StagingManifest
  ) -> Bool {
    let sql = """
      SELECT manifest.format_version, manifest.staging_id, manifest.artifact_sha256,
             manifest.profile_id, manifest.adapter_version, manifest.table_count,
             manifest.record_count, manifest.field_count, manifest.opaque_byte_count
      FROM staging_manifest AS manifest
      JOIN staged_artifact AS artifact ON artifact.artifact_id = manifest.staging_id
      WHERE manifest.format_version = 1
        AND manifest.artifact_sha256 = artifact.artifact_sha256
        AND manifest.profile_id = artifact.profile_id
        AND manifest.adapter_version = artifact.adapter_version
        AND (SELECT value FROM staging_meta WHERE key='format_version') = '1'
        AND (SELECT value FROM staging_meta WHERE key='staging_id') = manifest.staging_id
        AND (SELECT count(*) FROM staging_manifest) = 1
        AND (SELECT count(*) FROM staged_artifact) = 1
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return false }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let stagingID = columnText(statement, 1),
      let artifactSHA256 = columnText(statement, 2),
      let profileID = columnText(statement, 3),
      let adapterVersion = columnText(statement, 4)
    else { return false }
    let actual = StagingManifest(
      formatVersion: Int(sqlite3_column_int64(statement, 0)),
      stagingID: stagingID,
      artifactSHA256: artifactSHA256,
      profileID: profileID,
      adapterVersion: adapterVersion,
      tableCount: Int(sqlite3_column_int64(statement, 5)),
      recordCount: Int(sqlite3_column_int64(statement, 6)),
      fieldCount: Int(sqlite3_column_int64(statement, 7)),
      opaqueByteCount: Int(sqlite3_column_int64(statement, 8)))
    return actual == expected && sqlite3_step(statement) == SQLITE_DONE
  }

  private func scalarText(_ database: OpaquePointer, _ sql: String) -> String? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let text = sqlite3_column_text(statement, 0)
    else { return nil }
    return String(cString: text)
  }

  private func scalarInt(_ database: OpaquePointer, _ sql: String) -> Int? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_type(statement, 0) == SQLITE_INTEGER
    else { return nil }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func queryHasNoRows(_ database: OpaquePointer, _ sql: String) -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return false }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_DONE
  }

  private func columnText(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) == SQLITE_TEXT else { return nil }
    let count = Int(sqlite3_column_bytes(statement, column))
    if count == 0 { return "" }
    guard let bytes = sqlite3_column_text(statement, column) else { return nil }
    return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
  }

  private static func canonicalSQL(_ column: String) -> String {
    "typeof(\(column)) = 'text' AND length(CAST(\(column) AS BLOB)) = 64 AND \(column) NOT GLOB '*[^0-9a-f]*'"
  }

  private static func normalizedSQL(_ sql: String) -> String {
    let scalars = Array(sql.unicodeScalars)
    var normalized = String.UnicodeScalarView()
    var quote: Unicode.Scalar?
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      if let activeQuote = quote {
        normalized.append(scalar)
        if scalar == activeQuote {
          if index + 1 < scalars.count, scalars[index + 1] == activeQuote {
            index += 1
            normalized.append(scalars[index])
          } else {
            quote = nil
          }
        }
      } else if scalar == "'" || scalar == "\"" || scalar == "`" {
        quote = scalar
        normalized.append(scalar)
      } else if !scalar.properties.isWhitespace {
        normalized.append(scalar)
      }
      index += 1
    }
    return String(normalized)
  }

  private static func isCanonicalToken(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }

  private static func isValidExpectation(
    _ manifest: StagingManifest,
    contentDigest: String
  ) -> Bool {
    manifest.formatVersion == 1
      && isCanonicalToken(manifest.stagingID)
      && isCanonicalToken(manifest.artifactSHA256)
      && isCanonicalToken(contentDigest)
      && (1...256).contains(manifest.profileID.utf8.count)
      && (1...256).contains(manifest.adapterVersion.utf8.count)
      && manifest.tableCount >= 0 && manifest.recordCount >= 0
      && manifest.fieldCount >= 0 && manifest.opaqueByteCount >= 0
  }

  private static func isAcceptableFile(_ value: stat) -> Bool {
    (value.st_mode & S_IFMT) == S_IFREG && value.st_size > 0
      && value.st_size <= maximumDatabaseBytes
  }

  private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private static func hasNoSQLiteCompanions(_ url: URL) -> Bool {
    for suffix in ["-journal", "-wal", "-shm"] {
      var companion = stat()
      errno = 0
      if lstat(url.path + suffix, &companion) == 0 || errno != ENOENT { return false }
    }
    return true
  }

  private static let maximumDatabaseBytes: off_t = 1_073_741_824
  private static let maximumDecisionCount = 1_000_000
  private static let maximumSubjectCount = 1_000_000

  private static let versionOneSchema = [
    "staging_meta": """
    CREATE TABLE staging_meta(
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
    """,
    "staged_artifact": """
    CREATE TABLE staged_artifact(
      artifact_id TEXT PRIMARY KEY,
      artifact_sha256 TEXT NOT NULL,
      profile_id TEXT NOT NULL,
      adapter_version TEXT NOT NULL,
      source_size_bytes INTEGER NOT NULL CHECK(source_size_bytes >= 0)
    )
    """,
    "staged_table": """
    CREATE TABLE staged_table(
      table_id TEXT PRIMARY KEY,
      artifact_id TEXT NOT NULL REFERENCES staged_artifact(artifact_id),
      ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
      table_name TEXT NOT NULL,
      record_count INTEGER NOT NULL CHECK(record_count >= 0),
      UNIQUE(artifact_id, ordinal),
      UNIQUE(artifact_id, table_name)
    )
    """,
    "staged_record": """
    CREATE TABLE staged_record(
      record_id TEXT PRIMARY KEY,
      table_id TEXT NOT NULL REFERENCES staged_table(table_id),
      record_key TEXT NOT NULL,
      field_count INTEGER NOT NULL CHECK(field_count >= 0),
      opaque_byte_count INTEGER NOT NULL CHECK(opaque_byte_count >= 0),
      UNIQUE(table_id, record_key)
    )
    """,
    "staged_field": """
    CREATE TABLE staged_field(
      field_id TEXT PRIMARY KEY,
      record_id TEXT NOT NULL REFERENCES staged_record(record_id),
      ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
      column_name TEXT NOT NULL,
      declared_type TEXT,
      storage_class TEXT NOT NULL
        CHECK(storage_class IN ('null', 'integer', 'real', 'blob', 'text')),
      payload BLOB NOT NULL,
      sidecar_version INTEGER NOT NULL CHECK(sidecar_version = 1),
      container_member TEXT,
      UNIQUE(record_id, ordinal)
    )
    """,
    "staging_manifest": """
    CREATE TABLE staging_manifest(
      format_version INTEGER NOT NULL CHECK(format_version = 1),
      staging_id TEXT PRIMARY KEY REFERENCES staged_artifact(artifact_id),
      artifact_sha256 TEXT NOT NULL,
      profile_id TEXT NOT NULL,
      adapter_version TEXT NOT NULL,
      table_count INTEGER NOT NULL CHECK(table_count >= 0),
      record_count INTEGER NOT NULL CHECK(record_count >= 0),
      field_count INTEGER NOT NULL CHECK(field_count >= 0),
      opaque_byte_count INTEGER NOT NULL CHECK(opaque_byte_count >= 0)
    )
    """,
  ]

  private static func token(
    kind: ReconciliationSubjectKind,
    rawID: String,
    occurrence: Int
  ) -> String {
    var hasher = SHA256()
    for component in [
      "ledger-atlas/reconciliation-subject/v1", kind.rawValue, rawID, String(occurrence),
    ] {
      let data = Data(component.utf8)
      var length = UInt64(data.count).bigEndian
      withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
      hasher.update(data: data)
    }
    return hasher.finalize().lowercaseHex
  }
}

private struct RawSubject: Sendable {
  let kind: ReconciliationSubjectKind
  let rawID: String
  let parentID: String?
  let countMatches: Bool

  var key: SubjectKey { SubjectKey(kind: kind, subjectID: rawID) }
}

private struct SubjectKey: Hashable, Sendable {
  let kind: ReconciliationSubjectKind
  let subjectID: String
}

private struct DecisionKey: Hashable, Sendable {
  let kind: ReconciliationSubjectKind
  let subjectID: String

  init(_ decision: ReconciliationDecision) {
    kind = decision.kind
    subjectID = decision.subjectID
  }

  init(_ subjectKey: SubjectKey) {
    kind = subjectKey.kind
    subjectID = subjectKey.subjectID
  }

  var subjectKey: SubjectKey { SubjectKey(kind: kind, subjectID: subjectID) }
}

extension ReconciliationSubjectKind {
  fileprivate var parentKind: ReconciliationSubjectKind {
    switch self {
    case .artifact: .artifact
    case .table: .artifact
    case .record: .table
    case .field: .record
    }
  }
}
