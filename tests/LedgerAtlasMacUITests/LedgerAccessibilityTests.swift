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
  #expect(!mounted.readTimedOut, "the Accessibility read timed out")
  #expect(!mounted.showsNoLedgerPrompt, "\(destination) still shows the open-a-ledger prompt")
  expectEveryControlIsNamed(mounted.accessibilityElements(), on: "\(destination.rawValue)")
}

/// Guard for Increase Contrast: macOS raises contrast for system colours by itself, so the app may only
/// use system colours. A hand-mixed colour or a faded one (`opacity`) wouldn't follow the
/// setting and fails here.
@Test func everyColourFollowsIncreaseContrast() throws {
  let custom = ["Color(red:", "Color(white:", "Color(hue:", "NSColor(red:", "NSColor(white:",
                "Color(\"", "Color(#", ".opacity("]
  var offenders: [String] = []
  for (file, lines) in try appSources() {
    for (index, line) in lines.enumerated() where custom.contains(where: line.contains) {
      offenders.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
    }
  }
  #expect(offenders.isEmpty, "\(offenders)")
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

/// Keyboard completion on every screen: with Full Keyboard Access on (System Settings >
/// Keyboard > Keyboard navigation, which keyboard-only users turn on), Tab walks through the
/// screen's controls in a cycle, leaves the sidebar for the screen itself, and every control it
/// lands on is on screen and has a name VoiceOver can speak.
@MainActor
@Test(arguments: LedgerDemoTour.destinations)
func tabWalksEveryScreenWithFullKeyboardAccess(_ destination: AppDestination) async throws {
  // Full Keyboard Access is a per-user macOS setting that AppKit reads at launch. CI turns it on
  // for the runner (`defaults write -g AppleKeyboardUIMode -int 2`) before the tests start.
  // Without it, Tab only visits text fields and lists, as on any Mac.
  // The flag says the runner was set up for it (ci.yml sets both); other runs, such as a stress
  // soak, check what they can with Full Keyboard Access as they find it.
  let fullKeyboardAccess = NSApplication.shared.isFullKeyboardAccessEnabled
  if !fullKeyboardAccess, ProcessInfo.processInfo.environment["LEDGER_EXPECT_FULL_KEYBOARD_ACCESS"] == "1" {
    Issue.record("Full Keyboard Access is off although the workflow turned it on")
  }
  let mounted = try await MountedRoot(showing: destination)
  defer { mounted.close() }
  print("A11Y KEYBOARD \(destination.rawValue): Full Keyboard Access \(fullKeyboardAccess)")
  let sidebar = mounted.sidebarList()
  mounted.window.makeFirstResponder(nil)
  var visited: [(id: ObjectIdentifier, name: String, isPlaceholder: Bool)] = []
  var cycled = false
  var placeholdersInARow = 0
  for _ in 0..<60 {
    mounted.press("\t", keyCode: 48)
    guard let responder = mounted.window.firstResponder, responder !== mounted.window else { continue }
    let id = ObjectIdentifier(responder)
    if visited.first?.id == id {
      cycled = true
      break
    }
    if visited.contains(where: { $0.id == id }) { continue }
    // SwiftUI puts placeholder key views (`KeyViewProxy`) into the window's key loop, off
    // screen and outside the Accessibility tree, to hand focus between its hosting views. They
    // aren't controls, so they're counted but not checked.
    // A few in a row are normal (one per hosting view); a long run would be a dead stretch of
    // Tab presses where nothing visible takes focus.
    if String(describing: type(of: responder)).contains("KeyViewProxy") {
      visited.append((id, "(SwiftUI key-view placeholder)", true))
      placeholdersInARow += 1
      #expect(placeholdersInARow <= 8, "\(destination.rawValue): \(placeholdersInARow) Tab presses in a row reach nothing")
      continue
    }
    placeholdersInARow = 0
    var name = focusName(of: responder)
    // Some SwiftUI form controls (a Picker's popup, a Stepper) carry their label only in the
    // system Accessibility tree, so ask the system what VoiceOver hears for the focused element,
    // and use it only when the system's focused element sits where this responder is.
    if name.isEmpty, let view = responder as? NSView, let window = view.window {
      let onScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
      name = mounted.systemFocusedName(matching: onScreen)
    }
    visited.append((id, name.isEmpty ? "<unnamed \(type(of: responder))>" : name, false))
    if let view = responder as? NSView {
      let frame = view.convert(view.bounds, to: nil)
      #expect(
        !view.isHiddenOrHasHiddenAncestor && frame.width > 0 && frame.height > 0
          && mounted.window.contentView?.frame.intersects(frame) == true,
        "\(destination.rawValue): Tab landed on \(name), which isn't on screen")
    }
    #expect(!name.isEmpty, "\(destination.rawValue): Tab landed on a control with no name: \(type(of: responder))")
  }
  print("A11Y KEYBOARD \(destination.rawValue) tab order: \(visited.map(\.name))")
  #expect(cycled, "\(destination.rawValue): Tab never came back round to the first control")
  if fullKeyboardAccess {
    let outsideSidebar = visited.filter { !$0.isPlaceholder && $0.id != sidebar.map { ObjectIdentifier($0) } }
    #expect(!outsideSidebar.isEmpty, "\(destination.rawValue): Tab never left the sidebar")
  }
}

