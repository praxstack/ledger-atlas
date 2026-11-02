import CSQLite
import Foundation
import LedgerCore
import Testing

@testable import LedgerStore

@Test func acceptsTheCurrentCanonicalSchemaAndReportsItsIdentity() throws {
  let store = try makeStore()
  #expect(
    store.schemaIdentity
      == .init(
        version: CanonicalLedgerSchema.version, fingerprint: CanonicalLedgerSchema.fingerprint))
}

@Test func rejectsAHandleThatIsNotTheCurrentCanonicalSchema() throws {
  var database: OpaquePointer?
  #expect(sqlite3_open(":memory:", &database) == SQLITE_OK)
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try LedgerStore(takingOwnershipOfValidatedCanonicalDatabase: database)
  }
}

@Test func rejectsSemanticallyInvalidFinancialRows() throws {
  let database = try makeCanonicalDatabase()
  let origin = try LedgerOrigin(id: String(repeating: "a", count: 64), label: "synthetic")
  let accountID = try StableLedgerID.account(
    origin: origin, localKey: String(repeating: "b", count: 64))
  let transactionID = try StableLedgerID.transaction(
    origin: origin, localKey: String(repeating: "c", count: 64))
  let revisionID = try StableLedgerID.revision(transactionID: transactionID, revision: 1)
  try execute(
    database,
    """
    BEGIN;
    INSERT INTO ledger_origin VALUES ('\(origin.id)', 'synthetic', NULL);
    INSERT INTO ledger_account VALUES ('\(accountID)', 'Cash', 'USD', '\(origin.id)', 'active');
    INSERT INTO ledger_transaction VALUES ('\(transactionID)', '\(revisionID)');
    INSERT INTO ledger_transaction_revision VALUES ('\(revisionID)', '\(transactionID)', 1, NULL, NULL, 'adjustment', 0, 1970, 1, 1, 0, 0, 0, 0, 'fixed', '0', 'millisecond', 0, NULL, NULL, '\(origin.id)', 'active', 0);
    INSERT INTO ledger_transaction_effect VALUES ('\(revisionID)', '\(accountID)', 'increase', 'NaN', 'USD');
    COMMIT;
    """)
  #expect(!CanonicalLedgerHealth.isHealthy(database))
  sqlite3_close(database)
}

@Test func rejectsMismatchedCategoriesAndInvalidRevisionChains() throws {
  let origin = try LedgerOrigin(id: String(repeating: "c", count: 64), label: "synthetic")
  let accountID = try StableLedgerID.account(
    origin: origin, localKey: String(repeating: "d", count: 64))
  let categoryID = try StableLedgerID.category(
    origin: origin, localKey: String(repeating: "e", count: 64))
  let transactionID = try StableLedgerID.transaction(
    origin: origin, localKey: String(repeating: "f", count: 64))
  let firstID = try StableLedgerID.revision(transactionID: transactionID, revision: 1)
  let secondID = try StableLedgerID.revision(transactionID: transactionID, revision: 2)

  let categoryDatabase = try makeCanonicalDatabase()
  try execute(
    categoryDatabase,
    """
    BEGIN;
    INSERT INTO ledger_origin VALUES ('\(origin.id)', 'synthetic', NULL);
    INSERT INTO ledger_account VALUES ('\(accountID)', 'Cash', 'USD', '\(origin.id)', 'active');
    INSERT INTO ledger_category VALUES ('\(categoryID)', 'Bills', 'expense', '\(origin.id)', 'active');
    INSERT INTO ledger_transaction VALUES ('\(transactionID)', '\(firstID)');
    INSERT INTO ledger_transaction_revision VALUES ('\(firstID)', '\(transactionID)', 1, NULL, '\(categoryID)', 'income', 0, 1970, 1, 1, 0, 0, 0, 0, 'fixed', '0', 'millisecond', 0, NULL, NULL, '\(origin.id)', 'active', 0);
    INSERT INTO ledger_transaction_effect VALUES ('\(firstID)', '\(accountID)', 'increase', '1', 'USD');
    COMMIT;
    """)
  #expect(!CanonicalLedgerHealth.isHealthy(categoryDatabase))
  sqlite3_close(categoryDatabase)

  let tombstoneDatabase = try makeCanonicalDatabase()
  try execute(
    tombstoneDatabase,
    """
    BEGIN;
    INSERT INTO ledger_origin VALUES ('\(origin.id)', 'synthetic', NULL);
    INSERT INTO ledger_account VALUES ('\(accountID)', 'Cash', 'USD', '\(origin.id)', 'active');
    INSERT INTO ledger_transaction VALUES ('\(transactionID)', '\(secondID)');
    INSERT INTO ledger_transaction_revision VALUES ('\(firstID)', '\(transactionID)', 1, NULL, NULL, 'adjustment', 0, 1970, 1, 1, 0, 0, 0, 0, 'fixed', '0', 'millisecond', 0, NULL, NULL, '\(origin.id)', 'tombstoned', 1);
    INSERT INTO ledger_transaction_revision VALUES ('\(secondID)', '\(transactionID)', 2, '\(firstID)', NULL, 'adjustment', 0, 1970, 1, 1, 0, 0, 0, 0, 'fixed', '0', 'millisecond', 0, NULL, NULL, '\(origin.id)', 'active', 2);
    INSERT INTO ledger_transaction_effect VALUES ('\(firstID)', '\(accountID)', 'increase', '1', 'USD');
    INSERT INTO ledger_transaction_effect VALUES ('\(secondID)', '\(accountID)', 'increase', '1', 'USD');
    COMMIT;
    """)
  #expect(!CanonicalLedgerHealth.isHealthy(tombstoneDatabase))
  sqlite3_close(tombstoneDatabase)

  let timestampDatabase = try makeCanonicalDatabase()
  try execute(
    timestampDatabase,
    """
    BEGIN;
    INSERT INTO ledger_origin VALUES ('\(origin.id)', 'synthetic', NULL);
    INSERT INTO ledger_account VALUES ('\(accountID)', 'Cash', 'USD', '\(origin.id)', 'active');
    INSERT INTO ledger_transaction VALUES ('\(transactionID)', '\(secondID)');
    INSERT INTO ledger_transaction_revision VALUES ('\(firstID)', '\(transactionID)', 1, NULL, NULL, 'adjustment', 0, 1970, 1, 1, 0, 0, 0, 0, 'fixed', '0', 'millisecond', 0, NULL, NULL, '\(origin.id)', 'active', 2);
    INSERT INTO ledger_transaction_revision VALUES ('\(secondID)', '\(transactionID)', 2, '\(firstID)', NULL, 'adjustment', 0, 1970, 1, 1, 0, 0, 0, 0, 'fixed', '0', 'millisecond', 0, NULL, NULL, '\(origin.id)', 'active', 1);
    INSERT INTO ledger_transaction_effect VALUES ('\(firstID)', '\(accountID)', 'increase', '1', 'USD');
    INSERT INTO ledger_transaction_effect VALUES ('\(secondID)', '\(accountID)', 'increase', '1', 'USD');
    COMMIT;
    """)
  #expect(!CanonicalLedgerHealth.isHealthy(timestampDatabase))
  sqlite3_close(timestampDatabase)
}

