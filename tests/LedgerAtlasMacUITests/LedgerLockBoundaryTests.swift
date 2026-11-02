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
      let window = UnconstrainedTestWindow(
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

/// CI Mac runners have a small virtual display. A normal window gets shrunk to fit it,
/// which clips the lock screen text before OCR reads it. Keep the requested size.
private final class UnconstrainedTestWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

@MainActor
private func waitForRenderedText(_ expected: String, in window: NSWindow) async throws -> String {
  var text = ""
  var lastImages: [CGImage] = []
  for _ in 0..<30 {
    try await Task.sleep(for: .milliseconds(100))
    guard let view = window.contentView else { continue }
    view.layoutSubtreeIfNeeded()
    // Two captures of the same hosted view: AppKit's cached display, and the layer tree
    // rendered in software. On GPU-less CI runners the first can miss layer-backed
    // SwiftUI text, so read both and use everything either one shows.
    let images = [cachedDisplayImage(of: view)].compactMap { $0 } + layerImages(of: view)
    guard !images.isEmpty else { continue }
    lastImages = images
    var observed: [String] = []
    for image in images {
      // Vision work must not stall the app actor or other native responsiveness checks.
      observed.append(try await Task.detached { try recognizedText(in: image) }.value)
    }
    text = observed.joined(separator: "\n")
    if text.contains(expected) { return text }
  }
  for image in lastImages { saveDiagnosticImage(image, named: expected) }
  Issue.record("Native rendered text omitted \(expected); observed: \(text)")
  return text
}

@MainActor
private func cachedDisplayImage(of view: NSView) -> CGImage? {
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
  view.cacheDisplay(in: view.bounds, to: bitmap)
  return bitmap.cgImage
}

/// The layer tree rendered in software, once as-is and once flipped vertically, because
/// whether AppKit marks this layer geometry as flipped varies; OCR only reads upright text.
@MainActor
private func layerImages(of view: NSView) -> [CGImage] {
  guard let layer = view.layer else { return [] }
  let scale = view.window?.backingScaleFactor ?? 2
  let width = Int(view.bounds.width * scale)
  let height = Int(view.bounds.height * scale)
  guard width > 0, height > 0 else { return [] }
  return [false, true].compactMap { flip in
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if flip {
      context.translateBy(x: 0, y: CGFloat(height))
      context.scaleBy(x: 1, y: -1)
    }
    context.scaleBy(x: scale, y: scale)
    layer.render(in: context)
    return context.makeImage()
  }
}

private func recognizedText(in image: CGImage) throws -> String {
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
  return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    .joined(separator: "\n")
}

/// When LEDGER_ATLAS_TEST_ARTIFACTS is set (CI does), keep the last capture of a failed
/// lookup so a rendering problem on a runner can be seen instead of guessed.
private func saveDiagnosticImage(_ image: CGImage?, named name: String) {
  guard let image, let directory = ProcessInfo.processInfo.environment["LEDGER_ATLAS_TEST_ARTIFACTS"]
  else { return }
  let folder = URL(fileURLWithPath: directory, isDirectory: true)
  try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let safeName = name.replacingOccurrences(of: " ", with: "-")
  let url = folder.appendingPathComponent("lock-\(safeName)-\(UUID().uuidString.prefix(8)).png")
  let rep = NSBitmapImageRep(cgImage: image)
  try? rep.representation(using: .png, properties: [:])?.write(to: url)
}
