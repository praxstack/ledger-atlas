import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

@Test func demoLedgerIsComplete() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = try #require(try LedgerDemoTour.demoLedgerURL(in: directory))
  try LedgerDemoTour.makeDemoLedger(at: url)

  let snapshot = try LedgerStoreLifecycle.open(at: url).store.readSnapshot()
  #expect(snapshot.accounts.count == 7)
  #expect(snapshot.accountGroups.count == 3)
  #expect(snapshot.accounts.filter(\.hidden).count == 1)
  #expect(snapshot.categories.filter { $0.parentID != nil }.count == 1)
  #expect(snapshot.categories.count == 6)
  #expect(snapshot.tags.count == 3)
  #expect(snapshot.memos.count == 2)
  #expect(snapshot.recurrenceRules.count == 1)
  #expect(snapshot.budgets.count == 1)
  // Two opening balances, three months of 16 entries and a transfer, then a currency
  // transfer and its fee.
  #expect(snapshot.transactions.count == 3 * 17 + 2 + 2)
  #expect(
    snapshot.transactions.contains {
      $0.currentRevision.draft.sourceLiterals.contains { $0.field == "conversion.rate" }
    })
  #expect(Set(snapshot.accounts.map(\.currencyUnit)) == ["INR", "USD"])
}

@Test func demoTourRefusesWhereLedgersExistAndCleansUp() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = try #require(try LedgerDemoTour.demoLedgerURL(in: directory))
  try LedgerDemoTour.makeDemoLedger(at: url)
  // A ledger is now present, so a second tour refuses.
  #expect(try LedgerDemoTour.demoLedgerURL(in: directory) == nil)
  LedgerDemoTour.removeDemoLedger(at: url)
  // Only the store's hidden lifecycle lock may stay behind.
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { !$0.hasPrefix(".") }.isEmpty)
  #expect(try LedgerDemoTour.demoLedgerURL(in: directory) != nil)
}

@Test func demoTourIsOffUnlessRequested() {
  // CI and normal launches don't set the variable, so the tour never runs.
  #expect(ProcessInfo.processInfo.environment["LEDGER_ATLAS_DEMO_TOUR"] == nil)
  #expect(!LedgerDemoTour.isRequested)
}
