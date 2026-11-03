import AppKit
import CryptoKit
import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

// Synthetic data only: the marker values below are made up and exist only in this test.

/// #57 privacy scan: no ledger data leaves the device or lands in logs.
///
/// A synthetic ledger gets an account and a category with unique marker names. The real app
/// root view then shows that ledger on every screen, and diagnostics are exported from it.
/// The markers must show on screen (so the scan isn't vacuous) and must never appear in the
/// process's console output, in the widget's shared file, in the diagnostics export, or in any
/// file written under the temporary, Logs or Caches folders outside the ledger's own folder.
@MainActor
@Test func ledgerDataNeverReachesTheConsoleOrStrayFiles() async throws {
  let markers = PrivacyMarkers()
  let started = Date()
  let console = try ConsoleCapture()
  var ledgerFolders: [URL] = []
  var shownOnScreen = false
  var exportedDiagnostics: Data?
  var widgetFiles: [Data] = []
  do {
    defer { _ = console.finish() }
    for destination in LedgerDemoTour.destinations {
      let mounted = try await MountedRoot(showing: destination, prepareLedger: markers.add)
      ledgerFolders.append(mounted.directory.standardizedFileURL)
      let text = mounted.accessibilityElements().map { "\($0.spokenName) \($0.value)" }
        .joined(separator: "\n")
      if markers.all.contains(where: text.contains) { shownOnScreen = true }
      let widget = mounted.directory.appendingPathComponent(RedactedWidgetProjectionStore.filename)
      if let data = try? Data(contentsOf: widget) { widgetFiles.append(data) }
      mounted.close()
    }
    // Diagnostics, exported the way the app does, from the same marked ledger.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "privacy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    ledgerFolders.append(folder.standardizedFileURL)
    let ledger = folder.appendingPathComponent("Demo Household.sqlite")
    try LedgerDemoTour.makeDemoLedger(at: ledger)
    try markers.add(to: ledger)
    let snapshot = try LedgerStoreLifecycle.open(at: ledger).store.readSnapshot()
    let export = folder.appendingPathComponent("diagnostics.json")
    try LedgerDiagnosticsWriter.write(.init(snapshot: snapshot), to: export)
    exportedDiagnostics = try Data(contentsOf: export)
  }
  let output = console.output
  print("PRIVACY console bytes \(output.count), widget files \(widgetFiles.count)")

  #expect(shownOnScreen, "the marker account never showed on screen, so the scan proves nothing")
  #expect(markers.found(in: output).isEmpty, "ledger data reached the console: \(markers.found(in: output))")
  for data in widgetFiles {
    #expect(markers.found(in: data).isEmpty, "ledger data reached the widget's shared file")
  }
  let diagnostics = try #require(exportedDiagnostics)
  #expect(diagnostics.count > 20, "the diagnostics export is empty")
  #expect(markers.found(in: diagnostics).isEmpty, "ledger data reached the diagnostics export")

  let home = FileManager.default.homeDirectoryForCurrentUser
  let roots = [
    FileManager.default.temporaryDirectory,
    home.appendingPathComponent("Library/Logs"),
    home.appendingPathComponent("Library/Caches"),
  ]
  var scanned = 0
  var leaks: [String] = []
  for root in roots {
    for file in filesWritten(under: root, since: started) {
      let path = file.standardizedFileURL.path
      if ledgerFolders.contains(where: { path.hasPrefix($0.path + "/") }) { continue }
      guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
      scanned += 1
      if !markers.found(in: data).isEmpty { leaks.append(path) }
    }
  }
  print("PRIVACY scanned \(scanned) files written during the test")
  #expect(leaks.isEmpty, "ledger data was written outside the ledger's folder: \(leaks)")
}

/// Leaving the device: the signed app's sandbox has no outgoing-network entitlement, so macOS
/// refuses any connection it tries to make. The one incoming one is the Local Web Access server.
@Test func theAppCannotOpenNetworkConnections() throws {
  let url = repositoryRoot().appendingPathComponent("LedgerAtlas.entitlements")
  let data = try Data(contentsOf: url)
  let entitlements = try #require(
    try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
  #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
  #expect(entitlements["com.apple.security.network.client"] == nil, "the app may connect out")
  let allowed: Set<String> = [
    "com.apple.security.app-sandbox", "com.apple.security.application-groups",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.files.bookmarks.app-scope", "com.apple.security.network.server",
  ]
  #expect(Set(entitlements.keys).subtracting(allowed).isEmpty, "new entitlements: review them")
}

/// Leaving the device, in the code: only the Local Web Access server touches the network, and
/// it listens on the loopback address only, so nothing off this Mac can reach it.
@Test func onlyTheLoopbackServerUsesTheNetwork() throws {
  let networkAPIs = [
    "URLSession", "URLRequest", "NWConnection(", "NWListener", "NWBrowser", "CFSocket",
    "CFStream", "socket(", "import Network", "WKWebView", "NSURLConnection",
  ]
  var users: Set<String> = []
  for (file, lines) in try shippedSources() {
    for line in lines where networkAPIs.contains(where: line.contains) {
      if !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { users.insert(file) }
    }
  }
  #expect(users == ["LedgerLoopbackPortal.swift"], "network code outside the loopback server: \(users)")
  let portal = try #require(try shippedSources().first { $0.0 == "LedgerLoopbackPortal.swift" })
  let source = portal.1.joined(separator: "\n")
  #expect(source.contains("host: .ipv4(.loopback)"), "the server no longer binds to loopback")
  #expect(!source.contains(".any"), "the server may listen on every address")
}

