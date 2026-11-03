import CSQLite
import CryptoKit
import Foundation
import LedgerAdapterSemantics
import LedgerCore
import LedgerStore
import Security
import Testing

@Test("an admitted Money Manager v19 v10 graph requires authenticated re-import")
func admittedMoneyManagerV19V10GraphRequiresAuthenticatedReimport() throws {
  try withPersistedV19Ledger(version: 10) { url, fixture in
    #expect(try LedgerStoreLifecycle.inspect(at: url) == .upgradeRequired)
    let before = try Data(contentsOf: url)
    #expect(throws: LedgerStoreLifecycle.Error.unsupportedStore) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try Data(contentsOf: url) == before)
    #expect(try readReceiptEventCount(at: url, receipt: fixture.receiptID) == 1)
  }
}

@Test("legacy v19 receipts without a temporal commitment remain migration candidates")
func legacyV19ReceiptWithoutCommitmentRemainsReadable() throws {
  try withPersistedV19Ledger(version: 10, includeCommitment: false) { url, _ in
    let inspection = try LedgerStoreLifecycle.inspect(at: url)
    #expect(inspection == .upgradeRequired)
  }
}

@Test("an imported v19 transaction can be corrected the way the app does it, and reopens")
func importedV19TransactionCorrectionReopens() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, _ in
    do {
      let app = LedgerApplication(store: try LedgerStoreLifecycle.open(at: url).store)
      let target = try #require(
        try app.snapshot().transactions.first { $0.currentRevision.lifecycle == .active })
      let draft = target.currentRevision.draft
      // LedgerJourney drops the import receipt markers from a correction.
      _ = try app.correctTransaction(
        transactionID: target.id, expectedCurrentRevisionID: target.currentRevision.id,
        draft: try LedgerTransactionDraft(
          effects: draft.effects, categoryID: draft.categoryID, kind: draft.kind,
          occurredAt: draft.occurredAt, note: (draft.note ?? "") + " (checked)",
          roundingPolicy: draft.roundingPolicy,
          sourceLiterals: draft.sourceLiterals.filter {
            !$0.field.hasPrefix("import.") && !$0.field.hasPrefix("conversion.")
          },
          origin: draft.origin),
        createdAt: UTCInstant(epochMilliseconds: 1_793_000_000_000))
    }
    let reopened = LedgerApplication(store: try LedgerStoreLifecycle.open(at: url).store)
    #expect(try reopened.snapshot().revisionHistory.count == 2)
  }
}

/// A save skips the import-graph replay only while the import graph is provably untouched; a
/// save that adds an import marker, or one after another connection changed imported rows,
/// gets the full replay and is refused.
@Test("a save re-checks the import graph whenever it could have changed")
func saveRechecksImportGraphWhenItCouldHaveChanged() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, _ in
    let app = LedgerApplication(store: try LedgerStoreLifecycle.open(at: url).store)
    var createdAt: Int64 = 1_793_000_000_000
    func correct(addingImportMarker: Bool = false) throws {
      let target = try #require(
        try app.snapshot().transactions.first { $0.currentRevision.lifecycle == .active })
      let draft = target.currentRevision.draft
      let kept = draft.sourceLiterals.filter {
        !$0.field.hasPrefix("import.") && !$0.field.hasPrefix("conversion.")
      }
      let marker = try LedgerSourceLiteral(
        field: MoneyManagerV19Semantics.receiptGenerationField,
        literal: MoneyManagerV19Semantics.currentReceiptGenerationLiteral)
      createdAt += 1_000
      _ = try app.correctTransaction(
        transactionID: target.id, expectedCurrentRevisionID: target.currentRevision.id,
        draft: try LedgerTransactionDraft(
          effects: draft.effects, categoryID: draft.categoryID, kind: draft.kind,
          occurredAt: draft.occurredAt, note: (draft.note ?? "") + " (edited)",
          roundingPolicy: draft.roundingPolicy,
          sourceLiterals: addingImportMarker ? kept + [marker] : kept,
          origin: draft.origin),
        createdAt: UTCInstant(epochMilliseconds: createdAt))
    }

    try correct()
    // A second v19 marker on an imported transaction breaks the import proof.
    #expect(throws: (any Error).self) { try correct(addingImportMarker: true) }
    try correct()

    // Another connection changes an imported amount between two saves.
    try withSQLite(url) { database in
      try execute(
        database,
        "UPDATE economic_event SET amount_literal='987654321' WHERE rowid=(SELECT min(rowid) FROM economic_event);"
      )
    }
    #expect(throws: (any Error).self) { try correct() }
  }
}

@Test("an authenticated v19 backup reopens on the same Mac with its external trust key")
func authenticatedV19BackupReopensOnSameDevice() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, _ in
    let source = try LedgerStore.openReadOnly(at: url)
    let destination = url.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
    try source.backupCanonicalDatabase(to: destination)
    let restored = try LedgerStore.openReadOnly(at: destination)
    #expect(try restored.semanticChecksum() == source.semanticChecksum())
  }
}

@Test("current v11 receipt verification rejects a missing external trust key")
func currentV11RejectsMissingExternalTrustKey() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, _ in
    try withSQLite(url) { database in
      #expect(!CanonicalLedgerHealth.isHealthy(database, trustKey: nil))
    }
  }
}

/// A remembered stamp lets the check skip the replay, but only for the same import rows under
/// the same trust key. Any change to the import graph, or another key, gets the full replay.
@Test("a remembered import graph skips the replay only for the same rows and key")
func rememberedImportGraphSkipsReplayOnlyWhenUnchanged() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, fixture in
    let key = try #require(
      try LedgerReceiptTrust.key(for: url, create: false, stableIdentity: fixture.receiptID))
    let otherKey = Data(repeating: 7, count: 32)
    let remembered = CanonicalLedgerHealth.VerifiedImportGraphs(defaults: nil)
    let healthyStamp = try withSQLite(url) { database in
      try CanonicalLedgerHealth.validate(database, trustKey: key, remembering: remembered)
      let stamp = try CanonicalLedgerHealth.importGraphStamp(database, trustKey: key)
      #expect(remembered.contains(stamp))
      #expect(try CanonicalLedgerHealth.importGraphStamp(database, trustKey: otherKey) != stamp)
      return stamp
    }

    // An import-graph change the replay refuses: the remembered stamp no longer matches.
    try mutateAndRehash(
      at: url, fixture: fixture,
      sql: """
        DELETE FROM receipt_binding
          WHERE idempotency_key=\(quote(fixture.receiptID))
            AND event_id=\(quote(fixture.eventID)) AND semantic='kind';
        """,
      overrides: fixture.digestOverrides())
    try withSQLite(url) { database in
      let changedStamp = try CanonicalLedgerHealth.importGraphStamp(database, trustKey: key)
      #expect(changedStamp != healthyStamp)
      #expect(throws: (any Error).self) {
        try CanonicalLedgerHealth.validate(database, trustKey: key, remembering: remembered)
      }
      #expect(!remembered.contains(changedStamp))

      // Only a stamp for these exact rows skips the replay; the check then passes. The same
      // stamp is never accepted under another key, or when nothing is remembered.
      remembered.insert(changedStamp)
      #expect(throws: Never.self) {
        try CanonicalLedgerHealth.validate(database, trustKey: key, remembering: remembered)
      }
      #expect(throws: (any Error).self) {
        try CanonicalLedgerHealth.validate(database, trustKey: otherKey, remembering: remembered)
      }
      #expect(throws: (any Error).self) {
        try CanonicalLedgerHealth.validate(database, trustKey: key)
      }
    }
  }
}

/// Opening a ledger file the app already fully checked, byte for byte unchanged, skips the slow
/// checks. Any change to the bytes, another key, or an open that did not digest the file gets
/// the full check.
@Test("a remembered ledger file skips the open checks only while its bytes are unchanged")
func rememberedLedgerFileSkipsChecksOnlyWhileUnchanged() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, fixture in
    let key = try #require(try LedgerReceiptTrust.key(for: url, create: false))
    // Its own stamps: a stamp for the broken file below must never reach other tests, whose
    // fixtures can have the same bytes.
    let remembered = CanonicalLedgerHealth.VerifiedImportGraphs(defaults: nil)
    func open() throws -> LedgerStoreLifecycle.Result {
      try LedgerStoreLifecycle.open(at: url, testing: nil, verifiedFiles: remembered)
    }
    func fileStamp(_ key: Data) throws -> String {
      let digest = SHA256.hash(data: try Data(contentsOf: url))
      return try #require(
        CanonicalLedgerHealth.verifiedFileStamp(
          contentDigest: digest.map { String(format: "%02x", $0) }.joined(), trustKey: key))
    }

    // A stamp is only made or trusted once the file's change time is more than two seconds old,
    // so that any later write must move it.
    func letChangeTimeAge() { Thread.sleep(forTimeInterval: 3.2) }

    // A file written just now gets the full check but no stamp.
    do { _ = try open() }
    #expect(!remembered.contains(try fileStamp(key)))

    // A full open of a healthy file remembers its bytes.
    letChangeTimeAge()
    do { _ = try open() }
    #expect(remembered.contains(try fileStamp(key)))
    #expect(try fileStamp(Data(repeating: 7, count: 32)) != fileStamp(key))
    #expect(CanonicalLedgerHealth.verifiedFileStamp(contentDigest: "00", trustKey: key) == nil)

    // A change the import replay refuses, so only a skipped check could let it open.
    try mutateAndRehash(
      at: url, fixture: fixture,
      sql: """
        DELETE FROM receipt_binding
          WHERE idempotency_key=\(quote(fixture.receiptID))
            AND event_id=\(quote(fixture.eventID)) AND semantic='kind';
        """,
      overrides: fixture.digestOverrides())
    letChangeTimeAge()
    #expect(throws: (any Error).self) { try open() }
    let brokenStamp = try fileStamp(key)
    #expect(!remembered.contains(brokenStamp))

    // Remembering these exact bytes skips the checks. An open that did not digest the file
    // never trusts a stamp.
    remembered.insert(brokenStamp)
    #expect(throws: Never.self) { _ = try open() }
    #expect(throws: (any Error).self) { try LedgerStore.openForMutation(at: url) }

    // Any write changes the bytes, even one that puts a value back, and the full check runs
    // again. A caller holding the old identity and digest is refused too.
    var oldIdentity = stat()
    #expect(lstat(url.path, &oldIdentity) == 0)
    let oldDigest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }
      .joined()
    try withSQLite(url) { database in
      try execute(
        database,
        """
        UPDATE ledger_meta SET value='changed' WHERE key='schema_version';
        UPDATE ledger_meta SET value='\(CanonicalLedgerSchema.version)' WHERE key='schema_version';
        """)
    }
    #expect(try fileStamp(key) != brokenStamp)
    #expect(throws: (any Error).self) { try open() }
    #expect(throws: (any Error).self) {
      try LedgerStore.openForMutation(
        at: url, expectedIdentity: oldIdentity, contentDigest: oldDigest,
        verifiedFiles: remembered, testing: nil)
    }
  }
}

