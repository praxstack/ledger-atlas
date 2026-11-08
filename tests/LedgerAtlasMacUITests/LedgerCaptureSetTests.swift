import AppKit
import ApplicationServices
import Foundation
import LedgerCore
import LedgerStore
import SwiftUI
import Testing

@testable import LedgerAtlasMacUI

// Synthetic data only: every capture shows the made-up demo ledger.

/// #57 (MACV2-21): one capture of the real app for each of the 25 screenshot traceability
/// records, in light and dark, plus key states (empty, loaded, edit sheet, an error, the lock
/// screen). Each capture is checked: it isn't blank, light and dark differ, the screen shows
/// what the record is about, and no home-folder path is on screen. The PNGs and an index go to
/// `$LEDGER_ATLAS_TEST_ARTIFACTS/ui-captures`, which CI uploads as an artifact.
@MainActor
@Test func everyTraceabilityRecordHasASyntheticCapture() async throws {
  let records = try traceabilityRecords()
  #expect(records.count == 25)
  let missing = records.filter { capturePlan[$0.key] == nil }.map(\.key)
  #expect(missing.isEmpty, "no capture planned for \(missing)")
  for record in records {
    #expect(
      record.manifestPath == "ui-captures/" + record.fileName(.light),
      "the manifest points record \(record.number) at \(record.manifestPath ?? "nothing")")
  }

  let output = try captureDirectory()
  var index: [[String: String]] = []
  let snapshots = CaptureSnapshots()

  // Screens: one window per screen (and editing mode), every record on it, both appearances.
  let screens = records.compactMap { record -> (CaptureRecord, CaptureShot.ScreenShot)? in
    guard case .screen(let shot) = capturePlan[record.key]?.shot else { return nil }
    return (record, shot)
  }
  for (screen, group) in Dictionary(grouping: screens, by: { ScreenKey($0.1) })
    .sorted(by: { $0.value[0].0.number < $1.value[0].0.number })
  {
    captureLog("screen \(screen.destination) editing=\(screen.editing)")
    let root = try await MountedRoot(
      showing: screen.destination, size: captureSize, appWindow: true, readsInProcess: true)
    defer { root.close() }
    #expect(!root.showsNoLedgerPrompt, "\(screen.destination) never showed the demo ledger")
    if screen.editing {
      captureLog("clicking Begin editing")
      #expect(root.click(named: "Begin editing accounts"), "no Begin editing button")
      try await root.settle()
    }
    // What the screen says before scrolling, plus what it shows after: only the rows on
    // screen are read.
    let before = root.accessibilityElements().map { "\($0.spokenName) \($0.value)" }
    for (record, shot) in group.sorted(by: { $0.0.number < $1.0.number }) {
      let plan = try #require(capturePlan[record.key])
      captureLog("record \(record.number) \(record.key)")
      var pair: [Data] = []
      for appearance in CaptureAppearance.allCases {
        root.window.appearance = NSAppearance(named: appearance.name)
        let scrolled = scroll(root.window, to: shot.scroll)
        if shot.scroll != .top {
          // A scroll that didn't move would give the top picture under another state's name.
          #expect(
            scrolled == .moved || scrolled == .contentFits,
            "\(record.key): scrolling to the \(shot.scroll.rawValue) didn't move: \(scrolled.rawValue)"
          )
        }
        pump(0.6)
        let text = before + root.accessibilityElements().map { "\($0.spokenName) \($0.value)" }
        let (png, method) = try #require(
          windowPNG(root.window), "\(record.key) could not be captured")
        expectUsable(png, text: text, expecting: plan.expects, for: record.key)
        let name = record.fileName(appearance)
        try png.write(to: output.appendingPathComponent(name))
        snapshots.add(file: name, png: png, text: text)
        var entry = record.indexEntry(
          file: name, appearance: appearance, plan: plan, method: method)
        entry["scroll"] =
          shot.scroll == .top ? "top" : "\(shot.scroll.rawValue): \(scrolled.rawValue)"
        index.append(entry)
        pair.append(png)
      }
      #expect(pair[0] != pair[1], "\(record.key): light and dark captures are identical")
    }
  }

  index += try await captureKeyStates(into: output, snapshots: snapshots)

  // Sheets: opened in the real app window the way a person opens them, then the sheet
  // window itself is captured. Sheets opened from a menu go last.
  let sheetRecords = records.sorted {
    func fromMenu(_ record: CaptureRecord) -> Bool {
      if case .sheet(.editAccount) = capturePlan[record.key]?.shot { return true }
      return false
    }
    return (fromMenu($0) ? 1 : 0, $0.number) < (fromMenu($1) ? 1 : 0, $1.number)
  }
  for record in sheetRecords {
    guard let plan = capturePlan[record.key], case .sheet(let sheet) = plan.shot else { continue }
    captureLog("sheet \(record.number) \(record.key)")
    let root = try await MountedRoot(
      showing: sheet.destination, size: captureSize, appWindow: true, readsInProcess: true)
    defer {
      // Closing a window with a sheet still attached ended the whole test process.
      // Drop any input still queued (such as a spare Escape) so it can't reach later windows.
      while NSApplication.shared.nextEvent(
        matching: .any, until: Date(), inMode: .default, dequeue: true) != nil
      {}
      // Dismiss the sheet the way a person does, with its Cancel button, so SwiftUI ends it
      // itself. Ending it from outside (or closing the window under it) has ended the whole
      // test process.
      if let sheet = root.window.attachedSheet, root.click(named: "Cancel", in: sheet) {
        for _ in 0..<30 where root.window.attachedSheet != nil { pump(0.1) }
      }
      if let attached = root.window.attachedSheet {
        captureLog("Cancel did not close the sheet")
        root.window.endSheet(attached)
      }
      drainLog("sheet ended")
      root.close()
      // A menu-opened sheet leaves a stop of the main run loop behind a little later; run
      // the loop here so the stop lands in this run and not in the test's own.
      drainLog("window closed", seconds: 3)
    }
    captureLog("mounted \(sheet.destination)")
    guard let sheetWindow = try await sheet.open(in: root) else {
      Issue.record("\(record.key): the \(sheet.title) did not open")
      continue
    }
    captureLog("opened \(sheet.title)")
    pump(0.6)
    // The sheet and the window behind it, read on the main thread.
    let text = (inProcessAccessibilityTree(of: sheetWindow) + root.accessibilityElements())
      .map { "\($0.spokenName) \($0.value)" }
    captureLog("read \(text.count) elements")
    var pair: [Data] = []
    for appearance in CaptureAppearance.allCases {
      root.window.appearance = NSAppearance(named: appearance.name)
      sheetWindow.appearance = NSAppearance(named: appearance.name)
      pump(0.6)
      let (png, method) = try #require(
        windowPNG(sheetWindow), "\(record.key) could not be captured")
      expectUsable(png, text: text, expecting: plan.expects, for: record.key)
      let name = record.fileName(appearance)
      try png.write(to: output.appendingPathComponent(name))
      snapshots.add(file: name, png: png, text: text)
      index.append(
        record.indexEntry(file: name, appearance: appearance, plan: plan, method: method))
      pair.append(png)
    }
    #expect(pair[0] != pair[1], "\(record.key): light and dark captures are identical")
  }

  let data = try JSONSerialization.data(
    withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
  try data.write(to: output.appendingPathComponent("index.json"))
  print("CAPTURES \(index.count) files in \(output.path)")
  try snapshots.verify(writingTo: output)
  // 25 records and 14 key states, each in light and dark.
  let expectedFiles: Int = 78
  #expect(index.count == expectedFiles)
  print("CAPTURE main run loop restarts so far: \(MountedRoot.runLoopRestarts)")
  #expect(
    MountedRoot.runLoopRestarts < MountedRoot.maxRunLoopRestarts,
    "the main run loop was stopped too often; restarts are capped")
}

