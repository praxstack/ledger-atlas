import CSQLite
import CryptoKit
import Darwin
import Foundation

/// A content-free comparison for owner-supervised synthetic source-app experiments.
public enum SyntheticMoneyManagerOracle {
  public static func compare(
    before: URL, after: URL, action: OracleAction, limits: OracleLimits = .standard
  ) throws -> OracleComparisonReport {
    let beforeSnapshot = try OracleSnapshot.read(before, limits: limits)
    let afterSnapshot = try OracleSnapshot.read(after, limits: limits)
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
  public let tables: [OracleTableEvidence]
}

public struct OracleTableEvidence: Codable, Equatable, Sendable {
  /// A strict identifier, otherwise a stable digest. Never a source value.
  public let identifier: String
  public let rowCount: UInt64
  public let columns: [String]
}

public enum OracleStructuralDifferenceKind: String, Codable, Equatable, Sendable {
  case added, removed, changed
}

public struct OracleStructuralDifference: Codable, Equatable, Sendable {
  public let kind: OracleStructuralDifferenceKind
  /// A strict identifier, otherwise a stable digest. Never a source value.
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
  struct Table: Equatable {
    let rawName: String
    let evidence: OracleTableEvidence
  }

  let evidence: OracleSnapshotEvidence
  let tables: [Table]

  static func read(_ url: URL, limits: OracleLimits) throws -> Self {
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

    let rawTables = try tableNames(database, limit: limits.maximumTables)
    var totalColumns = 0
    var totalRows: UInt64 = 0
    var tables: [Table] = []
    tables.reserveCapacity(rawTables.count)
    for rawName in rawTables {
      let columns = try columnNames(database, table: rawName)
      let (nextColumns, columnOverflow) = totalColumns.addingReportingOverflow(columns.count)
      guard !columnOverflow, nextColumns <= limits.maximumColumns else {
        throw SyntheticMoneyManagerOracleError.hostileSize
      }
      totalColumns = nextColumns
      let rows = try rowCount(database, table: rawName)
      let (nextRows, rowOverflow) = totalRows.addingReportingOverflow(rows)
      guard !rowOverflow, nextRows <= limits.maximumRows else {
        throw SyntheticMoneyManagerOracleError.hostileSize
      }
      totalRows = nextRows
      tables.append(Table(
        rawName: rawName,
        evidence: OracleTableEvidence(
          identifier: OracleIdentifier.redacted(rawName), rowCount: rows,
          columns: columns.map(OracleIdentifier.redacted).sorted())))
    }
    let schema = SHA256.hash(data: Data(tables.map { table in
      "\(table.rawName)\u{0}\(table.evidence.columns.joined(separator: "\u{0}"))"
    }.joined(separator: "\u{0}").utf8)).hex
    let after = try source.fingerprint()
    guard before == after else { throw SyntheticMoneyManagerOracleError.sourceChanged }
    let evidence = OracleSnapshotEvidence(
      sha256: before.sha256, sizeBytes: before.sizeBytes, schemaSHA256: schema,
      tables: tables.map(\.evidence).sorted { $0.identifier < $1.identifier })
    return OracleSnapshot(evidence: evidence, tables: tables)
  }

  private static func tableNames(_ database: OpaquePointer, limit: Int) throws -> [String] {
    let sql = "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw SyntheticMoneyManagerOracleError.invalidSQLite
    }
    defer { sqlite3_finalize(statement) }
    var names: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let name = sqliteText(statement, column: 0) else {
        throw SyntheticMoneyManagerOracleError.invalidSQLite
      }
      guard names.count < limit else { throw SyntheticMoneyManagerOracleError.hostileSize }
      names.append(name)
    }
    guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
      throw SyntheticMoneyManagerOracleError.invalidSQLite
    }
    return names
  }

  private static func columnNames(_ database: OpaquePointer, table: String) throws -> [String] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA table_xinfo(\(quote(table)))", -1, &statement, nil) == SQLITE_OK,
      let statement else { throw SyntheticMoneyManagerOracleError.invalidSQLite }
    defer { sqlite3_finalize(statement) }
    var names: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard sqlite3_column_type(statement, 6) == SQLITE_INTEGER,
        sqlite3_column_int64(statement, 6) == 0, let name = sqliteText(statement, column: 1)
      else { throw SyntheticMoneyManagerOracleError.invalidSQLite }
      names.append(name)
    }
    guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
      throw SyntheticMoneyManagerOracleError.invalidSQLite
    }
    return names
  }

  private static func rowCount(_ database: OpaquePointer, table: String) throws -> UInt64 {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(quote(table))", -1, &statement, nil) == SQLITE_OK,
      let statement, sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_type(statement, 0) == SQLITE_INTEGER
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
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count >= 0 else { return nil }
    return String(data: Data(bytes: pointer, count: count), encoding: .utf8)
  }
}

