import CSQLite
import CryptoKit
import Darwin
import Foundation

public struct SourceClassifier: Sendable {
  private static let sqliteMagic = Data("SQLite format 3\0".utf8)

  private let profiles: [SourceProfile]
  private let zipLimits: ZIPInspectionLimits
  private let collectStructuralCoverage: Bool
  private let testingBeforeFinalFingerprint: (@Sendable () -> Void)?

  public init(
    profiles: [SourceProfile] = SourceProfile.moneyManagerImportProfiles,
    zipLimits: ZIPInspectionLimits = .default,
    collectStructuralCoverage: Bool = false
  ) {
    self.profiles = profiles
    self.zipLimits = zipLimits
    self.collectStructuralCoverage = collectStructuralCoverage
    testingBeforeFinalFingerprint = nil
  }

  // Internal seam used only by synthetic TOCTOU regressions. Production callers cannot
  // provide an inspection callback.
  init(
    profiles: [SourceProfile] = SourceProfile.moneyManagerImportProfiles,
    zipLimits: ZIPInspectionLimits = .default,
    collectStructuralCoverage: Bool = false,
    testingBeforeFinalFingerprint: @escaping @Sendable () -> Void
  ) {
    self.profiles = profiles
    self.zipLimits = zipLimits
    self.collectStructuralCoverage = collectStructuralCoverage
    self.testingBeforeFinalFingerprint = testingBeforeFinalFingerprint
  }

  public func classify(_ sourceURL: URL) -> ClassificationResult {
    let url = sourceURL.standardizedFileURL
    let source: StableSource
    do {
      source = try StableSource(url: url)
    } catch StableSource.Error.notFound {
      return ClassificationResult(
        container: .unknown,
        fingerprintBefore: nil,
        fingerprintAfter: nil,
        status: .unavailable,
        diagnostics: [.fileNotFound]
      )
    } catch StableSource.Error.symlink {
      return ClassificationResult(
        container: .unknown,
        fingerprintBefore: nil,
        fingerprintAfter: nil,
        status: .unsupported,
        diagnostics: [.sourceSymlink]
      )
    } catch StableSource.Error.notRegular {
      return ClassificationResult(
        container: .unknown,
        fingerprintBefore: nil,
        fingerprintAfter: nil,
        status: .unsupported,
        diagnostics: [.sourceNotRegular]
      )
    } catch {
      return ClassificationResult(
        container: .unknown,
        fingerprintBefore: nil,
        fingerprintAfter: nil,
        status: .unavailable,
        diagnostics: [.fileUnreadable]
      )
    }

    guard let before = try? source.fingerprint(),
      let prefix = try? source.readPrefix(count: 16)
    else {
      return ClassificationResult(
        container: .unknown,
        fingerprintBefore: nil,
        fingerprintAfter: nil,
        status: .corrupt,
        diagnostics: [.truncatedInput]
      )
    }

    if prefix == Self.sqliteMagic {
      return inspectSQLite(source, outerContainer: .sqlite, outerBefore: before)
    }
    if prefix.starts(with: Data([0x50, 0x4b])) {
      return inspectZIP(source, before: before)
    }
    return finalized(
      source: source,
      container: .unknown,
      before: before,
      status: .unsupported,
      diagnostics: [.unsupportedContainer]
    )
  }

