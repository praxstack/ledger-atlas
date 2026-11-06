import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Small owner-only files that can be replaced and removed, such as the app-lock passcode
/// verifier. Receipt keys use `LedgerReceiptKeyFile` instead, which never replaces a key.
package enum LedgerPrivateFile {
  package enum Error: Swift.Error, Equatable, Sendable {
    case invalidName
    case notARegularFile
    case tooLarge
    case empty
    case system(Int32)
  }

  /// Files larger than this are refused when read or written.
  package static let maximumSize = 4096

  /// `Application Support/Ledger Atlas/<name>`. In the sandboxed app this is inside the
  /// app's container.
  package static func directory(named name: String) throws -> URL {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return root.appendingPathComponent("Ledger Atlas", isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
  }

  /// The file's bytes, or nil when there is no file. A symlink, a folder or an oversized
  /// file is refused, never treated as missing.
  package static func read(_ name: String, in directory: URL) throws -> Data? {
    guard isSafeName(name) else { throw Error.invalidName }
    let descriptor = open(
      directory.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw Error.system(errno)
    }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0 else { throw Error.system(errno) }
    guard (status.st_mode & S_IFMT) == S_IFREG else { throw Error.notARegularFile }
    guard status.st_size <= maximumSize else { throw Error.tooLarge }
    // Writes are atomic, so an empty file is damage, never a value.
    guard status.st_size > 0 else { throw Error.empty }
    var bytes = [UInt8](repeating: 0, count: Int(status.st_size))
    var total = 0
    while total < bytes.count {
      let count = bytes.withUnsafeMutableBytes {
        Foundation.read(descriptor, $0.baseAddress! + total, $0.count - total)
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw Error.system(count < 0 ? errno : EIO) }
      total += count
    }
    return Data(bytes)
  }

  /// Replaces the file with `data` in one step, or removes it when `data` is nil. A reader sees
  /// either the old file or the new one, never a partial write.
  package static func write(_ data: Data?, to name: String, in directory: URL) throws {
    guard isSafeName(name) else { throw Error.invalidName }
    let final = directory.appendingPathComponent(name).path
    guard let data else {
      guard unlink(final) == 0 || errno == ENOENT else { throw Error.system(errno) }
      syncFolder(directory)
      return
    }
    guard data.count <= maximumSize else { throw Error.tooLarge }
    guard !data.isEmpty else { throw Error.empty }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    try tightenFolder(directory)
    let temporary = directory.appendingPathComponent(".\(name).\(UUID().uuidString).tmp").path
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw Error.system(errno) }
    defer { unlink(temporary) }
    var failure: Int32?
    data.withUnsafeBytes { buffer in
      var total = 0
      while total < buffer.count {
        let count = Foundation.write(descriptor, buffer.baseAddress! + total, buffer.count - total)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          failure = count < 0 ? errno : EIO
          return
        }
        total += count
      }
    }
    if failure == nil, fsync(descriptor) != 0 { failure = errno }
    close(descriptor)
    if let failure { throw Error.system(failure) }
    guard rename(temporary, final) == 0 else { throw Error.system(errno) }
    syncFolder(directory)
  }

  /// Makes the folder owner-only. It is opened without following a symlink, so a link put in
  /// its place is refused instead of changing the folder it points to.
  private static func tightenFolder(_ directory: URL) throws {
    let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard folder >= 0 else { throw Error.system(errno) }
    defer { close(folder) }
    guard fchmod(folder, 0o700) == 0 else { throw Error.system(errno) }
  }

  private static func syncFolder(_ directory: URL) {
    let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard folder >= 0 else { return }
    _ = fsync(folder)
    close(folder)
  }

  /// Lowercase letters, digits and dashes only, so a name can't leave the folder.
  private static func isSafeName(_ name: String) -> Bool {
    !name.isEmpty && name.count <= 64
      && name.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
  }
}