/// A write that lands after the file was digested, but before the open's check holds its read
/// lock, must not be covered by the stamp of the digested bytes.
@Test("a write between the digest and the check's read lock gets the full check")
func writeAfterDigestGetsTheFullCheck() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, fixture in
    let remembered = CanonicalLedgerHealth.VerifiedImportGraphs(defaults: nil)
    Thread.sleep(forTimeInterval: 3.2)  // so the file's change time is old enough to stamp
    do { _ = try LedgerStoreLifecycle.open(at: url, testing: nil, verifiedFiles: remembered) }
    var identity = stat()
    #expect(lstat(url.path, &identity) == 0)
    let digest = hexDigest(of: try Data(contentsOf: url))
    let key = try #require(try LedgerReceiptTrust.key(for: url, create: false))
    #expect(
      remembered.contains(
        try #require(CanonicalLedgerHealth.verifiedFileStamp(contentDigest: digest, trustKey: key)))
    )

    var wrote = false
    #expect(throws: (any Error).self) {
      try LedgerStore.openForMutation(
        at: url, expectedIdentity: identity, contentDigest: digest, verifiedFiles: remembered,
        testing: { phase in
          guard phase == .afterPinnedOpen, !wrote else { return }
          // A change the import replay refuses, so only a skipped check could let it open.
          try mutateAndRehash(
            at: url, fixture: fixture,
            sql: """
              DELETE FROM receipt_binding
                WHERE idempotency_key=\(quote(fixture.receiptID))
                  AND event_id=\(quote(fixture.eventID)) AND semantic='kind';
              """,
            overrides: fixture.digestOverrides())
          wrote = true
        })
    }
    #expect(wrote)
  }
}

/// A store opened from a checked file keeps it remembered through its own checked saves, so a
/// reopen after edits is fast too. Another connection's write ends that, as does an open that
/// didn't check a digested file.
@Test("checked saves keep a remembered file remembered, and nothing else does")
func checkedSavesKeepARememberedFileRemembered() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, _ in
    let remembered = CanonicalLedgerHealth.VerifiedImportGraphs(defaults: nil)
    let key = try #require(try LedgerReceiptTrust.key(for: url, create: false))
    func isRemembered() throws -> Bool {
      remembered.contains(
        try #require(
          CanonicalLedgerHealth.verifiedFileStamp(
            contentDigest: hexDigest(of: try Data(contentsOf: url)), trustKey: key)))
    }
    // Change times must be more than two seconds old before they can prove anything on a
    // volume with coarse timestamps.
    func letChangeTimeAge() { Thread.sleep(forTimeInterval: 3.1) }
    func rename(_ store: LedgerStore, _ name: String) throws {
      let account = try #require(try store.readSnapshot().accounts.first)
      try store.updateAccount(
        try LedgerAccount(
          id: account.id, name: name, currencyUnit: account.currencyUnit, origin: account.origin,
          lifecycle: account.lifecycle, groupID: account.groupID,
          displayOrder: account.displayOrder, hidden: account.hidden,
          includeInTotals: account.includeInTotals, variant: account.variant))
    }

    Thread.sleep(forTimeInterval: 3.2)
    do {
      let store = try LedgerStoreLifecycle.open(at: url, testing: nil, verifiedFiles: remembered)
        .store
      #expect(try isRemembered())
      try rename(store, "Saved once")
      letChangeTimeAge()
      try rename(store, "Saved twice")
      #expect(try !isRemembered())
      letChangeTimeAge()
      #expect(store.rememberFileNow(), "\(store.fileStamper?.lastRefusal ?? "no stamper")")
      #expect(try isRemembered())

      // Another connection's commit: the store no longer vouches for the file.
      try withSQLite(url) { database in
        try execute(database, "UPDATE ledger_account SET name='Renamed elsewhere';")
      }
      letChangeTimeAge()
      try rename(store, "Saved after")
      letChangeTimeAge()
      #expect(!store.rememberFileNow())
      #expect(try !isRemembered())
    }

    // An open that didn't check a digested file never remembers its saves.
    let unchecked = try LedgerStore.openForMutation(
      at: url, verifiedFiles: remembered, testing: nil)
    try rename(unchecked, "Saved unchecked")
    letChangeTimeAge()
    #expect(!unchecked.rememberFileNow())
    #expect(try !isRemembered())
  }
}

/// The background stamp reads the ledger while the editor may be saving. It must never cost a
/// save its lock: closing a separate descriptor to the file would drop every lock the process
/// holds on it (#140).
@Test("a stamp taken in the background never makes a save fail")
func backgroundStampNeverFailsASave() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, _ in
    let store = try LedgerStore.openForMutation(at: url, testing: nil)
    let stamper = LedgerFileStamper(
      url: url, verifiedFiles: CanonicalLedgerHealth.VerifiedImportGraphs(defaults: nil),
      fineTimestamps: true)
    let stop = LockedFlag()
    let attempted = LockedFlag()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      while !stop.isSet {
        var identity = stat()
        if lstat(url.path, &identity) == 0 { _ = stamper.stamp(identity) }
        attempted.set()
      }
      finished.signal()
    }
    let account = try #require(try store.readSnapshot().accounts.first)
    var saveError: (any Error)?
    do {
      for index in 0..<60 {
        try store.updateAccount(
          try LedgerAccount(
            id: account.id, name: "Save \(index)", currencyUnit: account.currencyUnit,
            origin: account.origin, lifecycle: account.lifecycle, groupID: account.groupID,
            displayOrder: account.displayOrder, hidden: account.hidden,
            includeInTotals: account.includeInTotals, variant: account.variant))
      }
    } catch { saveError = error }
    stop.set()
    finished.wait()
    if let saveError { throw saveError }
    #expect(attempted.isSet)
    #expect(try store.readSnapshot().accounts.first { $0.id == account.id }?.name == "Save 59")
    // And once saves stop, the stamp goes through.
    var identity = stat()
    #expect(lstat(url.path, &identity) == 0)
    #expect(stamper.stamp(identity), "\(stamper.lastRefusal ?? "")")
  }
}

/// On a large ledger the background check holds its read lock for seconds, longer than a save
/// waits for one. A save stops the check instead of waiting it out.
@Test("a save stops a running background check instead of waiting for it")
func saveStopsARunningStamp() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, _ in
    Thread.sleep(forTimeInterval: 3.2)
    let store = try LedgerStoreLifecycle.open(
      at: url, testing: nil, verifiedFiles: .init(defaults: nil)
    ).store
    let stamper = try #require(store.fileStamper)
    let inCheck = DispatchSemaphore(value: 0)
    // Hold the check's read lock until the check is cancelled, or for 20 seconds.
    stamper.afterPageCheck = { stillCurrent in
      inCheck.signal()
      let deadline = Date().addingTimeInterval(20)
      while stillCurrent() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }
    var current = stat()
    #expect(lstat(url.path, &current) == 0)
    let identity = current
    let stamped = LockedFlag()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      if stamper.stamp(identity) { stamped.set() }
      finished.signal()
    }
    #expect(inCheck.wait(timeout: .now() + 20) == .success)
    let account = try #require(try store.readSnapshot().accounts.first)
    let started = Date()
    try store.updateAccount(
      try LedgerAccount(
        id: account.id, name: "Saved during a check", currencyUnit: account.currencyUnit,
        origin: account.origin, lifecycle: account.lifecycle, groupID: account.groupID,
        displayOrder: account.displayOrder, hidden: account.hidden,
        includeInTotals: account.includeInTotals, variant: account.variant))
    #expect(Date().timeIntervalSince(started) < 4)
    #expect(finished.wait(timeout: .now() + 20) == .success)
    #expect(!stamped.isSet)
    #expect(
      try store.readSnapshot().accounts.first { $0.id == account.id }?.name
        == "Saved during a check")
  }
}

/// A screen refresh reuses the preserved source rows, but never past a change to them.
@Test("a snapshot reuses preserved source rows only while nothing could have changed them")
func snapshotReloadsPreservedSourceAfterAnotherConnectionWrites() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, _ in
    let store = try LedgerStoreLifecycle.open(at: url).store
    let first = try store.readSnapshot().preservedSource
    #expect(!first.isEmpty)
    #expect(try store.readSnapshot().preservedSource == first)

    // Another connection rewrites one preserved payload; no row count changes.
    try withSQLite(url) { database in
      try execute(
        database,
        "UPDATE sidecar_reference SET payload=X'2A2A' WHERE rowid=(SELECT min(rowid) FROM sidecar_reference);"
      )
    }
    let after = try store.readSnapshot().preservedSource
    #expect(after != first)
    #expect(after.contains { $0.payload == Data([0x2A, 0x2A]) })
  }
}