  private func inspectSQLite(
    _ source: StableSource,
    outerContainer: SourceContainer,
    outerBefore: SourceFingerprint,
    invokeTestingHook: Bool = true
  ) -> ClassificationResult {
    let companionSnapshot = source.sqliteCompanionSnapshot()
    if companionSnapshot.hasCompanion {
      return finalized(
        source: source,
        container: outerContainer,
        before: outerBefore,
        status: .incomplete,
        diagnostics: [.companionFiles],
        companionSnapshot: companionSnapshot,
        invokeTestingHook: invokeTestingHook
      )
    }

    guard outerBefore.sizeBytes >= 100 else {
      return finalized(
        source: source,
        container: outerContainer,
        before: outerBefore,
        status: .corrupt,
        diagnostics: [.truncatedInput],
        companionSnapshot: companionSnapshot,
        invokeTestingHook: invokeTestingHook
      )
    }

    var database: OpaquePointer?
    let uri = "file:/dev/fd/\(source.descriptor)?mode=ro&immutable=1"
    let openResult = sqlite3_open_v2(
      uri,
      &database,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
      nil
    )
    guard openResult == SQLITE_OK, let database else {
      if database != nil { sqlite3_close(database) }
      return finalized(
        source: source,
        container: outerContainer,
        before: outerBefore,
        status: .corrupt,
        diagnostics: [.invalidSQLite],
        companionSnapshot: companionSnapshot,
        invokeTestingHook: invokeTestingHook
      )
    }
    defer { sqlite3_close(database) }
    return inspectOpenedDatabase(
      database, fingerprintSource: source, outerContainer: outerContainer,
      outerBefore: outerBefore, companionSnapshot: companionSnapshot,
      invokeTestingHook: invokeTestingHook)
  }

  private func inspectOpenedDatabase(
    _ database: OpaquePointer,
    fingerprintSource source: StableSource,
    outerContainer: SourceContainer,
    outerBefore: SourceFingerprint,
    companionSnapshot: SQLiteCompanionSnapshot?,
    invokeTestingHook: Bool = true
  ) -> ClassificationResult {
    if sqlite3_db_readonly(database, "main") != 1 {
      guard execute(database, "PRAGMA query_only=ON") else {
        return finalized(
          source: source,
          container: outerContainer,
          before: outerBefore,
          status: .corrupt,
          diagnostics: [.sqliteNotReadonly],
          companionSnapshot: companionSnapshot,
          invokeTestingHook: invokeTestingHook
        )
      }
    }
    guard execute(database, "PRAGMA query_only=ON"),
      execute(database, "PRAGMA trusted_schema=OFF")
    else {
      return finalized(
        source: source,
        container: outerContainer,
        before: outerBefore,
        status: .corrupt,
        diagnostics: [.invalidSQLite],
        companionSnapshot: companionSnapshot,
        invokeTestingHook: invokeTestingHook
      )
    }

    guard check(database, "PRAGMA quick_check"), check(database, "PRAGMA integrity_check")
    else {
      return finalized(
        source: source,
        container: outerContainer,
        before: outerBefore,
        status: .corrupt,
        diagnostics: [.integrityFailed],
        companionSnapshot: companionSnapshot,
        invokeTestingHook: invokeTestingHook
      )
    }

    guard let applicationID = scalarInt(database, "PRAGMA application_id"),
      let userVersion = scalarInt(database, "PRAGMA user_version"),
      let pageSize = scalarInt(database, "PRAGMA page_size"),
      let encoding = scalarText(database, "PRAGMA encoding"),
      let inventory = schemaInventory(database)
    else {
      return finalized(
        source: source,
        container: outerContainer,
        before: outerBefore,
        status: .corrupt,
        diagnostics: [.invalidSQLite],
        companionSnapshot: companionSnapshot,
        invokeTestingHook: invokeTestingHook
      )
    }

    let schemaHash = Self.sha256(Data(inventory.serialized.utf8))
    let exact = profiles.first {
      $0.isExactSchemaCell && $0.applicationID == applicationID && $0.userVersion == userVersion
        && $0.schemaSHA256 == schemaHash
    }
    var family = resolvedFamilyProfile(
      userVersion: userVersion, tableNames: inventory.tableNames)
    // A family match still needs the contract's columns: a v19 file missing one is a different
    // profile and is refused as schema drift, never imported as an empty ledger.
    var contractMissing = false
    if exact == nil, family != nil {
      // An unreadable or oversized column inventory cannot prove the contract: unsupported.
      let columns = columnNames(database, tableNames: inventory.tableNames)
      if columns.map({ !MoneyManagerV19Contract.isSatisfied(columnsByTable: $0) }) ?? true {
        family = nil
        contractMissing = true
      }
    }
    let profile = exact ?? family
    let coverage: SourceStructuralCoverage?
    if collectStructuralCoverage {
      guard let collected = structuralCoverage(database, tableNames: inventory.tableNames) else {
        return finalized(
          source: source, container: outerContainer, before: outerBefore, status: .corrupt,
          diagnostics: [.invalidSQLite], companionSnapshot: companionSnapshot,
          invokeTestingHook: invokeTestingHook)
      }
      coverage = collected
    } else {
      coverage = nil
    }
    let metadata = SourceMetadata(
      applicationID: applicationID,
      userVersion: userVersion,
      pageSize: pageSize,
      encoding: encoding,
      schemaSHA256: schemaHash,
      tableCount: inventory.tableCount,
      indexCount: inventory.indexCount,
      structuralCoverage: coverage
    )
    let diagnostic: ClassificationDiagnostic?
    let status: ClassificationStatus
    if exact != nil {
      diagnostic = nil
      status = .supported
    } else if family != nil {
      diagnostic = .familyProfileMatch
      status = .familyMatch
    } else if contractMissing {
      diagnostic = .schemaDrift
      status = .unsupported
    } else if profiles.contains(where: {
      $0.applicationID == applicationID && $0.userVersion == userVersion
    }) {
      diagnostic = .schemaDrift
      status = .unsupported
    } else {
      diagnostic = .unknownProfile
      status = .unsupported
    }

    return finalized(
      source: source,
      container: outerContainer,
      before: outerBefore,
      status: status,
      profile: profile,
      metadata: metadata,
      diagnostics: diagnostic.map { [$0] } ?? [],
      companionSnapshot: companionSnapshot,
      invokeTestingHook: invokeTestingHook
    )
  }

