import AppKit
import ApplicationServices
import Foundation
import LedgerCore
import LedgerStore
import SwiftUI
import Testing

@testable import LedgerAtlasMacUI

// Synthetic data only: every screen shows the made-up demo ledger.

/// MACV2-21 (#57): every screen, with a ledger open, gives each control a name VoiceOver can
/// speak. It reads the tree through the macOS Accessibility API, the same one VoiceOver uses,
/// from the real root view hosted in a window.
@MainActor
@Test(arguments: LedgerDemoTour.destinations)
func everyControlOnEveryScreenHasAVoiceOverLabel(_ destination: AppDestination) async throws {
  let mounted = try await MountedRoot(showing: destination)
  defer { mounted.close() }
  let elements = mounted.accessibilityElements()
  let summary = Dictionary(grouping: elements, by: \.role).mapValues(\.count)
    .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
  print("A11Y \(destination.rawValue): \(elements.count) elements (in process \(mounted.inProcessCount())): \(summary)")
  #expect(elements.count > 5, "\(destination) exposed almost nothing to VoiceOver")
  let unlabeled = elements.filter { $0.isControl && $0.spokenName.isEmpty }
  for element in unlabeled {
    print("A11Y UNLABELED \(destination.rawValue): \(element.debugDescription)")
  }
  #expect(unlabeled.isEmpty, "\(destination): \(unlabeled.map(\.debugDescription))")
}

/// One accessibility element as VoiceOver sees it.
struct SpokenElement: Sendable {
  let role: String
  let subrole: String
  let label: String
  let title: String
  let value: String
  let placeholder: String
  let identifier: String

  static let controlRoles: Set<String> = [
    kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole,
    kAXTextFieldRole, kAXSliderRole, kAXComboBoxRole, kAXIncrementorRole, kAXDisclosureTriangleRole,
    kAXTextAreaRole, "AXLink",
  ]

  var isControl: Bool { Self.controlRoles.contains(role) }

  /// What VoiceOver reads as the element's name.
  var spokenName: String {
    [label, title, placeholder].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
  }

  var debugDescription: String {
    "\(role)/\(subrole) label=\(label.debugDescription) title=\(title.debugDescription) "
      + "value=\(value.prefix(40).debugDescription) id=\(identifier.debugDescription)"
  }
}

/// Reads this process's windows through the Accessibility API. It must run off the main
/// thread: the app answers these requests on its main run loop, so a call made from the main
/// thread can't complete.
func accessibilityTree(of pid: pid_t) -> [SpokenElement] {
  let app = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(app, 5)
  func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
  }
  func text(_ element: AXUIElement, _ name: String) -> String {
    guard let value = attribute(element, name) else { return "" }
    return (value as? String) ?? "\(value)"
  }
  var found: [SpokenElement] = []
  func visit(_ element: AXUIElement, depth: Int) {
    guard depth < 80 else { return }
    found.append(
      SpokenElement(
        role: text(element, kAXRoleAttribute), subrole: text(element, kAXSubroleAttribute),
        label: text(element, kAXDescriptionAttribute), title: text(element, kAXTitleAttribute),
        value: text(element, kAXValueAttribute),
        placeholder: text(element, kAXPlaceholderValueAttribute),
        identifier: text(element, kAXIdentifierAttribute)))
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
      visit(child, depth: depth + 1)
    }
  }
  var windows: CFTypeRef?
  let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
  if status != .success { print("A11Y windows attribute failed: \(status.rawValue)") }
  for window in (windows as? [AXUIElement]) ?? [] {
    visit(window, depth: 0)
  }
  return found
}

/// The root view in a window with the synthetic demo ledger open on one screen.
@MainActor
final class MountedRoot {
  let window: NSWindow
  private let directory: URL
  private let suite: String