@Test func validatesACompletePersistedFinancialRevision() throws {
  let database = try makeCanonicalDatabase()
  let origin = try LedgerOrigin(id: String(repeating: "d", count: 64), label: "synthetic")
  let accountID = try StableLedgerID.account(
    origin: origin, localKey: String(repeating: "e", count: 64))
  let transactionID = try StableLedgerID.transaction(
    origin: origin, localKey: String(repeating: "f", count: 64))
  let revisionID = try StableLedgerID.revision(transactionID: transactionID, revision: 1)
  try execute(
    database,
    """
    BEGIN;
    INSERT INTO ledger_origin VALUES ('\(origin.id)', 'synthetic', NULL);
    INSERT INTO ledger_account VALUES ('\(accountID)', 'Cash', 'USD', '\(origin.id)', 'active');
    INSERT INTO ledger_transaction VALUES ('\(transactionID)', '\(revisionID)');
    INSERT INTO ledger_transaction_revision VALUES ('\(revisionID)', '\(transactionID)', 1, NULL, NULL, 'adjustment', 0, 1970, 1, 1, 0, 0, 0, 0, 'fixed', '0', 'millisecond', 0, NULL, NULL, '\(origin.id)', 'active', 0);
    INSERT INTO ledger_transaction_effect VALUES ('\(revisionID)', '\(accountID)', 'increase', '1', 'USD');
    COMMIT;
    """)
  _ = try LedgerStore(takingOwnershipOfValidatedCanonicalDatabase: database)
}

@Test func opensAndReadsAnEmptyCanonicalFileWithoutMutation() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("ledger.sqlite")
  let database = try makeCanonicalDatabase(at: url)
  sqlite3_close(database)
  #expect(chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
  let before = try Data(contentsOf: url)

  let store = try LedgerStore.openReadOnly(at: url)
  let snapshot = try store.readSnapshot()

  #expect(snapshot.accounts.isEmpty)
  #expect(snapshot.transactions.isEmpty)
  #expect(snapshot.undisplayedImportedEventCount == 0)
  #expect(try Data(contentsOf: url) == before)
  for suffix in ["-wal", "-shm"] {
    #expect(!FileManager.default.fileExists(atPath: url.path + suffix))
  }
}

@Test func readsANativeAccountAndTransactionFromAnUnchangedFile() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("ledger.sqlite")
  let database = try makeCanonicalDatabase(at: url)
  let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "synthetic")
  let accountID = try StableLedgerID.account(
    origin: origin, localKey: String(repeating: "2", count: 64))
  let transactionID = try StableLedgerID.transaction(
    origin: origin, localKey: String(repeating: "3", count: 64))
  let revisionID = try StableLedgerID.revision(transactionID: transactionID, revision: 1)
  try execute(
    database,
    """
    BEGIN;
    INSERT INTO ledger_origin VALUES ('\(origin.id)', 'synthetic', NULL);
    INSERT INTO ledger_account VALUES ('\(accountID)', 'Cash', 'USD', '\(origin.id)', 'active');
    INSERT INTO ledger_transaction VALUES ('\(transactionID)', '\(revisionID)');
    INSERT INTO ledger_transaction_revision VALUES ('\(revisionID)', '\(transactionID)', 1, NULL, NULL, 'adjustment', 0, 1970, 1, 1, 0, 0, 0, 0, 'fixed', '0', 'millisecond', 0, 'Synthetic', NULL, '\(origin.id)', 'active', 0);
    INSERT INTO ledger_transaction_effect VALUES ('\(revisionID)', '\(accountID)', 'increase', '1', 'USD');
    COMMIT;
    """)
  sqlite3_close(database)
  #expect(chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
  let before = try Data(contentsOf: url)

  let snapshot = try LedgerStore.openReadOnly(at: url).readSnapshot()

  #expect(snapshot.accounts.map(\.name) == ["Cash"])
  #expect(snapshot.transactions.map(\.id) == [transactionID])
  #expect(snapshot.transactions.first?.currentRevision.draft.note == "Synthetic")
  #expect(try Data(contentsOf: url) == before)
}

