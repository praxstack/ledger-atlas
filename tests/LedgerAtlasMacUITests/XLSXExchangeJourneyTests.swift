import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

// Synthetic data only: every name, amount and date here is made up.

private func key(_ character: Character) -> String { String(repeating: character, count: 64) }

@MainActor
private func editableLedger(at url: URL) async throws -> LedgerJourney {
  let suite = "LedgerAtlasMacUITests.xlsx.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let bookmarks = SecurityScopedBookmarkStore(
    defaults: defaults, makeBookmark: { Data($0.path.utf8) },
    resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) })
  let journey = LedgerJourney()
  let created = await LedgerAtlasRootView.performLedgerLifecycle(
    .create, at: url, bookmarkStore: bookmarks, widgetPublisher: .init(write: { _ in }),
    journey: journey, session: LedgerSession(testingScopeStarter: { _ in true }),
    scopeStarter: { _ in true }, scopeStopper: { _ in })
  #expect(created.kind == .created)
  try journey.performBeginEditing()
  return journey
}

@MainActor
@Test func xlsxWorkbookMovesALedgerIntoAnotherAndReimportAddsNothing() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let source = try await editableLedger(at: directory.appendingPathComponent("source.sqlite"))
  let origin = try LedgerOrigin.macNative()
  let wallet = try LedgerAccount(
    id: try StableLedgerID.account(origin: origin, localKey: key("a")), name: "Wallet",
    currencyUnit: "INR", origin: origin)
  let savings = try LedgerAccount(
    id: try StableLedgerID.account(origin: origin, localKey: key("b")), name: "Savings",
    currencyUnit: "INR", origin: origin)
  try source.createAccount(wallet)
  try source.createAccount(savings)
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 7, day: 9)),
    in: SourceTimeZone(fixedOffsetSeconds: 19_800), precision: .day)
  let now = UTCInstant(epochMilliseconds: 1_790_000_000_000)
  let inr = { (literal: String) in
    try CurrencyAmount(unitCode: "INR", amount: ExactDecimal(literal))
  }
  _ = try source.createTransaction(
    idempotencyKey: key("1"),
    draft: try LedgerTransactionDraft(
      effects: [
        LedgerTransactionEffect(accountID: wallet.id, direction: .decrease, amount: try inr("250")),
        LedgerTransactionEffect(accountID: savings.id, direction: .increase, amount: try inr("250")),
      ], categoryID: nil, kind: .transfer, occurredAt: when, origin: origin),
    createdAt: now)

  let workbook = directory.appendingPathComponent("ledger.xlsx")
  try source.exportXLSX(to: workbook)
  try source.exportXLSX(to: workbook)  // the save panel already confirmed replacing it
  let mode = try FileManager.default.attributesOfItem(atPath: workbook.path)[.posixPermissions]
  #expect((mode as? NSNumber)?.intValue == 0o600)

  let target = try await editableLedger(at: directory.appendingPathComponent("target.sqlite"))
  let plan = try target.planXLSXImport(from: workbook)
  #expect(plan.canApply)
  #expect(
    LedgerJourney.xlsxImportPreview(plan)
      == "Importing adds 1 transaction, 2 accounts. Existing records are never changed.")
  try target.applyXLSXImport(plan, createdAt: now)
  let imported = try #require(target.snapshot)
  #expect(imported.accounts.count == 2)
  #expect(imported.transactions.count == 1)
  #expect(imported.transactions.first?.currentRevision.draft.effects.count == 2)

  let again = try target.planXLSXImport(from: workbook)
  #expect(again.isEmpty)
  #expect(
    LedgerJourney.xlsxImportPreview(again)
      == "Everything in this workbook is already in the open ledger. Nothing to add.")
}

@MainActor
@Test func xlsxImportRefusesAWorkbookThatDiffersFromTheOpenLedger() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let journey = try await editableLedger(at: directory.appendingPathComponent("ledger.sqlite"))
  let origin = try LedgerOrigin.macNative()
  let wallet = try LedgerAccount(
    id: try StableLedgerID.account(origin: origin, localKey: key("a")), name: "Wallet",
    currencyUnit: "INR", origin: origin)
  try journey.createAccount(wallet)

  let renamed = try LedgerAccount(
    id: wallet.id, name: "Old wallet", currencyUnit: "INR", origin: origin)
  let workbook = directory.appendingPathComponent("edited.xlsx")
  try LedgerXLSXExchange.xlsxData(LedgerXLSXExchange.Content(accounts: [renamed]))
    .write(to: workbook)
  let plan = try journey.planXLSXImport(from: workbook)
  #expect(!plan.canApply)
  #expect(LedgerJourney.xlsxImportPreview(plan).hasPrefix("Nothing was imported."))
  #expect(throws: LedgerStore.Error.importPlanNotApplicable) {
    try journey.applyXLSXImport(plan, createdAt: UTCInstant(epochMilliseconds: 1))
  }
  #expect(journey.snapshot?.accounts == [wallet])
}

@Test func xlsxImportPreviewCountsWithoutShowingRowContent() throws {
  let plan = LedgerXLSXImportPlan(content: .init(), existing: .init())
  #expect(plan.isEmpty)
  #expect(LedgerJourney.xlsxImportPreview(plan).contains("Nothing to add"))
}
