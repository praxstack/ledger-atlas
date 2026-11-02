import CSQLite
import CryptoKit
import Darwin
import Foundation
import LedgerCore

struct SQLiteStagingStore {
  private let testingAfterExclusiveCreate: (() throws -> Void)?
  private let testingAfterDatabaseOpen: (() throws -> Void)?

  init(
    testingAfterExclusiveCreate: (() throws -> Void)? = nil,
    testingAfterDatabaseOpen: (() throws -> Void)? = nil
  ) {
    self.testingAfterExclusiveCreate = testingAfterExclusiveCreate
    self.testingAfterDatabaseOpen = testingAfterDatabaseOpen
  }

  func write(
    _ contents: StagingContents,
    manifest: StagingManifest,
    sourceSizeBytes: UInt64,
    limitsDescription: String,
    to url: URL
  ) throws -> String {
    guard sourceSizeBytes <= UInt64(Int64.max) else { throw StagingError.sourceReadFailed }
    let descriptor = Darwin.open(
      url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw StagingError.stagingWriteFailed }
    do {
      try testingAfterExclusiveCreate?()
    } catch {
      Darwin.close(descriptor)
      throw error
    }
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else {
      if database != nil { sqlite3_close(database) }
      Darwin.close(descriptor)
      throw StagingError.stagingWriteFailed
    }
    var committed = false
    defer {
      if !committed { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
      sqlite3_close(database)
      Darwin.close(descriptor)
    }
    try testingAfterDatabaseOpen?()
    var descriptorIdentity = stat()
    var pathIdentity = stat()
    guard fstat(descriptor, &descriptorIdentity) == 0,
      lstat(url.path, &pathIdentity) == 0,
      sameIdentity(descriptorIdentity, pathIdentity), handleHasNotMoved(database)
    else { throw StagingError.stagingWriteFailed }
    guard execute(database, "PRAGMA foreign_keys=ON"),
      execute(database, "PRAGMA journal_mode=DELETE"),
      execute(database, "BEGIN IMMEDIATE"),
      execute(database, Self.schema)
    else { throw StagingError.stagingWriteFailed }

    try insertMeta(
      database,
      manifest: manifest,
      sourceSizeBytes: Int64(sourceSizeBytes),
      limitsDescription: limitsDescription)
    for (tableOrdinal, table) in contents.tables.enumerated() {
      try insertTable(
        database, table: table, stagingID: contents.stagingID, ordinal: tableOrdinal)
      for record in table.records {
        try insertRecord(database, record: record, tableID: table.id)
        for field in record.fields {
          try insertField(database, field: field, recordID: record.id)
        }
      }
    }
    try insertManifest(database, manifest)
    let contentDigest = try canonicalDigest(database)
    try insertPair(
      database, sql: "INSERT INTO staging_meta(key, value) VALUES (?, ?)",
      "content_digest", contentDigest)
    guard handleHasNotMoved(database), execute(database, "COMMIT"), handleHasNotMoved(database)
    else { throw StagingError.stagingWriteFailed }
    committed = true
    var written = stat()
    guard fstat(descriptor, &written) == 0, lstat(url.path, &pathIdentity) == 0,
      sameIdentity(written, pathIdentity), handleHasNotMoved(database),
      (written.st_mode & S_IFMT) == S_IFREG,
      (written.st_mode & 0o777) == (S_IRUSR | S_IWUSR)
    else { throw StagingError.stagingWriteFailed }
    return contentDigest
  }

  private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private func handleHasNotMoved(_ database: OpaquePointer) -> Bool {
    var moved: Int32 = 0
    return sqlite3_file_control(database, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK
      && moved == 0
  }

  /// Opens and authenticates a completed staging database while retaining the
  /// descriptor that was authenticated. Publication must use this pin rather
  /// than re-resolving the temporary pathname.
  func publicationPin(
    at url: URL,
    expectedManifest: StagingManifest,
    expectedDigest: String,
    limitsDescription: String,
    pinURL: URL? = nil
  ) throws -> PublicationPin {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw StagingError.stagingWriteFailed }
    var retainDescriptor = false
    defer {
      if !retainDescriptor { Darwin.close(descriptor) }
    }
    var descriptorBefore = stat()
    var pathBefore = stat()
    guard fstat(descriptor, &descriptorBefore) == 0,
      lstat(url.path, &pathBefore) == 0,
      (descriptorBefore.st_mode & S_IFMT) == S_IFREG,
      descriptorBefore.st_nlink == 1,
      (descriptorBefore.st_mode & 0o777) == (S_IRUSR | S_IWUSR),
      sameIdentity(descriptorBefore, pathBefore),
      sqliteCompanionsAbsent(url)
    else {
      throw StagingError.stagingWriteFailed
    }
    let sqliteDescriptor = dup(descriptor)
    guard sqliteDescriptor >= 0 else {
      throw StagingError.stagingWriteFailed
    }
    var database: OpaquePointer?
    let uri = "file:/dev/fd/\(sqliteDescriptor)?mode=ro&immutable=1"
    guard
      sqlite3_open_v2(
        uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        == SQLITE_OK,
      let database
    else {
      if database != nil { sqlite3_close(database) }
      Darwin.close(sqliteDescriptor)
      throw StagingError.stagingWriteFailed
    }
    defer {
      sqlite3_close(database)
      Darwin.close(sqliteDescriptor)
    }
    guard scalarText(database, "PRAGMA quick_check") == "ok",
      scalarText(
        database, "SELECT value FROM staging_meta WHERE key='format_version'") == "1",
      scalarText(
        database, "SELECT value FROM staging_meta WHERE key='limits_description'")
        == limitsDescription,
      let storedDigest = scalarText(
        database, "SELECT value FROM staging_meta WHERE key='content_digest'"),
      storedDigest == expectedDigest,
      (try? canonicalDigest(database)) == expectedDigest,
      hasExactSchema(database)
    else { throw StagingError.stagingWriteFailed }

    let sql = """
      SELECT format_version, staging_id, artifact_sha256, profile_id, adapter_version,
             table_count, record_count, field_count, opaque_byte_count
      FROM staging_manifest
      WHERE staging_id = ?
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw StagingError.stagingWriteFailed }
    defer { sqlite3_finalize(statement) }
    guard bindText(statement, 1, expectedManifest.stagingID),
      sqlite3_step(statement) == SQLITE_ROW
    else {
      throw StagingError.stagingWriteFailed
    }
    guard let readStageID = columnText(statement, 1),
      let artifactSHA256 = columnText(statement, 2),
      let profileID = columnText(statement, 3),
      let adapterVersion = columnText(statement, 4)
    else { throw StagingError.stagingWriteFailed }
    let manifest = StagingManifest(
      formatVersion: Int(sqlite3_column_int64(statement, 0)),
      stagingID: readStageID,
      artifactSHA256: artifactSHA256,
      profileID: profileID,
      adapterVersion: adapterVersion,
      tableCount: Int(sqlite3_column_int64(statement, 5)),
      recordCount: Int(sqlite3_column_int64(statement, 6)),
      fieldCount: Int(sqlite3_column_int64(statement, 7)),
      opaqueByteCount: Int(sqlite3_column_int64(statement, 8)))
    var descriptorAfter = stat()
    var pathAfter = stat()
    guard manifest == expectedManifest,
      scalarInt(database, "SELECT count(*) FROM staged_table") == manifest.tableCount,
      scalarInt(database, "SELECT count(*) FROM staged_record") == manifest.recordCount,
      scalarInt(database, "SELECT count(*) FROM staged_field") == manifest.fieldCount,
      scalarInt(database, "SELECT coalesce(sum(length(payload)), 0) FROM staged_field")
        == manifest.opaqueByteCount,
      queryHasNoRows(database, "PRAGMA foreign_key_check"),
      fstat(descriptor, &descriptorAfter) == 0,
      lstat(url.path, &pathAfter) == 0,
      sameIdentity(descriptorBefore, descriptorAfter),
      sameIdentity(descriptorBefore, pathAfter),
      sqliteCompanionsAbsent(url)
    else { throw StagingError.stagingWriteFailed }
    let authenticatedIdentity: stat
    if let pinURL {
      guard Darwin.link(url.path, pinURL.path) == 0 else {
        throw StagingError.stagingWriteFailed
      }
      var pinned = stat()
      var pinnedPath = stat()
      guard fstat(descriptor, &pinned) == 0,
        lstat(pinURL.path, &pinnedPath) == 0,
        sameIdentity(pinned, pinnedPath)
      else {
        throw StagingError.stagingWriteFailed
      }
      authenticatedIdentity = pinned
    } else {
      authenticatedIdentity = descriptorBefore
    }
    retainDescriptor = true
    return PublicationPin(
      descriptor: descriptor,
      authenticatedIdentity: authenticatedIdentity,
      manifest: manifest,
      pinURL: pinURL)
  }

  func reusableManifest(
    at url: URL,
    expectedManifest: StagingManifest,
    expectedDigest: String,
    limitsDescription: String
  ) -> StagingManifest? {
    try? publicationPin(
      at: url,
      expectedManifest: expectedManifest,
      expectedDigest: expectedDigest,
      limitsDescription: limitsDescription
    ).manifest
  }

  private func sqliteCompanionsAbsent(_ url: URL) -> Bool {
    ["-wal", "-shm", "-journal"].allSatisfy {
      !FileManager.default.fileExists(atPath: url.path + $0)
    }
  }

  func contentDigest(at url: URL) throws -> String {
    var database: OpaquePointer?
    let uri =
      url.absoluteString + (url.absoluteString.contains("?") ? "&" : "?")
      + "mode=ro&immutable=1"
    guard
      sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        == SQLITE_OK, let database
    else {
      if database != nil { sqlite3_close(database) }
      throw StagingError.stagingWriteFailed
    }
    defer { sqlite3_close(database) }
    return try canonicalDigest(database)
  }

  func contentDigest(database: OpaquePointer) throws -> String {
    try canonicalDigest(database)
  }

  private func hasExactSchema(_ database: OpaquePointer) -> Bool {
    let sql = """
      SELECT type, name, tbl_name
      FROM sqlite_schema
      WHERE name NOT LIKE 'sqlite_%'
      ORDER BY type, name, tbl_name
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return false }
    defer { sqlite3_finalize(statement) }
    var rows: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let type = columnText(statement, 0), let name = columnText(statement, 1),
        let table = columnText(statement, 2)
      else { return false }
      rows.append("\(type)|\(name)|\(table)")
    }
    return rows == [
      "table|staged_artifact|staged_artifact",
      "table|staged_field|staged_field",
      "table|staged_record|staged_record",
      "table|staged_table|staged_table",
      "table|staging_manifest|staging_manifest",
      "table|staging_meta|staging_meta",
    ]
  }