/// What VoiceOver would say for the control that has keyboard focus.
@MainActor
private func focusName(of responder: NSResponder) -> String {
  // A text field being edited hands focus to the window's shared field editor; VoiceOver
  // reads the text field itself.
  if let editor = responder as? NSTextView, editor.isFieldEditor,
    let field = editor.delegate as? NSResponder
  {
    return focusName(of: field)
  }
  if let name = ownName(of: responder as NSObject) { return name }
  // A form control is often named by the label next to it, as VoiceOver reads it.
  if let titleElement = inProcessProperty(responder, "accessibilityTitleUIElement") as? NSObject,
    let name = ownName(of: titleElement) ?? (inProcessProperty(titleElement, "accessibilityValue") as? String)
  {
    return name
  }
  if let button = responder as? NSButton, !button.title.isEmpty { return button.title }
  if let table = responder as? NSTableView {
    return "list of \(table.numberOfRows) rows"
  }
  // A scroll bar is a standard AppKit control; VoiceOver names it by its role.
  if responder is NSScroller { return "scroll bar" }
  // A hosting view that takes focus for a SwiftUI control: VoiceOver reads the control inside.
  var queue = (inProcessProperty(responder, "accessibilityChildren") as? [NSObject]) ?? []
  var looked = 0
  while !queue.isEmpty, looked < 40 {
    let element = queue.removeFirst()
    looked += 1
    if let name = ownName(of: element) { return name }
    queue += (inProcessProperty(element, "accessibilityChildren") as? [NSObject]) ?? []
  }
  return ""
}

@MainActor
private func ownName(of element: NSObject) -> String? {
  for getter in ["accessibilityLabel", "accessibilityTitle", "accessibilityPlaceholderValue"] {
    if let text = inProcessProperty(element, getter) as? String,
      !text.trimmingCharacters(in: .whitespaces).isEmpty
    {
      return text
    }
  }
  return nil
}

/// Visible focus: the app never turns off the system focus ring, so whatever has keyboard
/// focus is always drawn as focused.
@Test func focusIsAlwaysVisible() throws {
  let hiding = [".focusEffectDisabled(", "focusRingType = .none", ".focusable(false", "focusRingType: .none"]
  var offenders: [String] = []
  for (file, lines) in try appSources() {
    for (index, line) in lines.enumerated() where hiding.contains(where: codePart(of: line).contains) {
      offenders.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
    }
  }
  #expect(offenders.isEmpty, "\(offenders)")
}

