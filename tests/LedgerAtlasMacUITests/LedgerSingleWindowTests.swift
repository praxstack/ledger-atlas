import Foundation
import Testing

// Each `LedgerAtlasRootView` owns its own `LedgerAppLock`, session and save queue. A second
// window would be a second, independently unlocked copy of the ledger, so "Lock now" in one
// window would leave the other readable (#179). The app therefore declares a single `Window`
// scene, which has no File > New Window command and restores one window at launch.
@Test func theAppHasExactlyOneWindowSoOneLockGuardsTheLedger() throws {
  let app = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/LedgerAtlasMac/LedgerAtlasMacApp.swift")
  let code = try String(contentsOf: app, encoding: .utf8)
    .components(separatedBy: "\n")
    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    .joined(separator: "\n")
  #expect(code.contains("Window(\"Ledger Atlas\", id: \"main\")"))
  for multiWindowScene in ["WindowGroup", "DocumentGroup", "openWindow", "newDocument"] {
    #expect(!code.contains(multiWindowScene), "\(multiWindowScene) would allow a second window")
  }
}