/// The empty state, the lock screen, a refused passcode, the balance receipt, the entry
/// suggestion, the reminder's entry form with Upcoming (due and nothing due) and bulk edit
/// (selection, confirm, done), in light and dark. (Loaded and the edit sheet are records 1 and 14
/// above.)
@MainActor
private func captureKeyStates(
  into output: URL, snapshots: CaptureSnapshots
) async throws -> [[String: String]] {
  var index: [[String: String]] = []
  func save(
    _ capture: (png: Data, method: String), _ name: String, _ appearance: CaptureAppearance,
    _ note: String, text: [String]
  ) throws {
    let png = capture.png
    let file = "key-\(name)-\(appearance.rawValue).png"
    try png.write(to: output.appendingPathComponent(file))
    snapshots.add(file: file, png: png, text: text)
    index.append([
      "file": file, "state": name, "appearance": appearance.rawValue, "note": note,
      "capture_method": capture.method,
    ])
  }

  captureLog("empty state")
  let empty = try await MountedRoot(
    showing: .ledger, withLedger: false, size: captureSize, appWindow: true,
    readsInProcess: true)
  defer { empty.close() }
  for appearance in CaptureAppearance.allCases {
    empty.window.appearance = NSAppearance(named: appearance.name)
    pump(0.6)
    let capture = try #require(windowPNG(empty.window))
    let text = empty.accessibilityElements().map { "\($0.spokenName) \($0.value)" }
    expectUsable(capture.png, text: text, expecting: ["Open a ledger"], for: "empty")
    try save(capture, "empty", appearance, "No ledger open yet: the first-run prompt.", text: text)
  }

  let lock = LedgerAppLock(reader: { _ in nil }, writer: { _, _ in }, kdfIterations: 1_000)
  try lock.setPasscode("2468")
  lock.lock()
  captureLog("lock screen")
  let locked = try await MountedRoot(
    showing: .ledger, appLock: lock, size: captureSize, appWindow: true, readsInProcess: true)
  defer { locked.close() }
  for appearance in CaptureAppearance.allCases {
    locked.window.appearance = NSAppearance(named: appearance.name)
    pump(0.6)
    let capture = try #require(windowPNG(locked.window))
    let text = locked.accessibilityElements().map { "\($0.spokenName) \($0.value)" }
    expectUsable(capture.png, text: text, expecting: ["Ledger Atlas is locked"], for: "lock")
    #expect(!text.contains { $0.contains("Everyday Bank") }, "the lock screen shows ledger content")
    try save(capture, "lock", appearance, "App Lock on: ledger content is hidden until unlock.", text: text)
  }
  // An error: Unlock with no passcode is refused.
  captureLog("clicking Unlock with no passcode")
  #expect(locked.click(named: "Unlock"), "no Unlock button")
  pump(0.6)
  for appearance in CaptureAppearance.allCases {
    locked.window.appearance = NSAppearance(named: appearance.name)
    pump(0.6)
    let capture = try #require(windowPNG(locked.window))
    let text = locked.accessibilityElements().map { "\($0.spokenName) \($0.value)" }
    expectUsable(
      capture.png, text: text, expecting: ["That passcode was not accepted."], for: "error")
    try save(
      capture, "error", appearance, "A refused passcode, shown in words as well as colour.", text: text)
  }
  // #172: the balance-match receipt on Import Review, with a matching row, one that differs
  // and a hidden account Money Manager has no figure for (the demo ledger's made-up receipt).
  captureLog("balance receipt")
  let receipt = try await MountedRoot(
    showing: .importReview, size: captureSize, appWindow: true, readsInProcess: true)
  defer { receipt.close() }
  for appearance in CaptureAppearance.allCases {
    receipt.window.appearance = NSAppearance(named: appearance.name)
    pump(0.6)
    let capture = try #require(windowPNG(receipt.window))
    let text = receipt.accessibilityElements().map { "\($0.spokenName) \($0.value)" }
    expectUsable(
      capture.png, text: text,
      expecting: ["Balances after import", "matches", "higher here"],
      for: "balance-receipt")
    try save(
      capture, "balance-receipt", appearance,
      "After an import: each account beside Money Manager's figure, with the difference in words.",
      text: text)
  }

  // #169: the entry form after typing a memo an earlier entry used. Account and category are
  // filled from that entry and the form says so in words; nothing is saved yet.
  captureLog("entry suggestion")
  let demo = FileManager.default.temporaryDirectory.appendingPathComponent(
    "entry-suggestion-\(UUID().uuidString).sqlite")
  defer { try? FileManager.default.removeItem(at: demo) }
  try LedgerDemoTour.makeDemoLedger(at: demo, withBalanceReceipt: false)
  let ledger = try LedgerStore.openReadOnly(at: demo).readSnapshot()
  let form = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled],
    backing: .buffered, defer: false)
  form.isReleasedWhenClosed = false
  form.contentViewController = NSHostingController(
    rootView: NativeTransactionForm(
      accounts: ledger.accounts, categories: ledger.categories,
      intent: LedgerIntentRequest(kind: .addExpense, amountLiteral: "24000.00", note: "Flat rent"),
      entries: ledger.transactions, onSave: { _, _, _, _, _, _, _ in .saved }))
  form.makeKeyAndOrderFront(nil)
  defer { form.close() }
  var formText: [String] = []
  for _ in 0..<40 {
    try await Task.sleep(for: .milliseconds(200))
    formText = inProcessAccessibilityTree(of: form).map { "\($0.spokenName) \($0.value)" }
    if formText.contains(where: { $0.contains("suggested from an entry") }) { break }
  }
  for appearance in CaptureAppearance.allCases {
    form.appearance = NSAppearance(named: appearance.name)
    pump(0.6)
    let capture = try #require(windowPNG(form))
    expectUsable(
      capture.png, text: formText, expecting: ["suggested from an entry", "Flat rent"],
      for: "entry-suggestion")
    try save(
      capture, "entry-suggestion", appearance,
      "A memo used before fills account and category, labelled as a suggestion; nothing is saved yet.",
      text: formText)
  }

  // #171: the daily reminder opens the entry form with Upcoming beside it. The demo rent rule's
  // 3 Nov date was never entered, so it is overdue; 3 Dec is due. Then a day with nothing due:
  // the form still opens and Upcoming says so in words.
  let dueSoon = LedgerUpcoming(
    rules: ledger.recurrenceRules, installmentPlans: ledger.installmentPlans,
    transactions: ledger.transactions, today: MountedRoot.fixedToday)
  let nothingDue = LedgerUpcoming(
    rules: [], installmentPlans: [], transactions: [], today: MountedRoot.fixedToday)
  let upcomingStates: [(name: String, view: AnyView, size: NSSize, expects: [String], note: String)] = [
    (
      "upcoming-reminder", AnyView(
        EntryFormWithUpcoming(
          form: NativeTransactionForm(
            accounts: ledger.accounts, categories: ledger.categories,
            intent: LedgerIntentRequest(kind: .addExpense, showsUpcoming: true),
            entries: ledger.transactions, onSave: { _, _, _, _, _, _, _ in .saved }),
          upcoming: dueSoon, accounts: ledger.accounts, categories: ledger.categories)),
      NSSize(width: 780, height: 520),
      ["Upcoming", "Overdue", "Rent", "Total"],
      "The daily reminder opens the entry form with Upcoming beside it; an unentered date is overdue, in red and in words."
    ),
    (
      "upcoming-empty", AnyView(
        EntryFormWithUpcoming(
          form: NativeTransactionForm(
            accounts: ledger.accounts, categories: ledger.categories,
            intent: LedgerIntentRequest(kind: .addExpense, showsUpcoming: true),
            entries: ledger.transactions, onSave: { _, _, _, _, _, _, _ in .saved }),
          upcoming: nothingDue, accounts: ledger.accounts, categories: ledger.categories)),
      NSSize(width: 780, height: 520),
      ["Upcoming", UpcomingPanel.emptyText],
      "Nothing due: the reminder still opens the entry form, and Upcoming says so."
    ),
  ]
  // #168: bulk edit. Three expenses selected show the bulk bar; the confirm sheet says how many
  // entries change, what stays the same and how to revert; the notice after it offers Revert.
  let rent = try #require(ledger.categories.first { $0.name == "Rent" })
  let picked = Array(
    ledger.transactions.filter {
      $0.currentRevision.draft.kind == .expense && $0.links.isEmpty
        && $0.currentRevision.lifecycle == .active && $0.currentRevision.draft.categoryID != rent.id
    }.prefix(3).map(\.id))
  let bulkPlan = try LedgerBulkEditPlan.make(.category(rent.id), transactionIDs: picked, in: ledger)
  let bulkStates: [(name: String, view: AnyView, size: NSSize, expects: [String], note: String)] = [
    (
      "bulk-selection",
      AnyView(
        NavigationStack {
          LedgerBrowseList(
            transactions: ledger.transactions, hiddenIDs: [], accounts: ledger.accounts,
            categories: ledger.categories, splitPurchases: [], selectedIDs: .constant(Set(picked)),
            copy: { _ in }, tombstone: { _ in }, tags: ledger.tags,
            revisionTags: ledger.revisionTags, bulkEdit: { _, _ in })
        }),
      // Wide enough for the full bar beside the inspector; a narrower window folds the three
      // changes into one Change menu.
      NSSize(width: 1240, height: 600), [
        "3 selected", "Selection total: Spending", "Set Category", "Add Tag", "Remove Tag",
      ],
      "Several entries selected: the bulk bar says how many, what they add up to (#237), and"
        + " offers category and tag changes."
    ),
    (
      "bulk-confirm",
      AnyView(
        BulkEditConfirmSheet(
          plan: bulkPlan, categories: ledger.categories, tags: ledger.tags, confirm: {})),
      NSSize(width: 480, height: 280), ["Set the category to Rent on 3 entries?", "Revert Bulk Change"],
      "The confirm sheet states the count, what stays the same and the one-step revert."
    ),
    (
      "bulk-done",
      AnyView(
        NavigationStack {
          VStack(spacing: 0) {
            LedgerBrowseList(
              transactions: ledger.transactions, hiddenIDs: [], accounts: ledger.accounts,
              categories: ledger.categories, splitPurchases: [], selectedIDs: .constant([]),
              copy: { _ in }, tombstone: { _ in }, tags: ledger.tags,
              revisionTags: ledger.revisionTags, bulkEdit: { _, _ in })
            BulkEditNotice(text: "Category set to Rent on 3 entries.", revert: {}, dismiss: {})
          }
        }),
      NSSize(width: 1240, height: 600),
      ["Category set to Rent on 3 entries.", "Revert This Bulk Change"],
      "After a bulk change: what changed, and Revert This Bulk Change."
    ),
  ]
  // #238: To Review with three entries the app added, and with nothing waiting.
  let reviewWaiting = Set(
    ledger.transactions.filter {
      $0.currentRevision.draft.kind == .expense && $0.links.isEmpty
        && $0.currentRevision.lifecycle == .active
    }.suffix(3).map(\.id))
  func reviewScreen(_ waiting: Set<String>) -> AnyView {
    AnyView(
      NavigationStack {
        LedgerView(
          state: .loaded(LedgerSession.Presentation(snapshot: ledger)), isEditing: false,
          accounts: ledger.accounts, categories: ledger.categories,
          transactions: ledger.transactions, splitPurchases: [], splitTransactionIDs: [],
          splitNotice: nil, intentRequest: nil, consumeIntent: {}, open: {},
          lifecycleMessage: nil, lastFailure: nil, beginEditing: {}, saveAmount: { _, _ in },
          tombstone: { _ in }, copy: { _ in }, addMacTransaction: { _ in },
          createTransaction: { _, _, _, _, _, _, _ in .saved }, createSplit: { _ in },
          tags: ledger.tags, revisionTags: ledger.revisionTags,
          review: LedgerReviewMode(
            waitingIDs: waiting, markReviewed: { _ in }, markAllReviewed: {}))
      })
  }
  let reviewStates: [(name: String, view: AnyView, size: NSSize, expects: [String], note: String)] = [
    (
      "to-review", reviewScreen(reviewWaiting), NSSize(width: 1240, height: 600),
      [LedgerReviewMode.waitingText(3), "Mark Reviewed", "Mark All Reviewed"],
      "To Review: entries the app added wait, grouped by day, with Mark Reviewed and Mark All Reviewed."
    ),
    (
      "to-review-empty", reviewScreen([]), NSSize(width: 900, height: 520),
      [LedgerReviewMode.emptyTitle, LedgerReviewMode.emptyText],
      "Nothing waits in To Review: it says what would."
    ),
  ]
  // #239: Month in Review and Year in Review on the demo ledger, with "today" fixed so the
  // finished periods don't depend on the day the captures run.
  let recapMonthToday = try SourceLocalDate(year: 2026, month: 11, day: 15)
  let recapYearToday = try SourceLocalDate(year: 2027, month: 1, day: 15)
  let recapStates: [(name: String, view: AnyView, size: NSSize, expects: [String], note: String)] = [
    (
      "recap-month",
      AnyView(
        NavigationStack {
          InsightsRecapView(
            snapshot: ledger, today: recapMonthToday,
            period: .month(2026, 10))
        }),
      NSSize(width: 980, height: 760), ["October 2026 in review", "Money in", "Top spending"],
      "Month in Review: money in, spending and net against the month before, top categories, biggest expenses and activity."
    ),
    (
      "recap-year",
      AnyView(
        NavigationStack {
          InsightsRecapView(
            snapshot: ledger, today: recapYearToday,
            period: .year(2026))
        }),
      NSSize(width: 980, height: 760), ["2026 in review", "Money in", "Top spending"],
      "Year in Review: the same blocks for a year, plus spending by month and the best and hardest month."
    ),
  ]
  for state in upcomingStates + bulkStates + reviewStates + recapStates {
    captureLog(state.name)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: state.size), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: state.view)
    window.setContentSize(state.size)
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    var text: [String] = []
    for _ in 0..<40 {
      try await Task.sleep(for: .milliseconds(200))
      text = inProcessAccessibilityTree(of: window).map { "\($0.spokenName) \($0.value)" }
      if let first = state.expects.first, text.contains(where: { $0.contains(first) }) { break }
    }
    // The list opens its inspector a moment after it measures its width; let that land so
    // every run captures the same layout, then read the screen again.
    try await Task.sleep(for: .milliseconds(1_000))
    text = inProcessAccessibilityTree(of: window).map { "\($0.spokenName) \($0.value)" }
    for appearance in CaptureAppearance.allCases {
      window.appearance = NSAppearance(named: appearance.name)
      pump(0.6)
      let capture = try #require(windowPNG(window))
      expectUsable(capture.png, text: text, expecting: state.expects, for: state.name)
      try save(capture, state.name, appearance, state.note, text: text)
    }
  }
  return index
}