@Test func createsAndRetriesTheSameNativeTransaction() throws {
  let database = try makeCanonicalDatabase()
  let origin = try LedgerOrigin(id: String(repeating: "4", count: 64), label: "synthetic")
  let accountID = try StableLedgerID.account(
    origin: origin, localKey: String(repeating: "5", count: 64))
  try execute(
    database,
    """
    INSERT INTO ledger_origin VALUES ('\(origin.id)', 'synthetic', NULL);
    INSERT INTO ledger_account VALUES ('\(accountID)', 'Cash', 'USD', '\(origin.id)', 'active');
    """)
  let store = try LedgerStore(takingOwnershipOfValidatedCanonicalDatabase: database)
  let temporal = try SourceTemporal(
    instant: .init(epochMilliseconds: 0),
    localDateTime: .init(
      date: .init(year: 1970, month: 1, day: 1), hour: 0, minute: 0, second: 0, millisecond: 0),
    timeZone: .init(fixedOffsetSeconds: 0), precision: .millisecond, resolvedOffsetSeconds: 0)
  let draft = try LedgerTransactionDraft(
    effects: [
      .init(
        accountID: accountID, direction: .increase,
        amount: .init(unitCode: "USD", amount: .init("1.20")))
    ],
    categoryID: nil, kind: .adjustment, occurredAt: temporal, note: "Synthetic", origin: origin)
  let request = LedgerStore.CreateTransactionRequest(
    idempotencyKey: String(repeating: "6", count: 64), draft: draft,
    createdAt: .init(epochMilliseconds: 1))

  let created = try store.createTransaction(request)
  let retried = try store.createTransaction(request)

  #expect(created.status == .committed)
  #expect(retried.status == .unchanged)
  #expect(created.revision == retried.revision)
  let conflictingDraft = try LedgerTransactionDraft(
    effects: [
      .init(
        accountID: accountID, direction: .increase,
        amount: .init(unitCode: "USD", amount: .init("9")))
    ],
    categoryID: nil, kind: .adjustment, occurredAt: temporal, note: "Conflict", origin: origin)
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try store.createTransaction(
      .init(
        idempotencyKey: request.idempotencyKey, draft: conflictingDraft,
        createdAt: request.createdAt))
  }

  let correctionDraft = try LedgerTransactionDraft(
    effects: [
      .init(
        accountID: accountID, direction: .increase,
        amount: .init(unitCode: "USD", amount: .init("2.40")))
    ],
    categoryID: nil, kind: .adjustment, occurredAt: temporal, note: "Corrected", origin: origin)
  let correction = LedgerStore.CorrectTransactionRequest(
    transactionID: created.revision.transactionID, expectedCurrentRevisionID: created.revision.id,
    draft: correctionDraft, createdAt: .init(epochMilliseconds: 2))
  let corrected = try store.correctTransaction(correction)
  let retriedCorrection = try store.correctTransaction(correction)
  #expect(corrected.status == .committed)
  #expect(retriedCorrection.status == .unchanged)
  #expect(corrected.revision.revision == 2)
  #expect(corrected.revision.predecessorID == created.revision.id)
  #expect(try store.createTransaction(request).status == .unchanged)

  let tombstone = LedgerStore.TombstoneTransactionRequest(
    transactionID: created.revision.transactionID, expectedCurrentRevisionID: corrected.revision.id,
    createdAt: .init(epochMilliseconds: 3))
  let tombstoned = try store.tombstoneTransaction(tombstone)
  let retriedTombstone = try store.tombstoneTransaction(tombstone)
  #expect(tombstoned.revision.lifecycle == .tombstoned)
  #expect(tombstoned.revision.draft == correctionDraft)
  #expect(retriedTombstone.status == .unchanged)
  let staleCorrection = LedgerStore.CorrectTransactionRequest(
    transactionID: created.revision.transactionID, expectedCurrentRevisionID: corrected.revision.id,
    draft: correctionDraft, createdAt: .init(epochMilliseconds: 4))
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try store.correctTransaction(staleCorrection)
  }
}

@Test func mutableOpenerRejectsUnsafePathFormsBeforeWriting() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("source.sqlite")
  let database = try makeCanonicalDatabase(at: source)
  sqlite3_close(database)
  #expect(chmod(source.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

  let symlinkURL = directory.appendingPathComponent("symlink.sqlite")
  #expect(Darwin.symlink(source.path, symlinkURL.path) == 0)
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try LedgerStore.openForMutation(at: symlinkURL)
  }

  let hardlink = directory.appendingPathComponent("hardlink.sqlite")
  #expect(link(source.path, hardlink.path) == 0)
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try LedgerStore.openForMutation(at: source)
  }
  #expect(unlink(hardlink.path) == 0)

  #expect(chmod(source.path, mode_t(S_IRUSR | S_IWUSR | S_IRGRP)) == 0)
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try LedgerStore.openForMutation(at: source)
  }
  #expect(chmod(source.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

  var directoryStat = stat()
  #expect(lstat(directory.path, &directoryStat) == 0)
  let directoryMode = directoryStat.st_mode & mode_t(0o777)
  #expect(chmod(directory.path, directoryMode | mode_t(S_IWGRP)) == 0)
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try LedgerStore.openForMutation(at: source)
  }
  #expect(chmod(directory.path, directoryMode) == 0)

  try Data().write(to: URL(fileURLWithPath: source.path + "-journal"))
  var journalBefore = stat()
  #expect(lstat(source.path + "-journal", &journalBefore) == 0)
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try LedgerStore.openForMutation(at: source)
  }
  var journalAfter = stat()
  #expect(lstat(source.path + "-journal", &journalAfter) == 0)
  #expect(journalBefore.st_dev == journalAfter.st_dev)
  #expect(journalBefore.st_ino == journalAfter.st_ino)
  #expect(try Data(contentsOf: URL(fileURLWithPath: source.path + "-journal")).isEmpty)
}

@Test func staleJournalBindingDoesNotBlockTheNextWrite() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try makeFileBackedMutationFixture(in: directory)
  let binding = URL(fileURLWithPath: fixture.url.path + "-journal.ledger-atlas-binding")
  try Data("ledger-atlas-journal-v3\n1\n2\n3\n4\n5\n6\n7\n8\n".utf8).write(
    to: binding, options: .atomic)
  #expect(chmod(binding.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

  let store = try LedgerStore.openForMutation(at: fixture.url)
  #expect(try store.createTransaction(fixture.request).status == .committed)
  #expect(FileManager.default.fileExists(atPath: binding.path))
}

@Test func mutableOpenerRejectsPersistedWALModeBeforeWriting() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("wal.sqlite")
  let database = try makeCanonicalDatabase(at: url)
  try execute(database, "PRAGMA journal_mode=WAL")
  sqlite3_close(database)
  #expect(chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
  for suffix in ["-wal", "-shm"] {
    #expect(!FileManager.default.fileExists(atPath: url.path + suffix))
  }
  let before = try Data(contentsOf: url)

  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try LedgerStore.openForMutation(at: url)
  }
  #expect(try Data(contentsOf: url) == before)
}

