import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

// Synthetic data only: every name, amount and date here is made up.

private func key(_ character: Character) -> String { String(repeating: character, count: 64) }

private func fileChecksum(_ url: URL) throws -> String {
  try LedgerStore.openReadOnly(at: url).semanticChecksum()
}

@MainActor
@Test func backupsRestoreTwiceMergeAndResetWithoutTouchingTheOriginal() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let original = directory.appendingPathComponent("original.sqlite")
  let suite = "LedgerAtlasMacUITests.backup.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let bookmarks = SecurityScopedBookmarkStore(
    defaults: defaults, makeBookmark: { Data($0.path.utf8) },
    resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) })

  let journey = LedgerJourney()
  let created = await LedgerAtlasRootView.performLedgerLifecycle(
    .create, at: original, bookmarkStore: bookmarks, widgetPublisher: .init(write: { _ in }),
    journey: journey, session: LedgerSession(testingScopeStarter: { _ in true }),
    scopeStarter: { _ in true }, scopeStopper: { _ in })
  #expect(created.kind == .created)
  try journey.performBeginEditing()
  let origin = try LedgerOrigin.macNative()
  let wallet = try LedgerAccount(
    id: try StableLedgerID.account(origin: origin, localKey: key("a")), name: "Wallet",
    currencyUnit: "INR", origin: origin)
  try journey.createAccount(wallet)
  let now = UTCInstant.currentEpochMilliseconds()
  _ = try journey.createNativeTransaction(
    amountLiteral: "120", kind: .expense, accountID: wallet.id, categoryID: nil,
    note: "Synthetic tea", createdAt: UTCInstant(epochMilliseconds: now), submissionID: "one")
  let originalChecksum = try journey.checksum()

  // Two backup and restore cycles keep the checksum.
  let firstBackup = directory.appendingPathComponent("backup-1.sqlite")
  try journey.backupCanonicalLedger(to: firstBackup)
  let firstRestore = directory.appendingPathComponent("restore-1.sqlite")
  try journey.restoreCanonicalBackup(from: firstBackup, to: firstRestore)
  #expect(try fileChecksum(firstRestore) == originalChecksum)
  let secondBackup = directory.appendingPathComponent("backup-2.sqlite")
  try journey.backupCanonicalLedger(to: secondBackup)
  let secondRestore = directory.appendingPathComponent("restore-2.sqlite")
  try journey.restoreCanonicalBackup(from: secondBackup, to: secondRestore)
  #expect(try fileChecksum(secondRestore) == originalChecksum)

  // A later ledger with one more expense, merged into the restored one.
  try journey.beginEditing(firstRestore)
  _ = try journey.createNativeTransaction(
    amountLiteral: "80", kind: .expense, accountID: wallet.id, categoryID: nil,
    note: "Synthetic snack", createdAt: UTCInstant(epochMilliseconds: now + 1),
    submissionID: "two")
  try journey.beginEditing(secondRestore)
  let incoming = try LedgerJourney.incomingPackage(from: firstRestore)
  let summary = try journey.previewMerge(incoming)
  #expect(summary.addedTransactions == 1 && summary.addedAccounts == 0)
  #expect(
    LedgerJourney.mergePreviewMessage(summary).hasPrefix("Merging adds 1 new transaction."))
  let mergedURL = directory.appendingPathComponent("merged.sqlite")
  try journey.mergeIntoNewLedger(incoming, at: mergedURL)
  #expect(journey.snapshot?.transactions.count == 2)
  #expect(try fileChecksum(secondRestore) == originalChecksum)

  // Both reset scopes build a new ledger and leave the merged one as it was.
  let mergedChecksum = try fileChecksum(mergedURL)
  let contentsURL = directory.appendingPathComponent("contents-reset.sqlite")
  try journey.resetLedger(.contentsOnly, at: contentsURL)
  #expect(journey.snapshot?.accounts.map(\.id) == [wallet.id])
  #expect(journey.snapshot?.transactions.isEmpty == true)
  let completeURL = directory.appendingPathComponent("complete-reset.sqlite")
  try journey.resetLedger(.complete, at: completeURL)
  #expect(journey.snapshot?.accounts.isEmpty == true)
  #expect(try fileChecksum(mergedURL) == mergedChecksum)

  // A reset that can't finish leaves nothing behind and keeps the open ledger.
  #expect(throws: (any Error).self) {
    try journey.resetLedger(.complete, at: completeURL)
  }
  #expect(journey.ledgerURL == completeURL)
  #expect(try fileChecksum(original) == originalChecksum)
}
