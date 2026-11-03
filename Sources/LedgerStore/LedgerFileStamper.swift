import CSQLite
import CryptoKit
import Foundation

/// Remembers a ledger file after this app's own checked saves, so the next open of those bytes
/// can skip the slow checks (see `CanonicalLedgerHealth.verifiedFiles`).
///
/// A store opened from a fully checked or remembered file keeps that file's identity. A save
/// that starts from exactly that identity, with no other connection's commit since, changes the
/// file only through its own checks, so the bytes it leaves behind are as trustworthy as the
/// ones it started from. Once saves have been quiet for a few seconds, this hashes the file on
/// a background queue and records its stamp, provided the file still has the identity the last
/// save left.
final class LedgerFileStamper: @unchecked Sendable {
  /// How long saves must be quiet before the file is hashed. Longer than two seconds, so that
  /// a write during the hash moves the change time even on a volume with coarse timestamps.
  static let quietDelay: TimeInterval = 3

  private let url: URL
  private let verifiedFiles: CanonicalLedgerHealth.VerifiedImportGraphs
  private let queue = DispatchQueue(label: "LedgerAtlas.fileStamper", qos: .utility)
  private let lock = NSLock()
  private var generation = 0

  init(url: URL, verifiedFiles: CanonicalLedgerHealth.VerifiedImportGraphs) {
    self.url = url
    self.verifiedFiles = verifiedFiles
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

  /// Hash the file now and remember it, if it still has `identity`. Returns whether it did.
  @discardableResult
  func stamp(_ identity: stat) -> Bool {
    let started = time(nil)
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    var before = stat()
    // An unchanged identity before and after the hash proves the hash is of the bytes the last
    // save left, but only if any write in between must move the change time.
    guard fstat(descriptor, &before) == 0, LedgerStore.sameFile(identity, before),
      csqlite_has_fine_timestamps(descriptor) == 1 || identity.st_ctimespec.tv_sec + 2 < started
    else { return false }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    var offset: off_t = 0
    while offset < before.st_size {
      let count = pread(descriptor, &buffer, min(buffer.count, Int(before.st_size - offset)), offset)
      guard count > 0 else { return false }
      buffer.withUnsafeBytes {
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count]))
      }
      offset += off_t(count)
    }
    var after = stat()
    var atPath = stat()
    guard fstat(descriptor, &after) == 0, LedgerStore.sameFile(identity, after),
      lstat(url.path, &atPath) == 0, LedgerStore.sameFile(identity, atPath),
      let trustKey = try? LedgerReceiptTrust.key(for: url, create: false),
      let stamp = CanonicalLedgerHealth.verifiedFileStamp(
        contentDigest: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
        trustKey: trustKey)
    else { return false }
    verifiedFiles.insert(stamp)
    return true
  }
}
