import CSQLite
import CryptoKit
import Darwin
import Foundation

/// A content-free comparison for owner-supervised synthetic source-app experiments.
public enum SyntheticMoneyManagerOracle {
  public static func compare(
    before: URL, after: URL, action: OracleAction, limits: OracleLimits = .standard
  ) throws -> OracleComparisonReport {
    try compare(before: before, after: after, action: action, limits: limits, testingBeforeFinalValidation: nil)
  }

  // Internal seam for deterministic source-race regressions. Production callers cannot use it.
  static func compare(
    before: URL, after: URL, action: OracleAction, limits: OracleLimits,
    testingBeforeFinalValidation: (() -> Void)?
  ) throws -> OracleComparisonReport {
    let beforeSnapshot = try OracleSnapshot.read(
      before, limits: limits, testingBeforeFinalValidation: testingBeforeFinalValidation)
    let afterSnapshot = try OracleSnapshot.read(
      after, limits: limits, testingBeforeFinalValidation: testingBeforeFinalValidation)
    return OracleComparisonReport(
      action: action, before: beforeSnapshot.evidence, after: afterSnapshot.evidence,
      differences: OracleStructuralDifference.between(beforeSnapshot, afterSnapshot))
  }
}

public enum SyntheticMoneyManagerOracleError: Error, Equatable, Sendable {
  case invalidAction
  case unreadableSource
  case companionFilesPresent
  case invalidSQLite
  case hostileSize
  case sourceChanged
}

/// The single action intentionally recorded for a synthetic before/after pair.
public struct OracleAction: Codable, Equatable, Sendable {
  public let identifier: String

  public init(identifier: String) throws {
    guard identifier.utf8.count <= 128, OracleIdentifier.isSafeAction(identifier) else {
      throw SyntheticMoneyManagerOracleError.invalidAction
    }
    self.identifier = identifier
  }

  public init(from decoder: Decoder) throws {
    self = try Self(identifier: decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(identifier)
  }
}

public struct OracleLimits: Equatable, Sendable {
  public let maximumBytes: UInt64
  public let maximumTables: Int
  public let maximumColumns: Int
  public let maximumRows: UInt64

  public init(maximumBytes: UInt64, maximumTables: Int, maximumColumns: Int, maximumRows: UInt64) {
    self.maximumBytes = maximumBytes
    self.maximumTables = maximumTables
    self.maximumColumns = maximumColumns
    self.maximumRows = maximumRows
  }

  public static let standard = OracleLimits(
    maximumBytes: 512 * 1_024 * 1_024, maximumTables: 256, maximumColumns: 4_096,
    maximumRows: 2_000_000)
}

public struct OracleSnapshotEvidence: Codable, Equatable, Sendable {
  public let sha256: String
  public let sizeBytes: UInt64
  public let schemaSHA256: String
  public let schemaObjects: [OracleSchemaObjectEvidence]
  public let tables: [OracleTableEvidence]
}

public enum OracleSchemaObjectKind: String, Codable, Equatable, Sendable {
  case table, index, trigger, view
}

/// Every source-controlled identifier and definition is represented only by digests.
public struct OracleSchemaObjectEvidence: Codable, Equatable, Sendable {
  public let kind: OracleSchemaObjectKind
  public let identifier: String
  public let digest: String
}

public struct OracleTableEvidence: Codable, Equatable, Sendable {
  public let identifier: String
  public let rowCount: UInt64
  public let schemaObjectDigest: String
}

public enum OracleStructuralDifferenceKind: String, Codable, Equatable, Sendable {
  case added, removed, changed
}

public struct OracleStructuralDifference: Codable, Equatable, Sendable {
  public let kind: OracleStructuralDifferenceKind
  public let subject: String
}

public struct OracleComparisonReport: Codable, Equatable, Sendable {
  public let action: OracleAction
  public let before: OracleSnapshotEvidence
  public let after: OracleSnapshotEvidence
  public let differences: [OracleStructuralDifference]

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }
}

private struct OracleSnapshot {
  struct SchemaObject: Equatable {
    let rawKey: String
    let evidence: OracleSchemaObjectEvidence
  }

  struct Table: Equatable {
    let rawKey: String
    let evidence: OracleTableEvidence
  }

  let evidence: OracleSnapshotEvidence
  let schemaObjects: [SchemaObject]
  let tables: [Table]