/// Saves and screen refreshes reuse the last checked snapshot, but never past a change to the
/// file, whoever made it.
@Test("a store reuses its checked snapshot only while nothing could have changed it")
func storeReloadsCoreSnapshotAfterAnyWrite() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, _ in
    var refuseNextSave = false
    let store = try LedgerStore.openForMutation(
      at: url,
      testing: { phase in
        guard phase == .afterMutationWrite, refuseNextSave else { return }
        refuseNextSave = false
        throw LedgerStore.Error.incompatibleCanonicalStore
      })
    let account = try #require(try store.readSnapshot().accounts.first)
    func renamed(_ name: String) throws -> LedgerAccount {
      try LedgerAccount(
        id: account.id, name: name, currencyUnit: account.currencyUnit, origin: account.origin,
        lifecycle: account.lifecycle, groupID: account.groupID,
        displayOrder: account.displayOrder, hidden: account.hidden,
        includeInTotals: account.includeInTotals, variant: account.variant)
    }
    func currentName() throws -> String? {
      try store.readSnapshot().accounts.first { $0.id == account.id }?.name
    }
    func renameElsewhere(_ name: String) throws {
      try withSQLite(url) { database in
        try execute(
          database,
          "UPDATE ledger_account SET name=\(quote(name)) WHERE account_id=\(quote(account.id));")
      }
    }
    #expect(try currentName() == account.name)

    // Another connection's commit reaches the next refresh.
    try renameElsewhere("Renamed elsewhere")
    #expect(try currentName() == "Renamed elsewhere")

    // And the next save: re-creating the account as it now stands is a no-op, while the stale
    // copy would refuse it.
    try renameElsewhere("Renamed again")
    try store.createAccount(try renamed("Renamed again"))
    #expect(try currentName() == "Renamed again")

    // This connection's own saves reach the next refresh and the next save.
    try store.updateAccount(try renamed("Saved here"))
    #expect(try currentName() == "Saved here")
    try store.createAccount(try renamed("Saved here"))
    #expect(throws: (any Error).self) { try store.createAccount(try renamed("Renamed again")) }
    #expect(try currentName() == "Saved here")

    // A save that writes and is then refused leaves nothing behind for the next refresh or save.
    refuseNextSave = true
    #expect(throws: (any Error).self) { try store.updateAccount(try renamed("Rolled back")) }
    #expect(try currentName() == "Saved here")
    try store.createAccount(try renamed("Saved here"))
  }
}

@Test("the health check leaves the caller's connection as it found it")
func healthCheckRestoresConnectionState() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, fixture in
    let key = try LedgerReceiptTrust.key(
      for: url, create: false, stableIdentity: fixture.receiptID)
    try withSQLite(url) { database in
      func cacheSize() -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA cache_size", -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW
        else { return 0 }
        return sqlite3_column_int64(statement, 0)
      }
      try execute(database, "PRAGMA cache_size=-1234")
      // Outside a transaction: it opens and closes its own, pass or fail.
      #expect(CanonicalLedgerHealth.isHealthy(database, trustKey: key))
      #expect(!CanonicalLedgerHealth.isHealthy(database, trustKey: nil))
      #expect(sqlite3_get_autocommit(database) != 0)
      #expect(cacheSize() == -1234)
      // Inside the caller's transaction: it never commits or ends it.
      try execute(database, "BEGIN")
      #expect(CanonicalLedgerHealth.isHealthy(database, trustKey: key))
      #expect(sqlite3_get_autocommit(database) == 0)
      try execute(database, "COMMIT")
      #expect(cacheSize() == -1234)
    }
  }
}

@Test("current v11 receipt verification rejects a replacement signer key")
func currentV11RejectsReplacementSignerKey() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, fixture in
    guard
      let originalKey = try LedgerReceiptTrust.key(
        for: url, create: false, stableIdentity: fixture.receiptID)
    else { throw ReplayError.sqlite }
    let replacementKey = Data(repeating: 0xA5, count: 32)
    let replacementSignature = LedgerReceiptTrust.signature(
      key: replacementKey, receiptID: fixture.receiptID,
      integrityHash: try fixture.reconciliationHash())
    try withSQLite(url) { database in
      try execute(
        database,
        "UPDATE ledger_receipt_trust_anchor SET signature=\(quote(replacementSignature)) WHERE idempotency_key=\(quote(fixture.receiptID));"
      )
      #expect(!CanonicalLedgerHealth.isHealthy(database, trustKey: originalKey))
    }
  }
}

@Test("new receipt trust keys remain readable through a synchronizable Keychain query")
func synchronizableReceiptTrustKeyRoundTrips() throws {
  let identity = String(repeating: "a", count: 63) + "b"
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let account = CanonicalReceiptDigest.sha256(
    Data("ledger-atlas/receipt-key/v3\n\(identity)".utf8))
  let cleanup: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.praxstack.ledger-atlas.receipt-integrity.v1",
    kSecAttrAccount as String: account,
    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
  ]
  defer { SecItemDelete(cleanup as CFDictionary) }
  let created = try LedgerReceiptTrust.key(for: url, create: true, stableIdentity: identity)
  let reopened = try LedgerReceiptTrust.key(for: url, create: false, stableIdentity: identity)
  #expect(created == reopened)
  var item: CFTypeRef?
  let status = SecItemCopyMatching(
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.praxstack.ledger-atlas.receipt-integrity.v1",
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: true,
      kSecReturnData as String: true,
    ] as CFDictionary,
    &item)
  // Unsigned SwiftPM tests cannot request the iCloud Keychain entitlement. The signed app target
  // exercises this branch; the package fallback still proves that local reopen remains usable.
  if status == errSecMissingEntitlement || status == errSecItemNotFound { return }
  #expect(status == errSecSuccess)
  #expect(item as? Data == created)
}

@Test("legacy receipt trust keys are copied into the current namespace before use")
func legacyReceiptTrustKeyMigratesToCurrentNamespace() throws {
  let identity = String(repeating: "c", count: 63) + "d"
  let legacyAccount = CanonicalReceiptDigest.sha256(
    Data("ledger-atlas/receipt-key/v2\n\(identity)".utf8))
  let currentAccount = CanonicalReceiptDigest.sha256(
    Data("ledger-atlas/receipt-key/v3\n\(identity)".utf8))
  let service = "com.praxstack.ledger-atlas.receipt-integrity.v1"
  let legacyQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: legacyAccount,
    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
  ]
  let currentQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: currentAccount,
    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
  ]
  defer {
    SecItemDelete(legacyQuery as CFDictionary)
    SecItemDelete(currentQuery as CFDictionary)
  }
  let legacyValue = Data(repeating: 0x3C, count: 32)
  let addStatus = SecItemAdd(
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: legacyAccount,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: legacyValue,
    ] as CFDictionary,
    nil)
  #expect(addStatus == errSecSuccess)
  let recovered = try LedgerReceiptTrust.key(
    for: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
    create: false, stableIdentity: identity)
  #expect(recovered == legacyValue)
  var item: CFTypeRef?
  let readStatus = SecItemCopyMatching(
    currentQuery.merging([
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
      kSecReturnData as String: true,
    ]) { _, current in current } as CFDictionary,
    &item)
  #expect(readStatus == errSecSuccess)
  #expect(item as? Data == legacyValue)
}

@Test("a current-schema ledger cannot be downgraded to the legacy v19 receipt generation")
func currentV11RejectsLegacyReceiptGenerationDowngrade() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, fixture in
    try mutateAndRehash(
      at: url, fixture: fixture,
      sql: """
        DROP TRIGGER ledger_transaction_source_literal_immutable_update;
        UPDATE ledger_transaction_source_literal
          SET literal='\(MoneyManagerV19Semantics.legacyReceiptGenerationLiteral)'
          WHERE field='\(MoneyManagerV19Semantics.receiptGenerationField)';
        CREATE TRIGGER ledger_transaction_source_literal_immutable_update
        BEFORE UPDATE ON ledger_transaction_source_literal
        BEGIN
          SELECT RAISE(ABORT, 'immutable ledger history');
        END;
        """, generation: .legacy)
    try assertRejectedWithoutMutation(at: url)
  }
}

// The import-graph structure checks are set queries (GROUP BY joins and EXCEPT) so a real-size
// ledger opens in minutes. Each test breaks exactly one of them and keeps every hash valid.

@Test("a current-schema ledger rejects a binding its receipt does not list")
func lifecycleRejectsBindingMissingFromReceipt() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, fixture in
    try mutateAndRehash(
      at: url, fixture: fixture,
      sql: """
        DELETE FROM receipt_binding
          WHERE idempotency_key=\(quote(fixture.receiptID))
            AND event_id=\(quote(fixture.eventID)) AND semantic='kind';
        """,
      overrides: fixture.digestOverrides())
    try assertRejectedWithoutMutation(at: url)
  }
}

@Test("a current-schema ledger rejects a sidecar its receipt does not list")
func lifecycleRejectsSidecarMissingFromReceipt() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, fixture in
    let note = fixture.field(named: "NOTE").id(in: fixture)
    try mutateAndRehash(
      at: url, fixture: fixture,
      sql: """
        DELETE FROM receipt_sidecar
          WHERE idempotency_key=\(quote(fixture.receiptID)) AND sidecar_id=\(quote(note));
        """,
      overrides: fixture.digestOverrides())
    try assertRejectedWithoutMutation(at: url)
  }
}

@Test("a current-schema ledger rejects provenance that nothing references")
func lifecycleRejectsUnreferencedProvenance() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, fixture in
    // Another artifact's identity, so only the "referenced somewhere" check can see it.
    let orphan = String(repeating: "e", count: 64)
    try mutateAndRehash(
      at: url, fixture: fixture,
      sql: """
        INSERT INTO provenance_reference VALUES (\(quote(orphan)),
          \(quote(String(repeating: "f", count: 64))), 'other-profile', '1', NULL,
          'OTHER', 'k', NULL, NULL);
        """,
      overrides: fixture.digestOverrides())
    try assertRejectedWithoutMutation(at: url)
  }
}

@Test("a current-schema ledger rejects an event its receipt does not list")
func lifecycleRejectsEventMissingFromReceipt() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, fixture in
    try withSQLite(url) { database in
      try execute(
        database,
        """
        DELETE FROM receipt_binding WHERE idempotency_key=\(quote(fixture.receiptID));
        DELETE FROM receipt_sidecar WHERE idempotency_key=\(quote(fixture.receiptID));
        DELETE FROM receipt_event WHERE idempotency_key=\(quote(fixture.receiptID));
        """)
    }
    try assertRejectedWithoutMutation(at: url)
  }
}

@Test(
  "persisted v10 and current-schema reject kind bindings repointed to memo without mutation",
  arguments: [10, CanonicalLedgerSchema.version])
