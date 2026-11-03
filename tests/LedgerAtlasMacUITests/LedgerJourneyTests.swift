import CSQLite
import CryptoKit
import Darwin
import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

@MainActor
@Test func recordedFailuresReplaceThePreviousFailure() {
  let journey = LedgerJourney()

  journey.recordFailure("Widget status could not be published.")
  journey.recordFailure("Ledger access was not granted.")

  #expect(journey.lastFailure == "Ledger access was not granted.")
}

@MainActor
@Test func widgetPublicationFailureKeepsTheWidgetAndFlowFailuresTogetherOnce() {
  #expect(
    LedgerAtlasRootView.failureMessage(
      widgetPublished: false, flowFailure: "Ledger access was not granted.")
      == "Widget status could not be published. Ledger access was not granted.")
  #expect(
    LedgerAtlasRootView.failureMessage(
      widgetPublished: true, flowFailure: "Ledger access was not granted.")
      == "Ledger access was not granted.")
}

@MainActor
@Test func failedWidgetPublicationClosesTheSessionAndOpenedJourney() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("synthetic.sqlite")
  try writeSyntheticV19(to: source)
  let journey = LedgerJourney()
  try journey.selectSource(
    source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
    sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
  try LedgerShell.approve(journey, into: LedgerSession())
  try journey.performBeginEditing()
  let stops = TestScopeCounts()
  let presentation = LedgerSession.Presentation(
    snapshot: .init(
      accounts: [], transactions: [], revisionHistory: [], undisplayedImportedEventCount: 0))
  let session = LedgerSession(
    testingLoader: { _ in presentation }, testingScopeStarter: { _ in true },
    testingScopeStopper: { _ in stops.increment() })
  #expect(session.open(try #require(journey.ledgerURL), requiresSecurityScope: true))
  for _ in 0..<100 where session.screen == .loading { try? await Task.sleep(for: .milliseconds(1)) }

  let publisher = RedactedWidgetProjectionPublisher(write: { _ in
    throw CocoaError(.fileWriteNoPermission)
  })
  #expect(
    !LedgerAtlasRootView.publishWidget(
      .ready, publisher: publisher, journey: journey, session: session))

  #expect(session.screen == .noLedger)
  #expect(stops.value == 1)
  #expect(journey.ledgerURL == nil)
  #expect(journey.snapshot == nil)
  #expect(!journey.isEditing)
}

@MainActor
@Test func readyWidgetFailurePreservesApprovedImportSessionAndBookmark() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("synthetic.sqlite")
  try writeSyntheticV19(to: source)
  let journey = LedgerJourney()
  let session = LedgerSession()
  try journey.selectSource(
    source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
    sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
  try LedgerShell.approve(journey, into: session)
  for _ in 0..<200 where session.screen == .loading {
    try? await Task.sleep(for: .milliseconds(1))
  }
  let ledgerURL = try #require(journey.ledgerURL)
  let suite = "LedgerAtlasMacUITests.import-bookmark.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let bookmarks = SecurityScopedBookmarkStore(
    defaults: defaults, makeBookmark: { Data($0.path.utf8) },
    resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) })
  try bookmarks.save(ledgerURL, for: .canonicalLedger)

  #expect(
    !LedgerAtlasRootView.publishWidget(
      .ready,
      publisher: .init(write: { _ in throw CocoaError(.fileWriteNoPermission) }),
      journey: journey, session: session, closeLedgerOnFailure: false))

  #expect(bookmarks.reopen(.canonicalLedger) == .resolved(ledgerURL))
  #expect(session.screen == .loaded)
  #expect(journey.phase == .imported)
  #expect(journey.ledgerURL == ledgerURL)
  #expect(journey.snapshot != nil)
  #expect(journey.lastFailure == "Widget status could not be published.")
}

@MainActor
@Test func macNativeDateUsesTheDeclaredTimeZoneAtUTCDayBoundary() throws {
  let instant = UTCInstant(epochMilliseconds: 1_767_297_600_000)
  let zone = try #require(TimeZone(identifier: "Asia/Kolkata"))
  let date = try LedgerJourney.localDate(for: instant, in: zone)
  let expected = try SourceLocalDate(year: 2026, month: 1, day: 2)
  #expect(date == expected)
}

@MainActor
@Test func journeyStartsIdleAndRejectsMissingPreparation() throws {
  let journey = LedgerJourney()
  #expect(journey.phase == .idle)
  #expect(journey.summary.decision == .blocked)
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try journey.approveAndOpen(
      canonicalDatabaseURL: URL(fileURLWithPath: "/tmp/synthetic-ledger.sqlite"))
  }
  #expect(journey.phase == .failed)
  #expect(journey.lastFailure != nil)
}

@Test func destinationsCoverDeclaredDailyFinanceSurfaces() {
  let titles = Set(AppDestination.allCases.map(\.title))
  for required in [
    "Onboarding", "Import Review", "Accounts", "Ledger", "Receipts", "Local Access", "Categories", "Transfers",
    "Recurrence", "Installments", "Budgets", "Insights", "Search", "Backup", "Settings",
  ] {
    #expect(titles.contains(required))
  }
}

@MainActor
@Test func journeySelectsReviewsApprovesAndEditsASyntheticSource() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("synthetic.sqlite")
  try writeSyntheticV19(to: source)
  let staging = directory.appendingPathComponent("stage.sqlite")
  let canonical = directory.appendingPathComponent("canonical.sqlite")
  let sourceBefore = try Data(contentsOf: source)

  let journey = LedgerJourney()
  let sourceTimeZone = try SourceTimeZone(ianaIdentifier: "Asia/Kolkata")
  try journey.selectSource(
    source, stagingDatabaseURL: staging, canonicalDatabaseURL: canonical,
    sourceTimeZone: sourceTimeZone)
  #expect(journey.phase == .reviewing)
  #expect(journey.summary.decision == .reviewable)
  #expect(journey.isSourceTimeZoneSelectionLocked)
  #expect(
    journey.summary.rows.contains {
      $0.label == "Source time zone" && $0.value == "Asia/Kolkata"
    })
  #expect(!journey.summary.visibleText.contains("12.30"))
  #expect(try Data(contentsOf: source) == sourceBefore)

  try journey.approveAndOpen(canonicalDatabaseURL: canonical)
  #expect(journey.phase == .imported)
  #expect(journey.isSourceTimeZoneSelectionLocked)
  #expect(journey.ledgerURL == canonical)
  #expect(try Data(contentsOf: source) == sourceBefore)
  let imported = try #require(journey.snapshot)
  #expect(!imported.transactions.isEmpty)
  #expect(!journey.rows(for: .ledger).isEmpty)
  let importedRevision = imported.transactions[0].currentRevision
  #expect(importedRevision.draft.effects[0].amount.amount.rawLiteral == "12.30")
  #expect(importedRevision.draft.effects[0].amount.unitCode == "USD")
  let insights = journey.rows(for: .insights)
  let importedKind = importedRevision.draft.kind.rawValue
  #expect(
    insights.contains {
      $0.title == importedKind
        && ($0.detail.contains("12.30") || $0.detail.contains("12.3 "))
    })
  #expect(insights.contains { $0.detail.contains("USD") && $0.detail.contains("(") })

  try LedgerShell.beginEditing(journey)
  #expect(journey.isEditing)
  let afterImport = UTCInstant(
    epochMilliseconds: importedRevision.createdAt.epochMilliseconds + 1)
  let six = try LedgerTransactionDraft(
    effects: [
      try LedgerTransactionEffect(
        accountID: importedRevision.draft.effects[0].accountID,
        direction: importedRevision.draft.effects[0].direction,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("6.00")))
    ], categoryID: importedRevision.draft.categoryID, kind: importedRevision.draft.kind,
    occurredAt: importedRevision.draft.occurredAt, origin: importedRevision.draft.origin)
  do {
    try journey.edit(
      ledgerURL: canonical, transactionID: imported.transactions[0].id,
      expectedRevisionID: importedRevision.id, draft: six, createdAt: afterImport)
  } catch {
    Issue.record("valid journey edit of imported ledger failed: \(error)")
    throw error
  }
  let editedLiteral =
    journey.snapshot?.transactions.first?.currentRevision.draft.effects[0].amount.amount.rawLiteral
  #expect(editedLiteral == "6.00")

  let invalid = try LedgerTransactionDraft(
    effects: [
      try LedgerTransactionEffect(
        accountID: importedRevision.draft.effects[0].accountID,
        direction: importedRevision.draft.effects[0].direction,
        amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("9.00")))
    ], categoryID: importedRevision.draft.categoryID, kind: importedRevision.draft.kind,
    occurredAt: importedRevision.draft.occurredAt, origin: importedRevision.draft.origin)
  do {
    try journey.edit(
      ledgerURL: canonical, transactionID: imported.transactions[0].id,
      expectedRevisionID: importedRevision.id, draft: invalid,
      createdAt: UTCInstant(epochMilliseconds: afterImport.epochMilliseconds + 1))
    Issue.record("expected invalid edit to fail")
  } catch {
    #expect(error is LedgerApplication.Error || error is LedgerStore.Error)
  }
  let afterInvalid =
    journey.snapshot?.transactions.first?.currentRevision.draft.effects[0].amount.amount.rawLiteral
  #expect(afterInvalid == "6.00")
}