private extension OracleStructuralDifference {
  static func between(_ before: OracleSnapshot, _ after: OracleSnapshot) -> [Self] {
    let old = Dictionary(uniqueKeysWithValues: before.tables.map { ($0.rawName, $0.evidence) })
    let new = Dictionary(uniqueKeysWithValues: after.tables.map { ($0.rawName, $0.evidence) })
    return (Set(old.keys).union(new.keys)).sorted().compactMap { rawName in
      switch (old[rawName], new[rawName]) {
      case (nil, .some): Self(kind: .added, subject: OracleIdentifier.redacted(rawName))
      case (.some, nil): Self(kind: .removed, subject: OracleIdentifier.redacted(rawName))
      case let (.some(old), .some(new)) where old != new:
        Self(kind: .changed, subject: OracleIdentifier.redacted(rawName))
      default: nil
      }
    }
  }
}

private final class OracleSource {
  struct Fingerprint: Equatable {
    let sha256: String
    let sizeBytes: UInt64
    let device: dev_t
    let inode: ino_t
    let mtimeSeconds: Int64
    let mtimeNanoseconds: Int64
  }

  private let descriptor: Int32
  private let initial: Fingerprint

  init(url: URL, limits: OracleLimits) throws {
    let stableURL = url.standardizedFileURL
    var path = stat()
    guard lstat(stableURL.path, &path) == 0, (path.st_mode & S_IFMT) == S_IFREG else {
      throw SyntheticMoneyManagerOracleError.unreadableSource
    }
    guard path.st_size >= 0, UInt64(path.st_size) <= limits.maximumBytes else {
      throw SyntheticMoneyManagerOracleError.hostileSize
    }
    guard ["-wal", "-shm", "-journal"].allSatisfy({ suffix in
      var companion = stat()
      return lstat(stableURL.path + suffix, &companion) != 0 && errno == ENOENT
    }) else { throw SyntheticMoneyManagerOracleError.companionFilesPresent }
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
    descriptor = opened
    initial = candidate
    retainDescriptor = true
  }

  deinit { Darwin.close(descriptor) }

  func fingerprint() throws -> Fingerprint {
    var start = stat()
    guard fstat(descriptor, &start) == 0 else { throw SyntheticMoneyManagerOracleError.unreadableSource }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    handle.seek(toFileOffset: 0)
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
    var end = stat()
    guard fstat(descriptor, &end) == 0,
      same(Self.fingerprint(start, sha256: ""), Self.fingerprint(end, sha256: "")),
      same(initial, Self.fingerprint(end, sha256: "")) else {
      throw SyntheticMoneyManagerOracleError.sourceChanged
    }
    return Self.fingerprint(end, sha256: hasher.finalize().hex)
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
}

private enum OracleIdentifier {
  static func isSafeAction(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first,
      (first.properties.isAlphabetic || first == "_"), value.utf8.count <= 64 else { return false }
    return value.unicodeScalars.allSatisfy { $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_" || $0 == "-" || $0 == "." }
  }

  static func redacted(_ value: String) -> String {
    isSafeSchemaIdentifier(value) ? value : "sha256:\(SHA256.hash(data: Data(value.utf8)).hex)"
  }

  private static func isSafeSchemaIdentifier(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first,
      (first.properties.isAlphabetic || first == "_"), value.utf8.count <= 64 else { return false }
    return value.unicodeScalars.allSatisfy {
      $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_"
    }
  }
}

private extension SHA256.Digest {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}