func lifecycleRejectsKindBindingToMemoWithoutMutation(_ version: Int) throws {
  try withPersistedV19Ledger(version: version) { url, fixture in
    let kind = fixture.field(.kind).id(in: fixture)
    let memo = fixture.field(named: "NOTE").id(in: fixture)
    var overrides = fixture.digestOverrides()
    overrides.bindingProvenanceIDs[.kind] = memo
    try mutateAndRehash(
      at: url, fixture: fixture,
      sql: """
        UPDATE event_source_binding SET provenance_id=\(quote(memo))
          WHERE event_id=\(quote(fixture.eventID)) AND semantic='kind';
        UPDATE receipt_binding SET provenance_id=\(quote(memo))
          WHERE idempotency_key=\(quote(fixture.receiptID))
            AND event_id=\(quote(fixture.eventID)) AND semantic='kind';
        """,
      overrides: overrides)
    // Keep the original kind provenance in the graph; only the binding is forged.
    #expect(kind != memo)
    try assertRejectedWithoutMutation(at: url)
  }
}

@Test(
  "persisted v10 and current-schema reject occurred_at bindings repointed to memo without mutation",
  arguments: [10, CanonicalLedgerSchema.version])
func lifecycleRejectsOccurredAtBindingToMemoWithoutMutation(_ version: Int) throws {
  try withPersistedV19Ledger(version: version) { url, fixture in
    let occurredAt = fixture.field(.occurredAt).id(in: fixture)
    let memo = fixture.field(named: "NOTE").id(in: fixture)
    var overrides = fixture.digestOverrides()
    overrides.bindingProvenanceIDs[.occurredAt] = memo
    try mutateAndRehash(
      at: url, fixture: fixture,
      sql: """
        UPDATE event_source_binding SET provenance_id=\(quote(memo))
          WHERE event_id=\(quote(fixture.eventID)) AND semantic='occurred_at';
        UPDATE receipt_binding SET provenance_id=\(quote(memo))
          WHERE idempotency_key=\(quote(fixture.receiptID))
            AND event_id=\(quote(fixture.eventID)) AND semantic='occurred_at';
        """,
      overrides: overrides)
    #expect(occurredAt != memo)
    try assertRejectedWithoutMutation(at: url)
  }
}

@Test(
  "persisted v10 and current-schema reject amount storage and payload relabelled BLOB without mutation",
  arguments: [10, CanonicalLedgerSchema.version])
func lifecycleRejectsAmountBlobRelabelWithoutMutation(_ version: Int) throws {
  try withPersistedV19Ledger(version: version) { url, fixture in
    let amount = fixture.field(.amount).id(in: fixture)
    var overrides = fixture.digestOverrides()
    overrides.bindingStorageClasses[.amount] = .blob
    overrides.sidecarStorageClasses["ZMONEY"] = .blob
    try mutateAndRehash(
      at: url, fixture: fixture,
      sql: """
        UPDATE event_source_binding SET storage_class='blob'
          WHERE event_id=\(quote(fixture.eventID)) AND semantic='amount';
        UPDATE sidecar_reference SET storage_class='blob'
          WHERE event_id=\(quote(fixture.eventID)) AND sidecar_id=\(quote(amount));
        """,
      overrides: overrides)
    try assertRejectedWithoutMutation(at: url)
  }
}

@Test(
  "persisted v10 and current-schema reject a fully rekeyed known profile with a forged adapter version without mutation",
  arguments: [10, CanonicalLedgerSchema.version])
func lifecycleRejectsFullyRekeyedForgedAdapterWithoutMutation(_ version: Int) throws {
  try withPersistedV19Ledger(version: version) { url, fixture in
    let forged = try V19Fixture(adapterVersion: "forged-money-manager-adapter-v1")
    try rekeyPersistedGraph(at: url, from: fixture, to: forged)
    #expect(forged.profileID == MoneyManagerProfile.profileID)
    #expect(forged.adapterVersion != MoneyManagerProfile.adapterVersion)
    #expect(
      forged.receiptID
        == CanonicalStagingID.stage(
          artifactSHA256: forged.artifactSHA256, profileID: forged.profileID,
          adapterVersion: forged.adapterVersion))
    try mutateAndRehash(at: url, fixture: forged, sql: "SELECT 1;")
    try assertRejectedWithoutMutation(at: url)
  }
}

@Test(
  "persisted v10 and current-schema reject canonical amount normalization with recomputed public hashes without mutation",
  arguments: [10, CanonicalLedgerSchema.version])
func lifecycleRejectsCanonicalAmountNormalizationWithoutMutation(_ version: Int) throws {
  try withPersistedV19Ledger(version: version) { url, fixture in
    var overrides = fixture.digestOverrides()
    overrides.amountLiteral = "12.3"
    try mutateAndRehash(
      at: url, fixture: fixture,
      sql:
        "UPDATE economic_event SET amount_literal='12.3' WHERE event_id=\(quote(fixture.eventID));",
      overrides: overrides)
    try assertRejectedWithoutMutation(at: url)
  }
}

@Test(
  "persisted v10 and current-schema reject a wrong admitted adapter even when no events remain",
  arguments: [10, CanonicalLedgerSchema.version])
func lifecycleRejectsWrongAdmittedAdapterForZeroEventReceipt(_ version: Int) throws {
  try withPersistedV19Ledger(version: version) { url, fixture in
    let forged = try V19Fixture(adapterVersion: "forged-money-manager-adapter-v1")
    try rekeyPersistedGraph(at: url, from: fixture, to: forged)
    try removeEventAndRehash(at: url, fixture: forged)
    try assertRejectedWithoutMutation(at: url)
  }
}

@Test("persisted v10 and current-schema reject fully rekeyed admitted event IDs", arguments: [10, CanonicalLedgerSchema.version])
func lifecycleRejectsFullyRekeyedAdmittedEventID(_ version: Int) throws {
  try withPersistedV19Ledger(version: version) { url, fixture in
    let forgedID = String(repeating: "f", count: 64)
    try rekeyEventID(at: url, from: fixture.eventID, to: forgedID)
    var overrides = fixture.digestOverrides()
    overrides.eventID = forgedID
    try mutateAndRehash(at: url, fixture: fixture, sql: "SELECT 1;", overrides: overrides)
    try assertRejectedWithoutMutation(at: url)
  }
}

@Test(
  "persisted v10 and current-schema reject a fully rehashed opaque NOTE sidecar deletion",
  arguments: [10, CanonicalLedgerSchema.version])
func lifecycleRejectsFullyRehashedOpaqueSidecarDeletion(_ version: Int) throws {
  try withPersistedV19Ledger(version: version) { url, fixture in
    let note = fixture.field(named: "NOTE").id(in: fixture)
    var overrides = fixture.digestOverrides()
    overrides.omittedSidecarIDs.insert(note)
    try mutateAndRehash(
      at: url, fixture: fixture,
      sql: """
        DELETE FROM receipt_sidecar
          WHERE idempotency_key=\(quote(fixture.receiptID)) AND sidecar_id=\(quote(note));
        DELETE FROM sidecar_reference WHERE sidecar_id=\(quote(note));
        """,
      overrides: overrides)
    try assertRejectedWithoutMutation(at: url)
  }
}

@Test(
  "persisted v10 and current-schema reject deleting the complete new v19 opaque commitment",
  arguments: [10, CanonicalLedgerSchema.version])
func lifecycleRejectsCompleteV19CommitmentDeletion(_ version: Int) throws {
  try withPersistedV19Ledger(version: version) { url, fixture in
    let note = fixture.field(named: "NOTE").id(in: fixture)
    var overrides = fixture.digestOverrides()
    overrides.omittedSidecarIDs.insert(note)
    overrides.omitTransactionPreservation = true
    try mutateAndRehash(
      at: url, fixture: fixture,
      sql: """
        DROP TRIGGER ledger_transaction_source_literal_immutable_delete;
        DELETE FROM receipt_sidecar
          WHERE idempotency_key=\(quote(fixture.receiptID)) AND sidecar_id=\(quote(note));
        DELETE FROM sidecar_reference WHERE sidecar_id=\(quote(note));
        DELETE FROM receipt_preservation_membership
          WHERE idempotency_key=\(quote(fixture.receiptID))
            AND anchor_subject_id=\(quote(fixture.transaction.id(in: fixture)));
        DELETE FROM receipt_preservation_payload
          WHERE idempotency_key=\(quote(fixture.receiptID))
            AND anchor_id=\(quote(fixture.transactionAnchorID));
        DELETE FROM receipt_preservation_anchor
          WHERE idempotency_key=\(quote(fixture.receiptID))
            AND anchor_id=\(quote(fixture.transactionAnchorID));
        DELETE FROM provenance_reference WHERE provenance_id=\(quote(note));
        DELETE FROM ledger_transaction_source_literal
          WHERE field='\(MoneyManagerV19Semantics.temporalCommitmentField)';
        DELETE FROM ledger_transaction_source_literal
          WHERE field='\(MoneyManagerV19Semantics.receiptGenerationField)';
        CREATE TRIGGER ledger_transaction_source_literal_immutable_delete
        BEFORE DELETE ON ledger_transaction_source_literal
        BEGIN
          SELECT RAISE(ABORT, 'immutable ledger history');
        END;
        """,
      overrides: overrides)
    try assertRejectedWithoutMutation(at: url)
  }
}

@Test(
  "a current-schema ledger rejects an opaque field deleted from both retention paths",
  arguments: [CanonicalLedgerSchema.version])
func lifecycleRejectsRehashedOpaqueFieldDeletionFromBothPaths(_ version: Int) throws {
  try withPersistedV19Ledger(version: version) { url, fixture in
    let note = fixture.field(named: "NOTE").id(in: fixture)
    var overrides = fixture.digestOverrides()
    overrides.omittedSidecarIDs.insert(note)
    overrides.omittedPreservationIDs.insert(note)
    try mutateAndRehash(
      at: url, fixture: fixture,
      sql: """
        DELETE FROM receipt_sidecar
          WHERE idempotency_key=\(quote(fixture.receiptID)) AND sidecar_id=\(quote(note));
        DELETE FROM sidecar_reference WHERE sidecar_id=\(quote(note));
        DELETE FROM receipt_preservation_membership
          WHERE idempotency_key=\(quote(fixture.receiptID))
            AND source_subject_id=\(quote(note));
        DELETE FROM receipt_preservation_payload
          WHERE idempotency_key=\(quote(fixture.receiptID))
            AND provenance_id=\(quote(note));
        DELETE FROM provenance_reference WHERE provenance_id=\(quote(note));
        """,
      overrides: overrides)
    try assertRejectedWithoutMutation(at: url)
  }
}