// MARK: - The plan: which app state stands for each traceability record

/// A traceability record from docs/specifications/screenshot-traceability-v1.json.
struct CaptureRecord: Sendable {
  let number: Int
  let route: String
  let state: String
  /// Where the manifest says this record's light capture is.
  let manifestPath: String?
  var key: String { "\(route)/\(state)" }

  func fileName(_ appearance: CaptureAppearance) -> String {
    String(format: "%02d-%@-%@-%@.png", number, route, state, appearance.rawValue)
  }

  func indexEntry(
    file: String, appearance: CaptureAppearance, plan: CapturePlan, method: String
  ) -> [String: String] {
    [
      "file": file, "record": String(number), "route_id": route, "state_id": state,
      "appearance": appearance.rawValue, "ledger_atlas": plan.shot.description,
      "note": plan.note ?? "", "capture_method": method,
    ]
  }
}

enum CaptureAppearance: String, CaseIterable, Sendable {
  case light, dark
  var name: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
}

enum CaptureScroll: String, Sendable { case top, middle, bottom }

enum CaptureShot: CustomStringConvertible, Sendable {
  struct ScreenShot: Sendable {
    let destination: AppDestination
    var scroll: CaptureScroll = .top
    var editing = false
  }
  case screen(ScreenShot)
  case sheet(CaptureSheet)