  private func insertMeta(
    _ database: OpaquePointer,
    manifest: StagingManifest,
    sourceSizeBytes: Int64,
    limitsDescription: String
  ) throws {
    let values = [
      ("format_version", String(manifest.formatVersion)),
      ("staging_id", manifest.stagingID),
      ("limits_description", limitsDescription),
    ]
    for (key, value) in values {
      try insertPair(
        database, sql: "INSERT INTO staging_meta(key, value) VALUES (?, ?)", key, value)
    }
    let sql = """
      INSERT INTO staged_artifact(
        artifact_id, artifact_sha256, profile_id, adapter_version, source_size_bytes
      ) VALUES (?, ?, ?, ?, ?)
      """
    try withStatement(database, sql) { statement in
      guard bindText(statement, 1, manifest.stagingID),
        bindText(statement, 2, manifest.artifactSHA256),
        bindText(statement, 3, manifest.profileID),
        bindText(statement, 4, manifest.adapterVersion),
        sqlite3_bind_int64(statement, 5, sourceSizeBytes) == SQLITE_OK,
        sqlite3_step(statement) == SQLITE_DONE
      else { throw StagingError.stagingWriteFailed }
    }
  }

  private func insertTable(
    _ database: OpaquePointer,
    table: StagedTable,
    stagingID: String,
    ordinal: Int
  ) throws {
    let sql = """
      INSERT INTO staged_table(
        table_id, artifact_id, ordinal, table_name, record_count
      ) VALUES (?, ?, ?, ?, ?)
      """
    try withStatement(database, sql) { statement in
      guard bindText(statement, 1, table.id),
        bindText(statement, 2, stagingID),
        sqlite3_bind_int64(statement, 3, Int64(ordinal)) == SQLITE_OK,
        bindText(statement, 4, table.name),
        sqlite3_bind_int64(statement, 5, Int64(table.records.count)) == SQLITE_OK,
        sqlite3_step(statement) == SQLITE_DONE
      else { throw StagingError.stagingWriteFailed }
    }
  }

