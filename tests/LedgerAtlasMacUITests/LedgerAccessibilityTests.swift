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
  expectEveryControlIsNamed(mounted.accessibilityElements(), on: "\(destination.rawValue)")
}

/// Increase Contrast: every screen still renders and stays fully labeled in both high-contrast
/// appearances.
@MainActor
@Test(arguments: LedgerDemoTour.destinations)
func everyScreenStaysLabeledWithIncreasedContrast(_ destination: AppDestination) async throws {
  for appearance in [NSAppearance.Name.accessibilityHighContrastAqua,
                     .accessibilityHighContrastDarkAqua] {
    let mounted = try await MountedRoot(showing: destination, appearance: appearance)
    defer { mounted.close() }
    #expect(mounted.window.appearance?.name == appearance)
    expectEveryControlIsNamed(
      mounted.accessibilityElements(), on: "\(destination.rawValue) \(appearance.rawValue)")
  }
}

@MainActor
private func expectEveryControlIsNamed(_ elements: [SpokenElement], on screen: String) {
  let summary = Dictionary(grouping: elements, by: \.role).mapValues(\.count)
    .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
  print("A11Y \(screen): \(elements.count) elements: \(summary)")
  #expect(elements.count > 5, "\(screen) exposed almost nothing to VoiceOver")
  let unlabeled = elements.filter { $0.isControl && $0.spokenName.isEmpty }
  for element in unlabeled {
    print("A11Y UNLABELED \(screen): \(element.debugDescription)")
  }
  #expect(unlabeled.isEmpty, "\(screen): \(unlabeled.map(\.debugDescription))")
}

/// Keyboard: with nothing focused, Tab walks through more than one control on the ledger
/// screen, and reaches both the search field and the transaction list.
@MainActor
@Test func tabWalksTheLedgerScreenControls() async throws {
  let mounted = try await MountedRoot(showing: .ledger)
  defer { mounted.close() }
  mounted.window.makeFirstResponder(nil)
  var visited: [String] = []
  var seen = Set<ObjectIdentifier>()
  for _ in 0..<12 {
    mounted.press("\t", keyCode: 48)
    guard let responder = mounted.window.firstResponder, responder !== mounted.window else {
      continue
    }
    if seen.insert(ObjectIdentifier(responder)).inserted {
      visited.append(String(describing: type(of: responder)))
    }
  }
  print("A11Y KEYBOARD tab order: \(visited)")
  #expect(visited.count >= 2, "Tab reached \(visited)")
  #expect(visited.contains { $0.contains("Text") }, "Tab never reached a text field: \(visited)")
  #expect(
    visited.contains { $0.contains("Table") || $0.contains("Outline") || $0.contains("Collection") },
    "Tab never reached a list: \(visited)")
}

/// Keyboard: the sidebar moves between screens with the arrow keys.
@MainActor
@Test func arrowKeysMoveBetweenScreensInTheSidebar() async throws {
  let mounted = try await MountedRoot(showing: .ledger)
  defer { mounted.close() }
  let sidebar = try #require(mounted.sidebarList(), "no sidebar list in the window")
  #expect(mounted.window.makeFirstResponder(sidebar))
  let before = sidebar.selectedRow
  mounted.press(String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125)
  try await mounted.settle()
  let after = sidebar.selectedRow
  print("A11Y KEYBOARD sidebar row \(before) -> \(after)")
  #expect(after != before, "Down arrow left the sidebar on row \(before)")
}

/// Larger text: macOS has no Dynamic Type, so the app must not pin text sizes. Every font
/// is a system text style (`.body`, `.caption`, ...), which follows the macOS text size and
/// display zoom settings; a fixed point size or custom font fails here.
@Test func everyFontIsASystemTextStyle() throws {
  let fixed = ["system(size:", ".custom(", "NSFont(name:", "systemFont(ofSize:"]
  var offenders: [String] = []
  for (file, lines) in try appSources() {
    for (index, line) in lines.enumerated() where fixed.contains(where: line.contains) {
      offenders.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
    }
  }
  #expect(offenders.isEmpty, "\(offenders)")
}