@MainActor
@Test func journeySearchAppliesQueryAndInsightsIncludeAccessibleInventory() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("synthetic.sqlite")
  try writeSyntheticV19(to: source)
  let journey = LedgerJourney()
  try journey.selectSource(
    source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
    sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
  try journey.approveAndOpen(
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"))
  #expect(!journey.rows(for: .search).isEmpty)

  journey.setSearch(LedgerSearchQuery(textContains: "no-such-memo"))
  #expect(journey.rows(for: .search).isEmpty)
  #expect(journey.searchQuery.textContains == "no-such-memo")

  try LedgerShell.beginEditing(journey)
  let imported = try #require(journey.snapshot?.transactions.first)
  let draft = imported.currentRevision.draft
  let created = try journey.createTransaction(
    idempotencyKey: String(repeating: "c", count: 64),
    draft: LedgerTransactionDraft(
      effects: draft.effects, categoryID: draft.categoryID, kind: draft.kind,
      occurredAt: draft.occurredAt, note: "find-me-note", origin: draft.origin),
    createdAt: UTCInstant(
      epochMilliseconds: imported.currentRevision.createdAt.epochMilliseconds + 2))
  journey.setSearch(LedgerSearchQuery(noteContains: "find-me"))
  let found = journey.rows(for: .search)
  #expect(found.map(\.id) == [created.transactionID])
  #expect(found[0].detail.contains("find-me-note"))

  let insights = journey.rows(for: .insights)
  #expect(insights.contains { $0.title == "Tombstones" })
  #expect(insights.contains { $0.title == "Transfers" })
  #expect(insights.contains { $0.title == "Corrections" })
  #expect(journey.insightTable.contains("Tombstones"))
  #expect(journey.insightTable.contains("Activity by kind"))
}

@MainActor
@Test func journeyBacksUpAndRestoresTheApprovedLedgerThroughTwoCycles() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("synthetic.sqlite")
  try writeSyntheticV19(to: source)
  let journey = LedgerJourney()
  try journey.selectSource(
    source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
    sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
  try journey.approveAndOpen(
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"))
  // Imported ledgers export a v4 package that carries their import history.
  let package = try journey.exportPackage()
  #expect(!package.payload.isEmpty)
  let restoredURL = directory.appendingPathComponent("restored.sqlite")
  let digest = try journey.backupCanonicalLedger(to: restoredURL)
  #expect(
    digest
      == SHA256.hash(data: try Data(contentsOf: restoredURL))
      .map { String(format: "%02x", $0) }.joined())
  #expect(LedgerAtlasRootView.backupSavedMessage(sha256: digest).hasSuffix(digest))
  let restored = LedgerJourney()
  restored.openLedger(restoredURL)
  #expect(restored.phase == .imported)
  #expect(restored.ledgerURL == restoredURL)
  let firstRows = restored.rows(for: .ledger)
  #expect(!firstRows.isEmpty)
  #expect(firstRows.contains { $0.detail.contains("12.30") || $0.detail.contains("12.3 ") })

  let restoredCopyURL = directory.appendingPathComponent("restored-copy.sqlite")
  try restored.restoreCanonicalBackup(from: restoredURL, to: restoredCopyURL)
  let copied = LedgerJourney()
  copied.openLedger(restoredCopyURL)
  #expect(copied.rows(for: .ledger).map(\.id) == firstRows.map(\.id))
  let restoredCopyChecksum = try copied.checksum()
  let restoredChecksum = try restored.checksum()
  #expect(restoredCopyChecksum == restoredChecksum)

  let secondURL = directory.appendingPathComponent("restored-again.sqlite")
  try restored.backupCanonicalLedger(to: secondURL)
  let reopened = LedgerJourney()
  reopened.openLedger(secondURL)
  #expect(reopened.rows(for: .ledger).map(\.id) == firstRows.map(\.id))
  #expect(try reopened.checksum() == journey.checksum())
}

@Test func plaintextExportWarningSaysTheCopyIsNotEncrypted() {
  let warning = LedgerJourney.plaintextExportWarning
  #expect(warning.title.contains("not encrypted"))
  #expect(warning.message.contains("Anyone who can open the file"))
}

@MainActor
@Test func journeyPortablePackageRoundTripsANativeLedger() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let accountID = try StableLedgerID.account(
    origin: origin, localKey: String(repeating: "a", count: 64))
  let source = directory.appendingPathComponent("native.sqlite")
  try writeEmptyCanonicalLedger(to: source, origin: origin, accountID: accountID)
  #expect(chmod(source.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

  let journey = LedgerJourney()
  journey.openLedger(source)
  try journey.beginEditing(source)
  let expectedChecksum = try journey.checksum()
  let packageURL = directory.appendingPathComponent("native.ledgerpackage")
  #expect(try journey.exportPortablePackage(to: packageURL) == false)
  #expect(chmod(packageURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

  let restoredURL = directory.appendingPathComponent("restored.sqlite")
  let restored = LedgerJourney()
  try restored.restorePortablePackage(from: packageURL, to: restoredURL)
  #expect(restored.phase == .imported)
  #expect(restored.ledgerURL == restoredURL)
  #expect(try restored.checksum() == expectedChecksum)
}

@MainActor
@Test func packageExportMessageNamesFallbacksForImportedHistory() {
  #expect(
    LedgerJourney.packageExportSuccessMessage(includesImportHistory: false)
      == "Portable package exported.")
  let imported = LedgerJourney.packageExportSuccessMessage(includesImportHistory: true)
  #expect(imported.contains("receipt key"))
  #expect(imported.contains(".mmbak"))
  #expect(imported.contains("XLSX"))
  #expect(
    LedgerJourney.packageExportFailureMessage(for: LedgerApplication.Error.packageTooLarge)
      .contains("Save 1:1 backup"))
  #expect(
    LedgerJourney.packageExportFailureMessage(for: LedgerApplication.Error.invalidCommand)
      == "Portable package export failed.")
}