@Test func fileBackedMutationReopensOnlyASafeCanonicalLedger() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("ledger.sqlite")
  let database = try makeCanonicalDatabase(at: url)
  let origin = try LedgerOrigin(id: String(repeating: "7", count: 64), label: "synthetic")
  let accountID = try StableLedgerID.account(
    origin: origin, localKey: String(repeating: "8", count: 64))
  try execute(
    database,
    """
    INSERT INTO ledger_origin VALUES ('\(origin.id)', 'synthetic', NULL);
    INSERT INTO ledger_account VALUES ('\(accountID)', 'Cash', 'USD', '\(origin.id)', 'active');
    """)
  sqlite3_close(database)
  #expect(chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
  _ = try LedgerStore.openReadOnly(at: url)
  let temporal = try SourceTemporal(
    instant: .init(epochMilliseconds: 0),
    localDateTime: .init(
      date: .init(year: 1970, month: 1, day: 1), hour: 0, minute: 0, second: 0, millisecond: 0),
    timeZone: .init(fixedOffsetSeconds: 0), precision: .millisecond, resolvedOffsetSeconds: 0)
  let draft = try LedgerTransactionDraft(
    effects: [
      .init(
        accountID: accountID, direction: .increase,
        amount: .init(unitCode: "USD", amount: .init("3")))
    ],
    categoryID: nil, kind: .adjustment, occurredAt: temporal, origin: origin)

  do {
    let store = try LedgerStore.openForMutation(at: url)
    let result = try store.createTransaction(
      .init(
        idempotencyKey: String(repeating: "9", count: 64), draft: draft,
        createdAt: .init(epochMilliseconds: 1)))
    #expect(result.status == .committed)
  }
  let snapshot = try LedgerStore.openReadOnly(at: url).readSnapshot()
  #expect(snapshot.transactions.count == 1)
  for suffix in ["-wal", "-shm"] {
    #expect(!FileManager.default.fileExists(atPath: url.path + suffix))
  }
  try expectInactiveJournal(at: url.path + "-journal")
  #expect(FileManager.default.fileExists(atPath: url.path + "-journal.ledger-atlas-binding"))
}

@Test func backupPublishesOnlyAfterACompleteValidatedTemporaryFile() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try makeFileBackedMutationFixture(in: directory)
  let destination = directory.appendingPathComponent("backup.sqlite")
  let store = try LedgerStore.openReadOnly(at: fixture.url)
  var reachedValidatedTemporary = false

  do {
    try store.backupCanonicalDatabase(to: destination) { phase in
      guard phase == .afterTemporaryFileValidated else { return }
      reachedValidatedTemporary = true
      #expect(!FileManager.default.fileExists(atPath: destination.path))
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      #expect(names.contains { $0.hasPrefix(".ledger-atlas-backup-") })
      throw TestError.injected
    }
    Issue.record("expected injected failure before backup publication")
  } catch TestError.injected {
  } catch {
    Issue.record("unexpected backup error")
  }

  #expect(reachedValidatedTemporary)
  #expect(!FileManager.default.fileExists(atPath: destination.path))
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy {
      !$0.hasPrefix(".ledger-atlas-backup-")
    })
  try store.backupCanonicalDatabase(to: destination)
  #expect(
    try LedgerStore.openReadOnly(at: destination).semanticChecksum()
      == store.semanticChecksum())
}

@Test func backupDetectsAReplacementAtTheFinalPublicationSeam() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try makeFileBackedMutationFixture(in: directory)
  let destination = directory.appendingPathComponent("backup.sqlite")
  let parked = directory.appendingPathComponent("parked-backup.sqlite")
  let sentinel = Data("backup publication sentinel".utf8)
  let store = try LedgerStore.openReadOnly(at: fixture.url)

  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try store.backupCanonicalDatabase(to: destination) { phase in
      guard phase == .beforeDestinationPublication else { return }
      let temporary = try #require(
        FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          .first { $0.lastPathComponent.hasPrefix(".ledger-atlas-backup-") })
      #expect(Darwin.rename(temporary.path, parked.path) == 0)
      try sentinel.write(to: temporary)
      #expect(chmod(temporary.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
    }
  }

  #expect(!FileManager.default.fileExists(atPath: destination.path))
  #expect(try Data(contentsOf: parked).isEmpty == false)
  let replacement = try #require(
    FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .first { $0.lastPathComponent.hasPrefix(".ledger-atlas-backup-") })
  #expect(try Data(contentsOf: replacement) == sentinel)
}

@Test func backupRejectsDestinationTruncationAfterCopy() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try makeFileBackedMutationFixture(in: directory)
  let destination = directory.appendingPathComponent("backup.sqlite")
  let store = try LedgerStore.openReadOnly(at: fixture.url)

  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try store.backupCanonicalDatabase(to: destination) { phase in
      guard phase == .afterDestinationCopyBeforeValidation else { return }
      let descriptor = Darwin.open(destination.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else { throw TestError.injected }
      defer { Darwin.close(descriptor) }
      #expect(ftruncate(descriptor, 1) == 0)
      #expect(fsync(descriptor) == 0)
    }
  }

  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func preservedSourceProjectionDeduplicatesTheSameOpaqueFieldCommitment() throws {
  let database = try makeCanonicalDatabase()
  let store = try LedgerStore(takingOwnershipOfValidatedCanonicalDatabase: database)
  let id = String(repeating: "a", count: 64)
  let receipt = String(repeating: "b", count: 64)
  let anchor = String(repeating: "c", count: 64)
  let event = String(repeating: "d", count: 64)
  let payload = Data("synthetic note".utf8).map { String(format: "%02x", $0) }.joined()
  try execute(
    database,
    """
    INSERT INTO provenance_reference VALUES ('\(id)', '\(id)', 'synthetic-profile', 'synthetic-adapter', NULL, 'INOUTCOME', 'row-1', 7, 'NOTE');
    INSERT INTO economic_event VALUES ('\(event)', 'account', 'expense', '1', 'USD', 0, 1970, 1, 1, 0, 0, 0, 0, 'fixed', '0', 'millisecond', 0, 'row-1', '\(id)');
    INSERT INTO import_receipt VALUES ('\(receipt)', '\(id)', '\(id)', 'synthetic-profile', 'synthetic-adapter', '\(id)', '\(id)', 1, 8);
    INSERT INTO receipt_preservation_anchor VALUES ('\(anchor)', '\(receipt)', 'row-subject', 'record', '\(id)', 'synthetic-profile', 'synthetic-adapter', NULL, 'INOUTCOME', 'row-1');
    INSERT INTO receipt_preservation_payload VALUES ('payload', '\(receipt)', '\(anchor)', '\(id)', '\(id)', 1, 'TEXT', 'text', X'\(payload)');
    INSERT INTO sidecar_reference VALUES ('\(id)', '\(event)', '\(id)', 1, 'TEXT', 'text', X'\(payload)');
    """)

  let projected = try store.readPreservedSource()

  #expect(projected.count == 1)
  #expect(projected.first?.table == "INOUTCOME")
  #expect(projected.first?.recordKey == "row-1")
  #expect(projected.first?.columnName == "NOTE")
  #expect(projected.first?.payload == Data("synthetic note".utf8))
}

