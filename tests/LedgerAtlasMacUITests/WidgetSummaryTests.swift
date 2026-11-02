import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

// Synthetic data only.

private func key(_ character: Character) -> String { String(repeating: character, count: 64) }

@MainActor
@Test func theReadyWidgetCountsThisMonthsEntriesAndNoNamesOrAmounts() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let suite = "LedgerAtlasMacUITests.widget.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let bookmarks = SecurityScopedBookmarkStore(
    defaults: defaults, makeBookmark: { Data($0.path.utf8) },
    resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) })

  let journey = LedgerJourney()
  _ = await LedgerAtlasRootView.performLedgerLifecycle(
    .create, at: directory.appendingPathComponent("widget.sqlite"), bookmarkStore: bookmarks,
    widgetPublisher: .init(write: { _ in }), journey: journey,
    session: LedgerSession(testingScopeStarter: { _ in true }),
    scopeStarter: { _ in true }, scopeStopper: { _ in })
  try journey.performBeginEditing()
  let origin = try LedgerOrigin.macNative()
  let wallet = try LedgerAccount(
    id: try StableLedgerID.account(origin: origin, localKey: key("a")), name: "Secret wallet",
    currencyUnit: "INR", origin: origin)
  try journey.createAccount(wallet)
  let generation = journey.snapshotGeneration
  let now = UTCInstant.currentEpochMilliseconds()
  for (index, amount) in ["120", "75"].enumerated() {
    _ = try journey.createNativeTransaction(
      amountLiteral: amount, kind: .expense, accountID: wallet.id, categoryID: nil,
      note: "Private note", createdAt: UTCInstant(epochMilliseconds: now + Int64(index)),
      submissionID: "w\(index)")
  }
  #expect(journey.snapshotGeneration > generation)

  let projection = LedgerAtlasRootView.widgetProjection(for: .ready, journey: journey)
  #expect(projection.summary == .init(entriesThisMonth: 2, budgets: .none))
  let json = String(decoding: try JSONEncoder().encode(projection), as: UTF8.self)
  for secret in ["Secret", "wallet", "Private", "120", "75", "INR"] {
    #expect(!json.contains(secret))
  }
  #expect(LedgerAtlasRootView.widgetProjection(for: .locked, journey: journey) == .locked)
}
