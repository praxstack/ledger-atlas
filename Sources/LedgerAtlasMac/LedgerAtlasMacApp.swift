import AppKit
import LedgerAtlasMacUI
import SwiftUI

@main
struct LedgerAtlasMacApp: App {
  @NSApplicationDelegateAdaptor(LedgerAtlasAppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup("Ledger Atlas") {
      LedgerAtlasRootView()
    }
    .defaultSize(width: 980, height: 680)
  }
}

private final class LedgerAtlasAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
    guard let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: RedactedWidgetProjectionStore.appGroupIdentifier)
    else { return }
    let projectionStore = RedactedWidgetProjectionStore(containerURL: containerURL)
    if !FileManager.default.fileExists(atPath: projectionStore.url.path) {
      try? projectionStore.write(.empty)
    }
  }
}