  static func read(
    _ url: URL, limits: OracleLimits, testingBeforeFinalValidation: (() -> Void)?
  ) throws -> Self {
    let source = try OracleSource(url: url, limits: limits)
    let before = try source.fingerprint()
    guard try source.prefix(count: 16) == Data("SQLite format 3\0".utf8) else {
      throw SyntheticMoneyManagerOracleError.invalidSQLite
    }
    let database = try source.openSQLite()
    defer { sqlite3_close(database) }
    guard sqlite3_db_readonly(database, "main") == 1,
      sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK,
      sqlite3_exec(database, "PRAGMA trusted_schema=OFF", nil, nil, nil) == SQLITE_OK
    else { throw SyntheticMoneyManagerOracleError.invalidSQLite }

    let schemaObjects = try collectSchemaObjects(database, limits: limits)
    let tables = try collectTables(database, objects: schemaObjects, limits: limits)
    testingBeforeFinalValidation?()
    try source.validateCurrentPath()
    let after = try source.fingerprint()
    guard before == after else { throw SyntheticMoneyManagerOracleError.sourceChanged }
    var objects = schemaObjects.map(\.evidence)
    objects.sort { lhs, rhs in
      lhs.kind.rawValue == rhs.kind.rawValue
        ? lhs.identifier < rhs.identifier : lhs.kind.rawValue < rhs.kind.rawValue
    }
    let schemaDigestInput = objects.map { $0.digest }.joined(separator: "\u{0}")
    let evidence = OracleSnapshotEvidence(
      sha256: before.sha256, sizeBytes: before.sizeBytes,
      schemaSHA256: SHA256.hash(data: Data(schemaDigestInput.utf8)).hex,
      schemaObjects: objects, tables: tables.map(\.evidence).sorted { $0.identifier < $1.identifier })
    return OracleSnapshot(evidence: evidence, schemaObjects: schemaObjects, tables: tables)
  }

  private static func collectSchemaObjects(
    _ database: OpaquePointer, limits: OracleLimits
  ) throws -> [SchemaObject] {
    let sql = "SELECT type, name, tbl_name, COALESCE(sql, '') FROM sqlite_schema WHERE type IN ('table', 'index', 'trigger', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name, tbl_name"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw SyntheticMoneyManagerOracleError.invalidSQLite
    }
    defer { sqlite3_finalize(statement) }
    var output: [SchemaObject] = []
    var tableCount = 0
    var columnCount = 0
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let typeText = sqliteText(statement, column: 0), let kind = OracleSchemaObjectKind(rawValue: typeText),
        let name = sqliteText(statement, column: 1), let table = sqliteText(statement, column: 2),
        let sql = sqliteText(statement, column: 3) else { throw SyntheticMoneyManagerOracleError.invalidSQLite }
      if kind == .table {
        tableCount += 1
        guard tableCount <= limits.maximumTables else { throw SyntheticMoneyManagerOracleError.hostileSize }
      }
      let metadata: (serialized: String, count: Int) = kind == .table
        ? try tableMetadata(database, table: name) : (serialized: "", count: 0)
      let (nextColumns, overflow) = columnCount.addingReportingOverflow(metadata.count)
      guard !overflow, nextColumns <= limits.maximumColumns else {
        throw SyntheticMoneyManagerOracleError.hostileSize
      }
      columnCount = nextColumns
      let rawKey = "\(kind.rawValue)\u{0}\(name)\u{0}\(table)"
      let digest = digest(["ledger-atlas/oracle-schema-object/v1", rawKey, sql, metadata.serialized])
      output.append(SchemaObject(
        rawKey: rawKey,
        evidence: OracleSchemaObjectEvidence(kind: kind, identifier: OracleIdentifier.digest(rawKey), digest: digest)))
    }
    guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
      throw SyntheticMoneyManagerOracleError.invalidSQLite
    }
    return output
  }

  private static func collectTables(
    _ database: OpaquePointer, objects: [SchemaObject], limits: OracleLimits
  ) throws -> [Table] {
    var totalRows: UInt64 = 0
    var output: [Table] = []
    for object in objects where object.evidence.kind == .table {
      let name = object.rawKey.split(separator: "\u{0}", maxSplits: 2)[1]
      let rows = try rowCount(database, table: String(name))
      let (nextRows, overflow) = totalRows.addingReportingOverflow(rows)
      guard !overflow, nextRows <= limits.maximumRows else { throw SyntheticMoneyManagerOracleError.hostileSize }
      totalRows = nextRows
      output.append(Table(
        rawKey: object.rawKey,
        evidence: OracleTableEvidence(
          identifier: object.evidence.identifier, rowCount: rows, schemaObjectDigest: object.evidence.digest)))
    }
    return output
  }

  private static func tableMetadata(_ database: OpaquePointer, table: String) throws -> (serialized: String, count: Int) {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA table_xinfo(\(quote(table)))", -1, &statement, nil) == SQLITE_OK,
      let statement else { throw SyntheticMoneyManagerOracleError.invalidSQLite }
    defer { sqlite3_finalize(statement) }
    var rows: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
        let name = sqliteText(statement, column: 1), let type = sqliteText(statement, column: 2),
        sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
        sqlite3_column_type(statement, 5) == SQLITE_INTEGER, sqlite3_column_type(statement, 6) == SQLITE_INTEGER
      else { throw SyntheticMoneyManagerOracleError.invalidSQLite }
      let defaultValue = sqliteOptionalText(statement, column: 4)
      rows.append([
        String(sqlite3_column_int64(statement, 0)), name, type, String(sqlite3_column_int64(statement, 3)),
        defaultValue ?? "<null>", String(sqlite3_column_int64(statement, 5)), String(sqlite3_column_int64(statement, 6)),
      ].joined(separator: "\u{0}"))
    }
    guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
      throw SyntheticMoneyManagerOracleError.invalidSQLite
    }
    return (rows.joined(separator: "\u{0}"), rows.count)
  }

  private static func rowCount(_ database: OpaquePointer, table: String) throws -> UInt64 {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(quote(table))", -1, &statement, nil) == SQLITE_OK,
      let statement, sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER
    else { throw SyntheticMoneyManagerOracleError.invalidSQLite }
    defer { sqlite3_finalize(statement) }
    let value = sqlite3_column_int64(statement, 0)
    guard value >= 0, sqlite3_step(statement) == SQLITE_DONE else {
      throw SyntheticMoneyManagerOracleError.invalidSQLite
    }
    return UInt64(value)
  }

  private static func quote(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  private static func sqliteText(_ statement: OpaquePointer, column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
      let pointer = sqlite3_column_text(statement, column) else { return nil }
    return String(data: Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8)
  }

  private static func sqliteOptionalText(_ statement: OpaquePointer, column: Int32) -> String? {
    sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqliteText(statement, column: column)
  }

  private static func digest(_ values: [String]) -> String {
    SHA256.hash(data: Data(values.joined(separator: "\u{0}").utf8)).hex
  }
}

