import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

private func key(_ character: Character) -> String { String(repeating: character, count: 64) }

private func tag(_ character: Character, _ name: String, retired: Bool = false) throws -> LedgerTag {
  let origin = try LedgerOrigin.macNative()
  return try LedgerTag(
    id: try StableLedgerID.tag(origin: origin, localKey: key(character)), name: name,
    origin: origin, lifecycle: retired ? .tombstoned : .active)
}

@Test func tagsListActiveFirstThenByNameIgnoringCase() throws {
  let sorted = AnnotationPresentation.sortedTags([
    try tag("a", "zeta"), try tag("b", "Alpha", retired: true), try tag("c", "beta"),
    try tag("d", "Gamma"),
  ])
  #expect(sorted.map(\.name) == ["beta", "Gamma", "zeta", "Alpha"])
}

@Test func selectableTagsKeepRetiredOnesAlreadyChosen() throws {
  let retired = try tag("b", "Old", retired: true)
  let tags = [try tag("a", "Trip"), retired, try tag("c", "Unused", retired: true)]
  #expect(AnnotationPresentation.selectableTags(tags, keeping: []).map(\.name) == ["Trip"])
  #expect(
    AnnotationPresentation.selectableTags(tags, keeping: [retired.id]).map(\.name)
      == ["Trip", "Old"])
}

@Test func memosShowNewestDayFirstAndHideDeletedOnes() throws {
  let origin = try LedgerOrigin.macNative()
  func memo(_ character: Character, day: Int, deleted: Bool = false) throws -> LedgerMemo {
    try LedgerMemo(
      id: try StableLedgerID.memo(origin: origin, localKey: key(character)),
      body: "Synthetic memo \(character)\nsecond line",
      date: try SourceLocalDate(year: 2026, month: 3, day: day), origin: origin,
      lifecycle: deleted ? .tombstoned : .active)
  }
  let shown = AnnotationPresentation.activeMemos([
    try memo("a", day: 2), try memo("b", day: 9), try memo("c", day: 5, deleted: true),
  ])
  #expect(shown.map { AnnotationPresentation.dateLabel($0.date) } == ["2026-03-09", "2026-03-02"])
  #expect(AnnotationPresentation.firstLine(shown[0].body) == "Synthetic memo b")
}

@Test func pickedDayRoundTripsThroughTheCalendar() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
  let day = try SourceLocalDate(year: 2026, month: 12, day: 31)
  let picked = AnnotationPresentation.pickerDate(for: day, calendar: calendar)
  #expect(try AnnotationPresentation.localDate(from: picked, calendar: calendar) == day)
}

@MainActor
@Test func tagsTemplatesAndMemosPersistAndATemplateRecordsATaggedTransaction() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("tags.sqlite")
  let suite = "LedgerAtlasMacUITests.tags.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let bookmarks = SecurityScopedBookmarkStore(
    defaults: defaults, makeBookmark: { Data($0.path.utf8) },
    resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) })

  let journey = LedgerJourney()
  let created = await LedgerAtlasRootView.performLedgerLifecycle(
    .create, at: destination, bookmarkStore: bookmarks, widgetPublisher: .init(write: { _ in }),
    journey: journey, session: LedgerSession(testingScopeStarter: { _ in true }),
    scopeStarter: { _ in true }, scopeStopper: { _ in })
  #expect(created.kind == .created)
  try journey.performBeginEditing()
  let origin = try LedgerOrigin.macNative()
  let wallet = try LedgerAccount(
    id: try StableLedgerID.account(origin: origin, localKey: key("a")), name: "Wallet",
    currencyUnit: "INR", origin: origin)
  try journey.createAccount(wallet)

  // Tags: create, reject a same-name twin, rename, retire one.
  let trip = try tag("1", "Trip")
  let shared = try tag("2", "Shared")
  try journey.createTag(trip)
  try journey.createTag(shared)
  do {
    try journey.createTag(try tag("3", "trip"))
    Issue.record("A second active tag named trip was accepted.")
  } catch {
    #expect(
      LedgerJourney.annotationFailureMessage(for: error, otherwise: "x")
        == "Another tag already has that name.")
  }
  try journey.updateTag(try trip.renamed("Goa trip"))

  // A template carrying both tags. After one tag retires, using the template records today's
  // expense with the active tag only.
  let template = try LedgerTransactionTemplate(
    id: try StableLedgerID.transactionTemplate(origin: origin, localKey: key("e")),
    name: "Tea", kind: .expense, categoryID: nil,
    amount: try CurrencyAmount(unitCode: "INR", amount: ExactDecimal("20")), note: "Synthetic",
    accountID: wallet.id, tags: try LedgerTagLinks([trip.id, shared.id]), origin: origin)
  try journey.saveTransactionTemplate(template)
  try journey.updateTag(try shared.tombstoned())
  let now = UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds())
  let first = try journey.createTransaction(
    fromTemplate: template.id, createdAt: now, submissionID: "submit-1")
  let again = try journey.createTransaction(
    fromTemplate: template.id, createdAt: now, submissionID: "submit-1")
  #expect(first.id == again.id)
  #expect(first.draft.kind == .expense)
  let twenty = try ExactDecimal("20")
  #expect(first.draft.effects.first?.amount.amount == twenty)

  let memo = try LedgerMemo(
    id: try StableLedgerID.memo(origin: origin, localKey: key("f")), body: "Synthetic note",
    date: try SourceLocalDate(year: 2026, month: 11, day: 2), origin: origin)
  try journey.saveMemo(memo)
  try journey.saveMemo(try memo.edited(body: "Synthetic note, edited"))

  let snapshot = try #require(journey.snapshot)
  #expect(snapshot.transactions.count == 1)
  #expect(snapshot.tags(forRevision: first.id).tagIDs == [trip.id])
  #expect(
    AnnotationPresentation.usageCounts(
      transactions: snapshot.transactions, revisionTags: snapshot.revisionTags) == [trip.id: 1])
  #expect(journey.rows(for: .tags).map(\.title).sorted() == ["Goa trip", "Shared"])

  // Everything survives a reopen from disk.
  let reopened = LedgerJourney()
  let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
    .open, at: destination, bookmarkStore: bookmarks, widgetPublisher: .init(write: { _ in }),
    journey: reopened, session: LedgerSession(testingScopeStarter: { _ in true }),
    scopeStarter: { _ in true }, scopeStopper: { _ in })
  #expect(outcome.kind == .opened)
  let restored = try #require(reopened.snapshot)
  #expect(AnnotationPresentation.sortedTags(restored.tags).map(\.name) == ["Goa trip", "Shared"])
  #expect(restored.tags.first { $0.id == shared.id }?.lifecycle == .tombstoned)
  #expect(AnnotationPresentation.activeTemplates(restored.transactionTemplates).map(\.name) == ["Tea"])
  #expect(AnnotationPresentation.activeMemos(restored.memos).map(\.body) == ["Synthetic note, edited"])
}
