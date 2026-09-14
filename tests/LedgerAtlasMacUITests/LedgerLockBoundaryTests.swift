import AppKit
import Foundation
import SwiftUI
import Testing
import Vision

@testable import LedgerAtlasMacUI

// This observes the real hosted root's rendered text. It supplements, but does not
// assert, keyboard/VoiceOver interaction or other processes' widget/intent surfaces.
@MainActor
@Test func nativeLockBoundaryProtectsSettingsAndSyntheticContentAcrossRestart() async throws {
  _ = NSApplication.shared
  let suite = "LedgerAtlasMacUITests.lock.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let bookmarks = SecurityScopedBookmarkStore(
    defaults: defaults, makeBookmark: { _ in Data() }, resolveBookmark: { _ in
      throw LedgerAppLock.Error.storageFailure
    })
  let widgetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: widgetDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: widgetDirectory) }
  let widgetPublisher = RedactedWidgetProjectionPublisher(store: .init(containerURL: widgetDirectory))
  var storage: [String: Data] = [:]
  let reader: LedgerAppLock.Reader = { storage[$0] }
  let writer: LedgerAppLock.Writer = { storage[$0] = $1 }
  let original = LedgerAppLock(reader: reader, writer: writer)
  try original.setPasscode("synthetic-correct")
  original.lock()
  let summary = ImportReviewSummary(workspaceReviewJSON: Data("""
    {"reportVersion":1,"status":"prepared","classificationStatus":"supported",
     "container":"sqlite","diagnosticCodes":[],"tableCount":1,"recordCount":1,
     "fieldCount":1,"mappedCount":4,"preservedCount":0,"excludedCount":0,
     "blockingCount":0,"profileID":"Synthetic Lock Marker"}
    """.utf8))
  #expect(summary.visibleText.contains("Synthetic Lock Marker"))

  for destination in [AppDestination.settings, .importReview] {
    // Both the existing instance and a fresh instance after an authenticated session
    // must shield Settings and the injected content when a root is mounted.
    for restarted in [false, true] {
      let lock = restarted
        ? LedgerAppLock(reader: reader, writer: writer, authenticate: { false }) : original
      lock.lock()
      let view = LedgerAtlasRootView(
        initialSelection: destination, importReviewSummary: summary,
        appLock: lock, productSettings: .init(), bookmarkStore: bookmarks,
        widgetProjectionPublisher: widgetPublisher)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1000),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: view)
      window.makeKeyAndOrderFront(nil)
      defer { window.close() }
      var text = try await waitForRenderedText("Ledger Atlas is locked", in: window)
      #expect(text.contains("Passcode"))
      #expect(!text.contains("Application lock"))
      #expect(!text.contains("Synthetic Lock Marker"))
      #expect(!lock.unlock(with: "wrong"))
      text = try await waitForRenderedText("Ledger Atlas is locked", in: window)
      #expect(!text.contains("Synthetic Lock Marker"))
      #expect(lock.unlock(with: "synthetic-correct"))
      text = try await waitForRenderedText(
        destination == .settings ? "Application lock" : "Synthetic Lock Marker", in: window)
      #expect(!text.contains("Ledger Atlas is locked"))
      if destination == .settings { #expect(text.contains("Enabled")) }
      window.close()
    }
  }
}

@MainActor
private func waitForRenderedText(_ expected: String, in window: NSWindow) async throws -> String {
  var text = ""
  for _ in 0..<30 {
    try await Task.sleep(for: .milliseconds(100))
    guard let view = window.contentView else { continue }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let image = bitmap.cgImage else { continue }
    // Vision work must not stall the app actor or other native responsiveness checks.
    text = try await Task.detached {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
      return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
    }.value
    if text.contains(expected) { return text }
  }
  Issue.record("Native rendered text omitted \(expected); observed: \(text)")
  return text
}
