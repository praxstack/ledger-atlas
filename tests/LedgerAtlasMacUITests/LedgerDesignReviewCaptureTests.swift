import AppKit
import Foundation
import LedgerCore
import SwiftUI
import Testing

@testable import LedgerAtlasMacUI

// Synthetic data only: every capture shows the made-up demo ledger.

/// The design-review set: every screen a person reaches from the sidebar, the Transactions
/// screen with a row selected and its inspector open, the welcome screen and the lock screen,
/// each in light and dark, with the window active so the title bar, toolbar and selection show
/// as they do in use. These feed the screenshot council and the before/after page.
///
/// The PNGs and an index go to `$LEDGER_ATLAS_TEST_ARTIFACTS/design-review`, which CI uploads
/// as the `design-review` artifact. Each capture is checked the same way as the traceability
/// set: not blank, light and dark differ, and no home-folder path on screen.
@MainActor
@Test func designReviewCaptureSet() async throws {
  let output = try reviewDirectory()
  var index: [[String: String]] = []

  func record(
    _ root: MountedRoot, _ name: String, note: String, after prepare: () -> Void = {}
  ) throws {
    var pair: [Data] = []
    for appearance in CaptureAppearance.allCases {
      root.window.appearance = NSAppearance(named: appearance.name)
      activate(root.window)
      prepare()
      pump(0.8)
      let (png, method) = try #require(windowPNG(root.window), "\(name) could not be captured")
      let text = root.accessibilityElements().map { "\($0.spokenName) \($0.value)" }
      expectUsableReviewCapture(png, text: text, for: name)
      let file = "\(name)-\(appearance.rawValue).png"
      try png.write(to: output.appendingPathComponent(file))
      index.append([
        "file": file, "screen": name, "appearance": appearance.rawValue, "note": note,
        "capture_method": method, "window_active": root.window.isKeyWindow ? "true" : "false",
      ])
      pair.append(png)
    }
    #expect(pair[0] != pair[1], "\(name): light and dark captures are identical")
  }

  for (number, destination) in LedgerDemoTour.destinations.enumerated() {
    let name = String(format: "%02d-%@", number + 1, destination.rawValue)
    log("review \(name)")
    let root = try await MountedRoot(
      showing: destination, size: captureSize, appWindow: true, readsInProcess: true)
    defer { root.close() }
    #expect(!root.showsNoLedgerPrompt, "\(destination) never showed the demo ledger")
    try record(root, name, note: "\(destination.sidebarTitle) with the demo ledger open.")

    if destination == .ledger {
      // The same screen with the first entry selected, so the inspector shows its details.
      // The inspector hides itself in a narrow window, so it is opened from the toolbar.
      let selected = selectFirstEntry(in: root.window)
      #expect(selected, "no entry row to select on the Transactions screen")
      if !root.accessibilityElements().contains(where: { $0.spokenName == "Hide inspector" }) {
        _ = root.click(named: "Show inspector")
      }
      try await root.settle()
      try record(
        root, String(format: "%02d-%@-inspector", number + 1, destination.rawValue),
        note: "Transactions with an entry selected and the inspector open.")
    }
  }

  log("review welcome")
  let welcome = try await MountedRoot(
    showing: .overview, withLedger: false, size: captureSize, appWindow: true, readsInProcess: true)
  defer { welcome.close() }
  try record(welcome, "18-welcome", note: "First launch: no ledger open yet.")

  let lock = LedgerAppLock(reader: { _ in nil }, writer: { _, _ in }, kdfIterations: 1_000)
  try lock.setPasscode("2468")
  lock.lock()
  log("review lock")
  let locked = try await MountedRoot(
    showing: .overview, appLock: lock, size: captureSize, appWindow: true, readsInProcess: true)
  defer { locked.close() }
  try record(locked, "19-locked", note: "App Lock on: ledger content hidden until unlock.")

  let data = try JSONSerialization.data(
    withJSONObject: ["captures": index, "window": ["width": 1000, "height": 700]],
    options: [.prettyPrinted, .sortedKeys])
  try data.write(to: output.appendingPathComponent("index.json"))
  #expect(index.count >= 2 * (LedgerDemoTour.destinations.count + 3))
}

// MARK: - Helpers

private func reviewDirectory() throws -> URL {
  let base =
    ProcessInfo.processInfo.environment["LEDGER_ATLAS_TEST_ARTIFACTS"].map {
      URL(fileURLWithPath: $0)
    } ?? FileManager.default.temporaryDirectory.appendingPathComponent("ledger-atlas-\(UUID())")
  let url = base.appendingPathComponent("design-review", isDirectory: true)
  try? FileManager.default.removeItem(at: url)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// Brings the app and the window to the front, so the window draws as the active one (full
/// title and toolbar colour, accent selection) instead of the dimmed inactive look.
@MainActor
private func activate(_ window: NSWindow) {
  NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
  NSApplication.shared.activate(ignoringOtherApps: true)
  window.makeKeyAndOrderFront(nil)
  window.makeMain()
  pump(0.2)
}

/// Selects the first entry row of the widest table that isn't the sidebar (the transactions
/// list), the way a click does. Returns false if there is no such row.
@MainActor
private func selectFirstEntry(in window: NSWindow) -> Bool {
  func tables(in view: NSView) -> [NSTableView] {
    ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables)
  }
  guard let content = window.contentView else { return false }
  let candidates = tables(in: content).filter { $0.numberOfRows > 0 }
  guard let table = candidates.max(by: { $0.bounds.width < $1.bounds.width }) else { return false }
  for row in 0..<table.numberOfRows {
    if table.delegate?.tableView?(table, isGroupRow: row) == true { continue }
    let rect = table.rect(ofRow: row)
    guard !rect.isEmpty else { continue }
    table.scrollRowToVisible(row)
    let location = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard
        let event = NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
      else { return false }
      window.sendEvent(event)
      pump(0.05)
    }
    pump(0.5)
    if table.selectedRow < 0 {
      // The click didn't land (for example the row moved); select it directly.
      table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      pump(0.3)
    }
    return table.selectedRow >= 0
  }
  return false
}

/// Not blank, not one colour, and no home-folder path. The design set has no per-screen
/// expectations: it shows whatever the screen shows, so the reviewers see the real state.
private func expectUsableReviewCapture(_ png: Data, text: [String], for name: String) {
  #expect(png.count > 20_000, "\(name): capture is only \(png.count) bytes; it looks blank")
  if let image = NSBitmapImageRep(data: png) {
    var seen = Set<UInt32>()
    let step = max(1, min(image.pixelsWide, image.pixelsHigh) / 40)
    for x in stride(from: 0, to: image.pixelsWide, by: step) {
      for y in stride(from: 0, to: image.pixelsHigh, by: step) {
        guard let colour = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        let r = UInt32(colour.redComponent * 255), g = UInt32(colour.greenComponent * 255)
        let b = UInt32(colour.blueComponent * 255)
        seen.insert(r << 16 | g << 8 | b)
      }
    }
    #expect(seen.count > 8, "\(name): capture is almost one colour")
  }
  #expect(!text.joined(separator: "\n").contains("/Users/"), "\(name): a home-folder path is on screen")
}