@MainActor
@Test func backupRejectsAReplacementAtTheOpenedLedgerPath() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let firstURL = directory.appendingPathComponent("first.sqlite")
  let secondURL = directory.appendingPathComponent("second.sqlite")
  let parkedURL = directory.appendingPathComponent("parked.sqlite")
  let backupURL = directory.appendingPathComponent("backup.sqlite")
  let originA = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let originB = try LedgerOrigin(id: String(repeating: "2", count: 64), label: "local")
  try writeEmptyCanonicalLedger(
    to: firstURL, origin: originA,
    accountID: StableLedgerID.account(
      origin: originA, localKey: String(repeating: "a", count: 64)))
  try writeEmptyCanonicalLedger(
    to: secondURL, origin: originB,
    accountID: StableLedgerID.account(
      origin: originB, localKey: String(repeating: "b", count: 64)))
  #expect(chmod(firstURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
  #expect(chmod(secondURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
  let journey = LedgerJourney()
  journey.openLedger(firstURL)
  let openedChecksum = try journey.checksum()
  try FileManager.default.moveItem(at: firstURL, to: parkedURL)
  try FileManager.default.moveItem(at: secondURL, to: firstURL)

  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try journey.backupCanonicalLedger(to: backupURL)
  }
  #expect(!FileManager.default.fileExists(atPath: backupURL.path))
  let replacement = LedgerJourney()
  replacement.openLedger(firstURL)
  #expect(try replacement.checksum() != openedChecksum)
}

@MainActor
@Test func failedOpenDisconnectsThePreviouslyEditableLedger() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let validURL = directory.appendingPathComponent("valid.sqlite")
  let invalidURL = directory.appendingPathComponent("invalid.sqlite")
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  try writeEmptyCanonicalLedger(
    to: validURL, origin: origin,
    accountID: StableLedgerID.account(
      origin: origin, localKey: String(repeating: "a", count: 64)))
  #expect(chmod(validURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
  try Data("not sqlite".utf8).write(to: invalidURL)
  #expect(chmod(invalidURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
  let journey = LedgerJourney()
  journey.openLedger(validURL)
  try journey.beginEditing(validURL)
  let checksum = try journey.checksum()
  #expect(journey.isEditing)

  journey.openLedger(invalidURL)

  #expect(journey.phase == .failed)
  #expect(journey.snapshot == nil)
  #expect(journey.ledgerURL == nil)
  #expect(!journey.isEditing)
  #expect(journey.rows(for: .ledger).isEmpty)
  let reopened = LedgerJourney()
  reopened.openLedger(validURL)
  #expect(try reopened.checksum() == checksum)
}

@MainActor
@Test func journeyAdoptsTheExactStoreReturnedByTheLifecycle() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("validated.sqlite")
  let result = try LedgerStoreLifecycle.create(at: url)
  let journey = LedgerJourney()

  let snapshot = try journey.openValidatedLedger(result.store, at: url)

  #expect(journey.phase == .imported)
  #expect(journey.ledgerURL == url)
  #expect(snapshot.accounts.isEmpty)
}

@MainActor
@Test func journeyDailyFinanceDestinationsFillFromNativeCommands() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("synthetic.sqlite")
  try writeSyntheticV19(to: source)
  let journey = LedgerJourney()
  try journey.selectSource(
    source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
    sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
  try journey.approveAndOpen(
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"))
  #expect(!journey.rows(for: .accounts).isEmpty)
  #expect(!journey.rows(for: .ledger).isEmpty)
  #expect(!journey.rows(for: .onboarding).isEmpty)
  #expect(journey.rows(for: .settings).contains { $0.title == "Privacy redaction" })
  #expect(journey.rows(for: .transfers).contains { $0.title == "Preserved source record" })
  #expect(journey.rows(for: .budgets).isEmpty)

  try LedgerShell.beginEditing(journey)
  let cash = try #require(journey.snapshot?.accounts.first)
  let origin = cash.origin
  let when = try SourceTemporal(
    resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 8, day: 1)),
    in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .day)
  let savings = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "b", count: 64)),
    name: "Savings", currencyUnit: cash.currencyUnit, origin: origin)
  try journey.createAccount(savings)
  let groceries = try LedgerCategory(
    id: StableLedgerID.category(origin: origin, localKey: String(repeating: "c", count: 64)),
    name: "Groceries", kind: .expense, origin: origin)
  try journey.createCategory(groceries)
  let amount = try CurrencyAmount(unitCode: cash.currencyUnit, amount: ExactDecimal("3.00"))
  _ = try journey.createTransfer(
    idempotencyKey: String(repeating: "e", count: 64), sourceAccountID: cash.id,
    destinationAccountID: savings.id, sourceAmount: amount, destinationAmount: amount,
    conversion: nil, fee: nil, feeAccountID: nil, occurredAt: when, origin: origin,
    createdAt: UTCInstant(epochMilliseconds: 8))
  _ = try journey.createSplit(
    idempotencyKey: String(repeating: "f", count: 64), accountID: cash.id,
    parentAmount: CurrencyAmount(unitCode: cash.currencyUnit, amount: ExactDecimal("4.00")),
    components: [
      (try CurrencyAmount(unitCode: cash.currencyUnit, amount: ExactDecimal("1.50")), groceries.id),
      (try CurrencyAmount(unitCode: cash.currencyUnit, amount: ExactDecimal("2.50")), groceries.id),
    ], occurredAt: when, origin: origin, createdAt: UTCInstant(epochMilliseconds: 9))
  _ = try journey.createInstallmentPlan(
    LedgerInstallmentPlan(
      id: StableLedgerID.installmentPlan(
        origin: origin, localKey: String(repeating: "1", count: 64)),
      origin: origin, accountID: cash.id, categoryID: groceries.id,
      principal: CurrencyAmount(unitCode: cash.currencyUnit, amount: ExactDecimal("6.00")),
      occurrenceCount: 2),
    occurredAt: when, createdAt: UTCInstant(epochMilliseconds: 10))
  try journey.createRecurrence(
    LedgerRecurrenceRule(
      id: StableLedgerID.recurrenceRule(
        origin: origin, localKey: String(repeating: "2", count: 64)),
      origin: origin, accountID: cash.id, categoryID: groceries.id, kind: .expense,
      amount: CurrencyAmount(unitCode: cash.currencyUnit, amount: ExactDecimal("1.00")),
      frequency: .monthly, interval: 1, timeZone: SourceTimeZone(fixedOffsetSeconds: 0),
      start: SourceLocalDate(year: 2026, month: 8, day: 1)))
  try journey.createBudget(
    LedgerBudget(
      id: StableLedgerID.budget(origin: origin, localKey: String(repeating: "3", count: 64)),
      origin: origin, name: "Food", categoryID: groceries.id,
      amount: CurrencyAmount(unitCode: cash.currencyUnit, amount: ExactDecimal("30.00")),
      period: .monthly, rollover: false, start: SourceLocalDate(year: 2026, month: 8, day: 1)))

  #expect(journey.rows(for: .accounts).contains { $0.title == "Savings" })
  #expect(journey.rows(for: .categories).contains { $0.title == "Groceries" })
  #expect(!journey.rows(for: .transfers).isEmpty)
  #expect(journey.rows(for: .installments).contains { $0.title == "6.00" || $0.title == "6" })
  #expect(journey.rows(for: .recurrence).contains { $0.title == "monthly" })
  #expect(journey.rows(for: .budgets).contains { $0.title == "Food" })
  #expect(journey.rows(for: .settings).contains { $0.title == "Reduced motion" })

  let before = try #require(journey.snapshot)
  do {
    _ = try journey.createTransfer(
      idempotencyKey: String(repeating: "a", count: 64), sourceAccountID: cash.id,
      destinationAccountID: savings.id, sourceAmount: amount, destinationAmount: amount,
      conversion: nil,
      fee: CurrencyAmount(unitCode: "EUR", amount: ExactDecimal("0.10")),
      feeAccountID: cash.id, occurredAt: when, origin: origin,
      createdAt: UTCInstant(epochMilliseconds: 11))
    Issue.record("expected mismatched fee currency to fail")
  } catch {
    #expect(error is LedgerApplication.Error || error is LedgerStore.Error)
  }
  #expect(journey.snapshot?.transactions.count == before.transactions.count)
  #expect(journey.rows(for: .budgets).contains { $0.title == "Food" })
}