  static func screen(
    _ destination: AppDestination, _ scroll: CaptureScroll = .top, editing: Bool = false
  ) -> CaptureShot {
    .screen(ScreenShot(destination: destination, scroll: scroll, editing: editing))
  }

  var description: String {
    switch self {
    case .screen(let shot):
      "\(shot.destination.title) screen\(shot.editing ? " (editing)" : ""), scrolled to \(shot.scroll.rawValue)"
    case .sheet(let sheet): sheet.title
    }
  }
}

struct ScreenKey: Hashable, Sendable {
  let destination: AppDestination
  let editing: Bool
  init(_ shot: CaptureShot.ScreenShot) {
    destination = shot.destination
    editing = shot.editing
  }
}

enum CaptureSheet: Sendable {
  case newAccount, editAccount(row: Int, name: String), setPasscode

  var title: String {
    switch self {
    case .newAccount: "New account sheet"
    case .editAccount(_, let name): "Edit account sheet for \(name)"
    case .setPasscode: "Set passcode sheet"
    }
  }

  var destination: AppDestination { self == .setPasscode ? .settings : .accounts }

  /// Opens the sheet with clicks and menus in the mounted window. Returns the sheet window.
  @MainActor
  func open(in root: MountedRoot) async throws -> NSWindow? {
    switch self {
    case .newAccount:
      guard root.click(named: "Begin editing accounts") else { return nil }
      try await root.settle()
      guard root.click(named: "New account") else { return nil }
    case .editAccount(let row, let name):
      // The Actions menus only work while editing. Each account row has one, labelled
      // with the account's name; `row` is the fallback, counting pop-ups from the top.
      guard root.click(named: "Begin editing accounts") else { return nil }
      try await root.settle()
      guard root.chooseMenuItem("Edit account", from: "Actions for \(name)", orRow: row)
      else { return nil }
    case .setPasscode:
      guard root.click(named: "Set passcode…") else { return nil }
    }
    for _ in 0..<20 {
      pump(0.2)
      if let sheet = root.window.attachedSheet { return sheet }
    }
    return nil
  }
}

