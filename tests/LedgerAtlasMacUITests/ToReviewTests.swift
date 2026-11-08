import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

// #238 To Review. Synthetic data only: every name, amount and date here is made up.

/// A new empty ledger open for editing, with one account and a daily rule.
@MainActor
private func reviewLedger(in directory: URL) throws -> (
  journey: LedgerJourney, url: URL, account: LedgerAccount, rule: LedgerRecurrenceRule
) {
  let url = directory.appendingPathComponent("review.sqlite")
  _ = try LedgerStoreLifecycle.create(at: url)
  let journey = LedgerJourney()
  try journey.beginEditing(url)
  let origin = try LedgerOrigin.macNative()
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "6", count: 64)),
    name: "Synthetic wallet", currencyUnit: "INR", origin: origin)
  try journey.createAccount(account)
  let rule = try LedgerRecurrenceRule(
    id: StableLedgerID.recurrenceRule(origin: origin, localKey: String(repeating: "8", count: 64)),
    origin: origin, accountID: account.id, categoryID: nil, kind: .expense,
    amount: CurrencyAmount(unitCode: "INR", amount: ExactDecimal("40")), frequency: .daily,
    interval: 1, timeZone: SourceTimeZone(fixedOffsetSeconds: 0),
    start: SourceLocalDate(year: 2026, month: 11, day: 1))
  try journey.createRecurrence(rule)
  return (journey, url, account, rule)
}

private func temporaryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

@MainActor
@Test func generatedRecurringDatesWaitInToReviewAndTypedEntriesNever() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let (journey, _, account, rule) = try reviewLedger(in: directory)

  // Typed by the person: never waits.
  let typed = journey.saveNativeEntry(
    amountLiteral: "12", kind: .expense, accountID: account.id, categoryID: nil, note: nil,
    createdAt: UTCInstant(epochMilliseconds: 1), submissionID: UUID().uuidString, tags: .empty)
  guard case .saved = typed else {
    Issue.record("the typed entry was not saved")
    return
  }
  #expect(journey.waitingReviewIDs.isEmpty)
  let typedIDs = Set(journey.snapshot?.transactions.map(\.id) ?? [])

  try journey.generateOccurrences(
    rule, through: SourceLocalDate(year: 2026, month: 11, day: 5),
    createdAt: UTCInstant(epochMilliseconds: 2))
  let all = Set(journey.snapshot?.transactions.map(\.id) ?? [])
  #expect(all.count == typedIDs.count + 5)
  // Exactly the five generated dates wait.
  #expect(journey.waitingReviewIDs == all.subtracting(typedIDs))
  #expect(journey.rows(for: .toReview).count == 5)
}

@MainActor
@Test func markingReviewedWritesNothingToTheLedger() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let (journey, url, _, rule) = try reviewLedger(in: directory)
  try journey.generateOccurrences(
    rule, through: SourceLocalDate(year: 2026, month: 11, day: 4),
    createdAt: UTCInstant(epochMilliseconds: 2))
  let sidecar = LedgerReviewQueue.sidecarURL(forLedgerAt: url)
  #expect(FileManager.default.fileExists(atPath: sidecar.path))
  let checksum = try journey.checksum()

  let first = try #require(journey.waitingReviewIDs.sorted().first)
  journey.markReviewed([first])
  #expect(journey.waitingReviewIDs.count == 3)
  #expect(!journey.waitingReviewIDs.contains(first))
  #expect(try journey.checksum() == checksum)

  journey.markAllReviewed()
  #expect(journey.waitingReviewIDs.isEmpty)
  #expect(try journey.checksum() == checksum)
  // Nothing waits, so nothing is kept beside the ledger.
  #expect(!FileManager.default.fileExists(atPath: sidecar.path))
}

@MainActor
@Test func closedAndEditedEntriesDropOffToReview() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let (journey, _, _, rule) = try reviewLedger(in: directory)
  try journey.generateOccurrences(
    rule, through: SourceLocalDate(year: 2026, month: 11, day: 3),
    createdAt: UTCInstant(epochMilliseconds: 2))
  let waiting = journey.waitingReviewIDs.sorted()
  #expect(waiting.count == 3)

  try journey.tombstoneTransaction(
    transactionID: waiting[0], createdAt: UTCInstant(epochMilliseconds: 3))
  #expect(!journey.waitingReviewIDs.contains(waiting[0]))

  // Editing an entry counts as checking it.
  journey.performCorrectAmount(
    transactionID: waiting[1], amountLiteral: "41", createdAt: UTCInstant(epochMilliseconds: 4))
  #expect(journey.lastFailure == nil)
  #expect(journey.waitingReviewIDs == [waiting[2]])
}

@MainActor
@Test func theToReviewListSurvivesARelaunch() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let (journey, url, _, rule) = try reviewLedger(in: directory)
  try journey.generateOccurrences(
    rule, through: SourceLocalDate(year: 2026, month: 11, day: 3),
    createdAt: UTCInstant(epochMilliseconds: 2))
  journey.markReviewed([try #require(journey.waitingReviewIDs.sorted().first)])
  let waiting = journey.waitingReviewIDs
  #expect(waiting.count == 2)
  journey.closeLedger()
  #expect(journey.waitingReviewIDs.isEmpty)

  let relaunched = LedgerJourney()
  relaunched.openLedger(url)
  #expect(relaunched.waitingReviewIDs == waiting)
}

@Test func toReviewIsInTheSidebarWithItsOwnWords() {
  #expect(AppDestination.SidebarSection.money.destinations.contains(.toReview))
  #expect(AppDestination.toReview.sidebarTitle == "To Review")
  #expect(LedgerReviewMode.waitingText(1) == "1 entry to review")
  #expect(LedgerReviewMode.waitingText(3) == "3 entries to review")
  #expect(LedgerReviewMode.emptyText.hasPrefix("Entries the app adds for you"))
}