@MainActor
@Test func approvedImportOpensTheSessionAndCorrectsTheSameLedger() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("synthetic.sqlite")
  try writeSyntheticV19(to: source)
  let journey = LedgerJourney()
  let session = LedgerSession()
  try journey.selectSource(
    source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
    sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))

  try LedgerShell.approve(journey, into: session)
  #expect(journey.phase == .imported)
  #expect(journey.ledgerURL != nil)
  for _ in 0..<200 where session.screen == .loading {
    try? await Task.sleep(for: .milliseconds(1))
  }
  guard case .loaded(let presentation) = session.state else {
    Issue.record("session did not load the approved ledger")
    return
  }
  #expect(!presentation.transactions.isEmpty)
  #expect(presentation.transactions[0].detail.contains("12.30"))

  try LedgerShell.beginEditing(journey)
  let imported = try #require(journey.snapshot?.transactions.first)
  try journey.correctAmount(
    transactionID: imported.id, amountLiteral: "8.25",
    createdAt: UTCInstant(
      epochMilliseconds: imported.currentRevision.createdAt.epochMilliseconds + 1))
  #expect(
    journey.snapshot?.transactions.first?.currentRevision.draft.effects[0].amount.amount.rawLiteral
      == "8.25")
}

@MainActor
@Test func journeyKeepsSourceHashThroughSelectReviewApproveAndValidAmountEdit() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("synthetic.sqlite")
  try writeSyntheticV19(to: source)
  let before = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }
    .joined()

  let journey = LedgerJourney()
  let session = LedgerSession()
  try journey.selectSource(
    source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
    sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
  #expect(journey.summary.decision == .reviewable)
  #expect(!journey.summary.visibleText.contains("12.30"))
  #expect(journey.lastFailure == nil)

  journey.performApprove(into: session)
  #expect(journey.lastFailure == nil)
  #expect(journey.phase == .imported)
  #expect(!journey.rows(for: .ledger).isEmpty)
  #expect(!journey.rows(for: .accounts).isEmpty)

  try journey.performBeginEditing()
  let imported = try #require(journey.snapshot?.transactions.first)
  journey.performCorrectAmount(
    transactionID: imported.id, amountLiteral: "8.25",
    createdAt: UTCInstant(
      epochMilliseconds: imported.currentRevision.createdAt.epochMilliseconds + 1))
  #expect(journey.lastFailure == nil)
  #expect(
    journey.snapshot?.transactions.first?.currentRevision.draft.effects[0].amount.amount.rawLiteral
      == "8.25")
  let after = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }
    .joined()
  #expect(after == before)
}

@MainActor
@Test func invalidAmountEditLeavesChecksumUnchangedAndSurfacesFailure() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("synthetic.sqlite")
  try writeSyntheticV19(to: source)
  let journey = LedgerJourney()
  try journey.selectSource(
    source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
    sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
  try LedgerShell.approve(journey, into: LedgerSession())
  try journey.performBeginEditing()
  let imported = try #require(journey.snapshot?.transactions.first)
  try journey.correctAmount(
    transactionID: imported.id, amountLiteral: "8.25",
    createdAt: UTCInstant(
      epochMilliseconds: imported.currentRevision.createdAt.epochMilliseconds + 1))
  let before = try journey.checksum()
  let hostile = "PRIVATE-AMOUNT-99.99"
  journey.performCorrectAmount(
    transactionID: imported.id, amountLiteral: hostile,
    createdAt: UTCInstant(
      epochMilliseconds: imported.currentRevision.createdAt.epochMilliseconds + 2))
  #expect(journey.lastFailure != nil)
  #expect(!(journey.lastFailure ?? "").contains(hostile))
  #expect(!(journey.lastFailure ?? "").contains("99.99"))
  #expect(try journey.checksum() == before)
  #expect(
    journey.snapshot?.transactions.first?.currentRevision.draft.effects[0].amount.amount.rawLiteral
      == "8.25")
}

@MainActor
@Test func failedApproveLeavesDestinationUnchangedAndSurfacesFailure() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("canonical.sqlite")
  let journey = LedgerJourney()
  let session = LedgerSession()
  journey.performApprove(into: session)
  #expect(journey.lastFailure != nil)
  #expect(journey.phase == .failed || journey.phase == .blocked)
  #expect(journey.snapshot == nil)
  #expect(journey.ledgerURL == nil)
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@MainActor
@Test func nativeEntryAndOrganizationCommandsRoundTrip() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("synthetic.sqlite")
  try writeSyntheticV19(to: source)
  let journey = LedgerJourney()
  try journey.selectSource(
    source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
    sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
  try journey.approveAndOpen(canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"))
  try journey.performBeginEditing()
  let imported = try #require(journey.snapshot)
  let account = try #require(imported.accounts.first)
  let sourceCategory = try #require(imported.categories.first)
  let importedTransaction = try #require(imported.transactions.first)
  #expect(importedTransaction.currentRevision.draft.categoryID == sourceCategory.id)
  let macOrigin = try LedgerOrigin.macNative()
  let group = try LedgerAccountGroup(id: String(repeating: "b", count: 64), name: "Daily")
  try journey.createAccountGroup(group)
  try journey.updateAccount(
    LedgerAccount(
      id: account.id, name: account.name, currencyUnit: account.currencyUnit,
      origin: account.origin, groupID: group.id))
  let childCategory = try LedgerCategory(
    id: String(repeating: "c", count: 64), name: "Health", kind: .expense, origin: macOrigin,
    parentID: sourceCategory.id)
  try journey.createCategory(childCategory)
  _ = try journey.createNativeTransaction(
    amountLiteral: "4.00", kind: .expense, accountID: account.id,
    categoryID: childCategory.id, note: "Pharmacy",
    createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
  let when = try LedgerJourney.nativeTemporal(
    for: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
  let purchaseID = try StableLedgerID.transaction(
    origin: macOrigin, localKey: String(repeating: "d", count: 64))
  let lines = try [
    LedgerSplitLine(
      id: try StableLedgerID.splitLine(origin: macOrigin, localKey: String(repeating: "e", count: 64)),
      amount: CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal("2.50")),
      categoryID: sourceCategory.id, description: "Groceries", displayOrder: 0),
    LedgerSplitLine(
      id: try StableLedgerID.splitLine(origin: macOrigin, localKey: String(repeating: "f", count: 64)),
      amount: CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal("2.50")),
      categoryID: childCategory.id, description: "Medicine", displayOrder: 1),
  ]
  let purchase = try journey.createSplit(
    LedgerSplitDraft(
      id: purchaseID, accountID: account.id,
      parentAmount: CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal("5.00")),
      lines: lines, occurredAt: when, note: "Mixed purchase", origin: macOrigin),
    createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
  #expect(purchase.lines.map(\.description) == ["Groceries", "Medicine"])
  #expect(purchase.total.amount.rawLiteral == "5")
  #expect(journey.snapshot?.accountGroups.contains(group) == true)
  #expect(journey.snapshot?.categories.contains(childCategory) == true)
  #expect(try LedgerApplication.splitPurchases(from: try #require(journey.snapshot)).count == 1)
  let secondAccount = try LedgerAccount(
    id: String(repeating: "9", count: 64), name: "Savings", currencyUnit: account.currencyUnit,
    origin: macOrigin)
  try journey.createAccount(secondAccount)
  let transfer = try journey.createNativeTransfer(
    sourceAccountID: account.id, destinationAccountID: secondAccount.id,
    sourceAmountLiteral: "3.25", destinationAmountLiteral: nil, rateLiteral: nil,
    feeAmountLiteral: nil, feeAccountID: nil,
    createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
  #expect(transfer.transfer.draft.kind == .transfer)
  #expect(transfer.transfer.draft.effects.count == 2)

  let beforeCopyCount = try #require(journey.snapshot).transactions.count
  let copiedRevision = try journey.copyTransaction(
    transactionID: transfer.transfer.transactionID,
    createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds() + 1))
  let copied = try #require(
    journey.snapshot?.transactions.first(where: { $0.id == copiedRevision.transactionID }))
  #expect(journey.snapshot?.transactions.count == beforeCopyCount + 1)
  #expect(copied.currentRevision.draft.origin.label == LedgerOrigin.macNativeLabel)
  try journey.tombstoneTransaction(
    transactionID: copied.id,
    createdAt: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds() + 2))
  #expect(journey.snapshot?.transactions.first(where: { $0.id == copied.id })?.currentRevision.lifecycle == .tombstoned)
}

