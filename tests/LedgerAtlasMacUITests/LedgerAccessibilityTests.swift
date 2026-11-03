import ApplicationServices
import AppKit
import Foundation
import LedgerCore
import LedgerStore
import SwiftUI
import Testing

@testable import LedgerAtlasMacUI

// Synthetic data only: every screen shows the made-up demo ledger.

/// MACV2-21 (#57): every screen, with a ledger open, exposes a VoiceOver label for each
/// control. This reads the same accessibility tree VoiceOver reads, from the real root view
/// hosted in a window.
@MainActor
@Test(arguments: LedgerDemoTour.destinations)
func everyControlOnEveryScreenHasAVoiceOverLabel(_ destination: AppDestination) async throws {
  let mounted = try await MountedRoot(showing: destination)
  defer { mounted.close() }
  let elements = mounted.accessibilityElements()
  let summary = Dictionary(grouping: elements, by: \.role).mapValues(\.count)
    .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
  print("A11Y \(destination.rawValue): \(elements.count) elements: \(summary)")
  #expect(elements.count > 5, "\(destination) exposed almost nothing to VoiceOver")
  let unlabeled = elements.filter { $0.isControl && $0.spokenName.isEmpty }
  for element in unlabeled {
    print("A11Y UNLABELED \(destination.rawValue): \(element.debugDescription)")
  }
  #expect(unlabeled.isEmpty, "\(destination): \(unlabeled.map(\.debugDescription))")
}

/// One accessibility element as VoiceOver sees it.
struct SpokenElement {
  let role: String
  let subrole: String
  let label: String
  let title: String
  let value: String
  let placeholder: String
  let identifier: String

  static let controlRoles: Set<NSAccessibility.Role> = [
    .button, .checkBox, .radioButton, .popUpButton, .menuButton, .textField, .slider,
    .comboBox, .incrementor, .link, .disclosureTriangle, .textArea,
  ]

  var isControl: Bool { Self.controlRoles.map(\.rawValue).contains(role) }

  /// What VoiceOver reads as the element's name.
  var spokenName: String {
    [label, title, placeholder].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
  }

  var debugDescription: String {
    "\(role)/\(subrole) label=\(label.debugDescription) title=\(title.debugDescription) "
      + "value=\(value.prefix(40).debugDescription) id=\(identifier.debugDescription)"
  }
}

/// The root view in a window with the synthetic demo ledger open on one screen.
@MainActor
final class MountedRoot {
  let window: NSWindow
  private let directory: URL
  private let suite: String

  init(showing destination: AppDestination, appearance: NSAppearance.Name? = nil) async throws {
    _ = NSApplication.shared
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
    for _ in 0..<50 {
      try await Task.sleep(for: .milliseconds(100))
      window.contentView?.layoutSubtreeIfNeeded()
      let count = accessibilityElements().count
      if count == previous, count > 5 { break }
      previous = count
    }
  }

  func close() {
    window.close()
    UserDefaults.standard.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }

  func accessibilityElements() -> [SpokenElement] {
    guard let root = window.contentView else { return [] }
    var found: [SpokenElement] = []
    var seen = Set<ObjectIdentifier>()
    func visit(_ node: Any, depth: Int) {
      guard depth < 60, let element = node as? NSAccessibilityProtocol & NSObject,
        seen.insert(ObjectIdentifier(element)).inserted
      else { return }
      if element.isAccessibilityElement() {
        found.append(
          SpokenElement(
            role: element.accessibilityRole()?.rawValue ?? "",
            subrole: element.accessibilitySubrole()?.rawValue ?? "",
            label: element.accessibilityLabel() ?? "",
            title: element.accessibilityTitle() ?? "",
            value: (element.accessibilityValue()).map { "\($0)" } ?? "",
            placeholder: element.accessibilityPlaceholderValue() ?? "",
            identifier: element.accessibilityIdentifier() ?? ""))
      }
      for child in element.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
    }
    visit(root, depth: 0)
    return found
  }
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

// TEMPORARY probe: which way of reading the accessibility tree works on CI.
@MainActor
@Test func accessibilityTreeProbe() async throws {
  let mounted = try await MountedRoot(showing: .accounts)
  defer { mounted.close() }
  let view = try #require(mounted.window.contentView)
  func count(_ node: Any?, _ depth: Int = 0) -> Int {
    guard depth < 60, let element = node as? NSAccessibilityProtocol & NSObject else { return 0 }
    return 1 + (element.accessibilityChildren() ?? []).reduce(0) { $0 + count($1, depth + 1) }
  }
  print("A11YPROBE contentView children: \(view.accessibilityChildren()?.count ?? -1) total \(count(view))")
  print("A11YPROBE window total \(count(mounted.window))")
  print("A11YPROBE subviews \(view.subviews.map { String(describing: type(of: $0)) })")
  _ = view.accessibilityHitTest(NSPoint(x: 500, y: 400))
  _ = NSApplication.shared.accessibilityApplicationFocusedUIElement()
  try await Task.sleep(for: .milliseconds(500))
  print("A11YPROBE after hit test total \(count(view))")
  let app = AXUIElementCreateApplication(getpid())
  var windows: CFTypeRef?
  let windowsError = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
  print("A11YPROBE AX windows error \(windowsError.rawValue) count \((windows as? [AXUIElement])?.count ?? -1) trusted \(AXIsProcessTrusted())")
  let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
  let enhanced = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
  print("A11YPROBE set manual \(manual.rawValue) enhanced \(enhanced.rawValue)")
  try await Task.sleep(for: .milliseconds(1000))
  view.layoutSubtreeIfNeeded()
  print("A11YPROBE after AX enable total \(count(view)) window \(count(mounted.window))")
  func axCount(_ element: AXUIElement, _ depth: Int = 0) -> Int {
    guard depth < 60 else { return 0 }
    var children: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    return 1 + ((children as? [AXUIElement]) ?? []).reduce(0) { $0 + axCount($1, depth + 1) }
  }
  print("A11YPROBE AXUIElement app total \(axCount(app))")
}