/// Row-level VoiceOver on every screen: each row of every list says something when VoiceOver
/// moves onto it, through the macOS Accessibility API.
@MainActor
@Test(arguments: LedgerDemoTour.destinations)
func everyListRowOnEveryScreenIsSpoken(_ destination: AppDestination) async throws {
  let mounted = try await MountedRoot(showing: destination)
  defer { mounted.close() }
  let sidebarRows = mounted.sidebarList()?.numberOfRows ?? 0
  let rows = mounted.accessibilityRows()
  // "Says something" means at least one word, not only punctuation or a lone number.
  let silent = rows.filter { $0.range(of: #"\p{L}{2,}"#, options: .regularExpression) == nil }
  print("A11Y ROWS \(destination.rawValue): \(rows.count) rows (\(sidebarRows) in the sidebar), \(silent.count) silent")
  #expect(!rows.isEmpty, "\(destination.rawValue): no list rows at all (not even the sidebar)")
  #expect(silent.isEmpty, "\(destination.rawValue): \(silent.count) of \(rows.count) rows say nothing: \(silent)")
  // Screens whose demo data fills a list must expose its rows, not only the sidebar's.
  if screensWithDemoLists.contains(destination) {
    #expect(rows.count > sidebarRows, "\(destination.rawValue): only the sidebar's rows are readable")
  }
}

/// The screens whose list the demo ledger fills (seen in the capture set).
private let screensWithDemoLists: Set<AppDestination> = [
  .ledger, .accounts, .categories, .tags, .transfers, .recurrence, .budgets, .insights, .search,
  .receipts, .backupRestore,
]

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

/// Guard for larger text: macOS has no Dynamic Type, so the app must not pin text sizes. Every font
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

/// Guard for not using colour alone: every coloured foreground in the app sits on text, so the meaning is in
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
  // A row is read as its label, or as the text it shows when it has no separate label.
  let spoken = mounted.accessibilityElements().map { "\($0.spokenName) \($0.value)" }
  let rows = spoken.filter { $0.contains(time) }
  print("A11Y ROWS \(rows.count) ledger rows")
  #expect(rows.count > 3)
  let kinds = ["Income", "Expense", "Transfer", "Adjustment"]
  // The kind is its own field in the row: "<title>, <Kind> · …" or the title itself.
  let missing = rows.filter { row in
    let fields = row.split(whereSeparator: { ",·".contains($0) })
      .map { $0.trimmingCharacters(in: .whitespaces) }
    return !fields.contains(where: kinds.contains)
  }
  #expect(missing.isEmpty, "\(missing.count) rows don't say their kind")
}

/// A source line without a trailing `//` comment, or empty for a comment-only line.
private func codePart(of line: String) -> String {
  let trimmed = line.trimmingCharacters(in: .whitespaces)
  if trimmed.hasPrefix("//") { return "" }
  // A " //" outside a string ends the code; good enough for this codebase's style.
  guard let range = line.range(of: " // ") else { return line }
  return String(line[..<range.lowerBound])
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
func accessibilityTree(of pid: pid_t, windowIdentifier: String) -> [SpokenElement] {
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
  // Only this test's window, so a window left over from another test can't count.
  for window in (windows as? [AXUIElement]) ?? [] where text(window, kAXIdentifierAttribute) == windowIdentifier {
    visit(window, depth: 0)
  }
  return found
}

/// An element's Accessibility property read in-process through its Objective-C getter (such
/// as `accessibilityLabel`), which is how SwiftUI's elements answer.
@MainActor
func inProcessProperty(_ element: NSObject, _ getter: String) -> Any? {
  let selector = Selector(getter)
  guard element.responds(to: selector) else { return nil }
  return element.perform(selector)?.takeUnretainedValue()
}

@MainActor
private func inProcessText(_ element: NSObject, _ getter: String) -> String {
  guard let value = inProcessProperty(element, getter) else { return "" }
  return (value as? String) ?? (value as? NSAttributedString)?.string ?? "\(value)"
}

/// The same reading as `accessibilityTree`, taken in-process on the main thread from the
/// window's own Accessibility objects. Reading this process's UI through the system API runs
/// AppKit and SwiftUI code in the reading thread, which crashes now and then; the screenshot
/// captures read this way instead.
@MainActor
func inProcessAccessibilityTree(of window: NSWindow) -> [SpokenElement] {
  var found: [SpokenElement] = []
  func visit(_ element: NSObject, depth: Int) {
    guard depth < 80 else { return }
    let linked = inProcessProperty(element, "accessibilityTitleUIElement") as? NSObject
    found.append(
      SpokenElement(
        role: inProcessText(element, "accessibilityRole"),
        subrole: inProcessText(element, "accessibilitySubrole"),
        label: inProcessText(element, "accessibilityLabel"),
        title: inProcessText(element, "accessibilityTitle"),
        value: inProcessText(element, "accessibilityValue"),
        placeholder: inProcessText(element, "accessibilityPlaceholderValue"),
        identifier: inProcessText(element, "accessibilityIdentifier"),
        linkedTitle: linked.map { inProcessText($0, "accessibilityValue") } ?? ""))
    for child in inProcessProperty(element, "accessibilityChildren") as? [NSObject] ?? [] {
      visit(child, depth: depth + 1)
    }
    // A list's rows are made on demand and aren't among its children here; read the rows
    // on screen.
    if let table = element as? NSTableView {
      let rows = table.rows(in: table.visibleRect)
      for row in rows.location..<(rows.location + rows.length) {
        if let rowView = table.rowView(atRow: row, makeIfNecessary: false) {
          visit(rowView, depth: depth + 1)
        }
      }
    }
  }
  visit(window, depth: 0)
  return found
}

/// The root view in a window with the synthetic demo ledger open on one screen.
@MainActor
final class MountedRoot {
  let window: NSWindow
  private let directory: URL
  private let suite: String
  let identifier = "a11y-window-\(UUID().uuidString)"
  /// Set when an Accessibility read ran out of time; its reader thread may still be running.
  private(set) var readTimedOut = false
  /// The empty-ledger prompt is showing instead of the screen.
  private(set) var showsNoLedgerPrompt = false
  /// Read the Accessibility tree in-process on the main thread (see
  /// `inProcessAccessibilityTree`) instead of through the system API from another thread.
  /// Only the captures use this, to check what is on screen. It is not evidence of what
  /// VoiceOver hears: the VoiceOver label checks keep the default (false) and go through the
  /// real Accessibility API.
  let readsInProcess: Bool

  /// `withLedger: false` shows the empty state; `appLock` lets a test show the lock screen.
  init(
    showing destination: AppDestination, withLedger: Bool = true, appLock: LedgerAppLock? = nil,
    size: NSSize = NSSize(width: 1100, height: 900), appWindow: Bool = false,
    readsInProcess: Bool = false
  ) async throws {
    self.readsInProcess = readsInProcess
    Self.launchOnce()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "a11y-\(UUID().uuidString)")
    self.directory = directory
    var mounted = false
    defer { if !mounted { try? FileManager.default.removeItem(at: directory) } }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let ledger = directory.appendingPathComponent("Demo Household.sqlite")
    if withLedger { try LedgerDemoTour.makeDemoLedger(at: ledger) }
    suite = "LedgerAtlasMacUITests.a11y.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let bookmarks = SecurityScopedBookmarkStore(
      defaults: defaults, makeBookmark: { Data($0.path.utf8) },
      resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) })
    if withLedger { try bookmarks.save(ledger, for: .canonicalLedger) }
    let lock =
      appLock ?? LedgerAppLock(reader: { _ in nil }, writer: { _, _ in }, kdfIterations: 1_000)
    let root = LedgerAtlasRootView(
      initialSelection: destination, appLock: lock,
      productSettings: .init(startScreen: destination), bookmarkStore: bookmarks,
      // A widget store in the test folder, as the app has its App Group container. Without
      // one every screen reports "Widget status could not be published".
      widgetProjectionPublisher: RedactedWidgetProjectionPublisher(
        store: .init(containerURL: directory)),
      scopeStarter: { _ in true }, scopeStopper: { _ in })
    // `appWindow` builds the window the way the app's WindowGroup does (full-size content
    // under a hosting controller), so the detail column starts beside the sidebar instead of
    // under it. Captures need that; the Accessibility checks don't.
    window = FullSizeTestWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: appWindow
        ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        : [.titled, .closable, .resizable],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.setAccessibilityIdentifier(identifier)
    if appWindow {
      window.contentViewController = NSHostingController(rootView: root)
      window.setContentSize(size)
    } else {
      window.contentView = NSHostingView(rootView: root)
    }
    window.makeKeyAndOrderFront(nil)
    mounted = true
    do { try await settle() } catch { close(); throw error }
  }

  /// Waits for the ledger to open and the screen to settle.
  func settle() async throws {
    var previous = -1
    for _ in 0..<30 {
      try await Task.sleep(for: .milliseconds(200))
      window.contentView?.layoutSubtreeIfNeeded()
      let elements = accessibilityElements()
      if readTimedOut { break }
      // Keep waiting while the saved ledger is still opening.
      // The empty-ledger prompt's title is exactly "Open a ledger".
      showsNoLedgerPrompt = elements.contains {
        $0.spokenName == "Open a ledger" || $0.value == "Open a ledger"
      }
      if elements.count == previous, elements.count > 5, !showsNoLedgerPrompt { break }
      previous = elements.count
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
    keepTestRunLoopAlive()
  }

  nonisolated(unsafe) private static var loopDepth = 0
  /// How many times the test runner's run of the main loop was stopped and run again.
  nonisolated(unsafe) static var runLoopRestarts = 0
  static let maxRunLoopRestarts = 20

  /// The test process lives inside the test runner's own run of the main run loop, and that
  /// run should never end: when the tests finish, the runner calls exit() itself. Something in
  /// AppKit or SwiftUI sometimes stops it after a sheet closes, which ended the whole test
  /// process with status 0 partway through. This watches the main run loop and, when that
  /// outermost run ends, logs it and runs the loop again. Nested runs are counted and left
  /// alone. The outermost run was entered before this observer existed, so it sits at -1;
  /// that holds because `launchOnce` first runs from a test body, inside the runner's own run.
  /// Restarts nest on the stack, so after `maxRunLoopRestarts` the stop is let through and the
  /// CI summary check fails the job. Finding the caller is #151.
  /// Run loop observers aren't called while they are already firing, so each restart hands
  /// over to a fresh observer before running the loop again.
  private static func keepTestRunLoopAlive() {
    let activities = CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue
    let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) {
      observer, activity in
      if activity == .entry {
        loopDepth += 1
        return
      }
      loopDepth -= 1
      guard loopDepth < 0, runLoopRestarts < maxRunLoopRestarts else { return }
      runLoopRestarts += 1
      print("CAPTURE the test runner's run of the main loop was stopped (\(runLoopRestarts)); running it again")
      CFRunLoopObserverInvalidate(observer)
      keepTestRunLoopAlive()
      CFRunLoopRun()
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
  }

  func close() {
    window.orderOut(nil)
    autoreleasepool {
      window.contentViewController = nil
      window.contentView = nil
      window.close()
    }
    UserDefaults.standard.removePersistentDomain(forName: suite)
    // SwiftUI may release the open ledger a little later; unlinking its file first is fine
    // since #150 keeps the pinned file's name alive until the connection closes.
    try? FileManager.default.removeItem(at: directory)
  }


  /// Every element in this window's tree, read the way VoiceOver reads it.
  /// The test runner doesn't run the main run loop, and the app answers Accessibility requests
  /// there, so pump it until the background read finishes.
  func accessibilityElements() -> [SpokenElement] {
    if readsInProcess {
      // SwiftUI only builds its accessibility elements once an Accessibility client has asked
      // for them. Run alone, nothing else in the process has, and the in-process tree is
      // just the window title; so ask once through the system API first.
      if !Self.systemReadDone {
        Self.systemReadDone = true
        _ = systemAccessibilityElements()
      }
      return inProcessAccessibilityTree(of: window)
    }
    return systemAccessibilityElements()
  }

  nonisolated(unsafe) private static var systemReadDone = false

  /// What VoiceOver says for each list row in this window: the row's own text plus the text
  /// of everything inside it, read through the system Accessibility API.
  func accessibilityRows() -> [String] {
    let pid = ProcessInfo.processInfo.processIdentifier
    let result = RowsBox()
    let identifier = identifier
    Thread.detachNewThread {
      result.finish(accessibilityRowTexts(of: pid, windowIdentifier: identifier))
    }
    let deadline = Date().addingTimeInterval(20)
    while !result.isDone, Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    if !result.isDone { readTimedOut = true }
    return result.rows
  }

  /// The name the system Accessibility API gives the focused element, read off the main thread.
  func systemFocusedName(matching frame: NSRect) -> String {
    let pid = ProcessInfo.processInfo.processIdentifier
    // The system API measures from the top of the main screen; AppKit from the bottom.
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    let expected = CGRect(
      x: frame.minX, y: screenHeight - frame.maxY, width: frame.width, height: frame.height)
    let result = RowsBox()
    Thread.detachNewThread {
      result.finish([accessibilityFocusedName(of: pid, within: expected)])
    }
    let deadline = Date().addingTimeInterval(10)
    while !result.isDone, Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    if !result.isDone { readTimedOut = true }
    return result.rows.first ?? ""
  }

  private func systemAccessibilityElements() -> [SpokenElement] {
    let pid = ProcessInfo.processInfo.processIdentifier
    let result = TreeBox()
    let identifier = identifier
    Thread.detachNewThread {
      result.finish(accessibilityTree(of: pid, windowIdentifier: identifier))
    }
    let deadline = Date().addingTimeInterval(20)
    while !result.isDone, Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    if !result.isDone { readTimedOut = true }
    return result.elements
  }
}