@Test func backupReportsWhenRenameCompletedBeforeFinalDurabilityChecks() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try makeFileBackedMutationFixture(in: directory)
  let destination = directory.appendingPathComponent("backup.sqlite")
  let store = try LedgerStore.openReadOnly(at: fixture.url)
  var reachedPublishedDestination = false

  #expect(throws: LedgerStore.Error.backupPublicationCompleted) {
    try store.backupCanonicalDatabase(to: destination) { phase in
      guard phase == .afterDestinationPublished else { return }
      reachedPublishedDestination = true
      throw TestError.injected
    }
  }

  #expect(reachedPublishedDestination)
  #expect(FileManager.default.fileExists(atPath: destination.path))
  #expect(
    try LedgerStore.openReadOnly(at: destination).semanticChecksum()
      == store.semanticChecksum())
}

@Test func backupRejectsARepurposedTemporaryBeforeWritingFinancialBytes() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try makeFileBackedMutationFixture(in: directory)
  let destination = directory.appendingPathComponent("backup.sqlite")
  let parked = directory.appendingPathComponent("parked.sqlite")
  let sentinel = Data("unrelated-sentinel".utf8)
  let store = try LedgerStore.openReadOnly(at: fixture.url)
  var racedLeaf: URL?

  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try store.backupCanonicalDatabase(to: destination) { phase in
      guard phase == .afterTemporaryFileCreated else { return }
      let temporary = try #require(
        FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          .first { $0.lastPathComponent.hasPrefix(".ledger-atlas-backup-") })
      try FileManager.default.moveItem(at: temporary, to: parked)
      let parkedDescriptor = Darwin.open(parked.path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
      guard parkedDescriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
      defer { Darwin.close(parkedDescriptor) }
      let parkedWrite = sentinel.withUnsafeBytes {
        Darwin.write(parkedDescriptor, $0.baseAddress, $0.count)
      }
      #expect(parkedWrite == sentinel.count)
      #expect(fsync(parkedDescriptor) == 0)
      try sentinel.write(to: temporary)
      #expect(chmod(temporary.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
      racedLeaf = temporary
    }
  }

  #expect(try Data(contentsOf: #require(racedLeaf)) == sentinel)
  #expect(try Data(contentsOf: parked) == sentinel)
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func failedBackupNeverDeletesOrTruncatesARepurposedTemporaryInode() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try makeFileBackedMutationFixture(in: directory)
  let destination = directory.appendingPathComponent("backup.sqlite")
  let parked = directory.appendingPathComponent("parked.sqlite")
  let sentinel = Data("unrelated-sentinel".utf8)
  let store = try LedgerStore.openReadOnly(at: fixture.url)
  var racedLeaf: URL?

  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try store.backupCanonicalDatabase(to: destination) { phase in
      guard phase == .afterTemporaryFileValidated else { return }
      let temporary = try #require(
        FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          .first { $0.lastPathComponent.hasPrefix(".ledger-atlas-backup-") })
      try FileManager.default.moveItem(at: temporary, to: parked)
      let parkedDescriptor = Darwin.open(parked.path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
      guard parkedDescriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
      defer { Darwin.close(parkedDescriptor) }
      let parkedWrite = sentinel.withUnsafeBytes {
        Darwin.write(parkedDescriptor, $0.baseAddress, $0.count)
      }
      #expect(parkedWrite == sentinel.count)
      #expect(fsync(parkedDescriptor) == 0)
      try sentinel.write(to: temporary)
      #expect(chmod(temporary.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
      racedLeaf = temporary
    }
  }

  #expect(try Data(contentsOf: #require(racedLeaf)) == sentinel)
  #expect(try Data(contentsOf: parked) == sentinel)
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func failedBackupPreservesARenamedValidatedTemporary() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try makeFileBackedMutationFixture(in: directory)
  let destination = directory.appendingPathComponent("backup.sqlite")
  let parked = directory.appendingPathComponent("parked.sqlite")
  let store = try LedgerStore.openReadOnly(at: fixture.url)
  var parkedBytes = Data()

  do {
    try store.backupCanonicalDatabase(to: destination) { phase in
      guard phase == .afterTemporaryFileValidated else { return }
      let temporary = try #require(
        FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          .first { $0.lastPathComponent.hasPrefix(".ledger-atlas-backup-") })
      try FileManager.default.moveItem(at: temporary, to: parked)
      parkedBytes = try Data(contentsOf: parked)
      throw TestError.injected
    }
    Issue.record("expected injected failure after renaming validated backup")
  } catch TestError.injected {
  } catch {
    Issue.record("unexpected backup error: \(error)")
  }

  #expect(!parkedBytes.isEmpty)
  #expect(try Data(contentsOf: parked) == parkedBytes)
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func failedBackupPreservesAMatchingPrefixInARenamedTemporaryInode() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try makeFileBackedMutationFixture(in: directory)
  let destination = directory.appendingPathComponent("backup.sqlite")
  let parked = directory.appendingPathComponent("parked.sqlite")
  let store = try LedgerStore.openReadOnly(at: fixture.url)
  var expectedPrefix = Data()

  do {
    try store.backupCanonicalDatabase(to: destination) { phase in
      guard phase == .afterTemporaryFileValidated else { return }
      let temporary = try #require(
        FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          .first { $0.lastPathComponent.hasPrefix(".ledger-atlas-backup-") })
      try FileManager.default.moveItem(at: temporary, to: parked)
      let serialized = try Data(contentsOf: parked)
      expectedPrefix = Data(serialized.prefix(max(1, min(4_096, serialized.count))))
      let parkedDescriptor = Darwin.open(
        parked.path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
      guard parkedDescriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
      defer { Darwin.close(parkedDescriptor) }
      let written = expectedPrefix.withUnsafeBytes {
        Darwin.write(parkedDescriptor, $0.baseAddress, $0.count)
      }
      #expect(written == expectedPrefix.count)
      #expect(fsync(parkedDescriptor) == 0)
      throw TestError.injected
    }
    Issue.record("expected injected failure after repurposing validated backup")
  } catch TestError.injected {
  } catch {
    Issue.record("unexpected backup error: \(error)")
  }

  #expect(!expectedPrefix.isEmpty)
  #expect(try Data(contentsOf: parked) == expectedPrefix)
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func descriptorBoundWriterDoesNotMutateAReplacementPath() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try makeFileBackedMutationFixture(in: directory)
  let replacement = directory.appendingPathComponent("replacement.sqlite")
  sqlite3_close(try makeCanonicalDatabase(at: replacement))
  #expect(chmod(replacement.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
  let parked = directory.appendingPathComponent("parked.sqlite")
  let originalBytes = try Data(contentsOf: fixture.url)
  let replacementBytes = try Data(contentsOf: replacement)
  var began = false
  var swapped = false

  let store = try LedgerStore.openForMutation(at: fixture.url) { phase in
    if phase == .afterBeginImmediate { began = true }
    guard phase == .afterMutationWrite else { return }
    guard Darwin.rename(fixture.url.path, parked.path) == 0,
      Darwin.rename(replacement.path, fixture.url.path) == 0
    else { throw TestError.injected }
    swapped = true
  }

  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try store.createTransaction(fixture.request)
  }
  #expect(began)
  #expect(swapped)
  let parkedBytes = try? Data(contentsOf: parked)
  #expect(parkedBytes == originalBytes)
  #expect(try Data(contentsOf: fixture.url) == replacementBytes)
  for path in [fixture.url.path, parked.path] {
    for suffix in ["-wal", "-shm"] {
      #expect(!FileManager.default.fileExists(atPath: path + suffix))
    }
  }
}