@MainActor
@Test func amountEditKeepsRoundingTagsAndTransferLegsAndRefusesCrossCurrency() throws {
  // Review m3: cover the rounding, tag and transfer behaviour the amount-edit fix claims.
  // Uses an empty canonical ledger (no import) to keep main-actor time short.
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let canonical = directory.appendingPathComponent("canonical.sqlite")
  _ = try LedgerStoreLifecycle.create(at: canonical)
  let journey = LedgerJourney()
  try journey.beginEditing(canonical)
  let macOrigin = try LedgerOrigin.macNative()
  let when = try LedgerJourney.nativeTemporal(for: UTCInstant(epochMilliseconds: 1_000))
  let unit = "USD"
  let otherUnit = "EUR"
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: macOrigin, localKey: String(repeating: "f", count: 64)),
    name: "Synthetic primary", currencyUnit: unit, origin: macOrigin)
  try journey.createAccount(account)
  let sibling = try LedgerAccount(
    id: StableLedgerID.account(origin: macOrigin, localKey: String(repeating: "a", count: 64)),
    name: "Synthetic sibling", currencyUnit: unit, origin: macOrigin)
  let foreign = try LedgerAccount(
    id: StableLedgerID.account(origin: macOrigin, localKey: String(repeating: "b", count: 64)),
    name: "Synthetic foreign", currencyUnit: otherUnit, origin: macOrigin)
  try journey.createAccount(sibling)
  try journey.createAccount(foreign)
  func money(_ literal: String, _ code: String) throws -> CurrencyAmount {
    try CurrencyAmount(unitCode: code, amount: ExactDecimal(literal))
  }

  // Rounding policy and tag literals survive an amount edit.
  let tagged = try journey.createTransaction(
    idempotencyKey: String(repeating: "c", count: 64),
    draft: LedgerTransactionDraft(
      effects: [
        try LedgerTransactionEffect(
          accountID: account.id, direction: .decrease, amount: money("7.00", unit))
      ], categoryID: nil, kind: .expense, occurredAt: when, note: "Tagged",
      roundingPolicy: .halfEven,
      sourceLiterals: [try LedgerSourceLiteral(field: "tag", literal: "synthetic-tag")],
      origin: macOrigin),
    createdAt: UTCInstant(epochMilliseconds: 2_000))
  try journey.correctAmount(
    transactionID: tagged.transactionID, amountLiteral: "7.25",
    createdAt: UTCInstant(epochMilliseconds: 2_001))
  let editedTagged = try #require(
    journey.snapshot?.transactions.first { $0.id == tagged.transactionID }?.currentRevision.draft)
  #expect(editedTagged.roundingPolicy == .halfEven)
  #expect(editedTagged.sourceLiterals.contains { $0.field == "tag" && $0.literal == "synthetic-tag" })
  #expect(editedTagged.note == "Tagged")
  #expect(editedTagged.effects[0].amount == (try money("7.25", unit)))

  // A same-currency transfer edit moves both legs and keeps their directions.
  let local = try journey.createTransfer(
    idempotencyKey: String(repeating: "d", count: 64), sourceAccountID: account.id,
    destinationAccountID: sibling.id, sourceAmount: money("10.00", unit),
    destinationAmount: money("10.00", unit), conversion: nil, fee: nil, feeAccountID: nil,
    occurredAt: when, origin: macOrigin, createdAt: UTCInstant(epochMilliseconds: 3_000))
  let directions = local.transfer.draft.effects.map(\.direction)
  try journey.correctAmount(
    transactionID: local.transfer.transactionID, amountLiteral: "12.00",
    createdAt: UTCInstant(epochMilliseconds: 3_001))
  let editedLocal = try #require(
    journey.snapshot?.transactions.first { $0.id == local.transfer.transactionID }?
      .currentRevision.draft)
  #expect(editedLocal.effects.count == 2)
  #expect(editedLocal.effects.map(\.direction) == directions)
  #expect(try editedLocal.effects.allSatisfy { $0.amount == (try money("12.00", unit)) })

  // A cross-currency transfer edit is refused and leaves the ledger unchanged.
  let ten = try money("10.00", unit)
  let nine = try money("9.00", otherUnit)
  let fx = try journey.createTransfer(
    idempotencyKey: String(repeating: "e", count: 64), sourceAccountID: account.id,
    destinationAccountID: foreign.id, sourceAmount: ten, destinationAmount: nine,
    conversion: LedgerConversion(
      sourceAmount: ten, convertedAmount: nine, rate: ExactDecimal("1.1111"), rateScale: 4,
      rounding: .halfEven),
    fee: nil, feeAccountID: nil, occurredAt: when, origin: macOrigin,
    createdAt: UTCInstant(epochMilliseconds: 4_000))
  let before = try journey.checksum()
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try journey.correctAmount(
      transactionID: fx.transfer.transactionID, amountLiteral: "11.00",
      createdAt: UTCInstant(epochMilliseconds: 4_001))
  }
  #expect(try journey.checksum() == before)
}

