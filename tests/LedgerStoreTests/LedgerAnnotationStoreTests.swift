import CSQLite
import CryptoKit
import Foundation
import LedgerCore
import Testing

@testable import LedgerStore

// Synthetic data only: every name, amount and date here is made up.

private func makeAnnotationStore() throws -> LedgerStore {
  var database: OpaquePointer?
  guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else {
    throw LedgerStore.Error.incompatibleCanonicalStore
  }
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
  return try LedgerStore(takingOwnershipOfValidatedCanonicalDatabase: database)
}

private struct AnnotationFixture {
  let store: LedgerStore
  let origin: LedgerOrigin
  let account: LedgerAccount
  let when: SourceTemporal

  init() throws {
    store = try makeAnnotationStore()
    origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
    account = try LedgerAccount(
      id: StableLedgerID.account(origin: origin, localKey: String(repeating: "a", count: 64)),
      name: "Synthetic cash", currencyUnit: "USD", origin: origin)
    try store.createAccount(account)
    when = try SourceTemporal(
      resolving: SourceLocalDateTime(date: SourceLocalDate(year: 2026, month: 3, day: 4)),
      in: SourceTimeZone(fixedOffsetSeconds: 0), precision: .minute)
  }

  func tag(_ key: Character, _ name: String) throws -> LedgerTag {
    try LedgerTag(
      id: StableLedgerID.tag(origin: origin, localKey: String(repeating: key, count: 64)),
      name: name, origin: origin)
  }

  func expense(_ literal: String) throws -> LedgerTransactionDraft {
    try LedgerTransactionDraft(
      effects: [
        try LedgerTransactionEffect(
          accountID: account.id, direction: .decrease,
          amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal(literal)))
      ], categoryID: nil, kind: .expense, occurredAt: when, origin: origin)
  }
}

@Test func tagsLabelRevisionsCarryForwardAndSurviveRenameAndTombstone() throws {
  let fixture = try AnnotationFixture()
  let store = fixture.store
  let food = try fixture.tag("c", "Food")
  let trip = try fixture.tag("d", "Trip")
  try store.createTag(food)
  try store.createTag(trip)
  try store.createTag(food)  // retry is a no-op

  // Names are unique among active tags, ignoring case.
  #expect(throws: LedgerStore.Error.duplicateTagName) {
    try store.createTag(try fixture.tag("e", "fOOD"))
  }
  #expect(throws: LedgerStore.Error.duplicateTagName) {
    try store.updateTag(try trip.renamed("food"))
  }

  let created = try store.createTransaction(
    .init(
      idempotencyKey: String(repeating: "b", count: 64), draft: fixture.expense("4.50"),
      createdAt: UTCInstant(epochMilliseconds: 1), tags: try LedgerTagLinks([food.id])))
  // Retrying the same create with different tags is a conflict, not a silent overwrite.
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    _ = try store.createTransaction(
      .init(
        idempotencyKey: String(repeating: "b", count: 64), draft: fixture.expense("4.50"),
        createdAt: UTCInstant(epochMilliseconds: 1), tags: try LedgerTagLinks([trip.id])))
  }

  // A correction without tags keeps the previous ones.
  let carried = try store.correctTransaction(
    .init(
      transactionID: created.revision.transactionID,
      expectedCurrentRevisionID: created.revision.id, draft: fixture.expense("5.00"),
      createdAt: UTCInstant(epochMilliseconds: 2)))
  var snapshot = try store.readSnapshot()
  #expect(snapshot.tags(forRevision: carried.revision.id).tagIDs == [food.id])

  // A correction with tags replaces them; the earlier revision keeps its own.
  let replaced = try store.correctTransaction(
    .init(
      transactionID: created.revision.transactionID,
      expectedCurrentRevisionID: carried.revision.id, draft: fixture.expense("5.00"),
      createdAt: UTCInstant(epochMilliseconds: 3), tags: try LedgerTagLinks([trip.id])))
  snapshot = try store.readSnapshot()
  #expect(snapshot.tags(forRevision: replaced.revision.id).tagIDs == [trip.id])
  #expect(snapshot.tags(forRevision: created.revision.id).tagIDs == [food.id])

  // Renaming changes no stored link. Tombstoning keeps history but blocks new links.
  try store.updateTag(try food.renamed("Groceries"))
  try store.updateTag(try trip.tombstoned())
  snapshot = try store.readSnapshot()
  #expect(snapshot.tags.first(where: { $0.id == food.id })?.name == "Groceries")
  #expect(snapshot.tags(forRevision: created.revision.id).tagIDs == [food.id])
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    _ = try store.createTransaction(
      .init(
        idempotencyKey: String(repeating: "f", count: 64), draft: fixture.expense("1.00"),
        createdAt: UTCInstant(epochMilliseconds: 4), tags: try LedgerTagLinks([trip.id])))
  }
  // A retired name can be used again.
  try store.createTag(try fixture.tag("9", "Trip"))

  // Tombstoning the transaction keeps the tombstoned tag it already had.
  let tombstoned = try store.tombstoneTransaction(
    .init(
      transactionID: created.revision.transactionID,
      expectedCurrentRevisionID: replaced.revision.id,
      createdAt: UTCInstant(epochMilliseconds: 5)))
  snapshot = try store.readSnapshot()
  #expect(snapshot.tags(forRevision: tombstoned.revision.id).tagIDs == [trip.id])
}