extension CaptureSheet: Equatable {}

struct CapturePlan: Sendable {
  let shot: CaptureShot
  /// Text that must be on screen, so a capture of the wrong state fails.
  let expects: [String]
  /// How the Ledger Atlas state differs from the recorded Android one, if it does.
  var note: String? = nil
}

/// Ledger Atlas is a Mac app, not a copy of the Android one, so each record maps to the screen
/// that does the same job. Notes say where the Mac app has no exact counterpart.
let capturePlan: [String: CapturePlan] = [
  "transactions.daily/dark.populated.root": .init(
    shot: .screen(.ledger), expects: ["Entertainment, Expense"]),
  "statistics.overview/monthly.expense": .init(
    shot: .screen(.insights), expects: ["Period", "Expense by category", "Income"],
    note: "Insights opens on the newest month with entries; month and year share one picker instead of tabs."),
  "statistics.overview/annual.expense": .init(
    shot: .screen(.insights, .middle), expects: ["Period", "Trend"],
    note: "Shows the default month view; Year is one click away in the period picker, with the same sections."),
  "statistics.overview/annual.income.scrolled": .init(
    shot: .screen(.insights, .bottom), expects: ["Export PDF statement"]),
  "statistics.category_detail/annual.income.category": .init(
    shot: .screen(.categories), expects: ["Salary"]),
  "statistics.category_detail/annual.income.capture_anomaly": .init(
    shot: .screen(.categories, .middle), expects: ["Salary"],
    note: "The anomaly was in the source app's capture; the synthetic ledger has none."),
  "statistics.category_detail/annual.expense.subcategory": .init(
    shot: .screen(.categories, .bottom), expects: ["Open subcategories of Food"]),
  "statistics.total_balance/monthly.trend": .init(
    shot: .screen(.budgets), expects: ["Groceries"],
    note: "Monthly progress is shown by budgets; there is no separate balance-trend chart."),
  "accounts.overview/upper.cards.totals": .init(
    shot: .screen(.accounts), expects: ["Everyday Bank"]),
  "accounts.overview/cards.savings.groups": .init(
    shot: .screen(.accounts, .middle), expects: ["Savings & Investments"]),
  "accounts.overview/lower.groups.active_scroll": .init(
    shot: .screen(.accounts, .bottom), expects: ["Travel Wallet"]),
  "accounts.overview/restored.chrome": .init(
    shot: .screen(.accounts), expects: ["Everyday Bank"],
    note: "Mac windows keep their chrome; this is the top of Accounts again."),
  "accounts.overview/investments.others.boundary": .init(
    shot: .screen(.accounts, .bottom), expects: ["Index Fund"]),
  "accounts.account_info/existing.edit": .init(
    shot: .sheet(.editAccount(row: 1, name: "Everyday Bank")), expects: ["Everyday Bank", "Save"]),
  "settings.configuration/index": .init(
    shot: .screen(.settings), expects: ["Appearance"]),
  "settings.accounts/index": .init(
    shot: .screen(.accounts, editing: true), expects: ["New account"]),
  "settings.account_groups/edit.reorder.protected": .init(
    shot: .screen(.accounts, .middle, editing: true), expects: ["New account group"]),
  "settings.account_list/upper.hidden_variant": .init(
    shot: .screen(.accounts, editing: true), expects: ["Old Wallet"]),
  "settings.account_list/tail": .init(
    shot: .screen(.accounts, .bottom, editing: true), expects: ["Travel Wallet"]),
  "accounts.add/group_picker.open": .init(
    shot: .sheet(.newAccount), expects: ["Group"],
    note: "Shows the group picker closed; an open menu is a separate window."),
  "accounts.add/name.focused": .init(shot: .sheet(.newAccount), expects: ["Account name", "Create"]),
  "accounts.account_info/savings.edit": .init(
    shot: .sheet(.editAccount(row: 4, name: "Emergency Savings")),
    expects: ["Emergency Savings"]),
  "security.set_passcode/first_entry.empty": .init(
    shot: .sheet(.setPasscode), expects: ["New passcode"]),
  "local_web_access.idle/passcode_off.service_stopped": .init(
    shot: .screen(.localAccess), expects: ["Start read-only portal"]),
  "backup.hub/all_entries": .init(
    shot: .screen(.backupRestore), expects: ["Save 1:1 backup"]),
]