@MainActor
@Test func nativeEntryIsIdempotentPerSubmissionAndRejectsFormattedDisplayStrings() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("synthetic.sqlite")
  try writeSyntheticV19(to: source)
  let journey = LedgerJourney()
  try journey.selectSource(
    source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
    sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
  try journey.approveAndOpen(
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"))
  try journey.performBeginEditing()
  let account = try #require(journey.snapshot?.accounts.first)
  let before = try #require(journey.snapshot).transactions.count
  let now = UTCInstant.currentEpochMilliseconds()

  // Pressing Save twice sends the same submission a moment apart: one transaction.
  let submission = UUID().uuidString
  let first = try journey.createNativeTransaction(
    amountLiteral: "4.00", kind: .expense, accountID: account.id, categoryID: nil, note: nil,
    createdAt: UTCInstant(epochMilliseconds: now), submissionID: submission)
  let second = try journey.createNativeTransaction(
    amountLiteral: "4.00", kind: .expense, accountID: account.id, categoryID: nil, note: nil,
    createdAt: UTCInstant(epochMilliseconds: now + 3), submissionID: submission)
  #expect(second == first)
  #expect(journey.snapshot?.transactions.count == before + 1)

  // A new form is a new submission, even with the same content.
  _ = try journey.createNativeTransaction(
    amountLiteral: "4.00", kind: .expense, accountID: account.id, categoryID: nil, note: nil,
    createdAt: UTCInstant(epochMilliseconds: now + 5), submissionID: UUID().uuidString)
  #expect(journey.snapshot?.transactions.count == before + 2)

  // Display formatting never becomes canonical money: these are rejected, nothing is written.
  let checksum = try journey.checksum()
  for formatted in ["1,234.50", "$4.00", "4.00 USD", "4,00", "\u{0664}", "1e3", "4.00\u{00A0}"] {
    #expect(throws: (any Error).self) {
      try journey.createNativeTransaction(
        amountLiteral: formatted, kind: .expense, accountID: account.id, categoryID: nil,
        note: nil, createdAt: UTCInstant(epochMilliseconds: now + 7),
        submissionID: UUID().uuidString)
    }
  }
  #expect(try journey.checksum() == checksum)
  #expect(journey.snapshot?.transactions.count == before + 2)
}

@MainActor
@Test func staleEditsReportAConflictInsteadOfAGenericFailure() {
  #expect(
    LedgerJourney.editFailureMessage(
      for: LedgerStore.Error.revisionConflict, otherwise: "Amount could not be saved.")
      .contains("changed since you opened it"))
  #expect(
    LedgerJourney.editFailureMessage(
      for: LedgerStore.Error.incompatibleCanonicalStore, otherwise: "Amount could not be saved.")
      == "Amount could not be saved.")
}

@MainActor
@Test func staleEditIsRefusedAndEntriesCorrectionsAndClosuresSurviveReopen() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
  let accountID = try StableLedgerID.account(
    origin: origin, localKey: String(repeating: "a", count: 64))
  let url = directory.appendingPathComponent("ledger.sqlite")
  try writeEmptyCanonicalLedger(to: url, origin: origin, accountID: accountID)
  #expect(chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
  let now = UTCInstant.currentEpochMilliseconds()
  var keptID = ""
  var closedID = ""
  var correctedDraft: LedgerTransactionDraft?

  do {
    let journey = LedgerJourney()
    journey.openLedger(url)
    try journey.beginEditing(url)
    let kept = try journey.createNativeTransaction(
      amountLiteral: "4.00", kind: .expense, accountID: accountID, categoryID: nil,
      note: "Lunch", createdAt: UTCInstant(epochMilliseconds: now), submissionID: "form-1")
    let closed = try journey.createNativeTransaction(
      amountLiteral: "9.00", kind: .income, accountID: accountID, categoryID: nil,
      note: nil, createdAt: UTCInstant(epochMilliseconds: now + 1), submissionID: "form-2")
    keptID = kept.transactionID
    closedID = closed.transactionID

    try journey.correctAmount(
      transactionID: keptID, amountLiteral: "5.00",
      createdAt: UTCInstant(epochMilliseconds: now + 2))
    let corrected = try #require(
      journey.snapshot?.transactions.first { $0.id == keptID }?.currentRevision)
    correctedDraft = corrected.draft
    #expect(corrected.draft.note == "Lunch")
    #expect(corrected.revision == 2 && corrected.draft.effects != kept.draft.effects)

    // An edit made from the first version, after the correction, is a conflict, not a write.
    let checksum = try journey.checksum()
    let staleDraft = try LedgerTransactionDraft(
      effects: [
        try LedgerTransactionEffect(
          accountID: accountID, direction: .decrease,
          amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("7.00")))
      ], categoryID: nil, kind: .expense, occurredAt: kept.draft.occurredAt, note: "Lunch",
      origin: kept.draft.origin)
    #expect(throws: LedgerStore.Error.revisionConflict) {
      try journey.edit(
        ledgerURL: url, transactionID: keptID, expectedRevisionID: kept.id, draft: staleDraft,
        createdAt: UTCInstant(epochMilliseconds: now + 3))
    }
    #expect(try journey.checksum() == checksum)
    #expect(journey.snapshot?.transactions.first { $0.id == keptID }?.currentRevision == corrected)

    try journey.tombstoneTransaction(
      transactionID: closedID, createdAt: UTCInstant(epochMilliseconds: now + 4))
  }

  let reopened = LedgerJourney()
  reopened.openLedger(url)
  try reopened.beginEditing(url)
  let snapshot = try #require(reopened.snapshot)
  let kept = try #require(snapshot.transactions.first { $0.id == keptID })
  #expect(kept.currentRevision.revision == 2)
  #expect(kept.currentRevision.draft == correctedDraft)
  #expect(
    snapshot.transactions.first { $0.id == closedID }?.currentRevision.lifecycle == .tombstoned)
  // The same form submitted again after reopening still records nothing new.
  let count = snapshot.transactions.count
  _ = try reopened.createNativeTransaction(
    amountLiteral: "4.00", kind: .expense, accountID: accountID, categoryID: nil,
    note: "Lunch", createdAt: UTCInstant(epochMilliseconds: now + 5), submissionID: "form-1")
  #expect(reopened.snapshot?.transactions.count == count)
  #expect(
    reopened.snapshot?.transactions.first { $0.id == keptID }?.currentRevision
      == kept.currentRevision)
}

private func writeSyntheticV19(to url: URL) throws {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  defer { sqlite3_close(database) }
  let sql = """
    PRAGMA user_version=19;
    CREATE TABLE ASSETS (uid TEXT); CREATE TABLE ZCATEGORY (uid TEXT);
    CREATE TABLE CURRENCY (uid TEXT, ISO TEXT);
    CREATE TABLE INOUTCOME (uid TEXT, assetUid TEXT, currencyUid TEXT, DO_TYPE TEXT, ctgUid TEXT, ZMONEY TEXT, WDATE TEXT, ZDATE TEXT, NOTE TEXT);
    INSERT INTO ASSETS VALUES ('asset'); INSERT INTO ZCATEGORY VALUES ('category');
    INSERT INTO CURRENCY VALUES ('currency', 'USD');
    INSERT INTO INOUTCOME VALUES ('transaction', 'asset', 'currency', '1', 'category', '12.30', '2025-02-03', '1738547200000', 'synthetic');
    """
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
}

private final class TestScopeCounts: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}

private func writeEmptyCanonicalFile(to url: URL) throws {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  defer { sqlite3_close(database) }
  for statement in CanonicalLedgerSchema.creationStatements {
    guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
      throw LedgerStore.Error.incompatibleCanonicalStore
    }
  }
  guard
    sqlite3_exec(
      database, "PRAGMA application_id=\(CanonicalLedgerSchema.applicationID)", nil, nil, nil)
      == SQLITE_OK,
    sqlite3_exec(
      database,
      "INSERT INTO ledger_meta(key, value) VALUES('schema_version', '\(CanonicalLedgerSchema.version)'), ('ledger_identity', 'ledger-atlas-canonical'), ('schema_fingerprint', '\(CanonicalLedgerSchema.fingerprint)')",
      nil, nil, nil) == SQLITE_OK
  else { throw LedgerStore.Error.incompatibleCanonicalStore }
  #expect(chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
}