@Test func descriptorBoundWriterRollsBackAnInjectedPrecommitFailure() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try makeFileBackedMutationFixture(in: directory)
  let before = try Data(contentsOf: fixture.url)
  let store = try LedgerStore.openForMutation(at: fixture.url) { phase in
    if phase == .afterMutationWrite { throw TestError.injected }
  }

  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try store.createTransaction(fixture.request)
  }
  #expect(try Data(contentsOf: fixture.url) == before)
  for suffix in ["-wal", "-shm"] {
    #expect(!FileManager.default.fileExists(atPath: fixture.url.path + suffix))
  }
  try expectInactiveJournal(at: fixture.url.path + "-journal")
}

@Test func descriptorBoundWritersReuseSQLiteWriterExclusion() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try makeFileBackedMutationFixture(in: directory)
  let first = try LedgerStore.openForMutation(at: fixture.url)
  let second = try LedgerStore.openForMutation(at: fixture.url)

  _ = try first.performAtomically { _ in
    #expect(throws: LedgerStore.Error.sqliteFailure(code: SQLITE_BUSY)) {
      try second.performAtomically { _ in () }
    }
    _ = try LedgerStore.openReadOnly(at: fixture.url).readSnapshot()
    let externalWriter = Process()
    externalWriter.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    externalWriter.arguments = [fixture.url.path, "PRAGMA busy_timeout=0; BEGIN IMMEDIATE;"]
    externalWriter.standardOutput = FileHandle.nullDevice
    externalWriter.standardError = FileHandle.nullDevice
    try externalWriter.run()
    externalWriter.waitUntilExit()
    #expect(externalWriter.terminationStatus != 0)
  }

  for suffix in ["-wal", "-shm"] {
    #expect(!FileManager.default.fileExists(atPath: fixture.url.path + suffix))
  }
}

@Test func descriptorBoundWriterRecoversAHotRollbackJournal() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try makeFileBackedMutationFixture(in: directory)
  var seedDatabase: OpaquePointer?
  #expect(sqlite3_open(fixture.url.path, &seedDatabase) == SQLITE_OK)
  if let seedDatabase {
    for index in 0..<2048 {
      let hex = String(index, radix: 16)
      let id = String(repeating: "0", count: 64 - hex.count) + hex
      try execute(seedDatabase, "INSERT INTO ledger_origin VALUES ('\(id)', 'seed', NULL);")
    }
    #expect(sqlite3_close(seedDatabase) == SQLITE_OK)
  }
  let before = try Data(contentsOf: fixture.url)
  let marker = directory.appendingPathComponent("writer-reached-sleep")
  let process = Process()
  let input = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
  process.arguments = [fixture.url.path]
  process.standardInput = input
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  try input.fileHandleForWriting.write(
    contentsOf: Data(
      "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA cache_size=1; BEGIN IMMEDIATE; UPDATE ledger_origin SET label='uncommitted';\n.shell /usr/bin/touch \(marker.path)\n.shell /bin/sleep 30\n"
        .utf8))
  try input.fileHandleForWriting.close()
  let journalPath = fixture.url.path + "-journal"
  let deadline = Date().addingTimeInterval(5)
  while Date() < deadline {
    if FileManager.default.fileExists(atPath: marker.path),
      let attributes = try? FileManager.default.attributesOfItem(atPath: journalPath),
      let size = attributes[.size] as? NSNumber, size.intValue >= 512
    {
      break
    }
    usleep(10_000)
  }
  let journalSize = try #require(
    (try FileManager.default.attributesOfItem(atPath: journalPath)[.size] as? NSNumber)?.intValue)
  #expect(journalSize >= 512)
  try writeSyntheticJournalBinding(
    databaseURL: fixture.url, journalURL: URL(fileURLWithPath: journalPath))
  let journalBytes = try Data(contentsOf: URL(fileURLWithPath: journalPath))
  // The interrupted CLI leaves an uncommitted journal body; mark its header as a hot journal
  // to model the crash boundary after the header sync but before database-page commit.
  var hotJournal = journalBytes
  hotJournal.replaceSubrange(0..<8, with: [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7])
  hotJournal.replaceSubrange(8..<12, with: [0xff, 0xff, 0xff, 0xff])
  try hotJournal.write(to: URL(fileURLWithPath: journalPath))
  #expect(Darwin.kill(process.processIdentifier, SIGKILL) == 0)
  process.waitUntilExit()
  var journal = stat()
  #expect(lstat(journalPath, &journal) == 0)
  #expect((journal.st_mode & mode_t(0o777)) == mode_t(S_IRUSR | S_IWUSR))
  #expect(journal.st_uid == getuid())
  #expect(journal.st_nlink == 1)

  var pinnedOpen = false
  do {
    _ = try LedgerStore.openForMutation(at: fixture.url) { phase in
      if phase == .afterPinnedOpen { pinnedOpen = true }
    }
  } catch {
    #expect(pinnedOpen)
    try expectInactiveJournal(at: journalPath)
    throw error
  }
  #expect(pinnedOpen)
  #expect(try Data(contentsOf: fixture.url) == before)
  for suffix in ["-wal", "-shm"] {
    #expect(!FileManager.default.fileExists(atPath: fixture.url.path + suffix))
  }
  try expectInactiveJournal(at: journalPath)
}