/// Logs: shipped code never writes to the console or the system log. Two exceptions, both
/// without ledger values: a debug-build line in LedgerStore (SQLite codes and errno), and the
/// demo tour's progress lines, which run only on a Mac with no ledgers and describe the
/// synthetic demo ledger.
@Test func shippedCodeDoesNotLog() throws {
  let logging = try Regex(
    #"(?<![A-Za-z_.])(print|NSLog|os_log|debugPrint|dump|fputs)\(|\bLogger\(|\bOSLog\(|FileHandle\.standard(Error|Output)"#)
  let allowed = ["[demo-tour]"]
  var offenders: [String] = []
  for (file, lines) in try shippedSources() {
    var debugDepth = 0
    for (index, line) in lines.enumerated() {
      let code = line.trimmingCharacters(in: .whitespaces)
      if code.hasPrefix("#if DEBUG") { debugDepth += 1 }
      if code.hasPrefix("#endif"), debugDepth > 0 { debugDepth -= 1 }
      if code.hasPrefix("//") || debugDepth > 0 { continue }
      if code.contains(logging), !allowed.contains(where: code.contains) {
        offenders.append("\(file):\(index + 1): \(code)")
      }
    }
  }
  #expect(offenders.isEmpty, "\(offenders)")
}

// MARK: - Helpers

/// Made-up values that appear nowhere else, and the ledger rows that carry them.
private struct PrivacyMarkers: Sendable {
  let account = "Marker Account Q7X3VZ"
  let category = "Marker Category Q7X3VZ"
  var all: [String] { [account, category] }

  func found(in data: Data) -> [String] {
    let text = String(decoding: data, as: UTF8.self)
    return all.filter { text.contains($0) || text.contains("Q7X3VZ") }
  }

  func found(in text: String) -> [String] { found(in: Data(text.utf8)) }

  func add(to ledger: URL) throws {
    let store = try LedgerStoreLifecycle.open(at: ledger).store
    let app = LedgerApplication(store: store)
    let origin = try LedgerOrigin(id: hash("privacy-origin"), label: "local")
    try app.createAccount(
      LedgerAccount(
        id: StableLedgerID.account(origin: origin, localKey: hash("privacy-account")),
        name: account, currencyUnit: "INR", origin: origin, groupID: nil, displayOrder: 9,
        hidden: false, variant: .standard))
    try app.createCategory(
      LedgerCategory(
        id: StableLedgerID.category(origin: origin, localKey: hash("privacy-category")),
        name: category, kind: .expense, origin: origin, parentID: nil))
  }

  private func hash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// Sends this process's stdout and stderr into a pipe while the test runs, keeps a copy, and
/// passes everything on to the real console when it finishes.
private final class ConsoleCapture: @unchecked Sendable {
  private let pipe = Pipe()
  private let savedOut: Int32
  private let savedErr: Int32
  private let lock = NSLock()
  private var captured = Data()
  private var finished = false
  private let reader: Thread

  init() throws {
    fflush(stdout)
    fflush(stderr)
    savedOut = dup(STDOUT_FILENO)
    savedErr = dup(STDERR_FILENO)
    let write = pipe.fileHandleForWriting.fileDescriptor
    dup2(write, STDOUT_FILENO)
    dup2(write, STDERR_FILENO)
    let handle = pipe.fileHandleForReading
    let box = Box()
    reader = Thread {
      while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        box.owner?.append(chunk)
      }
    }
    box.owner = self
    reader.start()
  }

  private final class Box: @unchecked Sendable { weak var owner: ConsoleCapture? }

  private func append(_ chunk: Data) {
    lock.withLock { captured.append(chunk) }
    _ = chunk.withUnsafeBytes { write(savedOut, $0.baseAddress, chunk.count) }
  }

  var output: Data { lock.withLock { captured } }

  /// Puts the console back. Safe to call more than once.
  @discardableResult
  func finish() -> Data {
    lock.lock()
    let alreadyDone = finished
    finished = true
    lock.unlock()
    if !alreadyDone {
      fflush(stdout)
      fflush(stderr)
      dup2(savedOut, STDOUT_FILENO)
      dup2(savedErr, STDERR_FILENO)
      try? pipe.fileHandleForWriting.close()
      // Let the reader drain what is left in the pipe.
      let deadline = Date().addingTimeInterval(2)
      while !reader.isFinished, Date() < deadline { usleep(10_000) }
      close(savedOut)
      close(savedErr)
    }
    return output
  }
}

private func filesWritten(under root: URL, since date: Date) -> [URL] {
  let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
  guard
    let files = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants])
  else { return [] }
  var result: [URL] = []
  while let file = files.nextObject() as? URL {
    guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
      let modified = values.contentModificationDate, modified >= date,
      (values.fileSize ?? 0) < 50_000_000
    else { continue }
    result.append(file)
  }
  return result
}

private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// Every Swift file the app ships: the app, its UI, the widget, the core and the store. The
/// command-line tools are left out: printing is their job.
private func shippedSources() throws -> [(String, [String])] {
  let modules = ["LedgerAtlasMac", "LedgerAtlasMacUI", "LedgerAtlasWidget", "LedgerCore", "LedgerStore"]
  var result: [(String, [String])] = []
  for module in modules {
    let folder = repositoryRoot().appendingPathComponent("Sources/\(module)")
    let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
    while let file = files?.nextObject() as? URL {
      guard file.pathExtension == "swift" else { continue }
      result.append(
        (file.lastPathComponent,
         try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")))
    }
  }
  return result
}
