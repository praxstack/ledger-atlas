import CSQLite
import Foundation
import LedgerCore

/// The only path-based boundary for creating, opening, and upgrading canonical ledgers.
public enum LedgerStoreLifecycle {
  public enum Inspection: Equatable, Sendable { case current, upgradeRequired }
  public enum Disposition: Equatable, Sendable { case created, opened, upgraded }

  public struct Result {
    public let store: LedgerStore
    public let disposition: Disposition
    public let recoveryImageURL: URL?
  }

  public enum Error: Swift.Error, Equatable, Sendable {
    case unsafePath
    case pathChanged
    case companionPresent
    case invalidStore
    case unsupportedStore
    case destinationExists
    case recoveryImageExists
    case publicationFailed
    case interrupted
  }

  package enum TestPhase: Equatable, Sendable {
    case afterTemporaryCreated
    case afterTemporaryValidated
    case afterSourceAuthenticated
    case afterRecoveryCreated
    case afterRecoveryValidated
    case afterRecoveryPublished
    case afterReplacementCreated
    case afterReplacementMigrated
    case afterReplacementValidated
    case afterPublication

    package static let creationPhases: [Self] = [
      .afterTemporaryCreated, .afterTemporaryValidated, .afterPublication,
    ]
    package static let upgradePhases: [Self] = [
      .afterSourceAuthenticated, .afterRecoveryCreated, .afterRecoveryValidated,
      .afterRecoveryPublished, .afterReplacementCreated, .afterReplacementMigrated,
      .afterReplacementValidated, .afterPublication,
    ]
  }

  package typealias TestHook = (TestPhase) throws -> Void

  public static func inspect(at url: URL) throws -> Inspection {
    let source = try openPinned(at: url)
    defer { Darwin.close(source.descriptor) }
    let result = try inspect(source)
    try requirePath(url, matches: source.identity)
    switch result {
    case .current:
      try requireInspectableCompanions(at: url, databaseDescriptor: source.descriptor)
    case .upgradeRequired: try requireNoCompanions(at: url)
    }
    try requirePath(url, matches: source.identity)
    return result
  }

  public static func create(at url: URL) throws -> Result {
    try create(at: url, testing: nil)
  }

  package static func create(at url: URL, testing hook: TestHook?) throws -> Result {
    do { return try createImpl(at: url, hook: hook) } catch let error as Error { throw error }
    catch { throw Error.interrupted }
  }

  public static func open(at url: URL) throws -> Result {
    try open(at: url, testing: nil)
  }

  package static func open(at url: URL, testing hook: TestHook?) throws -> Result {
    do { return try openImpl(at: url, hook: hook) } catch let error as Error { throw error }
    catch { throw Error.interrupted }
  }

  public static func recoveryImageURL(for url: URL) -> URL {
    URL(fileURLWithPath: url.path + ".v10-recovery")
  }

  private static func createImpl(at url: URL, hook: TestHook?) throws -> Result {
    let destination = try Destination(url)
    defer { Darwin.close(destination.parentDescriptor) }
    guard !entryExists(destination.leaf, in: destination.parentDescriptor) else {
      throw Error.destinationExists
    }
    let image = try currentImage()
    let temporary = try TemporaryFile(
      parentDescriptor: destination.parentDescriptor, prefix: ".ledger-atlas-create-")
    var published = false
    defer { temporary.closeAndRemoveUnlessPublished(published) }

    try invoke(hook, .afterTemporaryCreated)
    try write(image, to: temporary.descriptor)
    try validate(temporary.descriptor, as: .current)
    try invoke(hook, .afterTemporaryValidated)
    guard
      Darwin.renameatx_np(
        destination.parentDescriptor, temporary.leaf, destination.parentDescriptor,
        destination.leaf, UInt32(RENAME_EXCL)) == 0,
      fsync(destination.parentDescriptor) == 0
    else {
      if errno == EEXIST { throw Error.destinationExists }
      throw Error.publicationFailed
    }
    published = true
    try invoke(hook, .afterPublication)
    let store = try openPublished(
      at: url, expected: try identity(of: temporary.descriptor))
    return Result(store: store, disposition: .created, recoveryImageURL: nil)
  }