  private func insertRecord(
    _ database: OpaquePointer,
    record: StagedRecord,
    tableID: String
  ) throws {
    let sql = """
      INSERT INTO staged_record(
        record_id, table_id, record_key, field_count, opaque_byte_count
      ) VALUES (?, ?, ?, ?, ?)
      """
    try withStatement(database, sql) { statement in
      guard bindText(statement, 1, record.id),
        bindText(statement, 2, tableID),
        bindText(statement, 3, record.recordKey),
        sqlite3_bind_int64(statement, 4, Int64(record.fields.count)) == SQLITE_OK,
        sqlite3_bind_int64(statement, 5, Int64(record.opaqueByteCount)) == SQLITE_OK,
        sqlite3_step(statement) == SQLITE_DONE
      else { throw StagingError.stagingWriteFailed }
    }
  }

  private func insertField(
    _ database: OpaquePointer,
    field: StagedField,
    recordID: String
  ) throws {
    let sql = """
      INSERT INTO staged_field(
        field_id, record_id, ordinal, column_name, declared_type, storage_class,
        payload, sidecar_version, container_member
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """
    try withStatement(database, sql) { statement in
      guard bindText(statement, 1, field.id),
        bindText(statement, 2, recordID),
        sqlite3_bind_int64(statement, 3, Int64(field.ordinal)) == SQLITE_OK,
        bindText(statement, 4, field.name),
        bindOptionalText(statement, 5, field.sidecar.declaredType),
        bindText(statement, 6, field.sidecar.storageClass.rawValue),
        bindBlob(statement, 7, field.sidecar.payload),
        sqlite3_bind_int64(statement, 8, Int64(field.sidecar.formatVersion)) == SQLITE_OK,
        bindOptionalText(statement, 9, field.sidecar.provenance.locator.containerMember),
        sqlite3_step(statement) == SQLITE_DONE
      else { throw StagingError.stagingWriteFailed }
    }
  }

