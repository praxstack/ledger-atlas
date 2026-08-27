import CSQLite
import CryptoKit
import Darwin
import Foundation
import LedgerCore
import LedgerStore
import Testing

@MainActor
@Test func recordedFailuresReplaceThePreviousFailure() {
  let journey = LedgerJourney()

  journey.recordFailure("Widget status could not be published.")
  journey.recordFailure("Ledger access was not granted.")

  #expect(journey.lastFailure == "Ledger access was not granted.")
}

@testable import LedgerAtlasMacUI

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
    snapshot: .init(accounts: [], transactions: [], revisionHistory: [], undisplayedImportedEventCount: 0))
  let session = LedgerSession(
    testingLoader: { _ in presentation }, testingScopeStarter: { _ in true },
    testingScopeStopper: { _ in stops.increment() })
  #expect(session.open(try #require(journey.ledgerURL), requiresSecurityScope: true))
  for _ in 0..<100 where session.screen == .loading { try? await Task.sleep(for: .milliseconds(1)) }

  let publisher = RedactedWidgetProjectionPublisher(write: { _ in
    throw CocoaError(.fileWriteNoPermission)
  })
  #expect(!LedgerAtlasRootView.publishWidget(
    .ready, publisher: publisher, journey: journey, session: session))

  #expect(session.screen == .noLedger)
  #expect(stops.value == 1)
  #expect(journey.ledgerURL == nil)
  #expect(journey.snapshot == nil)
  #expect(!journey.isEditing)
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
    "Onboarding", "Import Review", "Accounts", "Ledger", "Categories", "Transfers",
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
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    _ = try journey.exportPackage()
  }
  let restoredURL = directory.appendingPathComponent("restored.sqlite")
  try journey.backupCanonicalLedger(to: restoredURL)
  let restored = LedgerJourney()
  restored.openLedger(restoredURL)
  #expect(restored.phase == .imported)
  #expect(restored.ledgerURL == restoredURL)
  let firstRows = restored.rows(for: .ledger)
  #expect(!firstRows.isEmpty)
  #expect(firstRows.contains { $0.detail.contains("12.30") || $0.detail.contains("12.3 ") })

  let secondURL = directory.appendingPathComponent("restored-again.sqlite")
  try restored.backupCanonicalLedger(to: secondURL)
  let reopened = LedgerJourney()
  reopened.openLedger(secondURL)
  #expect(reopened.rows(for: .ledger).map(\.id) == firstRows.map(\.id))
  #expect(try reopened.checksum() == journey.checksum())
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
