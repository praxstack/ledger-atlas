import Darwin
import Foundation

/// Saves an exported file the only way the App Sandbox allows: the file the person picked,
/// written in place, with nothing created beside it.
enum SavedFile {
  enum Error: Swift.Error, Equatable {
    case exists
    case notAFile
    case writeFailed
  }

  /// Writes `data` as a new owner-only file at `url`.
  ///
  /// With `replacing`, a regular file already at `url` is removed first. Callers pass it only
  /// after a save panel has asked the person and they chose Replace. Symbolic links and folders
  /// are never removed.
  static func write(_ data: Data, to url: URL, replacing: Bool) throws {
    guard url.isFileURL, !url.path.isEmpty else { throw Error.notAFile }
    var existing = stat()
    if lstat(url.path, &existing) == 0 {
      guard replacing else { throw Error.exists }
      guard existing.st_mode & S_IFMT == S_IFREG else { throw Error.notAFile }
      guard unlink(url.path) == 0 else { throw Error.writeFailed }
    }
    do {
      try LedgerPortablePackageFile.publish(data, to: url)
    } catch LedgerPortablePackageFile.Error.destinationExists {
      throw Error.exists
    } catch {
      throw Error.writeFailed
    }
  }
}
