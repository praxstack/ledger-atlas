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
/// A synthetic ledger gets an account, a category and a transaction note with unique marker
/// names. The real app root view then shows that ledger on every screen, and diagnostics are
/// exported from it. A marker must show on every screen, and the note on the ledger screen's
/// rows (so the scan isn't vacuous), and the markers must never appear in the
/// process's console output, in the widget's shared file, in the diagnostics export, or in any
/// file written under the temporary, Logs, Caches, Preferences or Application Support folders
/// outside the ledger's own folder.
///
/// The console capture redirects the whole process's stdout and stderr, including the test
/// reporter's, so this relies on the serial run (`swift test --no-parallel`, as CI runs it).
@MainActor
@Test func ledgerDataNeverReachesTheConsoleOrStrayFiles() async throws {
  let markers = PrivacyMarkers()
  let started = Date()
  let console = try ConsoleCapture()
  var ledgerFolders: [URL] = []
  var screensWithoutMarker: [String] = []
  var noteShownInLedger = false
  var exportedDiagnostics: Data?
  var widgetFiles: [Data] = []
  do {
    defer { _ = console.finish() }
    for destination in LedgerDemoTour.destinations {
      // In-process Accessibility reads, as the capture set uses: reading this process's own
      // windows through the system API on every screen made AppKit stop the main run loop
      // over and over (20 times, the keep-alive's cap) and lay out from the reader thread.
      let mounted = try await MountedRoot(
        showing: destination, readsInProcess: true, prepareLedger: markers.add)
      ledgerFolders.append(mounted.directory.standardizedFileURL)
      let text = mounted.accessibilityElements().map { "\($0.spokenName) \($0.value)" }
        .joined(separator: "\n")
      if !markers.all.contains(where: text.contains) { screensWithoutMarker.append(destination.rawValue) }
      if destination == .ledger, text.contains(markers.note) { noteShownInLedger = true }
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

  #expect(screensWithoutMarker.isEmpty, "no marker on screen \(screensWithoutMarker), so the scan proves nothing there")
  #expect(noteShownInLedger, "the marker transaction never showed in the ledger rows, so the scan proves nothing")
  #expect(markers.found(in: output).isEmpty, "ledger data reached the console: \(markers.found(in: output))")
  for data in widgetFiles {
    #expect(markers.found(in: data).isEmpty, "ledger data reached the widget's shared file")
  }
  let diagnostics = try #require(exportedDiagnostics)
  #expect(diagnostics.count > 20, "the diagnostics export is empty")
  #expect(markers.found(in: diagnostics).isEmpty, "ledger data reached the diagnostics export")

  let home = FileManager.default.homeDirectoryForCurrentUser
  // Where an app's stray writes land: temp files, logs, caches, preferences (UserDefaults)
  // and Application Support (app and app-group containers).
  let roots = [
    FileManager.default.temporaryDirectory,
    home.appendingPathComponent("Library/Logs"),
    home.appendingPathComponent("Library/Caches"),
    home.appendingPathComponent("Library/Preferences"),
    home.appendingPathComponent("Library/Application Support"),
  ]
  var scanned = 0
  var leaks: [String] = []
  for root in roots {
    for file in filesWritten(under: root, since: started) {
      let path = file.standardizedFileURL.path
      if ledgerFolders.contains(where: { path.hasPrefix($0.path + "/") }) { continue }
      // Read, not mapped: another process truncating a cache or temp file would fault a mapping.
      guard let data = try? Data(contentsOf: file) else { continue }
      scanned += 1
      if !markers.found(in: data).isEmpty { leaks.append(path) }
    }
  }
  print("PRIVACY scanned \(scanned) files written during the test")
  #expect(leaks.isEmpty, "ledger data was written outside the ledger's folder: \(leaks)")
}

/// Leaving the device: the signed app's and widget's sandboxes have no outgoing-network
/// entitlement, so macOS refuses any connection they try to make. The one incoming one is the
/// app's Local Web Access server.
@Test(arguments: ["LedgerAtlas.entitlements", "LedgerAtlasWidget.entitlements"])
func theAppCannotOpenNetworkConnections(_ file: String) throws {
  let url = repositoryRoot().appendingPathComponent(file)
  let data = try Data(contentsOf: url)
  let entitlements = try #require(
    try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
  #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true, "\(file): sandbox off")
  #expect(entitlements["com.apple.security.network.client"] == nil, "\(file): may connect out")
  var allowed: Set<String> = ["com.apple.security.app-sandbox", "com.apple.security.application-groups"]
  if file == "LedgerAtlas.entitlements" {
    allowed.formUnion([
      "com.apple.security.files.user-selected.read-write",
      "com.apple.security.files.bookmarks.app-scope", "com.apple.security.network.server",
    ])
  }
  #expect(Set(entitlements.keys).subtracting(allowed).isEmpty, "\(file): new entitlements, review them")
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
  let anyAddress = try Regex(#"host:\s*\.any\b|\.ipv[46]\(\.any\)|IPv[46]Address\.any\b|Host\.any\b|host:\s*nil"#)
  #expect(!source.contains(anyAddress), "the server may listen on every address")
}

/// Logs: shipped code never writes to the console, and writes to the system log only fixed
/// status words, never a value from the ledger. Allowed: the demo tour's progress lines, which
/// run only on a Mac with no ledgers and describe the synthetic demo ledger; `Logger`
/// declarations (they log nothing by themselves); and log calls whose message is a literal with
/// no interpolation, plus the listed exceptions.
@Test func shippedCodeDoesNotLogLedgerData() throws {
  let console = try Regex(
    #"(^|[^A-Za-z0-9_.])(print|NSLog|os_log|debugPrint|dump|fputs)\(|\bOSLog\(|FileHandle\.standard(Error|Output)"#)
  let logCall = try Regex(#"\b\w*[lL]og(ger)?\.(log|trace|debug|info|notice|warning|error|critical|fault)\("#)
  let allowedConsole = ["[demo-tour]"]
  // Log calls that interpolate, each with why it carries no ledger value.
  let allowedInterpolation = [
    // The operation name ("create" or "open") is public; the error's description, which for a
    // file error carries the ledger's path, is `privacy: .private`, so the system log redacts it.
    "LedgerAtlasRootView.swift: lifecycleLog.error(",
    // The widget status name is public; the error's description, which for a file error
    // carries the App Group container's path (with the user's name), is `privacy: .private`.
    "LedgerAtlasRootView.swift: LedgerWidgetAvailability.log.error(",
  ]
  var offenders: [String] = []
  for (file, lines) in try shippedSources() {
    // Each open `#if`, and whether the branch the scan is in is debug-only. `#else` after
    // `#if DEBUG` is release code; `#else` after `#if !DEBUG` is debug code.
    struct Branch { var debugOnly: Bool; var elseIsDebug: Bool }
    var branches: [Branch] = []
    for (index, line) in lines.enumerated() {
      let code = line.trimmingCharacters(in: .whitespaces)
      func condition(after prefix: String) -> String {
        code.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
      }
      if code.hasPrefix("#if ") {
        let condition = condition(after: "#if ")
        branches.append(Branch(debugOnly: condition == "DEBUG", elseIsDebug: condition == "!DEBUG"))
      } else if code.hasPrefix("#elseif "), !branches.isEmpty {
        branches[branches.count - 1].debugOnly = condition(after: "#elseif ") == "DEBUG"
      } else if code.hasPrefix("#else"), !branches.isEmpty {
        branches[branches.count - 1].debugOnly = branches[branches.count - 1].elseIsDebug
      } else if code.hasPrefix("#endif"), !branches.isEmpty {
        branches.removeLast()
      }
      if code.hasPrefix("//") || branches.contains(where: \.debugOnly) { continue }
      if code.contains(console), !allowedConsole.contains(where: code.contains) {
        offenders.append("\(file):\(index + 1): \(code)")
      }
      if code.contains(logCall) {
        // The message may start on the next line.
        let statement = lines[index..<min(index + 3, lines.count)].joined(separator: " ")
        let interpolates = statement.contains("\\(")
        if interpolates, !allowedInterpolation.contains(where: { "\(file): \(code)".hasPrefix($0) }) {
          offenders.append("\(file):\(index + 1): log message interpolates a value: \(code)")
        }
        // Even an allowed message must keep an error's description private.
        if statement.contains("String(describing: error), privacy: .public") {
          offenders.append("\(file):\(index + 1): an error's description is logged publicly")
        }
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
  let note = "Marker Memo Q7X3VZ"
  var all: [String] { [account, category, note] }

  func found(in data: Data) -> [String] {
    let text = String(decoding: data, as: UTF8.self)
    return all.filter { text.contains($0) || text.contains("Q7X3VZ") }
  }

  func found(in text: String) -> [String] { found(in: Data(text.utf8)) }

  func add(to ledger: URL) throws {
    let store = try LedgerStoreLifecycle.open(at: ledger).store
    let app = LedgerApplication(store: store)
    let origin = try LedgerOrigin(id: hash("privacy-origin"), label: "local")
    let accountID = try StableLedgerID.account(origin: origin, localKey: hash("privacy-account"))
    try app.createAccount(
      LedgerAccount(
        id: accountID, name: account, currencyUnit: "INR", origin: origin, groupID: nil,
        displayOrder: 9, hidden: false, variant: .standard))
    let categoryID = try StableLedgerID.category(origin: origin, localKey: hash("privacy-category"))
    try app.createCategory(
      LedgerCategory(id: categoryID, name: category, kind: .expense, origin: origin, parentID: nil))
    // One expense inside the demo ledger's months, so it sits among the ledger's rows.
    let occurredAt = try SourceTemporal(
      resolving: SourceLocalDateTime(
        date: SourceLocalDate(year: 2026, month: 10, day: 20), hour: 12, minute: 0, second: 0,
        millisecond: 0),
      in: try SourceTimeZone(ianaIdentifier: "Asia/Kolkata"), precision: .minute,
      ambiguityPolicy: .reject)
    let draft = try LedgerTransactionDraft(
      effects: [
        try LedgerTransactionEffect(
          accountID: accountID, direction: .decrease,
          amount: try CurrencyAmount(unitCode: "INR", amount: try ExactDecimal("123.45")))
      ], categoryID: categoryID, kind: .expense, occurredAt: occurredAt, note: note, origin: origin)
    _ = try app.createTransaction(
      idempotencyKey: hash("privacy-transaction"), draft: draft,
      createdAt: UTCInstant(epochMilliseconds: 1_790_000_100_000))
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
      // Let the reader drain what is left in the pipe. The saved descriptors stay open while
      // it may still forward to them; if it never finishes, leaking two descriptors is safer
      // than writing to a closed one.
      let deadline = Date().addingTimeInterval(5)
      while !reader.isFinished, Date() < deadline { usleep(10_000) }
      if reader.isFinished {
        close(savedOut)
        close(savedErr)
      }
    }
    return output
  }
}

private func filesWritten(under root: URL, since date: Date) -> [URL] {
  let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
  guard
    let files = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: keys)
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