@Test func templatesAndMemosPersistAndRejectInvalidChangesAtomically() throws {
  let fixture = try AnnotationFixture()
  let store = fixture.store
  let coffee = try fixture.tag("c", "Coffee")
  try store.createTag(coffee)
  let template = try LedgerTransactionTemplate(
    id: StableLedgerID.transactionTemplate(
      origin: fixture.origin, localKey: String(repeating: "7", count: 64)),
    name: "Morning coffee", kind: .expense, categoryID: nil,
    amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("3.25")),
    accountID: fixture.account.id, tags: try LedgerTagLinks([coffee.id]), origin: fixture.origin)
  try store.saveTransactionTemplate(template)
  try store.saveTransactionTemplate(template)  // retry is a no-op

  // Using a template is an ordinary create through the standard command.
  let draft = try template.instantiate(occurredAt: fixture.when, origin: fixture.origin)
  let made = try store.createTransaction(
    .init(
      idempotencyKey: String(repeating: "b", count: 64), draft: draft,
      createdAt: UTCInstant(epochMilliseconds: 1), tags: template.tags))
  #expect(made.revision.draft.effects[0].amount.amount == (try ExactDecimal("3.25")))

  // Editing the template never touches the transaction made from it.
  let edited = try template.edited(
    amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("3.75")))
  try store.saveTransactionTemplate(edited)
  var snapshot = try store.readSnapshot()
  #expect(snapshot.transactionTemplates == [edited])
  #expect(
    snapshot.transactions[0].currentRevision.draft.effects[0].amount.amount
      == (try ExactDecimal("3.25")))

  // A template in another currency than its account is rejected and changes nothing.
  let before = try store.semanticChecksum()
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try store.saveTransactionTemplate(
      try edited.edited(amount: CurrencyAmount(unitCode: "EUR", amount: ExactDecimal("1"))))
  }
  #expect(try store.semanticChecksum() == before)

  try store.saveTransactionTemplate(try edited.tombstoned())
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try store.saveTransactionTemplate(edited)
  }

  let memo = try LedgerMemo(
    id: StableLedgerID.memo(origin: fixture.origin, localKey: String(repeating: "8", count: 64)),
    body: "Synthetic reminder", date: SourceLocalDate(year: 2026, month: 3, day: 4),
    origin: fixture.origin)
  try store.saveMemo(memo)
  try store.saveMemo(try memo.edited(body: "Synthetic reminder, edited"))
  try store.saveMemo(try memo.edited(body: "Synthetic reminder, edited").tombstoned())
  snapshot = try store.readSnapshot()
  #expect(snapshot.memos.count == 1)
  #expect(snapshot.memos[0].lifecycle == .tombstoned)
  #expect(snapshot.memos[0].body == "Synthetic reminder, edited")
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) { try store.saveMemo(memo) }

  #expect(try store.semanticChecksum() != before)
}