  private func insertManifest(_ database: OpaquePointer, _ manifest: StagingManifest) throws {
    let sql = """
      INSERT INTO staging_manifest(
        format_version, staging_id, artifact_sha256, profile_id, adapter_version,
        table_count, record_count, field_count, opaque_byte_count
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """
    try withStatement(database, sql) { statement in
      guard sqlite3_bind_int64(statement, 1, Int64(manifest.formatVersion)) == SQLITE_OK,
        bindText(statement, 2, manifest.stagingID),
        bindText(statement, 3, manifest.artifactSHA256),
        bindText(statement, 4, manifest.profileID),
        bindText(statement, 5, manifest.adapterVersion),
        sqlite3_bind_int64(statement, 6, Int64(manifest.tableCount)) == SQLITE_OK,
        sqlite3_bind_int64(statement, 7, Int64(manifest.recordCount)) == SQLITE_OK,
        sqlite3_bind_int64(statement, 8, Int64(manifest.fieldCount)) == SQLITE_OK,
        sqlite3_bind_int64(statement, 9, Int64(manifest.opaqueByteCount)) == SQLITE_OK,
        sqlite3_step(statement) == SQLITE_DONE
      else { throw StagingError.stagingWriteFailed }
    }
  }

  private func insertPair(
    _ database: OpaquePointer,
    sql: String,
    _ first: String,
    _ second: String
  ) throws {
    try withStatement(database, sql) { statement in
      guard bindText(statement, 1, first), bindText(statement, 2, second),
        sqlite3_step(statement) == SQLITE_DONE
      else { throw StagingError.stagingWriteFailed }
    }
  }