  private static func openImpl(at url: URL, hook: TestHook?) throws -> Result {
    let source = try openPinned(at: url)
    defer { Darwin.close(source.descriptor) }
    switch try inspect(source) {
    case .current:
      let store = try openPublished(at: url, expected: source.identity)
      try requireInspectableCompanions(at: url, databaseDescriptor: source.descriptor)
      try requirePath(url, matches: source.identity)
      return Result(store: store, disposition: .opened, recoveryImageURL: nil)
    case .upgradeRequired:
      try invoke(hook, .afterSourceAuthenticated)
      try requirePath(url, matches: source.identity)
      try requireNoCompanions(at: url)
      return try upgrade(source, at: url, hook: hook)
    }
  }

  private static func upgrade(_ source: PinnedFile, at url: URL, hook: TestHook?) throws -> Result {
    let destination = try Destination(url)
    defer { Darwin.close(destination.parentDescriptor) }
    let recoveryURL = recoveryImageURL(for: url)
    let recoveryLeaf = recoveryURL.lastPathComponent
    var temporaryRecovery: TemporaryFile?
    var recoveryPublished = false
    var didPublishRecovery = false
    defer { temporaryRecovery?.closeAndRemoveUnlessPublished(recoveryPublished) }
    let recovery: PinnedFile
    if entryExists(recoveryLeaf, in: destination.parentDescriptor) {
      do {
        recovery = try openValidatedRecovery(
          source: source, url: recoveryURL, leaf: recoveryLeaf,
          parentDescriptor: destination.parentDescriptor)
      } catch {
        throw Error.recoveryImageExists
      }
    } else {
      let temporary = try TemporaryFile(
        parentDescriptor: destination.parentDescriptor, prefix: ".ledger-atlas-recovery-")
      temporaryRecovery = temporary
      try invoke(hook, .afterRecoveryCreated)
      try copy(source.descriptor, to: temporary.descriptor)
      try requirePath(url, matches: source.identity)
      guard filesEqual(source.descriptor, temporary.descriptor) else { throw Error.pathChanged }
      try validate(temporary.descriptor, as: .legacyV10)
      try invoke(hook, .afterRecoveryValidated)
      guard
        Darwin.renameatx_np(
          destination.parentDescriptor, temporary.leaf, destination.parentDescriptor,
          recoveryLeaf, UInt32(RENAME_EXCL)) == 0,
        fsync(destination.parentDescriptor) == 0
      else {
        if errno == EEXIST { throw Error.recoveryImageExists }
        throw Error.publicationFailed
      }
      recoveryPublished = true
      let descriptor = dup(temporary.descriptor)
      guard descriptor >= 0 else { throw Error.publicationFailed }
      do {
        recovery = PinnedFile(
          descriptor: descriptor, identity: try identity(of: descriptor), url: recoveryURL)
      } catch {
        Darwin.close(descriptor)
        throw error
      }
      didPublishRecovery = true
    }
    defer { Darwin.close(recovery.descriptor) }
    if didPublishRecovery { try invoke(hook, .afterRecoveryPublished) }

    let replacement = try TemporaryFile(
      parentDescriptor: destination.parentDescriptor, prefix: ".ledger-atlas-upgrade-")
    var replacementPublished = false
    defer { replacement.closeAndRemoveUnlessPublished(replacementPublished) }
    try invoke(hook, .afterReplacementCreated)
    try write(try migratedImage(from: source.descriptor), to: replacement.descriptor)
    try invoke(hook, .afterReplacementMigrated)
    try validate(replacement.descriptor, as: .current)
    try invoke(hook, .afterReplacementValidated)
    try requirePath(url, matches: source.identity)
    try requireNoCompanions(at: url)
    try requireNoCompanions(leaf: recoveryLeaf, in: destination.parentDescriptor)
    guard
      sameEntry(recoveryLeaf, identity: recovery.identity, in: destination.parentDescriptor),
      filesEqual(source.descriptor, recovery.descriptor)
    else { throw Error.pathChanged }

    guard
      Darwin.renameatx_np(
        destination.parentDescriptor, replacement.leaf, destination.parentDescriptor,
        destination.leaf, UInt32(RENAME_SWAP)) == 0
    else { throw Error.publicationFailed }
    var displaced = stat()
    guard
      fstatat(
        destination.parentDescriptor, replacement.leaf, &displaced, AT_SYMLINK_NOFOLLOW) == 0,
      sameContentIdentity(displaced, source.identity),
      filesEqual(source.descriptor, recovery.descriptor), fsync(destination.parentDescriptor) == 0
    else {
      _ = Darwin.renameatx_np(
        destination.parentDescriptor, replacement.leaf, destination.parentDescriptor,
        destination.leaf, UInt32(RENAME_SWAP))
      _ = fsync(destination.parentDescriptor)
      throw Error.pathChanged
    }
    replacementPublished = true
    try invoke(hook, .afterPublication)
    let store = try openPublished(
      at: url, expected: try identity(of: replacement.descriptor))
    if sameEntry(replacement.leaf, identity: source.identity, in: destination.parentDescriptor) {
      _ = unlinkat(destination.parentDescriptor, replacement.leaf, 0)
      _ = fsync(destination.parentDescriptor)
    }
    return Result(store: store, disposition: .upgraded, recoveryImageURL: recoveryURL)
  }