  private func resolvedFamilyProfile(userVersion: Int32, tableNames: [String]) -> SourceProfile? {
    guard let family = Self.familyProfile(userVersion: userVersion, tableNames: tableNames) else {
      return nil
    }
    return profiles.contains(where: { $0.identifier == family.identifier }) ? family : nil
  }

  private static func familyProfile(userVersion: Int32, tableNames: [String]) -> SourceProfile? {
    guard userVersion == 19 else { return nil }
    let names = Set(tableNames)
    let hasOutcome = names.contains("INOUTCOME") || names.contains("ZINOUTCOME")
    let hasAssets = names.contains("ASSETS") || names.contains("ZASSETS")
    let hasCategory = names.contains("ZCATEGORY") || names.contains("CATEGORY")
    let hasCurrency = names.contains("CURRENCY") || names.contains("ZCURRENCY")
    guard hasOutcome, hasAssets, hasCategory, hasCurrency else { return nil }
    if names.contains("android_metadata") {
      return .moneyManagerAndroidV19Family
    }
    if names.contains("Z_PRIMARYKEY") || names.contains("Z_METADATA") || names.contains("ZINOUTCOME")
    {
      return .moneyManagerIOSV19Family
    }
    return .moneyManagerMacV19Family
  }

  /// Inspects SQLite bytes extracted from a ZIP without writing the original archive.
  /// Uses sqlite3_deserialize into an in-memory handle (read-only).
  private func inspectExtractedSQLite(
    _ bytes: Data,
    zipSource: StableSource,
    outerBefore: SourceFingerprint
  ) -> ClassificationResult {
    guard bytes.count >= 100, bytes.starts(with: Self.sqliteMagic) else {
      return finalized(
        source: zipSource, container: .zip, before: outerBefore, status: .corrupt,
        diagnostics: [.invalidSQLite])
    }
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        ":memory:", &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MEMORY, nil)
      == SQLITE_OK, let database
    else {
      if database != nil { sqlite3_close(database) }
      return finalized(
        source: zipSource, container: .zip, before: outerBefore, status: .unsupported,
        diagnostics: [.zipSQLiteInspectionUnavailable])
    }
    defer { sqlite3_close(database) }
    // FREEONCLOSE hands the buffer to SQLite, which frees it with sqlite3_free (also when
    // deserialize fails), so it must come from sqlite3_malloc64.
    guard let raw = sqlite3_malloc64(UInt64(bytes.count)) else {
      return finalized(
        source: zipSource, container: .zip, before: outerBefore, status: .unsupported,
        diagnostics: [.zipSQLiteInspectionUnavailable])
    }
    let copy = raw.assumingMemoryBound(to: UInt8.self)
    bytes.copyBytes(to: copy, count: bytes.count)
    let flags: UInt32 = 0x01 | 0x04  // SQLITE_DESERIALIZE_FREEONCLOSE | READONLY
    let rc = sqlite3_deserialize(
      database, "main", copy, Int64(bytes.count), Int64(bytes.count), flags)
    guard rc == SQLITE_OK else {
      return finalized(
        source: zipSource, container: .zip, before: outerBefore, status: .unsupported,
        diagnostics: [.zipSQLiteInspectionUnavailable])
    }
    return inspectOpenedDatabase(
      database, fingerprintSource: zipSource, outerContainer: .zip, outerBefore: outerBefore,
      companionSnapshot: zipSource.sqliteCompanionSnapshot())
  }

  private func inspectZIP(_ source: StableSource, before: SourceFingerprint) -> ClassificationResult
  {
    guard before.sizeBytes <= UInt64(zipLimits.maximumArchiveBytes),
      let archive = try? source.readAll(maxBytes: zipLimits.maximumArchiveBytes)
    else {
      return finalized(
        source: source,
        container: .zip,
        before: before,
        status: .corrupt,
        diagnostics: [.zipBoundsExceeded]
      )
    }

    switch ZIP32Inspector.sqliteCandidate(in: archive, limits: zipLimits) {
    case .success(let sqliteBytes):
      return inspectExtractedSQLite(sqliteBytes, zipSource: source, outerBefore: before)
    case .failure(let diagnostic):
      let status: ClassificationStatus =
        diagnostic == .archivedCompanionFiles
        ? .incomplete : .corrupt
      return finalized(
        source: source,
        container: .zip,
        before: before,
        status: status,
        diagnostics: [diagnostic]
      )
    }

  }

  private func finalized(
    source: StableSource,
    container: SourceContainer,
    before: SourceFingerprint,
    status: ClassificationStatus,
    profile: SourceProfile? = nil,
    metadata: SourceMetadata? = nil,
    diagnostics: [ClassificationDiagnostic],
    companionSnapshot: SQLiteCompanionSnapshot? = nil,
    invokeTestingHook: Bool = true
  ) -> ClassificationResult {
    if invokeTestingHook { testingBeforeFinalFingerprint?() }
    let after = try? source.fingerprint()
    let companionAfter = companionSnapshot.map { _ in source.sqliteCompanionSnapshot() }
    guard after == before, companionAfter == companionSnapshot else {
      return ClassificationResult(
        container: container,
        fingerprintBefore: before,
        fingerprintAfter: after,
        status: .incomplete,
        profile: profile,
        metadata: metadata,
        diagnostics: [.sourceChanged]
      )
    }
    return ClassificationResult(
      container: container,
      fingerprintBefore: before,
      fingerprintAfter: after,
      status: status,
      profile: profile,
      metadata: metadata,
      diagnostics: diagnostics
    )
  }

  private func execute(_ database: OpaquePointer, _ sql: String) -> Bool {
    sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
  }

  private func check(_ database: OpaquePointer, _ sql: String) -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return false }
    defer { sqlite3_finalize(statement) }
    var rows: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let text = strictText(statement, column: 0) else { return false }
      rows.append(text)
    }
    return rows == ["ok"]
  }

  private func scalarInt(_ database: OpaquePointer, _ sql: String) -> Int32? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return sqlite3_column_int(statement, 0)
  }

  private func scalarText(_ database: OpaquePointer, _ sql: String) -> String? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return strictText(statement, column: 0)
  }

  /// Lower-cased column names per table, read with PRAGMA table_info.
  private func columnNames(_ database: OpaquePointer, tableNames: [String]) -> [String: Set<String>]? {
    guard tableNames.count <= 256 else { return nil }
    var result: [String: Set<String>] = [:]
    for table in tableNames {
      let quoted = table.replacingOccurrences(of: "\"", with: "\"\"")
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, "PRAGMA table_info(\"\(quoted)\")", -1, &statement, nil)
        == SQLITE_OK, let statement
      else { return nil }
      defer { sqlite3_finalize(statement) }
      var names: Set<String> = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let name = strictText(statement, column: 1) else { return nil }
        names.insert(name.lowercased())
      }
      result[table] = names
    }
    return result
  }

  private func schemaInventory(_ database: OpaquePointer) -> (
    serialized: String, tableCount: Int, indexCount: Int, tableNames: [String]
  )? {
    let sql = """
      SELECT type, name, tbl_name, coalesce(sql, '')
      FROM sqlite_schema
      WHERE name NOT LIKE 'sqlite_%'
      ORDER BY type, name
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    var serialized = ""
    var tables = 0
    var indexes = 0
    var tableNames: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      var values: [String] = []
      // SQLite schema SQL is hashed as length-aware UTF-8 so an appended NUL is
      // not erased by C-string conversion. Object identifiers themselves cannot
      // contain a NUL because they are later used as SQL metadata.
      for column in 0..<3 {
        guard let text = strictText(statement, column: Int32(column)) else { return nil }
        values.append(text)
      }
      guard let schemaSQL = strictUTF8Text(statement, column: 3, rejectNUL: false)
      else { return nil }
      values.append(schemaSQL)
      if values[0] == "table" {
        tables += 1
        tableNames.append(values[1])
      }
      if values[0] == "index" { indexes += 1 }
      serialized += values.joined(separator: "|") + "\n"
    }
    return (serialized, tables, indexes, tableNames)
  }

  private func structuralCoverage(
    _ database: OpaquePointer, tableNames: [String]
  ) -> SourceStructuralCoverage? {
    guard tableNames.count <= 256 else { return nil }
    var recordCount: UInt64 = 0
    var fieldCount: UInt64 = 0
    var nullCount: UInt64 = 0
    var integerCount: UInt64 = 0
    var realCount: UInt64 = 0
    var textCount: UInt64 = 0
    var blobCount: UInt64 = 0
    var columnCount = 0

    for table in tableNames {
      guard let rows = scalarUInt64(database, "SELECT COUNT(*) FROM \(quotedIdentifier(table))"),
        add(&recordCount, rows), let columns = tableColumns(database, table: table)
      else { return nil }
      columnCount += columns.count
      guard columnCount <= 4_096 else { return nil }
      for column in columns {
        guard add(&fieldCount, rows),
          let counts = storageClassCounts(database, table: table, column: column)
        else { return nil }
        guard add(&nullCount, counts.null), add(&integerCount, counts.integer),
          add(&realCount, counts.real), add(&textCount, counts.text), add(&blobCount, counts.blob)
        else { return nil }
      }
    }
    return SourceStructuralCoverage(
      recordCount: recordCount, fieldCount: fieldCount, nullCount: nullCount,
      integerCount: integerCount, realCount: realCount, textCount: textCount, blobCount: blobCount)
  }

  private func tableColumns(_ database: OpaquePointer, table: String) -> [String]? {
    let sql = "PRAGMA table_xinfo(\(quotedIdentifier(table)))"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    var columns: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let name = strictText(statement, column: 1) else { return nil }
      columns.append(name)
    }
    return columns
  }

  private func storageClassCounts(
    _ database: OpaquePointer, table: String, column: String
  ) -> (null: UInt64, integer: UInt64, real: UInt64, text: UInt64, blob: UInt64)? {
    let sql =
      "SELECT typeof(\(quotedIdentifier(column))), COUNT(*) FROM \(quotedIdentifier(table)) GROUP BY 1"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    var counts: (null: UInt64, integer: UInt64, real: UInt64, text: UInt64, blob: UInt64) = (
      0, 0, 0, 0, 0
    )
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let storage = strictText(statement, column: 0),
        let count = columnUInt64(statement, column: 1)
      else { return nil }
      switch storage {
      case "null": guard add(&counts.null, count) else { return nil }
      case "integer": guard add(&counts.integer, count) else { return nil }
      case "real": guard add(&counts.real, count) else { return nil }
      case "text": guard add(&counts.text, count) else { return nil }
      case "blob": guard add(&counts.blob, count) else { return nil }
      default: return nil
      }
    }
    return counts
  }

  private func scalarUInt64(_ database: OpaquePointer, _ sql: String) -> UInt64? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return columnUInt64(statement, column: 0)
  }

  private func columnUInt64(_ statement: OpaquePointer, column: Int32) -> UInt64? {
    guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else { return nil }
    let value = sqlite3_column_int64(statement, column)
    return value < 0 ? nil : UInt64(value)
  }

  private func quotedIdentifier(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  private func add(_ value: inout UInt64, _ amount: UInt64) -> Bool {
    let (sum, overflow) = value.addingReportingOverflow(amount)
    guard !overflow else { return false }
    value = sum
    return true
  }

  /// Decodes SQLite text by the reported byte length rather than treating it as
  /// a NUL-terminated C string. Metadata used as an identifier must be valid
  /// UTF-8 and NUL-free.
  private func strictText(_ statement: OpaquePointer, column: Int32) -> String? {
    strictUTF8Text(statement, column: column, rejectNUL: true)
  }

  private func strictUTF8Text(
    _ statement: OpaquePointer,
    column: Int32,
    rejectNUL: Bool
  ) -> String? {
    guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
      let bytes = sqlite3_column_text(statement, column)
    else { return nil }
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count >= 0 else { return nil }
    let data = Data(bytes: bytes, count: count)
    guard !rejectNUL || !data.contains(0), let value = String(data: data, encoding: .utf8)
    else { return nil }
    return value
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).hex
  }
}

private final class StableSource: @unchecked Sendable {
  enum Error: Swift.Error {
    case notFound
    case symlink
    case notRegular
    case unreadable
    case readFailed
    case tooLarge
  }

  let url: URL
  let descriptor: Int32
  private let initial: stat

  init(url: URL) throws {
    self.url = url
    var pathStat = stat()
    guard lstat(url.path, &pathStat) == 0 else {
      if errno == ENOENT || errno == ENOTDIR { throw Error.notFound }
      throw Error.unreadable
    }
    if (pathStat.st_mode & S_IFMT) == S_IFLNK { throw Error.symlink }
    guard (pathStat.st_mode & S_IFMT) == S_IFREG else { throw Error.notRegular }

    let opened = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
    guard opened >= 0 else { throw Error.unreadable }
    var descriptorStat = stat()
    guard fstat(opened, &descriptorStat) == 0 else {
      Darwin.close(opened)
      throw Error.unreadable
    }
    guard Self.sameIdentity(pathStat, descriptorStat) else {
      Darwin.close(opened)
      throw Error.symlink
    }
    descriptor = opened
    initial = descriptorStat
  }

  deinit { Darwin.close(descriptor) }

  func sqliteCompanionSnapshot() -> SQLiteCompanionSnapshot {
    SQLiteCompanionSnapshot(
      entries: ["-journal", "-wal", "-shm"].map {
        CompanionFileSnapshot.capture(path: url.path + $0)
      })
  }

  func readPrefix(count: Int) throws -> Data {
    try read(count: max(0, count), exact: false)
  }

  func readAll(maxBytes: Int) throws -> Data {
    let current = try descriptorStat()
    guard current.st_size >= 0, UInt64(current.st_size) <= UInt64(maxBytes) else {
      throw Error.tooLarge
    }
    return try read(count: Int(current.st_size), exact: true)
  }

  func fingerprint() throws -> SourceFingerprint {
    let start = try descriptorStat()
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    handle.seek(toFileOffset: 0)
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    let end = try descriptorStat()
    guard Self.sameIdentity(start, end), let path = try? pathStat(),
      Self.sameIdentity(end, path)
    else { throw Error.readFailed }
    let identity = SourceFingerprint(
      sha256: hasher.finalize().hex,
      sizeBytes: UInt64(max(0, end.st_size)),
      deviceID: UInt64(end.st_dev),
      inode: UInt64(end.st_ino),
      modificationTimeSeconds: Int64(end.st_mtimespec.tv_sec),
      modificationTimeNanoseconds: Int64(end.st_mtimespec.tv_nsec))
    return identity
  }

  private func read(count: Int, exact: Bool) throws -> Data {
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    handle.seek(toFileOffset: 0)
    var output = Data()
    while output.count < count {
      let amount = min(1_048_576, count - output.count)
      let chunk = try handle.read(upToCount: amount) ?? Data()
      if chunk.isEmpty { break }
      output.append(chunk)
    }
    if exact && output.count != count { throw Error.readFailed }
    return output
  }

  private func descriptorStat() throws -> stat {
    var value = stat()
    guard fstat(descriptor, &value) == 0 else { throw Error.readFailed }
    return value
  }

  private func pathStat() throws -> stat {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw Error.readFailed }
    return value
  }

  private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }
}

private struct SQLiteCompanionSnapshot: Equatable {
  let entries: [CompanionFileSnapshot]

  var hasCompanion: Bool { entries.contains(where: \.isPresent) }
}

private enum CompanionFileSnapshot: Equatable {
  case missing
  case present(path: FileStatSnapshot, descriptor: FileStatSnapshot?)
  case indeterminate(errno: Int32)

  var isPresent: Bool {
    switch self {
    case .missing: false
    case .present, .indeterminate: true
    }
  }

  static func capture(path: String) -> Self {
    var pathStat = stat()
    guard lstat(path, &pathStat) == 0 else {
      let capturedErrno = errno
      if capturedErrno == ENOENT || capturedErrno == ENOTDIR { return .missing }
      return .indeterminate(errno: capturedErrno)
    }

    let pathSnapshot = FileStatSnapshot(pathStat)
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { return .present(path: pathSnapshot, descriptor: nil) }
    defer { Darwin.close(descriptor) }
    var descriptorStat = stat()
    guard fstat(descriptor, &descriptorStat) == 0 else {
      return .present(path: pathSnapshot, descriptor: nil)
    }
    return .present(path: pathSnapshot, descriptor: FileStatSnapshot(descriptorStat))
  }
}

private struct FileStatSnapshot: Equatable {
  let deviceID: UInt64
  let inode: UInt64
  let mode: UInt32
  let size: Int64
  let modificationTimeSeconds: Int64
  let modificationTimeNanoseconds: Int64
  let changeTimeSeconds: Int64
  let changeTimeNanoseconds: Int64

  init(_ value: stat) {
    deviceID = UInt64(value.st_dev)
    inode = UInt64(value.st_ino)
    mode = UInt32(value.st_mode)
    size = Int64(value.st_size)
    modificationTimeSeconds = Int64(value.st_mtimespec.tv_sec)
    modificationTimeNanoseconds = Int64(value.st_mtimespec.tv_nsec)
    changeTimeSeconds = Int64(value.st_ctimespec.tv_sec)
    changeTimeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
  }
}

extension SHA256.Digest {
  fileprivate var hex: String { map { String(format: "%02x", $0) }.joined() }
}
