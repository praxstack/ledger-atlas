import AppKit
import Foundation
import LedgerCore
import Testing

@testable import LedgerAtlasMacUI

// Synthetic data only: the demo ledger and made-up requests.

/// #171: opening the daily reminder opens the entry form with Upcoming beside it.

@MainActor
@Test func anOpenedReminderIsTakenOnceAndAStaleOneIsDropped() {
  let opened = Date(timeIntervalSince1970: 1_800_000_000)
  LedgerReminderResponder.reminderOpened(at: opened)
  #expect(LedgerReminderResponder.isWaiting)
  #expect(LedgerReminderResponder.take(at: opened.addingTimeInterval(5)))
  #expect(!LedgerReminderResponder.isWaiting)
  #expect(!LedgerReminderResponder.take(at: opened.addingTimeInterval(6)))

  // Opened while no ledger could be shown, then found much later: dropped, not acted on.
  LedgerReminderResponder.reminderOpened(at: opened)
  #expect(!LedgerReminderResponder.take(at: opened.addingTimeInterval(LedgerReminderResponder.lifetime + 1)))
  #expect(!LedgerReminderResponder.isWaiting)
}

@Test func aQueuedRequestFromAnEarlierBuildDoesNotAskForUpcoming() throws {
  let earlier = #"{"id":"x","kind":"addExpense","createdAtMilliseconds":1}"#
  let request = try JSONDecoder().decode(LedgerIntentRequest.self, from: Data(earlier.utf8))
  #expect(!request.showsUpcoming)
  let reminder = LedgerIntentRequest(kind: .addExpense, showsUpcoming: true)
  let decoded = try JSONDecoder().decode(
    LedgerIntentRequest.self, from: JSONEncoder().encode(reminder))
  #expect(decoded == reminder)
}

@Test func theReminderTextStaysNeutral() {
  let content = LedgerNotificationScheduler.reminderContent()
  // No streaks and no "days missed" counts: the same words every day, with no number in them.
  let hasNumber = content.body.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
  #expect(content.body == "Review your Ledger Atlas activity.")
  #expect(!hasNumber)
}

@MainActor
@Test func theDailyReminderOpensTheEntryFormWithUpcomingBeside() async throws {
  let root = try await MountedRoot(
    showing: .ledger, size: NSSize(width: 1100, height: 800), appWindow: true,
    readsInProcess: true)
  defer {
    // Dismiss the sheet with its own Cancel button, as the capture set does: ending it from
    // outside, or closing the window under it, has ended the whole test process.
    if let sheet = root.window.attachedSheet, root.click(named: "Cancel", in: sheet) {
      for _ in 0..<30 where root.window.attachedSheet != nil { pump(0.1) }
    }
    if let attached = root.window.attachedSheet { root.window.endSheet(attached) }
    pump(0.3)
    root.close()
    pump(1)
  }
  #expect(!root.showsNoLedgerPrompt, "the demo ledger never opened")
  LedgerReminderResponder.reminderOpened()
  var sheet: NSWindow?
  for _ in 0..<40 {
    try await Task.sleep(for: .milliseconds(200))
    if let attached = root.window.attachedSheet {
      sheet = attached
      break
    }
  }
  let form = try #require(sheet, "the reminder did not open the entry form")
  var text: [String] = []
  for _ in 0..<20 {
    pump(0.2)
    text = inProcessAccessibilityTree(of: form).map { "\($0.spokenName) \($0.value)" }
    if text.contains(where: { $0.contains("Overdue") }) { break }
  }
  // The form itself, and Upcoming beside it made for the test's fixed day.
  #expect(text.contains { $0.contains("Amount") }, "no entry form: \(text)")
  #expect(text.contains { $0.contains("Upcoming") }, "no Upcoming beside the form: \(text)")
  #expect(text.contains { $0.contains("Overdue") }, "the unentered 3 Nov rent is not overdue: \(text)")
  #expect(!LedgerReminderResponder.isWaiting)
}