private func writeEmptyCanonicalLedger(to url: URL, origin: LedgerOrigin, accountID: String) throws
{
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
  defer { sqlite3_close(database) }
  for statement in CanonicalLedgerSchema.creationStatements {
    guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
      throw LedgerStore.Error.incompatibleCanonicalStore
    }
  }
  let bootstrap = """
    PRAGMA application_id=\(CanonicalLedgerSchema.applicationID);
    INSERT INTO ledger_meta(key, value) VALUES('schema_version', '\(CanonicalLedgerSchema.version)'), ('ledger_identity', 'ledger-atlas-canonical'), ('schema_fingerprint', '\(CanonicalLedgerSchema.fingerprint)');
    INSERT INTO ledger_origin VALUES ('\(origin.id)', 'local', NULL);
    INSERT INTO ledger_account VALUES ('\(accountID)', 'Cash', 'USD', '\(origin.id)', 'active');
    """
  guard sqlite3_exec(database, bootstrap, nil, nil, nil) == SQLITE_OK else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
}

@MainActor
@Test func amountEditPreservesNoteAndSplitMetadataAndKeepsSplitsVisible() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("synthetic.sqlite")
  try writeSyntheticV19(to: source)
  let journey = LedgerJourney()
  try journey.selectSource(
    source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
    sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
  try journey.approveAndOpen(
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"))
  try journey.performBeginEditing()
  let imported = try #require(journey.snapshot)
  let account = try #require(imported.accounts.first)
  let category = try #require(imported.categories.first)
  let macOrigin = try LedgerOrigin.macNative()
  let when = try LedgerJourney.nativeTemporal(for: UTCInstant(epochMilliseconds: 1_000))

  // A plain transaction keeps its note on amount edit.
  let noted = try journey.createNativeTransaction(
    amountLiteral: "4.00", kind: .expense, accountID: account.id, categoryID: category.id,
    note: "Synthetic note", createdAt: UTCInstant(epochMilliseconds: 2_000))
  try journey.correctAmount(
    transactionID: noted.transactionID, amountLiteral: "4.50",
    createdAt: UTCInstant(epochMilliseconds: 2_001))
  let editedNote = try #require(
    journey.snapshot?.transactions.first { $0.id == noted.transactionID })
  #expect(editedNote.currentRevision.draft.note == "Synthetic note")
  #expect(editedNote.currentRevision.draft.effects[0].amount.amount.rawLiteral == "4.50")

  // Editing one split child keeps the split group readable.
  let lines = try [
    LedgerSplitLine(
      id: StableLedgerID.splitLine(origin: macOrigin, localKey: String(repeating: "e", count: 64)),
      amount: CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal("2.00")),
      categoryID: category.id, description: "One", displayOrder: 0),
    LedgerSplitLine(
      id: StableLedgerID.splitLine(origin: macOrigin, localKey: String(repeating: "f", count: 64)),
      amount: CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal("3.00")),
      categoryID: category.id, description: "Two", displayOrder: 1),
  ]
  _ = try journey.createSplit(
    LedgerSplitDraft(
      id: StableLedgerID.transaction(origin: macOrigin, localKey: String(repeating: "d", count: 64)),
      accountID: account.id,
      parentAmount: CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal("5.00")),
      lines: lines, occurredAt: when, note: "Group", origin: macOrigin),
    createdAt: UTCInstant(epochMilliseconds: 3_000))
  let child = try #require(
    journey.snapshot?.transactions.first { $0.links.contains { $0.kind == .split } })
  try journey.correctAmount(
    transactionID: child.id, amountLiteral: "2.25",
    createdAt: UTCInstant(epochMilliseconds: 3_001))
  let purchases = try LedgerApplication.splitPurchases(from: try #require(journey.snapshot))
  #expect(purchases.count == 1)
  #expect(purchases[0].lines.count == 2)

  // MACV2-07: editing the whole purchase keeps it one group; closing it closes every line.
  let purchase = purchases[0]
  let reordered = try purchase.lines.enumerated().map { index, line in
    try LedgerSplitLine(
      id: line.id,
      amount: CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal("3.00")),
      categoryID: line.categoryID, description: line.description,
      displayOrder: purchase.lines.count - 1 - index)
  }
  let edited = try journey.editSplit(
    LedgerSplitDraft(
      id: purchase.id, accountID: purchase.accountID,
      parentAmount: CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal("6.00")),
      lines: reordered, occurredAt: purchase.occurredAt, note: "Group, edited",
      origin: purchase.origin),
    createdAt: UTCInstant(epochMilliseconds: 3_002))
  #expect(edited.id == purchase.id)
  #expect(edited.lines.map(\.id) == purchase.lines.map(\.id).reversed())
  #expect(edited.note == "Group, edited")
  try journey.closeSplit(purchaseID: purchase.id, createdAt: UTCInstant(epochMilliseconds: 3_003))
  let listing = LedgerApplication.splitPurchaseListing(from: try #require(journey.snapshot))
  #expect(listing.purchases.isEmpty)
  #expect(listing.closedTransactionIDs.count == 2)
}

@MainActor
@Test func crossCurrencyTransfersDeriveTheRateFromBothAmountsAndRejectBadInput() throws {
  // MACV2-08: the amounts sent and received are the truth; the rate is derived from them.
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let canonical = directory.appendingPathComponent("canonical.sqlite")
  _ = try LedgerStoreLifecycle.create(at: canonical)
  let journey = LedgerJourney()
  try journey.beginEditing(canonical)
  let macOrigin = try LedgerOrigin.macNative()
  let usd = try LedgerAccount(
    id: StableLedgerID.account(origin: macOrigin, localKey: String(repeating: "1", count: 64)),
    name: "Synthetic USD", currencyUnit: "USD", origin: macOrigin)
  let inr = try LedgerAccount(
    id: StableLedgerID.account(origin: macOrigin, localKey: String(repeating: "2", count: 64)),
    name: "Synthetic INR", currencyUnit: "INR", origin: macOrigin)
  try journey.createAccount(usd)
  try journey.createAccount(inr)
  let now = UTCInstant.currentEpochMilliseconds()
  func literal(_ revision: LedgerTransactionRevision, _ field: String) -> String? {
    revision.draft.sourceLiterals.first(where: { $0.field == field })?.literal
  }

  // No rate typed: it is derived (source units per converted unit) and both amounts are kept.
  let submission = UUID().uuidString
  let first = try journey.createNativeTransfer(
    sourceAccountID: usd.id, destinationAccountID: inr.id, sourceAmountLiteral: "100",
    destinationAmountLiteral: "8325.50", rateLiteral: nil, feeAmountLiteral: nil,
    feeAccountID: nil, createdAt: UTCInstant(epochMilliseconds: now), submissionID: submission)
  #expect(literal(first.transfer, "conversion.sourceAmount") == "100")
  #expect(literal(first.transfer, "conversion.convertedAmount") == "8325.50")
  #expect(literal(first.transfer, "conversion.rate") == "0.0120112906")
  #expect(literal(first.transfer, "conversion.rateScale") == "10")
  let count = try #require(journey.snapshot).transactions.count

  // Saving the same form twice records one transfer.
  let again = try journey.createNativeTransfer(
    sourceAccountID: usd.id, destinationAccountID: inr.id, sourceAmountLiteral: "100",
    destinationAmountLiteral: "8325.50", rateLiteral: nil, feeAmountLiteral: nil,
    feeAccountID: nil, createdAt: UTCInstant(epochMilliseconds: now + 4), submissionID: submission)
  #expect(again.transfer == first.transfer)
  #expect(journey.snapshot?.transactions.count == count)

  // Zero or negative amounts or rates are refused and nothing is written.
  let checksum = try journey.checksum()
  let bad: [(String, String, String?)] = [
    ("100", "0", nil), ("0", "8325", nil), ("-100", "8325", nil), ("100", "-8325", nil),
    ("100", "8325", "-0.012"), ("100", "8325", "0"),
  ]
  for (sent, received, rate) in bad {
    #expect(throws: (any Error).self) {
      try journey.createNativeTransfer(
        sourceAccountID: usd.id, destinationAccountID: inr.id, sourceAmountLiteral: sent,
        destinationAmountLiteral: received, rateLiteral: rate, feeAmountLiteral: nil,
        feeAccountID: nil, createdAt: UTCInstant(epochMilliseconds: now + 8),
        submissionID: UUID().uuidString)
    }
  }
  #expect(try journey.checksum() == checksum)
  #expect(journey.snapshot?.transactions.count == count)
}