/// Not color alone: every coloured foreground in the app sits on text, so the meaning is in
/// words too (errors are red text, never a red mark on its own).
@Test func colourIsNeverTheOnlySignal() throws {
  let colours = [".red", ".green", ".orange", ".yellow", ".blue", ".pink", ".purple"]
  var offenders: [String] = []
  var checked = 0
  for (file, lines) in try appSources() {
    for (index, line) in lines.enumerated()
    where line.contains("foregroundStyle(") || line.contains("foregroundColor(") || line.contains(".tint(") {
      guard colours.contains(where: { line.contains("(\($0)") || line.contains("Color\($0)") }) else {
        continue
      }
      checked += 1
      let context = lines[max(0, index - 5)...index].joined(separator: " ")
      if !context.contains("Text(") && !context.contains("Label(") {
        offenders.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
      }
    }
  }
  #expect(checked > 0)
  #expect(offenders.isEmpty, "\(offenders)")
}

/// Not color alone: each ledger row says in words whether it is income, expense or transfer.
@MainActor
@Test func ledgerRowsNameTheirKindInWords() async throws {
  let mounted = try await MountedRoot(showing: .ledger)
  defer { mounted.close() }
  let time = #/\b\d{2}:\d{2}\b/#
  let names = mounted.accessibilityElements().map(\.spokenName).filter { $0.count > 12 }
  for name in names.prefix(40) { print("A11Y NAME \(name.prefix(120))") }
  let rows = names.filter { $0.contains(time) }
  print("A11Y ROWS \(rows.count) ledger rows")
  #expect(rows.count > 3)
  let kinds = ["Income", "Expense", "Transfer", "Adjustment"]
  let missing = rows.filter { row in !kinds.contains { row.contains($0) } }
  #expect(missing.isEmpty, "\(missing.count) rows don't say their kind")
}

private func appSources() throws -> [(String, [String])] {
  let sources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources")
  var result: [(String, [String])] = []
  let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
  while let file = files?.nextObject() as? URL {
    guard file.pathExtension == "swift" else { continue }
    result.append(
      (file.lastPathComponent,
       try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")))
  }
  return result
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
  /// Text of the separate label VoiceOver reads for this control (AXTitleUIElement), as in a
  /// settings form where the label sits in its own column.
  let linkedTitle: String

  static let controlRoles: Set<String> = [
    kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole,
    kAXTextFieldRole, kAXSliderRole, kAXComboBoxRole, kAXIncrementorRole, kAXDisclosureTriangleRole,
    kAXTextAreaRole, "AXLink",
  ]

  /// Parts of standard AppKit chrome (window buttons, scroll bar and stepper arrows). VoiceOver
  /// names these from their subrole, and the app can't label them.
  static let systemChrome: Set<String> = [
    kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXZoomButtonSubrole,
    kAXFullScreenButtonSubrole, kAXIncrementArrowSubrole, kAXDecrementArrowSubrole,
    kAXIncrementPageSubrole, kAXDecrementPageSubrole,
  ]

  var isControl: Bool { Self.controlRoles.contains(role) && !Self.systemChrome.contains(subrole) }

  /// What VoiceOver reads as the element's name.
  var spokenName: String {
    [label, title, linkedTitle, placeholder].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
  }

  var debugDescription: String {
    "\(role)/\(subrole) label=\(label.debugDescription) title=\(title.debugDescription) "
      + "linked=\(linkedTitle.debugDescription) "
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
        identifier: text(element, kAXIdentifierAttribute),
        linkedTitle: attribute(element, kAXTitleUIElementAttribute).map {
          CFGetTypeID($0) == AXUIElementGetTypeID()
            ? text(unsafeBitCast($0, to: AXUIElement.self), kAXValueAttribute) : ""
        } ?? ""))
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
    try await settle()
  }

  /// Waits for the ledger to open and the screen to settle.
  func settle() async throws {
    var previous = -1
    for _ in 0..<30 {
      try await Task.sleep(for: .milliseconds(200))
      window.contentView?.layoutSubtreeIfNeeded()
      let count = accessibilityElements().count
      if count == previous, count > 5 { break }
      previous = count
    }
  }

  /// Sends one key press to the window, as the keyboard would.
  func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      guard
        let event = NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: modifiers,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, characters: characters, charactersIgnoringModifiers: characters,
          isARepeat: false, keyCode: keyCode)
      else { continue }
      window.sendEvent(event)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  }

  /// The leftmost list in the window: the screen sidebar.
  func sidebarList() -> NSTableView? {
    func lists(in view: NSView) -> [NSTableView] {
      ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(lists)
    }
    guard let content = window.contentView else { return nil }
    return lists(in: content).min {
      $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
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