  private static func openValidatedRecovery(
    source: PinnedFile, url: URL, leaf: String, parentDescriptor: Int32
  ) throws -> PinnedFile {
    try requireNoCompanions(leaf: leaf, in: parentDescriptor)
    let descriptor = Darwin.openat(parentDescriptor, leaf, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw Error.recoveryImageExists }
    do {
      let value = try identity(of: descriptor)
      var atPath = stat()
      guard
        safeFile(value),
        fstatat(parentDescriptor, leaf, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
        sameFile(value, atPath), filesEqual(source.descriptor, descriptor)
      else { throw Error.recoveryImageExists }
      try validate(descriptor, as: .legacyV10)
      return PinnedFile(descriptor: descriptor, identity: value, url: url)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private static func inspect(_ source: PinnedFile) throws -> Inspection {
    let database = try openReadOnlyDatabase(source.descriptor)
    defer { sqlite3_close(database) }
    let version = scalarText(database, "SELECT value FROM ledger_meta WHERE key='schema_version'")
    let fingerprint = scalarText(
      database, "SELECT value FROM ledger_meta WHERE key='schema_fingerprint'")
    if version == String(CanonicalLedgerSchema.version),
      fingerprint == CanonicalLedgerSchema.fingerprint
    {
      try validateDatabase(database, as: .current)
      return .current
    }
    if version == "10", fingerprint == CanonicalLedgerSchema.legacyV10Fingerprint {
      try validateDatabase(database, as: .legacyV10)
      return .upgradeRequired
    }
    if scalarInt(database, "PRAGMA application_id") == Int(CanonicalLedgerSchema.applicationID),
      scalarText(database, "SELECT value FROM ledger_meta WHERE key='ledger_identity'")
        == "ledger-atlas-canonical"
    {
      throw Error.unsupportedStore
    }
    throw Error.invalidStore
  }

  private enum Schema { case current, legacyV10 }

  private static func validate(_ descriptor: Int32, as schema: Schema) throws {
    let database = try openReadOnlyDatabase(descriptor)
    defer { sqlite3_close(database) }
    try validateDatabase(database, as: schema)
  }

  private static func validateDatabase(_ database: OpaquePointer, as schema: Schema) throws {
    let expectedVersion = schema == .current ? CanonicalLedgerSchema.version : 10
    let expectedFingerprint =
      schema == .current
      ? CanonicalLedgerSchema.fingerprint : CanonicalLedgerSchema.legacyV10Fingerprint
    let expectedObjects =
      schema == .current
      ? CanonicalLedgerSchema.expectedObjects : CanonicalLedgerSchema.legacyV10Objects
    guard
      scalarInt(database, "PRAGMA application_id") == Int(CanonicalLedgerSchema.applicationID),
      scalarText(database, "SELECT value FROM ledger_meta WHERE key='schema_version'")
        == String(expectedVersion),
      scalarText(database, "SELECT value FROM ledger_meta WHERE key='ledger_identity'")
        == "ledger-atlas-canonical",
      scalarText(database, "SELECT value FROM ledger_meta WHERE key='schema_fingerprint'")
        == expectedFingerprint,
      scalarInt(database, "SELECT count(*) FROM ledger_meta") == 3,
      schemaObjects(database) == expectedObjects,
      scalarText(database, "PRAGMA quick_check") == "ok",
      hasNoRows(database, "PRAGMA foreign_key_check"),
      CanonicalLedgerHealth.isHealthy(database)
    else { throw Error.invalidStore }
  }

  private static func currentImage() throws -> Data {
    var database: OpaquePointer?
    guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else {
      throw Error.invalidStore
    }
    defer { sqlite3_close(database) }
    guard execute(database, "PRAGMA foreign_keys=ON"),
      execute(database, "PRAGMA application_id=\(CanonicalLedgerSchema.applicationID)")
    else { throw Error.invalidStore }
    for statement in CanonicalLedgerSchema.creationStatements {
      guard execute(database, statement) else { throw Error.invalidStore }
    }
    guard execute(
      database,
      "INSERT INTO ledger_meta(key, value) VALUES('schema_version', '11'), ('ledger_identity', 'ledger-atlas-canonical'), ('schema_fingerprint', '\(CanonicalLedgerSchema.fingerprint)')"
    ) else { throw Error.invalidStore }
    try validateDatabase(database, as: .current)
    return try serialized(database)
  }

  private static func migratedImage(from descriptor: Int32) throws -> Data {
    let source = try openReadOnlyDatabase(descriptor)
    defer { sqlite3_close(source) }
    try validateDatabase(source, as: .legacyV10)
    var destination: OpaquePointer?
    guard sqlite3_open(":memory:", &destination) == SQLITE_OK, let destination else {
      throw Error.invalidStore
    }
    defer { sqlite3_close(destination) }
    guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
      throw Error.invalidStore
    }
    let step = sqlite3_backup_step(backup, -1)
    let finish = sqlite3_backup_finish(backup)
    guard step == SQLITE_DONE, finish == SQLITE_OK,
      execute(destination, "PRAGMA foreign_keys=ON"), execute(destination, "BEGIN IMMEDIATE")
    else { throw Error.invalidStore }
    do {
      for statement in CanonicalLedgerSchema.v10ToV11MigrationStatements {
        guard execute(destination, statement) else { throw Error.invalidStore }
      }
      guard
        execute(
          destination,
          "UPDATE ledger_meta SET value='11' WHERE key='schema_version'; UPDATE ledger_meta SET value='\(CanonicalLedgerSchema.fingerprint)' WHERE key='schema_fingerprint'"),
        execute(destination, "COMMIT")
      else { throw Error.invalidStore }
    } catch {
      _ = execute(destination, "ROLLBACK")
      throw error
    }
    try validateDatabase(destination, as: .current)
    return try serialized(destination)
  }

  private static func serialized(_ database: OpaquePointer) throws -> Data {
    var count: sqlite3_int64 = 0
    guard let bytes = sqlite3_serialize(database, "main", &count, 0), count > 0,
      count <= sqlite3_int64(Int.max)
    else { throw Error.invalidStore }
    defer { sqlite3_free(bytes) }
    return Data(bytes: bytes, count: Int(count))
  }

  private struct PinnedFile {
    let descriptor: Int32
    let identity: stat
    let url: URL
  }

  private static func openPinned(at url: URL) throws -> PinnedFile {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty else {
      throw Error.unsafePath
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw Error.unsafePath }
    do {
      let value = try identity(of: descriptor)
      guard safeFile(value) else { throw Error.unsafePath }
      try requirePath(url, matches: value)
      try requireInspectableCompanions(at: url, databaseDescriptor: descriptor)
      try requirePath(url, matches: value)
      return PinnedFile(descriptor: descriptor, identity: value, url: url)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private struct Destination {
    let parentDescriptor: Int32
    let leaf: String

    init(_ url: URL) throws {
      guard url.isFileURL, url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty,
        url.lastPathComponent != ".", url.lastPathComponent != ".."
      else { throw Error.unsafePath }
      leaf = url.lastPathComponent
      parentDescriptor = Darwin.open(
        url.deletingLastPathComponent().path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard parentDescriptor >= 0 else { throw Error.unsafePath }
    }
  }

  private final class TemporaryFile {
    let parentDescriptor: Int32
    let leaf: String
    let descriptor: Int32
    private let originalIdentity: stat

    init(parentDescriptor: Int32, prefix: String) throws {
      self.parentDescriptor = parentDescriptor
      leaf = prefix + UUID().uuidString + ".tmp"
      descriptor = Darwin.openat(
        parentDescriptor, leaf, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode_t(S_IRUSR | S_IWUSR))
      guard descriptor >= 0, fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
        if descriptor >= 0 { Darwin.close(descriptor) }
        throw Error.publicationFailed
      }
      do { originalIdentity = try identity(of: descriptor) } catch {
        Darwin.close(descriptor)
        _ = unlinkat(parentDescriptor, leaf, 0)
        throw error
      }
      guard safeFile(originalIdentity) else {
        Darwin.close(descriptor)
        _ = unlinkat(parentDescriptor, leaf, 0)
        throw Error.publicationFailed
      }
    }

    func closeAndRemoveUnlessPublished(_ published: Bool) {
      Darwin.close(descriptor)
      guard !published,
        sameEntry(leaf, identity: originalIdentity, in: parentDescriptor)
      else { return }
      _ = unlinkat(parentDescriptor, leaf, 0)
      _ = fsync(parentDescriptor)
    }
  }

  private static func openPublished(at url: URL, expected: stat) throws -> LedgerStore {
    do {
      let store = try LedgerStore.openForMutation(at: url)
      guard store.matchesPinnedInode(expected) else { throw Error.pathChanged }
      return store
    } catch let error as Error { throw error }
    catch { throw Error.invalidStore }
  }

  private static func invoke(_ hook: TestHook?, _ phase: TestPhase) throws {
    do { try hook?(phase) } catch { throw Error.interrupted }
  }

  private static func requireNoCompanions(at url: URL) throws {
    for suffix in ["-journal", "-journal.ledger-atlas-binding", "-wal", "-shm"] {
      var value = stat()
      errno = 0
      guard lstat(url.path + suffix, &value) != 0, errno == ENOENT else {
        throw Error.companionPresent
      }
    }
  }

  private static func requireNoCompanions(leaf: String, in parentDescriptor: Int32) throws {
    for suffix in ["-journal", "-journal.ledger-atlas-binding", "-wal", "-shm"] {
      var value = stat()
      errno = 0
      guard
        fstatat(parentDescriptor, leaf + suffix, &value, AT_SYMLINK_NOFOLLOW) != 0,
        errno == ENOENT
      else { throw Error.companionPresent }
    }
  }

  /// A successfully mutated current store retains an authenticated, empty rollback journal.
  /// The pinned mutation VFS verifies the binding before reusing the journal for a write; this
  /// preflight only admits that inactive shape and still refuses WAL, SHM, hot journals, and
  /// orphan bindings.
  private static func requireInspectableCompanions(
    at url: URL, databaseDescriptor: Int32
  ) throws {
    do {
      try LedgerStore.validateInactiveSQLiteCompanions(
        at: url, databaseDescriptor: databaseDescriptor)
    } catch {
      throw Error.companionPresent
    }
  }

  private static func requirePath(_ url: URL, matches expected: stat) throws {
    var value = stat()
    guard lstat(url.path, &value) == 0, sameFile(value, expected), safeFile(value) else {
      throw Error.pathChanged
    }
  }

  private static func identity(of descriptor: Int32) throws -> stat {
    var value = stat()
    guard fstat(descriptor, &value) == 0 else { throw Error.unsafePath }
    return value
  }

  private static func safeFile(_ value: stat) -> Bool {
    (value.st_mode & S_IFMT) == S_IFREG && value.st_uid == getuid() && value.st_nlink == 1
      && (value.st_mode & mode_t(0o777)) == mode_t(S_IRUSR | S_IWUSR)
  }

  private static func sameInode(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
    sameContentIdentity(lhs, rhs)
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private static func sameContentIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    sameInode(lhs, rhs) && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
  }

  private static func entryExists(_ leaf: String, in parent: Int32) -> Bool {
    var value = stat()
    errno = 0
    return fstatat(parent, leaf, &value, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT
  }

  private static func sameEntry(_ leaf: String, identity: stat, in parent: Int32) -> Bool {
    var value = stat()
    return fstatat(parent, leaf, &value, AT_SYMLINK_NOFOLLOW) == 0
      && sameInode(value, identity)
  }

  private static func write(_ data: Data, to descriptor: Int32) throws {
    guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
      throw Error.publicationFailed
    }
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { throw Error.publicationFailed }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
        guard count > 0 else { throw Error.publicationFailed }
        offset += count
      }
    }
    guard fsync(descriptor) == 0, safeFile(try identity(of: descriptor)) else {
      throw Error.publicationFailed
    }
  }

  private static func copy(_ source: Int32, to destination: Int32) throws {
    guard ftruncate(destination, 0) == 0, lseek(destination, 0, SEEK_SET) == 0 else {
      throw Error.publicationFailed
    }
    var offset: off_t = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = pread(source, &buffer, buffer.count, offset)
      guard count >= 0 else { throw Error.publicationFailed }
      if count == 0 { break }
      var written = 0
      while written < count {
        let result = buffer.withUnsafeBytes {
          Darwin.write(destination, $0.baseAddress!.advanced(by: written), count - written)
        }
        guard result > 0 else { throw Error.publicationFailed }
        written += result
      }
      offset += off_t(count)
    }
    guard fsync(destination) == 0, safeFile(try identity(of: destination)) else {
      throw Error.publicationFailed
    }
  }

  private static func filesEqual(_ lhs: Int32, _ rhs: Int32) -> Bool {
    guard let left = try? identity(of: lhs), let right = try? identity(of: rhs),
      left.st_size == right.st_size
    else { return false }
    var offset: off_t = 0
    var leftBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var rightBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while offset < left.st_size {
      let amount = min(leftBuffer.count, Int(left.st_size - offset))
      let leftCount = pread(lhs, &leftBuffer, amount, offset)
      let rightCount = pread(rhs, &rightBuffer, amount, offset)
      guard leftCount == amount, rightCount == amount,
        leftBuffer.prefix(amount).elementsEqual(rightBuffer.prefix(amount))
      else { return false }
      offset += off_t(amount)
    }
    return true
  }

  private static func openReadOnlyDatabase(_ descriptor: Int32) throws -> OpaquePointer {
    let duplicate = dup(descriptor)
    guard duplicate >= 0 else { throw Error.invalidStore }
    defer { Darwin.close(duplicate) }
    var database: OpaquePointer?
    let uri = "file:/dev/fd/\(duplicate)?mode=ro"
    guard
      sqlite3_open_v2(
        uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK,
      let database, sqlite3_db_readonly(database, "main") == 1
    else {
      if database != nil { sqlite3_close(database) }
      throw Error.invalidStore
    }
    return database
  }

  private static func schemaObjects(_ database: OpaquePointer) -> [CanonicalSchemaObject]? {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
        -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    var objects: [CanonicalSchemaObject] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let type = text(statement, 0), let name = text(statement, 1),
        let table = text(statement, 2), let ddl = text(statement, 3)
      else { return nil }
      objects.append(
        CanonicalSchemaObject(
          type: type, name: name, tableName: table,
          ddl: CanonicalLedgerSchema.normalizedDDL(ddl)))
    }
    return objects.sorted { ($0.type, $0.name) < ($1.type, $1.name) }
  }

  private static func scalarInt(_ database: OpaquePointer, _ sql: String) -> Int? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement, sqlite3_step(statement) == SQLITE_ROW
    else {
      if statement != nil { sqlite3_finalize(statement) }
      return nil
    }
    defer { sqlite3_finalize(statement) }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private static func scalarText(_ database: OpaquePointer, _ sql: String) -> String? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement, sqlite3_step(statement) == SQLITE_ROW
    else {
      if statement != nil { sqlite3_finalize(statement) }
      return nil
    }
    defer { sqlite3_finalize(statement) }
    return text(statement, 0)
  }

  private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, column) else { return nil }
    let count = sqlite3_column_bytes(statement, column)
    guard count >= 0 else { return nil }
    let data = Data(bytes: value, count: Int(count))
    guard !data.contains(0) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func hasNoRows(_ database: OpaquePointer, _ sql: String) -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return false }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_DONE
  }

  private static func execute(_ database: OpaquePointer, _ sql: String) -> Bool {
    sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
  }
}