@Test func portablePackageRoundTripsTagsTemplatesMemosAndOlderPackagesStillImport() throws {
  let fixture = try AnnotationFixture()
  let store = fixture.store
  let food = try fixture.tag("c", "Food")
  let retired = try fixture.tag("d", "Retired")
  try store.createTag(food)
  try store.createTag(retired)
  let created = try store.createTransaction(
    .init(
      idempotencyKey: String(repeating: "b", count: 64), draft: fixture.expense("4.50"),
      createdAt: UTCInstant(epochMilliseconds: 1),
      tags: try LedgerTagLinks([food.id, retired.id])))
  _ = try store.correctTransaction(
    .init(
      transactionID: created.revision.transactionID,
      expectedCurrentRevisionID: created.revision.id, draft: fixture.expense("5.00"),
      createdAt: UTCInstant(epochMilliseconds: 2), tags: try LedgerTagLinks([food.id])))
  // History still points at a tombstoned tag; the package must carry it.
  try store.updateTag(try retired.tombstoned())
  try store.saveTransactionTemplate(
    try LedgerTransactionTemplate(
      id: StableLedgerID.transactionTemplate(
        origin: fixture.origin, localKey: String(repeating: "7", count: 64)),
      name: "Synthetic lunch", kind: .expense, categoryID: nil,
      amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("12.00")),
      note: "synthetic", accountID: fixture.account.id, tags: try LedgerTagLinks([food.id]),
      origin: fixture.origin))
  try store.saveMemo(
    try LedgerMemo(
      id: StableLedgerID.memo(
        origin: fixture.origin, localKey: String(repeating: "8", count: 64)),
      body: "Synthetic memo", date: SourceLocalDate(year: 2026, month: 3, day: 4),
      origin: fixture.origin))

  let source = LedgerApplication(store: store)
  let exported = try source.exportPackage()
  #expect(exported.manifest.formatVersion == LedgerPortablePackageFormat.version)

  let destinationStore = try makeAnnotationStore()
  try LedgerApplication(store: destinationStore).importPackage(
    manifest: exported.manifest, payload: exported.payload)
  let original = try store.readSnapshot()
  let restored = try destinationStore.readSnapshot()
  #expect(restored.tags == original.tags)
  #expect(restored.transactionTemplates == original.transactionTemplates)
  #expect(restored.memos == original.memos)
  #expect(restored.revisionTags == original.revisionTags)
  #expect(restored.revisionTags.count == 2)
  #expect(try destinationStore.semanticChecksum() == store.semanticChecksum())

  // A v3 package (no provenance keys, no import graph) still imports, annotations included.
  let v3Object = removingV4PackageKeys(
    try #require(JSONSerialization.jsonObject(with: exported.payload) as? [String: Any]))
    .merging(
      [
        "formatVersion": LedgerPortablePackageFormat.legacyV3Version,
        "formatFingerprint": LedgerPortablePackageFormat.legacyV3Fingerprint,
      ], uniquingKeysWith: { _, new in new })
  let v3Payload = try JSONSerialization.data(withJSONObject: v3Object, options: [.sortedKeys])
  let v3Store = try makeAnnotationStore()
  try LedgerApplication(store: v3Store).importPackage(
    manifest: LedgerExportManifest(
      formatVersion: LedgerPortablePackageFormat.legacyV3Version,
      formatFingerprint: LedgerPortablePackageFormat.legacyV3Fingerprint,
      payloadSHA256: SHA256.hash(data: v3Payload).map { String(format: "%02x", $0) }.joined(),
      createdAtMilliseconds: 0),
    payload: v3Payload)
  #expect(try v3Store.semanticChecksum() == store.semanticChecksum())

  // A v2 package (no annotation keys) still imports.
  var object = removingV4PackageKeys(
    try #require(JSONSerialization.jsonObject(with: exported.payload) as? [String: Any]))
  for key in ["tags", "transactionTemplates", "memos", "revisionTags"] {
    object.removeValue(forKey: key)
  }
  object["formatVersion"] = LedgerPortablePackageFormat.legacyV2Version
  object["formatFingerprint"] = LedgerPortablePackageFormat.legacyV2Fingerprint
  let legacyPayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  let legacyManifest = LedgerExportManifest(
    formatVersion: LedgerPortablePackageFormat.legacyV2Version,
    formatFingerprint: LedgerPortablePackageFormat.legacyV2Fingerprint,
    payloadSHA256: SHA256.hash(data: legacyPayload).map { String(format: "%02x", $0) }.joined(),
    createdAtMilliseconds: 0)
  let legacyStore = try makeAnnotationStore()
  try LedgerApplication(store: legacyStore).importPackage(
    manifest: legacyManifest, payload: legacyPayload)
  #expect(try legacyStore.readSnapshot().transactions.count == 1)
  #expect(try legacyStore.readSnapshot().tags.isEmpty)

  // A tampered package whose template currency no longer matches its account is refused.
  var tampered = try #require(
    JSONSerialization.jsonObject(with: exported.payload) as? [String: Any])
  var templates = try #require(tampered["transactionTemplates"] as? [[String: Any]])
  templates[0]["unit"] = "EUR"
  tampered["transactionTemplates"] = templates
  let tamperedPayload = try JSONSerialization.data(
    withJSONObject: tampered, options: [.sortedKeys])
  let tamperedManifest = LedgerExportManifest(
    formatVersion: exported.manifest.formatVersion,
    formatFingerprint: exported.manifest.formatFingerprint,
    payloadSHA256: SHA256.hash(data: tamperedPayload).map { String(format: "%02x", $0) }
      .joined(),
    createdAtMilliseconds: 0)
  let refusing = try makeAnnotationStore()
  #expect(throws: LedgerApplication.Error.invalidCommand) {
    try LedgerApplication(store: refusing).importPackage(
      manifest: tamperedManifest, payload: tamperedPayload)
  }
  #expect(try refusing.readSnapshot().accounts.isEmpty)
}