@Test(
  "a current-schema ledger rejects a consistently rewritten v19 timezone tuple",
  arguments: [CanonicalLedgerSchema.version])
func lifecycleRejectsRehashedV19TimezoneTuple(_ version: Int) throws {
  try withPersistedV19Ledger(version: version) { url, fixture in
    var overrides = fixture.digestOverrides()
    overrides.instantMilliseconds = 1_738_537_200_000
    overrides.timeZoneValue = "3600"
    overrides.resolvedOffsetSeconds = 3_600
    try mutateAndRehash(
      at: url, fixture: fixture,
      sql: """
        DROP TRIGGER ledger_transaction_revision_immutable_update;
        DROP TRIGGER ledger_transaction_source_literal_immutable_update;
        UPDATE economic_event SET instant_milliseconds=1738537200000,
          timezone_kind='fixed', timezone_value='3600', resolved_offset_seconds=3600
          WHERE event_id=\(quote(fixture.eventID));
        UPDATE ledger_transaction_revision SET instant_milliseconds=1738537200000,
          timezone_kind='fixed', timezone_value='3600', resolved_offset_seconds=3600
          WHERE transaction_id=\(quote(fixture.eventID));
        UPDATE ledger_transaction_source_literal
          SET literal=\(quote(v19ChangedTemporalCommitment()))
          WHERE field='\(MoneyManagerV19Semantics.temporalCommitmentField)';
        UPDATE ledger_transaction_source_literal
          SET literal=\(quote(v19ChangedTemporalCommitment()))
          WHERE field='\(MoneyManagerV19Semantics.temporalAnchorField)';
        CREATE TRIGGER ledger_transaction_revision_immutable_update
        BEFORE UPDATE ON ledger_transaction_revision
        BEGIN
          SELECT RAISE(ABORT, 'immutable ledger history');
        END;
        CREATE TRIGGER ledger_transaction_source_literal_immutable_update
        BEFORE UPDATE ON ledger_transaction_source_literal
        BEGIN
          SELECT RAISE(ABORT, 'immutable ledger history');
        END;
        """,
      overrides: overrides)
    try assertRejectedWithoutMutation(at: url)
  }
}

private enum MoneyManagerProfile {
  static let profileID = "realbyte-android-v19-synthetic-text-subset-v1"
  static let adapterVersion = "money-manager-android-v19-adapter-v1"
}

private struct V19Field {
  let table: String
  let recordKey: String
  let ordinal: Int
  let name: String
  let value: String

  var locator: SourceLocator {
    SourceLocator(table: table, recordKey: recordKey, columnOrdinal: ordinal, columnName: name)
  }

  func id(in fixture: V19Fixture) -> String {
    CanonicalStagingID.field(stagingID: fixture.receiptID, locator: locator)
  }

  var payload: Data { Data(value.utf8) }
}

private struct V19Record {
  let table: String
  let recordKey: String
  let fields: [V19Field]

  func id(in fixture: V19Fixture) -> String {
    CanonicalStagingID.record(
      stagingID: fixture.receiptID, table: table, recordKey: recordKey)
  }
}

private struct V19Anchor {
  let anchorID: String
  let sourceSubjectID: String
  let subjectKind: CanonicalPreservationSubjectKind
  let sourceTable: String
  let sourceRecordKey: String?
}

private struct V19Payload {
  let payloadID: String
  let anchorID: String
  let field: V19Field
}

private struct V19Membership {
  let sourceSubjectID: String
  let subjectKind: String
  let anchorID: String
  let anchorSubjectID: String
  let anchorSubjectKind: String
  let payloadID: String?
}

private struct V19DigestOverrides {
  var amountLiteral = "12.30"
  var eventID: String?
  var instantMilliseconds: Int64 = 1_738_540_800_000
  var timeZoneValue = "0"
  var resolvedOffsetSeconds = 0
  var bindingProvenanceIDs: [CanonicalEventSourceSemantic: String] = [:]
  var bindingStorageClasses: [CanonicalEventSourceSemantic: CanonicalFieldStorageClass] = [:]
  var sidecarStorageClasses: [String: CanonicalFieldStorageClass] = [:]
  var omittedSidecarIDs: Set<String> = []
  var omittedPreservationIDs: Set<String> = []
  var omitTransactionPreservation = false
}

private struct V19Fixture {
  let artifactSHA256 = String(repeating: "a", count: 64)
  let profileID = MoneyManagerProfile.profileID
  let adapterVersion: String
  let stagingDigest: String
  let receiptID: String
  let transaction: V19Record
  let receiptOwnedRecords: [V19Record]
  let receiptOwnedTables = ["ASSETS", "ZCATEGORY", "CURRENCY"]
  let eventID: String
  let accountID: String

  var transactionAnchorID: String {
    try! StableCanonicalID.preservationAnchor(
      stagingID: receiptID, sourceSubjectID: transaction.id(in: self), kind: .record)
  }

  init(adapterVersion: String = MoneyManagerProfile.adapterVersion) throws {
    self.adapterVersion = adapterVersion
    let receiptID = CanonicalStagingID.stage(
      artifactSHA256: artifactSHA256, profileID: profileID, adapterVersion: adapterVersion)
    self.receiptID = receiptID
    stagingDigest = CanonicalReceiptDigest.hash([
      "ledger-atlas/synthetic-staging/v1", artifactSHA256, profileID, adapterVersion,
    ])
    transaction = V19Record(
      table: "INOUTCOME", recordKey: "transaction-record",
      fields: [
        .init(
          table: "INOUTCOME", recordKey: "transaction-record", ordinal: 0, name: "uid",
          value: "synthetic-transaction"),
        .init(
          table: "INOUTCOME", recordKey: "transaction-record", ordinal: 1, name: "assetUid",
          value: "synthetic-account"),
        .init(
          table: "INOUTCOME", recordKey: "transaction-record", ordinal: 2, name: "currencyUid",
          value: "synthetic-currency"),
        .init(
          table: "INOUTCOME", recordKey: "transaction-record", ordinal: 3, name: "DO_TYPE",
          value: "1"),
        .init(
          table: "INOUTCOME", recordKey: "transaction-record", ordinal: 4, name: "ctgUid",
          value: "synthetic-category"),
        .init(
          table: "INOUTCOME", recordKey: "transaction-record", ordinal: 5, name: "ZMONEY",
          value: "12.30"),
        .init(
          table: "INOUTCOME", recordKey: "transaction-record", ordinal: 6, name: "WDATE",
          value: "2025-02-03"),
        .init(
          table: "INOUTCOME", recordKey: "transaction-record", ordinal: 7, name: "ZDATE",
          value: "1738540800000"),
        .init(
          table: "INOUTCOME", recordKey: "transaction-record", ordinal: 8, name: "NOTE",
          value: "synthetic opaque note"),
      ])
    receiptOwnedRecords = [
      V19Record(
        table: "ASSETS", recordKey: "asset-record",
        fields: [
          .init(
            table: "ASSETS", recordKey: "asset-record", ordinal: 0, name: "uid",
            value: "synthetic-account")
        ]),
      V19Record(
        table: "ZCATEGORY", recordKey: "category-record",
        fields: [
          .init(
            table: "ZCATEGORY", recordKey: "category-record", ordinal: 0, name: "uid",
            value: "synthetic-category")
        ]),
      V19Record(
        table: "CURRENCY", recordKey: "currency-record",
        fields: [
          .init(
            table: "CURRENCY", recordKey: "currency-record", ordinal: 0, name: "uid",
            value: "synthetic-currency"),
          .init(
            table: "CURRENCY", recordKey: "currency-record", ordinal: 1, name: "ISO", value: "USD"),
        ]),
    ]
    eventID = try StableCanonicalID.event(
      sourceRecordID: CanonicalStagingID.record(
        stagingID: receiptID, table: "INOUTCOME", recordKey: "transaction-record"),
      effectOrdinal: 0)
    accountID = try StableCanonicalID.account(
      profileID: profileID, sourceAccountID: "synthetic-account")
  }

  func field(_ semantic: CanonicalEventSourceSemantic) -> V19Field {
    switch semantic {
    case .amount: return transaction.fields[5]
    case .currency: return receiptOwnedRecords[2].fields[1]
    case .occurredAt: return transaction.fields[7]
    case .account: return transaction.fields[1]
    case .kind: return transaction.fields[3]
    }
  }

  func field(named name: String) -> V19Field {
    (transaction.fields + receiptOwnedRecords.flatMap(\.fields)).first { $0.name == name }!
  }

  func allFields() -> [V19Field] {
    transaction.fields + receiptOwnedRecords.flatMap(\.fields)
  }

  func isOpaqueTransactionField(_ field: V19Field) -> Bool {
    ![self.field(.amount), self.field(.occurredAt), self.field(.account), self.field(.kind)]
      .contains { $0.id(in: self) == field.id(in: self) }
  }

  func anchors() throws -> [V19Anchor] {
    let tables = try receiptOwnedTables.map { table in
      let subjectID = CanonicalStagingID.table(stagingID: receiptID, table: table)
      return V19Anchor(
        anchorID: try StableCanonicalID.preservationAnchor(
          stagingID: receiptID, sourceSubjectID: subjectID, kind: .table),
        sourceSubjectID: subjectID, subjectKind: .table, sourceTable: table, sourceRecordKey: nil)
    }
    let records = try (receiptOwnedRecords + [transaction]).map { record in
      let subjectID = record.id(in: self)
      return V19Anchor(
        anchorID: try StableCanonicalID.preservationAnchor(
          stagingID: receiptID, sourceSubjectID: subjectID, kind: .record),
        sourceSubjectID: subjectID, subjectKind: .record,
        sourceTable: record.table, sourceRecordKey: record.recordKey)
    }
    return tables + records
  }