/// Hands the row texts from the reader thread back to the main thread.
final class RowsBox: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  private var found: [String] = []
  var isDone: Bool { lock.withLock { done } }
  var rows: [String] { lock.withLock { found } }
  func finish(_ rows: [String]) { lock.withLock { found = rows; done = true } }
}

/// Each AXRow in the window, as the text VoiceOver can read from it and its descendants.
func accessibilityRowTexts(of pid: pid_t, windowIdentifier: String) -> [String] {
  let app = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(app, 5)
  func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
  }
  func text(_ element: AXUIElement, _ name: String) -> String {
    guard let value = attribute(element, name) else { return "" }
    return (value as? String) ?? ""
  }
  func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
  }
  func spoken(_ element: AXUIElement, depth: Int) -> String {
    guard depth < 20 else { return "" }
    let own = [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute]
      .map { text(element, $0) }.filter { !$0.isEmpty }
    return (own + children(element).map { spoken($0, depth: depth + 1) })
      .filter { !$0.isEmpty }.joined(separator: " ")
  }
  var rows: [String] = []
  func visit(_ element: AXUIElement, depth: Int) {
    guard depth < 80 else { return }
    let role = text(element, kAXRoleAttribute)
    // A row scrolled out of view has empty cells until it comes back into view (VoiceOver
    // scrolls it there first), so a list's rows are read as the list shows them.
    if role == kAXTableRole || role == kAXOutlineRole,
      let visible = attribute(element, kAXVisibleRowsAttribute) as? [AXUIElement], !visible.isEmpty
    {
      rows += visible.map { spoken($0, depth: 0) }
      return
    }
    if role == kAXRowRole {
      rows.append(spoken(element, depth: 0))
      return
    }
    for child in children(element) { visit(child, depth: depth + 1) }
  }
  var windows: CFTypeRef?
  AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
  for window in (windows as? [AXUIElement]) ?? [] where text(window, kAXIdentifierAttribute) == windowIdentifier {
    visit(window, depth: 0)
  }
  return rows
}