@Test func recoveryJournalSwapAfterAuthenticationFailsWithoutTouchingReplacement() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try makeFileBackedMutationFixture(in: directory)
  let journalURL = URL(fileURLWithPath: fixture.url.path + "-journal")
  let bindingURL = URL(fileURLWithPath: fixture.url.path + "-journal.ledger-atlas-binding")
  let parkedURL = directory.appendingPathComponent("parked-journal")
  let parkedBindingURL = directory.appendingPathComponent("parked-journal.ledger-atlas-binding")
  let replacementURL = directory.appendingPathComponent("replacement-journal")
  var originalJournal = Data(repeating: 0xA5, count: 512)
  originalJournal.replaceSubrange(0..<8, with: [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7])
  try originalJournal.write(to: journalURL, options: .atomic)
  #expect(chmod(journalURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
  try writeSyntheticJournalBinding(databaseURL: fixture.url, journalURL: journalURL)
  let replacementJournal = Data(repeating: 0x5A, count: 512)
  try replacementJournal.write(to: replacementURL, options: .atomic)
  #expect(chmod(replacementURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
  let before = try Data(contentsOf: fixture.url)
  var authenticated = false
  var pinnedOpen = false

  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try LedgerStore.openForMutation(at: fixture.url) { phase in
      guard phase == .afterRecoveryJournalAuthenticated else {
        if phase == .afterPinnedOpen { pinnedOpen = true }
        return
      }
      authenticated = true
      guard Darwin.rename(journalURL.path, parkedURL.path) == 0,
        Darwin.rename(bindingURL.path, parkedBindingURL.path) == 0,
        Darwin.rename(replacementURL.path, journalURL.path) == 0
      else { throw TestError.injected }
    }
  }
  #expect(authenticated)
  #expect(!pinnedOpen)
  #expect(try Data(contentsOf: fixture.url) == before)
  #expect(try Data(contentsOf: parkedURL) == originalJournal)
  #expect(try Data(contentsOf: journalURL) == replacementJournal)
  for suffix in ["-wal", "-shm"] {
    #expect(!FileManager.default.fileExists(atPath: fixture.url.path + suffix))
  }
}

@Test func expectedMutationIdentityRejectsAPathSwapBeforePinnedSQLiteOpen() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try makeFileBackedMutationFixture(in: directory)
  let replacement = directory.appendingPathComponent("replacement.sqlite")
  sqlite3_close(try makeCanonicalDatabase(at: replacement))
  #expect(chmod(replacement.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
  let parked = directory.appendingPathComponent("parked.sqlite")
  let originalBytes = try Data(contentsOf: fixture.url)
  let replacementBytes = try Data(contentsOf: replacement)
  var expectedIdentity = stat()
  #expect(lstat(fixture.url.path, &expectedIdentity) == 0)
  var reachedPinnedOpen = false

  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try LedgerStore.openForMutation(
      at: fixture.url, expectedIdentity: expectedIdentity,
      testing: { phase in
        if phase == .afterPinnedOpen { reachedPinnedOpen = true }
        guard phase == .afterRecoveryJournalAuthenticated else { return }
        #expect(Darwin.rename(fixture.url.path, parked.path) == 0)
        #expect(Darwin.rename(replacement.path, fixture.url.path) == 0)
      })
  }

  #expect(!reachedPinnedOpen)
  #expect(try Data(contentsOf: parked) == originalBytes)
  #expect(try Data(contentsOf: fixture.url) == replacementBytes)
  for suffix in ["-wal", "-shm"] {
    #expect(!FileManager.default.fileExists(atPath: fixture.url.path + suffix))
  }
}

@Test func importedEventLoaderRejectsUnknownKindAndInvalidCivilDates() throws {
  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try makeStoreWithImportedEvent(kind: "not-a-kind")
  }

  #expect(throws: LedgerStore.Error.incompatibleCanonicalStore) {
    try makeStoreWithImportedEvent(kind: "income", localMonth: 13)
  }
}

@Test func importedAdjustmentEventsMaterializeWithoutSilentDefaults() throws {
  let store = try makeStoreWithImportedEvent(kind: "adjustment")
  try store.materializeImportedEvents()
  let snapshot = try store.readSnapshot()
  #expect(snapshot.transactions.count == 1)
  #expect(snapshot.transactions[0].currentRevision.draft.kind == .adjustment)
}

@Test func importedDebitAdjustmentsRemoveMoney() throws {
  let store = try makeStoreWithImportedEvent(kind: "adjustment_debit")
  try store.materializeImportedEvents()
  let snapshot = try store.readSnapshot()
  #expect(snapshot.transactions.count == 1)
  let draft = snapshot.transactions[0].currentRevision.draft
  #expect(draft.kind == .adjustment)
  #expect(draft.effects.map(\.direction) == [.decrease])
}

@Test func importedCreditAdjustmentsStillAddMoney() throws {
  let store = try makeStoreWithImportedEvent(kind: "adjustment")
  try store.materializeImportedEvents()
  let draft = try store.readSnapshot().transactions[0].currentRevision.draft
  #expect(draft.effects.map(\.direction) == [.increase])
}