@Test func conversionPreviewShowsOneSourceUnitInTheDestinationUnit() {
  #expect(
    LedgerJourney.conversionPreview(
      sourceLiteral: "100", sourceUnit: "USD", destinationLiteral: "8325.50",
      destinationUnit: "INR") == "1 USD = 83.255 INR")
  #expect(
    LedgerJourney.conversionPreview(
      sourceLiteral: "", sourceUnit: "USD", destinationLiteral: "8325", destinationUnit: "INR")
      == nil)
  #expect(
    LedgerJourney.conversionPreview(
      sourceLiteral: "0", sourceUnit: "USD", destinationLiteral: "8325", destinationUnit: "INR")
      == nil)
  #expect(
    LedgerJourney.conversionPreview(
      sourceLiteral: "1,000", sourceUnit: "USD", destinationLiteral: "8325",
      destinationUnit: "INR") == nil)
}

@Test func impliedRateIsSourceUnitsPerConvertedUnitAndNeedsPositiveAmounts() throws {
  let source = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("100"))
  let converted = try CurrencyAmount(unitCode: "INR", amount: ExactDecimal("8325.50"))
  #expect(
    try LedgerConversion.impliedRate(sourceAmount: source, convertedAmount: converted, scale: 10)
      .rawLiteral == "0.0120112906")
  let zero = try CurrencyAmount(unitCode: "INR", amount: ExactDecimal("0"))
  #expect(throws: (any Error).self) {
    try LedgerConversion.impliedRate(sourceAmount: source, convertedAmount: zero, scale: 10)
  }
  #expect(throws: (any Error).self) {
    try LedgerConversion(
      sourceAmount: source, convertedAmount: converted, rate: ExactDecimal("-1"), rateScale: 6,
      rounding: .halfEven)
  }
}

@MainActor
@Test func longRecurrenceCatchUpRunsInBoundedBatches() throws {
  // LA-028: a daily rule started more than a year ago used to fail after 366 occurrences.
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let canonical = directory.appendingPathComponent("canonical.sqlite")
  _ = try LedgerStoreLifecycle.create(at: canonical)
  let journey = LedgerJourney()
  try journey.beginEditing(canonical)
  let origin = try LedgerOrigin.macNative()
  let account = try LedgerAccount(
    id: StableLedgerID.account(origin: origin, localKey: String(repeating: "4", count: 64)),
    name: "Synthetic daily", currencyUnit: "USD", origin: origin)
  try journey.createAccount(account)
  let rule = try LedgerRecurrenceRule(
    id: StableLedgerID.recurrenceRule(origin: origin, localKey: String(repeating: "5", count: 64)),
    origin: origin, accountID: account.id, categoryID: nil, kind: .expense,
    amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("1")), frequency: .daily,
    interval: 1, timeZone: SourceTimeZone(fixedOffsetSeconds: 0),
    start: SourceLocalDate(year: 2024, month: 1, day: 1))
  try journey.createRecurrence(rule)
  let end = try SourceLocalDate(year: 2026, month: 2, day: 4)  // 766 days
  try journey.generateOccurrences(rule, through: end, createdAt: UTCInstant(epochMilliseconds: 1))
  #expect(journey.snapshot?.transactions.count == 766)
  let checksum = try journey.checksum()
  try journey.generateOccurrences(rule, through: end, createdAt: UTCInstant(epochMilliseconds: 2))
  #expect(try journey.checksum() == checksum)
}

@MainActor
@Test func backgroundImportPreparesAndApprovesOffTheMainThreadAndOpensTheLedger() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("synthetic.sqlite")
  try writeSyntheticV19(to: source)

  let journey = LedgerJourney()
  let session = LedgerSession()
  #expect(journey.backgroundWork == nil)
  await journey.selectSourceInBackground(
    source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
    sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
  #expect(journey.backgroundWork == nil)
  #expect(journey.lastFailure == nil)
  #expect(journey.phase == .reviewing)
  #expect(journey.summary.decision == .reviewable)

  await journey.approveInBackground(into: session)
  #expect(journey.backgroundWork == nil)
  #expect(journey.lastFailure == nil)
  #expect(journey.phase == .imported)
  #expect(journey.ledgerURL == directory.appendingPathComponent("canonical.sqlite"))
  #expect(!journey.rows(for: .ledger).isEmpty)
  #expect(session.screen != .loading)

  // Approving again without a new preparation fails visibly instead of importing twice.
  await journey.approveInBackground(into: session)
  #expect(journey.lastFailure == "Import could not be approved.")
}

@MainActor
@Test func backgroundImportShowsAFileThatIsNotABackupAsBlocked() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("not-a-backup.sqlite")
  try Data("not sqlite".utf8).write(to: source)
  let journey = LedgerJourney()
  await journey.selectSourceInBackground(
    source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
    canonicalDatabaseURL: directory.appendingPathComponent("canonical.sqlite"),
    sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
  #expect(journey.backgroundWork == nil)
  #expect(journey.phase == .blocked)
  await journey.approveInBackground(into: LedgerSession())
  #expect(journey.lastFailure == "Import could not be approved.")
}

@Test func elapsedTimeReadsInSecondsThenMinutes() {
  let start = Date(timeIntervalSince1970: 0)
  #expect(LedgerElapsedTime.text(since: start, now: start.addingTimeInterval(12.7)) == "12 s")
  #expect(LedgerElapsedTime.text(since: start, now: start.addingTimeInterval(65)) == "1 min 05 s")
  #expect(LedgerElapsedTime.text(since: start, now: start.addingTimeInterval(-3)) == "0 s")
}

@MainActor
@Test func backgroundImportResultIsDroppedWhenTheLedgerIsClosedMeanwhile() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("synthetic.sqlite")
  try writeSyntheticV19(to: source)
  let canonical = directory.appendingPathComponent("canonical.sqlite")

  // Closed while the backup is being read: the review is not adopted.
  let journey = LedgerJourney()
  let preparing = Task {
    await journey.selectSourceInBackground(
      source, stagingDatabaseURL: directory.appendingPathComponent("stage.sqlite"),
      canonicalDatabaseURL: canonical, sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
  }
  while journey.backgroundWork != .preparingImport { await Task.yield() }
  journey.closeLedger()
  await preparing.value
  #expect(journey.phase == .idle)
  #expect(journey.lastFailure == nil)
  #expect(journey.backgroundWork == nil)

  // Closed while importing: the new ledger isn't adopted or shown, and the caller learns it.
  await journey.selectSourceInBackground(
    source, stagingDatabaseURL: directory.appendingPathComponent("stage2.sqlite"),
    canonicalDatabaseURL: canonical, sourceTimeZone: SourceTimeZone(fixedOffsetSeconds: 0))
  #expect(journey.phase == .reviewing)
  let session = LedgerSession()
  let importing = Task { await journey.approveInBackground(into: session) }
  while journey.backgroundWork != .importing { await Task.yield() }
  journey.closeLedger()
  #expect(await importing.value == false)
  #expect(journey.phase == .idle)
  #expect(journey.ledgerURL == nil)
  #expect(journey.snapshot == nil)
  #expect(session.screen == .noLedger)
}