  func payloads() throws -> [V19Payload] {
    let recordAnchors = try Dictionary(
      uniqueKeysWithValues: anchors().filter { $0.subjectKind == .record }.map {
        ($0.sourceSubjectID, $0.anchorID)
      })
    var result: [V19Payload] = []
    for record in receiptOwnedRecords + [transaction] {
      for field in record.fields {
        guard record.table != transaction.table || isOpaqueTransactionField(field) else { continue }
        let sourceID = field.id(in: self)
        result.append(
          V19Payload(
            payloadID: try StableCanonicalID.preservationPayload(
              receiptID: receiptID, anchorID: recordAnchors[record.id(in: self)]!,
              sourceSubjectID: sourceID, formatVersion: 1, declaredType: "TEXT",
              storageClass: .text, payload: field.payload),
            anchorID: recordAnchors[record.id(in: self)]!, field: field))
      }
    }
    return result
  }

  func memberships() throws -> [V19Membership] {
    let anchors = try anchors()
    let payloads = try payloads()
    let anchorRows = anchors.map {
      V19Membership(
        sourceSubjectID: $0.sourceSubjectID, subjectKind: $0.subjectKind.rawValue,
        anchorID: $0.anchorID, anchorSubjectID: $0.sourceSubjectID,
        anchorSubjectKind: $0.subjectKind.rawValue, payloadID: nil)
    }
    let recordByID = Dictionary(
      uniqueKeysWithValues: anchors.filter { $0.subjectKind == .record }.map {
        ($0.sourceSubjectID, $0)
      })
    let fieldRows = payloads.map { payload in
      let record = (receiptOwnedRecords + [transaction]).first {
        $0.fields.contains { $0.id(in: self) == payload.field.id(in: self) }
      }!
      let recordAnchor = recordByID[record.id(in: self)]!
      return V19Membership(
        sourceSubjectID: payload.field.id(in: self), subjectKind: "field",
        anchorID: recordAnchor.anchorID, anchorSubjectID: recordAnchor.sourceSubjectID,
        anchorSubjectKind: "record", payloadID: payload.payloadID)
    }
    return anchorRows + fieldRows
  }

  func digestOverrides() -> V19DigestOverrides { .init() }

  func eventSetHash(_ overrides: V19DigestOverrides = .init()) -> String {
    let amount = field(.amount)
    let amountID = overrides.bindingProvenanceIDs[.amount] ?? amount.id(in: self)
    var components = [
      CanonicalReceiptDigest.eventSetPrefix, overrides.eventID ?? eventID, accountID, "expense",
      overrides.amountLiteral, "USD", String(overrides.instantMilliseconds), "2025", "2", "3", "0",
      "0", "0", "0", "fixed", overrides.timeZoneValue, "millisecond",
      String(overrides.resolvedOffsetSeconds), transaction.id(in: self), amountID,
    ]
    for semantic in CanonicalEventSourceSemantic.allCases.sorted(by: { $0.rawValue < $1.rawValue })
    {
      let field = field(semantic)
      components += [
        semantic.rawValue, overrides.bindingProvenanceIDs[semantic] ?? field.id(in: self),
      ]
      components += CanonicalReceiptDigest.optionalComponents("TEXT")
      components.append((overrides.bindingStorageClasses[semantic] ?? .text).rawValue)
    }
    for field in transaction.fields.sorted(by: { $0.id(in: self) < $1.id(in: self) }) {
      guard !overrides.omittedSidecarIDs.contains(field.id(in: self)) else { continue }
      let storage = overrides.sidecarStorageClasses[field.name] ?? .text
      components += [field.id(in: self), field.id(in: self), "1"]
      components += CanonicalReceiptDigest.optionalComponents("TEXT")
      components += [
        storage.rawValue, CanonicalReceiptDigest.sha256(field.payload), artifactSHA256, profileID,
        adapterVersion,
      ]
      components += CanonicalReceiptDigest.optionalComponents(nil)
      components += [field.table, field.recordKey]
      components += CanonicalReceiptDigest.optionalComponents(String(field.ordinal))
      components += CanonicalReceiptDigest.optionalComponents(field.name)
    }
    return CanonicalReceiptDigest.hash(components)
  }

  func preservationHash(_ overrides: V19DigestOverrides = .init()) throws -> String {
    var components = ["ledger-atlas/receipt-owned-preservation-set/v4"]
    let memberships = try memberships().filter {
      (!overrides.omitTransactionPreservation || $0.anchorID != transactionAnchorID)
        && !overrides.omittedPreservationIDs.contains($0.sourceSubjectID)
    }
    for membership in memberships.sorted(by: { $0.sourceSubjectID < $1.sourceSubjectID }) {
      components += [
        receiptID, membership.sourceSubjectID, membership.subjectKind, membership.anchorID,
        membership.anchorSubjectID, membership.anchorSubjectKind,
      ]
      components += CanonicalReceiptDigest.optionalComponents(membership.payloadID)
    }
    for anchor in try anchors().filter({
      ($0.subjectKind == .table || $0.subjectKind == .record)
        && (!overrides.omitTransactionPreservation || $0.anchorID != transactionAnchorID)
    })
    .sorted(by: { $0.anchorID < $1.anchorID }) {
      components += [
        anchor.anchorID, receiptID, anchor.sourceSubjectID, anchor.subjectKind.rawValue,
        artifactSHA256, profileID, adapterVersion,
      ]
      components += CanonicalReceiptDigest.optionalComponents(nil)
      components.append(anchor.sourceTable)
      components += CanonicalReceiptDigest.optionalComponents(anchor.sourceRecordKey)
    }
    for payload in try payloads().filter({
      (!overrides.omitTransactionPreservation || $0.anchorID != transactionAnchorID)
        && !overrides.omittedPreservationIDs.contains($0.field.id(in: self))
    }).sorted(by: { $0.payloadID < $1.payloadID }) {
      let field = payload.field
      components += [payload.payloadID, receiptID, payload.anchorID, field.id(in: self), "1"]
      components += CanonicalReceiptDigest.optionalComponents("TEXT")
      components += [
        "text", CanonicalReceiptDigest.sha256(field.payload), artifactSHA256, profileID,
        adapterVersion,
      ]
      components += CanonicalReceiptDigest.optionalComponents(nil)
      components += [field.table, field.recordKey]
      components += CanonicalReceiptDigest.optionalComponents(String(field.ordinal))
      components += CanonicalReceiptDigest.optionalComponents(field.name)
      components.append(field.id(in: self))
    }
    return CanonicalReceiptDigest.hash(components)
  }

  func reconciliationHash(
    eventSetHash: String? = nil, preservationHash: String? = nil, eventCount: Int = 1,
    generation: MoneyManagerV19Semantics.ReceiptGeneration = .current
  ) throws -> String {
    let events = eventSetHash ?? self.eventSetHash()
    let preservation = try preservationHash ?? self.preservationHash()
    return MoneyManagerV19Semantics.receiptIntegrityHash(
      envelope: [
        receiptID, stagingDigest, artifactSHA256, profileID, adapterVersion, events,
        String(eventCount), "8",
      ], eventSetHash: events, preservationHash: preservation, generation: generation)
  }
}

private func withPersistedV19Ledger(
  version: Int, includeCommitment: Bool = true,
  _ body: (URL, V19Fixture) throws -> Void
) throws {
  guard version == 10 || version == CanonicalLedgerSchema.version else { throw ReplayError.sqlite }
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("ledger.sqlite")
  let fixture = try V19Fixture()
  try writeV19V10Ledger(to: url, fixture: fixture, includeCommitment: includeCommitment)
  if version == 10 {
    #expect(try LedgerStoreLifecycle.inspect(at: url) == .upgradeRequired)
  } else {
    guard includeCommitment else { throw ReplayError.sqlite }
    try materializeCurrentV19Fixture(at: url, fixture: fixture)
    #expect(try LedgerStoreLifecycle.inspect(at: url) == .current)
  }
  try body(url, fixture)
}

private func materializeCurrentV19Fixture(at url: URL, fixture: V19Fixture) throws {
  guard
    let trustKey = try LedgerReceiptTrust.key(
      for: url, create: true, stableIdentity: fixture.receiptID)
  else {
    throw ReplayError.sqlite
  }
  let fieldIDs = fixture.transaction.fields.map { $0.id(in: fixture) }.sorted()
  let sourceRecordID = fixture.transaction.id(in: fixture)
  let sourceSubjectSet = MoneyManagerV19Semantics.sourceSubjectSetCommitment(
    sourceRecordID: sourceRecordID, fieldIDs: fieldIDs)
  try withSQLite(url) { database in
    try execute(database, "BEGIN IMMEDIATE;")
    for statement in CanonicalLedgerSchema.v10ToV11MigrationStatements
      + CanonicalLedgerSchema.v11ToV12MigrationStatements
      + CanonicalLedgerSchema.v12ToV13MigrationStatements
    {
      try execute(database, statement)
    }
    let revisionID = try StableLedgerID.revision(transactionID: fixture.eventID, revision: 1)
    try execute(
      database,
      """
      INSERT INTO ledger_transaction_source_literal VALUES (\(quote(revisionID)), 4,
        '\(MoneyManagerV19Semantics.sourceSubjectSetField)', \(quote(sourceSubjectSet)), NULL);
      INSERT INTO ledger_transaction_source_literal VALUES (\(quote(revisionID)), 5,
        '\(MoneyManagerV19Semantics.sourceTimeZoneField)', 'fixed:0', NULL);
      UPDATE ledger_meta SET value='\(CanonicalLedgerSchema.version)' WHERE key='schema_version';
      UPDATE ledger_meta SET value='\(CanonicalLedgerSchema.fingerprint)' WHERE key='schema_fingerprint';
      """)
    let integrity = try fixture.reconciliationHash()
    let signature = LedgerReceiptTrust.signature(
      key: trustKey, receiptID: fixture.receiptID, integrityHash: integrity)
    try execute(
      database,
      "INSERT INTO ledger_receipt_trust_anchor(idempotency_key, algorithm, signature) VALUES(\(quote(fixture.receiptID)), '\(LedgerReceiptTrust.algorithm)', \(quote(signature)));"
    )
    try execute(database, "COMMIT;")
  }
}