  private func withStatement(
    _ database: OpaquePointer,
    _ sql: String,
    _ body: (OpaquePointer) throws -> Void
  ) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw StagingError.stagingWriteFailed }
    defer { sqlite3_finalize(statement) }
    try body(statement)
  }

  private func execute(_ database: OpaquePointer, _ sql: String) -> Bool {
    sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
  }

  private func scalarText(_ database: OpaquePointer, _ sql: String) -> String? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return columnText(statement, 0)
  }

  private func scalarInt(_ database: OpaquePointer, _ sql: String) -> Int? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
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

  private func columnText(_ statement: OpaquePointer, _ ordinal: Int32) -> String? {
    guard let text = sqlite3_column_text(statement, ordinal) else { return nil }
    return String(cString: text)
  }

  private func bindText(_ statement: OpaquePointer, _ ordinal: Int32, _ text: String) -> Bool {
    text.withCString {
      sqlite3_bind_text(
        statement, ordinal, $0, -1,
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK
    }
  }

  private func bindOptionalText(
    _ statement: OpaquePointer,
    _ ordinal: Int32,
    _ text: String?
  ) -> Bool {
    guard let text else { return sqlite3_bind_null(statement, ordinal) == SQLITE_OK }
    return bindText(statement, ordinal, text)
  }

  private func bindBlob(_ statement: OpaquePointer, _ ordinal: Int32, _ data: Data) -> Bool {
    if data.isEmpty {
      return sqlite3_bind_zeroblob(statement, ordinal, 0) == SQLITE_OK
    }
    return data.withUnsafeBytes {
      sqlite3_bind_blob(
        statement, ordinal, $0.baseAddress, Int32(data.count),
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK
    }
  }

  private func canonicalDigest(_ database: OpaquePointer) throws -> String {
    var hasher = SHA256()
    let queries = [
      "SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name, tbl_name",
      "SELECT key, value FROM staging_meta WHERE NOT key = 'content_digest' ORDER BY key",
      "SELECT artifact_id, artifact_sha256, profile_id, adapter_version, source_size_bytes FROM staged_artifact ORDER BY artifact_id",
      "SELECT table_id, artifact_id, ordinal, table_name, record_count FROM staged_table ORDER BY table_id",
      "SELECT record_id, table_id, record_key, field_count, opaque_byte_count FROM staged_record ORDER BY record_id",
      "SELECT field_id, record_id, ordinal, column_name, declared_type, storage_class, payload, sidecar_version, container_member FROM staged_field ORDER BY field_id",
      "SELECT format_version, staging_id, artifact_sha256, profile_id, adapter_version, table_count, record_count, field_count, opaque_byte_count FROM staging_manifest ORDER BY staging_id",
    ]
    for sql in queries {
      updateDigest(&hasher, with: Data(sql.utf8))
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else { throw StagingError.stagingWriteFailed }
      defer { sqlite3_finalize(statement) }
      while true {
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { break }
        guard step == SQLITE_ROW else { throw StagingError.stagingWriteFailed }
        updateDigest(&hasher, with: Data([0x72]))
        for ordinal in 0..<sqlite3_column_count(statement) {
          updateDigest(&hasher, with: try digestValue(statement, ordinal: ordinal))
        }
      }
    }
    return hasher.finalize().lowercaseHex
  }

  private func digestValue(_ statement: OpaquePointer, ordinal: Int32) throws -> Data {
    switch sqlite3_column_type(statement, ordinal) {
    case SQLITE_NULL:
      return Data([0x00])
    case SQLITE_INTEGER:
      var integer = UInt64(bitPattern: sqlite3_column_int64(statement, ordinal)).bigEndian
      return Data([0x01]) + withUnsafeBytes(of: &integer) { Data($0) }
    case SQLITE_TEXT:
      let count = Int(sqlite3_column_bytes(statement, ordinal))
      if count == 0 { return Data([0x02]) }
      guard let bytes = sqlite3_column_text(statement, ordinal) else {
        throw StagingError.stagingWriteFailed
      }
      return Data([0x02]) + Data(bytes: bytes, count: count)
    case SQLITE_BLOB:
      let count = Int(sqlite3_column_bytes(statement, ordinal))
      if count == 0 { return Data([0x03]) }
      guard let bytes = sqlite3_column_blob(statement, ordinal) else {
        throw StagingError.stagingWriteFailed
      }
      return Data([0x03]) + Data(bytes: bytes, count: count)
    default:
      throw StagingError.stagingWriteFailed
    }
  }

  private func updateDigest(_ hasher: inout SHA256, with value: Data) {
    var length = UInt64(value.count).bigEndian
    withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
    hasher.update(data: value)
  }

  private static let schema = """
    CREATE TABLE staging_meta(
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    CREATE TABLE staged_artifact(
      artifact_id TEXT PRIMARY KEY,
      artifact_sha256 TEXT NOT NULL,
      profile_id TEXT NOT NULL,
      adapter_version TEXT NOT NULL,
      source_size_bytes INTEGER NOT NULL CHECK(source_size_bytes >= 0)
    );
    CREATE TABLE staged_table(
      table_id TEXT PRIMARY KEY,
      artifact_id TEXT NOT NULL REFERENCES staged_artifact(artifact_id),
      ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
      table_name TEXT NOT NULL,
      record_count INTEGER NOT NULL CHECK(record_count >= 0),
      UNIQUE(artifact_id, ordinal),
      UNIQUE(artifact_id, table_name)
    );
    CREATE TABLE staged_record(
      record_id TEXT PRIMARY KEY,
      table_id TEXT NOT NULL REFERENCES staged_table(table_id),
      record_key TEXT NOT NULL,
      field_count INTEGER NOT NULL CHECK(field_count >= 0),
      opaque_byte_count INTEGER NOT NULL CHECK(opaque_byte_count >= 0),
      UNIQUE(table_id, record_key)
    );
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
    );
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
    );
    """
}

/// A retained descriptor for an authenticated temporary staging database.
///
/// The pathname is intentionally not trusted after this is created: callers
/// publish by linking the descriptor's inode, then prove the destination is
/// that same inode before reporting success.
final class PublicationPin {
  let manifest: StagingManifest
  private let descriptor: Int32
  private let authenticatedIdentity: stat
  private var pinURL: URL?

  init(
    descriptor: Int32,
    authenticatedIdentity: stat,
    manifest: StagingManifest,
    pinURL: URL?
  ) {
    self.descriptor = descriptor
    self.authenticatedIdentity = authenticatedIdentity
    self.manifest = manifest
    self.pinURL = pinURL
  }

  deinit {
    Darwin.close(descriptor)
  }

  func remainsAuthenticated(at url: URL) -> Bool {
    var opened = stat()
    var path = stat()
    return fstat(descriptor, &opened) == 0
      && lstat(url.path, &path) == 0
      && sameIdentity(authenticatedIdentity, opened)
      && sameIdentity(authenticatedIdentity, path)
  }

  func publishNoOverwrite(to destination: URL) throws {
    guard let pinURL else { throw StagingError.stagingWriteFailed }
    guard
      Darwin.renameatx_np(
        AT_FDCWD, pinURL.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0
    else {
      if errno == EEXIST { throw StagingError.destinationExists }
      throw StagingError.stagingWriteFailed
    }
    self.pinURL = nil
    guard matchesCurrentDescriptor(at: destination) else {
      _ = unlinkIfCurrentDescriptor(destination)
      throw StagingError.stagingWriteFailed
    }
  }

  /// Removes only the file authenticated by this pin. A swapped pathname is
  /// never unlinked as cleanup collateral.
  @discardableResult
  func unlinkIfCurrentDescriptor(_ url: URL) -> Bool {
    guard matchesCurrentDescriptor(at: url) else { return false }
    return Darwin.unlink(url.path) == 0
  }

  func discardPinnedLink() {
    guard let pinURL else { return }
    _ = unlinkIfCurrentDescriptor(pinURL)
    self.pinURL = nil
  }

  private func matchesCurrentDescriptor(at url: URL) -> Bool {
    var opened = stat()
    var path = stat()
    return fstat(descriptor, &opened) == 0
      && lstat(url.path, &path) == 0
      && sameIdentity(opened, path)
  }

  private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }
}
