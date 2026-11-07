import AppKit
import LedgerAtlasMacUI
import SwiftUI

@main
struct LedgerAtlasMacApp: App {
  @NSApplicationDelegateAdaptor(LedgerAtlasAppDelegate.self) private var appDelegate

  var body: some Scene {
    // One window only. Each root view owns its own lock, session and save queue, so a second
    // window (File > New Window, or state restoration) would stay readable after "Lock now" in
    // the first and race it for the ledger's write lease (#179). `Window` has no New Window
    // command and restores a single window.
    Window("Ledger Atlas", id: "main") {
      LedgerAtlasRootView()
    }
    .defaultSize(width: 980, height: 680)
    .commands {
      CommandGroup(after: .newItem) {
        Button("New Ledger…") {
          NotificationCenter.default.post(
            name: LedgerAtlasRootView.createLedgerRequested, object: nil)
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        Button("Open Ledger…") {
          NotificationCenter.default.post(
            name: LedgerAtlasRootView.openLedgerRequested, object: nil)
        }
        .keyboardShortcut("o", modifiers: .command)
        Divider()
        Button("Import Money Manager Backup…") {
          NotificationCenter.default.post(
            name: LedgerAtlasRootView.importBackupRequested, object: nil)
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
      }
      LedgerHideAmountsCommands()
      LedgerViewExportCommands()
    }
  }
}

private final class LedgerAtlasAppDelegate: NSObject, NSApplicationDelegate {
  /// Quit waits for an import, upgrade or restore to finish instead of cutting it off (#178).
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    MainActor.assumeIsolated { LedgerQuitGuard.shared.terminateReply() }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
    // Opening the daily reminder opens the entry form with Upcoming beside it (#171).
    LedgerReminderResponder.shared.install()
    // The widget's first status. A build without a usable App Group (the ad-hoc DMG) skips it.
    guard LedgerWidgetAvailability.signingTeamIdentifier() != nil,
      let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: RedactedWidgetProjectionStore.appGroupIdentifier)
    else { return }
    let projectionStore = RedactedWidgetProjectionStore(containerURL: containerURL)
    if !FileManager.default.fileExists(atPath: projectionStore.url.path) {
      try? projectionStore.write(.empty)
    }
  }
}
