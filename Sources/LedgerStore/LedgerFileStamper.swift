import CSQLite
import CryptoKit
import Foundation

/// Remembers a ledger file after this app's own checked saves, so the next open of those bytes
/// can skip the slow checks (see `CanonicalLedgerHealth.verifiedFiles`).
///
/// A store opened from a fully checked or remembered file keeps that file's identity. A save
/// that starts from exactly that identity, with no other connection's commit since, changes the
/// file only through its own checks. Once saves have been quiet for ten seconds, this runs
/// SQLite's page check and hashes the file on a background queue, and records its stamp if the
/// file still has the identity the last save left.
///
/// Such a stamp is weaker than one from a full open check: it rests on the saves' own checks
/// and the page check, not on the foreign-key check and import replay over the whole file.
package final class LedgerFileStamper: @unchecked Sendable {
  /// How long saves must be quiet before the file is checked and hashed. Longer than two
  /// seconds, so that a write during the hash moves the change time even on a volume with
  /// coarse timestamps; ten, so the check (which holds a read lock for 5-6 s on a ~900 MB
  /// ledger) rarely runs while the user is still editing. A save that comes anyway stops it.
  static let quietDelay: TimeInterval = 10

  private let url: URL
  private let verifiedFiles: CanonicalLedgerHealth.VerifiedImportGraphs
  /// Whether the file's volume keeps nanosecond change times (`csqlite_has_fine_timestamps`).
  private let fineTimestamps: Bool
  private let queue = DispatchQueue(label: "LedgerAtlas.fileStamper", qos: .utility)
  private let lock = NSLock()
  private var generation = 0
  /// The connection of the check that is running now, so `cancel()` can stop it.
  private var running: OpaquePointer?

  package init(
    url: URL, verifiedFiles: CanonicalLedgerHealth.VerifiedImportGraphs, fineTimestamps: Bool
  ) {
    self.url = url
    self.verifiedFiles = verifiedFiles
    self.fineTimestamps = fineTimestamps
  }

  /// Hash the file once saves have been quiet for `quietDelay`, if it still has `identity`.
  /// A later call replaces an earlier one that hasn't run yet.
  func schedule(_ identity: stat) {
    let scheduled = lock.withLock {
      generation += 1
      return generation
    }
    queue.asyncAfter(deadline: .now() + Self.quietDelay) { [self] in
      _ = stamp(identity, generation: scheduled)
    }
  }

  /// Drop a scheduled stamp, and stop one that is running so it lets go of the file within
  /// moments. Every save calls this first: on a ~900 MB ledger the check holds its read lock
  /// for several seconds, longer than a save waits for one.
  func cancel() {
    lock.withLock {
      generation += 1
      if let running { sqlite3_interrupt(running) }
    }
  }

  /// Check and hash the file now and remember it, if it still has `identity`. Returns whether
  /// it did.
  @discardableResult
  package func stamp(_ identity: stat) -> Bool {
    stamp(identity, generation: lock.withLock { generation })
  }

  /// Tests: runs inside the check's read lock, after the page check, with a test of whether
  /// the check has been cancelled.
  package var afterPageCheck: (@Sendable (_ stillCurrent: () -> Bool) -> Void)?

  private func stamp(_ identity: stat, generation current: Int) -> Bool {
    guard lock.withLock({ generation == current }) else { return false }
    let started = time(nil)
    // An unchanged identity before and after proves the bytes checked and hashed are the ones
    // the last save left, but only if any write in between must move the change time.
    guard fineTimestamps || identity.st_ctimespec.tv_sec + 2 < started else {
      return refuse("change time too recent")
    }
    guard isUnchanged(identity) else { return refuse("file changed before the check") }
    guard let digest = checkedDigest(whileCurrent: current) else { return false }
    guard isUnchanged(identity) else { return refuse("file changed during the check") }
    guard let trustKey = try? LedgerReceiptTrust.key(for: url, create: false),
      let stamp = CanonicalLedgerHealth.verifiedFileStamp(contentDigest: digest, trustKey: trustKey)
    else { return refuse("no trust key") }
    verifiedFiles.insert(stamp)
    return true
  }

  /// Tests and diagnostics: why the last stamp that didn't go through stopped.
  package var lastRefusal: String? { lock.withLock { refusal } }
  private var refusal: String?

  private func refuse(_ reason: String) -> Bool {
    lock.withLock { refusal = reason }
    return false
  }

  private func isUnchanged(_ identity: stat) -> Bool {
    var current = stat()
    return lstat(url.path, &current) == 0 && LedgerStore.sameFile(identity, current)
  }

  /// SQLite's `quick_check`, then the SHA-256 of every byte of the file, both under one read
  /// lock on a separate connection that only reads. Saves since the open skipped the page
  /// check, which the open's full check ran.
  ///
  /// The bytes are read through that connection's own file handle. Opening and closing another
  /// descriptor to the ledger would drop every POSIX lock this process holds on it, including a
  /// save's write lock (#140). The connection is opened read-write, as `openReadOnly` does,
  /// because a read-only description of the file broke the editor's write lock on macOS.
  ///
  /// It gives up as soon as `cancel()` moves the generation past `current`.
  private func checkedDigest(whileCurrent current: Int) -> String? {
    var database: OpaquePointer?
    defer {
      lock.withLock { running = nil }
      sqlite3_close(database)
    }
    guard
      sqlite3_open_v2(
        url.path, &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
      let database,
      lock.withLock({
        running = database
        return generation == current
      }),
      sqlite3_busy_timeout(database, LedgerStore.busyTimeoutMilliseconds) == SQLITE_OK,
      sqlite3_exec(database, "PRAGMA query_only=1", nil, nil, nil) == SQLITE_OK,
      sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK
    else { return failed("open", database) }
    defer { sqlite3_exec(database, "COMMIT", nil, nil, nil) }
    // The check's reads take the shared lock, which no save can pass until COMMIT.
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return failed("prepare quick_check", database) }
    let checked =
      sqlite3_step(statement) == SQLITE_ROW
      && sqlite3_column_text(statement, 0).map { String(cString: $0) } == "ok"
      && sqlite3_step(statement) == SQLITE_DONE
    sqlite3_finalize(statement)
    afterPageCheck?({ self.lock.withLock { self.generation == current } })
    guard checked else { return failed("quick_check", database) }
    var file: UnsafeMutablePointer<sqlite3_file>?
    let control = sqlite3_file_control(database, "main", SQLITE_FCNTL_FILE_POINTER, &file)
    guard control == SQLITE_OK, let file, let methods = file.pointee.pMethods,
      let read = methods.pointee.xRead, let fileSize = methods.pointee.xFileSize
    else { return failed("file pointer \(control)", database) }
    var size: sqlite3_int64 = 0
    let sized = fileSize(file, &size)
    guard sized == SQLITE_OK else { return failed("file size \(sized)", database) }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    var offset: sqlite3_int64 = 0
    while offset < size {
      guard lock.withLock({ generation == current }) else { return failed("cancelled", nil) }
      let count = Int(min(sqlite3_int64(buffer.count), size - offset))
      let result = buffer.withUnsafeMutableBytes {
        read(file, $0.baseAddress, Int32(count), offset)
      }
      guard result == SQLITE_OK else {
        return failed("read \(result) at \(offset) of \(size)", database)
      }
      buffer.withUnsafeBytes {
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count]))
      }
      offset += sqlite3_int64(count)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func failed(_ step: String, _ database: OpaquePointer?) -> String? {
    let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? ""
    _ = refuse("\(step): \(message)")
    return nil
  }
}
