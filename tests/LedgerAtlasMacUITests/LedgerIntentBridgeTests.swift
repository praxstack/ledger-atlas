import Foundation
import Testing

@testable import LedgerAtlasMacUI

@MainActor
@Test func intentBridgeQueuesOneTypedRequestAndNeverOverwritesIt() throws {
  _ = LedgerIntentBridge.consume()
  let request = LedgerIntentRequest(
    kind: .addExpense, amountLiteral: "12.34", note: "synthetic")
  try LedgerIntentBridge.enqueue(request)
  #expect(throws: LedgerIntentError.alreadyPending) {
    try LedgerIntentBridge.enqueue(.init(kind: .openBudgets))
  }
  #expect(LedgerIntentBridge.consume() == request)
  #expect(LedgerIntentBridge.consume() == nil)
}

@Test func expiredOrUnreadableRequestsNeverJamTheQueue() throws {
  let suite = "LedgerAtlasMacUITests.intent.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let start: Int64 = 1_800_000_000_000
  let old = LedgerIntentRequest(kind: .addExpense, createdAtMilliseconds: start)
  try LedgerIntentBridge.enqueue(old, in: defaults, now: start)

  // Still fresh: a second request is refused.
  #expect(throws: LedgerIntentError.alreadyPending) {
    try LedgerIntentBridge.enqueue(
      .init(kind: .openBudgets, createdAtMilliseconds: start + 1), in: defaults, now: start + 1)
  }
  // Once expired, the old one is replaced instead of blocking.
  let later = start + LedgerIntentRequest.lifetimeMilliseconds + 1
  let fresh = LedgerIntentRequest(kind: .openBudgets, createdAtMilliseconds: later)
  try LedgerIntentBridge.enqueue(fresh, in: defaults, now: later)
  #expect(LedgerIntentBridge.consume(from: defaults, now: later) == fresh)

  // An expired request is cleared, not returned.
  try LedgerIntentBridge.enqueue(fresh, in: defaults, now: later)
  #expect(LedgerIntentBridge.consume(from: defaults, now: later * 2) == nil)
  #expect(defaults.data(forKey: LedgerIntentBridge.key) == nil)

  // Unreadable bytes, or a request from a build without a timestamp, are cleared too.
  defaults.set(Data("junk".utf8), forKey: LedgerIntentBridge.key)
  #expect(LedgerIntentBridge.consume(from: defaults, now: later) == nil)
  #expect(defaults.data(forKey: LedgerIntentBridge.key) == nil)
  defaults.set(Data(#"{"id":"x","kind":"addIncome"}"#.utf8), forKey: LedgerIntentBridge.key)
  try LedgerIntentBridge.enqueue(fresh, in: defaults, now: later)
  #expect(LedgerIntentBridge.consume(from: defaults, now: later) == fresh)
}
