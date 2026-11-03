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
  /// coarse timestamps; ten, so the check's read lock (about a second on a ~900 MB ledger)
  /// rarely delays a save while the user is still editing.
  static let quietDelay: TimeInterval = 10

  private let url: URL
  private let verifiedFiles: CanonicalLedgerHealth.VerifiedImportGraphs
  /// Whether the file's volume keeps nanosecond change times (`csqlite_has_fine_timestamps`).
  private let fineTimestamps: Bool
  private let queue = DispatchQueue(label: "LedgerAtlas.fileStamper", qos: .utility)
  private let lock = NSLock()
  private var generation = 0

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
      guard lock.withLock({ generation == scheduled }) else { return }
      _ = stamp(identity)
    }
  }

  /// Drop a scheduled stamp that hasn't run yet.
  func cancel() {
    lock.withLock { generation += 1 }
  }

  /// Check and hash the file now and remember it, if it still has `identity`. Returns whether
  /// it did.
  @discardableResult
  package func stamp(_ identity: stat) -> Bool {
    let started = time(nil)
    // An unchanged identity before and after proves the bytes checked and hashed are the ones
    // the last save left, but only if any write in between must move the change time.
    guard fineTimestamps || identity.st_ctimespec.tv_sec + 2 < started, isUnchanged(identity),
      let digest = Self.checkedDigest(url), isUnchanged(identity),
      let trustKey = try? LedgerReceiptTrust.key(for: url, create: false),
      let stamp = CanonicalLedgerHealth.verifiedFileStamp(contentDigest: digest, trustKey: trustKey)
    else { return false }
    verifiedFiles.insert(stamp)
    return true
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
  private static func checkedDigest(_ url: URL) -> String? {
    var database: OpaquePointer?
    defer { sqlite3_close(database) }
    guard
      sqlite3_open_v2(
        url.path, &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
      let database,
      sqlite3_busy_timeout(database, LedgerStore.busyTimeoutMilliseconds) == SQLITE_OK,
      sqlite3_exec(database, "PRAGMA query_only=1", nil, nil, nil) == SQLITE_OK,
      sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK
    else { return nil }
    defer { sqlite3_exec(database, "COMMIT", nil, nil, nil) }
    // The check's reads take the shared lock, which no save can pass until COMMIT.
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    let checked =
      sqlite3_step(statement) == SQLITE_ROW
      && sqlite3_column_text(statement, 0).map { String(cString: $0) } == "ok"
      && sqlite3_step(statement) == SQLITE_DONE
    sqlite3_finalize(statement)
    var file: UnsafeMutablePointer<sqlite3_file>?
    guard checked,
      sqlite3_file_control(database, "main", SQLITE_FCNTL_FILE_POINTER, &file) == SQLITE_OK,
      let file, let methods = file.pointee.pMethods,
      let read = methods.pointee.xRead, let fileSize = methods.pointee.xFileSize
    else { return nil }
    var size: sqlite3_int64 = 0
    guard fileSize(file, &size) == SQLITE_OK else { return nil }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    var offset: sqlite3_int64 = 0
    while offset < size {
      let count = Int(min(sqlite3_int64(buffer.count), size - offset))
      let result = buffer.withUnsafeMutableBytes {
        read(file, $0.baseAddress, Int32(count), offset)
      }
      guard result == SQLITE_OK else { return nil }
      buffer.withUnsafeBytes {
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count]))
      }
      offset += sqlite3_int64(count)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