// MARK: - Helpers

private func traceabilityRecords() throws -> [CaptureRecord] {
  let manifest = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("docs/specifications/screenshot-traceability-v1.json")
  let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
  let captures = try #require(json?["captures"] as? [[String: Any]])
  return captures.enumerated().map {
    CaptureRecord(
      number: $0.offset + 1, route: $0.element["route_id"] as? String ?? "",
      state: $0.element["state_id"] as? String ?? "",
      manifestPath: $0.element["synthetic_capture_path"] as? String)
  }
}

private func captureDirectory() throws -> URL {
  let base =
    ProcessInfo.processInfo.environment["LEDGER_ATLAS_TEST_ARTIFACTS"].map {
      URL(fileURLWithPath: $0)
    } ?? FileManager.default.temporaryDirectory.appendingPathComponent("ledger-atlas-\(UUID())")
  let url = base.appendingPathComponent("ui-captures", isDirectory: true)
  try? FileManager.default.removeItem(at: url)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// Not blank, not tiny, the expected text on screen, and no home-folder path.
///
/// Limits: the text comes from the Accessibility tree, not the pixels. For a scrolled shot it
/// also includes what the screen said before scrolling, so it shows the screen's content, not
/// that the scrolled part is in view (the scroll itself is checked where it happens). The
/// home-folder check likewise reads that text, so a path drawn only as pixels would pass.
private func expectUsable(_ png: Data, text: [String], expecting: [String], for key: String) {
  #expect(png.count > 20_000, "\(key): capture is only \(png.count) bytes; it looks blank")
  if let image = NSBitmapImageRep(data: png) {
    #expect(distinctColours(in: image) > 8, "\(key): capture is almost one colour")
  }
  let joined = text.joined(separator: "\n")
  for expected in expecting {
    #expect(joined.contains(expected), "\(key): \"\(expected)\" is not on screen")
  }
  #expect(!joined.contains("/Users/"), "\(key): a home-folder path is on screen")
}

private func distinctColours(in image: NSBitmapImageRep) -> Int {
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
  return seen.count
}

/// Window size for captures: it fits on the runner's 1024 x 768 display, so the window server
/// has drawn all of it.
let captureSize = NSSize(width: 1000, height: 700)

func captureLog(_ line: String) {
  FileHandle.standardError.write(Data("CAPTURE \(line)\n".utf8))
}

/// The window as a PNG, and how it was taken. `screencapture` shows what the window server
/// composited, which is what a person sees. AppKit's own cached drawing leaves out much of
/// SwiftUI (the sidebar, most labels) yet still passes the size and colour checks, so it is
/// only a fallback for a local Mac without Screen Recording permission, and CI fails on it.
@MainActor
func windowPNG(_ window: NSWindow) -> (png: Data, method: String)? {
  window.contentView?.layoutSubtreeIfNeeded()
  window.displayIfNeeded()
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(
    "capture-\(UUID().uuidString).png")
  defer { try? FileManager.default.removeItem(at: file) }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
  if (try? process.run()) != nil {
    let deadline = Date().addingTimeInterval(15)
    while process.isRunning, Date() < deadline { pump(0.05) }
    if !process.isRunning, process.terminationStatus == 0,
      let data = try? Data(contentsOf: file), data.count > 1_000
    {
      return (data, "screencapture")
    }
  }
  captureLog("screencapture failed for window \(window.windowNumber); using AppKit's drawing")
  if ProcessInfo.processInfo.environment["CI"] != nil {
    Issue.record("screencapture failed on CI; AppKit's drawing is not accepted there")
  }
  return pngData(of: window).map { ($0, "appkit-drawing") }
}

@MainActor
private func pngData(of window: NSWindow) -> Data? {
  window.contentView?.layoutSubtreeIfNeeded()
  guard let view = window.contentView?.superview ?? window.contentView,
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
  else { return nil }
  view.cacheDisplay(in: view.bounds, to: rep)
  return rep.representation(using: .png, properties: [:])
}

/// Scrolls the main content (the widest scroll view, not the sidebar) to the top, middle or
/// bottom, and says whether the view really moved away from the top.
@MainActor
@discardableResult
private func scroll(_ window: NSWindow, to position: CaptureScroll) -> ScrollOutcome {
  func scrollViews(in view: NSView) -> [NSScrollView] {
    ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
  }
  guard let content = window.contentView,
    let main = scrollViews(in: content).max(by: { $0.frame.width < $1.frame.width }),
    let document = main.documentView
  else { return .noScrollView }
  let clip = main.contentView
  // The window's content runs under the title bar and the sidebar, so the clip view is
  // inset: its resting origin is (-left, -top), not (0, 0). Keep x as it is, or the rows
  // slide under the sidebar.
  let insets = main.contentInsets
  let travel = max(0, document.frame.height - clip.bounds.height + insets.top + insets.bottom)
  let fraction: CGFloat =
    switch position {
    case .top: 0
    case .middle: 0.5
    case .bottom: 1
    }
  let y =
    document.isFlipped
    ? -insets.top + travel * fraction : -insets.bottom + travel * (1 - fraction)
  clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
  main.reflectScrolledClipView(clip)
  let top = document.isFlipped ? -insets.top : -insets.bottom + travel
  if travel < 1 { return .contentFits }
  return abs(clip.bounds.origin.y - top) > 1 ? .moved : .atTop
}

enum ScrollOutcome: String {
  case moved, atTop = "at top", contentFits = "content fits", noScrollView = "no scroll view"
}

/// Runs the main run loop briefly and logs any run that ends early, so a stray stop of the
/// main run loop (which ends the test process) shows where it came from.
@MainActor
private func drainLog(_ step: String, seconds: Double = 0.3) {
  for _ in 0..<Int(seconds / 0.05) {
    let result = CFRunLoopRunInMode(.defaultMode, 0.05, false)
    if result != .timedOut { captureLog("\(step): run loop returned \(result.rawValue)") }
  }
}

func pump(_ seconds: TimeInterval) {
  RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// The AppKit screen frame (bottom-left origin) of the first element in the window whose
/// label or title is `name`, read in-process on the main thread.
@MainActor
private func inProcessFrame(in window: NSWindow, named name: String) -> CGRect? {
  func find(_ element: NSObject, depth: Int) -> CGRect? {
    guard depth < 80 else { return nil }
    let names = ["accessibilityLabel", "accessibilityTitle"].compactMap {
      let value = inProcessProperty(element, $0)
      return value as? String ?? (value as? NSAttributedString)?.string
    }
    if names.contains(name), let element = element as? any NSAccessibilityElementProtocol {
      return element.accessibilityFrame()
    }
    for child in inProcessProperty(element, "accessibilityChildren") as? [NSObject] ?? [] {
      if let found = find(child, depth: depth + 1) { return found }
    }
    return nil
  }
  return find(window, depth: 0)
}

/// What the menu timer saw, shared with the code waiting for it on the main thread.
@MainActor
private final class PickBox {
  let menu: NSMenu
  var ticks = 0
  var chosen = false
  var closeAttempts = 0
  var titles: [String] = []
  init(menu: NSMenu) { self.menu = menu }
}

extension MountedRoot {
  /// Clicks a control the way the mouse does: finds it by its spoken name in the
  /// Accessibility tree (reading only), then sends a mouse down and up at its centre.
  /// Returns false if there is no such control.
  func click(named name: String, in target: NSWindow? = nil) -> Bool {
    let window = target ?? self.window
    let frame: CGRect?
    if readsInProcess || target != nil {
      frame = inProcessFrame(in: window, named: name)
    } else {
      let pid = ProcessInfo.processInfo.processIdentifier
      let identifier = identifier
      let result = FrameBox()
      Thread.detachNewThread {
        result.finish(accessibilityFrame(pid: pid, windowIdentifier: identifier, named: name))
      }
      let deadline = Date().addingTimeInterval(20)
      while !result.isDone, Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
      }
      // System Accessibility frames are in screen points from the top left; AppKit's from
      // the bottom left.
      frame = result.frame.flatMap { found in
        NSScreen.screens.first.map {
          CGRect(
            x: found.minX, y: $0.frame.maxY - found.maxY, width: found.width,
            height: found.height)
        }
      }
    }
    guard let frame else {
      captureLog("nothing named \(name) to click")
      return false
    }
    let centre = NSPoint(x: frame.midX, y: frame.midY)
    let location = window.convertPoint(fromScreen: centre)
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
    return true
  }

  /// Picks an item from the pop-up button with this accessibility label (or else the n-th
  /// pop-up, top to bottom), as choosing it with the mouse would, without opening the menu.
  func chooseMenuItem(_ title: String, from label: String, orRow row: Int) -> Bool {
    func popUps(in view: NSView) -> [NSPopUpButton] {
      ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap(popUps)
    }
    guard let content = window.contentView else { return false }
    let ordered = popUps(in: content).sorted {
      $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY
    }
    let described = ordered.map { ($0.accessibilityLabel() ?? "-") + ($0.isEnabled ? "" : " (off)") }
    captureLog("pop-ups: \(described)")
    let popUp =
      ordered.first { $0.accessibilityLabel() == label }
      ?? (ordered.indices.contains(row) ? ordered[row] : nil)
    guard let popUp, let menu = popUp.menu else {
      captureLog("no pop-up \(label) or \(row); \(ordered.count) pop-ups")
      return false
    }
    // SwiftUI fills the menu only while it is open, so open it with a mouse press. The
    // press runs the menu's own tracking loop; a timer in that loop picks the item.
    let picked = PickBox(menu: menu)
    let timer = Timer(timeInterval: 0.25, repeats: true) { timer in
      let finished = MainActor.assumeIsolated { () -> Bool in
        let menu = picked.menu
        picked.ticks += 1
        if picked.chosen || picked.ticks > 20 {
          // Still open: the timer only runs while the press is tracking the menu. Close it
          // with Escape, as a person would, and as a last resort cancel the tracking.
          picked.closeAttempts += 1
          if picked.closeAttempts > 8 {
            menu.cancelTracking()
            return true
          }
          if picked.closeAttempts == 1, let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
            keyCode: 53)
          {
            NSApplication.shared.postEvent(escape, atStart: false)
          }
          return false
        }
        if let index = menu.items.firstIndex(where: { $0.title == title }) {
          picked.titles = menu.items.map(\.title)
          // Choose the item while the menu is open, as a click on it does.
          menu.performActionForItem(at: index)
          picked.chosen = true
        }
        return false
      }
      if finished { timer.invalidate() }
    }
    RunLoop.main.add(timer, forMode: .common)
    let location = popUp.convert(NSPoint(x: popUp.bounds.midX, y: popUp.bounds.midY), to: nil)
    // The press returns once the menu closes.
    if let press = NSEvent.mouseEvent(
      with: .leftMouseDown, location: location, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    {
      window.sendEvent(press)
    }
    timer.invalidate()
    captureLog(
      "press returned; chosen \(picked.chosen) after \(picked.ticks) ticks, "
        + "\(picked.closeAttempts) close attempts")
    drainLog("menu closed")
    guard picked.chosen else {
      captureLog("pop-up \(row) has \(picked.titles), not \(title)")
      return false
    }
    return true
  }
}

private final class FrameBox: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  private var found: CGRect?
  var isDone: Bool { lock.withLock { done } }
  var frame: CGRect? { lock.withLock { found } }
  func finish(_ frame: CGRect?) { lock.withLock { found = frame; done = true } }
}

/// The screen frame of the first element in the window whose spoken name is `name`.
private func accessibilityFrame(pid: pid_t, windowIdentifier: String, named name: String) -> CGRect? {
  let app = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(app, 5)
  func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
  }
  func frame(of element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute),
      let size = attribute(element, kAXSizeAttribute),
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin)
    AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
    return CGRect(origin: origin, size: extent)
  }
  func find(_ element: AXUIElement, depth: Int) -> CGRect? {
    guard depth < 80 else { return nil }
    if [kAXDescriptionAttribute, kAXTitleAttribute].contains(where: {
      attribute(element, $0) as? String == name
    }), let found = frame(of: element) {
      return found
    }
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
      if let found = find(child, depth: depth + 1) { return found }
    }
    return nil
  }
  for window in (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
  where attribute(window, kAXIdentifierAttribute) as? String == windowIdentifier {
    if let found = find(window, depth: 0) { return found }
  }
  return nil
}
