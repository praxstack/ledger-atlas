import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Keeps a receipt trust key in a private file when the Keychain can't hold it.
///
/// The free, ad-hoc signed app has no Apple Team ID, so iCloud Keychain refuses its items
/// (errSecMissingEntitlement), and a device-only Keychain item asks for the Mac password after
/// every update, because each build has a new signature (measured by
/// `scripts/ci/keychain-probe.sh`). The key then lives in the app's own storage, readable only
/// by this user, and never inside a ledger file.
package enum LedgerReceiptKeyFile {
  /// `Application Support/Ledger Atlas/Keys`, created owner-only. In the sandboxed app this is
  /// inside the app's container.
  package static func defaultDirectory() throws -> URL {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return root.appendingPathComponent("Ledger Atlas", isDirectory: true)
      .appendingPathComponent("Keys", isDirectory: true)
  }

  /// The key for `account`, or nil when there is none. A file that is not a regular,
  /// 32-byte file is refused, never treated as missing.
  package static func read(account: String, in directory: URL) throws -> Data? {
    guard isSafeName(account) else { throw LedgerReceiptTrustError.invalidKey }
    let path = directory.appendingPathComponent(account + ".key").path
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw LedgerReceiptTrustError.file(errno)
    }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
      status.st_size == 32
    else { throw LedgerReceiptTrustError.invalidKey }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard Foundation.read(descriptor, &bytes, 32) == 32 else {
      throw LedgerReceiptTrustError.invalidKey
    }
    return Data(bytes)
  }

  /// Stores `value` for `account` unless a key is already there, and returns the key that is
  /// kept. The file appears whole or not at all: it is written to a temporary name, synced, and
  /// then linked into place, which fails rather than replacing an existing key.
  package static func store(_ value: Data, account: String, in directory: URL) throws -> Data {
    guard value.count == 32, isSafeName(account) else { throw LedgerReceiptTrustError.invalidKey }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    // A folder made earlier with wider permissions is tightened before a key goes in.
    // Opened without following a symlink, so a link in the folder's place is refused.
    let keysFolder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard keysFolder >= 0 else { throw LedgerReceiptTrustError.file(errno) }
    let tightened = fchmod(keysFolder, 0o700) == 0
    let chmodError = errno
    close(keysFolder)
    guard tightened else { throw LedgerReceiptTrustError.file(chmodError) }
    let final = directory.appendingPathComponent(account + ".key").path
    let temporary = directory.appendingPathComponent(".\(account).\(UUID().uuidString).tmp").path
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw LedgerReceiptTrustError.file(errno) }
    defer { unlink(temporary) }
    let written = value.withUnsafeBytes { Foundation.write(descriptor, $0.baseAddress, 32) }
    // errno is read right after the call that failed; close() could change it.
    var failure: Int32? = written == 32 ? nil : (written < 0 ? errno : EIO)
    if failure == nil, fsync(descriptor) != 0 { failure = errno }
    close(descriptor)
    if let failure { throw LedgerReceiptTrustError.file(failure) }
    if link(temporary, final) != 0 {
      guard errno == EEXIST else { throw LedgerReceiptTrustError.file(errno) }
      guard let existing = try read(account: account, in: directory) else {
        throw LedgerReceiptTrustError.invalidKey
      }
      return existing
    }
    let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if folder >= 0 {
      _ = fsync(folder)
      close(folder)
    }
    return value
  }

  /// Accounts that have a key file in `directory`. None when the folder doesn't exist.
  package static func accounts(in directory: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasSuffix(".key") }
      .map { String($0.dropLast(4)) }
      .filter(isSafeName)
      .sorted()
  }

  /// Removes the key file for `account`. Call it only once the key is safely somewhere else.
  package static func remove(account: String, in directory: URL) throws {
    guard isSafeName(account) else { throw LedgerReceiptTrustError.invalidKey }
    let path = directory.appendingPathComponent(account + ".key").path
    guard unlink(path) == 0 || errno == ENOENT else { throw LedgerReceiptTrustError.file(errno) }
    let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if folder >= 0 {
      _ = fsync(folder)
      close(folder)
    }
  }

  /// Account names are lowercase hex digests; anything else could escape the folder.
  private static func isSafeName(_ account: String) -> Bool {
    !account.isEmpty && account.count <= 128
      && account.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