private extension OracleStructuralDifference {
  static func between(_ before: OracleSnapshot, _ after: OracleSnapshot) -> [Self] {
    var changes: [String: OracleStructuralDifferenceKind] = [:]
    compare(before.schemaObjects, after.schemaObjects, into: &changes)
    compare(before.tables, after.tables, into: &changes)
    return changes.keys.sorted().map { Self(kind: changes[$0]!, subject: OracleIdentifier.digest($0)) }
  }

  private static func compare<T: OracleDiffable & Equatable>(
    _ before: [T], _ after: [T], into changes: inout [String: OracleStructuralDifferenceKind]
  ) {
    let old = Dictionary(uniqueKeysWithValues: before.map { ($0.rawKey, $0) })
    let new = Dictionary(uniqueKeysWithValues: after.map { ($0.rawKey, $0) })
    for key in Set(old.keys).union(new.keys) {
      switch (old[key], new[key]) {
      case (nil, .some): changes[key] = .added
      case (.some, nil): changes[key] = .removed
      case let (.some(old), .some(new)) where old != new: changes[key] = .changed
      default: break
      }
    }
  }
}

private protocol OracleDiffable { var rawKey: String { get } }
extension OracleSnapshot.SchemaObject: OracleDiffable {}
extension OracleSnapshot.Table: OracleDiffable {}

private final class OracleSource {
  struct Fingerprint: Equatable {
    let sha256: String
    let sizeBytes: UInt64
    let device: dev_t
    let inode: ino_t
    let mtimeSeconds: Int64
    let mtimeNanoseconds: Int64
  }

  private let url: URL
  private let descriptor: Int32
  private let initial: Fingerprint

