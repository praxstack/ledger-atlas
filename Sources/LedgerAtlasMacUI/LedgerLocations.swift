import Darwin
import Foundation
import LedgerStore
internal import MMImport

/// Where ledgers live on the Mac.
///
/// The App Sandbox lets the app write a file the person picked in a panel, but nothing next to
/// it. SQLite needs a `-journal` file beside the ledger, so a ledger at a picked path cannot be
/// edited. Ledgers therefore live in the app's own storage, where the journal is allowed.
/// Opening a ledger from elsewhere copies it in and leaves the original untouched.
package enum LedgerLocations {
  /// `Application Support/Ledger Atlas/Ledgers`, created owner-only on first use.
  package static func ledgersDirectory(base: URL? = nil) throws -> URL {
    let root =
      try base
      ?? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let directory = root.appendingPathComponent("Ledger Atlas", isDirectory: true)
      .appendingPathComponent("Ledgers", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    return directory
  }

  /// True when `url` names a file directly inside `directory`.
  package static func isInside(_ url: URL, _ directory: URL) -> Bool {
    url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path
      == directory.standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// A safe file name for a ledger the person named: letters, digits, spaces, `-` and `_` only.
  package static func fileStem(for name: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " -_"))
    let cleaned = String(
      String.UnicodeScalarView(name.unicodeScalars.filter { allowed.contains($0) })
    )
    .trimmingCharacters(in: .whitespaces)
    let stem = String(cleaned.prefix(64)).trimmingCharacters(in: .whitespaces)
    return stem.isEmpty ? "Ledger" : stem
  }

  /// The first free `<stem>.sqlite`, `<stem> 2.sqlite`, … in `directory`.
  package static func availableURL(named name: String, in directory: URL) -> URL {
    let stem = fileStem(for: name)
    var candidate = directory.appendingPathComponent("\(stem).sqlite", isDirectory: false)
    var number = 2
    while FileManager.default.fileExists(atPath: candidate.path)
      || FileManager.default.fileExists(atPath: candidate.path + "-journal")
    {
      candidate = directory.appendingPathComponent("\(stem) \(number).sqlite", isDirectory: false)
      number += 1
    }
    return candidate
  }

  /// An import writes its ledger under a hidden name and moves it to its own name only once it
  /// is complete. An import cut off by a crash or a kill leaves only the hidden file, which Open
  /// Ledger doesn't list and the next import removes (#178).
  package static let importInProgressPrefix = ".importing-"

  package static func importInProgressURL(in directory: URL) -> URL {
    directory.appendingPathComponent(
      "\(importInProgressPrefix)\(UUID().uuidString).sqlite", isDirectory: false)
  }

  /// Removes what earlier imports that never finished left in `directory`.
  package static func removeUnfinishedImports(in directory: URL) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasPrefix(importInProgressPrefix) {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  /// Moves a complete import from its hidden name to `destination`, or to the next free name
  /// beside it if something took that name meanwhile. Never replaces a file.
  package static func publishImport(_ inProgress: URL, as destination: URL) throws -> URL {
    // The importer's journal is deleted when its transaction commits; one still there means
    // the ledger isn't complete.
    guard !FileManager.default.fileExists(atPath: inProgress.path + "-journal") else {
      throw CocoaError(.fileWriteUnknown)
    }
    let directory = destination.deletingLastPathComponent()
    var candidate = destination
    for _ in 0..<100 {
      if renamex_np(inProgress.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
        // What SQLite or the store kept beside the hidden name is for that name only. The
        // journal itself was checked absent above.
        for suffix in ["-journal.ledger-atlas-binding", "-wal", "-shm"] {
          unlink(inProgress.path + suffix)
        }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if parent >= 0 {
          _ = fsync(parent)
          Darwin.close(parent)
        }
        return candidate
      }
      guard errno == EEXIST else { throw CocoaError(.fileWriteUnknown) }
      candidate = availableURL(
        named: destination.deletingPathExtension().lastPathComponent, in: directory)
    }
    throw CocoaError(.fileWriteFileExists)
  }

  /// Starts access to a ledger URL. Files in app storage need no security scope.
  package static func startAccess(_ url: URL, ledgersDirectory: URL? = nil) -> Bool {
    if let directory = ledgersDirectory ?? (try? Self.ledgersDirectory()),
      isInside(url, directory)
    {
      return true
    }
    return url.startAccessingSecurityScopedResource()
  }

  package static func stopAccess(_ url: URL, ledgersDirectory: URL? = nil) {
    if let directory = ledgersDirectory ?? (try? Self.ledgersDirectory()),
      isInside(url, directory)
    {
      return
    }
    url.stopAccessingSecurityScopedResource()
  }

  /// Copies a ledger the person picked into app storage and returns the copy. The original is
  /// only read. The caller opens (and if needed upgrades) the copy through the normal lifecycle,
  /// which validates it.
  /// Removes a ledger file in app storage and the files SQLite keeps beside it. Only those
  /// exact names, so a ledger whose name starts the same ("Home" and "Home 2") is never touched.
  package static func removeLedgerFiles(at url: URL) {
    for suffix in [
      "", "-journal", "-wal", "-shm", ImportBalanceReceipt.sidecarSuffix,
      LedgerReviewQueue.sidecarSuffix,
    ] {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }

  package static func importCopy(of source: URL, into directory: URL) throws -> URL {
    let destination = availableURL(
      named: source.deletingPathExtension().lastPathComponent, in: directory)
    try FileManager.default.copyItem(at: source, to: destination)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: destination.path)
    return destination
  }
}