private func writeV19V10Ledger(
  to url: URL, fixture: V19Fixture, includeCommitment: Bool
) throws {
  try withSQLite(url) { database in
    try execute(
      database,
      "PRAGMA foreign_keys=ON; PRAGMA application_id=\(CanonicalLedgerSchema.applicationID);")
    for object in CanonicalLedgerSchema.legacyV10Objects { try execute(database, object.ddl) }
    try execute(
      database,
      """
      INSERT INTO ledger_meta(key, value) VALUES
        ('schema_version', '10'), ('ledger_identity', 'ledger-atlas-canonical'),
        ('schema_fingerprint', '\(CanonicalLedgerSchema.legacyV10Fingerprint)');
      """)
    for field in fixture.allFields().sorted(by: { $0.id(in: fixture) < $1.id(in: fixture) }) {
      try execute(
        database,
        """
        INSERT INTO provenance_reference VALUES (\(quote(field.id(in: fixture))),
          \(quote(fixture.artifactSHA256)), \(quote(fixture.profileID)),
          \(quote(fixture.adapterVersion)), NULL, \(quote(field.table)),
          \(quote(field.recordKey)), \(field.ordinal), \(quote(field.name)));
        """)
    }
    try execute(
      database,
      """
      INSERT INTO economic_event VALUES (\(quote(fixture.eventID)), \(quote(fixture.accountID)),
        'expense', '12.30', 'USD',
        1738540800000, 2025, 2, 3, 0, 0, 0, 0, 'fixed', '0', 'millisecond', 0,
        \(quote(fixture.transaction.id(in: fixture))),
        \(quote(fixture.field(.amount).id(in: fixture))));
      INSERT INTO import_receipt VALUES (\(quote(fixture.receiptID)),
        \(quote(fixture.stagingDigest)), \(quote(fixture.artifactSHA256)),
        \(quote(fixture.profileID)), \(quote(fixture.adapterVersion)),
        \(quote(try fixture.reconciliationHash(generation: includeCommitment ? .current : .legacy))),
        \(quote(fixture.eventSetHash())), 1, 8);
      INSERT INTO receipt_event VALUES (\(quote(fixture.receiptID)), \(quote(fixture.eventID)));
      """)
    for semantic in CanonicalEventSourceSemantic.allCases {
      let field = fixture.field(semantic)
      try execute(
        database,
        """
        INSERT INTO event_source_binding VALUES (\(quote(fixture.eventID)),
          \(quote(semantic.rawValue)), \(quote(field.id(in: fixture))), 'TEXT', 'text');
        INSERT INTO receipt_binding VALUES (\(quote(fixture.receiptID)),
          \(quote(fixture.eventID)), \(quote(semantic.rawValue)),
          \(quote(field.id(in: fixture))));
        """)
    }
    for field in fixture.transaction.fields {
      let id = field.id(in: fixture)
      try execute(
        database,
        """
        INSERT INTO sidecar_reference VALUES (\(quote(id)), \(quote(fixture.eventID)),
          \(quote(id)), 1, 'TEXT', 'text', X'\(hex(field.payload))');
        INSERT INTO receipt_sidecar VALUES (\(quote(fixture.receiptID)), \(quote(id)),
          \(quote(fixture.eventID)), \(quote(id)));
        """)
    }
    for anchor in try fixture.anchors() {
      try execute(
        database,
        """
        INSERT INTO receipt_preservation_anchor VALUES (\(quote(anchor.anchorID)),
          \(quote(fixture.receiptID)), \(quote(anchor.sourceSubjectID)),
          \(quote(anchor.subjectKind.rawValue)), \(quote(fixture.artifactSHA256)),
          \(quote(fixture.profileID)), \(quote(fixture.adapterVersion)), NULL,
          \(quote(anchor.sourceTable)), \(anchor.sourceRecordKey.map(quote) ?? "NULL"));
        """)
    }
    for payload in try fixture.payloads() {
      let field = payload.field
      let fieldID = field.id(in: fixture)
      try execute(
        database,
        """
        INSERT INTO receipt_preservation_payload VALUES (\(quote(payload.payloadID)),
          \(quote(fixture.receiptID)), \(quote(payload.anchorID)), \(quote(fieldID)),
          \(quote(fieldID)), 1, 'TEXT', 'text', X'\(hex(field.payload))');
        """)
    }
    for membership in try fixture.memberships() {
      try execute(
        database,
        """
        INSERT INTO receipt_preservation_membership VALUES (\(quote(fixture.receiptID)),
          \(quote(membership.sourceSubjectID)), \(quote(membership.subjectKind)),
          \(quote(membership.anchorID)), \(quote(membership.anchorSubjectID)),
          \(quote(membership.anchorSubjectKind)), \(membership.payloadID.map(quote) ?? "NULL"));
        """)
    }
    let revisionID = try StableLedgerID.revision(transactionID: fixture.eventID, revision: 1)
    let importedOrigin = String(repeating: "e", count: 64)
    try execute(
      database,
      """
      BEGIN IMMEDIATE;
      INSERT INTO ledger_origin VALUES (\(quote(importedOrigin)), 'imported', NULL);
      INSERT INTO ledger_account VALUES (\(quote(fixture.accountID)), 'synthetic-account',
        'USD', \(quote(importedOrigin)), 'active');
      INSERT INTO ledger_transaction VALUES (\(quote(fixture.eventID)), \(quote(revisionID)));
      INSERT INTO ledger_transaction_revision VALUES (\(quote(revisionID)),
        \(quote(fixture.eventID)), 1, NULL, NULL, 'expense', 1738540800000,
        2025, 2, 3, 0, 0, 0, 0, 'fixed', '0', 'millisecond', 0, NULL, NULL,
        \(quote(importedOrigin)), 'active', 1738540800000);
      INSERT INTO ledger_transaction_effect VALUES (\(quote(revisionID)),
        \(quote(fixture.accountID)), 'decrease', '12.30', 'USD');
      INSERT INTO ledger_transaction_source_literal VALUES (\(quote(revisionID)), 0,
        'import.eventID', \(quote(fixture.eventID)), NULL);
      COMMIT;
      """)
    if includeCommitment {
      try execute(
        database,
        "INSERT INTO ledger_transaction_source_literal VALUES (\(quote(revisionID)), 1, 'import.v19Commitment', \(quote(v19TemporalCommitment())), NULL);"
      )
    }
    try execute(
      database,
      "INSERT INTO ledger_transaction_source_literal VALUES (\(quote(revisionID)), \(includeCommitment ? 2 : 1), '\(MoneyManagerV19Semantics.receiptGenerationField)', '\(includeCommitment ? MoneyManagerV19Semantics.currentReceiptGenerationLiteral : MoneyManagerV19Semantics.legacyReceiptGenerationLiteral)', NULL);"
    )
    if includeCommitment {
      try execute(
        database,
        "INSERT INTO ledger_transaction_source_literal VALUES (\(quote(revisionID)), 3, '\(MoneyManagerV19Semantics.temporalAnchorField)', \(quote(v19TemporalCommitment())), NULL);"
      )
    }
  }
  guard chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else { throw ReplayError.sqlite }
}

private func mutateAndRehash(
  at url: URL, fixture: V19Fixture, sql: String, overrides: V19DigestOverrides = .init(),
  generation: MoneyManagerV19Semantics.ReceiptGeneration = .current
) throws {
  let eventSetHash = fixture.eventSetHash(overrides)
  let reconciliationHash = try fixture.reconciliationHash(
    eventSetHash: eventSetHash, preservationHash: fixture.preservationHash(overrides),
    generation: generation)
  try withSQLite(url) { database in
    try execute(
      database,
      """
      BEGIN IMMEDIATE;
      \(sql)
      UPDATE import_receipt SET event_set_hash=\(quote(eventSetHash)),
        reconciliation_hash=\(quote(reconciliationHash))
        WHERE idempotency_key=\(quote(fixture.receiptID));
      COMMIT;
      """)
  }
}

private func removeEventAndRehash(at url: URL, fixture: V19Fixture) throws {
  let emptyEventSet = CanonicalReceiptDigest.hash([CanonicalReceiptDigest.eventSetPrefix])
  let integrity = try fixture.reconciliationHash(
    eventSetHash: emptyEventSet, preservationHash: fixture.preservationHash(), eventCount: 0)
  try withSQLite(url) { database in
    try execute(
      database,
      """
      BEGIN IMMEDIATE;
      DELETE FROM receipt_binding WHERE idempotency_key=\(quote(fixture.receiptID));
      DELETE FROM receipt_sidecar WHERE idempotency_key=\(quote(fixture.receiptID));
      DELETE FROM sidecar_reference WHERE event_id=\(quote(fixture.eventID));
      DELETE FROM event_source_binding WHERE event_id=\(quote(fixture.eventID));
      DELETE FROM receipt_event WHERE idempotency_key=\(quote(fixture.receiptID));
      DELETE FROM economic_event WHERE event_id=\(quote(fixture.eventID));
      DELETE FROM provenance_reference
        WHERE source_table='INOUTCOME' AND source_column_name<>'NOTE';
      UPDATE import_receipt SET event_count=0, event_set_hash=\(quote(emptyEventSet)),
        reconciliation_hash=\(quote(integrity))
        WHERE idempotency_key=\(quote(fixture.receiptID));
      COMMIT;
      """)
  }
}

private func rekeyEventID(at url: URL, from old: String, to new: String) throws {
  try withSQLite(url) { database in
    try execute(
      database,
      """
      PRAGMA foreign_keys=OFF;
      BEGIN IMMEDIATE;
      UPDATE economic_event SET event_id=\(quote(new)) WHERE event_id=\(quote(old));
      UPDATE event_source_binding SET event_id=\(quote(new)) WHERE event_id=\(quote(old));
      UPDATE sidecar_reference SET event_id=\(quote(new)) WHERE event_id=\(quote(old));
      UPDATE receipt_event SET event_id=\(quote(new)) WHERE event_id=\(quote(old));
      UPDATE receipt_binding SET event_id=\(quote(new)) WHERE event_id=\(quote(old));
      UPDATE receipt_sidecar SET event_id=\(quote(new)) WHERE event_id=\(quote(old));
      COMMIT;
      PRAGMA foreign_keys=ON;
      """)
  }
}