  init(url: URL, limits: OracleLimits) throws {
    let stableURL = url.standardizedFileURL
    var path = stat()
    guard lstat(stableURL.path, &path) == 0, (path.st_mode & S_IFMT) == S_IFREG else {
      throw SyntheticMoneyManagerOracleError.unreadableSource
    }
    guard path.st_size >= 0, UInt64(path.st_size) <= limits.maximumBytes,
      UInt64(path.st_size) <= UInt64(Int.max) else {
      throw SyntheticMoneyManagerOracleError.hostileSize
    }
    guard Self.companionsAbsent(stableURL) else { throw SyntheticMoneyManagerOracleError.companionFilesPresent }
    let opened = Darwin.open(stableURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard opened >= 0 else { throw SyntheticMoneyManagerOracleError.unreadableSource }
    var retainDescriptor = false
    defer { if !retainDescriptor { Darwin.close(opened) } }
    var openedStat = stat()
    guard fstat(opened, &openedStat) == 0 else { throw SyntheticMoneyManagerOracleError.unreadableSource }
    let candidate = Self.fingerprint(openedStat, sha256: "")
    guard candidate.device == path.st_dev, candidate.inode == path.st_ino else {
      throw SyntheticMoneyManagerOracleError.unreadableSource
    }
    self.url = stableURL
    descriptor = opened
    initial = candidate
    retainDescriptor = true
  }

  deinit { Darwin.close(descriptor) }

  func fingerprint() throws -> Fingerprint {
    var start = stat()
    guard fstat(descriptor, &start) == 0, same(initial, Self.fingerprint(start, sha256: "")) else {
      throw SyntheticMoneyManagerOracleError.sourceChanged
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    handle.seek(toFileOffset: 0)
    var remaining = Int(initial.sizeBytes)
    var hasher = SHA256()
    while remaining > 0 {
      let chunk = try handle.read(upToCount: min(1_048_576, remaining)) ?? Data()
      guard !chunk.isEmpty else { throw SyntheticMoneyManagerOracleError.sourceChanged }
      hasher.update(data: chunk)
      remaining -= chunk.count
    }
    var end = stat()
    guard fstat(descriptor, &end) == 0, same(initial, Self.fingerprint(end, sha256: "")) else {
      throw SyntheticMoneyManagerOracleError.sourceChanged
    }
    return Self.fingerprint(end, sha256: hasher.finalize().hex)
  }

  func validateCurrentPath() throws {
    var path = stat()
    guard lstat(url.path, &path) == 0, (path.st_mode & S_IFMT) == S_IFREG else {
      throw SyntheticMoneyManagerOracleError.sourceChanged
    }
    guard same(initial, Self.fingerprint(path, sha256: "")) else {
      throw SyntheticMoneyManagerOracleError.sourceChanged
    }
    guard Self.companionsAbsent(url) else { throw SyntheticMoneyManagerOracleError.companionFilesPresent }
  }

  func prefix(count: Int) throws -> Data {
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    handle.seek(toFileOffset: 0)
    return try handle.read(upToCount: count) ?? Data()
  }

  func openSQLite() throws -> OpaquePointer {
    let copy = dup(descriptor)
    guard copy >= 0 else { throw SyntheticMoneyManagerOracleError.unreadableSource }
    var database: OpaquePointer?
    let result = sqlite3_open_v2(
      "file:/dev/fd/\(copy)?mode=ro&immutable=1", &database,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
    Darwin.close(copy)
    guard result == SQLITE_OK, let database else {
      if database != nil { sqlite3_close(database) }
      throw SyntheticMoneyManagerOracleError.invalidSQLite
    }
    return database
  }

  private static func fingerprint(_ value: stat, sha256: String) -> Fingerprint {
    Fingerprint(
      sha256: sha256, sizeBytes: UInt64(value.st_size), device: value.st_dev, inode: value.st_ino,
      mtimeSeconds: Int64(value.st_mtimespec.tv_sec), mtimeNanoseconds: Int64(value.st_mtimespec.tv_nsec))
  }

  private func same(_ lhs: Fingerprint, _ rhs: Fingerprint) -> Bool {
    lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.sizeBytes == rhs.sizeBytes
      && lhs.mtimeSeconds == rhs.mtimeSeconds && lhs.mtimeNanoseconds == rhs.mtimeNanoseconds
  }

  private static func companionsAbsent(_ source: URL) -> Bool {
    ["-wal", "-shm", "-journal"].allSatisfy { suffix in
      var companion = stat()
      return lstat(source.path + suffix, &companion) != 0 && errno == ENOENT
    }
  }
}

private enum OracleIdentifier {
  static func isSafeAction(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first,
      (first.properties.isAlphabetic || first == "_"), value.utf8.count <= 128 else { return false }
    return value.unicodeScalars.allSatisfy {
      $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_" || $0 == "-" || $0 == "."
    }
  }

  static func digest(_ value: String) -> String {
    "sha256:\(SHA256.hash(data: Data(value.utf8)).hex)"
  }
}

private extension SHA256.Digest {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}