/// What VoiceOver names the focused element: its description or title, else the label next to it.
func accessibilityFocusedName(of pid: pid_t, within expected: CGRect) -> String {
  let app = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(app, 5)
  func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
  }
  func name(_ element: AXUIElement) -> String? {
    [kAXDescriptionAttribute, kAXTitleAttribute]
      .compactMap { attribute(element, $0) as? String }
      .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
  }
  func axElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }
  func frame(_ element: AXUIElement) -> CGRect? {
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard let position = attribute(element, kAXPositionAttribute), let extent = attribute(element, kAXSizeAttribute),
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(extent) == AXValueGetTypeID(),
      AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
      AXValueGetValue(unsafeDowncast(extent, to: AXValue.self), .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
  }
  // The name counts only if the system's focused element is the responder the test focused:
  // its frame must overlap the responder's.
  guard let element = axElement(attribute(app, kAXFocusedUIElementAttribute)),
    let focusedFrame = frame(element), focusedFrame.insetBy(dx: -2, dy: -2).intersects(expected)
  else { return "" }
  if let own = name(element) { return own }
  if let labelElement = axElement(attribute(element, kAXTitleUIElementAttribute)) {
    if let text = name(labelElement) ?? (attribute(labelElement, kAXValueAttribute) as? String), !text.isEmpty {
      return text
    }
  }
  return ""
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
    where animationAPIs.contains(where: codePart(of: line).contains) {
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