private func rekeyPersistedGraph(at url: URL, from old: V19Fixture, to new: V19Fixture) throws {
  var ids: [String: String] = [
    old.receiptID: new.receiptID, old.eventID: new.eventID,
    old.transaction.id(in: old): new.transaction.id(in: new),
  ]
  for table in old.receiptOwnedTables {
    ids[CanonicalStagingID.table(stagingID: old.receiptID, table: table)] =
      CanonicalStagingID.table(stagingID: new.receiptID, table: table)
  }
  let oldFields = old.allFields()
  let newFields = new.allFields()
  for oldField in oldFields {
    let newField = newFields.first {
      $0.table == oldField.table && $0.recordKey == oldField.recordKey
        && $0.ordinal == oldField.ordinal && $0.name == oldField.name
    }!
    ids[oldField.id(in: old)] = newField.id(in: new)
  }
  for oldRecord in old.receiptOwnedRecords {
    let newRecord = new.receiptOwnedRecords.first {
      $0.table == oldRecord.table && $0.recordKey == oldRecord.recordKey
    }!
    ids[oldRecord.id(in: old)] = newRecord.id(in: new)
  }
  let oldAnchors = try old.anchors()
  let newAnchors = try new.anchors()
  for oldAnchor in oldAnchors {
    let newAnchor = newAnchors.first {
      $0.sourceTable == oldAnchor.sourceTable && $0.sourceRecordKey == oldAnchor.sourceRecordKey
        && $0.subjectKind == oldAnchor.subjectKind
    }!
    ids[oldAnchor.anchorID] = newAnchor.anchorID
    ids[oldAnchor.sourceSubjectID] = newAnchor.sourceSubjectID
  }
  let oldPayloads = try old.payloads()
  let newPayloads = try new.payloads()
  for oldPayload in oldPayloads {
    let newPayload = newPayloads.first {
      $0.field.table == oldPayload.field.table && $0.field.recordKey == oldPayload.field.recordKey
        && $0.field.ordinal == oldPayload.field.ordinal && $0.field.name == oldPayload.field.name
    }!
    ids[oldPayload.payloadID] = newPayload.payloadID
  }

  try withSQLite(url) { database in
    try execute(
      database, "PRAGMA foreign_keys=OFF; PRAGMA ignore_check_constraints=ON; BEGIN IMMEDIATE;")
    try remap(database, table: "provenance_reference", column: "provenance_id", ids)
    try execute(
      database, "UPDATE provenance_reference SET adapter_version=\(quote(new.adapterVersion));")
    try remap(database, table: "economic_event", column: "event_id", ids)
    try remap(database, table: "economic_event", column: "source_record_id", ids)
    try remap(database, table: "economic_event", column: "provenance_id", ids)
    try remap(database, table: "event_source_binding", column: "event_id", ids)
    try remap(database, table: "event_source_binding", column: "provenance_id", ids)
    try remap(database, table: "sidecar_reference", column: "sidecar_id", ids)
    try remap(database, table: "sidecar_reference", column: "event_id", ids)
    try remap(database, table: "sidecar_reference", column: "provenance_id", ids)
    try remap(database, table: "import_receipt", column: "idempotency_key", ids)
    try execute(
      database,
      "UPDATE import_receipt SET staging_digest=\(quote(new.stagingDigest)), adapter_version=\(quote(new.adapterVersion));"
    )
    try remap(database, table: "receipt_event", column: "idempotency_key", ids)
    try remap(database, table: "receipt_event", column: "event_id", ids)
    try remap(database, table: "receipt_binding", column: "idempotency_key", ids)
    try remap(database, table: "receipt_binding", column: "event_id", ids)
    try remap(database, table: "receipt_binding", column: "provenance_id", ids)
    try remap(database, table: "receipt_sidecar", column: "idempotency_key", ids)
    try remap(database, table: "receipt_sidecar", column: "sidecar_id", ids)
    try remap(database, table: "receipt_sidecar", column: "event_id", ids)
    try remap(database, table: "receipt_sidecar", column: "provenance_id", ids)
    try remap(database, table: "receipt_preservation_anchor", column: "anchor_id", ids)
    try remap(database, table: "receipt_preservation_anchor", column: "idempotency_key", ids)
    try remap(database, table: "receipt_preservation_anchor", column: "source_subject_id", ids)
    try execute(
      database,
      "UPDATE receipt_preservation_anchor SET adapter_version=\(quote(new.adapterVersion));")
    try remap(database, table: "receipt_preservation_payload", column: "payload_id", ids)
    try remap(database, table: "receipt_preservation_payload", column: "idempotency_key", ids)
    try remap(database, table: "receipt_preservation_payload", column: "anchor_id", ids)
    try remap(database, table: "receipt_preservation_payload", column: "source_subject_id", ids)
    try remap(database, table: "receipt_preservation_payload", column: "provenance_id", ids)
    try remap(database, table: "receipt_preservation_membership", column: "idempotency_key", ids)
    try remap(database, table: "receipt_preservation_membership", column: "source_subject_id", ids)
    try remap(database, table: "receipt_preservation_membership", column: "anchor_id", ids)
    try remap(database, table: "receipt_preservation_membership", column: "anchor_subject_id", ids)
    try remap(database, table: "receipt_preservation_membership", column: "payload_id", ids)
    try execute(database, "COMMIT; PRAGMA ignore_check_constraints=OFF;")
  }
}

private func assertRejectedWithoutMutation(at url: URL) throws {
  let before = try Data(contentsOf: url)
  do {
    let inspection = try LedgerStoreLifecycle.inspect(at: url)
    #expect(inspection == .upgradeRequired)
  } catch LedgerStoreLifecycle.Error.invalidStore {
  }
  #expect(try Data(contentsOf: url) == before)
  do {
    _ = try LedgerStoreLifecycle.open(at: url)
    Issue.record("expected lifecycle rejection")
  } catch LedgerStoreLifecycle.Error.invalidStore {
  } catch LedgerStoreLifecycle.Error.unsupportedStore {
  }
  #expect(try Data(contentsOf: url) == before)
}

private func readReceiptEventCount(at url: URL, receipt: String) throws -> Int {
  try withSQLite(url) { database in
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT count(*) FROM receipt_event WHERE idempotency_key='\(receipt)'", -1,
        &statement, nil) == SQLITE_OK, let statement
    else { throw ReplayError.sqlite }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw ReplayError.sqlite }
    return Int(sqlite3_column_int64(statement, 0))
  }
}

private func remap(
  _ database: OpaquePointer, table: String, column: String, _ ids: [String: String]
) throws {
  let cases = ids.map { "WHEN \(quote($0.key)) THEN \(quote($0.value))" }.joined(separator: " ")
  try execute(database, "UPDATE \(table) SET \(column)=CASE \(column) \(cases) ELSE \(column) END;")
}

private func withSQLite<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw ReplayError.sqlite
  }
  defer { sqlite3_close(database) }
  return try body(database)
}

private func execute(_ database: OpaquePointer, _ sql: String) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw ReplayError.statement(String(cString: sqlite3_errmsg(database)))
  }
}

private func quote(_ value: String) -> String {
  "'\(value.replacingOccurrences(of: "'", with: "''"))'"
}

private func hexDigest(of data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func hex(_ data: Data) -> String {
  data.map { String(format: "%02x", $0) }.joined()
}

private func v19TemporalCommitment() -> String {
  CanonicalReceiptDigest.hash([
    "ledger-atlas/money-manager-v19-source-temporal/v1", "fixed", "0", "1738540800000",
    "0",
  ])
}

private func v19ChangedTemporalCommitment() -> String {
  CanonicalReceiptDigest.hash([
    "ledger-atlas/money-manager-v19-source-temporal/v1", "fixed", "3600", "1738537200000",
    "3600",
  ])
}

private enum ReplayError: Error {
  case sqlite
  case statement(String)
}

@Test("saves keep working while read-only connections open and close on the same file")
func savesSurviveConcurrentReadOnlyOpens() throws {
  try withPersistedV19Ledger(version: CanonicalLedgerSchema.version) { url, _ in
    let store = try LedgerStore.openForMutation(at: url)
    let account = try #require(try store.readSnapshot().accounts.first)
    let failures = LockedFailures()
    let reads = LockedCount()
    let stop = LockedFlag()
    let readers = DispatchGroup()
    // The app's session loads the ledger read-only on a background thread while the editor
    // saves through its own connection. A load may be refused while a save's journal is on
    // disk; what must never happen is a save failing because a load was running.
    for _ in 0..<2 {
      DispatchQueue.global().async(group: readers) {
        while !stop.isSet {
          if let reader = try? LedgerStore.openReadOnly(at: url), (try? reader.readSnapshot()) != nil {
            reads.increment()
          }
        }
      }
    }
    // Save at least 150 times, and keep saving until 5 more reads have completed while saves
    // run: fast saves can otherwise all finish before either reader gets one full read (seen
    // after #152). Reads that finished before the first save don't count.
    let readsBeforeSaves = reads.value
    var index = 0
    while index < 150 || (reads.value < readsBeforeSaves + 5 && index < 5_000) {
      defer { index += 1 }
      let renamed = try LedgerAccount(
        id: account.id, name: "Save \(index)", currencyUnit: account.currencyUnit,
        origin: account.origin, lifecycle: account.lifecycle, groupID: account.groupID,
        displayOrder: account.displayOrder, hidden: account.hidden,
        includeInTotals: account.includeInTotals, variant: account.variant)
      do {
        try store.updateAccount(renamed)
      } catch {
        failures.record("save \(index): \(error)")
      }
    }
    let readsDuringSaves = reads.value - readsBeforeSaves
    stop.set()
    readers.wait()
    #expect(failures.all.isEmpty, "\(failures.all.prefix(5))")
    #expect(
      readsDuringSaves >= 5,
      "only \(readsDuringSaves) read-only loads finished during \(index) saves, so too little overlapped")
    #expect(try store.readSnapshot().accounts.first { $0.id == account.id }?.name == "Save \(index - 1)")
  }
}

private final class LockedFailures: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func record(_ value: String) { lock.withLock { values.append(value) } }
  var all: [String] { lock.withLock { values } }
}

private final class LockedCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func set() { lock.withLock { value = true } }
  var isSet: Bool { lock.withLock { value } }
}