private func makeStoreWithImportedEvent(kind: String, localMonth: Int = 1) throws -> LedgerStore {
  let database = try makeCanonicalDatabase()
  let accountID = String(repeating: "d", count: 64)
  let artifact = String(repeating: "a", count: 64)
  let receipt = CanonicalStagingID.stage(
    artifactSHA256: artifact, profileID: "synthetic-profile",
    adapterVersion: "synthetic-adapter-v1")
  let sourceRecordID = CanonicalStagingID.record(
    stagingID: receipt, table: "INOUTCOME", recordKey: "event")
  let eventID = try StableCanonicalID.event(sourceRecordID: sourceRecordID, effectOrdinal: 0)
  let bindingIDs = (0..<5).map { (index: Int) in
    CanonicalStagingID.field(
      stagingID: receipt,
      locator: SourceLocator(
        table: "INOUTCOME", recordKey: "event", columnOrdinal: index,
        columnName: "c\(index)"))
  }
  let provenanceID = bindingIDs[0]
  let provenanceRows = bindingIDs.enumerated().map { index, id in
    "INSERT INTO provenance_reference VALUES ('\(id)', '\(artifact)', 'synthetic-profile', 'synthetic-adapter-v1', NULL, 'INOUTCOME', 'event', \(index), 'c\(index)')"
  }.joined(separator: ";")
  let bindings = zip(["amount", "currency", "occurred_at", "account", "kind"], bindingIDs)
    .map { semantic, id in
      "INSERT INTO event_source_binding VALUES ('\(eventID)', '\(semantic)', '\(id)', 'TEXT', 'text'); INSERT INTO receipt_binding VALUES ('\(receipt)', '\(eventID)', '\(semantic)', '\(id)')"
    }.joined(separator: ";")
  var eventComponents = [
    CanonicalReceiptDigest.eventSetPrefix, eventID, accountID, kind, "1.00", "USD", "0",
    "1970", String(localMonth), "1", "0", "0", "0", "0", "fixed", "0", "millisecond",
    "0", sourceRecordID, provenanceID,
  ]
  for (semantic, id) in zip(
    ["amount", "currency", "occurred_at", "account", "kind"], bindingIDs
  ).sorted(by: { $0.0 < $1.0 }) {
    eventComponents.append(contentsOf: [semantic, id, "optional:some", "TEXT", "text"])
  }
  let eventSetHash = CanonicalReceiptDigest.hash(eventComponents)
  let preservationHash = CanonicalReceiptDigest.hash([
    "ledger-atlas/receipt-owned-preservation-set/v4"
  ])
  let reconciliationHash = CanonicalReceiptDigest.hash([
    "ledger-atlas/canonical-receipt-integrity/v6", receipt, artifact, artifact,
    "synthetic-profile", "synthetic-adapter-v1", eventSetHash, "1", "8", eventSetHash,
    preservationHash,
  ])
  try execute(
    database,
    """
    \(provenanceRows);
    INSERT INTO economic_event(
      event_id, account_id, event_kind, amount_literal, currency_unit,
      instant_milliseconds, local_year, local_month, local_day, local_hour, local_minute,
      local_second, local_millisecond, timezone_kind, timezone_value, temporal_precision,
      resolved_offset_seconds, source_record_id, provenance_id
    ) VALUES (
      '\(eventID)', '\(accountID)', '\(kind)', '1.00', 'USD',
      0, 1970, \(localMonth), 1, 0, 0, 0, 0, 'fixed', '0', 'millisecond',
      0, '\(sourceRecordID)', '\(provenanceID)'
    );
    INSERT INTO import_receipt VALUES ('\(receipt)', '\(artifact)', '\(artifact)', 'synthetic-profile', 'synthetic-adapter-v1', '\(reconciliationHash)', '\(eventSetHash)', 1, 8);
    INSERT INTO receipt_event VALUES ('\(receipt)', '\(eventID)');
    \(bindings);
    """)
  return try LedgerStore(takingOwnershipOfValidatedCanonicalDatabase: database)
}

private func expectInactiveJournal(at path: String) throws {
  var value = stat()
  #expect(lstat(path, &value) == 0)
  #expect(value.st_size == 0)
}

private func writeSyntheticJournalBinding(databaseURL: URL, journalURL: URL) throws {
  var database = stat()
  var journal = stat()
  guard lstat(databaseURL.path, &database) == 0, lstat(journalURL.path, &journal) == 0 else {
    throw TestError.sqlite
  }
  let payload =
    "ledger-atlas-journal-v3\n\(database.st_dev)\n\(database.st_ino)\n\(database.st_birthtimespec.tv_sec)\n\(database.st_birthtimespec.tv_nsec)\n\(journal.st_dev)\n\(journal.st_ino)\n\(journal.st_birthtimespec.tv_sec)\n\(journal.st_birthtimespec.tv_nsec)\n"
  let binding = URL(fileURLWithPath: journalURL.path + ".ledger-atlas-binding")
  try Data(payload.utf8).write(to: binding, options: .atomic)
  #expect(chmod(binding.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
}

private func makeStore() throws -> LedgerStore {
  let database = try makeCanonicalDatabase()
  return try LedgerStore(takingOwnershipOfValidatedCanonicalDatabase: database)
}

private func makeCanonicalDatabase() throws -> OpaquePointer {
  var database: OpaquePointer?
  guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else {
    throw TestError.sqlite
  }
  try initializeCanonicalDatabase(database)
  return database
}

private func makeCanonicalDatabase(at url: URL) throws -> OpaquePointer {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw TestError.sqlite
  }
  try initializeCanonicalDatabase(database)
  return database
}

private func makeFileBackedMutationFixture(in directory: URL) throws -> (
  url: URL, request: LedgerStore.CreateTransactionRequest
) {
  let url = directory.appendingPathComponent("ledger.sqlite")
  let database = try makeCanonicalDatabase(at: url)
  let origin = try LedgerOrigin(id: String(repeating: "a", count: 64), label: "synthetic")
  let accountID = try StableLedgerID.account(
    origin: origin, localKey: String(repeating: "b", count: 64))
  try execute(
    database,
    """
    INSERT INTO ledger_origin VALUES ('\(origin.id)', 'synthetic', NULL);
    INSERT INTO ledger_account VALUES ('\(accountID)', 'Cash', 'USD', '\(origin.id)', 'active');
    """)
  sqlite3_close(database)
  #expect(chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
  let temporal = try SourceTemporal(
    instant: .init(epochMilliseconds: 0),
    localDateTime: .init(
      date: .init(year: 1970, month: 1, day: 1), hour: 0, minute: 0, second: 0,
      millisecond: 0),
    timeZone: .init(fixedOffsetSeconds: 0), precision: .millisecond,
    resolvedOffsetSeconds: 0)
  let draft = try LedgerTransactionDraft(
    effects: [
      .init(
        accountID: accountID, direction: .increase,
        amount: .init(unitCode: "USD", amount: .init("3")))
    ],
    categoryID: nil, kind: .adjustment, occurredAt: temporal, origin: origin)
  return (
    url,
    .init(
      idempotencyKey: String(repeating: "c", count: 64), draft: draft,
      createdAt: .init(epochMilliseconds: 1))
  )
}

private func initializeCanonicalDatabase(_ database: OpaquePointer) throws {
  for statement in CanonicalLedgerSchema.creationStatements {
    guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
      throw TestError.sqlite
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
  else { throw TestError.sqlite }
}

private func execute(_ database: OpaquePointer, _ sql: String) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw TestError.sqlite }
}

private enum TestError: Swift.Error { case sqlite, injected }