  init(showing destination: AppDestination, appearance: NSAppearance.Name? = nil) async throws {
    Self.launchOnce()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "a11y-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let ledger = directory.appendingPathComponent("Demo Household.sqlite")
    try LedgerDemoTour.makeDemoLedger(at: ledger)
    suite = "LedgerAtlasMacUITests.a11y.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let bookmarks = SecurityScopedBookmarkStore(
      defaults: defaults, makeBookmark: { Data($0.path.utf8) },
      resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) })
    try bookmarks.save(ledger, for: .canonicalLedger)
    let lock = LedgerAppLock(reader: { _ in nil }, writer: { _, _ in }, kdfIterations: 1_000)
    let root = LedgerAtlasRootView(
      initialSelection: destination, appLock: lock,
      productSettings: .init(startScreen: destination), bookmarkStore: bookmarks,
      scopeStarter: { _ in true }, scopeStopper: { _ in })
    window = FullSizeTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    if let appearance { window.appearance = NSAppearance(named: appearance) }
    window.contentView = NSHostingView(rootView: root)
    window.makeKeyAndOrderFront(nil)
    // Wait for the ledger to open and the screen to settle.
    var previous = -1
    for _ in 0..<30 {
      try await Task.sleep(for: .milliseconds(200))
      window.contentView?.layoutSubtreeIfNeeded()
      let count = accessibilityElements().count
      if count == previous, count > 5 { break }
      previous = count
    }
  }

  /// The test runner never finishes launching an app, so the Accessibility server that answers
  /// VoiceOver isn't registered yet. Do it once.
  private static var launched = false
  private static func launchOnce() {
    guard !launched else { return }
    launched = true
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.finishLaunching()
  }

  /// The same tree walked in process, for comparison in the log.
  func inProcessCount() -> Int {
    func count(_ element: Any, _ depth: Int) -> Int {
      guard depth < 80, let node = element as? NSObject else { return 0 }
      let selector = Selector(("accessibilityChildren"))
      guard node.responds(to: selector) else { return 1 }
      let children = node.perform(selector)?.takeUnretainedValue() as? [Any] ?? []
      return 1 + children.reduce(0) { $0 + count($1, depth + 1) }
    }
    return count(window, 0)
  }

  func close() {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
    UserDefaults.standard.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }

  /// Every element in this window's tree, read the way VoiceOver reads it.
  /// The test runner doesn't run the main run loop, and the app answers Accessibility requests
  /// there, so pump it until the background read finishes.
  func accessibilityElements() -> [SpokenElement] {
    let pid = ProcessInfo.processInfo.processIdentifier
    let result = TreeBox()
    Thread.detachNewThread { result.finish(accessibilityTree(of: pid)) }
    let deadline = Date().addingTimeInterval(20)
    while !result.isDone, Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return result.elements
  }
}

/// Hands the tree from the reader thread back to the main thread.
final class TreeBox: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  private var found: [SpokenElement] = []
  var isDone: Bool { lock.withLock { done } }
  var elements: [SpokenElement] { lock.withLock { found } }
  func finish(_ elements: [SpokenElement]) { lock.withLock { found = elements; done = true } }
}

/// CI runners have a small virtual display; keep the requested window size.
private final class FullSizeTestWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

/// Reduce Motion: every animation in the app goes through `MotionPolicy`, which drops it when
/// Reduce Motion is on (`MotionPolicyTests`). A new animation added without it fails here.
@Test func everyAnimationInTheAppGoesThroughMotionPolicy() throws {
  let sources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources")
  let animationAPIs = [
    "withAnimation", ".animation(", ".transition(", "repeatForever", ".symbolEffect(",
    ".contentTransition(", "matchedGeometryEffect", ".phaseAnimator", ".keyframeAnimator",
  ]
  var checked = 0
  var offenders: [String] = []
  let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
  while let file = files?.nextObject() as? URL {
    guard file.pathExtension == "swift", file.lastPathComponent != "MotionPolicy.swift" else {
      continue
    }
    let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
    for (index, line) in lines.enumerated()
    where animationAPIs.contains(where: line.contains) && !line.contains("//") {
      checked += 1
      // The animation value must come from MotionPolicy on the same or the next two lines.
      let window = lines[index..<min(index + 3, lines.count)].joined(separator: " ")
      if !window.contains("MotionPolicy.") {
        offenders.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
      }
    }
  }
  #expect(checked > 0, "no animations found; is the Sources path right?")
  #expect(offenders.isEmpty, "\(offenders)")
}

